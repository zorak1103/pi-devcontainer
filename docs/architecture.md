# Architecture

## Three layers

Everything that enters the container comes from exactly one of three layers. When you wonder
where a piece of configuration belongs, this table answers it.

| Layer | Location | Contents | Owner |
|---|---|---|---|
| Base | `.devcontainer/` in the project | Go image, Node feature, mise feature, pi installation, hardening | this template |
| Personal | `~/.pi/devcontainer/` on the host | pi `settings.json`, `models.json`, `mcp.json`, `mise.toml`, global `AGENTS.md`, optional `skills/` | one developer, across all projects |
| Project | committed in the project repo | `mise.toml`, `.pi/settings.json`, `AGENTS.md` | the team |

Two properties make this work:

**The personal layer is copied, not mounted.** A read-only mount of a host config directory
would leave the container unable to write to it, and pi writes: `pi install`, `pi update`,
model catalogs. Copying gives the container a writable copy while the host original stays
untouched. The copy is refreshed on every container create, so editing the host file and
rebuilding is the update mechanism.

**The project layer provisions itself.** pi installs missing packages from
`.pi/settings.json` at startup, so a teammate who clones the repo needs nothing from you.

## Mount and volume map

```
Host                                  Container (linux/amd64, user vscode, uid 1000)
┌──────────────────────────┐          ┌───────────────────────────────────────┐
│ project/  ───────────────┼─ bind ──▶│ /workspaces/<project>          (RW)   │
│   .pi/sessions/  ◀───────┼──────────┤   pi sessions written here            │
│   .devcontainer/.personal┼◀ copy ───┤   (written on the host, then copied   │
│                          │          │    into the container by postCreate)  │
│                          │          │                                       │
│ ~/.pi/devcontainer/  ────┼─ COPY ──▶│ ~/.pi/agent/{settings.json,models.json│
│   (never mounted)        │          │   mcp.json,AGENTS.md}                 │
│                          │          │ ~/.config/mise/config.toml            │
│                          │          │                                       │
│ ANTHROPIC_API_KEY  ──────┼remoteEnv▶│ (process environment only)            │
│ ~/.pi/agent/auth.json    │  never   │                                       │
└──────────────────────────┘          └───────────────────────────────────────┘
```

### Volumes

Shared across all projects: these are caches, and sharing them is the difference between a
ten-second and a five-minute container rebuild:

| Volume | Mount point | Holds |
|---|---|---|
| `pi-dc-gomod` | `/go/pkg/mod` | Go module cache |
| `pi-dc-gobuild` | `~/.cache/go-build` | Go build cache |
| `pi-dc-mise` | `~/.local/share/mise` | downloaded tools |

Per project, named after the workspace folder: these hold state, and state should not leak
between projects:

| Volume | Mount point | Holds |
|---|---|---|
| `pi-dc-<project>-pinpm` | `~/.pi/agent/npm` | installed pi packages |
| `pi-dc-<project>-config` | `~/.config` | `gh`, `glab`, `jira` logins |
| `pi-dc-<project>-hist` | `~/.history` | shell history |

Two details in that table are deliberate and easy to get wrong:

**The pi volume sits on `~/.pi/agent/npm`, not `~/.pi/agent`.** Package installs should
survive rebuilds, but `settings.json` must be re-copied from the personal layer every time.
A volume one level up would freeze the first copy, and every later edit to your personal
settings would be silently ignored.

**Every volume mount point must exist in the image, owned by `vscode`.** Docker creates a
missing mount point as `root`, and `no-new-privileges` leaves no `sudo` to repair it. This is
why there is a `Dockerfile` at all (see [findings.md](findings.md), finding F8). If you add a
volume, add its directory there too.

Known limitation: two projects whose folders share a basename share the "per project"
volumes. Rename one, or give it explicit volume names.

## Lifecycle

Four hooks run in a fixed order. Splitting them across files is not cosmetic: `install-pi.sh`
is standalone so it can become a Dev Container Feature's `install.sh` without edits.

| Stage | File | Runs | Does |
|---|---|---|---|
| `initializeCommand` | `sync-personal.js` | on the **host**, before the container exists | copies `~/.pi/devcontainer/` to `.devcontainer/.personal/` in the workspace |
| image build | `Dockerfile` | at build time | creates and chowns the volume mount points, puts the mise shims first on `PATH` |
| `onCreateCommand` | `install-pi.sh` | in the container, once | checks for npm, installs the pinned pi version |
| `postCreateCommand` | `post-create.sh` | in the container, after that | applies the personal layer, fetches its declared pi packages, registers the git safe directory, runs `mise install` |

`sync-personal.js` runs Node rather than a shell script because the devcontainer CLI ships
Node and the host shell differs per platform. It never fails the container start: a missing
personal layer is a supported configuration.

`PATH` is set in the `Dockerfile`, not in `containerEnv`. Two reasons: `${containerEnv:PATH}`
is not resolved inside `containerEnv` itself; it is passed through literally and breaks the
container. A value baked into the image also applies to a plain `docker exec`.

The mise shims directory comes **first** on `PATH`. pi's `bash` tool spawns non-interactive
shells, where shell-init hooks such as `mise activate` never run. A tool that is only
reachable through shell init is invisible to the agent, which is a confusing failure: you
see the tool in your terminal, the agent reports "command not found". A side effect worth
knowing: a project that pins Go in `mise.toml` wins over the image's `/usr/local/go`.

## Trust

The container sets `defaultProjectTrust: "always"` for pi and
`MISE_TRUSTED_CONFIG_PATHS=/workspaces` for mise. Both are deliberate reductions of a
safeguard, justified by the container boundary rather than waved away. See
[decisions.md](decisions.md#trust-inside-the-container).
