#!/usr/bin/env bash
# Installs the StopFailure hook into ~/.claude/settings.json WITHOUT clobbering
# the entries herdr's own `integration install claude` already wrote there.

set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SETTINGS="$CLAUDE_DIR/settings.json"
HOOK_DEST="$CLAUDE_DIR/hooks/limit-watch.sh"
STATE_DIR="${HERDR_LIMIT_STATE:-$HOME/.herdr-limit}"

command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }
[ -d "$CLAUDE_DIR" ] || { echo "$CLAUDE_DIR does not exist. Run claude once first." >&2; exit 1; }

echo "==> installing hook"
mkdir -p "$CLAUDE_DIR/hooks" "$STATE_DIR"
install -m 0755 "$SRC/hooks/limit-watch.sh" "$HOOK_DEST"
chmod +x "$SRC/bin/"*.sh

echo "==> merging into $SETTINGS"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
cp "$SETTINGS" "$SETTINGS.bak.$(date +%Y%m%d%H%M%S)"

tmp=$(mktemp)
jq --arg cmd "$HOOK_DEST" '
  .hooks //= {}
  | .hooks.StopFailure //= []
  # drop any previous copy of OUR entry, keep everything else (incl. herdr'"'"'s)
  | .hooks.StopFailure |= (
      map(select(([.hooks[]?.command] | index($cmd)) | not))
      + [{
          matcher: "rate_limit",
          hooks: [{ type: "command", command: $cmd, args: [] }]
        }]
    )
' "$SETTINGS" > "$tmp"

# Refuse to install if the merge produced invalid JSON or lost herdr's hooks.
jq -e . "$tmp" >/dev/null || { echo "merge produced invalid JSON, aborting" >&2; exit 1; }
mv "$tmp" "$SETTINGS"

echo
echo "==> done"
echo
echo "verify:"
echo "  $SRC/bin/selftest.sh --post-install"
echo "  jq '.hooks.StopFailure' $SETTINGS"
echo "  herdr integration status        # Claude Code integration should be >= 6"
echo
echo "run Option A (local resume):"
echo "  $SRC/bin/resumer.sh"
echo
echo "run Option B (cross-provider relay), in a second pane:"
echo "  RELAY_AGENT_KIND=codex $SRC/bin/relay.sh"
echo
echo "add the dead man's switch (macOS: launchd, Linux: cron — see README,"
echo "  'Dead man's switch'; NOTE crontab hangs on TCC when run over SSH)"
