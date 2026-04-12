#!/usr/bin/env bash
set -euo pipefail

PROJECT_NAME="AeroFlux"
SERVICE_NAME="aeroflux"
INSTALL_DIR="/etc/aeroflux"
CONFIG_FILE="$INSTALL_DIR/config.json"
META_FILE="$INSTALL_DIR/install.env"
LINKS_FILE="$INSTALL_DIR/share-links.txt"
CERT_FILE="$INSTALL_DIR/cert.pem"
KEY_FILE="$INSTALL_DIR/key.pem"
OPENSSL_FILE="$INSTALL_DIR/openssl.cnf"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
BIN_PATH="/usr/local/bin/sing-box"
SHORTCUT_PATH="/usr/local/bin/afx"
TUNE_SCRIPT_PATH="/usr/local/lib/${SERVICE_NAME}/system-tune.sh"
REPO_TUNE_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts/system-tune.sh"
DEFAULT_REALITY_SERVER="www.cloudflare.com"
DEFAULT_HY2_SNI="www.bing.com"

red() { printf '\033[31;1m%s\033[0m\n' "$1"; }
green() { printf '\033[32;1m%s\033[0m\n' "$1"; }
yellow() { printf '\033[33;1m%s\033[0m\n' "$1"; }
blue() { printf '\033[36;1m%s\033[0m\n' "$1"; }

prompt() {
  local message="$1"
  local default_value="${2-}"
  local answer
  if [[ -n "$default_value" ]]; then
    read -r -p "$message [$default_value]: " answer
    printf '%s' "${answer:-$default_value}"
  else
    read -r -p "$message: " answer
    printf '%s' "$answer"
  fi
}

require_root() {
  if [[ ${EUID} -ne 0 ]]; then
    red "请使用 root 运行脚本"
    exit 1
  fi
}

require_systemd() {
  if ! command -v systemctl >/dev/null 2>&1; then
    red "当前系统未检测到 systemd，本脚本只支持 systemd 服务器"
    exit 1
  fi
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

detect_arch() {
  case "$(uname -m)" in
    x86_64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    armv7l) ARCH="armv7" ;;
    *)
      red "暂不支持的架构: $(uname -m)"
      exit 1
      ;;
  esac
}

install_packages() {
  local packages_debian=(ca-certificates curl wget jq openssl tar iproute2 qrencode)
  local packages_rhel=(ca-certificates curl wget jq openssl tar iproute qrencode)
  local packages_alpine=(ca-certificates curl wget jq openssl tar iproute2 qrencode coreutils)

  if command_exists apt-get; then
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages_debian[@]}"
  elif command_exists dnf; then
    dnf install -y epel-release || true
    dnf install -y "${packages_rhel[@]}"
  elif command_exists yum; then
    yum install -y epel-release || true
    yum install -y "${packages_rhel[@]}"
  elif command_exists apk; then
    apk update
    apk add "${packages_alpine[@]}"
  else
    red "无法识别包管理器，请手动安装 curl wget jq openssl tar iproute2 qrencode"
    exit 1
  fi
}

latest_sing_box_version() {
  local version
  version=$(curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r '.tag_name' | sed 's/^v//') || true
  if [[ -z "$version" || "$version" == "null" ]]; then
    version=$(curl -fsSLI -o /dev/null -w '%{url_effective}' https://github.com/SagerNet/sing-box/releases/latest | sed 's#.*/tag/v##')
  fi
  if [[ -z "$version" ]]; then
    red "无法获取 sing-box 最新版本"
    exit 1
  fi
  printf '%s' "$version"
}

download_sing_box() {
  local version="$1"
  local archive_name="sing-box-${version}-linux-${ARCH}"
  local url="https://github.com/SagerNet/sing-box/releases/download/v${version}/${archive_name}.tar.gz"
  local temp_dir
  temp_dir=$(mktemp -d)

  mkdir -p "$INSTALL_DIR"
  blue "下载 sing-box ${version} ..."
  curl -fsSL "$url" -o "$temp_dir/sing-box.tar.gz"
  tar -xzf "$temp_dir/sing-box.tar.gz" -C "$temp_dir"
  install -m 755 "$temp_dir/${archive_name}/sing-box" "$BIN_PATH"
  rm -rf "$temp_dir"
}

random_port() {
  local protocol="$1"
  local port
  while true; do
    port=$(shuf -i 20000-60000 -n 1)
    if ! list_listening_ports "$protocol" | grep -Eq "(^|:)$port$"; then
      printf '%s' "$port"
      return
    fi
  done
}

list_listening_ports() {
  local protocol="$1"
  if [[ "$protocol" == "tcp" ]]; then
    ss -H -ltn | awk '{print $4}'
  else
    ss -H -lun | awk '{print $4}'
  fi
}

port_in_use() {
  local protocol="$1"
  local port="$2"
  list_listening_ports "$protocol" | grep -Eq "(^|:)$port$"
}

normalize_port() {
  local candidate="$1"
  local protocol="$2"
  if [[ -z "$candidate" ]]; then
    printf '%s' "$(random_port "$protocol")"
    return
  fi
  if [[ ! "$candidate" =~ ^[0-9]+$ ]] || (( candidate < 1 || candidate > 65535 )); then
    red "端口无效: $candidate"
    exit 1
  fi
  if port_in_use "$protocol" "$candidate"; then
    yellow "端口 $candidate/$protocol 已被占用，自动改用随机端口"
    printf '%s' "$(random_port "$protocol")"
    return
  fi
  printf '%s' "$candidate"
}

get_public_ip() {
  local ip4 ip6
  ip4=$(curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)
  if [[ -n "$ip4" ]]; then
    printf '%s' "$ip4"
    return
  fi
  ip6=$(curl -6fsS --max-time 5 https://api64.ipify.org 2>/dev/null || true)
  if [[ -n "$ip6" ]]; then
    printf '%s' "$ip6"
    return
  fi
  red "无法获取 VPS 公网 IP"
  exit 1
}

format_host_for_uri() {
  local host="$1"
  if [[ "$host" == *:* ]]; then
    printf '[%s]' "$host"
  else
    printf '%s' "$host"
  fi
}

generate_self_signed_cert() {
  local server_ip="$1"
  cat > "$OPENSSL_FILE" <<EOF
[req]
default_bits = 2048
prompt = no
default_md = sha256
x509_extensions = v3_req
distinguished_name = dn

[dn]
CN = ${DEFAULT_HY2_SNI}

[v3_req]
subjectAltName = @alt_names
extendedKeyUsage = serverAuth

[alt_names]
DNS.1 = ${DEFAULT_HY2_SNI}
IP.1 = ${server_ip}
EOF

  openssl ecparam -genkey -name prime256v1 -out "$KEY_FILE"
  openssl req -new -x509 -days 3650 -key "$KEY_FILE" -out "$CERT_FILE" -config "$OPENSSL_FILE"
}

generate_reality_keypair() {
  local output
  output=$("$BIN_PATH" generate reality-keypair)
  REALITY_PRIVATE_KEY=$(printf '%s\n' "$output" | awk '/PrivateKey:/ {print $2}')
  REALITY_PUBLIC_KEY=$(printf '%s\n' "$output" | awk '/PublicKey:/ {print $2}')
  if [[ -z "$REALITY_PRIVATE_KEY" || -z "$REALITY_PUBLIC_KEY" ]]; then
    red "REALITY 密钥生成失败"
    exit 1
  fi
}

generate_short_id() {
  REALITY_SHORT_ID=$(openssl rand -hex 4)
}

generate_config() {
  cat > "$CONFIG_FILE" <<EOF
{
  "log": {
    "level": "warn",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "reality-in",
      "listen": "::",
      "listen_port": ${REALITY_PORT},
      "users": [
        {
          "name": "primary",
          "uuid": "${UUID}",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${REALITY_SERVER}",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "${REALITY_SERVER}",
            "server_port": 443
          },
          "private_key": "${REALITY_PRIVATE_KEY}",
          "short_id": [
            "${REALITY_SHORT_ID}"
          ]
        }
      }
    },
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": ${HY2_PORT},
      "up_mbps": ${HY2_UP_MBPS},
      "down_mbps": ${HY2_DOWN_MBPS},
      "users": [
        {
          "name": "primary",
          "password": "${HY2_PASSWORD}"
        }
      ],
      "tls": {
        "enabled": true,
        "alpn": [
          "h3"
        ],
        "certificate_path": "${CERT_FILE}",
        "key_path": "${KEY_FILE}"
      },
      "masquerade": "https://www.bing.com"
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ]
}
EOF
}

write_meta() {
  cat > "$META_FILE" <<EOF
REALITY_PORT=${REALITY_PORT}
REALITY_SERVER=${REALITY_SERVER}
REALITY_PUBLIC_KEY=${REALITY_PUBLIC_KEY}
REALITY_SHORT_ID=${REALITY_SHORT_ID}
UUID=${UUID}
HY2_PORT=${HY2_PORT}
HY2_PASSWORD=${HY2_PASSWORD}
HY2_UP_MBPS=${HY2_UP_MBPS}
HY2_DOWN_MBPS=${HY2_DOWN_MBPS}
HY2_SNI=${DEFAULT_HY2_SNI}
INSTALLED_VERSION=${INSTALLED_VERSION}
EOF
}

install_systemd_service() {
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=${PROJECT_NAME} dual protocol proxy service
Documentation=https://sing-box.sagernet.org/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
ExecStart=${BIN_PATH} run -c ${CONFIG_FILE}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_ADMIN CAP_NET_RAW
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_NET_ADMIN CAP_NET_RAW

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME" >/dev/null
  systemctl restart "$SERVICE_NAME"
}

write_installed_tune_script() {
  mkdir -p "$(dirname "$TUNE_SCRIPT_PATH")"
  if [[ -f "$REPO_TUNE_SCRIPT" ]]; then
    install -m 755 "$REPO_TUNE_SCRIPT" "$TUNE_SCRIPT_PATH"
    return
  fi
  cat > "$TUNE_SCRIPT_PATH" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
SYSCTL_FILE="/etc/sysctl.d/99-aeroflux.conf"
if [[ ${EUID} -ne 0 ]]; then
  echo "please run as root" >&2
  exit 1
fi
cat > "$SYSCTL_FILE" <<CONF
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 26214400
net.core.wmem_max = 26214400
net.core.rmem_default = 8388608
net.core.wmem_default = 8388608
net.core.netdev_max_backlog = 8192
net.ipv4.udp_mem = 65536 131072 262144
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
CONF
modprobe tcp_bbr >/dev/null 2>&1 || true
sysctl --system >/dev/null
sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc net.core.rmem_max net.core.wmem_max
EOF
  chmod 755 "$TUNE_SCRIPT_PATH"
}

install_shortcut() {
  if [[ -f "${BASH_SOURCE[0]}" ]]; then
    install -m 755 "${BASH_SOURCE[0]}" "$SHORTCUT_PATH"
  fi
}

apply_tuning() {
  write_installed_tune_script
  if [[ "${ENABLE_TUNING}" == "y" ]]; then
    blue "应用内核与 UDP 调优..."
    "$TUNE_SCRIPT_PATH"
  fi
}

build_links() {
  if [[ ! -f "$META_FILE" ]]; then
    red "未找到安装信息，请先执行安装"
    exit 1
  fi
  # shellcheck disable=SC1090
  source "$META_FILE"

  local server_ip server_host reality_link hy2_link
  server_ip=$(get_public_ip)
  server_host=$(format_host_for_uri "$server_ip")
  reality_link="vless://${UUID}@${server_host}:${REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SERVER}&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT_ID}&type=tcp&headerType=none#AeroFlux-REALITY"
  hy2_link="hy2://${HY2_PASSWORD}@${server_host}:${HY2_PORT}/?sni=${HY2_SNI}&insecure=1&alpn=h3#AeroFlux-HYSTERIA2"

  cat > "$LINKS_FILE" <<EOF
+--------------------------------------------------+
| ${PROJECT_NAME} share links                      |
+--------------------------------------------------+
REALITY
${reality_link}

Hysteria 2
${hy2_link}

Files
config: ${CONFIG_FILE}
links : ${LINKS_FILE}
meta  : ${META_FILE}
EOF

  green "链接已生成: $LINKS_FILE"
  printf '\n%s\n\n%s\n\n' "$reality_link" "$hy2_link"
  if command_exists qrencode; then
    blue "REALITY 二维码"
    qrencode -t ANSIUTF8 "$reality_link" || true
    blue "Hysteria 2 二维码"
    qrencode -t ANSIUTF8 "$hy2_link" || true
  fi
}

show_status() {
  if systemctl is-active --quiet "$SERVICE_NAME"; then
    green "${PROJECT_NAME} 运行中"
  else
    yellow "${PROJECT_NAME} 未运行"
  fi
  if [[ -f "$META_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$META_FILE"
    printf 'version: %s\n' "$INSTALLED_VERSION"
    printf 'reality tcp port: %s\n' "$REALITY_PORT"
    printf 'hy2 udp port: %s\n' "$HY2_PORT"
  fi
}

install_flow() {
  require_root
  require_systemd
  detect_arch
  install_packages

  mkdir -p "$INSTALL_DIR"

  local default_reality_port default_hy2_port install_choice
  if port_in_use tcp 443; then
    default_reality_port=$(random_port tcp)
  else
    default_reality_port=443
  fi
  if port_in_use udp 443; then
    default_hy2_port=$(random_port udp)
  else
    default_hy2_port=443
  fi

  yellow "推荐 Ubuntu 22.04/24.04，开放 TCP/UDP 对应端口"
  install_choice=$(prompt "是否继续安装？输入 y 继续" "y")
  if [[ ! "$install_choice" =~ ^[Yy]$ ]]; then
    exit 0
  fi

  REALITY_SERVER=$(prompt "REALITY 伪装站点" "$DEFAULT_REALITY_SERVER")
  REALITY_PORT=$(normalize_port "$(prompt "REALITY TCP 端口" "$default_reality_port")" tcp)
  HY2_PORT=$(normalize_port "$(prompt "Hysteria 2 UDP 端口" "$default_hy2_port")" udp)
  HY2_UP_MBPS=$(prompt "Hysteria 2 上行限速 Mbps" "1000")
  HY2_DOWN_MBPS=$(prompt "Hysteria 2 下行限速 Mbps" "1000")
  ENABLE_TUNING=$(prompt "是否应用 BBR 和 UDP 调优？y/n" "y")

  if [[ ! "$HY2_UP_MBPS" =~ ^[0-9]+$ || ! "$HY2_DOWN_MBPS" =~ ^[0-9]+$ ]]; then
    red "Hysteria 2 带宽参数必须是整数"
    exit 1
  fi

  INSTALLED_VERSION=$(latest_sing_box_version)
  download_sing_box "$INSTALLED_VERSION"

  UUID=$(cat /proc/sys/kernel/random/uuid)
  HY2_PASSWORD="$UUID"
  SERVER_IP=$(get_public_ip)
  generate_self_signed_cert "$SERVER_IP"
  generate_reality_keypair
  generate_short_id
  generate_config
  write_meta
  install_systemd_service
  install_shortcut
  apply_tuning
  build_links

  green "安装完成"
  blue "v2rayN 直接导入上面的两个链接即可"
  blue "REALITY 更适合长期保底，Hysteria 2 更适合测速和大流量"
}

update_core() {
  require_root
  require_systemd
  detect_arch
  install_packages
  INSTALLED_VERSION=$(latest_sing_box_version)
  download_sing_box "$INSTALLED_VERSION"
  if [[ -f "$META_FILE" ]]; then
    awk -F= -v version="$INSTALLED_VERSION" 'BEGIN { updated = 0 } $1 == "INSTALLED_VERSION" { print "INSTALLED_VERSION=" version; updated = 1; next } { print } END { if (!updated) print "INSTALLED_VERSION=" version }' "$META_FILE" > "$META_FILE.tmp"
    mv "$META_FILE.tmp" "$META_FILE"
  fi
  systemctl restart "$SERVICE_NAME"
  green "sing-box 已更新到 ${INSTALLED_VERSION}"
}

uninstall_all() {
  require_root
  if ! [[ "$(prompt "确定卸载 ${PROJECT_NAME} 与配置？y/n" "n")" =~ ^[Yy]$ ]]; then
    exit 0
  fi
  systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
  rm -f "$SERVICE_FILE" "$BIN_PATH" "$SHORTCUT_PATH"
  rm -rf "$INSTALL_DIR" "/usr/local/lib/${SERVICE_NAME}" "/etc/sysctl.d/99-aeroflux.conf"
  systemctl daemon-reload
  sysctl --system >/dev/null 2>&1 || true
  green "卸载完成"
}

menu() {
  echo
  blue "${PROJECT_NAME} | Hysteria 2 + REALITY"
  echo "1. 安装或重装"
  echo "2. 查看分享链接"
  echo "3. 更新 sing-box 内核"
  echo "4. 查看运行状态"
  echo "5. 卸载"
  echo "0. 退出"
  case "$(prompt "请选择" "1")" in
    1) install_flow ;;
    2) build_links ;;
    3) update_core ;;
    4) show_status ;;
    5) uninstall_all ;;
    0) exit 0 ;;
    *) red "无效选择"; exit 1 ;;
  esac
}

case "${1-}" in
  install) install_flow ;;
  links|show-links) build_links ;;
  update) update_core ;;
  uninstall) uninstall_all ;;
  status) show_status ;;
  *) menu ;;
esac
