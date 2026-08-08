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

echo "==> merging into $SETTINGS"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"

# Backups live in OUR state dir, not in ~/.claude, and only the 5 most
# recent are kept - this tool stays out of other tools' directories.
BACKUP_DIR="$STATE_DIR/backups"
mkdir -p "$BACKUP_DIR"
cp "$SETTINGS" "$BACKUP_DIR/settings.json.bak.$(date +%Y%m%d%H%M%S)"
(ls -t "$BACKUP_DIR"/settings.json.bak.* 2>/dev/null || true) | tail -n +6 | \
  while read -r old; do rm -f "$old"; done

# tmp file in the SAME directory as the target: mv is then an atomic
# rename. mktemp's default $TMPDIR can be a different filesystem, where
# mv degrades to copy+delete and an interrupt truncates settings.json.
tmp=$(mktemp "$SETTINGS.tmp.XXXXXX")
# mktemp creates 0600; restore the target's own mode before the rename.
mode=$(stat -f '%Lp' "$SETTINGS" 2>/dev/null || stat -c '%a' "$SETTINGS")
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

# Refuse to install if the merge produced invalid JSON...
jq -e . "$tmp" >/dev/null || { echo "merge produced invalid JSON, aborting" >&2; rm -f "$tmp"; exit 1; }
# ...or changed ANYTHING outside .hooks.StopFailure (herdr's hooks and
# every other key must survive byte-for-byte). The normalizer also drops
# an empty .hooks container: creating it is the one legitimate side
# effect when a fresh user starts from '{}'.
norm='del(.hooks.StopFailure) | (if ((.hooks // {}) | length) == 0 then del(.hooks) else . end)'
if ! diff -q <(jq -S "$norm" "$SETTINGS") \
             <(jq -S "$norm" "$tmp") >/dev/null; then
  echo "merge touched something outside .hooks.StopFailure, aborting" >&2
  rm -f "$tmp"; exit 1
fi
chmod "$mode" "$tmp"
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
