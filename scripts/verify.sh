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

LANG_DETECTED="$(grep -o '"name"[[:space:]]*:[[:space:]]*"[a-z]*-pi"' "$WS/.devcontainer/devcontainer.json" \
                  | grep -o '[a-z]*-pi' | sed 's/-pi$//')"

case "$LANG_DETECTED" in
  go)
    MOUNTS="/go/pkg/mod /home/vscode/.cache/go-build /home/vscode/.local/share/mise /home/vscode/.pi/agent/npm /home/vscode/.pi/agent/pi-claude-marketplace /home/vscode/.config /home/vscode/.history"
    ;;
  java)
    MOUNTS="/home/vscode/.m2/repository /home/vscode/.gradle /home/vscode/.local/share/mise /home/vscode/.pi/agent/npm /home/vscode/.pi/agent/pi-claude-marketplace /home/vscode/.config /home/vscode/.history"
    ;;
  base)
    MOUNTS="/home/vscode/.local/share/mise /home/vscode/.pi/agent/npm /home/vscode/.pi/agent/pi-claude-marketplace /home/vscode/.config /home/vscode/.history"
    ;;
  *)
    echo "ERROR: cannot determine language from $WS/.devcontainer/devcontainer.json" >&2
    exit 1
    ;;
esac

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
# transition, and it is where the --cap-drop=ALL is visible (spec F1). The expected value
# differs by language: Go's image metadata forces SYS_PTRACE back in (F1); Java's does not
# (spec finding F19), so the ceiling there is fully empty.
if [ "$LANG_DETECTED" = go ]; then
  expect_match "V5a capability ceiling" '^CapBnd:[[:space:]]+0000000000080000$' 'grep CapBnd /proc/self/status'
else
  expect_match "V5a capability ceiling" '^CapBnd:[[:space:]]+0000000000000000$' 'grep CapBnd /proc/self/status'
fi
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

# V1 — pi is installed at the pinned version. The expectation is read from the config
# so the check cannot drift away from the template.
PI_VERSION_EXPECTED="$(grep -o '"PI_VERSION"[^,}]*' "$WS/.devcontainer/devcontainer.json" | grep -o '[0-9][0-9.]*')"
expect_match "V1 pi version" "^${PI_VERSION_EXPECTED}$" 'pi --version'

# V1b — the OpenSpec CLI is installed. OPENSPEC_VERSION floats on "latest" by default (unlike
# PI_VERSION), so this checks for a plausible semver rather than an exact pin.
expect_match "V1b openspec version" '^[0-9]+\.[0-9]+\.[0-9]+$' 'openspec --version'

# V3 — a project tool is visible to a NON-INTERACTIVE shell, which is how pi's bash
# tool runs commands. This is the check that catches a shims-not-in-PATH regression.
expect_match "V3 project tool on PATH" '/shims/jq$' 'command -v jq'
if [ "$LANG_DETECTED" = go ]; then
  expect_match "V3 go still resolves" '^go version' 'go version'
fi

# V2 — packages declared in the personal layer are installed
expect_match "V2 packages installed" 'pi-quit-aliases' 'pi list'

# V3b — personal tools are on PATH in a non-interactive shell
expect_match "V3b personal tool yq" '/shims/yq$' 'command -v yq'
# jira-cli needed a backend workaround (its binary is named `jira`, not after the repo),
# so it gets its own check rather than being assumed to work.
expect_match "V3c personal tool jira" '/shims/jira$' 'command -v jira'

# V2b — the personal layer landed where pi looks for it
expect_match "V2b settings applied" '"defaultProjectTrust"' 'cat ~/.pi/agent/settings.json'
expect_match "V2d default model applied" '"z-ai/glm-5.3-flash"' 'cat ~/.pi/agent/settings.json'
expect_match "V2c global context"   '# Environment'          'head -1 ~/.pi/agent/AGENTS.md'

# V4 — a real build works and populates the shared dependency cache. Base has no build
# toolchain by design; its equivalent proof is that the three things every generated project
# leans on — git, Node and mise — actually run. Bind mounts present host files as root-owned;
# without a safe.directory entry git refuses to run.
if [ "$LANG_DETECTED" = go ]; then
  expect_match "V4 GOMODCACHE"   '^/go/pkg/mod$' 'go env GOMODCACHE'
  expect_match "V4b git usable"  'On branch|HEAD detached' 'git status'
  expect_match "V4 go build"     '^ok$'          'go mod tidy >/dev/null 2>&1 && go build ./... && echo ok'
  expect_match "V4 cache filled" '^yes$'         '[ -d /go/pkg/mod/rsc.io ] && echo yes || echo no'
elif [ "$LANG_DETECTED" = java ]; then
  expect_match "V4b git usable"  'On branch|HEAD detached' 'git status'
  expect_match "V4 mvn build"    '^ok$'          'mvn -q -B compile && echo ok'
  expect_match "V4 cache filled" '^yes$' \
    '[ -d /home/vscode/.m2/repository/org/apache/commons ] && echo yes || echo no'
  # Gradle gets a shim-reachability check only, not a full build: both build tools ship in
  # the image (spec decision J5), only one gets a maintained build fixture. Gradle (like
  # Maven) is provided by the java devcontainer feature via SDKMAN, not by mise, so it is
  # not under .../shims/ the way jq/yq are — reachability from a non-interactive shell is
  # what this check proves, not the specific provisioning mechanism.
  expect_match "V4c gradle reachable" '/gradle$' 'command -v gradle'
else
  expect_match "V4b git usable"     'On branch|HEAD detached' 'git status'
  expect_match "V4 node runtime"    '^ok$'           'node -e "console.log(\"ok\")"'
  expect_match "V4c mise reachable" '^mise [0-9]'    'mise --version'
  expect_match "V4d git present"    '^git version'   'git --version'
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
