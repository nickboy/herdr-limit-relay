#!/usr/bin/env bash
# Dead man's switch. Run hourly from cron.
#
# herdr is pre-1.0 with an actively bumping socket protocol. The failure mode
# that actually hurts is silent: the daemon dies or an API call starts erroring,
# and you find out the next morning when nothing got done. This catches that.

set -uo pipefail

HERDR="${HERDR_BIN_PATH:-herdr}"
STATE_DIR="${HERDR_LIMIT_STATE:-$HOME/.herdr-limit}"
POLL="${RESUME_POLL_SECONDS:-300}"
STALE=$(( POLL * 3 ))

now=$(date +%s)
# A plain string, not an array: empty-array expansion under `set -u`
# errors on bash 3.2 (macOS default), and this script must run under
# whatever bash cron/launchd hands it.
problems=""

add_problem() { problems="${problems:+$problems; }$1"; }

check_heartbeat() {
  local file="$1" label="$2"
  if [ ! -f "$file" ]; then
    add_problem "$label never started"
    return
  fi
  local last age
  last=$(cat "$file" 2>/dev/null || echo 0)
  age=$(( now - last ))
  if [ "$age" -gt "$STALE" ]; then
    add_problem "$label stale (${age}s, threshold ${STALE}s)"
  fi
}

check_heartbeat "$STATE_DIR/heartbeat" "resumer"
[ -f "$STATE_DIR/relay-heartbeat" ] && \
  check_heartbeat "$STATE_DIR/relay-heartbeat" "relay"

# Queued work that nobody is draining is the other silent failure.
if [ -s "$STATE_DIR/ledger.jsonl" ]; then
  oldest=$(jq -rs 'min_by(.queued_at) | .queued_at' "$STATE_DIR/ledger.jsonl" 2>/dev/null || echo "$now")
  waited=$(( now - oldest ))
  if [ "$waited" -gt 25200 ]; then   # 7h > any 5h window + slack
    add_problem "session queued for $(( waited / 3600 ))h without resuming"
  fi
fi

"$HERDR" status >/dev/null 2>&1 || add_problem "herdr server unreachable"

if [ -n "$problems" ]; then
  body="$problems"
  "$HERDR" notification show "Auto-resume unhealthy" \
    --body "$body" --sound request >/dev/null 2>&1 || true
  # Fallback for when herdr itself is the thing that is down.
  command -v osascript >/dev/null 2>&1 && \
    osascript -e "display notification \"$body\" with title \"Auto-resume unhealthy\"" 2>/dev/null
  command -v notify-send >/dev/null 2>&1 && \
    notify-send "Auto-resume unhealthy" "$body" 2>/dev/null
  echo "UNHEALTHY: $body" >&2
  exit 1
fi

echo "ok"
