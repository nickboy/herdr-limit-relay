#!/usr/bin/env bash
# Round-trip test for install.sh + uninstall.sh against a sandboxed
# CLAUDE_CONFIG_DIR. Offline, no herdr, no tokens. Asserts the jq merge
# adds exactly our StopFailure entry (preserving a foreign one), is
# idempotent, and that uninstall restores the original settings
# byte-for-byte (modulo key order) and removes the hook copy.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0

ok()  { printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=1; }

command -v jq >/dev/null 2>&1 || { echo "jq required" >&2; exit 2; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export CLAUDE_CONFIG_DIR="$tmp/claude"
export HERDR_LIMIT_STATE="$tmp/state"
mkdir -p "$CLAUDE_CONFIG_DIR"

# Pre-existing settings: a foreign StopFailure hook (herdr's) plus an
# unrelated key. Neither may be disturbed.
cat > "$CLAUDE_CONFIG_DIR/settings.json" <<'EOF'
{
  "model": "opus",
  "hooks": {
    "StopFailure": [
      {
        "matcher": "rate_limit",
        "hooks": [{ "type": "command", "command": "/somewhere/herdr-agent-state.sh" }]
      }
    ]
  }
}
EOF
cp "$CLAUDE_CONFIG_DIR/settings.json" "$tmp/original.json"

HOOK_CMD="$CLAUDE_CONFIG_DIR/hooks/limit-watch.sh"
our_entries() {
  jq --arg cmd "$HOOK_CMD" \
    '[.hooks.StopFailure[]? | select(([.hooks[]?.command] | index($cmd)))] | length' \
    "$CLAUDE_CONFIG_DIR/settings.json"
}

RAW_CMD="$CLAUDE_CONFIG_DIR/hooks/stopfailure-raw.sh"
raw_entries() {
  jq --arg cmd "$RAW_CMD" \
    '[.hooks.StopFailure[]? | select(([.hooks[]?.command] | index($cmd)))] | length' \
    "$CLAUDE_CONFIG_DIR/settings.json"
}

echo "install"
( cd "$ROOT" && ./install.sh >/dev/null 2>&1 )
if [ -x "$HOOK_CMD" ]; then ok "hook copied and executable"; else bad "hook not installed"; fi
if [ -x "$RAW_CMD" ]; then ok "raw logger copied and executable"; else bad "raw logger not installed"; fi
if [ "$(our_entries)" = "1" ]; then ok "our StopFailure entry added"; else bad "our entry missing"; fi
if [ "$(raw_entries)" = "1" ]; then ok "raw diagnostic entry added (matcher-less)"; else bad "raw entry missing"; fi
if jq -e '.hooks.StopFailure[] | select(.hooks[].command == "/somewhere/herdr-agent-state.sh")' \
     "$CLAUDE_CONFIG_DIR/settings.json" >/dev/null; then
  ok "foreign hook entry preserved"
else
  bad "foreign hook entry lost"
fi
if [ "$(jq -r '.model' "$CLAUDE_CONFIG_DIR/settings.json")" = "opus" ]; then
  ok "unrelated keys preserved"
else
  bad "unrelated keys damaged"
fi

echo "idempotency"
( cd "$ROOT" && ./install.sh >/dev/null 2>&1 )
if [ "$(our_entries)" = "1" ] && [ "$(raw_entries)" = "1" ]; then
  ok "second install -> still exactly one entry of each"
else
  bad "second install duplicated entries (ours=$(our_entries) raw=$(raw_entries))"
fi

echo "uninstall"
( cd "$ROOT" && ./uninstall.sh >/dev/null 2>&1 )
if [ ! -e "$HOOK_CMD" ] && [ ! -e "$RAW_CMD" ]; then ok "both hook files removed"; else bad "hook files remain"; fi
if [ "$(our_entries)" = "0" ] && [ "$(raw_entries)" = "0" ]; then ok "both entries removed"; else bad "entries remain"; fi
if diff <(jq -S . "$tmp/original.json") \
        <(jq -S . "$CLAUDE_CONFIG_DIR/settings.json") >/dev/null; then
  ok "settings restored to original (modulo key order)"
else
  bad "settings differ from original after round trip"
fi

echo "empty-original round trip (fresh user starts from '{}')"
rm -rf "$CLAUDE_CONFIG_DIR" "$tmp/state"
mkdir -p "$CLAUDE_CONFIG_DIR"
printf '{}\n' > "$CLAUDE_CONFIG_DIR/settings.json"
chmod 644 "$CLAUDE_CONFIG_DIR/settings.json"
file_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }

( cd "$ROOT" && ./install.sh >/dev/null 2>&1 )
if [ "$(our_entries)" = "1" ]; then ok "install from {} adds our entry"; else bad "install from {} failed"; fi
if [ "$(file_mode "$CLAUDE_CONFIG_DIR/settings.json")" = "644" ]; then
  ok "file mode preserved after install (644)"
else
  bad "install changed settings.json mode to $(file_mode "$CLAUDE_CONFIG_DIR/settings.json")"
fi

( cd "$ROOT" && ./uninstall.sh >/dev/null 2>&1 )
if [ "$(jq -Sc . "$CLAUDE_CONFIG_DIR/settings.json")" = "{}" ]; then
  ok "uninstall returns a fresh user to exactly {}"
else
  bad "round trip from {} left: $(jq -Sc . "$CLAUDE_CONFIG_DIR/settings.json")"
fi
if [ "$(file_mode "$CLAUDE_CONFIG_DIR/settings.json")" = "644" ]; then
  ok "file mode preserved after uninstall (644)"
else
  bad "uninstall changed settings.json mode"
fi

echo "backup hygiene"
if ls "$tmp"/state/backups/settings.json.bak.* >/dev/null 2>&1; then
  ok "backups live in the state dir"
else
  bad "no backups found in state dir"
fi
if ls "$CLAUDE_CONFIG_DIR"/settings.json.bak.* >/dev/null 2>&1; then
  bad "backups leaked into the claude config dir"
else
  ok "no backups left in the claude config dir"
fi

echo "pre-existing EMPTY .hooks (known, accepted asymmetry)"
# A user who deliberately keeps '{"hooks":{}}' gets '{}' back after the
# round trip: uninstall cannot tell our emptied container from theirs.
# This is documented behavior - pinned here so nobody "fixes" it into a
# regression of the fresh-user round trip above.
rm -rf "$CLAUDE_CONFIG_DIR" "$tmp/state"
mkdir -p "$CLAUDE_CONFIG_DIR"
printf '{"hooks":{}}\n' > "$CLAUDE_CONFIG_DIR/settings.json"
( cd "$ROOT" && ./install.sh >/dev/null 2>&1 )
( cd "$ROOT" && ./uninstall.sh >/dev/null 2>&1 )
if [ "$(jq -Sc . "$CLAUDE_CONFIG_DIR/settings.json")" = "{}" ]; then
  ok "empty .hooks collapses to {} - intentional, see comment"
else
  bad "unexpected shape: $(jq -Sc . "$CLAUDE_CONFIG_DIR/settings.json")"
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "all good"
else
  exit 1
fi
