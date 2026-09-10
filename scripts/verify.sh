#!/usr/bin/env bash
# Acceptance checks for the pi dev container. Runs on the host against a live container.
#   scripts/verify.sh [workspace-folder]     default: test/fixture-go
set -uo pipefail

WS="${1:-test/fixture-go}"
PASS=0
FAIL=0

ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n        expected: %s\n        actual:   %s\n' "$1" "$2" "$3"; FAIL=$((FAIL + 1)); }

# Non-login, non-interactive shell on purpose: this is how pi's bash tool runs commands,
# so shell-init tricks such as `mise activate` must not be what makes a check pass.
inc() { devcontainer exec --workspace-folder "$WS" bash -c "$1" 2>&1; }

expect_match() { # name pattern command
  local name="$1" pattern="$2" out
  out="$(inc "$3")"
  if printf '%s' "$out" | grep -Eq "$pattern"; then
    ok "$name"
  else
    bad "$name" "matches /$pattern/" "$out"
  fi
}

expect_cmd_fails() { # name command
  local name="$1" out
  out="$(inc "$2 >/dev/null 2>&1; echo rc=\$?")"
  if printf '%s' "$out" | grep -q 'rc=0'; then
    bad "$name" "non-zero exit status" "$out"
  else
    ok "$name"
  fi
}

MOUNTS="/go/pkg/mod /home/vscode/.cache/go-build /home/vscode/.local/share/mise /home/vscode/.pi/agent/npm /home/vscode/.config /home/vscode/.history"

echo "verify: $WS"

# V9 — every volume mount point is owned by vscode and writable (spec F8)
for m in $MOUNTS; do
  expect_match "V9 owner $m" '^vscode$' "stat -c %U $m"
  expect_match "V9 write $m" '^ok$'     "touch $m/.wtest && rm -f $m/.wtest && echo ok"
done

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
