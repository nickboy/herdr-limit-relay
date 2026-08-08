#!/usr/bin/env bash
# Offline test for hooks/limit-watch.sh. No herdr, no tokens, CI-ready.
#
# The hook is the single point of failure for the whole system: if it
# silently breaks, the ledger stays empty and nothing ever resumes.
# This exercises it with fake StopFailure payloads.

set -uo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hooks/limit-watch.sh"
fail=0

ok()  { printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=1; }

command -v jq >/dev/null 2>&1 || { echo "jq required" >&2; exit 2; }
[ -x "$HOOK" ] || { echo "$HOOK not found or not executable" >&2; exit 2; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# $1 = payload on stdin; $2.. = VAR=val pairs for the hook's environment.
# The test itself may run inside herdr (where HERDR_ENV/HERDR_PANE_ID are
# already set), so those are scrubbed first and only re-added explicitly —
# otherwise the no-op case can never be exercised.
run_hook() {
  local payload="$1"; shift
  printf '%s' "$payload" | \
    env -u HERDR_ENV -u HERDR_PANE_ID \
      HERDR_LIMIT_STATE="$tmp/state" HERDR_BIN_PATH=/usr/bin/true "$@" "$HOOK"
}

echo "happy path"
if run_hook '{"session_id":"abc-123","cwd":"/tmp/proj"}' \
     HERDR_ENV=1 HERDR_PANE_ID=w1:p1 && \
   jq -e '.session_id == "abc-123" and .pane == "w1:p1" and .cwd == "/tmp/proj"' \
     "$tmp/state/ledger.jsonl" >/dev/null 2>&1; then
  ok "ledger entry written with session_id, pane, cwd"
else
  bad "ledger entry missing or malformed"
fi

echo "dedup path"
run_hook '{"session_id":"abc-123","cwd":"/tmp/proj"}' \
  HERDR_ENV=1 HERDR_PANE_ID=w1:p1
lines=$(wc -l < "$tmp/state/ledger.jsonl" 2>/dev/null | tr -d ' ')
if [ "$lines" = "1" ]; then
  ok "same session queued twice -> 1 ledger line"
else
  bad "expected 1 ledger line after dedup, got ${lines:-none}"
fi

echo "no-op path (outside herdr)"
rm -rf "$tmp/state"
run_hook '{"session_id":"abc-123","cwd":"/tmp/proj"}'   # no HERDR_ENV added
if [ ! -e "$tmp/state" ]; then
  ok "no state dir created when HERDR_ENV is unset"
else
  bad "hook left traces on disk outside herdr"
fi

RAW_HOOK="$(dirname "$HOOK")/stopfailure-raw.sh"

run_raw() {
  local payload="$1"; shift
  printf '%s' "$payload" | \
    env -u HERDR_ENV -u HERDR_PANE_ID \
      HERDR_LIMIT_STATE="$tmp/state" "$@" "$RAW_HOOK"
}

echo "raw logger: capture path"
rm -rf "$tmp/state"
run_raw '{"session_id":"abc-123","cwd":"/tmp/proj"}' HERDR_ENV=1
if jq -e '.session_id == "abc-123" and (.logged_at | type == "number")' \
     "$tmp/state/stopfailure-raw.jsonl" >/dev/null 2>&1; then
  ok "payload captured verbatim with logged_at stamp"
else
  bad "raw payload missing or malformed"
fi

echo "raw logger: append-only (no dedup - every event is data)"
run_raw '{"session_id":"abc-123","cwd":"/tmp/proj"}' HERDR_ENV=1
raw_lines=$(wc -l < "$tmp/state/stopfailure-raw.jsonl" | tr -d ' ')
if [ "$raw_lines" = "2" ]; then
  ok "two events -> two lines"
else
  bad "expected 2 raw lines, got ${raw_lines:-none}"
fi

echo "raw logger: no-op outside herdr"
rm -rf "$tmp/state"
run_raw '{"session_id":"abc-123","cwd":"/tmp/proj"}'
if [ ! -e "$tmp/state" ]; then
  ok "no state dir created when HERDR_ENV is unset"
else
  bad "raw logger left traces outside herdr"
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "all good"
else
  exit 1
fi
