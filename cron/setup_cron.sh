#!/bin/bash
# =============================================================================
# cron/setup_cron.sh  —  Install cron jobs for health checks and alerts
# Run once: bash cron/setup_cron.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

HEALTH_SCRIPT="$PROJECT_DIR/scripts/health_check.sh"
ALERT_SCRIPT="$PROJECT_DIR/alerts/alert.sh"
CRON_LOG="$PROJECT_DIR/logs/cron.log"

# Ensure scripts are executable
chmod +x "$HEALTH_SCRIPT" "$ALERT_SCRIPT"

# Build cron entries
HEALTH_CRON="* * * * * bash $HEALTH_SCRIPT --json >> $CRON_LOG 2>&1"
ALERT_CRON="* * * * * bash $ALERT_SCRIPT >> $CRON_LOG 2>&1"

# Append only if not already present
add_cron() {
  local entry="$1"
  local existing
  existing=$(crontab -l 2>/dev/null || true)
  if echo "$existing" | grep -qF "$entry"; then
    echo "  [skip] Already present: $entry"
  else
    (echo "$existing"; echo "$entry") | crontab -
    echo "  [added] $entry"
  fi
}

echo ""
echo "Installing cron jobs..."
add_cron "$HEALTH_CRON"
add_cron "$ALERT_CRON"
echo ""
echo "Current crontab:"
crontab -l
echo ""
echo "Done. Logs: $CRON_LOG"
