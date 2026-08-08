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

echo "install"
( cd "$ROOT" && ./install.sh >/dev/null 2>&1 )
if [ -x "$HOOK_CMD" ]; then ok "hook copied and executable"; else bad "hook not installed"; fi
if [ "$(our_entries)" = "1" ]; then ok "our StopFailure entry added"; else bad "our entry missing"; fi
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
if [ "$(our_entries)" = "1" ]; then
  ok "second install -> still exactly one entry"
else
  bad "second install duplicated the entry ($(our_entries))"
fi

echo "uninstall"
( cd "$ROOT" && ./uninstall.sh >/dev/null 2>&1 )
if [ ! -e "$HOOK_CMD" ]; then ok "hook file removed"; else bad "hook file remains"; fi
if [ "$(our_entries)" = "0" ]; then ok "our entry removed"; else bad "our entry remains"; fi
if diff <(jq -S . "$tmp/original.json") \
        <(jq -S . "$CLAUDE_CONFIG_DIR/settings.json") >/dev/null; then
  ok "settings restored to original (modulo key order)"
else
  bad "settings differ from original after round trip"
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "all good"
else
  exit 1
fi
