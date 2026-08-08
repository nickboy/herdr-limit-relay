#!/usr/bin/env bash
# Unit tests for the relay.json state helpers in bin/relay.sh. Offline, no
# herdr, no tokens. The concurrency case is the point: record() runs in the
# main loop while mark_done() runs in fire-and-forget subshells, so without
# the state lock parallel writers lose entries.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0

ok()  { printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=1; }

command -v jq >/dev/null 2>&1 || { echo "jq required" >&2; exit 2; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export HERDR_LIMIT_STATE="$tmp/state"

# main() is guarded behind a BASH_SOURCE check; sourcing only loads helpers.
# shellcheck disable=SC1091
source "$ROOT/bin/relay.sh"

entry() {  # entry <n>
  jq -nc --arg n "$1" \
    '{workspace:("ws-" + $n), pane:("p-" + $n), agent:("a-" + $n),
      cwd:("/tmp/proj-" + $n), branch:("b/" + $n), kind:"codex",
      status:"running", started_at:0}'
}

echo "concurrent record()"
N=20
for i in $(seq 1 "$N"); do
  record "$(entry "$i")" &
done
wait
len=$(jq 'length' "$tmp/state/relay.json" 2>/dev/null)
if [ "$len" = "$N" ]; then
  ok "$N parallel writers -> $N entries, none lost"
else
  bad "expected $N entries after parallel record, got ${len:-none}"
fi
if jq -e . "$tmp/state/relay.json" >/dev/null 2>&1; then
  ok "relay.json still valid JSON"
else
  bad "relay.json corrupted"
fi

echo "mark_done()"
mark_done "ws-7" "finished"
if jq -e '.[] | select(.workspace == "ws-7") | .status == "finished"' \
     "$tmp/state/relay.json" >/dev/null; then
  ok "ws-7 marked finished"
else
  bad "mark_done did not update ws-7"
fi
untouched=$(jq '[.[] | select(.workspace != "ws-7") | select(.status == "running")] | length' "$tmp/state/relay.json")
if [ "$untouched" = "$((N - 1))" ]; then
  ok "other $((N - 1)) entries untouched"
else
  bad "mark_done touched other entries ($untouched still running)"
fi

echo "bookkeeping helpers"
if [ "$(active_count)" = "$((N - 1))" ]; then
  ok "active_count sees $((N - 1)) running"
else
  bad "active_count wrong: $(active_count)"
fi
if already_relayed "/tmp/proj-3" && ! already_relayed "/tmp/proj-7"; then
  ok "already_relayed: running yes, finished no"
else
  bad "already_relayed misclassified"
fi

echo "lock hygiene"
if [ ! -d "$tmp/state/.relay-state.lock" ]; then
  ok "no lock dir left behind"
else
  bad "stale lock dir remains"
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "all good"
else
  exit 1
fi
