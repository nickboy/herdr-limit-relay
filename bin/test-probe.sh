#!/usr/bin/env bash
# Unit tests for probe_quota() in bin/resumer.sh. Offline, no herdr, no
# tokens: a stub `claude` on PATH simulates each outcome the probe must
# classify. Return-code contract under test:
#   0 lifted / 1 limited / 2 broken (non-limit failure)

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0

ok()  { printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Keep the sourced resumer's state writes inside the sandbox.
export HERDR_LIMIT_STATE="$tmp/state"

# Stub claude: CLAUDE_STUB_MODE picks the behavior.
mkdir -p "$tmp/bin"
cat > "$tmp/bin/claude" <<'EOF'
#!/usr/bin/env bash
case "${CLAUDE_STUB_MODE:-ok}" in
  ok)        echo "OK"; exit 0 ;;
  limit)     echo "Claude AI usage limit reached|1754630000" >&2; exit 1 ;;
  limit-alt) echo "5-hour limit reached - resets 3am" >&2; exit 1 ;;
  neterr)    echo "fetch failed: getaddrinfo ENOTFOUND api.anthropic.com" >&2; exit 1 ;;
  autherr)   echo "Invalid API key - please run /login" >&2; exit 1 ;;
esac
EOF
chmod +x "$tmp/bin/claude"
export PATH="$tmp/bin:$PATH"

# main() is guarded behind a BASH_SOURCE check, so sourcing only loads
# functions and never starts the daemon loop.
# shellcheck disable=SC1091
source "$ROOT/bin/resumer.sh"

run_case() {  # run_case <stub mode> <expected rc> <label>
  local mode="$1" want="$2" label="$3" rc=0
  CLAUDE_STUB_MODE="$mode" probe_quota >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq "$want" ]; then
    ok "$label (rc=$rc)"
  else
    bad "$label: expected rc=$want, got rc=$rc"
  fi
}

echo "probe_quota classification"
run_case ok        0 "probe succeeds -> lifted"
run_case limit     1 "usage-limit error -> still limited"
run_case limit-alt 1 "5-hour-limit banner wording -> still limited"
run_case neterr    2 "network error -> broken, not limited"
run_case autherr   2 "auth error -> broken, not limited"

echo "sourcing safety"
if [ ! -e "$tmp/state/heartbeat" ]; then
  ok "sourcing did not start the daemon loop"
else
  bad "sourcing wrote a heartbeat - daemon loop ran during tests"
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "all good"
else
  exit 1
fi
