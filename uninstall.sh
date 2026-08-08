#!/usr/bin/env bash
# Reverses install.sh: removes OUR StopFailure entry from
# ~/.claude/settings.json (preserving everything else, including herdr's
# own hooks) and deletes the copied hook file. Leaves ~/.herdr-limit and
# any daemons/launchd agents/cron entries alone - those were not created
# by install.sh.

set -euo pipefail

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SETTINGS="$CLAUDE_DIR/settings.json"
HOOK_DEST="$CLAUDE_DIR/hooks/limit-watch.sh"

command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }

if [ ! -f "$SETTINGS" ]; then
  echo "no $SETTINGS - nothing to do"
else
  echo "==> removing our StopFailure entry from $SETTINGS"
  cp "$SETTINGS" "$SETTINGS.bak.$(date +%Y%m%d%H%M%S)"

  tmp=$(mktemp)
  jq --arg cmd "$HOOK_DEST" '
    if .hooks.StopFailure? then
      .hooks.StopFailure |= map(select(([.hooks[]?.command] | index($cmd)) | not))
      | (if (.hooks.StopFailure | length) == 0 then del(.hooks.StopFailure) else . end)
    else . end
  ' "$SETTINGS" > "$tmp"

  # Refuse to proceed if the edit produced invalid JSON.
  jq -e . "$tmp" >/dev/null || { echo "edit produced invalid JSON, aborting" >&2; exit 1; }
  mv "$tmp" "$SETTINGS"
fi

if [ -f "$HOOK_DEST" ]; then
  echo "==> removing $HOOK_DEST"
  rm -f "$HOOK_DEST"
fi

echo
echo "==> done. Not touched (remove yourself if wanted):"
echo "  ~/.herdr-limit/                      # ledger, logs, heartbeats"
echo "  any resumer/relay daemons, launchd agents, or cron entries"
echo "  herdr's own claude integration (herdr integration uninstall claude)"
