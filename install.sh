#!/usr/bin/env bash
set -euo pipefail

readonly AFX_NAME="AeroFlux"
readonly AFX_SERVICE="aeroflux"
readonly AFX_ACCOUNT="aeroflux"
readonly AFX_HOME="/etc/aeroflux"
readonly AFX_STATE="/var/lib/aeroflux"
readonly AFX_RUNTIME="/run/aeroflux"
readonly AFX_LIB="/usr/local/lib/aeroflux"
readonly AFX_CORE_DIR="$AFX_LIB/core"
readonly AFX_BINARY="$AFX_CORE_DIR/sing-box"
readonly AFX_MANAGER="$AFX_LIB/manager.sh"
readonly AFX_WRAPPER="/usr/local/bin/afx"
readonly AFX_TUNE_SCRIPT="$AFX_LIB/system-tune.sh"
readonly AFX_SERVICE_FILE="/etc/systemd/system/${AFX_SERVICE}.service"
readonly AFX_CONFIG_FILE="$AFX_HOME/node.json"
readonly AFX_ENV_FILE="$AFX_HOME/runtime.env"
readonly AFX_LINK_FILE="$AFX_HOME/share-links.txt"
readonly AFX_HY2_CLIENT_HINT_FILE="$AFX_HOME/hy2-v2rayn-manual.txt"
readonly AFX_HY2_CLIENT_JSON_FILE="$AFX_HOME/hy2-client-singbox.json"
readonly AFX_HY2_NATIVE_FILE="$AFX_HOME/hy2-client-hysteria.yaml"
readonly AFX_CERT_FILE="$AFX_HOME/tls.crt"
readonly AFX_KEY_FILE="$AFX_HOME/tls.key"
readonly AFX_OPENSSL_FILE="$AFX_STATE/openssl.cnf"
readonly AFX_PERF_SYSCTL="/etc/sysctl.d/90-aeroflux-performance.conf"
readonly AFX_DEFAULT_REALITY_SERVER="www.cloudflare.com"
readonly AFX_DEFAULT_HY2_SNI="www.bing.com"
readonly AFX_DEFAULT_HY2_MODE="bbr"
readonly AFX_DEFAULT_PERF_PROFILE="extreme"
readonly AFX_DEFAULT_HY2_SERVER_UP="1000"
readonly AFX_DEFAULT_HY2_SERVER_DOWN="1000"
readonly AFX_DEFAULT_HY2_CLIENT_UP="1000"
readonly AFX_DEFAULT_HY2_CLIENT_DOWN="1000"

AFX_ARCH=""
AFX_RELEASE_JSON=""
AFX_HY2_MODE=""
AFX_PERF_PROFILE=""
AFX_HY2_CLIENT_UP=""
AFX_HY2_CLIENT_DOWN=""

paint() {
  local color="$1"
  shift
  printf '\033[%sm%s\033[0m\n' "$color" "$*"
}

note() { paint '36;1' "$*"; }
good() { paint '32;1' "$*"; }
warn() { paint '33;1' "$*"; }
fail() { paint '31;1' "$*" >&2; }

die() {
  fail "$*"
  exit 1
}

has() {
  command -v "$1" >/dev/null 2>&1
}

prompt_value() {
  local label="$1"
  local fallback="${2-}"
  local reply
  if [[ -n "$fallback" ]]; then
    read -r -p "$label [$fallback]: " reply
    printf '%s' "${reply:-$fallback}"
  else
    read -r -p "$label: " reply
    printf '%s' "$reply"
  fi
}

normalize_hy2_mode() {
  local raw="${1,,}"
  case "$raw" in
    ""|1|bbr|compat|compatible)
      printf 'bbr'
      ;;
    2|brutal|fixed|bandwidth)
      printf 'brutal'
      ;;
    *)
      die "Hysteria 2 模式只支持 1/bbr 或 2/brutal"
      ;;
  esac
}

normalize_perf_profile() {
  local raw="${1,,}"
  case "$raw" in
    ""|1|extreme|turbo|fast|performance)
      printf 'extreme'
      ;;
    2|balanced|compat|safe)
      printf 'balanced'
      ;;
    *)
      die "性能模式只支持 1/extreme 或 2/balanced"
      ;;
  esac
}

json_number_or_null() {
  local value="${1-}"
  if [[ -n "$value" ]]; then
    printf '%s' "$value"
  else
    printf 'null'
  fi
}

require_root() {
  [[ ${EUID} -eq 0 ]] || die "请使用 root 执行 ${AFX_NAME} 安装器"
}

require_systemd() {
  has systemctl || die "当前系统未检测到 systemd，${AFX_NAME} 只支持 systemd 场景"
}

detect_architecture() {
  case "$(uname -m)" in
    x86_64) AFX_ARCH="amd64" ;;
    aarch64|arm64) AFX_ARCH="arm64" ;;
    armv7l) AFX_ARCH="armv7" ;;
    *) die "暂不支持的架构: $(uname -m)" ;;
  esac
}

install_dependencies() {
  local debian_packages=(ca-certificates curl jq openssl tar iproute2 coreutils)
  local redhat_packages=(ca-certificates curl jq openssl tar iproute coreutils)
  local alpine_packages=(ca-certificates curl jq openssl tar iproute2 coreutils)

  if has apt-get; then
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${debian_packages[@]}"
    return
  fi

  if has dnf; then
    dnf install -y epel-release >/dev/null 2>&1 || true
    dnf install -y "${redhat_packages[@]}"
    return
  fi

  if has yum; then
    yum install -y epel-release >/dev/null 2>&1 || true
    yum install -y "${redhat_packages[@]}"
    return
  fi

  if has apk; then
    apk update
    apk add "${alpine_packages[@]}"
    return
  fi

  die "无法识别包管理器，请手动安装 curl jq openssl tar iproute2 coreutils"
}

load_release_catalog() {
  if [[ -z "$AFX_RELEASE_JSON" ]]; then
    AFX_RELEASE_JSON=$(curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases/latest)
  fi
}

latest_core_version() {
  load_release_catalog
  jq -r '.tag_name' <<<"$AFX_RELEASE_JSON" | sed 's/^v//'
}

release_asset_url() {
  local asset_name="$1"
  load_release_catalog
  jq -r --arg asset_name "$asset_name" '.assets[] | select(.name == $asset_name) | .browser_download_url' <<<"$AFX_RELEASE_JSON" | head -n 1
}

download_core_binary() {
  local version="$1"
  local archive_name="sing-box-${version}-linux-${AFX_ARCH}.tar.gz"
  local archive_url checksum_url workdir expected_checksum
  workdir=$(mktemp -d)
  archive_url=$(release_asset_url "$archive_name")
  checksum_url=$(release_asset_url "${archive_name}.sha256sum")

  [[ -n "$archive_url" ]] || die "无法在 release 资产中找到 ${archive_name}"

  note "拉取 sing-box ${version} (${AFX_ARCH})"
  curl -fsSL "$archive_url" -o "$workdir/core.tar.gz"

  if [[ -n "$checksum_url" ]]; then
    curl -fsSL "$checksum_url" -o "$workdir/core.tar.gz.sha256sum"
    expected_checksum=$(awk '{print $1}' "$workdir/core.tar.gz.sha256sum")
    printf '%s  %s\n' "$expected_checksum" "$workdir/core.tar.gz" | sha256sum -c - >/dev/null
  else
    warn "未找到官方 sha256 校验文件，跳过校验"
  fi

  rm -rf "$AFX_CORE_DIR"
  mkdir -p "$AFX_CORE_DIR"
  tar -xzf "$workdir/core.tar.gz" -C "$workdir"
  install -m 755 "$workdir/sing-box-${version}-linux-${AFX_ARCH}/sing-box" "$AFX_BINARY"
  chmod 755 "$AFX_CORE_DIR"
  rm -rf "$workdir"
}

list_ports() {
  local proto="$1"
  if [[ "$proto" == "tcp" ]]; then
    ss -H -ltn | awk '{print $4}'
  else
    ss -H -lun | awk '{print $4}'
  fi
}

port_busy() {
  local proto="$1"
  local port="$2"
  list_ports "$proto" | grep -Eq "(^|:)$port$"
}

random_port() {
  local proto="$1"
  local candidate
  while true; do
    candidate=$(shuf -i 20000-60999 -n 1)
    if ! port_busy "$proto" "$candidate"; then
      printf '%s' "$candidate"
      return
    fi
  done
}

preferred_port() {
  local proto="$1"
  if port_busy "$proto" 443; then
    random_port "$proto"
  else
    printf '443'
  fi
}

normalize_port() {
  local candidate="$1"
  local proto="$2"
  if [[ -z "$candidate" ]]; then
    random_port "$proto"
    return
  fi
  [[ "$candidate" =~ ^[0-9]+$ ]] || die "端口必须是数字: $candidate"
  (( candidate >= 1 && candidate <= 65535 )) || die "端口超出范围: $candidate"
  if port_busy "$proto" "$candidate"; then
    warn "端口 $candidate/$proto 已占用，自动改用随机端口"
    random_port "$proto"
    return
  fi
  printf '%s' "$candidate"
}

configure_firewall_rules() {
  if has iptables; then
    while iptables -t raw -C PREROUTING -p udp --dport "${AFX_HY2_PORT}" -j NOTRACK 2>/dev/null; do
      iptables -t raw -D PREROUTING -p udp --dport "${AFX_HY2_PORT}" -j NOTRACK
    done
    while iptables -t raw -C OUTPUT -p udp --sport "${AFX_HY2_PORT}" -j NOTRACK 2>/dev/null; do
      iptables -t raw -D OUTPUT -p udp --sport "${AFX_HY2_PORT}" -j NOTRACK
    done
  fi
  if has ip6tables; then
    while ip6tables -t raw -C PREROUTING -p udp --dport "${AFX_HY2_PORT}" -j NOTRACK 2>/dev/null; do
      ip6tables -t raw -D PREROUTING -p udp --dport "${AFX_HY2_PORT}" -j NOTRACK
    done
    while ip6tables -t raw -C OUTPUT -p udp --sport "${AFX_HY2_PORT}" -j NOTRACK 2>/dev/null; do
      ip6tables -t raw -D OUTPUT -p udp --sport "${AFX_HY2_PORT}" -j NOTRACK
    done
  fi
  if [[ "${AFX_PERF_PROFILE:-$AFX_DEFAULT_PERF_PROFILE}" == "extreme" ]]; then
    note "极致性能模式：关闭主机防火墙并清空本机过滤规则"
    if has ufw; then
      ufw --force disable >/dev/null 2>&1 || true
    fi
    if has systemctl; then
      systemctl stop firewalld.service >/dev/null 2>&1 || true
      systemctl disable firewalld.service >/dev/null 2>&1 || true
    fi
    if has setenforce; then
      setenforce 0 >/dev/null 2>&1 || true
    fi
    if has iptables; then
      iptables -P INPUT ACCEPT >/dev/null 2>&1 || true
      iptables -P FORWARD ACCEPT >/dev/null 2>&1 || true
      iptables -P OUTPUT ACCEPT >/dev/null 2>&1 || true
      iptables -t mangle -F >/dev/null 2>&1 || true
      iptables -F >/dev/null 2>&1 || true
      iptables -X >/dev/null 2>&1 || true
    fi
    if has ip6tables; then
      ip6tables -P INPUT ACCEPT >/dev/null 2>&1 || true
      ip6tables -P FORWARD ACCEPT >/dev/null 2>&1 || true
      ip6tables -P OUTPUT ACCEPT >/dev/null 2>&1 || true
      ip6tables -t mangle -F >/dev/null 2>&1 || true
      ip6tables -F >/dev/null 2>&1 || true
      ip6tables -X >/dev/null 2>&1 || true
    fi
    if has iptables; then
      iptables -t raw -A PREROUTING -p udp --dport "${AFX_HY2_PORT}" -j NOTRACK >/dev/null 2>&1 || true
      iptables -t raw -A OUTPUT -p udp --sport "${AFX_HY2_PORT}" -j NOTRACK >/dev/null 2>&1 || true
    fi
    if has ip6tables; then
      ip6tables -t raw -A PREROUTING -p udp --dport "${AFX_HY2_PORT}" -j NOTRACK >/dev/null 2>&1 || true
      ip6tables -t raw -A OUTPUT -p udp --sport "${AFX_HY2_PORT}" -j NOTRACK >/dev/null 2>&1 || true
    fi
    if has netfilter-persistent; then
      netfilter-persistent save >/dev/null 2>&1 || true
    fi
    return
  fi
  if has ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then
    note "检测到 UFW 已启用，正在放行 AeroFlux 所需端口"
    ufw allow "${AFX_REALITY_PORT}/tcp" >/dev/null
    ufw allow "${AFX_HY2_PORT}/udp" >/dev/null
  fi
}

public_host() {
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
  die "无法获取公网 IP"
}

uri_host() {
  local host="$1"
  if [[ "$host" == *:* ]]; then
    printf '[%s]' "$host"
  else
    printf '%s' "$host"
  fi
}

service_shell() {
  if [[ -x /usr/sbin/nologin ]]; then
    printf '/usr/sbin/nologin'
  elif [[ -x /sbin/nologin ]]; then
    printf '/sbin/nologin'
  else
    printf '/bin/false'
  fi
}

ensure_layout() {
  mkdir -p "$AFX_HOME" "$AFX_STATE" "$AFX_LIB"
  chmod 750 "$AFX_HOME"
  chmod 755 "$AFX_STATE" "$AFX_LIB"
}

ensure_service_account() {
  if ! id -u "$AFX_ACCOUNT" >/dev/null 2>&1; then
    useradd --system --home-dir "$AFX_STATE" --shell "$(service_shell)" "$AFX_ACCOUNT"
  fi
}

sanitize_label() {
  local raw="$1"
  raw=${raw// /-}
  raw=${raw//[^a-zA-Z0-9._-]/-}
  printf '%s' "$raw"
}

generate_tls_material() {
  local endpoint="$1"
  cat > "$AFX_OPENSSL_FILE" <<EOF
[req]
prompt = no
distinguished_name = dn
x509_extensions = ext

[dn]
CN = ${AFX_DEFAULT_HY2_SNI}

[ext]
subjectAltName = @san
extendedKeyUsage = serverAuth

[san]
DNS.1 = ${AFX_DEFAULT_HY2_SNI}
IP.1 = ${endpoint}
EOF

  openssl ecparam -genkey -name prime256v1 -out "$AFX_KEY_FILE"
  openssl req -new -x509 -days 3650 -key "$AFX_KEY_FILE" -out "$AFX_CERT_FILE" -config "$AFX_OPENSSL_FILE"
}

generate_reality_keys() {
  local output
  output=$("$AFX_BINARY" generate reality-keypair)
  AFX_REALITY_PRIVATE=$(awk '/PrivateKey:/ {print $2}' <<<"$output")
  AFX_REALITY_PUBLIC=$(awk '/PublicKey:/ {print $2}' <<<"$output")
  AFX_REALITY_SHORT_ID=$(openssl rand -hex 4)
  [[ -n "$AFX_REALITY_PRIVATE" && -n "$AFX_REALITY_PUBLIC" ]] || die "REALITY 密钥生成失败"
}

write_runtime_env() {
  cat > "$AFX_ENV_FILE" <<EOF
AFX_CORE_VERSION=${AFX_CORE_VERSION}
AFX_NODE_LABEL=${AFX_NODE_LABEL}
AFX_NODE_ID=${AFX_NODE_ID}
AFX_REALITY_SERVER=${AFX_REALITY_SERVER}
AFX_REALITY_PORT=${AFX_REALITY_PORT}
AFX_REALITY_PUBLIC=${AFX_REALITY_PUBLIC}
AFX_REALITY_PRIVATE=${AFX_REALITY_PRIVATE}
AFX_REALITY_SHORT_ID=${AFX_REALITY_SHORT_ID}
AFX_HY2_PORT=${AFX_HY2_PORT}
AFX_HY2_SECRET=${AFX_HY2_SECRET}
AFX_HY2_MODE=${AFX_HY2_MODE}
AFX_PERF_PROFILE=${AFX_PERF_PROFILE}
AFX_HY2_UP=${AFX_HY2_UP}
AFX_HY2_DOWN=${AFX_HY2_DOWN}
AFX_HY2_CLIENT_UP=${AFX_HY2_CLIENT_UP}
AFX_HY2_CLIENT_DOWN=${AFX_HY2_CLIENT_DOWN}
AFX_HY2_SNI=${AFX_DEFAULT_HY2_SNI}
AFX_ENDPOINT=${AFX_ENDPOINT}
EOF
}

lock_permissions() {
  chown -R root:"$AFX_ACCOUNT" "$AFX_HOME"
  chown -R root:root "$AFX_LIB"
  chown -R "$AFX_ACCOUNT":"$AFX_ACCOUNT" "$AFX_STATE"
  chmod 750 "$AFX_HOME"
  chmod 755 "$AFX_LIB" "$AFX_CORE_DIR" "$AFX_STATE"
  chmod 640 "$AFX_CONFIG_FILE" "$AFX_ENV_FILE" "$AFX_CERT_FILE" "$AFX_KEY_FILE"
  chmod 640 "$AFX_LINK_FILE" 2>/dev/null || true
}

render_config() {
  jq -n \
    --arg node_id "$AFX_NODE_ID" \
    --arg reality_server "$AFX_REALITY_SERVER" \
    --arg reality_private "$AFX_REALITY_PRIVATE" \
    --arg reality_short_id "$AFX_REALITY_SHORT_ID" \
    --arg hy2_secret "$AFX_HY2_SECRET" \
    --arg hy2_mode "$AFX_HY2_MODE" \
    --arg cert_file "$AFX_CERT_FILE" \
    --arg key_file "$AFX_KEY_FILE" \
    --argjson reality_port "$AFX_REALITY_PORT" \
    --argjson hy2_port "$AFX_HY2_PORT" \
    --argjson hy2_up "$(json_number_or_null "$AFX_HY2_UP")" \
    --argjson hy2_down "$(json_number_or_null "$AFX_HY2_DOWN")" \
    '{
      log: {
        level: "warn",
        timestamp: true
      },
      inbounds: [
        {
          type: "vless",
          tag: "edge-reality",
          listen: "::",
          listen_port: $reality_port,
          users: [
            {
              name: "primary",
              uuid: $node_id,
              flow: "xtls-rprx-vision"
            }
          ],
          tls: {
            enabled: true,
            server_name: $reality_server,
            reality: {
              enabled: true,
              handshake: {
                server: $reality_server,
                server_port: 443
              },
              private_key: $reality_private,
              short_id: [$reality_short_id]
            }
          }
        },
        (
          {
            type: "hysteria2",
            tag: "edge-hy2",
            listen: "::",
            listen_port: $hy2_port,
            ignore_client_bandwidth: false,
            users: [
              {
                password: $hy2_secret
              }
            ],
            tls: {
              enabled: true,
              alpn: ["h3"],
              certificate_path: $cert_file,
              key_path: $key_file
            }
          }
          + if $hy2_mode == "brutal" then {
              up_mbps: $hy2_up,
              down_mbps: $hy2_down
            } else {} end
        )
      ],
      outbounds: [
        {
          type: "direct",
          tag: "direct"
        },
        {
          type: "block",
          tag: "block"
        }
      ]
    }' > "$AFX_CONFIG_FILE"

  "$AFX_BINARY" check -c "$AFX_CONFIG_FILE" >/dev/null
}

install_manager_plane() {
  mkdir -p "$AFX_LIB"
  if [[ -r "${BASH_SOURCE[0]}" ]]; then
    install -m 755 "${BASH_SOURCE[0]}" "$AFX_MANAGER"
  fi

  cat > "$AFX_WRAPPER" <<EOF
#!/usr/bin/env bash
exec bash "$AFX_MANAGER" "\$@"
EOF
  chmod 755 "$AFX_WRAPPER"
}

install_tune_plane() {
  local repo_tune
  repo_tune="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts/system-tune.sh"
  if [[ -f "$repo_tune" ]]; then
    install -m 755 "$repo_tune" "$AFX_TUNE_SCRIPT"
    return
  fi

  cat > "$AFX_TUNE_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

readonly AFX_SYSCTL_FILE="/etc/sysctl.d/90-aeroflux-performance.conf"

die() {
  printf '\033[31;1m%s\033[0m\n' "$*" >&2
  exit 1
}

note() {
  printf '\033[36;1m%s\033[0m\n' "$*"
}

require_root() {
  [[ ${EUID} -eq 0 ]] || die "请使用 root 运行性能调优脚本"
}

write_profile() {
  cat > "$AFX_SYSCTL_FILE" <<'CONF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 262144
net.core.optmem_max = 25165824
net.core.rmem_default = 16777216
net.core.wmem_default = 16777216
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.udp_rmem_min = 32768
net.ipv4.udp_wmem_min = 32768
net.ipv4.udp_mem = 262144 524288 1048576
CONF
}

apply_profile() {
  require_root
  write_profile
  modprobe tcp_bbr >/dev/null 2>&1 || true
  sysctl --system >/dev/null
  note "AeroFlux performance profile 已应用"
  show_status
}

show_status() {
  require_root
  if [[ -f "$AFX_SYSCTL_FILE" ]]; then
    note "当前性能档案: $AFX_SYSCTL_FILE"
  else
    note "当前未应用 AeroFlux 专用性能档案"
  fi
  sysctl net.ipv4.tcp_congestion_control
  sysctl net.core.default_qdisc
  sysctl net.core.rmem_max
  sysctl net.core.wmem_max
  sysctl net.core.netdev_max_backlog
  sysctl net.ipv4.udp_mem
}

remove_profile() {
  require_root
  rm -f "$AFX_SYSCTL_FILE"
  sysctl --system >/dev/null 2>&1 || true
  note "AeroFlux performance profile 已移除"
}

case "${1-apply}" in
  apply) apply_profile ;;
  status|inspect) show_status ;;
  remove|reset) remove_profile ;;
  *) die "可用参数: apply | status | remove" ;;
esac
EOF
  chmod 755 "$AFX_TUNE_SCRIPT"
}

install_service_unit() {
  if [[ "${AFX_PERF_PROFILE:-$AFX_DEFAULT_PERF_PROFILE}" == "extreme" ]]; then
    cat > "$AFX_SERVICE_FILE" <<EOF
[Unit]
Description=${AFX_NAME} edge runtime
Documentation=https://github.com/LuKasCuiRongfeng/AeroFlux
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${AFX_STATE}
RuntimeDirectory=${AFX_SERVICE}
ExecStartPre=${AFX_BINARY} check -c ${AFX_CONFIG_FILE}
ExecStart=${AFX_BINARY} run -c ${AFX_CONFIG_FILE}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=2
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
LimitNOFILE=infinity
LimitNPROC=infinity
TasksMax=infinity

[Install]
WantedBy=multi-user.target
EOF
  else
    cat > "$AFX_SERVICE_FILE" <<EOF
[Unit]
Description=${AFX_NAME} edge runtime
Documentation=https://github.com/LuKasCuiRongfeng/AeroFlux
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${AFX_ACCOUNT}
Group=${AFX_ACCOUNT}
WorkingDirectory=${AFX_STATE}
RuntimeDirectory=${AFX_SERVICE}
ExecStartPre=${AFX_BINARY} check -c ${AFX_CONFIG_FILE}
ExecStart=${AFX_BINARY} run -c ${AFX_CONFIG_FILE}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=2
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectControlGroups=true
ProtectKernelModules=true
ProtectKernelTunables=true
LockPersonality=true
MemoryDenyWriteExecute=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
RestrictRealtime=true
SystemCallArchitectures=native
ReadWritePaths=${AFX_HOME} ${AFX_STATE} ${AFX_RUNTIME}

[Install]
WantedBy=multi-user.target
EOF
  fi

  systemctl daemon-reload
  systemctl enable "$AFX_SERVICE" >/dev/null
  systemctl restart "$AFX_SERVICE"
}

load_runtime_env() {
  [[ -f "$AFX_ENV_FILE" ]] || die "未发现 ${AFX_NAME} 运行信息，请先安装"
  # shellcheck disable=SC1090
  source "$AFX_ENV_FILE"
  AFX_PERF_PROFILE="${AFX_PERF_PROFILE:-$AFX_DEFAULT_PERF_PROFILE}"
  if [[ -z "${AFX_HY2_MODE:-}" ]]; then
    if [[ -n "${AFX_HY2_UP:-}" || -n "${AFX_HY2_DOWN:-}" || -n "${AFX_HY2_CLIENT_UP:-}" || -n "${AFX_HY2_CLIENT_DOWN:-}" ]]; then
      AFX_HY2_MODE="brutal"
    else
      AFX_HY2_MODE="bbr"
    fi
  fi
}

render_links() {
  load_runtime_env

  local endpoint formatted_host reality_uri hy2_uri hy2_query label
  endpoint=$(public_host)
  formatted_host=$(uri_host "$endpoint")
  label=$(sanitize_label "$AFX_NODE_LABEL")

  reality_uri="vless://${AFX_NODE_ID}@${formatted_host}:${AFX_REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${AFX_REALITY_SERVER}&fp=chrome&pbk=${AFX_REALITY_PUBLIC}&sid=${AFX_REALITY_SHORT_ID}&type=tcp&headerType=none#${label}-reality"
  hy2_query="security=tls&alpn=h3&insecure=1&allowInsecure=1&sni=${AFX_HY2_SNI}"
  if [[ "$AFX_HY2_MODE" == "brutal" ]]; then
    hy2_query+="&upmbps=${AFX_HY2_CLIENT_UP}&downmbps=${AFX_HY2_CLIENT_DOWN}"
  fi
  hy2_uri="hysteria2://${AFX_HY2_SECRET}@${formatted_host}:${AFX_HY2_PORT}/?${hy2_query}#${label}-hy2"

  cat > "$AFX_LINK_FILE" <<EOF
${AFX_NAME} Share Links
=====================
Node Label : ${AFX_NODE_LABEL}
Endpoint   : ${endpoint}
Core       : ${AFX_CORE_VERSION}

REALITY
${reality_uri}

Hysteria 2
${hy2_uri}
EOF

  cat > "$AFX_HY2_CLIENT_HINT_FILE" <<EOF
v2rayN Hysteria2 Manual Fields
==============================
Address           : ${endpoint}
Port              : ${AFX_HY2_PORT}
Password          : ${AFX_HY2_SECRET}
TLS               : tls
SNI               : ${AFX_HY2_SNI}
ALPN              : h3
AllowInsecure     : true
Mode              : ${AFX_HY2_MODE}
Up Mbps           : ${AFX_HY2_CLIENT_UP:-留空}
Down Mbps         : ${AFX_HY2_CLIENT_DOWN:-留空}

Note:
- 当前模式为 ${AFX_HY2_MODE}。
- 如果是 bbr 模式，请把 v2rayN 的 Hysteria 最大流量（Up/Dw）留空，不要手填。
- 如果是 brutal 模式，请把 v2rayN 的 Hysteria 最大流量（Up/Dw）按这里手动填写。
- 某些 v2rayN 版本导入 hy2:// 链接时不会自动写入 Up/Down Mbps。
- v2rayN 默认的 Hysteria 2 核心类型可能仍是 Xray，建议切到 sing-box 或 hysteria2 原生核心再测速。
EOF

  cat > "$AFX_HY2_CLIENT_JSON_FILE" <<EOF
{
  "outbounds": [
    {
      "type": "hysteria2",
      "tag": "${label}-hy2",
      "server": "${endpoint}",
      "server_port": ${AFX_HY2_PORT},
      "password": "${AFX_HY2_SECRET}",
      "tls": {
        "enabled": true,
        "server_name": "${AFX_HY2_SNI}",
        "insecure": true,
        "alpn": ["h3"]
      }
    }
  ]
}
EOF

  if [[ "$AFX_HY2_MODE" == "brutal" ]]; then
    jq '.outbounds[0] += {up_mbps: '"$AFX_HY2_CLIENT_UP"', down_mbps: '"$AFX_HY2_CLIENT_DOWN"'}' "$AFX_HY2_CLIENT_JSON_FILE" > "${AFX_HY2_CLIENT_JSON_FILE}.tmp"
    mv "${AFX_HY2_CLIENT_JSON_FILE}.tmp" "$AFX_HY2_CLIENT_JSON_FILE"
  fi

  cat > "$AFX_HY2_NATIVE_FILE" <<EOF
server: ${endpoint}:${AFX_HY2_PORT}
auth: ${AFX_HY2_SECRET}
tls:
  sni: ${AFX_HY2_SNI}
  insecure: true
transport:
  type: udp
quic:
  initStreamReceiveWindow: 26843545
  maxStreamReceiveWindow: 26843545
  initConnReceiveWindow: 67108864
  maxConnReceiveWindow: 67108864
fastOpen: true
socks5:
  listen: 127.0.0.1:1080
EOF

  if [[ "$AFX_HY2_MODE" == "brutal" ]]; then
    cat >> "$AFX_HY2_NATIVE_FILE" <<EOF
bandwidth:
  up: ${AFX_HY2_CLIENT_UP} mbps
  down: ${AFX_HY2_CLIENT_DOWN} mbps
EOF
  fi

  chown root:"$AFX_ACCOUNT" "$AFX_LINK_FILE" "$AFX_HY2_CLIENT_HINT_FILE" "$AFX_HY2_CLIENT_JSON_FILE" "$AFX_HY2_NATIVE_FILE"
  chmod 640 "$AFX_LINK_FILE" "$AFX_HY2_CLIENT_HINT_FILE" "$AFX_HY2_CLIENT_JSON_FILE" "$AFX_HY2_NATIVE_FILE"

  good "已生成订阅链接: ${AFX_LINK_FILE}"
  note "已生成 Hysteria 2 手工参数: ${AFX_HY2_CLIENT_HINT_FILE}"
  note "已生成 Hysteria 2 sing-box 客户端 JSON: ${AFX_HY2_CLIENT_JSON_FILE}"
  note "已生成 Hysteria 2 原生客户端 YAML: ${AFX_HY2_NATIVE_FILE}"
  warn "测速前请确认 v2rayN 的 Hysteria 2 核心类型不是默认 Xray，优先改为 sing-box 或 hysteria2 原生核心"
  printf '\n%s\n\n%s\n\n' "$reality_uri" "$hy2_uri"
}

status_report() {
  load_runtime_env
  if systemctl is-active --quiet "$AFX_SERVICE"; then
    good "${AFX_NAME} 正在运行"
  else
    warn "${AFX_NAME} 当前未运行"
  fi

  printf 'node label       : %s\n' "$AFX_NODE_LABEL"
  printf 'core version     : %s\n' "$AFX_CORE_VERSION"
  printf 'reality endpoint : %s:%s\n' "$(public_host)" "$AFX_REALITY_PORT"
  printf 'hy2 endpoint     : %s:%s/udp\n' "$(public_host)" "$AFX_HY2_PORT"
  printf 'hy2 mode         : %s\n' "$AFX_HY2_MODE"
  if [[ "$AFX_HY2_MODE" == "brutal" ]]; then
    printf 'hy2 server rate  : %s/%s Mbps\n' "$AFX_HY2_UP" "$AFX_HY2_DOWN"
    printf 'hy2 client rate  : %s/%s Mbps\n' "$AFX_HY2_CLIENT_UP" "$AFX_HY2_CLIENT_DOWN"
  else
    printf 'hy2 server rate  : auto (BBR mode)\n'
    printf 'hy2 client rate  : auto (BBR mode)\n'
  fi
  if [[ "$AFX_PERF_PROFILE" == "extreme" ]]; then
    printf 'service user     : root (extreme)\n'
  else
    printf 'service user     : %s\n' "$AFX_ACCOUNT"
  fi
  printf 'perf profile     : %s\n' "$AFX_PERF_PROFILE"
  printf 'config file      : %s\n' "$AFX_CONFIG_FILE"
}

apply_performance_profile() {
  install_tune_plane
  "$AFX_TUNE_SCRIPT" apply
}

refresh_core() {
  require_root
  require_systemd
  detect_architecture
  install_dependencies
  ensure_layout

  AFX_CORE_VERSION=$(latest_core_version)
  download_core_binary "$AFX_CORE_VERSION"

  if [[ -f "$AFX_ENV_FILE" ]]; then
    awk -F= -v version="$AFX_CORE_VERSION" 'BEGIN { done = 0 } $1 == "AFX_CORE_VERSION" { print "AFX_CORE_VERSION=" version; done = 1; next } { print } END { if (!done) print "AFX_CORE_VERSION=" version }' "$AFX_ENV_FILE" > "$AFX_ENV_FILE.tmp"
    mv "$AFX_ENV_FILE.tmp" "$AFX_ENV_FILE"
  fi

  systemctl restart "$AFX_SERVICE"
  good "核心已刷新到 ${AFX_CORE_VERSION}"
}

remove_aeroflux() {
  require_root
  local answer
  answer=$(prompt_value "确认卸载 ${AFX_NAME} 以及全部配置？输入 y 继续" "n")
  [[ "$answer" =~ ^[Yy]$ ]] || exit 0

  systemctl disable --now "$AFX_SERVICE" >/dev/null 2>&1 || true
  rm -f "$AFX_SERVICE_FILE" "$AFX_WRAPPER"
  rm -rf "$AFX_HOME" "$AFX_STATE" "$AFX_RUNTIME" "$AFX_LIB"
  rm -f "$AFX_PERF_SYSCTL"
  systemctl daemon-reload
  sysctl --system >/dev/null 2>&1 || true
  if id -u "$AFX_ACCOUNT" >/dev/null 2>&1; then
    userdel "$AFX_ACCOUNT" >/dev/null 2>&1 || true
  fi
  good "${AFX_NAME} 已卸载完成"
}

install_fresh() {
  require_root
  require_systemd
  systemctl stop "$AFX_SERVICE" >/dev/null 2>&1 || true
  detect_architecture
  install_dependencies
  ensure_layout
  ensure_service_account

  local default_label decision
  default_label="$(hostname -s)-edge"

  note "${AFX_NAME} 默认按极致性能路径部署：root 运行、放开 systemd 约束，并优先移除主机防火墙路径开销。"
  decision=$(prompt_value "继续部署？输入 y 继续" "y")
  [[ "$decision" =~ ^[Yy]$ ]] || exit 0

  AFX_NODE_LABEL=$(sanitize_label "$(prompt_value "节点标签" "$default_label")")
  AFX_PERF_PROFILE=$(normalize_perf_profile "$(prompt_value "性能模式：1=极致性能 2=兼容基线" "1")")
  AFX_REALITY_SERVER=$(prompt_value "REALITY 握手站点" "$AFX_DEFAULT_REALITY_SERVER")
  AFX_REALITY_PORT=$(normalize_port "$(prompt_value "REALITY TCP 端口" "$(preferred_port tcp)")" tcp)
  AFX_HY2_PORT=$(normalize_port "$(prompt_value "Hysteria 2 UDP 端口" "$(preferred_port udp)")" udp)
  note "Hysteria 2 现在支持两种模式：1 为 BBR 自适应模式；2 为 Brutal 固定速率模式。前者更适合未知链路，后者只适合你能准确估计带宽上限的场景。"
  AFX_HY2_MODE=$(normalize_hy2_mode "$(prompt_value "Hysteria 2 模式：1=BBR自适应 2=Brutal固定速率" "1")")
  if [[ "$AFX_HY2_MODE" == "brutal" ]]; then
    note "Brutal 模式需要服务端和客户端都填写接近真实链路的带宽，不要盲目虚高。"
    AFX_HY2_UP=$(prompt_value "Hysteria 2 服务端上行带宽上限 Mbps" "$AFX_DEFAULT_HY2_SERVER_UP")
    AFX_HY2_DOWN=$(prompt_value "Hysteria 2 服务端下行带宽上限 Mbps" "$AFX_DEFAULT_HY2_SERVER_DOWN")
    AFX_HY2_CLIENT_UP=$(prompt_value "Hysteria 2 客户端上行目标 Mbps（写入分享链接）" "$AFX_DEFAULT_HY2_CLIENT_UP")
    AFX_HY2_CLIENT_DOWN=$(prompt_value "Hysteria 2 客户端下行目标 Mbps（写入分享链接）" "$AFX_DEFAULT_HY2_CLIENT_DOWN")
  else
    AFX_HY2_UP=""
    AFX_HY2_DOWN=""
    AFX_HY2_CLIENT_UP=""
    AFX_HY2_CLIENT_DOWN=""
  fi

  if [[ "$AFX_REALITY_PORT" != "443" || "$AFX_HY2_PORT" != "443" ]]; then
    warn "检测到 443 已被占用，AeroFlux 将使用 REALITY ${AFX_REALITY_PORT}/tcp 与 Hysteria 2 ${AFX_HY2_PORT}/udp"
    warn "请同步放行云防火墙与系统防火墙中的上述端口，否则客户端会显示延迟 -1ms 或无法连通"
  fi

  configure_firewall_rules

  if [[ "$AFX_HY2_MODE" == "brutal" ]]; then
    [[ "$AFX_HY2_UP" =~ ^[0-9]+$ ]] || die "上行带宽必须是整数"
    [[ "$AFX_HY2_DOWN" =~ ^[0-9]+$ ]] || die "下行带宽必须是整数"
    [[ "$AFX_HY2_CLIENT_UP" =~ ^[0-9]+$ ]] || die "客户端上行带宽必须是整数"
    [[ "$AFX_HY2_CLIENT_DOWN" =~ ^[0-9]+$ ]] || die "客户端下行带宽必须是整数"
  fi

  AFX_CORE_VERSION=$(latest_core_version)
  download_core_binary "$AFX_CORE_VERSION"

  AFX_NODE_ID=$(cat /proc/sys/kernel/random/uuid)
  AFX_HY2_SECRET="$AFX_NODE_ID"
  AFX_ENDPOINT=$(public_host)

  generate_tls_material "$AFX_ENDPOINT"
  generate_reality_keys
  write_runtime_env
  render_config
  install_manager_plane
  install_tune_plane
  lock_permissions
  install_service_unit

  local tune_answer
  tune_answer=$(prompt_value "是否立即应用性能档案（BBR + UDP profile）？y/n" "y")
  if [[ "$tune_answer" =~ ^[Yy]$ ]]; then
    apply_performance_profile
  fi

  render_links
  good "${AFX_NAME} 部署完成"
  note "性能模式: ${AFX_PERF_PROFILE}"
  note "最终端口: REALITY ${AFX_REALITY_PORT}/tcp, Hysteria 2 ${AFX_HY2_PORT}/udp"
  if [[ "$AFX_HY2_MODE" == "brutal" ]]; then
    note "Hysteria 2 模式: Brutal 锁带宽，服务端 ${AFX_HY2_UP}/${AFX_HY2_DOWN} Mbps, 客户端 ${AFX_HY2_CLIENT_UP}/${AFX_HY2_CLIENT_DOWN} Mbps"
  else
    note "Hysteria 2 模式: BBR 自适应，客户端 Up/Dw 请留空，按链路实时状态自动收敛"
  fi
  note "建议在 v2rayN 中同时保留 REALITY 与 Hysteria 2，两条线路按实时表现切换。"
}

show_menu() {
  echo
  note "${AFX_NAME} Control Plane"
  echo "1. Deploy / Rebuild"
  echo "2. Reprint Share Links"
  echo "3. Refresh Core"
  echo "4. Apply Performance Profile"
  echo "5. Runtime Status"
  echo "6. Uninstall"
  echo "0. Exit"
  case "$(prompt_value "请选择" "1")" in
    1) install_fresh ;;
    2) render_links ;;
    3) refresh_core ;;
    4) apply_performance_profile ;;
    5) status_report ;;
    6) remove_aeroflux ;;
    0) exit 0 ;;
    *) die "无效选项" ;;
  esac
}

case "${1-}" in
  install|deploy) install_fresh ;;
  links|show-links) render_links ;;
  refresh|update) refresh_core ;;
  tune)
    shift || true
    install_tune_plane
    "$AFX_TUNE_SCRIPT" "${1-apply}"
    ;;
  status) status_report ;;
  uninstall|remove) remove_aeroflux ;;
  *) show_menu ;;
esac
