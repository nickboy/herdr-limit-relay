#!/usr/bin/env bash
# Option A: wake rate-limited Claude Code sessions once the window resets.
#
# Consumes no tokens except a tiny haiku probe every RESUME_POLL_SECONDS.
# Everything else is herdr CLI calls against the local socket.

set -uo pipefail

HERDR="${HERDR_BIN_PATH:-herdr}"
STATE_DIR="${HERDR_LIMIT_STATE:-$HOME/.herdr-limit}"
LEDGER="$STATE_DIR/ledger.jsonl"
LOCK="$STATE_DIR/.ledger.lock"
HEARTBEAT="$STATE_DIR/heartbeat"
LOG="$STATE_DIR/resumer.log"

POLL="${RESUME_POLL_SECONDS:-300}"
PROBE_MODEL="${RESUME_PROBE_MODEL:-haiku}"
MAX_ATTEMPTS="${RESUME_MAX_ATTEMPTS:-5}"
TIMEOUT_MS="${RESUME_TIMEOUT_MS:-1800000}"
BROKEN_ALERT_AFTER="${RESUME_PROBE_BROKEN_ALERT:-3}"
RESUME_MESSAGE="${RESUME_MESSAGE:-Continue where you left off. If the task is already complete, reply DONE and stop.}"

mkdir -p "$STATE_DIR"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG"; }

notify() {
  "$HERDR" notification show "$1" --body "${2:-}" --sound "${3:-none}" \
    >/dev/null 2>&1 || true
}

preflight() {
  command -v jq >/dev/null 2>&1 || { echo "jq required" >&2; exit 2; }
  command -v claude >/dev/null 2>&1 || { echo "claude required" >&2; exit 2; }
  "$HERDR" status >/dev/null 2>&1 || {
    echo "herdr server not reachable. Start herdr first." >&2; exit 2; }
}

# --- ledger helpers ---------------------------------------------------------

with_lock() {
  for _ in $(seq 1 100); do
    mkdir "$LOCK" 2>/dev/null && return 0
    sleep 0.1
  done
  log "WARN could not acquire ledger lock, skipping this pass"
  return 1
}

unlock() { rmdir "$LOCK" 2>/dev/null || true; }

# Atomically take the whole ledger and empty it. Failures get requeued.
drain_ledger() {
  with_lock || return 1
  if [ -s "$LEDGER" ]; then
    cat "$LEDGER"
    : > "$LEDGER"
  fi
  unlock
}

requeue() {
  with_lock || return 1
  printf '%s\n' "$1" >> "$LEDGER"
  unlock
}

# --- probe ------------------------------------------------------------------

# Run from a neutral directory OUTSIDE $HOME: Claude Code reads CLAUDE.md from
# the cwd and its ancestors, so probing from anywhere under $HOME would load
# the user's global instructions into every probe and make a "tiny" probe not
# tiny.
#
# Return codes:
#   0 lifted  - probe succeeded, quota is back
#   1 limited - probe failed with a limit-shaped error (expected while queued)
#   2 broken  - probe failed for a non-limit reason (network, auth, CLI bug).
#               NOT evidence the limit is still on; alerted on separately.
probe_quota() {
  local out rc
  out=$( cd "${TMPDIR:-/tmp}" && \
    timeout 60 claude -p "Reply with exactly: OK" --model "$PROBE_MODEL" 2>&1 )
  rc=$?
  [ "$rc" -eq 0 ] && return 0
  if printf '%s' "$out" | grep -qiE 'limit|quota|too many requests|overloaded|429'; then
    return 1
  fi
  log "probe failed for a non-limit reason (rc=$rc): $(printf '%s' "$out" | head -c 200)"
  return 2
}

# --- resume paths -----------------------------------------------------------

# Deliberately checks exit codes rather than parsing JSON field names: herdr is
# pre-1.0 and field names move between releases. Exit codes are stable.
pane_alive() {
  "$HERDR" agent get "$1" >/dev/null 2>&1
}

# Path 1: the pane still holds a live Claude. Prompt it in place.
#
# `agent prompt` resolves the live agent and refuses if that agent no longer
# controls the pane, so a recycled pane id can never receive a stray message.
resume_in_place() {
  local pane="$1" err
  err=$("$HERDR" agent prompt "$pane" "$RESUME_MESSAGE" \
          --wait --until idle --until "done" --timeout "$TIMEOUT_MS" 2>&1 >/dev/null)
  local rc=$?

  if [ $rc -eq 0 ]; then
    return 0
  fi

  # herdr requires an observed lifecycle change within 5s of a prompt sent from
  # a non-working state. A stall usually means the limit is not actually lifted.
  if printf '%s' "$err" | grep -q 'agent_prompt_stalled'; then
    log "  stalled (agent did not start working) - will retry next pass"
    return 1
  fi

  log "  prompt failed: $(printf '%s' "$err" | head -c 200)"
  return 1
}

# Path 2: the pane is gone (herdr restarted, tab closed, machine rebooted).
# Create a fresh workspace at the original cwd and resume by session id.
resume_respawn() {
  local sid="$1" cwd="$2" created root name

  [ -d "$cwd" ] || { log "  cwd gone: $cwd"; return 1; }

  created=$("$HERDR" workspace create --cwd "$cwd" --label "resumed" --no-focus 2>/dev/null) \
    || { log "  workspace create failed"; return 1; }

  root=$(printf '%s' "$created" | jq -r '.result.root_pane.pane_id // empty')
  [ -n "$root" ] || { log "  could not read new pane id"; return 1; }

  # agent names must match [a-z][a-z0-9_-]{0,31}
  name="r$(printf '%s' "$sid" | tr '[:upper:]' '[:lower:]' | tr -dc 'a-z0-9' | cut -c1-20)"

  if ! "$HERDR" agent start "$name" --kind claude --pane "$root" \
        --timeout 120000 -- --resume "$sid" >/dev/null 2>&1; then
    log "  agent start failed in $root"
    return 1
  fi

  log "  respawned $sid as $name in $root"
  "$HERDR" agent prompt "$name" "$RESUME_MESSAGE" \
    --wait --until idle --until "done" --timeout "$TIMEOUT_MS" >/dev/null 2>&1
}

clear_limit_badge() {
  "$HERDR" pane report-metadata "$1" \
    --source user:claude-limit \
    --agent claude \
    --clear-token limit \
    --clear-state-labels >/dev/null 2>&1 || true
}

resume_one() {
  local entry="$1"
  local pane sid cwd attempts
  pane=$(jq -r '.pane'       <<<"$entry")
  sid=$(jq  -r '.session_id' <<<"$entry")
  cwd=$(jq  -r '.cwd'        <<<"$entry")
  attempts=$(jq -r '.attempts // 0' <<<"$entry")

  if [ "$attempts" -ge "$MAX_ATTEMPTS" ]; then
    log "GIVE UP $sid after $attempts attempts"
    notify "Auto-resume gave up" "$pane / $sid" request
    return 0
  fi

  log "resuming $pane ($sid), attempt $((attempts + 1))"

  if pane_alive "$pane"; then
    if resume_in_place "$pane"; then
      log "  resumed in place"
      clear_limit_badge "$pane"
      notify "Claude resumed" "$pane" "done"
      return 0
    fi
  else
    log "  pane $pane is gone, respawning"
    if resume_respawn "$sid" "$cwd"; then
      notify "Claude respawned" "$sid" "done"
      return 0
    fi
  fi

  requeue "$(jq -c '.attempts = (.attempts // 0) + 1' <<<"$entry")"
  return 1
}

# --- main -------------------------------------------------------------------

main() {
preflight
log "resumer started (poll=${POLL}s probe=${PROBE_MODEL} max_attempts=${MAX_ATTEMPTS})"

trap 'log "resumer stopping"; unlock; exit 0' INT TERM

broken_streak=0

while true; do
  date +%s > "$HEARTBEAT"

  if [ -s "$LEDGER" ]; then
    probe_quota
    probe_rc=$?
    case "$probe_rc" in
      0)
        broken_streak=0
        log "limit appears lifted, draining ledger"
        pending=$(drain_ledger) || pending=""
        if [ -n "$pending" ]; then
          while IFS= read -r line; do
            [ -n "$line" ] || continue
            resume_one "$line" || true
          done <<< "$pending"
        fi
        ;;
      1)
        broken_streak=0
        count=$(wc -l < "$LEDGER" | tr -d ' ')
        log "still limited, $count session(s) queued"
        ;;
      *)
        # Resumption still requires a successful probe; this branch only
        # surfaces that the probe itself looks broken instead of waiting
        # silently until healthcheck's queued-too-long alarm.
        broken_streak=$((broken_streak + 1))
        if [ "$broken_streak" -eq "$BROKEN_ALERT_AFTER" ]; then
          notify "Auto-resume probe broken" \
            "probe failing for non-limit reasons; see resumer.log" request
        fi
        ;;
    esac
  fi

  sleep "$POLL"
done
}

# Run the daemon only when executed directly. bin/test-probe.sh sources this
# file to unit-test probe_quota() without starting the loop.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main
fi
