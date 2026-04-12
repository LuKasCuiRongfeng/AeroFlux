#!/usr/bin/env bash
set -euo pipefail

readonly AFX_SYSCTL_FILE="/etc/sysctl.d/90-aeroflux-performance.conf"
readonly AFX_RUNTIME_ENV="/etc/aeroflux/runtime.env"

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

load_perf_profile() {
  if [[ -f "$AFX_RUNTIME_ENV" ]]; then
    # shellcheck disable=SC1090
    source "$AFX_RUNTIME_ENV"
  fi
  printf '%s' "${AFX_PERF_PROFILE:-extreme}"
}

detect_primary_iface() {
  ip route show default 2>/dev/null | awk '/default/ {print $5; exit}'
}

cpu_count() {
  nproc 2>/dev/null || echo 1
}

cpu_mask() {
  local cpu_count
  cpu_count=$(cpu_count)
  if (( cpu_count <= 1 )); then
    printf '1'
  elif (( cpu_count >= 63 )); then
    printf 'ffffffff,ffffffff'
  else
    printf '%x' "$(( (1 << cpu_count) - 1 ))"
  fi
}

cpu_mask_for_cpu() {
  local cpu="$1"
  if (( cpu < 32 )); then
    printf '%x' "$((1 << cpu))"
  else
    printf '%x,%08x' "$((1 << (cpu - 32)))" 0
  fi
}

tune_cpu_runtime() {
  local governor

  if command -v systemctl >/dev/null 2>&1; then
    systemctl stop irqbalance.service >/dev/null 2>&1 || true
    systemctl disable irqbalance.service >/dev/null 2>&1 || true
  fi

  for governor in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [[ -e "$governor" ]] || continue
    [[ -w "$governor" ]] && echo performance > "$governor" || true
  done
}

tune_irq_affinity() {
  local iface total_cpus irq index affinity
  iface=$(detect_primary_iface)
  [[ -n "$iface" && -r /proc/interrupts ]] || return 0

  total_cpus=$(cpu_count)
  (( total_cpus > 1 && total_cpus <= 64 )) || return 0

  index=0
  while read -r irq; do
    [[ -n "$irq" && -w "/proc/irq/$irq/smp_affinity" ]] || continue
    affinity=$(cpu_mask_for_cpu "$(( index % total_cpus ))")
    echo "$affinity" > "/proc/irq/$irq/smp_affinity" || true
    index=$((index + 1))
  done < <(awk -F: -v iface="$iface" '$0 ~ iface {gsub(/ /, "", $1); print $1}' /proc/interrupts)
}

tune_nic() {
  local iface mask queue combined_queues
  iface=$(detect_primary_iface)
  [[ -n "$iface" ]] || return 0
  mask=$(cpu_mask)

  ip link set dev "$iface" txqueuelen 10000 >/dev/null 2>&1 || true

  if command -v ethtool >/dev/null 2>&1; then
    combined_queues=$(ethtool -l "$iface" 2>/dev/null | awk '/Pre-set maximums:/ {preset=1; next} /Current hardware settings:/ {preset=0} preset && /Combined:/ {print $2; exit}')
    [[ "$combined_queues" =~ ^[0-9]+$ ]] && (( combined_queues > 0 )) && ethtool -L "$iface" combined "$combined_queues" >/dev/null 2>&1 || true
    ethtool -G "$iface" rx 4096 tx 4096 >/dev/null 2>&1 || true
    ethtool -K "$iface" gro on gso on tso on rx on tx on >/dev/null 2>&1 || true
    ethtool -K "$iface" rx-udp-gro-forwarding on >/dev/null 2>&1 || true
    ethtool -K "$iface" rx-gro-list off >/dev/null 2>&1 || true
  fi

  if [[ -w /proc/sys/net/core/rps_sock_flow_entries ]]; then
    echo 32768 > /proc/sys/net/core/rps_sock_flow_entries || true
  fi

  for queue in /sys/class/net/"$iface"/queues/rx-*; do
    [[ -e "$queue" ]] || continue
    [[ -w "$queue/rps_cpus" ]] && echo "$mask" > "$queue/rps_cpus" || true
    [[ -w "$queue/rps_flow_cnt" ]] && echo 4096 > "$queue/rps_flow_cnt" || true
  done

  for queue in /sys/class/net/"$iface"/queues/tx-*; do
    [[ -e "$queue" ]] || continue
    [[ -w "$queue/xps_cpus" ]] && echo "$mask" > "$queue/xps_cpus" || true
  done
}

write_profile() {
  cat > "$AFX_SYSCTL_FILE" <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 524288
net.core.netdev_budget = 1200
net.core.netdev_budget_usecs = 16000
net.core.dev_weight = 256
net.core.dev_weight_rx_bias = 4
net.core.dev_weight_tx_bias = 2
net.core.busy_poll = 50
net.core.busy_read = 50
net.core.optmem_max = 33554432
net.core.rmem_default = 33554432
net.core.wmem_default = 33554432
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_rmem = 4096 1048576 134217728
net.ipv4.tcp_wmem = 4096 1048576 134217728
net.ipv4.udp_rmem_min = 131072
net.ipv4.udp_wmem_min = 131072
net.ipv4.udp_mem = 524288 1048576 2097152
EOF
}

apply_profile() {
  local profile
  require_root
  profile=$(load_perf_profile)
  write_profile
  modprobe tcp_bbr >/dev/null 2>&1 || true
  sysctl --system >/dev/null
  if [[ "$profile" == "extreme" ]]; then
    tune_cpu_runtime
    tune_nic
    tune_irq_affinity
  fi
  note "AeroFlux performance profile 已应用"
  show_status
}

show_status() {
  local iface
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
  sysctl net.core.netdev_budget
  sysctl net.core.netdev_budget_usecs
  sysctl net.core.dev_weight
  sysctl net.core.dev_weight_rx_bias
  sysctl net.core.dev_weight_tx_bias
  sysctl net.core.busy_poll
  sysctl net.core.busy_read
  sysctl net.ipv4.udp_mem
  iface=$(detect_primary_iface)
  if [[ -n "$iface" ]]; then
    ip -details link show dev "$iface" | awk '/qlen/ {print $0; exit}'
    if command -v ethtool >/dev/null 2>&1; then
      ethtool -l "$iface" 2>/dev/null | awk '/Current hardware settings:/,0 {print $0}'
      ethtool -k "$iface" | awk '/generic-receive-offload|generic-segmentation-offload|tcp-segmentation-offload|rx-udp-gro-forwarding/ {print $0}'
    fi
  fi
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
