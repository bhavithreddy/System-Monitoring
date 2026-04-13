#!/bin/bash
# cron/remove_cron.sh — Remove system-monitor cron jobs

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "Removing system-monitor cron jobs..."
crontab -l 2>/dev/null \
  | grep -v "$PROJECT_DIR" \
  | crontab - \
  && echo "Done." || echo "No crontab found."
