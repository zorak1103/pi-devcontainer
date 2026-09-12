# How-to

Short recipes for common tasks. For the mechanism behind each one, see
[architecture.md](architecture.md) and [extending.md](extending.md); for why a step is
there at all, see [findings.md](findings.md).

## Add a global pi package

For yourself, across every project built from this template.

1. Edit `~/.pi/devcontainer/settings.json` (create it if it does not exist):

   ```json
   { "packages": ["npm:some-pi-package"] }
   ```

2. Rebuild the container, or, in an already-running one, apply it without a rebuild:

   ```bash
   cp .devcontainer/.personal/settings.json ~/.pi/agent/settings.json  # already current if you rebuilt
   pi update --extensions
   ```

`post-create.sh` runs that same `pi update --extensions` on every container creation, so a
rebuild is normally enough on its own
([findings.md#f14](findings.md#f14--global-pi-packages-install-on-the-next-invocation-with-no-trust-prompt)).
No trust prompt appears: global packages are outside the project trust boundary.

## Add a pi package for the whole team

Project-local, committed, so a teammate gets it without touching their personal layer.

1. From inside the project (in the container or on the host with pi installed):

   ```bash
   pi install -l npm:some-pi-package
   ```

   This writes `.pi/settings.json`. `.pi/npm/` is where it gets fetched to; pi writes its own
   `.gitignore` there, so only `.pi/settings.json` ends up committed.

2. Commit `.pi/settings.json`.

A teammate who pulls it gets a trust prompt the first time they run `pi` in the project,
unless their personal `settings.json` sets `"defaultProjectTrust": "always"` (the shipped
[`personal/settings.json`](../personal/settings.json) does, justified in
[decisions.md](decisions.md#trust-inside-the-container)). Either way, once trusted, pi
installs the missing package on that same startup, no separate step needed.

## Remove a package

```bash
pi remove npm:some-pi-package        # global
pi remove -l npm:some-pi-package     # project-local
```

Removes it from the relevant `settings.json`; it stops loading on the next start. Delete
`~/.pi/agent/npm/node_modules/<pkg>` (or the project's `.pi/npm/`) yourself if you also want
the fetched files gone, or leave them: an unlisted package already installed on disk is
inert.

## Make an extension's own config file persist across rebuilds

Worked example: [`pi-zentui`](https://github.com/lmilojevicc/pi-zentui) keeps its settings in
`~/.pi/agent/zentui.json`, written by its own `/zentui` command, not in `settings.json`. Any
package that manages its own config file outside `settings.json` follows the same pattern.

1. Install the package (see the two recipes above) and configure it inside a running
   container (here, `/zentui`).
2. Copy the file it wrote back to the host:

   ```bash
   # from the host, via the devcontainer CLI:
   devcontainer exec --workspace-folder . cat ~/.pi/agent/zentui.json > ~/.pi/devcontainer/zentui.json
   ```

3. Add a copy line for it in the project's `post-create.sh`, next to the existing personal
   layer copies (`settings.json`, `models.json`, `AGENTS.md`, `mise.toml`):

   ```bash
   [ -f "$P/zentui.json" ] && cp "$P/zentui.json" ~/.pi/agent/zentui.json
   ```

   The stock template does not ship this line for every possible package's config file; add
   it for whichever ones you actually use.

4. Commit that `post-create.sh` change. Rebuild: the configuration is back.

## Carry your own tools, skills and context across every project

Already-working examples ship in [`personal/`](../personal/); copy what you want into
`~/.pi/devcontainer/`:

| File | Effect |
|---|---|
| `mise.toml` | personal CLI tools (`jq`, `gh`, ...), see [extending.md](extending.md#cli-tools) |
| `skills/` | lands in `~/.pi/agent/skills/`, global across projects |
| `AGENTS.md` | your own global context, merged with the project's `AGENTS.md` |
| `settings.json` | pi settings: theme, packages, `defaultProjectTrust`, model thinking levels |

All of it is copied, not mounted, so editing the host file and rebuilding is the update
mechanism; see [architecture.md](architecture.md#three-layers).

## Set up a new project from this template

```bash
git clone https://github.com/zorak1103/pi-devcontainer
cd pi-devcontainer
./scripts/init-project.sh /path/to/your/go-project
```

Full walkthrough, including the `.gitignore` entries it prints and the API key setup, in the
[README quick start](../README.md#quick-start).
