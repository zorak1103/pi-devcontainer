# Extending the environment

The point of this setup is that extending it is cheap. pi has no MCP: its extension mechanism
is CLI tools with documentation, plus its own packages and skills. If adding a tool were
expensive, the agent's capabilities would freeze at whatever the image happened to ship.

## CLI tools

Declare the tool in a `mise.toml` and rebuild. Or, inside a running container, run
`mise use -g <tool>` and it is available immediately.

Where it goes depends on who needs it:

| Scope | File | Example |
|---|---|---|
| Everyone working on this project | `mise.toml` in the project repo | `golangci-lint`, `mockgen`, `buf` |
| You, in every project | `mise.toml` in `~/.pi/devcontainer/` | `jq`, `gh`, `glab`, `typst` |

Registry names work directly:

```toml
[tools]
jq = "latest"
yq = "latest"
"github-cli" = "latest"   # provides `gh`
typst = "latest"
```

When a tool is not in the registry, name a backend explicitly:

| Backend | Use for | Example |
|---|---|---|
| `aqua:` | anything the aqua registry knows, including odd archive layouts | `"aqua:ankitpokhrel/jira-cli" = "latest"` |
| `github:` | any GitHub release | `"github:owner/repo" = "latest"` |
| `go:` | Go tools | `"go:golang.org/x/tools/gopls" = "latest"` |
| `npm:`, `pipx:` | ecosystem tools | `"npm:prettier" = "latest"` |

Two traps worth knowing in advance:

**The binary may not be named after the repository.** `ankitpokhrel/jira-cli` ships a binary
called `jira`, and the plain release backend looks for `jira-cli*` and fails. Either use
`aqua:`, which knows the layout, or pass `github:owner/repo[exe=<name>]`.

**A failing tool no longer breaks the container.** `mise install` is deliberately non-fatal
and prints a warning; the other tools still install. Read the `postCreate` output when a tool
seems missing. Background:
[findings.md](findings.md#f12--one-unresolvable-tool-aborted-the-whole-container-creation).

To confirm a tool is genuinely reachable by the agent, check the shim path rather than mere
availability. The image already ships some tools of its own:

```bash
command -v jq     # want: /home/vscode/.local/share/mise/shims/jq
```

## System packages

There is no `sudo`; `no-new-privileges` disables it, and that is the intended posture. System
packages are declared, not installed by hand:

```jsonc
"features": {
  "ghcr.io/devcontainers-extra/features/apt-packages:1": {
    "packages": "postgresql-client,poppler-utils"
  }
}
```

Then rebuild the container. With warm caches this takes seconds, and the result is
reproducible for everyone who opens the project, which ad-hoc `apt install` never is.

## pi resources

**Packages are the portable form.** A package spec needs no host paths and no mounts, so it
survives the trip into a container unchanged:

```json
{ "packages": ["npm:some-pi-package", "git:github.com/user/repo"] }
```

Put them in `~/.pi/devcontainer/settings.json` for yourself, or in the project's
`.pi/settings.json` for the team: pi installs missing project packages at startup. Prefer
this over local-path extensions, which would need a mount and a path rewrite for every
developer.

**The personal copy alone does not fetch anything.** pi checks for missing packages at its
own startup, not when `settings.json` lands in `~/.pi/agent/`, and for the personal layer
that means the first `pi` invocation inside the container, not container creation (see
[findings.md](findings.md#f14--global-pi-packages-install-on-the-next-invocation-with-no-trust-prompt)).
`post-create.sh` runs `pi update --extensions` right after the copy so the fetch happens
during `postCreateCommand` instead, before anyone has typed a prompt:

```bash
[ -f "$P/settings.json" ] && pi update --extensions
```

`pi update --extensions` installs anything declared but missing and updates anything already
installed, so one line covers both. It needs no `--approve`: global packages carry no
project-trust gate, unlike `.pi/settings.json` in the project.

**A package with its own config file needs its own copy line.** `pi-zentui`, for example,
keeps its settings in `~/.pi/agent/zentui.json`, written by its own `/zentui` command, not in
`settings.json`. The personal layer's copy list in `post-create.sh` only knows a fixed set of
names (`settings.json`, `models.json`, `mcp.json`, `claude-plugins.json`, `AGENTS.md`,
`mise.toml`), so add the file there yourself:

```bash
[ -f "$P/zentui.json" ] && cp "$P/zentui.json" ~/.pi/agent/zentui.json
```

Configure the package once inside a container, copy the resulting file to
`~/.pi/devcontainer/` on the host, and every later rebuild keeps it.

**Skills** are discovered from, in order of scope:

| Path | Scope |
|---|---|
| `~/.pi/agent/skills/` | global; put files in `~/.pi/devcontainer/skills/` and they land here |
| `~/.agents/skills/` | global, cross-agent convention |
| `.pi/skills/` | project |
| `.agents/skills/` in the workspace and its ancestors | project, cross-agent convention |

**Context files.** `AGENTS.md` is loaded from `~/.pi/agent/AGENTS.md` (the personal layer
supplies it) and from the workspace and its ancestors. The shipped global one tells the agent
it is in a container without `sudo` and how to add tools, which is worth keeping: otherwise
the agent spends turns trying `sudo apt install`.

## The project layer

Three files, all committed:

```
mise.toml            project toolchain
AGENTS.md            project conventions for the agent
.pi/settings.json    project pi packages and settings
```

State the Go version explicitly in `mise.toml`:

```toml
[tools]
go = "1.27"
```

mise does **not** read `go.mod` by default, and its `go X.Y` directive is a minimum rather
than a pin ([findings.md](findings.md#f7--mise-does-not-read-gomod-by-default)).

Add to the project's `.gitignore`:

```
.devcontainer/.personal/
.pi/sessions/
```

## Adding a volume

If you add a named volume to `devcontainer.json`, **add its directory to the `Dockerfile`
too**:

```dockerfile
RUN mkdir -p /home/vscode/.cache/your-tool \
 && chown -R vscode:vscode /home/vscode/.cache/your-tool
```

Docker creates a missing mount point as `root`, and there is no `sudo` to repair it: the
first write fails and cannot be fixed from inside. This is not optional; see
[findings.md](findings.md#f8--named-volumes-on-paths-absent-from-the-image-are-created-root-owned).
`scripts/verify.sh` checks every mount point for ownership and writability, so add your new
path to its `MOUNTS` list as well.

## Several personal profiles

`sync-personal.js` reads `PI_DC_PERSONAL` if set, otherwise `~/.pi/devcontainer`. Point it
elsewhere to switch profiles, or to test a profile without touching your real one:

```bash
PI_DC_PERSONAL=~/profiles/minimal devcontainer up --workspace-folder .
```

## A new language target

Copy `templates/go/` to `templates/<language>/` and change two things:

1. the `FROM` line in the `Dockerfile`. The
   [devcontainer images](https://github.com/devcontainers/images) cover most ecosystems, and
   they all follow the same `vscode`-user convention this template relies on.
2. the project `mise.toml` in your project.

Everything else (pi installation, personal layer, hardening, volumes) is
language-independent. Keep the `mkdir`/`chown` block: only the language-specific cache path
changes (`/go/pkg/mod` becomes `~/.cache/pip`, `~/.npm`, `~/.cargo`, and so on).
