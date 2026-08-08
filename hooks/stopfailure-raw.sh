#!/usr/bin/env bash
# Diagnostic StopFailure hook, NO matcher: appends every raw payload to
# stopfailure-raw.jsonl. The StopFailure input schema is undocumented
# (anthropics/claude-code#35620); the first real event recorded here
# answers what limit-watch.sh's "rate_limit" matcher premise can only
# assume: the actual field names, the matcher value, and whether a
# reset time is present. Costs nothing until an event fires.

set -uo pipefail

input=$(cat)

# Same no-op contract as limit-watch.sh: leave zero trace outside herdr.
[ "${HERDR_ENV:-}" = "1" ] || exit 0

dir="${HERDR_LIMIT_STATE:-$HOME/.herdr-limit}"
mkdir -p "$dir"

if command -v jq >/dev/null 2>&1 && jq -e . >/dev/null 2>&1 <<<"$input"; then
  jq -c '. + {logged_at: (now | floor)}' <<<"$input" >> "$dir/stopfailure-raw.jsonl"
else
  printf '%s\n' "$input" >> "$dir/stopfailure-raw.jsonl"
fi

exit 0
