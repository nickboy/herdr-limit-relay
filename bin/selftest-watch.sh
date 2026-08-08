#!/usr/bin/env bash
# Weekly guard, run from launchd: herdr is pre-1.0 and CI runners have
# no herdr, so the CLI-surface drift selftest.sh detects is invisible
# to CI - the most likely way this project dies is a herdr upgrade
# quietly breaking the daemons. Runs the full selftest (including hook
# registration) and notifies on any failure.

set -uo pipefail

HERDR="${HERDR_BIN_PATH:-herdr}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if out=$("$DIR/selftest.sh" --post-install 2>&1); then
  echo "selftest ok"
  exit 0
fi

# grep -c exits 1 on zero matches (selftest can fail its prereq checks
# without printing FAIL); default to 0 explicitly - same future-set -e
# reasoning as the log-rotation if above.
fails=$(printf '%s\n' "$out" | grep -c FAIL) || fails=0
body="$fails check(s) failing after herdr/claude update - run selftest.sh"

"$HERDR" notification show "herdr-limit-relay selftest FAILED" \
  --body "$body" --sound request >/dev/null 2>&1 || true
if command -v osascript >/dev/null 2>&1; then
  osascript -e "display notification \"$body\" with title \"herdr-limit-relay selftest FAILED\"" 2>/dev/null
fi

printf '%s\n' "$out"
exit 1
