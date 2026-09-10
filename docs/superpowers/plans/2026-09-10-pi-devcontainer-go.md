# pi Dev Container (Go) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a copyable `.devcontainer` template that runs the pi coding agent inside a lightly hardened, VS Code–native Go dev container, plus the documentation that explains why every part of it looks the way it does.

**Architecture:** One thin image layer over the official Go dev container image owns the volume mount points; `devcontainer.json` adds Node, mise, hardening flags and volumes; three scripts install pi, sync a personal configuration layer from the host, and install tools through mise. A host-side `scripts/verify.sh` runs the acceptance checks against a live container and grows check-by-check alongside the implementation.

**Tech Stack:** Dev Containers spec + `devcontainer` CLI 0.89, Docker, `mcr.microsoft.com/devcontainers/go`, Dev Container Features (`node`, `mise`), mise (aqua/ubi/go backends), Node 22, `@earendil-works/pi-coding-agent`, Bash, Go.

**Spec:** `docs/superpowers/specs/2026-09-10-pi-devcontainer-go-design.md`

> **Historical document.** This is the plan as written before execution. It was followed
> task by task, but five checks and one whole step changed when measurements contradicted
> it — see findings F9–F13 in [docs/findings.md](../../findings.md). The implemented
> `scripts/verify.sh` has 30 checks, not the 27 planned here.

## Global Constraints

- Base image: `mcr.microsoft.com/devcontainers/go:1.27-bookworm`.
- pi package and version: `@earendil-works/pi-coding-agent@0.85.1`, installed with `npm install -g --ignore-scripts`.
- Container user: `vscode` (uid 1000), inherited from image metadata. Never run as root.
- Hardening: `runArgs: ["--cap-drop=ALL", "--security-opt", "no-new-privileges"]`. Never add `capAdd` or `securityOpt` entries — they are additive and cannot subtract what image metadata contributes.
- `sudo` does not work and must not be used in any script.
- The provider API key travels through `remoteEnv` only, never `containerEnv`.
- Every named volume needs a matching `mkdir` + `chown vscode:vscode` in the Dockerfile, otherwise it is created root-owned and unrepairable (spec F8).
- All shell scripts and JS files are LF-only, enforced by `.gitattributes`. Lifecycle hooks invoke `bash <script>` explicitly; never rely on the executable bit.
- Language of all repository content: English. License: MIT.
- No content that identifies a particular machine, user account, or personal configuration. Version numbers of tools are fine.
- Six volume mount points, fixed list, referenced by several tasks:
  `/go/pkg/mod`, `/home/vscode/.cache/go-build`, `/home/vscode/.local/share/mise`, `/home/vscode/.pi/agent/npm`, `/home/vscode/.config`, `/home/vscode/.history`.

---

## File Structure

| File | Responsibility |
|---|---|
| `templates/go/.devcontainer/Dockerfile` | one layer over the base image; owns the volume mount points |
| `templates/go/.devcontainer/devcontainer.json` | features, hardening, environment, volumes, lifecycle hooks |
| `templates/go/.devcontainer/sync-personal.js` | host-side copy of the personal layer into the workspace |
| `templates/go/.devcontainer/install-pi.sh` | Node check + pi install (becomes the Feature `install.sh` in stage C) |
| `templates/go/.devcontainer/post-create.sh` | apply personal layer, warn on missing key, `mise install` |
| `personal/settings.json` | template for the container-side pi settings |
| `personal/mise.toml` | template for cross-project personal tools |
| `personal/AGENTS.md` | template global context file describing the container to the agent |
| `scripts/verify.sh` | host-side acceptance checks V1–V10 against a live container |
| `scripts/init-project.sh` | copy the template into a target project |
| `test/fixture-go/` | throwaway Go module used to exercise the template |
| `README.md`, `LICENSE`, `docs/*.md` | published documentation |

`test/fixture-go/.devcontainer/` is a working copy of the template and is gitignored, so the template stays the single source of truth.

---

### Task 1: Check harness and volume-owning base image

**Files:**
- Create: `.gitignore`
- Create: `scripts/verify.sh`
- Create: `templates/go/.devcontainer/Dockerfile`
- Create: `templates/go/.devcontainer/devcontainer.json`
- Create: `test/fixture-go/go.mod`
- Create: `test/fixture-go/main.go`

**Interfaces:**
- Consumes: nothing.
- Produces: `scripts/verify.sh` with shell functions `ok`, `bad`, `inc <command>`, `expect_match <name> <pattern> <command>`, `expect_cmd_fails <name> <command>`, and the variables `WS` (workspace folder) and `MOUNTS` (space-separated list of the six mount points). Later tasks append checks to this file and reuse those functions verbatim.
- Produces: `templates/go/.devcontainer/devcontainer.json` with keys `name`, `build`, `mounts`. Later tasks add `features`, `runArgs`, `containerEnv`, `remoteEnv`, `initializeCommand`, `onCreateCommand`, `postCreateCommand`, `customizations`.

- [ ] **Step 1: Write the failing check**

Create `scripts/verify.sh`:

```bash
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
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `bash scripts/verify.sh`
Expected: every V9 check FAILs, because `test/fixture-go` has no `.devcontainer` yet. The `actual:` lines will contain a `devcontainer exec` error about a missing configuration.

- [ ] **Step 3: Write the minimal implementation**

Create `.gitignore`:

```gitignore
test/fixture-go/.devcontainer/
test/fixture-go/.pi/
test/fixture-go/go.sum
.devcontainer/.personal/
```

Create `templates/go/.devcontainer/Dockerfile`:

```dockerfile
FROM mcr.microsoft.com/devcontainers/go:1.27-bookworm

# A named volume whose target path does not exist in the image is created root-owned,
# and no-new-privileges leaves no sudo to repair it afterwards. Every volume mount point
# in devcontainer.json must appear here. See docs/findings.md, finding F8.
RUN mkdir -p /go/pkg/mod \
             /home/vscode/.cache/go-build \
             /home/vscode/.local/share/mise \
             /home/vscode/.pi/agent/npm \
             /home/vscode/.config \
             /home/vscode/.history \
 && chown -R vscode:vscode /go/pkg /home/vscode
```

Create `templates/go/.devcontainer/devcontainer.json`:

```jsonc
{
  "name": "go-pi",
  "build": { "dockerfile": "Dockerfile" },

  "mounts": [
    "source=pi-dc-gomod,target=/go/pkg/mod,type=volume",
    "source=pi-dc-gobuild,target=/home/vscode/.cache/go-build,type=volume",
    "source=pi-dc-mise,target=/home/vscode/.local/share/mise,type=volume",
    "source=pi-dc-${localWorkspaceFolderBasename}-pinpm,target=/home/vscode/.pi/agent/npm,type=volume",
    "source=pi-dc-${localWorkspaceFolderBasename}-config,target=/home/vscode/.config,type=volume",
    "source=pi-dc-${localWorkspaceFolderBasename}-hist,target=/home/vscode/.history,type=volume"
  ]
}
```

Create `test/fixture-go/go.mod`:

```
module example.com/fixture

go 1.27

require rsc.io/quote v1.5.2
```

Create `test/fixture-go/main.go`:

```go
package main

import (
	"fmt"

	"rsc.io/quote"
)

func main() {
	fmt.Println(quote.Hello())
}
```

- [ ] **Step 4: Run the checks and make sure they pass**

```bash
rm -rf test/fixture-go/.devcontainer
cp -r templates/go/.devcontainer test/fixture-go/.devcontainer
docker volume rm -f pi-dc-gomod pi-dc-gobuild pi-dc-mise \
  pi-dc-fixture-go-pinpm pi-dc-fixture-go-config pi-dc-fixture-go-hist
devcontainer up --workspace-folder test/fixture-go --remove-existing-container
bash scripts/verify.sh
```

Expected: `12 passed, 0 failed`. The volumes are deleted first so the check exercises fresh-volume creation, which is the exact failure mode F8 describes.

- [ ] **Step 5: Commit**

```bash
git add .gitignore scripts/verify.sh templates/go/.devcontainer test/fixture-go
git commit -m "feat: base image layer owning all volume mount points

Named volumes on paths absent from the image are created root-owned,
and no-new-privileges leaves no sudo to repair that. One derived layer
creates and chowns all six mount points. Adds the check harness."
```

---

### Task 2: Hardening and environment

**Files:**
- Modify: `templates/go/.devcontainer/devcontainer.json`
- Modify: `scripts/verify.sh`

**Interfaces:**
- Consumes: `ok`, `bad`, `inc`, `expect_match`, `expect_cmd_fails`, `WS` from Task 1.
- Produces: `CID` variable in `verify.sh` holding the container ID, derived from the container's own hostname; later tasks may reuse it for host-side `docker` queries.
- Produces: `containerEnv` keys `PI_CODING_AGENT_SESSION_DIR`, `HISTFILE`, `LANG`, `COLORTERM`; `remoteEnv` key `ANTHROPIC_API_KEY`.

- [ ] **Step 1: Write the failing checks**

In `scripts/verify.sh`, insert after the `MOUNTS=` line:

```bash
# Container ID via the container's own hostname — avoids brittle label filtering.
CID="$(inc 'cat /etc/hostname' | tr -d '\r\n')"
```

And append before the final `printf`:

```bash
# V5 — exactly one capability remains (spec F1)
expect_match "V5 capabilities" '^CapEff:[[:space:]]+0000000000080000$' 'grep CapEff /proc/self/status'

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
```

- [ ] **Step 2: Run the checks to verify they fail**

Run: `bash scripts/verify.sh`
Expected: V5 FAILs (`CapEff` shows the Docker default `0000...a80425fb`), V6 FAILs (`sudo` succeeds), V7b FAILs (`unset`). V7 and V8 already pass — V8 because the image metadata sets `remoteUser: vscode`, V7 trivially because no key is configured at all yet. Both become meaningful once Step 3 lands.

- [ ] **Step 3: Write the minimal implementation**

In `templates/go/.devcontainer/devcontainer.json`, insert between `"build"` and `"mounts"`:

```jsonc
  "runArgs": ["--cap-drop=ALL", "--security-opt", "no-new-privileges"],

  "containerEnv": {
    "PI_CODING_AGENT_SESSION_DIR": "${containerWorkspaceFolder}/.pi/sessions",
    "HISTFILE": "/home/vscode/.history/.bash_history",
    "LANG": "C.UTF-8",
    "COLORTERM": "truecolor"
  },

  "remoteEnv": {
    "ANTHROPIC_API_KEY": "${localEnv:ANTHROPIC_API_KEY}"
  },
```

Also add at the end of the file, after `"mounts"`:

```jsonc
  "customizations": {
    "vscode": { "settings": { "go.toolsManagement.checkForUpdates": "off" } }
  }
```

This one setting is not machine-checkable — it only takes effect in VS Code, and no check in
`verify.sh` can observe it. It stops the Go extension from fetching tool updates that the
image already provides. Verify it by reading the file, not by running anything.

- [ ] **Step 4: Run the checks and make sure they pass**

```bash
rm -rf test/fixture-go/.devcontainer
cp -r templates/go/.devcontainer test/fixture-go/.devcontainer
ANTHROPIC_API_KEY=verify-dummy-not-a-real-key \
  devcontainer up --workspace-folder test/fixture-go --remove-existing-container
ANTHROPIC_API_KEY=verify-dummy-not-a-real-key bash scripts/verify.sh
```

Expected: `17 passed, 0 failed`.

If V6 reports that `sudo` succeeded, the hardening did not apply — check that `runArgs` survived the JSON edit before changing anything else.

- [ ] **Step 5: Commit**

```bash
git add templates/go/.devcontainer/devcontainer.json scripts/verify.sh
git commit -m "feat: capability hardening and environment

Drops all capabilities except the SYS_PTRACE the image metadata forces
back in, sets no-new-privileges, and routes the API key through
remoteEnv so it stays out of docker inspect."
```

---

### Task 3: Node and pi installation

**Files:**
- Create: `templates/go/.devcontainer/install-pi.sh`
- Modify: `templates/go/.devcontainer/devcontainer.json`
- Modify: `scripts/verify.sh`

**Interfaces:**
- Consumes: `expect_match`, `WS` from Task 1.
- Produces: `containerEnv` key `PI_VERSION`, read by `install-pi.sh` and by `verify.sh`.
- Produces: `install-pi.sh`, a standalone script that assumes only that `npm` is on `PATH` — this is what becomes the Dev Container Feature's `install.sh` in stage C. It must not reference the workspace or the personal layer.

- [ ] **Step 1: Write the failing check**

In `scripts/verify.sh`, append before the final `printf`:

```bash
# V1 — pi is installed at the pinned version. The expectation is read from the config
# so the check cannot drift away from the template.
PI_VERSION_EXPECTED="$(grep -o '"PI_VERSION"[^,}]*' "$WS/.devcontainer/devcontainer.json" | grep -o '[0-9][0-9.]*')"
expect_match "V1 pi version" "^${PI_VERSION_EXPECTED}$" 'pi --version'
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `ANTHROPIC_API_KEY=verify-dummy-not-a-real-key bash scripts/verify.sh`
Expected: V1 FAILs. `PI_VERSION_EXPECTED` is empty and `pi --version` reports `bash: pi: command not found`.

- [ ] **Step 3: Write the minimal implementation**

Create `templates/go/.devcontainer/install-pi.sh`:

```bash
#!/usr/bin/env bash
# Installs the pi coding agent. Standalone by design: this file becomes the
# install.sh of a Dev Container Feature without modification.
set -euo pipefail

command -v npm >/dev/null || {
  echo "ERROR: node/npm not found. The node feature in devcontainer.json is required." >&2
  exit 1
}

npm install -g --ignore-scripts "@earendil-works/pi-coding-agent@${PI_VERSION:-latest}"
pi --version
```

In `templates/go/.devcontainer/devcontainer.json`, add the features block after `"build"`:

```jsonc
  "features": {
    "ghcr.io/devcontainers/features/node:2": { "version": "22" }
  },
```

add to `containerEnv`:

```jsonc
    "PI_VERSION": "0.85.1",
```

and add after `"mounts"`:

```jsonc
  "onCreateCommand": "bash .devcontainer/install-pi.sh",
```

- [ ] **Step 4: Run the checks and make sure they pass**

```bash
rm -rf test/fixture-go/.devcontainer
cp -r templates/go/.devcontainer test/fixture-go/.devcontainer
ANTHROPIC_API_KEY=verify-dummy-not-a-real-key \
  devcontainer up --workspace-folder test/fixture-go --remove-existing-container
ANTHROPIC_API_KEY=verify-dummy-not-a-real-key bash scripts/verify.sh
```

Expected: `18 passed, 0 failed`, and the `devcontainer up` output contains `0.85.1` from the script's closing `pi --version`.

- [ ] **Step 5: Commit**

```bash
git add templates/go/.devcontainer/install-pi.sh templates/go/.devcontainer/devcontainer.json scripts/verify.sh
git commit -m "feat: install pi on an isolated Node runtime

The base image ships nvm without a Node version, so the node feature is
mandatory. pi is pinned via PI_VERSION; install-pi.sh is standalone so it
can become a Dev Container Feature later."
```

---

### Task 4: mise tool plane and shim PATH

**Files:**
- Create: `templates/go/.devcontainer/post-create.sh`
- Create: `test/fixture-go/mise.toml`
- Modify: `templates/go/.devcontainer/devcontainer.json`
- Modify: `scripts/verify.sh`

**Interfaces:**
- Consumes: `expect_match` from Task 1.
- Produces: `containerEnv` keys `PATH` (shims first), `MISE_DATA_DIR`, `MISE_GLOBAL_CONFIG_FILE`, `MISE_TRUSTED_CONFIG_PATHS`.
- Produces: `post-create.sh`, extended by Task 5 with the personal-layer copy steps. Its `mise install` / `mise reshim` lines must stay last.

- [ ] **Step 1: Write the failing check**

In `scripts/verify.sh`, append before the final `printf`:

```bash
# V3 — a project tool is visible to a NON-INTERACTIVE shell, which is how pi's bash
# tool runs commands. This is the check that catches a shims-not-in-PATH regression.
expect_match "V3 project tool on PATH" '/shims/jq$' 'command -v jq'
expect_match "V3 go still resolves"    '^go version' 'go version'
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `ANTHROPIC_API_KEY=verify-dummy-not-a-real-key bash scripts/verify.sh`
Expected: the first V3 check FAILs with empty output (`jq` is not installed); the second passes.

- [ ] **Step 3: Write the minimal implementation**

Create `templates/go/.devcontainer/post-create.sh`:

```bash
#!/usr/bin/env bash
# Applies the personal configuration layer and installs declared tools.
set -euo pipefail

mkdir -p ~/.pi/agent ~/.pi/agent/skills ~/.config/mise "$PI_CODING_AGENT_SESSION_DIR"

mise install
mise reshim
```

Create `test/fixture-go/mise.toml`:

```toml
[tools]
jq = "latest"
```

In `templates/go/.devcontainer/devcontainer.json`, add to `features`:

```jsonc
    "ghcr.io/devcontainers-extra/features/mise:1": {}
```

add to `containerEnv`:

```jsonc
    "PATH": "/home/vscode/.local/share/mise/shims:${containerEnv:PATH}",
    "MISE_DATA_DIR": "/home/vscode/.local/share/mise",
    "MISE_GLOBAL_CONFIG_FILE": "/home/vscode/.config/mise/config.toml",
    "MISE_TRUSTED_CONFIG_PATHS": "/workspaces",
```

and add after `"onCreateCommand"`:

```jsonc
  "postCreateCommand": "bash .devcontainer/post-create.sh",
```

- [ ] **Step 4: Run the checks and make sure they pass**

```bash
rm -rf test/fixture-go/.devcontainer
cp -r templates/go/.devcontainer test/fixture-go/.devcontainer
ANTHROPIC_API_KEY=verify-dummy-not-a-real-key \
  devcontainer up --workspace-folder test/fixture-go --remove-existing-container
ANTHROPIC_API_KEY=verify-dummy-not-a-real-key bash scripts/verify.sh
```

Expected: `20 passed, 0 failed`. `command -v jq` must resolve to a path ending in `/shims/jq`, not `/usr/bin/jq` — the shim path is what proves the mechanism works rather than a distro package.

If `mise install` reports an untrusted config, `MISE_TRUSTED_CONFIG_PATHS` did not reach the container.

- [ ] **Step 5: Commit**

```bash
git add templates/go/.devcontainer/post-create.sh templates/go/.devcontainer/devcontainer.json test/fixture-go/mise.toml scripts/verify.sh
git commit -m "feat: mise as the tool plane, shims first on PATH

pi's bash tool spawns non-interactive shells where shell-init hooks do
not apply, so tools must be reachable through the shims directory in
PATH rather than through mise activate."
```

---

### Task 5: Personal layer

**Files:**
- Create: `templates/go/.devcontainer/sync-personal.js`
- Create: `personal/settings.json`
- Create: `personal/mise.toml`
- Create: `personal/AGENTS.md`
- Modify: `templates/go/.devcontainer/devcontainer.json`
- Modify: `templates/go/.devcontainer/post-create.sh`
- Modify: `scripts/verify.sh`

**Interfaces:**
- Consumes: `expect_match`, `WS` from Task 1; `post-create.sh` from Task 4.
- Produces: the environment variable `PI_DC_PERSONAL`, read by `sync-personal.js` on the **host** to override the personal-layer source directory. Default: `<home>/.pi/devcontainer`. This override exists so the layer can be tested deterministically without touching a real developer's configuration, and so several profiles can be kept side by side.
- Produces: `.devcontainer/.personal/` inside the workspace as the hand-off location between host and container.

- [ ] **Step 1: Write the failing checks**

In `scripts/verify.sh`, append before the final `printf`:

```bash
# V2 — packages declared in the personal layer are installed
expect_match "V2 packages installed" 'pi-quit-aliases' 'pi list'

# V3b — personal tools are on PATH in a non-interactive shell
expect_match "V3b personal tool yq" '/shims/yq$' 'command -v yq'

# V2b — the personal layer landed where pi looks for it
expect_match "V2b settings applied" '"defaultProjectTrust"' 'cat ~/.pi/agent/settings.json'
expect_match "V2c global context"   '# Environment'          'head -1 ~/.pi/agent/AGENTS.md'
```

- [ ] **Step 2: Run the checks to verify they fail**

Run: `ANTHROPIC_API_KEY=verify-dummy-not-a-real-key bash scripts/verify.sh`
Expected: all four FAIL. `pi list` shows no packages, `command -v yq` is empty, and both `cat`/`head` report `No such file or directory`.

- [ ] **Step 3: Write the minimal implementation**

Create `templates/go/.devcontainer/sync-personal.js`:

```js
// Runs on the HOST before container creation.
// Node is used because the devcontainer CLI ships it, which avoids every host-shell
// difference; array form in devcontainer.json avoids shell quoting entirely.
// Deliberately never fails the container start: a missing personal layer is a
// supported configuration that degrades to pi defaults.
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const src = process.env.PI_DC_PERSONAL || path.join(os.homedir(), ".pi", "devcontainer");
const dest = path.join(process.cwd(), ".devcontainer", ".personal");

fs.rmSync(dest, { recursive: true, force: true });
fs.mkdirSync(dest, { recursive: true });

if (fs.existsSync(src)) {
  fs.cpSync(src, dest, { recursive: true });
  console.log(`personal layer: copied ${fs.readdirSync(dest).join(", ")} from ${src}`);
} else {
  console.log(`personal layer: none at ${src} — continuing with pi defaults`);
}
```

Create `personal/settings.json`:

```json
{
  "theme": "dark",
  "defaultProjectTrust": "always",
  "packages": ["npm:pi-quit-aliases"],
  "modelThinkingLevels": { "anthropic/claude-sonnet-4-20250514": "high" }
}
```

Create `personal/mise.toml`:

```toml
# Cross-project personal tools. Registry names where they exist, backends otherwise:
# ubi: any GitHub release, go:, npm:, pipx:, aqua:.
[tools]
jq = "latest"
yq = "latest"
"github-cli" = "latest"
glab = "latest"
typst = "latest"
"ubi:ankitpokhrel/jira-cli" = "latest"
```

Create `personal/AGENTS.md`:

```markdown
# Environment

You are running inside a dev container (Debian, non-root user `vscode`), not on the host.

- No `sudo`, no `apt install`. This is intentional, not broken.
- New CLI tool: `mise use -g <tool>` (backends: aqua, ubi, go, npm, pipx).
- System packages require an entry in `.devcontainer/devcontainer.json` plus a rebuild.
- Writable: the workspace under `/workspaces` and the caches. The host is unreachable.
- Sessions are stored in `.pi/sessions` inside the project.
```

In `templates/go/.devcontainer/devcontainer.json`, add before `"onCreateCommand"`:

```jsonc
  "initializeCommand": ["node", ".devcontainer/sync-personal.js"],
```

In `templates/go/.devcontainer/post-create.sh`, replace the whole body with:

```bash
#!/usr/bin/env bash
# Applies the personal configuration layer and installs declared tools.
set -euo pipefail

P=".devcontainer/.personal"

mkdir -p ~/.pi/agent ~/.pi/agent/skills ~/.config/mise "$PI_CODING_AGENT_SESSION_DIR"

# Copied, never mounted: the container keeps a writable copy and the host stays untouched.
# Refreshed on every create, so edits to the personal layer take effect on rebuild.
[ -f "$P/settings.json" ] && cp    "$P/settings.json" ~/.pi/agent/settings.json
[ -f "$P/AGENTS.md"     ] && cp    "$P/AGENTS.md"     ~/.pi/agent/AGENTS.md
[ -f "$P/mise.toml"     ] && cp    "$P/mise.toml"     ~/.config/mise/config.toml
[ -d "$P/skills"        ] && cp -r "$P/skills/."      ~/.pi/agent/skills/

[ -n "${ANTHROPIC_API_KEY:-}" ] || \
  echo "WARNING: ANTHROPIC_API_KEY is empty — see docs/setup-windows.md"

mise install
mise reshim
```

- [ ] **Step 4: Run the checks and make sure they pass**

```bash
rm -rf test/fixture-go/.devcontainer
cp -r templates/go/.devcontainer test/fixture-go/.devcontainer
export PI_DC_PERSONAL="$PWD/personal"
ANTHROPIC_API_KEY=verify-dummy-not-a-real-key \
  devcontainer up --workspace-folder test/fixture-go --remove-existing-container
ANTHROPIC_API_KEY=verify-dummy-not-a-real-key bash scripts/verify.sh
```

Expected: `24 passed, 0 failed`. The `devcontainer up` output must contain a `personal layer: copied …` line. This run installs five tools through mise and will take noticeably longer than previous runs.

- [ ] **Step 5: Verify the degradation path**

```bash
mkdir -p /tmp/empty-personal
PI_DC_PERSONAL=/tmp/empty-personal ANTHROPIC_API_KEY=verify-dummy-not-a-real-key \
  devcontainer up --workspace-folder test/fixture-go --remove-existing-container
```

Expected: the container comes up, and the output contains `personal layer: none at /tmp/empty-personal — continuing with pi defaults`. A missing personal layer must never fail the create. Then restore the full layer:

```bash
PI_DC_PERSONAL="$PWD/personal" ANTHROPIC_API_KEY=verify-dummy-not-a-real-key \
  devcontainer up --workspace-folder test/fixture-go --remove-existing-container
```

- [ ] **Step 6: Commit**

```bash
git add templates/go/.devcontainer/sync-personal.js templates/go/.devcontainer/post-create.sh templates/go/.devcontainer/devcontainer.json personal scripts/verify.sh
git commit -m "feat: personal configuration layer, copied not mounted

A host directory is copied into the workspace by initializeCommand and
from there into the container, so the copy stays writable and the host
config is never touched. PI_DC_PERSONAL overrides the source."
```

---

### Task 6: Go workflow and cache persistence

**Files:**
- Modify: `scripts/verify.sh`

**Interfaces:**
- Consumes: `expect_match`, `MOUNTS`, `WS` from Task 1.
- Produces: no new interfaces. This task adds the two checks that prove the environment is actually usable for Go work and that decision D8 (shared caches) holds across rebuilds.

- [ ] **Step 1: Write the failing checks**

In `scripts/verify.sh`, append before the final `printf`:

```bash
# V4 — a real build works and populates the shared module cache
expect_match "V4 GOMODCACHE"   '^/go/pkg/mod$' 'go env GOMODCACHE'
expect_match "V4 go build"     '^ok$'          'go mod tidy >/dev/null 2>&1 && go build ./... && echo ok'
expect_match "V4 cache filled" '^yes$'         '[ -d /go/pkg/mod/rsc.io ] && echo yes || echo no'
```

- [ ] **Step 2: Run the checks and read the result honestly**

Run: `ANTHROPIC_API_KEY=verify-dummy-not-a-real-key bash scripts/verify.sh`
Expected: all three PASS on the first run. This task deviates from failing-first on purpose,
and the reason is worth understanding rather than working around: the `V4 go build` check
performs the download itself, so by the time `V4 cache filled` runs, the cache is populated.
Contriving a failure by reordering the checks would test the harness, not the container.

These are regression guards. They fail when something real breaks: a permission error on
`/go/pkg/mod` means a mount point is missing from the Dockerfile (spec F8), and a `GOMODCACHE`
outside `/go/pkg/mod` means the shared cache volume is not being used at all.

- [ ] **Step 3: Confirm the workflow end to end**

```bash
devcontainer exec --workspace-folder test/fixture-go bash -c 'go mod tidy && go build ./... && ./fixture'
```

Expected: `Hello, world.`

- [ ] **Step 4: Run the checks and make sure they pass**

Run: `ANTHROPIC_API_KEY=verify-dummy-not-a-real-key bash scripts/verify.sh`
Expected: `27 passed, 0 failed`.

- [ ] **Step 5: Verify cache survival across a rebuild (V10)**

```bash
ANTHROPIC_API_KEY=verify-dummy-not-a-real-key PI_DC_PERSONAL="$PWD/personal" \
  devcontainer up --workspace-folder test/fixture-go --remove-existing-container
devcontainer exec --workspace-folder test/fixture-go bash -c 'ls -d /go/pkg/mod/rsc.io && ls ~/.local/share/mise/installs'
```

Expected: `/go/pkg/mod/rsc.io` still exists and the mise installs directory still lists the tools — the container was replaced, the shared volumes were not. Note the wall-clock time of this `up` against the one in Task 5; it should be substantially shorter because no tool downloads occur.

- [ ] **Step 6: Commit**

```bash
git add scripts/verify.sh
git commit -m "test: Go build workflow and shared cache persistence

Proves the module cache is writable and shared across container
rebuilds, which is the payoff of the volume split in decision D8."
```

---

### Task 7: Project initialisation script

**Files:**
- Create: `scripts/init-project.sh`

**Interfaces:**
- Consumes: `templates/go/.devcontainer/` from Tasks 1–5.
- Produces: `scripts/init-project.sh <target-dir>`, the supported way to adopt the template. Documentation in Task 8 refers to it.

- [ ] **Step 1: Write the failing test**

Create `test/init-project.test.sh`:

```bash
#!/usr/bin/env bash
# Test: init-project.sh copies the template and reports the gitignore entries.
set -uo pipefail

TARGET="$(mktemp -d)"
trap 'rm -rf "$TARGET"' EXIT

out="$(bash scripts/init-project.sh "$TARGET" 2>&1)"
rc=$?

fail=0
check() { if [ "$2" = "$3" ]; then echo "  PASS  $1"; else echo "  FAIL  $1: expected '$3', got '$2'"; fail=1; fi; }

check "exit status" "$rc" "0"
for f in devcontainer.json Dockerfile sync-personal.js install-pi.sh post-create.sh; do
  [ -f "$TARGET/.devcontainer/$f" ] && echo "  PASS  copied $f" || { echo "  FAIL  missing $f"; fail=1; }
done
printf '%s' "$out" | grep -q '.devcontainer/.personal/' && echo "  PASS  reports gitignore entries" || { echo "  FAIL  no gitignore hint"; fail=1; }

# Refuses to clobber an existing configuration
out2="$(bash scripts/init-project.sh "$TARGET" 2>&1)"
[ $? -ne 0 ] && echo "  PASS  refuses to overwrite" || { echo "  FAIL  overwrote existing config"; fail=1; }

exit $fail
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `bash test/init-project.test.sh`
Expected: FAIL — `scripts/init-project.sh: No such file or directory`.

- [ ] **Step 3: Write the minimal implementation**

Create `scripts/init-project.sh`:

```bash
#!/usr/bin/env bash
# Copies the Go dev container template into a target project.
#   scripts/init-project.sh <target-dir>
set -euo pipefail

TARGET="${1:?usage: init-project.sh <target-dir>}"
SRC="$(cd "$(dirname "$0")/.." && pwd)/templates/go/.devcontainer"

[ -d "$SRC" ] || { echo "ERROR: template not found at $SRC" >&2; exit 1; }
[ -d "$TARGET" ] || { echo "ERROR: target directory does not exist: $TARGET" >&2; exit 1; }

if [ -e "$TARGET/.devcontainer" ]; then
  echo "ERROR: $TARGET/.devcontainer already exists — remove it first" >&2
  exit 1
fi

cp -r "$SRC" "$TARGET/.devcontainer"

cat <<'EOF'
Template installed. Add these lines to the project's .gitignore:

  .devcontainer/.personal/
  .pi/sessions/

Then open the project in VS Code and choose "Reopen in Container".
EOF
```

- [ ] **Step 4: Run the test and make sure it passes**

Run: `bash test/init-project.test.sh`
Expected: every line PASS, exit status 0.

- [ ] **Step 5: Commit**

```bash
git add scripts/init-project.sh test/init-project.test.sh
git commit -m "feat: init-project.sh to adopt the template

Refuses to overwrite an existing .devcontainer and prints the
gitignore entries the project needs."
```

---

### Task 8: Documentation

**Files:**
- Create: `LICENSE`, `README.md`
- Create: `docs/architecture.md`, `docs/decisions.md`, `docs/findings.md`, `docs/setup-windows.md`, `docs/extending.md`, `docs/comparison.md`
- Create: `test/docs.test.sh`

**Interfaces:**
- Consumes: the spec at `docs/superpowers/specs/2026-09-10-pi-devcontainer-go-design.md` as the source of all content.
- Produces: the published documentation set. Task 9 pushes it.

- [ ] **Step 1: Write the failing test**

Create `test/docs.test.sh`:

```bash
#!/usr/bin/env bash
# Test: documentation is complete, placeholder-free, and internally linked.
set -uo pipefail

fail=0
note() { echo "  FAIL  $1"; fail=1; }

REQUIRED="README.md LICENSE docs/architecture.md docs/decisions.md docs/findings.md docs/setup-windows.md docs/extending.md docs/comparison.md"
for f in $REQUIRED; do
  [ -s "$f" ] || note "missing or empty: $f"
done

if grep -rInE '\b(TBD|TODO|FIXME|XXX)\b' README.md docs/ --exclude-dir=superpowers 2>/dev/null; then
  note "placeholder markers found"
fi

# Every relative markdown link must resolve.
grep -rhoE '\]\(([^)#:]+\.md)[^)]*\)' README.md docs/ --exclude-dir=superpowers 2>/dev/null \
  | sed -E 's/^\]\(//; s/[)#].*$//' | sort -u | while read -r link; do
      [ -e "$link" ] || [ -e "docs/$link" ] || echo "  FAIL  broken link: $link"
    done | grep -q FAIL && note "broken relative links"

[ "$fail" -eq 0 ] && echo "  PASS  documentation complete"
exit $fail
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `bash test/docs.test.sh`
Expected: one FAIL line per missing file.

- [ ] **Step 3: Write the documentation**

`LICENSE`: the MIT licence text, current year, copyright holder taken from `git config user.name`.

`README.md` — what the project is, in this order:
1. One-paragraph statement: a VS Code dev container that runs pi with a lightly hardened, non-root Linux environment, first target Go.
2. Prerequisites: Docker, VS Code with the Dev Containers extension, optionally the `devcontainer` CLI.
3. Quick start: `scripts/init-project.sh <project>`, add the two gitignore lines, set the API key (link to `docs/setup-windows.md`), Reopen in Container, run `pi`.
4. What you get: table of the three layers with one line each, linking to `docs/architecture.md`.
5. The manual acceptance test, spelled out: `pi -p "say hello"` must answer without a trust prompt and must leave a file in `.pi/sessions/`. State that `scripts/verify.sh` covers everything else and deliberately makes no model call.
6. Security posture in five bullet points: non-root, all capabilities dropped except the `SYS_PTRACE` the image forces back, no `sudo`, key only via `remoteEnv`, host home never mounted. Link to `docs/findings.md`.
7. Credits: `marcfargas/pi-devcontainers` (MIT) as the origin of several ideas, linking to `docs/comparison.md`; pi; mise.
8. Licence.

`docs/architecture.md` — spec sections 5 and 6, rewritten as reference documentation: the three-layer table, the ASCII mount/volume map, the volume list with the shared/per-project split, the rationale for mounting at `~/.pi/agent/npm` rather than `~/.pi/agent`, the same-basename limitation, and a walk through what each of the three scripts does and when it runs.

`docs/decisions.md` — the nine decisions from spec section 3, one section each, in this shape: the question, the options considered, the choice, the reasoning, and the consequence you live with. Include the supplementary decisions (no `sudo`, sessions in the workspace, no live model call in verification, no CI).

`docs/findings.md` — findings F1–F8 from spec section 4, each with the reproduction command and its observed output, plus the reference environment. Add a sentence at the top telling the reader these are measurements against a specific base image and must be re-run when it changes.

`docs/setup-windows.md` — Docker Desktop; the API key via `setx ANTHROPIC_API_KEY <value>` and why VS Code must be restarted afterwards (`${localEnv:…}` is read from the environment VS Code was launched with); the CRLF trap and why `.gitattributes` matters; that `${localEnv:HOME}${localEnv:USERPROFILE}` is broken when both variables are set, which is why the template uses `initializeCommand` instead; and the note that entering the container with plain `docker exec` yields no API key.

`docs/extending.md` — how to extend without hitting a wall:
- a CLI tool: `mise use -g <tool>`, registry names vs. backends (`ubi:owner/repo` for any GitHub release, `go:`, `npm:`, `pipx:`), and where it belongs — project `mise.toml` vs. personal `mise.toml`;
- a system package: the `apt-packages` feature plus rebuild, and why there is no `sudo`;
- pi resources: packages, skills, extensions, prompts and themes, with the discovery paths `~/.pi/agent/skills/`, `~/.agents/skills/`, `.pi/skills/`, `.agents/skills/`, and the advice to prefer portable package specs over local paths because they need no host mounts;
- the project layer: a committed `mise.toml` whose Go version must be stated explicitly, because mise does not read `go.mod` by default and the `go X.Y` directive is a minimum rather than a pin (finding F7); a project `AGENTS.md`; and `.pi/settings.json` for project packages, which pi installs on startup once the project is trusted;
- the `PI_DC_PERSONAL` environment variable, which overrides the personal-layer source directory and allows several profiles side by side;
- a new volume: the Dockerfile rule from finding F8, stated as a hard requirement;
- a new language target: copy `templates/go/`, change the `FROM` line and the project `mise.toml`.

`docs/comparison.md` — spec section 2 as a fair comparison: what `marcfargas/pi-devcontainers` does, the constraint that drives its design, the six-step consequence chain, the table of findings with their evidence, what was adopted, what was not and why. Close by stating plainly that it solves a different problem well.

- [ ] **Step 4: Run the test and make sure it passes**

Run: `bash test/docs.test.sh`
Expected: `PASS  documentation complete`.

- [ ] **Step 5: Commit**

```bash
git add LICENSE README.md docs test/docs.test.sh
git commit -m "docs: architecture, decisions, findings, setup, extending, comparison

The measurements and the reasoning are the part of this project that is
hard to reproduce, so they ship as first-class documentation."
```

---

### Task 9: Publish

**Files:**
- Modify: none (repository metadata only)

**Interfaces:**
- Consumes: everything from Tasks 1–8.

- [ ] **Step 1: Verify the whole thing from a clean state**

```bash
# Remove the fixture container by its own id before its volumes can be deleted.
CID=$(devcontainer exec --workspace-folder test/fixture-go bash -c 'cat /etc/hostname' 2>/dev/null | tr -d '\r\n')
[ -n "$CID" ] && docker rm -f "$CID"
docker volume rm -f pi-dc-gomod pi-dc-gobuild pi-dc-mise \
  pi-dc-fixture-go-pinpm pi-dc-fixture-go-config pi-dc-fixture-go-hist
rm -rf test/fixture-go/.devcontainer
cp -r templates/go/.devcontainer test/fixture-go/.devcontainer
PI_DC_PERSONAL="$PWD/personal" ANTHROPIC_API_KEY=verify-dummy-not-a-real-key \
  devcontainer up --workspace-folder test/fixture-go --remove-existing-container
devcontainer exec --workspace-folder test/fixture-go bash -c 'go mod tidy && go build ./...'
ANTHROPIC_API_KEY=verify-dummy-not-a-real-key bash scripts/verify.sh
bash test/init-project.test.sh
bash test/docs.test.sh
```

Expected: `27 passed, 0 failed` from `verify.sh`, and both other test scripts pass. A cold run rebuilds the image and re-downloads all tools, so allow several minutes.

- [ ] **Step 2: Confirm no machine-specific content leaked in**

```bash
git grep -nIE "$(whoami)|AppData|Program Files|[A-Za-z]:[\\\\/]Users" -- . ':!docs/superpowers/specs' || echo "clean"
```

Expected: `clean`, or only intentional placeholder forms such as `C:\Users\<user>`. Fix anything else before publishing.

- [ ] **Step 3: Create the repository and push**

```bash
gh repo create pi-devcontainer --public --source . --remote origin --push \
  --description "VS Code dev container for the pi coding agent: hardened, non-root, mise-based tooling. First target: Go."
```

- [ ] **Step 4: Verify the published state**

```bash
gh repo view --json name,visibility,description
gh browse --no-browser
```

Expected: the repository exists, is public, and the README renders as the landing page.

- [ ] **Step 5: Commit**

Nothing to commit — the push in Step 3 is the deliverable. If Step 2 required fixes, commit them before creating the repository:

```bash
git add -A
git commit -m "chore: remove machine-specific references before publishing"
```

---

## Notes for the executor

- Every `devcontainer up` in this plan is deliberate: the checks assert runtime behaviour, and configuration edits only take effect on a fresh container. Do not skip the `--remove-existing-container` flag.
- `ANTHROPIC_API_KEY=verify-dummy-not-a-real-key` is used throughout so that V7/V7b are meaningful without a real credential. No check ever prints the value.
- The `PI_DC_PERSONAL` override is an addition beyond the approved spec, introduced so the personal layer can be tested without touching a real developer's `~/.pi/devcontainer`. It is documented in `docs/extending.md`.
- If a check fails, read `docs/findings.md` first: F1 (capabilities), F3 (`remoteEnv`), F4 (`sudo`), F8 (volume ownership) each explain a whole class of confusing symptom.
