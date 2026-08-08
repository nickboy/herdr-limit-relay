#!/usr/bin/env bash
# Claude Code StopFailure hook, matcher: rate_limit
#
# Fires when a turn ends because of a rate-limit API error. Records the stopped
# session in a ledger for the resumer daemon, and surfaces it in herdr's sidebar.
#
# This hook only records. It never resumes anything itself: StopFailure has no
# decision control (its output and exit code are ignored by Claude Code), so the
# actual resume has to come from an out-of-process daemon.

set -uo pipefail

STATE_DIR="${HERDR_LIMIT_STATE:-$HOME/.herdr-limit}"
LEDGER="$STATE_DIR/ledger.jsonl"
LOCK="$STATE_DIR/.ledger.lock"

input=$(cat)

# No-op outside herdr. Keeps the hook harmless if you also run Claude in a
# plain terminal, over SSH, or in CI.
[ "${HERDR_ENV:-}" = "1" ] || exit 0
[ -n "${HERDR_PANE_ID:-}" ] || exit 0

command -v jq >/dev/null 2>&1 || exit 0

mkdir -p "$STATE_DIR"

session_id=$(jq -r '.session_id // empty' <<<"$input" 2>/dev/null)
cwd=$(jq -r '.cwd // empty' <<<"$input" 2>/dev/null)

[ -n "$session_id" ] || exit 0
[ -n "$cwd" ] || cwd="$PWD"

entry=$(jq -nc \
  --arg pane "$HERDR_PANE_ID" \
  --arg sid  "$session_id" \
  --arg cwd  "$cwd" \
  --arg ws   "${HERDR_WORKSPACE_ID:-}" \
  '{pane:$pane, session_id:$sid, cwd:$cwd, workspace:$ws,
    attempts:0, queued_at:(now|floor)}')

# mkdir is atomic on every POSIX filesystem; safer than flock for portability.
for _ in $(seq 1 50); do
  if mkdir "$LOCK" 2>/dev/null; then
    # Replace any existing entry for the same session so a repeated limit hit
    # doesn't queue the same session twice.
    if [ -f "$LEDGER" ]; then
      tmp=$(mktemp "$STATE_DIR/.ledger.XXXXXX")
      jq -c --arg sid "$session_id" 'select(.session_id != $sid)' \
        < "$LEDGER" > "$tmp" 2>/dev/null || : > "$tmp"
      mv "$tmp" "$LEDGER"
    fi
    printf '%s\n' "$entry" >> "$LEDGER"
    rmdir "$LOCK"
    break
  fi
  sleep 0.1
done

HERDR="${HERDR_BIN_PATH:-herdr}"

# Display-only metadata. Deliberately NOT `pane report-agent`: Claude Code is a
# "session identity" integration in herdr, so its idle/working/blocked state is
# owned by herdr's screen-manifest detection. Calling report-agent here would
# seize that lifecycle authority and break both the sidebar and session restore.
"$HERDR" pane report-metadata "$HERDR_PANE_ID" \
  --source user:claude-limit \
  --agent claude \
  --token limit="rate limited" \
  --state-label idle="rate limited - queued" \
  --state-label unknown="rate limited - queued" \
  --ttl-ms 21600000 >/dev/null 2>&1 || true

"$HERDR" notification show "Claude rate limited" \
  --body "$HERDR_PANE_ID queued for auto-resume" \
  --sound request >/dev/null 2>&1 || true

exit 0
