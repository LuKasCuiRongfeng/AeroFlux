#!/usr/bin/env bash
set -euo pipefail

SYSCTL_FILE="/etc/sysctl.d/99-aeroflux.conf"

if [[ ${EUID} -ne 0 ]]; then
  echo "please run as root" >&2
  exit 1
fi

cat > "$SYSCTL_FILE" <<'EOF'
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
EOF

modprobe tcp_bbr >/dev/null 2>&1 || true
sysctl --system >/dev/null

sysctl net.ipv4.tcp_congestion_control
sysctl net.core.default_qdisc
sysctl net.core.rmem_max
sysctl net.core.wmem_max
