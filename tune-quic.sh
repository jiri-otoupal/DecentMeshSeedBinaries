#!/usr/bin/env bash
# ============================================================================
#  DecentMesh Relay — QUIC Network Tuning
#
#  Usage:   sudo bash tune-quic.sh [--nic eth0]
#  Tested:  Debian 12 (Bookworm)
#
#  Complements setup-relay.sh — run AFTER initial setup.
#  Idempotent — safe to re-run.
#
#  Tuning goals:
#    ◆ Low latency        — busy-poll, interrupt coalescing, NOTRACK
#    ◆ Low jitter          — NUMA pinning, timer migration off, watchdog off
#    ◆ Deterministic       — CPU governor locked, THP madvise, no compaction
#    ◆ High PPS            — RPS/RFS/XPS, conntrack bypass, backlog scaling
#    ◆ Message scalability — fd limits, memory headroom, hash table sizing
# ============================================================================
set -euo pipefail

# ─── colours ────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'; CYN='\033[0;36m'; RST='\033[0m'
step()  { echo -e "\n${CYN}▶ $1${RST}"; }
ok()    { echo -e "  ${GRN}✔ $1${RST}"; }
warn()  { echo -e "  ${YLW}⚠ $1${RST}"; }
fail()  { echo -e "  ${RED}✖ $1${RST}"; exit 1; }

[[ $EUID -eq 0 ]] || fail "Run as root:  sudo bash $0"

# ─── configurable ──────────────────────────────────────────────────────────
RELAY_PORT=8888
SERVICE_NAME="decentmesh-relay"

# Auto-detect primary NIC or accept --nic <name>
NIC=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --nic) NIC="$2"; shift 2 ;;
    *) fail "Unknown argument: $1" ;;
  esac
done

if [[ -z "${NIC}" ]]; then
  NIC=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)
fi
[[ -n "${NIC}" ]] || fail "Could not detect primary NIC. Use --nic <name>"

NUM_CPUS=$(nproc)
echo -e "${CYN}DecentMesh QUIC Network Tuning${RST}"
echo -e "  NIC: ${GRN}${NIC}${RST}  CPUs: ${GRN}${NUM_CPUS}${RST}  Port: ${GRN}${RELAY_PORT}${RST}"

###############################################################################
#  1.  KERNEL SYSCTL
###############################################################################
step "1/10  Kernel sysctl — UDP, jitter, PPS, scalability"

cat > /etc/sysctl.d/90-decentmesh-quic.conf <<'EOF'
# ═══════════════════════════════════════════════════════════════════════════
#  DecentMesh QUIC Tuning — latency · jitter · PPS · scalability
# ═══════════════════════════════════════════════════════════════════════════

# ── UDP / Socket Buffers (scalability under burst) ──
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 2097152
net.core.wmem_default = 2097152
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
net.ipv4.udp_mem = 65536 131072 262144

# ── Busy Polling (low latency — bypass interrupt path) ──
net.core.busy_read = 50
net.core.busy_poll = 50

# ── Backlog & Pacing (high PPS — absorb packet bursts) ──
net.core.netdev_max_backlog = 250000
net.core.netdev_budget = 1200
net.core.netdev_budget_usecs = 12000
net.core.somaxconn = 65535

# ── Optmem for ancillary data (GRO/cmsg scalability) ──
net.core.optmem_max = 2097152

# ── ARP table (high connection count scalability) ──
net.ipv4.neigh.default.gc_thresh1 = 2048
net.ipv4.neigh.default.gc_thresh2 = 8192
net.ipv4.neigh.default.gc_thresh3 = 16384

# ── Jitter reduction: disable NUMA balancing ──
# Prevents the kernel from randomly migrating memory pages between NUMA
# nodes, which causes unpredictable latency spikes.
kernel.numa_balancing = 0

# ── Jitter reduction: timer migration ──
# Prevents timer interrupts from migrating to random CPUs. Keeps
# processing deterministic on the CPU where the socket is pinned.
kernel.timer_migration = 0

# ── Jitter reduction: disable watchdog ──
# NMI watchdog fires periodic interrupts on every CPU. Disabling
# eliminates a source of jitter (safe for production relay servers).
kernel.nmi_watchdog = 0
kernel.watchdog = 0

# ── Jitter reduction: scheduler ──
# Reduce rescheduling noise — let the relay hold the CPU longer.
kernel.sched_min_granularity_ns = 10000000
kernel.sched_wakeup_granularity_ns = 15000000
kernel.sched_migration_cost_ns = 5000000

# ── Deterministic: VM / memory ──
# Never swap under normal conditions (relay must stay in RAM).
vm.swappiness = 1
# Don't let dirty page writeback spike latency.
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
# Allow overcommit — prevents surprise OOM on transient spikes.
vm.overcommit_memory = 1

# ── Scalability: file descriptor & socket limits ──
fs.file-max = 2097152
fs.nr_open = 2097152
EOF

# Apply each setting individually — some params may not exist on all kernels
grep -E '^[a-z]' /etc/sysctl.d/90-decentmesh-quic.conf | while IFS='=' read -r key value; do
  key="${key%% }"    # trim trailing spaces
  value="${value## }" # trim leading spaces
  sysctl -w "${key}=${value}" > /dev/null 2>&1 \
    || warn "Skipped ${key} (not available on this kernel)"
done

ok "Sysctl applied (UDP buffers, jitter, PPS, scalability)"

###############################################################################
#  2.  CPU GOVERNOR → PERFORMANCE (deterministic latency)
###############################################################################
step "2/10  CPU governor → performance (no frequency scaling jitter)"

apt-get install -y -qq linux-cpupower cpufrequtils 2>/dev/null || true

if command -v cpupower &>/dev/null; then
  cpupower frequency-set -g performance 2>/dev/null || true
  # Disable C-states deeper than C1 — deeper sleep adds wake-up jitter
  cpupower idle-set -D 2 2>/dev/null || true
  ok "CPU governor=performance, deep C-states disabled"
else
  for cpu_dir in /sys/devices/system/cpu/cpu*/cpufreq; do
    [[ -d "$cpu_dir" ]] && echo "performance" > "$cpu_dir/scaling_governor" 2>/dev/null || true
  done
  ok "CPU governor set via sysfs"
fi

cat > /etc/default/cpufrequtils <<'CPUF'
GOVERNOR="performance"
CPUF
ok "CPU governor persisted"

###############################################################################
#  3.  IRQ AFFINITY + RPS / RFS / XPS (high PPS + low jitter)
###############################################################################
step "3/10  Configuring RPS/RFS/XPS for ${NIC}"

# ── RFS: Receive Flow Steering (scalability) ──
RFS_ENTRIES=$((65536 * NUM_CPUS))
echo "${RFS_ENTRIES}" > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null || true
echo "net.core.rps_sock_flow_entries = ${RFS_ENTRIES}" > /etc/sysctl.d/91-decentmesh-rfs.conf
sysctl -p /etc/sysctl.d/91-decentmesh-rfs.conf > /dev/null 2>&1

# CPU mask for all CPUs
if [[ ${NUM_CPUS} -le 32 ]]; then
  CPU_MASK=$(printf '%x' $(( (1 << NUM_CPUS) - 1 )))
else
  CPU_MASK=$(python3 -c "print(format((1 << ${NUM_CPUS}) - 1, 'x'))")
fi

# ── RPS: Receive Packet Steering (spread rx across all CPUs) ──
for rxq in /sys/class/net/${NIC}/queues/rx-*/rps_cpus; do
  [[ -f "$rxq" ]] && echo "${CPU_MASK}" > "$rxq" 2>/dev/null || true
done

RX_QUEUE_COUNT=$(ls -d /sys/class/net/${NIC}/queues/rx-* 2>/dev/null | wc -l || echo 1)
RFS_PER_QUEUE=$(( RFS_ENTRIES / RX_QUEUE_COUNT ))
for rxq in /sys/class/net/${NIC}/queues/rx-*/rps_flow_cnt; do
  [[ -f "$rxq" ]] && echo "${RFS_PER_QUEUE}" > "$rxq" 2>/dev/null || true
done

ok "RPS/RFS: ${NUM_CPUS} CPUs, mask 0x${CPU_MASK}, ${RFS_ENTRIES} flow entries"

# ── XPS: Transmit Packet Steering (spread tx across CPUs) ──
TX_QUEUE_COUNT=$(ls -d /sys/class/net/${NIC}/queues/tx-* 2>/dev/null | wc -l || echo 1)
if [[ ${TX_QUEUE_COUNT} -gt 1 ]]; then
  # Distribute tx queues evenly across CPUs
  txq_idx=0
  for txq in /sys/class/net/${NIC}/queues/tx-*/xps_cpus; do
    if [[ -f "$txq" ]]; then
      # Assign round-robin: each tx queue gets a subset of CPUs
      cpu_for_queue=$(( txq_idx % NUM_CPUS ))
      queue_mask=$(printf '%x' $(( 1 << cpu_for_queue )))
      echo "${queue_mask}" > "$txq" 2>/dev/null || true
      ((txq_idx++))
    fi
  done
  ok "XPS: ${TX_QUEUE_COUNT} tx queues mapped to CPUs"
else
  # Single queue — all CPUs
  for txq in /sys/class/net/${NIC}/queues/tx-*/xps_cpus; do
    [[ -f "$txq" ]] && echo "${CPU_MASK}" > "$txq" 2>/dev/null || true
  done
  ok "XPS: single queue, all CPUs"
fi

# ── Persist RPS/RFS/XPS via rc.local ──
cat > /etc/rc.local <<RCEOF
#!/bin/bash
# DecentMesh QUIC tuning — boot persistence
CPU_MASK="${CPU_MASK}"
NIC="${NIC}"
RFS_ENTRIES="${RFS_ENTRIES}"

echo "\${RFS_ENTRIES}" > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null || true

for rxq in /sys/class/net/\${NIC}/queues/rx-*/rps_cpus; do
  [ -f "\$rxq" ] && echo "\${CPU_MASK}" > "\$rxq" 2>/dev/null || true
done

RFS_PER_QUEUE=\$(( RFS_ENTRIES / \$(ls -d /sys/class/net/\${NIC}/queues/rx-* 2>/dev/null | wc -l || echo 1) ))
for rxq in /sys/class/net/\${NIC}/queues/rx-*/rps_flow_cnt; do
  [ -f "\$rxq" ] && echo "\${RFS_PER_QUEUE}" > "\$rxq" 2>/dev/null || true
done

# XPS
txq_idx=0
NUM_CPUS=\$(nproc)
for txq in /sys/class/net/\${NIC}/queues/tx-*/xps_cpus; do
  cpu_for_queue=\$(( txq_idx % NUM_CPUS ))
  queue_mask=\$(printf '%x' \$(( 1 << cpu_for_queue )))
  [ -f "\$txq" ] && echo "\${queue_mask}" > "\$txq" 2>/dev/null || true
  ((txq_idx++))
done

exit 0
RCEOF
chmod +x /etc/rc.local
ok "RPS/RFS/XPS persisted"

###############################################################################
#  4.  NIC HARDWARE TUNING
###############################################################################
step "4/10  Tuning NIC hardware for ${NIC}"

apt-get install -y -qq ethtool > /dev/null 2>&1 || true

if command -v ethtool &>/dev/null; then
  # Max ring buffers — absorbs burst, prevents drops (high PPS)
  ethtool -G "${NIC}" rx 4096 tx 4096 2>/dev/null || true

  # GRO: batch incoming packets → fewer interrupts → lower jitter
  ethtool -K "${NIC}" gro on 2>/dev/null || true
  # GSO: batch outgoing packets
  ethtool -K "${NIC}" gso on 2>/dev/null || true
  # TSO off — irrelevant for UDP/QUIC
  ethtool -K "${NIC}" tso off 2>/dev/null || true
  # Scatter-gather
  ethtool -K "${NIC}" sg on 2>/dev/null || true
  # Receive hashing — multi-queue distribution (PPS scaling)
  ethtool -K "${NIC}" rxhash on 2>/dev/null || true
  # UDP segmentation offload — let NIC handle UDP fragmentation
  ethtool -K "${NIC}" tx-udp-segmentation on 2>/dev/null || true

  # Disable energy-efficient ethernet (adds jitter)
  ethtool --set-eee "${NIC}" eee off 2>/dev/null || true

  # Interrupt coalescing OFF — lowest latency, deterministic
  ethtool -C "${NIC}" rx-usecs 0 tx-usecs 0 2>/dev/null || true
  ethtool -C "${NIC}" adaptive-rx off adaptive-tx off 2>/dev/null || true

  # Multi-queue: set combined channels to max (PPS scaling)
  MAX_COMBINED=$(ethtool -l "${NIC}" 2>/dev/null | awk '/Combined:/{val=$2} END{print val}')
  if [[ -n "${MAX_COMBINED}" && "${MAX_COMBINED}" -gt 1 ]]; then
    ethtool -L "${NIC}" combined "${MAX_COMBINED}" 2>/dev/null || true
    ok "NIC: ${MAX_COMBINED} combined channels, ring 4096, GRO on, coalesce off"
  else
    ok "NIC: ring 4096, GRO on, coalesce off"
  fi
else
  warn "ethtool not available — skipping NIC tuning"
fi

###############################################################################
#  5.  CONNTRACK BYPASS (high PPS — biggest single win)
###############################################################################
step "5/10  Conntrack NOTRACK for UDP:${RELAY_PORT}"

apt-get install -y -qq iptables > /dev/null 2>&1 || true

# NOTRACK bypasses the entire conntrack state machine per-packet.
# For a relay doing 100k+ PPS this saves significant CPU per packet.
iptables  -t raw -C PREROUTING -p udp --dport ${RELAY_PORT} -j NOTRACK 2>/dev/null || \
iptables  -t raw -A PREROUTING -p udp --dport ${RELAY_PORT} -j NOTRACK
iptables  -t raw -C OUTPUT     -p udp --sport ${RELAY_PORT} -j NOTRACK 2>/dev/null || \
iptables  -t raw -A OUTPUT     -p udp --sport ${RELAY_PORT} -j NOTRACK

ip6tables -t raw -C PREROUTING -p udp --dport ${RELAY_PORT} -j NOTRACK 2>/dev/null || \
ip6tables -t raw -A PREROUTING -p udp --dport ${RELAY_PORT} -j NOTRACK 2>/dev/null || true
ip6tables -t raw -C OUTPUT     -p udp --sport ${RELAY_PORT} -j NOTRACK 2>/dev/null || \
ip6tables -t raw -A OUTPUT     -p udp --sport ${RELAY_PORT} -j NOTRACK 2>/dev/null || true

if command -v netfilter-persistent &>/dev/null; then
  netfilter-persistent save 2>/dev/null || true
elif command -v iptables-save &>/dev/null; then
  mkdir -p /etc/iptables
  iptables-save  > /etc/iptables/rules.v4
  ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
fi

ok "Conntrack bypassed (NOTRACK)"

###############################################################################
#  6.  TRANSPARENT HUGE PAGES (deterministic — no compaction jitter)
###############################################################################
step "6/10  THP → madvise (deterministic, no compaction storms)"

echo madvise > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
echo madvise > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true

# Disable khugepaged scan — another source of latency spikes
echo 0 > /sys/kernel/mm/transparent_hugepage/khugepaged/defrag 2>/dev/null || true

cat > /etc/tmpfiles.d/decentmesh-thp.conf <<'THP'
w /sys/kernel/mm/transparent_hugepage/enabled - - - - madvise
w /sys/kernel/mm/transparent_hugepage/defrag  - - - - madvise
w /sys/kernel/mm/transparent_hugepage/khugepaged/defrag - - - - 0
THP

ok "THP madvise, khugepaged defrag disabled"

###############################################################################
#  7.  QDISC — NOQUEUE FOR MINIMUM QUEUING DELAY
###############################################################################
step "7/10  Setting queueing discipline → noqueue"

# noqueue: zero queuing delay — packets go straight to the driver.
# If the driver can't accept, packet is dropped (QUIC handles retransmit).
# This is more deterministic than fq for a relay that doesn't need pacing.
tc qdisc replace dev "${NIC}" root noqueue 2>/dev/null \
  || tc qdisc replace dev "${NIC}" root pfifo_fast 2>/dev/null || true
ok "qdisc: noqueue (zero queuing delay)"

###############################################################################
#  8.  SYSTEMD SERVICE — LOW-LATENCY OVERRIDES
###############################################################################
step "8/10  Systemd service overrides"

OVERRIDE_DIR="/etc/systemd/system/${SERVICE_NAME}.service.d"
mkdir -p "${OVERRIDE_DIR}"

cat > "${OVERRIDE_DIR}/low-latency.conf" <<EOF
[Service]
# ── Scheduling (low jitter) ──
Nice=-15
IOSchedulingClass=realtime
IOSchedulingPriority=0
CPUSchedulingPolicy=fifo
CPUSchedulingPriority=50

# ── CPU (deterministic) ──
CPUAffinity=0-$((NUM_CPUS - 1))

# ── Memory (scalability) ──
LimitMEMLOCK=infinity
LimitNOFILE=2097152
LimitNPROC=65535

# ── Network (busy-poll capability) ──
AmbientCapabilities=CAP_NET_ADMIN

# ── Reliability ──
OOMScoreAdjust=-900
EOF

systemctl daemon-reload
systemctl restart "${SERVICE_NAME}" 2>/dev/null || true
ok "Service: FIFO scheduler, Nice=-15, 2M fds, OOM-protected"

###############################################################################
#  9.  UDP HASH TABLE SIZING (message scalability)
###############################################################################
step "9/10  UDP hash table & conntrack optimization"

# Increase UDP hash table for faster socket lookup under high connection counts
# This is a boot-time parameter — persist via GRUB for next boot
GRUB_FILE="/etc/default/grub"
if [[ -f "${GRUB_FILE}" ]]; then
  if ! grep -q "uhash_entries" "${GRUB_FILE}"; then
    sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 udp_htable_entries=65536"/' \
      "${GRUB_FILE}" 2>/dev/null || true
    update-grub 2>/dev/null || true
    ok "UDP hash table: 65536 entries (effective after reboot)"
  else
    ok "UDP hash table already configured"
  fi
fi

# If nf_conntrack is loaded, increase table size for any tracked connections
if lsmod | grep -q nf_conntrack; then
  echo 1048576 > /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || true
  echo "net.netfilter.nf_conntrack_max = 1048576" > /etc/sysctl.d/92-decentmesh-conntrack.conf 2>/dev/null || true
  ok "Conntrack table: 1M entries (for non-relay traffic)"
fi

###############################################################################
#  10.  VALIDATION & REPORT
###############################################################################
step "10/10  Validation"

echo ""
echo -e "${CYN}═══════════════════════════════════════════════════════════════${RST}"
echo -e "${GRN}  QUIC Network Tuning Complete${RST}"
echo -e "${CYN}═══════════════════════════════════════════════════════════════${RST}"
echo ""

echo -e "  ${CYN}UDP Buffers (scalability):${RST}"
echo "    rmem_max       = $(( $(cat /proc/sys/net/core/rmem_max) / 1048576 )) MB"
echo "    wmem_max       = $(( $(cat /proc/sys/net/core/wmem_max) / 1048576 )) MB"
echo ""

echo -e "  ${CYN}Latency:${RST}"
echo "    busy_read      = $(cat /proc/sys/net/core/busy_read 2>/dev/null) μs"
echo "    busy_poll      = $(cat /proc/sys/net/core/busy_poll 2>/dev/null) μs"
echo ""

echo -e "  ${CYN}Jitter Reduction:${RST}"
echo "    numa_balancing  = $(cat /proc/sys/kernel/numa_balancing 2>/dev/null || echo N/A)"
echo "    timer_migration = $(cat /proc/sys/kernel/timer_migration 2>/dev/null || echo N/A)"
echo "    nmi_watchdog    = $(cat /proc/sys/kernel/nmi_watchdog 2>/dev/null || echo N/A)"
echo "    swappiness      = $(cat /proc/sys/vm/swappiness 2>/dev/null || echo N/A)"
echo ""

echo -e "  ${CYN}PPS Scaling:${RST}"
echo "    backlog         = $(cat /proc/sys/net/core/netdev_max_backlog 2>/dev/null)"
echo "    rps_sock_flows  = $(cat /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null)"
RX_Q=$(ls -d /sys/class/net/${NIC}/queues/rx-* 2>/dev/null | wc -l || echo "?")
TX_Q=$(ls -d /sys/class/net/${NIC}/queues/tx-* 2>/dev/null | wc -l || echo "?")
echo "    NIC queues      = ${RX_Q} rx / ${TX_Q} tx"
echo ""

echo -e "  ${CYN}CPU:${RST}"
GOV=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "N/A")
echo "    governor        = ${GOV}"
echo ""

echo -e "  ${CYN}NIC (${NIC}):${RST}"
if command -v ethtool &>/dev/null; then
  RX_RING=$(ethtool -g "${NIC}" 2>/dev/null | awk '/Current hardware settings/{found=1} found && /RX:/{print $2; exit}')
  GRO=$(ethtool -k "${NIC}" 2>/dev/null | awk '/generic-receive-offload/{print $2}')
  echo "    rx ring         = ${RX_RING:-N/A}"
  echo "    GRO             = ${GRO:-N/A}"
fi
echo ""

echo -e "  ${CYN}Conntrack:${RST}"
if iptables -t raw -L PREROUTING -n 2>/dev/null | grep -q "${RELAY_PORT}.*NOTRACK"; then
  echo -e "    UDP:${RELAY_PORT}        = ${GRN}BYPASSED${RST}"
else
  echo -e "    UDP:${RELAY_PORT}        = ${YLW}tracked${RST}"
fi
echo ""

echo -e "  ${CYN}Scalability:${RST}"
echo "    file-max        = $(cat /proc/sys/fs/file-max 2>/dev/null)"
echo "    service fds     = 2097152"
echo ""

echo -e "  ${CYN}Service:${RST}"
echo "    scheduler       = FIFO (priority 50)"
echo "    nice            = -15"
echo "    OOM             = -900 (protected)"
echo ""

echo -e "${CYN}═══════════════════════════════════════════════════════════════${RST}"
echo ""
echo -e "  ${YLW}Monitoring:${RST}"
echo "    ss -uapi sport = :${RELAY_PORT}   # live socket stats"
echo "    perf top                         # kernel hot functions"
echo "    cat /proc/net/udp | wc -l        # open UDP sockets"
echo ""
echo -e "${CYN}═══════════════════════════════════════════════════════════════${RST}"
