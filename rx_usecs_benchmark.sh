#!/usr/bin/env bash
#
# rx_usecs_benchmark.sh
# Benchmarks NIC interrupt coalescing (rx-usecs) to help determine
# whether lowering the value improves performance for your workload.
#
# Usage: sudo ./rx_usecs_benchmark.sh -i <interface> [-t <target_ip>] [-d <duration>] [-p <port>]
#
# Requirements: ethtool, mpstat (sysstat), ping, iperf3 (optional for throughput test)
#

set -euo pipefail

# ─── Defaults ────────────────────────────────────────────────────────────────
IFACE=""
TARGET=""
DURATION=10
PORT=5201
RUN_THROUGHPUT=false
CANDIDATE_USECS=0
LOG_DIR=""

# ─── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ─── Helpers ─────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
${BOLD}rx-usecs Benchmark Tool${NC}

Compares your current rx-usecs setting against a candidate value (default: 0)
by measuring latency, interrupt rate, and CPU usage. Optionally tests throughput.

${BOLD}Usage:${NC}
  sudo $0 -i <interface> [options]

${BOLD}Required:${NC}
  -i <interface>    Network interface (e.g., eth0, ens5)

${BOLD}Options:${NC}
  -t <target_ip>    Target IP for latency test (ping). If omitted, latency test is skipped.
  -d <duration>     Test duration in seconds per phase (default: 10)
  -c <usecs>        Candidate rx-usecs value to test (default: 0)
  -p <port>         iperf3 port (default: 5201)
  -T                Run iperf3 throughput test (requires iperf3 server at target)
  -h                Show this help

${BOLD}Examples:${NC}
  sudo $0 -i eth0 -t 10.0.0.1
  sudo $0 -i eth0 -t 10.0.0.1 -d 15 -c 5 -T

EOF
    exit 0
}

log()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()  { echo -e "${RED}[ERR]${NC}   $*" >&2; }
hdr()  { echo -e "\n${BOLD}━━━ $* ━━━${NC}"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        err "This script must be run as root (sudo)."
        exit 1
    fi
}

check_deps() {
    local missing=()
    for cmd in ethtool mpstat; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        err "Missing required tools: ${missing[*]}"
        echo "  Install with: apt install ethtool sysstat  (or equivalent)"
        exit 1
    fi
    if $RUN_THROUGHPUT && ! command -v iperf3 &>/dev/null; then
        warn "iperf3 not found — throughput test will be skipped."
        RUN_THROUGHPUT=false
    fi
}

# ─── Parse args ──────────────────────────────────────────────────────────────
while getopts "i:t:d:c:p:Th" opt; do
    case $opt in
        i) IFACE="$OPTARG" ;;
        t) TARGET="$OPTARG" ;;
        d) DURATION="$OPTARG" ;;
        c) CANDIDATE_USECS="$OPTARG" ;;
        p) PORT="$OPTARG" ;;
        T) RUN_THROUGHPUT=true ;;
        h) usage ;;
        *) usage ;;
    esac
done

[[ -z "$IFACE" ]] && { err "Interface (-i) is required."; usage; }

check_root
check_deps

# Validate interface exists
if ! ip link show "$IFACE" &>/dev/null; then
    err "Interface '$IFACE' not found."
    exit 1
fi

# ─── Setup ───────────────────────────────────────────────────────────────────
LOG_DIR=$(mktemp -d /tmp/rx_usecs_bench.XXXXXX)
log "Results will be saved to: $LOG_DIR"

# Get current rx-usecs
CURRENT_USECS=$(ethtool -c "$IFACE" 2>/dev/null | awk '/^rx-usecs:/{print $2}')
if [[ -z "$CURRENT_USECS" || "$CURRENT_USECS" == "n/a" ]]; then
    err "Could not read rx-usecs for $IFACE. The NIC or driver may not support coalescing."
    exit 1
fi

ADAPTIVE=$(ethtool -c "$IFACE" 2>/dev/null | awk '/^Adaptive RX:/{print $3}')

hdr "Configuration"
echo "  Interface:         $IFACE"
echo "  Current rx-usecs:  $CURRENT_USECS"
echo "  Candidate rx-usecs: $CANDIDATE_USECS"
echo "  Adaptive RX:       ${ADAPTIVE:-unknown}"
echo "  Test duration:     ${DURATION}s per phase"
echo "  Ping target:       ${TARGET:-none (latency test skipped)}"
echo "  Throughput test:   $RUN_THROUGHPUT"

if [[ "$ADAPTIVE" == "on" ]]; then
    warn "Adaptive RX coalescing is ON. This script will temporarily disable it."
    warn "It will be re-enabled after the test."
fi

# ─── Measurement Functions ───────────────────────────────────────────────────

get_interrupt_count() {
    # Sum all interrupt counts for this interface across all CPUs
    awk -v iface="$IFACE" '
        $NF == iface || $NF == iface"-TxRx-0" || index($NF, iface) {
            for (i = 2; i <= NF-2; i++) sum += $i
        }
        END { print sum+0 }
    ' /proc/interrupts
}

measure_phase() {
    local label="$1"
    local usecs_val="$2"
    local result_file="$LOG_DIR/${label}.txt"

    hdr "Phase: $label (rx-usecs=$usecs_val)"

    # Disable adaptive if it was on, set the target rx-usecs
    if [[ "$ADAPTIVE" == "on" ]]; then
        ethtool -C "$IFACE" adaptive-rx off 2>/dev/null || true
    fi
    ethtool -C "$IFACE" rx-usecs "$usecs_val" 2>/dev/null
    log "Set rx-usecs to $usecs_val"

    # Brief settle time
    sleep 1

    # ── Interrupts (before) ──
    local irq_before
    irq_before=$(get_interrupt_count)

    # ── CPU usage via mpstat (background) ──
    mpstat -u 1 "$DURATION" > "$LOG_DIR/${label}_mpstat.txt" 2>&1 &
    local mpstat_pid=$!

    # ── Latency via ping (background, if target given) ──
    local ping_pid=""
    if [[ -n "$TARGET" ]]; then
        ping -i 0.05 -c $((DURATION * 20)) -q "$TARGET" > "$LOG_DIR/${label}_ping.txt" 2>&1 &
        ping_pid=$!
    fi

    # ── Throughput via iperf3 (background, if requested) ──
    local iperf_pid=""
    if $RUN_THROUGHPUT && [[ -n "$TARGET" ]]; then
        iperf3 -c "$TARGET" -p "$PORT" -t "$DURATION" -J > "$LOG_DIR/${label}_iperf.json" 2>&1 &
        iperf_pid=$!
    fi

    # Wait for everything
    wait "$mpstat_pid" 2>/dev/null || true
    [[ -n "$ping_pid" ]]  && wait "$ping_pid"  2>/dev/null || true
    [[ -n "$iperf_pid" ]] && wait "$iperf_pid" 2>/dev/null || true

    # ── Interrupts (after) ──
    local irq_after
    irq_after=$(get_interrupt_count)
    local irq_total=$((irq_after - irq_before))
    local irq_per_sec=$((irq_total / DURATION))

    # ── Parse results ──
    # CPU: average idle from mpstat
    local cpu_idle cpu_used
    cpu_idle=$(awk '/^Average:/ && /all/ {print $(NF)}' "$LOG_DIR/${label}_mpstat.txt" | head -1)
    cpu_used=$(echo "100 - ${cpu_idle:-0}" | bc 2>/dev/null || echo "N/A")

    # Softirq CPU specifically
    local softirq_pct
    softirq_pct=$(awk '/^Average:/ && /all/ {print $(NF-1)}' "$LOG_DIR/${label}_mpstat.txt" | head -1)

    # Latency
    local ping_avg="N/A" ping_min="N/A" ping_max="N/A" ping_mdev="N/A"
    if [[ -n "$TARGET" && -f "$LOG_DIR/${label}_ping.txt" ]]; then
        local rtt_line
        rtt_line=$(grep 'rtt\|round-trip' "$LOG_DIR/${label}_ping.txt" || true)
        if [[ -n "$rtt_line" ]]; then
            ping_min=$(echo "$rtt_line" | awk -F'[= /]' '{print $7}' | head -1)
            ping_avg=$(echo "$rtt_line" | awk -F'[= /]' '{print $8}' | head -1)
            ping_max=$(echo "$rtt_line" | awk -F'[= /]' '{print $9}' | head -1)
            ping_mdev=$(echo "$rtt_line" | awk -F'[= /]' '{print $10}' | head -1)
        fi
        local pkt_loss
        pkt_loss=$(grep -oP '\d+(\.\d+)?% packet loss' "$LOG_DIR/${label}_ping.txt" || echo "N/A")
    fi

    # Throughput
    local throughput="N/A"
    if $RUN_THROUGHPUT && [[ -f "$LOG_DIR/${label}_iperf.json" ]]; then
        throughput=$(python3 -c "
import json, sys
try:
    d = json.load(open('$LOG_DIR/${label}_iperf.json'))
    bps = d['end']['sum_received']['bits_per_second']
    print(f'{bps/1e9:.2f} Gbps')
except:
    print('N/A')
" 2>/dev/null || echo "N/A")
    fi

    # ── Write summary ──
    cat > "$result_file" <<RESULT
rx-usecs=$usecs_val
interrupts_total=$irq_total
interrupts_per_sec=$irq_per_sec
cpu_used_pct=$cpu_used
softirq_pct=${softirq_pct:-N/A}
ping_min_ms=$ping_min
ping_avg_ms=$ping_avg
ping_max_ms=$ping_max
ping_mdev_ms=$ping_mdev
packet_loss=${pkt_loss:-N/A}
throughput=$throughput
RESULT

    # ── Display ──
    echo ""
    printf "  %-24s %s\n" "Interrupts/sec:"    "$irq_per_sec"
    printf "  %-24s %s\n" "Total interrupts:"   "$irq_total"
    printf "  %-24s %s%%\n" "CPU used (avg):"   "$cpu_used"
    printf "  %-24s %s%%\n" "Soft IRQ CPU:"     "${softirq_pct:-N/A}"
    if [[ -n "$TARGET" ]]; then
        printf "  %-24s %s ms\n" "Ping avg:"    "$ping_avg"
        printf "  %-24s %s ms\n" "Ping min:"    "$ping_min"
        printf "  %-24s %s ms\n" "Ping max:"    "$ping_max"
        printf "  %-24s %s ms\n" "Ping jitter (mdev):" "$ping_mdev"
        printf "  %-24s %s\n"    "Packet loss:" "${pkt_loss:-N/A}"
    fi
    if $RUN_THROUGHPUT; then
        printf "  %-24s %s\n" "Throughput:" "$throughput"
    fi
}

# ─── Restore function (trap) ────────────────────────────────────────────────
restore() {
    hdr "Restoring original settings"
    ethtool -C "$IFACE" rx-usecs "$CURRENT_USECS" 2>/dev/null || true
    if [[ "$ADAPTIVE" == "on" ]]; then
        ethtool -C "$IFACE" adaptive-rx on 2>/dev/null || true
    fi
    log "Restored rx-usecs to $CURRENT_USECS"
    [[ "$ADAPTIVE" == "on" ]] && log "Re-enabled adaptive RX coalescing"
}
trap restore EXIT

# ─── Run Phases ──────────────────────────────────────────────────────────────
measure_phase "baseline" "$CURRENT_USECS"
measure_phase "candidate" "$CANDIDATE_USECS"

# ─── Analysis ────────────────────────────────────────────────────────────────
hdr "Comparison & Recommendation"

# Source results
declare -A B C
while IFS='=' read -r k v; do B["$k"]="$v"; done < "$LOG_DIR/baseline.txt"
while IFS='=' read -r k v; do C["$k"]="$v"; done < "$LOG_DIR/candidate.txt"

echo ""
printf "  ${BOLD}%-28s %-20s %-20s${NC}\n" "Metric" "Current (${CURRENT_USECS}µs)" "Candidate (${CANDIDATE_USECS}µs)"
printf "  %-28s %-20s %-20s\n"             "────────────────────────────" "────────────────────" "────────────────────"
printf "  %-28s %-20s %-20s\n" "Interrupts/sec"    "${B[interrupts_per_sec]}" "${C[interrupts_per_sec]}"
printf "  %-28s %-20s %-20s\n" "CPU used %"        "${B[cpu_used_pct]}%"     "${C[cpu_used_pct]}%"
printf "  %-28s %-20s %-20s\n" "Soft IRQ CPU %"    "${B[softirq_pct]}%"      "${C[softirq_pct]}%"

if [[ -n "$TARGET" ]]; then
    printf "  %-28s %-20s %-20s\n" "Ping avg (ms)"     "${B[ping_avg_ms]}"   "${C[ping_avg_ms]}"
    printf "  %-28s %-20s %-20s\n" "Ping min (ms)"     "${B[ping_min_ms]}"   "${C[ping_min_ms]}"
    printf "  %-28s %-20s %-20s\n" "Ping max (ms)"     "${B[ping_max_ms]}"   "${C[ping_max_ms]}"
    printf "  %-28s %-20s %-20s\n" "Ping jitter (ms)"  "${B[ping_mdev_ms]}"  "${C[ping_mdev_ms]}"
    printf "  %-28s %-20s %-20s\n" "Packet loss"       "${B[packet_loss]}"   "${C[packet_loss]}"
fi

if $RUN_THROUGHPUT; then
    printf "  %-28s %-20s %-20s\n" "Throughput"        "${B[throughput]}"     "${C[throughput]}"
fi

# ── Simple recommendation logic ──
echo ""
hdr "Analysis"

irq_increase=0
if [[ "${B[interrupts_per_sec]}" -gt 0 ]]; then
    irq_increase=$(( (${C[interrupts_per_sec]} - ${B[interrupts_per_sec]}) * 100 / ${B[interrupts_per_sec]} ))
fi

cpu_b=$(echo "${B[cpu_used_pct]}" | sed 's/[^0-9.]//g')
cpu_c=$(echo "${C[cpu_used_pct]}" | sed 's/[^0-9.]//g')

# Use awk for float comparisons
latency_improved=false
if [[ -n "$TARGET" && "${B[ping_avg_ms]}" != "N/A" && "${C[ping_avg_ms]}" != "N/A" ]]; then
    latency_improved=$(awk "BEGIN { print (${C[ping_avg_ms]} < ${B[ping_avg_ms]}) ? \"true\" : \"false\" }")
    latency_delta=$(awk "BEGIN { printf \"%.3f\", ${B[ping_avg_ms]} - ${C[ping_avg_ms]} }")
fi

cpu_spike=$(awk "BEGIN { print (${cpu_c:-0} - ${cpu_b:-0} > 10) ? \"true\" : \"false\" }")
irq_explosion=$(( irq_increase > 500 ))

echo ""
echo "  Interrupt rate change:  ${irq_increase}%"
[[ -n "$TARGET" && "$latency_improved" == "true" ]] && \
    echo -e "  Latency improvement:    ${GREEN}${latency_delta} ms lower${NC}"
[[ -n "$TARGET" && "$latency_improved" == "false" && "${B[ping_avg_ms]}" != "N/A" ]] && \
    echo -e "  Latency change:         ${YELLOW}no improvement or worse${NC}"
[[ "$cpu_spike" == "true" ]] && \
    echo -e "  CPU impact:             ${RED}significant increase (>${cpu_b}% → ${cpu_c}%)${NC}"
[[ "$cpu_spike" == "false" ]] && \
    echo -e "  CPU impact:             ${GREEN}manageable${NC}"

echo ""
if [[ "$cpu_spike" == "true" && "$irq_explosion" -eq 1 ]]; then
    echo -e "  ${RED}${BOLD}Recommendation: KEEP rx-usecs at $CURRENT_USECS${NC}"
    echo "  The candidate value caused a large spike in interrupts and CPU usage."
    echo "  The overhead likely outweighs any latency benefit."
elif [[ "$latency_improved" == "true" && "$cpu_spike" == "false" ]]; then
    echo -e "  ${GREEN}${BOLD}Recommendation: CONSIDER lowering rx-usecs to $CANDIDATE_USECS${NC}"
    echo "  Latency improved by ${latency_delta} ms with acceptable CPU overhead."
    echo "  Validate under production load before making permanent."
elif [[ "$latency_improved" == "false" && "$cpu_spike" == "false" ]]; then
    echo -e "  ${YELLOW}${BOLD}Recommendation: NO CLEAR BENEFIT to changing rx-usecs${NC}"
    echo "  Latency did not improve and CPU impact was minor."
    echo "  Keep current setting unless application-level benchmarks show otherwise."
else
    echo -e "  ${YELLOW}${BOLD}Recommendation: TEST FURTHER${NC}"
    echo "  Results are mixed. Consider testing intermediate values (e.g., 5, 10)"
    echo "  and running application-specific benchmarks."
fi

echo ""
echo -e "  ${BOLD}Tip:${NC} For the most accurate results, run this during representative workload."
echo "  Raw data saved to: $LOG_DIR"
echo ""

# ── Save final report ──
{
    echo "rx-usecs Benchmark Report — $(date)"
    echo "Interface: $IFACE"
    echo "Current: $CURRENT_USECS µs → Candidate: $CANDIDATE_USECS µs"
    echo "Duration: ${DURATION}s per phase"
    echo ""
    cat "$LOG_DIR/baseline.txt"
    echo ""
    cat "$LOG_DIR/candidate.txt"
} > "$LOG_DIR/report.txt"

log "Full report: $LOG_DIR/report.txt"
