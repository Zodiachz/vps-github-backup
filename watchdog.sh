#!/usr/bin/env bash
# Run hourly from cron. Alerts on Discord when no backup has succeeded for
# STALE_HOURS (cron removed, server down at backup time, script hung...).
# Re-alerts at most every 12 hours.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${1:-$HERE/backup.conf}"
STATE_DIR=/var/lib/vps-github-backup
STALE_HOURS=26
source "$CONF"
export DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}" DISCORD_BOT_TOKEN="${DISCORD_BOT_TOKEN:-}" \
       DISCORD_USER_IDS="${DISCORD_USER_IDS:-}"

now=$(date +%s)
mkdir -p "$STATE_DIR"
# fresh install: start the grace period now instead of alerting right away
[ -f "$STATE_DIR/last_ok" ] || { echo "$now" > "$STATE_DIR/last_ok"; exit 0; }
last=$(cat "$STATE_DIR/last_ok" 2>/dev/null || echo 0)
age_h=$(( (now - last) / 3600 ))
if [ "$age_h" -lt "$STALE_HOURS" ]; then
  rm -f "$STATE_DIR/watchdog_alerted"
  exit 0
fi
alerted=$(cat "$STATE_DIR/watchdog_alerted" 2>/dev/null || echo 0)
[ $(( now - alerted )) -lt 43200 ] && exit 0

if [ "$last" = 0 ]; then when="never"; else when="$(date -u -d "@$last" +%Y-%m-%dT%H:%MZ) (${age_h} h ago)"; fi
python3 "$HERE/notify.py" "🟠 **No successful backup on $(hostname) for more than ${STALE_HOURS} h**
Last success: $when" && echo "$now" > "$STATE_DIR/watchdog_alerted"
