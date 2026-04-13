#!/bin/bash
# =============================================================================
# alerts/alert.sh  —  Threshold-based alerting with cooldown
# Sends email and/or Slack notifications when metrics exceed thresholds.
# Cooldown prevents alert spam (one alert per category per COOLDOWN seconds).
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# ── Load Config ───────────────────────────────────────────────────────────────
if [[ -f "$PROJECT_DIR/.env" ]]; then
  export $(grep -v '^#' "$PROJECT_DIR/.env" | xargs 2>/dev/null || true)
fi

DATA_FILE="${DATA_FILE:-$PROJECT_DIR/data/metrics.json}"
LOG_FILE="${LOG_FILE:-$PROJECT_DIR/logs/alerts.log}"
COOLDOWN_DIR="${PROJECT_DIR}/data/cooldowns"

CPU_THRESHOLD="${ALERT_CPU_THRESHOLD:-85}"
MEM_THRESHOLD="${ALERT_MEM_THRESHOLD:-85}"
DISK_THRESHOLD="${ALERT_DISK_THRESHOLD:-90}"
COOLDOWN="${ALERT_COOLDOWN_SECONDS:-300}"   # 5 minutes default

ALERT_EMAIL="${ALERT_EMAIL:-}"
SMTP_FROM="${SMTP_FROM:-monitor@localhost}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
HOSTNAME_LABEL=$(hostname)

mkdir -p "$(dirname "$LOG_FILE")" "$COOLDOWN_DIR"

# ── Logging ───────────────────────────────────────────────────────────────────
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# ── Cooldown Guard ────────────────────────────────────────────────────────────
# Returns 0 (allow alert) if cooldown has expired; 1 (suppress) if still active.
cooldown_ok() {
  local key="$1"
  local stamp_file="$COOLDOWN_DIR/${key}.last"

  if [[ -f "$stamp_file" ]]; then
    local last_sent
    last_sent=$(cat "$stamp_file")
    local now
    now=$(date +%s)
    if (( now - last_sent < COOLDOWN )); then
      return 1   # still cooling down
    fi
  fi

  date +%s > "$stamp_file"
  return 0
}

# ── Send Email ────────────────────────────────────────────────────────────────
send_email() {
  local subject="$1"
  local body="$2"

  if [[ -z "$ALERT_EMAIL" ]]; then
    log "WARN  Email not configured (ALERT_EMAIL unset). Skipping."
    return
  fi

  if ! command -v mail &>/dev/null && ! command -v sendmail &>/dev/null; then
    log "WARN  Neither 'mail' nor 'sendmail' found. Install mailutils: sudo apt install mailutils"
    return
  fi

  if command -v mail &>/dev/null; then
    echo "$body" | mail -s "$subject" -a "From: $SMTP_FROM" "$ALERT_EMAIL"
    log "INFO  Email sent to $ALERT_EMAIL — Subject: $subject"
  else
    {
      echo "From: $SMTP_FROM"
      echo "To: $ALERT_EMAIL"
      echo "Subject: $subject"
      echo ""
      echo "$body"
    } | sendmail -t
    log "INFO  Email (sendmail) sent to $ALERT_EMAIL — Subject: $subject"
  fi
}

# ── Send Slack ────────────────────────────────────────────────────────────────
send_slack() {
  local message="$1"

  if [[ -z "$SLACK_WEBHOOK" ]]; then
    return   # silently skip if not configured
  fi

  if ! command -v curl &>/dev/null; then
    log "WARN  curl not found — cannot send Slack alert"
    return
  fi

  local payload
  payload=$(printf '{"text": "%s"}' "$message")

  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST -H 'Content-type: application/json' \
    --data "$payload" \
    "$SLACK_WEBHOOK" || echo "000")

  if [[ "$http_code" == "200" ]]; then
    log "INFO  Slack notification sent"
  else
    log "WARN  Slack notification failed (HTTP $http_code)"
  fi
}

# ── Fire Alert ────────────────────────────────────────────────────────────────
fire_alert() {
  local key="$1"     # cooldown key: cpu / memory / disk
  local subject="$2"
  local body="$3"
  local emoji="$4"

  if cooldown_ok "$key"; then
    log "ALERT [$key] $subject"
    send_email "$subject" "$body"
    send_slack "$emoji *[$HOSTNAME_LABEL]* $subject"
  else
    log "INFO  [$key] Alert suppressed (cooldown active)"
  fi
}

# ── Read Metrics ──────────────────────────────────────────────────────────────
if [[ ! -f "$DATA_FILE" ]]; then
  log "WARN  Metrics file not found: $DATA_FILE — running health check first"
  bash "$PROJECT_DIR/scripts/health_check.sh" --json > /dev/null 2>&1 || true
fi

if [[ ! -f "$DATA_FILE" ]]; then
  log "ERROR Cannot read metrics. Exiting."
  exit 1
fi

CPU_PCT=$(python3 -c "import json,sys; d=json.load(open('$DATA_FILE')); print(d['cpu']['usage_pct'])" 2>/dev/null || echo "0")
MEM_PCT=$(python3 -c "import json,sys; d=json.load(open('$DATA_FILE')); print(d['memory']['usage_pct'])" 2>/dev/null || echo "0")
DISK_PCT=$(python3 -c "import json,sys; d=json.load(open('$DATA_FILE')); print(d['disk']['usage_pct'])" 2>/dev/null || echo "0")
TIMESTAMP=$(python3 -c "import json,sys; d=json.load(open('$DATA_FILE')); print(d.get('timestamp','N/A'))" 2>/dev/null || echo "N/A")

log "INFO  Checking — CPU:${CPU_PCT}% MEM:${MEM_PCT}% DISK:${DISK_PCT}%"

# ── CPU Check ─────────────────────────────────────────────────────────────────
if (( CPU_PCT >= CPU_THRESHOLD )); then
  fire_alert "cpu" \
    "[ALERT] High CPU on $HOSTNAME_LABEL — ${CPU_PCT}%" \
    "$(printf 'HIGH CPU ALERT\n\nHost: %s\nCPU Usage: %s%%\nThreshold: %s%%\nTime: %s\n\nPlease investigate.' "$HOSTNAME_LABEL" "$CPU_PCT" "$CPU_THRESHOLD" "$TIMESTAMP")" \
    "🔥"
fi

# ── Memory Check ──────────────────────────────────────────────────────────────
if (( MEM_PCT >= MEM_THRESHOLD )); then
  fire_alert "memory" \
    "[ALERT] High Memory on $HOSTNAME_LABEL — ${MEM_PCT}%" \
    "$(printf 'HIGH MEMORY ALERT\n\nHost: %s\nMemory Usage: %s%%\nThreshold: %s%%\nTime: %s\n\nPlease investigate.' "$HOSTNAME_LABEL" "$MEM_PCT" "$MEM_THRESHOLD" "$TIMESTAMP")" \
    "🧠"
fi

# ── Disk Check ────────────────────────────────────────────────────────────────
if (( DISK_PCT >= DISK_THRESHOLD )); then
  fire_alert "disk" \
    "[ALERT] High Disk Usage on $HOSTNAME_LABEL — ${DISK_PCT}%" \
    "$(printf 'HIGH DISK ALERT\n\nHost: %s\nDisk Usage: %s%%\nThreshold: %s%%\nTime: %s\n\nPlease investigate.' "$HOSTNAME_LABEL" "$DISK_PCT" "$DISK_THRESHOLD" "$TIMESTAMP")" \
    "💾"
fi

log "INFO  Alert check complete"
