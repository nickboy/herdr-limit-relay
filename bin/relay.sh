#!/usr/bin/env bash
# Option B: while Claude is rate-limited, hand relay-safe work to a different
# provider (Codex / Grok / Gemini) in an isolated git worktree.
#
# Run this ALONGSIDE resumer.sh, not instead of it. relay.sh only starts the
# stand-in; resumer.sh still brings Claude back and points it at the branch.
#
# The two providers never share a working tree. Cross-provider edits to the same
# checkout is the single fastest way to lose work.

set -uo pipefail

HERDR="${HERDR_BIN_PATH:-herdr}"
STATE_DIR="${HERDR_LIMIT_STATE:-$HOME/.herdr-limit}"
LEDGER="$STATE_DIR/ledger.jsonl"
RELAY_STATE="$STATE_DIR/relay.json"
HEARTBEAT="$STATE_DIR/relay-heartbeat"
LOG="$STATE_DIR/relay.log"

AGENT_KIND="${RELAY_AGENT_KIND:-codex}"
POLL="${RELAY_POLL_SECONDS:-60}"
MAX_CONCURRENT="${RELAY_MAX_CONCURRENT:-1}"
TIMEOUT_MS="${RELAY_TIMEOUT_MS:-10800000}"   # 3h
BRANCH_PREFIX="${RELAY_BRANCH_PREFIX:-nightshift}"

RELAY_LOCK="$STATE_DIR/.relay-state.lock"

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"
# Explicit if (see resumer.sh): a bare && list returns 1 when the log
# does not exist yet, which becomes a restart loop under a future set -e.
if [ -f "$LOG" ] && [ "$(wc -c < "$LOG" | tr -d ' ')" -gt 1048576 ]; then
  mv "$LOG" "$LOG.old"
fi
log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG"; }

# relay.json is read-modified-written both by the main loop (record) and by
# the fire-and-forget wait subshells (mark_done). Same mkdir-lock pattern as
# the ledger in resumer.sh; readers don't need it because writers replace the
# file atomically via mv.
with_state_lock() {
  for _ in $(seq 1 100); do
    mkdir "$RELAY_LOCK" 2>/dev/null && return 0
    sleep 0.1
  done
  log "WARN could not acquire relay state lock"
  return 1
}

unlock_state() { rmdir "$RELAY_LOCK" 2>/dev/null || true; }

read_prompt() {
  # Same-origin content: templates/RELAY-CONTRACT.md mirrors this prompt.
  # If you change one, change the other.
  cat <<'PROMPT'
You are a stand-in agent. The primary agent (Claude Code) is rate-limited and
will return later to review your work. Follow these rules exactly.

SCOPE
- Read TASKS.md in the repository root.
- Work ONLY on items tagged [relay-safe]. Ignore every other item.
- If there are no [relay-safe] items, write that fact to RELAY-LOG.md and stop.

RULES
- Do not refactor across files. Do not change schemas, migrations, CI config,
  deployment config, dependency versions, or public APIs.
- Make one focused commit per task. Message format: "relay: <task summary>".
- Run the project's test command after each task. If tests fail and you cannot
  fix them inside the same task's scope, revert that commit and move on.
- Do not merge, rebase, force-push, or touch any branch other than the current
  one. Do not push.

REPORTING
- Append to RELAY-LOG.md after every task:
    ## <task>
    - what changed:
    - tests:
    - anything the primary agent must double-check:
- Mark finished items in TASKS.md as [relay-done] (not [x]) so the primary agent
  knows to review rather than assume.

When there is nothing left in scope, write a final summary to RELAY-LOG.md and
stop. Do not invent new work.
PROMPT
}

active_count() {
  [ -f "$RELAY_STATE" ] || { echo 0; return; }
  jq -r '[.[] | select(.status == "running")] | length' "$RELAY_STATE" 2>/dev/null || echo 0
}

already_relayed() {
  [ -f "$RELAY_STATE" ] || return 1
  jq -e --arg cwd "$1" 'any(.[]; .cwd == $cwd and .status == "running")' \
    "$RELAY_STATE" >/dev/null 2>&1
}

record() {
  local tmp; tmp=$(mktemp "$STATE_DIR/.relay.XXXXXX")
  with_state_lock || { rm -f "$tmp"; return 1; }
  [ -f "$RELAY_STATE" ] || echo '[]' > "$RELAY_STATE"
  jq --argjson e "$1" '. + [$e]' "$RELAY_STATE" > "$tmp" && mv "$tmp" "$RELAY_STATE"
  unlock_state
}

mark_done() {
  local tmp; tmp=$(mktemp "$STATE_DIR/.relay.XXXXXX")
  with_state_lock || { rm -f "$tmp"; return 1; }
  jq --arg ws "$1" --arg st "$2" \
    'map(if .workspace == $ws then .status = $st else . end)' \
    "$RELAY_STATE" > "$tmp" && mv "$tmp" "$RELAY_STATE"
  unlock_state
}

start_relay() {
  local cwd="$1" branch created ws root name

  # Must be a git repo with a clean-enough state to branch from.
  git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    log "  $cwd is not a git repo, skipping relay"; return 1; }

  [ -f "$cwd/TASKS.md" ] || {
    log "  no TASKS.md in $cwd, nothing safe to hand over"; return 1; }

  grep -q '\[relay-safe\]' "$cwd/TASKS.md" || {
    log "  no [relay-safe] items in $cwd/TASKS.md, skipping"; return 1; }

  branch="${BRANCH_PREFIX}/$(date +%Y%m%d-%H%M)"

  created=$("$HERDR" worktree create --cwd "$cwd" --branch "$branch" \
              --label "relay-${AGENT_KIND}" --no-focus 2>/dev/null) || {
    log "  worktree create failed for $cwd"; return 1; }

  ws=$(printf   '%s' "$created" | jq -r '.result.workspace.workspace_id // empty')
  root=$(printf '%s' "$created" | jq -r '.result.root_pane.pane_id // empty')
  [ -n "$root" ] || { log "  could not read worktree pane id"; return 1; }

  name="relay-$(date +%H%M%S)"
  if ! "$HERDR" agent start "$name" --kind "$AGENT_KIND" --pane "$root" \
        --timeout 120000 >/dev/null 2>&1; then
    log "  agent start ($AGENT_KIND) failed in $root"
    return 1
  fi

  log "  started $AGENT_KIND as $name on $branch (workspace $ws)"
  record "$(jq -nc --arg ws "$ws" --arg pane "$root" --arg name "$name" \
              --arg cwd "$cwd" --arg branch "$branch" --arg kind "$AGENT_KIND" \
              '{workspace:$ws, pane:$pane, agent:$name, cwd:$cwd,
                branch:$branch, kind:$kind, status:"running",
                started_at:(now|floor)}')"

  "$HERDR" notification show "Relay started" \
    --body "$AGENT_KIND on $branch" --sound none >/dev/null 2>&1 || true

  # Fire and forget; the wait runs in a subshell so one long relay doesn't
  # block detection of other limited sessions.
  (
    if "$HERDR" agent prompt "$name" "$(read_prompt)" \
         --wait --until idle --until "done" --timeout "$TIMEOUT_MS" >/dev/null 2>&1; then
      log "relay $name finished on $branch"
      mark_done "$ws" "finished"
      "$HERDR" notification show "Relay finished" \
        --body "$branch ready for review" --sound "done" >/dev/null 2>&1 || true
    else
      log "relay $name ended with an error on $branch"
      mark_done "$ws" "error"
    fi
  ) &
}

# --- main -------------------------------------------------------------------

main() {
command -v jq  >/dev/null 2>&1 || { echo "jq required" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "git required" >&2; exit 2; }
"$HERDR" status >/dev/null 2>&1 || { echo "herdr server not reachable" >&2; exit 2; }

log "relay started (kind=$AGENT_KIND max_concurrent=$MAX_CONCURRENT)"
trap 'log "relay stopping"; unlock_state; exit 0' INT TERM

while true; do
  date +%s > "$HEARTBEAT"

  if [ -s "$LEDGER" ]; then
    # Read without draining: resumer.sh owns the ledger lifecycle.
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      cwd=$(jq -r '.cwd' <<<"$line" 2>/dev/null) || continue
      [ -n "$cwd" ] || continue

      already_relayed "$cwd" && continue
      [ "$(active_count)" -lt "$MAX_CONCURRENT" ] || continue

      log "limited session in $cwd, considering relay"
      start_relay "$cwd" || true
    done < "$LEDGER"
  fi

  sleep "$POLL"
done
}

# Run the daemon only when executed directly. bin/test-relay-state.sh sources
# this file to unit-test the relay.json helpers without starting the loop.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main
fi
