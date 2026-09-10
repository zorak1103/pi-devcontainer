# Design: A VS Code Dev Container for pi, targeting Go

Date: 2026-09-10
Status: Approved (design), not yet implemented

## 1. Purpose

Provide a lightly hardened, VS Code–native runtime environment for the
[pi coding agent](https://pi.dev) (`@earendil-works/pi-coding-agent`) that does not
restrict pi's extensibility. The first target environment is Go.

Concretely, the environment must:

- Open with VS Code's "Reopen in Container" — no host-side wrapper CLI.
- Keep the agent away from the host filesystem, host credentials, and other repositories.
- Let any CLI tool be added in one line, without an image rebuild, because in pi's design
  CLI tools *are* the extension mechanism (pi has no MCP; see `README.md:499` of the pi package).
- Preserve pi's own extension mechanisms unchanged: packages, skills, extensions, prompts,
  themes, context files, project settings.

### Non-goals

- Network egress control. Evaluated and rejected as a default (decision D2).
- Protecting the provider API key from a compromised agent inside the container.
  The key is present in the container by design (decision D1).
- Supporting hosts other than Windows + Docker Desktop initially. The artifact is
  cross-platform by construction, but only Windows is verified for the first release.
- Replacing or wrapping the `devcontainer` CLI.

## 2. Origin and relationship to `marcfargas/pi-devcontainers`

This design started as an evaluation of [`marcfargas/pi-devcontainers`](https://github.com/marcfargas/pi-devcontainers)
(MIT). That project is not usable for this goal, for reasons that are structural rather
than incidental:

| Finding | Evidence |
|---|---|
| Not VS Code–compatible by design | It writes a merged `devcontainer.json` to `$TEMP/pidc-<ts>/` and passes `--config`. VS Code only reads `.devcontainer/devcontainer.json` from the workspace. |
| Feature image not publicly available | `ghcr.io/marcfargas/devcontainer-features/pi:0` returns `DENIED` from the GHCR token endpoint, while `devcontainers/features/go` returns a tag list. |
| Installs a different pi | `packages/feature/install.sh` installs `@mariozechner/pi-coding-agent` (npm: 0.73.1). This project targets `@earendil-works/pi-coding-agent` 0.85.1. |
| Config layout predates pi 0.85 | It mounts `~/.pi` read-only with writable overlays for `todos/` and `memoria/`. pi 0.85 writes to `~/.pi/agent/{sessions,npm}`, `trust.json`, `models-store.json`. |
| Security posture inverted | It bind-mounts the whole host `~/.pi`, including `auth.json`, into the container. |
| `npx pidc` does not resolve | npm 404 for `pidc`; the published names are `pi-devcontainers` and `@marcfargas/pi-devcontainers` (0.3.0). |

None of this is a defect of that project: it solves a different problem (running pi on a
Windows ARM host without an IDE, without touching project files). Its complexity is the
direct consequence of one constraint — "never modify the project repo" — which forces a
temp merged config, which forces `docker exec` over `devcontainer exec`, which loses
`remoteEnv`, which forces manual `TERM`/`COLORTERM`/`LANG` injection, manual `remoteUser`
resolution, and a state file for `down`/`status`.

Accepting a committed, standard `devcontainer.json` removes that entire chain.

Ideas adopted from it: an isolated pi runtime; packaging pi as a Dev Container Feature
(deferred to stage C); layered mounts separating resources from credentials;
`postCreateCommand` chaining rather than overwriting; explicit terminal/locale environment
for pi's TUI. Ideas deliberately not adopted: host-side config merging, `holdpty` session
management, read-only `~/.pi` with writable volume overlays, Windows path patching of
`settings.json`, monorepo-root mounts, and the `/mnt/host/<drive>` symlink fix — the last
three are unnecessary because this setup uses no host-path extensions.

## 3. Decisions

| # | Decision | Chosen | Rejected alternatives |
|---|---|---|---|
| D1 | Provider credentials | API key passed into the container via environment | Host-side credential broker (too much apparatus); container-local `pi /login` in a volume |
| D2 | Threat model | Filesystem blast radius + cheap container hardening | Egress filtering (breaks Go module fetches first, fails as a cryptic timeout mid-run); full hardening incl. read-only rootfs |
| D3 | Distribution | Copyable template now, Dev Container Feature later | Prebuilt base image + registry |
| D4 | Tool provisioning | `mise` as the single tool plane | Feature-per-tool (rebuild per tool, no coverage for niche tools); Dockerfile/apt (hand-written install logic, personal layer not committable) |
| D5 | Personal layer delivery | Dedicated host folder `~/.pi/devcontainer/`, copied into the container | Read-only mount of host `~/.pi/agent` (breaks `pi install`, leaks `auth.json`, carries Windows `shellPath`); everything committed in the repo |
| D6 | Go toolchain | Official `mcr.microsoft.com/devcontainers/go` image, plus one thin derived layer (see F8) | Slim base + Go feature; Go via mise |
| D7 | Delve / capabilities | Hard default, documented relaxation — superseded in part by F1 | Always-on `SYS_PTRACE`; no debugging support |
| D8 | Persistence | Expensive caches shared across projects, state per project | Everything per project (slow cold start per repo); one shared home volume (cross-project state leakage) |
| D9 | Language and license | English throughout; MIT | German; mixed-language docs |

Supplementary decisions made while designing:

- `no-new-privileges` is kept, so `sudo` does not work inside the container. System packages
  are added declaratively via `ghcr.io/devcontainers-extra/features/apt-packages` plus a rebuild.
- pi sessions are redirected into the workspace (`.pi/sessions`), removing the need for a
  session volume.
- Verification does not perform a live model call; `pi -p` is a documented manual test.
- No CI in the first release.

## 4. Measured findings

These were measured on the target host (Docker 29.7.2, linux/amd64 engine, Windows host,
`devcontainer` CLI 0.89.0, VS Code 1.137) and must be re-checked when the base image
changes. Reproduction commands belong in `docs/findings.md`.

**F1 — The Go image re-adds `SYS_PTRACE` and `seccomp=unconfined`.**
The image label `devcontainer.metadata` carries, from the Go feature,
`"init": true, "capAdd": ["SYS_PTRACE"], "securityOpt": ["seccomp=unconfined"]`.
The CLI appends these *after* `runArgs`:

```
docker run … --cap-drop=ALL --security-opt no-new-privileges --init \
             --cap-add SYS_PTRACE --security-opt seccomp=unconfined …
```

Net effect measured inside the container: `CapEff = 0000000000080000` (only `CAP_SYS_PTRACE`,
versus `0xa80425fb` by default), `NoNewPrivs: 1`, `Seccomp: 2` (a filter is loaded even with
`unconfined` on this host, including in a plain `docker run`).

Consequence: `SYS_PTRACE` cannot be removed without overriding the metadata label in a
custom Dockerfile. This is accepted. Delve therefore works out of the box, and the
"commented-out relaxation line" from D7 is unnecessary and must not be added.

**F2 — `${localEnv:HOME}${localEnv:USERPROFILE}` is broken here.**
Git Bash sets `HOME` in addition to `USERPROFILE`, so the idiom concatenates both:
`C:\Users\zorakC:\Users\zorak/.pi/devcontainer`, and container creation fails.
Resolution: no host-home mount. `initializeCommand` in array form runs Node (which the CLI
ships anyway, avoiding all host-shell differences) and copies the personal layer into the
workspace. Verified: `cwd` is the workspace folder, the copy succeeds, and a missing source
is silently tolerated.

**F3 — `remoteEnv` keeps the secret out of `docker inspect`.**

| Mechanism | `docker inspect` | `devcontainer exec` / VS Code terminal | plain `docker exec` |
|---|---|---|---|
| `containerEnv` | visible | yes | yes |
| `remoteEnv` | **not present** | yes | empty |

Consequence: the API key goes through `remoteEnv` only. pi must be started from a VS Code
terminal or `devcontainer exec`; entering via plain `docker exec` yields no key.

**F4 — `no-new-privileges` disables `sudo`.**
`sudo: The "no new privileges" flag is set, which prevents sudo from running as root.`
The cause is `no-new-privileges`, not the capability drop.

**F5 — Base image contents.**
`mcr.microsoft.com/devcontainers/go:1.27-bookworm` provides `go1.27.1`, and `gopls`, `dlv`,
`golangci-lint`, `staticcheck` in `/go/bin`, `GOPATH=/go`, `git`, `remoteUser: vscode`, and
the `golang.Go` extension plus `go.gopath` settings via image metadata.
**Node and npm are absent** — only an `nvm` installation without a Node version. pi needs Node,
so the Node feature is mandatory.

**F6 — Availability checks.**
Verified as resolvable: `ghcr.io/devcontainers/features/go` (1.3.4),
`ghcr.io/devcontainers/features/node` (2.1.0), `ghcr.io/devcontainers-extra/features/mise` (1.0.0),
`ghcr.io/devcontainers-extra/features/apt-packages` (1.0.6),
`mcr.microsoft.com/devcontainers/go` (1.25/1.26/1.27 on bookworm and trixie, amd64 + arm64).
In the mise registry: `jq`, `yq`, `glab`, `typst`, `golangci-lint`, `ripgrep`, and
`github-cli` (= `gh`, via `aqua:cli/cli`). Not in the registry, therefore via backends:
`jira-cli` (`ubi:`), `gopls`/`dlv` (`go:`). Backends `ubi`, `go`, `aqua`, `npm`, `pipx` all
documented and reachable.

**F7 — mise does not read `go.mod` by default.**
Idiomatic version files are disabled by default, and the `go X.Y` directive is a minimum,
not a pin (deprecated as a version source in mise, to be removed in 2026.11.0). Project Go
versions must be declared explicitly in `mise.toml`.

**F8 — Named volumes on paths absent from the image are created root-owned.**
This breaks the entire volume plan of section 5, because `no-new-privileges` (F4) leaves no
`sudo` to repair ownership afterwards. Measured with fresh volumes as user `vscode`:

```
drwxr-xr-x 2 root root /go/pkg/mod
drwxr-xr-x 2 root root /home/vscode/.cache/go-build
touch: cannot touch '/go/pkg/mod/x': Permission denied
```

Neither `/go/pkg` nor `/home/vscode/.cache` exists in the base image (`/go` itself does, as
`vscode:golang`). Docker initializes an empty named volume from the image directory at the
mount point — including its ownership — but creates the directory as `root` when it is absent.

Resolution: a single derived image layer that creates all six mount targets and chowns them
to `vscode`. Verified working: all three test mounts came up `vscode:vscode` and writable.
The `devcontainer.metadata` label is inherited by the derived image (verified: 5 entries,
`remoteUser: vscode`), so the `golang.Go` extension, `go.gopath`, and the non-root user
survive the change.

A side benefit, not used for now: this layer is also the place where the metadata label could
be overridden to remove the `SYS_PTRACE` that F1 forces back in.

## 5. Architecture

Everything entering the container comes from exactly one of three layers.

| Layer | Location | Contents | Owner |
|---|---|---|---|
| Base | `devcontainer.json` in the project | Go image, Node feature, mise feature, pi installation, hardening | this template repo |
| Personal | host `~/.pi/devcontainer/` | pi `settings.json`, `mise.toml`, global `AGENTS.md`, optional `skills/` | the individual developer, across projects |
| Project | committed in the project repo | `mise.toml`, `.pi/settings.json`, `AGENTS.md`, `.devcontainer/` | the team |

The personal layer is **copied, never mounted**, so it stays writable in the container and
the host copy is never modified. The project layer is self-provisioning: pi installs missing
packages from `.pi/settings.json` at startup.

### Mount and volume map

```
Host (Windows)                        Container (linux/amd64, user vscode)
┌──────────────────────────┐          ┌───────────────────────────────────────┐
│ project/  ───────────────┼─ bind ──▶│ /workspaces/<project>          (RW)   │
│   .pi/sessions/  ◀───────┼──────────┤   pi sessions written here            │
│   .devcontainer/.personal┼◀ copy ───┤   (written on host by initializeCmd)  │
│                          │          │                                       │
│ ~/.pi/devcontainer/  ────┼─ COPY ──▶│ ~/.pi/agent/{settings.json,AGENTS.md} │
│   (never mounted)        │          │ ~/.config/mise/config.toml            │
│                          │          │                                       │
│ ANTHROPIC_API_KEY  ──────┼remoteEnv▶│ (process environment only)            │
│ ~/.pi/agent/auth.json    │  never   │                                       │
└──────────────────────────┘          └───────────────────────────────────────┘

Named volumes, shared across projects:
  pi-dc-gomod      → /go/pkg/mod                      Go module cache
  pi-dc-gobuild    → ~/.cache/go-build                Go build cache
  pi-dc-mise       → ~/.local/share/mise              tool downloads

Named volumes, per project (suffix = workspace folder basename):
  pi-dc-<p>-pinpm  → ~/.pi/agent/npm                  pi packages
  pi-dc-<p>-config → ~/.config                        gh/glab/jira logins
  pi-dc-<p>-hist   → ~/.history                       shell history (HISTFILE)
```

The pi volume is mounted at `~/.pi/agent/**npm**`, not at `~/.pi/agent`. Package installs
must survive rebuilds (D8), but `settings.json` must be re-copied from the personal layer on
every create. A volume one level up would freeze the first copy and silently ignore every
later change to `~/.pi/devcontainer/settings.json`.

Deliberately not persisted: `auth.json` (never enters), `trust.json` and `models.json`
(cheap to regenerate), the workspace itself (already on the host).

All six volume mount points must exist in the image and be owned by `vscode` before the
volume is attached, otherwise they are created root-owned and unusable (F8). This is what
the derived image layer in 6.1 exists for.

Known limitation: two projects whose folders have the same basename share the "per project"
volumes. Documented, with a manual suffix as the workaround.

## 6. Artifacts

### 6.1 `templates/go/.devcontainer/devcontainer.json`

```jsonc
{
  "name": "go-pi",
  "build": { "dockerfile": "Dockerfile" },

  "features": {
    "ghcr.io/devcontainers/features/node:2": { "version": "22" },
    "ghcr.io/devcontainers-extra/features/mise:1": {}
  },

  "runArgs": ["--cap-drop=ALL", "--security-opt", "no-new-privileges"],

  "containerEnv": {
    "PATH": "/home/vscode/.local/share/mise/shims:${containerEnv:PATH}",
    "MISE_DATA_DIR": "/home/vscode/.local/share/mise",
    "MISE_GLOBAL_CONFIG_FILE": "/home/vscode/.config/mise/config.toml",
    "MISE_TRUSTED_CONFIG_PATHS": "/workspaces",
    "PI_VERSION": "0.85.1",
    "PI_CODING_AGENT_SESSION_DIR": "${containerWorkspaceFolder}/.pi/sessions",
    "HISTFILE": "/home/vscode/.history/.bash_history",
    "LANG": "C.UTF-8",
    "COLORTERM": "truecolor"
  },

  "remoteEnv": {
    "ANTHROPIC_API_KEY": "${localEnv:ANTHROPIC_API_KEY}"
  },

  "mounts": [
    "source=pi-dc-gomod,target=/go/pkg/mod,type=volume",
    "source=pi-dc-gobuild,target=/home/vscode/.cache/go-build,type=volume",
    "source=pi-dc-mise,target=/home/vscode/.local/share/mise,type=volume",
    "source=pi-dc-${localWorkspaceFolderBasename}-pinpm,target=/home/vscode/.pi/agent/npm,type=volume",
    "source=pi-dc-${localWorkspaceFolderBasename}-config,target=/home/vscode/.config,type=volume",
    "source=pi-dc-${localWorkspaceFolderBasename}-hist,target=/home/vscode/.history,type=volume"
  ],

  "initializeCommand": ["node", ".devcontainer/sync-personal.js"],
  "onCreateCommand":   "bash .devcontainer/install-pi.sh",
  "postCreateCommand": "bash .devcontainer/post-create.sh",

  "customizations": {
    "vscode": { "settings": { "go.toolsManagement.checkForUpdates": "off" } }
  }
}
```

Non-obvious points, all load-bearing:

- **Shims first in `PATH`.** pi's `bash` tool spawns non-interactive shells where shell-init
  hooks such as `mise activate` do not apply. Only the shims directory in `PATH` makes tools
  visible to the agent. Intended side effect: a project pinning Go in `mise.toml` wins over
  `/usr/local/go`.
- **`onCreate` before `postCreate`.** Ordering is guaranteed; the object form of
  `postCreateCommand` would run entries in parallel. Hence two hooks instead of one.
- **Hooks invoke `bash` explicitly** rather than relying on the executable bit, which a
  Windows checkout does not preserve.
- **`golang.Go` is intentionally absent** from `customizations`: the extension, `go.gopath`,
  and `remoteUser: vscode` already arrive via the image metadata label (F5).
- **No `capAdd`/`securityOpt` entries**, because they are additive and cannot subtract what
  the image metadata contributes (F1).
- **`build` instead of `image`**, solely to own the volume mount points (F8). The base image
  and its metadata are otherwise untouched.

### 6.1b `templates/go/.devcontainer/Dockerfile`

One layer, one purpose: make every volume mount point exist and belong to `vscode`.

```dockerfile
FROM mcr.microsoft.com/devcontainers/go:1.27-bookworm

# Named volumes are created root-owned when the target path is absent from the image,
# and no-new-privileges leaves no sudo to repair that afterwards. See docs/findings.md F8.
RUN mkdir -p /go/pkg/mod \
             /home/vscode/.cache/go-build \
             /home/vscode/.local/share/mise \
             /home/vscode/.pi/agent/npm \
             /home/vscode/.config \
             /home/vscode/.history \
 && chown -R vscode:vscode /go/pkg /home/vscode
```

The Go version is pinned by the `FROM` line; changing it is a one-line edit plus a rebuild.

### 6.2 `templates/go/.devcontainer/sync-personal.js`

Runs on the **host** before container creation. Node is used because the CLI ships it, which
avoids every host-shell difference; array form avoids shell quoting entirely.

Behaviour:
1. Resolve `path.join(os.homedir(), '.pi', 'devcontainer')`.
2. Create `<cwd>/.devcontainer/.personal/`.
3. If the source exists, `fs.cpSync(src, dest, { recursive: true })`.
4. Print one line stating what was copied, or that the personal layer is absent.
5. Never fail the container start because the personal layer is missing.

### 6.3 `templates/go/.devcontainer/install-pi.sh` (onCreate)

This file is deliberately standalone: it is what becomes the Dev Container Feature's
`install.sh` in stage C.

```bash
#!/usr/bin/env bash
set -euo pipefail
command -v npm >/dev/null || { echo "ERROR: node/npm missing — check the node feature"; exit 1; }
npm install -g --ignore-scripts "@earendil-works/pi-coding-agent@${PI_VERSION:-latest}"
pi --version
```

`--ignore-scripts` is the documented install form (pi `quickstart.md:10`). `PI_VERSION` is
pinned in `containerEnv` so that upgrading pi is an explicit one-line change.

### 6.4 `templates/go/.devcontainer/post-create.sh` (postCreate)

```bash
#!/usr/bin/env bash
set -euo pipefail
P=".devcontainer/.personal"
mkdir -p ~/.pi/agent ~/.pi/agent/skills ~/.config/mise "$PI_CODING_AGENT_SESSION_DIR"

# Personal layer: refreshed on every create, never mounted, always writable
[ -f "$P/settings.json" ] && cp    "$P/settings.json" ~/.pi/agent/settings.json
[ -f "$P/AGENTS.md"     ] && cp    "$P/AGENTS.md"     ~/.pi/agent/AGENTS.md
[ -f "$P/mise.toml"     ] && cp    "$P/mise.toml"     ~/.config/mise/config.toml
[ -d "$P/skills"        ] && cp -r "$P/skills/."      ~/.pi/agent/skills/

[ -n "${ANTHROPIC_API_KEY:-}" ] || echo "WARNING: ANTHROPIC_API_KEY is empty — see docs/setup-windows.md"

mise install
mise reshim
```

Every copy step is conditional: a missing personal layer degrades to pi defaults rather than
failing the create.

### 6.5 `personal/` — template for `~/.pi/devcontainer/`

`settings.json` is the host settings file **minus `shellPath`**, which points at
`…/git/current/bin/bash.exe` and does not exist in the container; leaving it in would break
every `bash` tool call.

```json
{
  "theme": "light",
  "defaultProjectTrust": "always",
  "packages": ["npm:pi-quit-aliases", "npm:tintinweb/pi-subagents", "npm:pi-claude-marketplace"],
  "modelThinkingLevels": { "bars/claude-sonnet-5": "high" }
}
```

```toml
# mise.toml — cross-project personal tools
[tools]
jq = "latest"
yq = "latest"
"github-cli" = "latest"                  # gh
glab = "latest"
typst = "latest"
"ubi:ankitpokhrel/jira-cli" = "latest"   # registry gap; ubi is the universal escape hatch
```

`AGENTS.md` (global) tells the agent what kind of environment it is in. Without it the agent
burns turns on `sudo apt install`:

```markdown
# Environment
You are running inside a dev container (Debian, non-root user `vscode`), not on the host.
- No `sudo`, no `apt install`. This is intentional, not broken.
- New CLI tool: `mise use -g <tool>` (backends: aqua, ubi, go, npm, pipx).
- System packages require an entry in `.devcontainer/devcontainer.json` plus a rebuild.
- Writable: /workspaces/<project> and the caches. The host is unreachable.
- Sessions are stored in `.pi/sessions` inside the project.
```

### 6.6 Project layer (documented, created per project)

`mise.toml` for the project toolchain — the Go version must be explicit because of F7:

```toml
[tools]
go = "1.27"
"golangci-lint" = "2"
```

`AGENTS.md` for project conventions, `.pi/settings.json` for project packages, and
`.gitignore` entries:

```
.devcontainer/.personal/
.pi/sessions/
```

The personal layer lands inside the workspace folder, therefore: **no secrets in
`~/.pi/devcontainer/`.** The API key travels via `remoteEnv` and nothing else.

### 6.7 `scripts/`

- `init-project.sh <target>` — copies `templates/go/.devcontainer` into a target project and
  prints the `.gitignore` lines to add.
- `verify.sh` — the acceptance checks of section 8, run inside a live container.

## 7. Trust model

`defaultProjectTrust: "always"` in the container's pi settings, plus
`MISE_TRUSTED_CONFIG_PATHS=/workspaces`.

This is a deliberate lowering of a pi safeguard. A hostile repository gets its project
extensions executed at pi startup, and its `mise.toml` may set environment variables. The
justification is that the trust boundary is the container wall, not a line inside it; the
benefit is no trust prompts and working non-interactive `pi -p` runs.

Two qualifications: `AGENTS.md` and other context files are loaded regardless of trust
(pi `security.md:27`), so this setting does not govern prompt-injection exposure at all. And
when reviewing untrusted third-party repositories, the correct countermeasure is a separate
container, not `defaultProjectTrust: "ask"`.

## 8. Failure modes and verification

### Failure modes

| Case | Symptom | Handling |
|---|---|---|
| CRLF line endings in `.sh` | `bad interpreter: /usr/bin/env bash^M` | `.gitattributes` with `*.sh text eol=lf` — the most likely first failure on Windows |
| Missing executable bit | `permission denied` | hooks call `bash .devcontainer/…` explicitly |
| Node missing | pi install fails late and cryptically | explicit `command -v npm` check with a clear message |
| `ANTHROPIC_API_KEY` unset | `${localEnv:…}` silently becomes empty; pi asks for `/login` | visible warning in `post-create.sh`; `docs/setup-windows.md` covers `setx` and the required VS Code restart |
| Personal layer absent | — | all copy steps conditional |
| Tool absent from mise registry | — | documented escape hatches `ubi:`, `go:`, `npm:`, `pipx:` |
| System package needed | no `sudo` (intended) | `apt-packages` feature plus rebuild, explained in the global `AGENTS.md` |
| A feature's postinstall needs `sudo` | create fails | surfaced by V6 during the build, not weeks later |
| Two projects with the same folder name | shared "per project" volumes | documented; manual volume suffix as workaround |
| A new volume is added without a matching directory in the Dockerfile | `permission denied` on first write, unfixable without `sudo` | F8; V9 checks every mount point; `docs/extending.md` states the rule |
| Entering via plain `docker exec` | no API key | intended consequence of `remoteEnv` (F3); documented |

### Verification (`scripts/verify.sh`)

The work is done when these pass, executed inside the running container:

| # | Check | Expectation |
|---|---|---|
| V1 | `pi --version` | `0.85.1` (matches `PI_VERSION`) |
| V2 | `pi list` | the three packages installed |
| V3 | `bash -c 'command -v jq gh typst go'` | all found in a **non-interactive** shell (the shim/`PATH` trap) |
| V4 | `go build ./...` in a scratch module | succeeds; `/go/pkg/mod` populated |
| V5 | `grep CapEff /proc/self/status` | `0000000000080000` (only `SYS_PTRACE`) |
| V6 | `sudo -n true` | **must fail** — hardening verified negatively |
| V7 | `docker inspect <container>` filtered for `ANTHROPIC` | no match |
| V8 | `whoami` | `vscode` — non-root confirmed |
| V9 | all six volume mount points | owned by `vscode` and writable (F8) |
| V10 | second `devcontainer up` after `--remove-existing-container` | caches survive, noticeably faster |

One manual test, deliberately outside `verify.sh` because it costs a live model call:
`pi -p "say hello"` must answer without a trust prompt, and must leave a session file in
`.pi/sessions/` on the host. Documented in `README.md`.

V5, V6, and V7 are the substantive ones: they check that the hardening is *actually in
effect* rather than merely present in the configuration. F1 is exactly the case where a
configuration-only reading would have been wrong.

No unit test framework and no CI in the first release. The artifact is one JSON file, a
six-line Dockerfile, and three short scripts; a smoke test against a real container carries
more information than mocks. Stage C (the feature) changes this and warrants a build test.

## 9. Repository and documentation

The repository is published on GitHub. Documentation is a primary deliverable, not an
afterthought: the value of this work is in the reasoning and the measurements, which are not
documented in one place anywhere else.

```
README.md                      what/why, prerequisites, quick start, credits
LICENSE                        MIT
.gitattributes                 *.sh text eol=lf
docs/
├─ architecture.md             three-layer model, mount/volume map
├─ decisions.md                the nine decisions with alternatives and rationale
├─ findings.md                 the measurements, with reproduction commands
├─ setup-windows.md            Docker Desktop, API key via setx, VS Code restart
├─ extending.md                tools (mise/ubi), system packages, skills, packages,
│                              adding a new language target
├─ comparison.md               analysis of marcfargas/pi-devcontainers
└─ superpowers/specs/          this document
templates/go/.devcontainer/    the artifact (devcontainer.json, Dockerfile, 3 scripts)
personal/                      template for ~/.pi/devcontainer/
scripts/                       init-project.sh, verify.sh
```

Attribution: `marcfargas/pi-devcontainers` is MIT-licensed. Ideas are adopted, no code is
copied, so there is no legal obligation — but credit belongs in the README, and
`comparison.md` is written as a fair comparison of two designs solving different problems.

Language: English throughout. License: MIT.

## 10. Stage C — the Dev Container Feature (future)

`install-pi.sh` is already cut to become a feature's `install.sh`. The step then consists of
a `devcontainer-feature.json`, publishing to GHCR, and replacing the `onCreateCommand` with
a `features` entry. Everything else stays. Adding further language targets
(`templates/python/`, `templates/node/`) becomes cheap at that point, because only the base
image and the project-layer `mise.toml` differ.
