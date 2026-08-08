#!/usr/bin/env bash
# Run this after every `herdr update`. It verifies that the exact CLI surface
# these scripts depend on still exists, before you find out at 3am that it
# doesn't. Nothing here consumes model tokens.
#
# Default run checks prerequisites only, so it passes on a fresh clone.
# After ./install.sh, run `selftest.sh --post-install` to also verify the
# StopFailure hook registration.

set -uo pipefail
HERDR="${HERDR_BIN_PATH:-herdr}"
fail=0
post_install=0
[ "${1:-}" = "--post-install" ] && post_install=1

ok()   { printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=1; }

echo "herdr version: $("$HERDR" --version 2>/dev/null || echo unknown)"
echo

echo "server"
if "$HERDR" status >/dev/null 2>&1; then ok "status"; else bad "status"; fi

echo "commands this project calls"
for c in \
  "agent get" "agent prompt" "agent start" "agent wait" \
  "pane report-metadata" "pane wait-output" \
  "workspace create" "worktree create" "notification show"
do
  # shellcheck disable=SC2086
  if "$HERDR" $c --help >/dev/null 2>&1; then ok "$c"; else bad "$c"; fi
done

echo "flags this project relies on"
has_flag() {  # has_flag <flag> "<subcommand>"
  local flag="$1" cmd="$2"
  # shellcheck disable=SC2086  # $cmd is a deliberately word-split subcommand
  "$HERDR" $cmd --help 2>&1 | grep -q -- "$flag"
}
for spec in \
  "--until:agent prompt" "--wait:agent prompt" "--kind:agent start" \
  "--token:pane report-metadata" "--branch:worktree create"
do
  flag="${spec%%:*}"; cmd="${spec#*:}"
  if has_flag "$flag" "$cmd"; then ok "$cmd $flag"; else bad "$cmd $flag"; fi
done

echo "claude integration"
# The status line for an absent integration still contains the word
# "claude" ("claude: not installed"), so match the line and then make
# sure it isn't the not-installed form.
if "$HERDR" integration status 2>/dev/null | grep -i '^claude:' | grep -qiv 'not installed'; then
  ok "claude integration installed"
  "$HERDR" integration status | grep -i claude | sed 's/^/       /'
else
  bad "claude integration missing - run: herdr integration install claude"
fi

if [ "$post_install" -eq 1 ]; then
  echo "claude hook"
  CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  if jq -e '.hooks.StopFailure // empty' "$CLAUDE_DIR/settings.json" >/dev/null 2>&1; then
    ok "StopFailure hook registered"
  else
    bad "StopFailure hook missing - run ./install.sh"
  fi
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "all good"
else
  echo "SOMETHING MOVED. Check: herdr api schema --json | jq '.' and the 0.8.x"
  echo "changelog before trusting the daemons overnight."
  exit 1
fi
