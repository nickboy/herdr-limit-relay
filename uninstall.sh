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
RAW_DEST="$CLAUDE_DIR/hooks/stopfailure-raw.sh"

command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }

if [ ! -f "$SETTINGS" ]; then
  echo "no $SETTINGS - nothing to do"
else
  echo "==> removing our StopFailure entry from $SETTINGS"
  STATE_DIR="${HERDR_LIMIT_STATE:-$HOME/.herdr-limit}"
  BACKUP_DIR="$STATE_DIR/backups"
  mkdir -p "$BACKUP_DIR"
  cp "$SETTINGS" "$BACKUP_DIR/settings.json.bak.$(date +%Y%m%d%H%M%S)"
  (ls -t "$BACKUP_DIR"/settings.json.bak.* 2>/dev/null || true) | tail -n +6 | \
    while read -r old; do rm -f "$old"; done

  # Same-directory tmp file -> atomic rename (see install.sh).
  tmp=$(mktemp "$SETTINGS.tmp.XXXXXX")
  mode=$(stat -c '%a' "$SETTINGS" 2>/dev/null || stat -f '%Lp' "$SETTINGS")
  # Also drop .hooks itself if we emptied it: install.sh starts new users
  # from '{}', and a true round trip must return them to '{}'.
  jq --arg cmd "$HOOK_DEST" --arg raw "$RAW_DEST" '
    if .hooks.StopFailure? then
      .hooks.StopFailure |= map([.hooks[]?.command] as $cs
        | select(((($cs | index($cmd)) != null) or (($cs | index($raw)) != null)) | not))
      | (if (.hooks.StopFailure | length) == 0 then del(.hooks.StopFailure) else . end)
      | (if (.hooks | length) == 0 then del(.hooks) else . end)
    else . end
  ' "$SETTINGS" > "$tmp"

  # Refuse to proceed if the edit produced invalid JSON.
  jq -e . "$tmp" >/dev/null || { echo "edit produced invalid JSON, aborting" >&2; rm -f "$tmp"; exit 1; }
  chmod "$mode" "$tmp"
  mv "$tmp" "$SETTINGS"
fi

for f in "$HOOK_DEST" "$RAW_DEST"; do
  if [ -f "$f" ]; then
    echo "==> removing $f"
    rm -f "$f"
  fi
done

echo
echo "==> done. Not touched (remove yourself if wanted):"
echo "  ~/.herdr-limit/                      # ledger, logs, heartbeats"
echo "  any resumer/relay daemons, launchd agents, or cron entries"
echo "  herdr's own claude integration (herdr integration uninstall claude)"
