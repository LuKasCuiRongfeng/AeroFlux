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
  cat > "$AFX_SYSCTL_FILE" <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.somaxconn = 4096
net.core.netdev_max_backlog = 16384
net.core.rmem_default = 8388608
net.core.wmem_default = 8388608
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
net.ipv4.udp_mem = 65536 131072 262144
EOF
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
