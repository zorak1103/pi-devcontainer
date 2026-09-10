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

# Container ID via the container's own hostname — avoids brittle label filtering.
CID="$(inc 'cat /etc/hostname' | tr -d '\r\n')"

echo "verify: $WS"

# V9 — every volume mount point is owned by vscode and writable (spec F8)
for m in $MOUNTS; do
  expect_match "V9 owner $m" '^vscode$' "stat -c %U $m"
  expect_match "V9 write $m" '^ok$'     "touch $m/.wtest && rm -f $m/.wtest && echo ok"
done

# V5 — capability ceiling. Measured on the process pi's tools actually run as (vscode,
# uid 1000), not on root: a non-root process holds no effective capabilities at all, so
# CapEff proves nothing on its own. CapBnd is the ceiling that survives any setuid
# transition, and it is where the --cap-drop=ALL is visible (spec F1).
expect_match "V5a capability ceiling" '^CapBnd:[[:space:]]+0000000000080000$' 'grep CapBnd /proc/self/status'
expect_match "V5b no effective caps"  '^CapEff:[[:space:]]+0000000000000000$' 'grep CapEff /proc/self/status'

# V6 — hardening verified negatively: privilege escalation must not work (spec F4)
expect_cmd_fails "V6 sudo refused" 'sudo -n true'

# V7 — the API key must not be readable from the container configuration (spec F3)
if docker inspect "$CID" --format '{{json .Config.Env}}' | grep -q ANTHROPIC; then
  bad "V7 key absent from docker inspect" "no ANTHROPIC entry" "found one"
else
  ok "V7 key absent from docker inspect"
fi

# V7b — but it does reach processes started through the devcontainer CLI or VS Code.
# Never print the value.
expect_match "V7b key reaches the container" '^set$' '[ -n "$ANTHROPIC_API_KEY" ] && echo set || echo unset'

# V8 — non-root
expect_match "V8 user" '^vscode$' 'whoami'

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
