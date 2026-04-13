#!/bin/bash
# =============================================================================
# System Health Check Script
# Collects CPU, Memory, Disk, Services, Network, and Process metrics.
# Outputs plain text by default; use --json flag for structured JSON output.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Load environment variables if .env exists
if [[ -f "$PROJECT_DIR/.env" ]]; then
  export $(grep -v '^#' "$PROJECT_DIR/.env" | xargs)
fi

# Defaults (can be overridden via .env)
DATA_FILE="${DATA_FILE:-$PROJECT_DIR/data/metrics.json}"
LOG_FILE="${LOG_FILE:-$PROJECT_DIR/logs/health_check.log}"
SERVICES="${MONITORED_SERVICES:-ssh,cron,networking}"
OUTPUT_FORMAT="${1:-text}"   # "text" or "json"

mkdir -p "$(dirname "$DATA_FILE")" "$(dirname "$LOG_FILE")"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

# ── CPU Usage ────────────────────────────────────────────────────────────────
get_cpu() {
  # Read two snapshots 0.5s apart for accuracy
  local cpu_line1 cpu_line2
  cpu_line1=$(grep '^cpu ' /proc/stat)
  sleep 0.5
  cpu_line2=$(grep '^cpu ' /proc/stat)

  read -r _ u1 n1 s1 i1 io1 irq1 sirq1 _ <<< "$cpu_line1"
  read -r _ u2 n2 s2 i2 io2 irq2 sirq2 _ <<< "$cpu_line2"

  local idle1=$((i1 + io1))
  local idle2=$((i2 + io2))
  local total1=$((u1+n1+s1+i1+io1+irq1+sirq1))
  local total2=$((u2+n2+s2+i2+io2+irq2+sirq2))

  local diff_idle=$((idle2 - idle1))
  local diff_total=$((total2 - total1))

  if [[ $diff_total -eq 0 ]]; then
    echo "0"
  else
    echo $(( (diff_total - diff_idle) * 100 / diff_total ))
  fi
}

# ── Memory Usage ─────────────────────────────────────────────────────────────
get_memory() {
  local total used free available
  total=$(grep MemTotal /proc/meminfo | awk '{print $2}')
  available=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
  used=$(( total - available ))
  local pct=$(( used * 100 / total ))
  echo "$pct $((total/1024)) $((used/1024)) $((available/1024))"
}

# ── Disk Usage ───────────────────────────────────────────────────────────────
get_disk() {
  df -h / | awk 'NR==2 {
    gsub(/%/,"",$5)
    print $5, $2, $3, $4
  }'
}

# ── Service Status ───────────────────────────────────────────────────────────
get_services() {
  local results=()
  IFS=',' read -ra svc_list <<< "$SERVICES"
  for svc in "${svc_list[@]}"; do
    svc=$(echo "$svc" | tr -d ' ')
    if command -v systemctl &>/dev/null; then
      if systemctl is-active --quiet "$svc" 2>/dev/null; then
        results+=("{\"name\":\"$svc\",\"status\":\"active\"}")
      else
        results+=("{\"name\":\"$svc\",\"status\":\"inactive\"}")
      fi
    else
      results+=("{\"name\":\"$svc\",\"status\":\"unknown\"}")
    fi
  done
  echo "${results[@]}"
}

# ── Network Status ───────────────────────────────────────────────────────────
get_network() {
  local status="up"
  local latency="N/A"

  if ! ping -c 1 -W 2 8.8.8.8 &>/dev/null 2>&1; then
    status="down"
  else
    latency=$(ping -c 1 8.8.8.8 2>/dev/null | grep 'time=' | awk -F'time=' '{print $2}' | awk '{print $1}' || echo "N/A")
  fi

  local iface
  iface=$(ip route 2>/dev/null | grep '^default' | awk '{print $5}' | head -1 || echo "unknown")
  echo "$status $latency $iface"
}

# ── Top Processes ─────────────────────────────────────────────────────────────
get_top_processes() {
  ps aux --no-headers --sort=-%cpu 2>/dev/null | head -5 | awk '{
    printf "{\"pid\":%s,\"user\":\"%s\",\"cpu\":%.1f,\"mem\":%.1f,\"cmd\":\"%s\"}", $2, $1, $3, $4, $11
  }' | paste -sd ',' -
}

# ── Collect All Metrics ───────────────────────────────────────────────────────
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

CPU_PCT=$(get_cpu)
read -r MEM_PCT MEM_TOTAL MEM_USED MEM_FREE <<< "$(get_memory)"
read -r DISK_PCT DISK_TOTAL DISK_USED DISK_FREE <<< "$(get_disk)"
read -r NET_STATUS NET_LATENCY NET_IFACE <<< "$(get_network)"
SERVICES_JSON=$(get_services)
TOP_PROCS=$(get_top_processes)

# ── Output ────────────────────────────────────────────────────────────────────
if [[ "$OUTPUT_FORMAT" == "--json" || "$OUTPUT_FORMAT" == "json" ]]; then
  # Build service array
  SVC_ARRAY="[$(IFS=','; echo "${SERVICES_JSON[*]}" | tr ' ' ',')]"
  # Fix: join service JSON objects properly
  SVC_ARRAY=$(get_services | tr ' ' '\n' | paste -sd ',' | sed 's/^/[/' | sed 's/$/]/')

  JSON_OUT=$(cat <<EOF
{
  "timestamp": "$TIMESTAMP",
  "cpu": {
    "usage_pct": $CPU_PCT
  },
  "memory": {
    "usage_pct": $MEM_PCT,
    "total_mb": $MEM_TOTAL,
    "used_mb": $MEM_USED,
    "free_mb": $MEM_FREE
  },
  "disk": {
    "usage_pct": $DISK_PCT,
    "total": "$DISK_TOTAL",
    "used": "$DISK_USED",
    "free": "$DISK_FREE"
  },
  "network": {
    "status": "$NET_STATUS",
    "latency_ms": "$NET_LATENCY",
    "interface": "$NET_IFACE"
  },
  "services": $SVC_ARRAY,
  "top_processes": [${TOP_PROCS}]
}
EOF
)

  echo "$JSON_OUT" | tee "$DATA_FILE"
  log "Metrics collected (JSON). CPU:${CPU_PCT}% MEM:${MEM_PCT}% DISK:${DISK_PCT}%"

else
  # Human-readable output
  echo "============================================"
  echo "  SYSTEM HEALTH REPORT — $(date '+%Y-%m-%d %H:%M:%S')"
  echo "============================================"
  echo ""
  echo "  CPU Usage   : ${CPU_PCT}%"
  echo "  Memory      : ${MEM_PCT}% used (${MEM_USED}MB / ${MEM_TOTAL}MB)"
  echo "  Disk (/)    : ${DISK_PCT}% used (${DISK_USED} / ${DISK_TOTAL})"
  echo "  Network     : ${NET_STATUS} | Latency: ${NET_LATENCY}ms | Interface: ${NET_IFACE}"
  echo ""
  echo "  Services:"
  IFS=',' read -ra svc_list <<< "$SERVICES"
  for svc in "${svc_list[@]}"; do
    svc=$(echo "$svc" | tr -d ' ')
    if command -v systemctl &>/dev/null && systemctl is-active --quiet "$svc" 2>/dev/null; then
      echo "    [✔] $svc"
    else
      echo "    [✘] $svc"
    fi
  done
  echo ""
  echo "  Top Processes (by CPU):"
  ps aux --no-headers --sort=-%cpu 2>/dev/null | head -5 | awk '{printf "    %-8s %-20s CPU:%-6s MEM:%s\n", $2, $11, $3"%", $4"%"}'
  echo "============================================"

  log "Metrics collected (text). CPU:${CPU_PCT}% MEM:${MEM_PCT}% DISK:${DISK_PCT}%"
fi
