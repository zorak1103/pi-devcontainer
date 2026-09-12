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

## Add an MCP server

[`pi-mcp-adapter`](https://github.com/nicobailon/pi-mcp-adapter) gives pi access to MCP
servers through one proxy tool instead of loading every server's full tool schema. Worked
example: [Context7](https://context7.com/) (up-to-date library docs), added globally.

1. Add the package (see "Add a global pi package" above):

   ```json
   { "packages": ["npm:pi-mcp-adapter"] }
   ```

2. Declare the server in `~/.pi/devcontainer/mcp.json`. It lands at `~/.pi/agent/mcp.json`,
   the adapter's own global-override path, and the personal-layer copy list already includes
   it (`post-create.sh`, no per-project edit needed for this file):

   ```json
   {
     "mcpServers": {
       "context7": {
         "url": "https://mcp.context7.com/mcp",
         "headers": { "Authorization": "Bearer ${CONTEXT7_API_KEY}" }
       }
     }
   }
   ```

   `headers` (and `env`, for stdio servers) interpolate `${VAR}` from the process
   environment; nothing pi-specific needed on the server side.

3. Get the secret into the container the same way as any other API key
   ([setup-windows.md](setup-windows.md#the-api-key), [decisions.md#d1](decisions.md#d1--where-the-provider-credentials-live)):
   add it to the **project's** `devcontainer.json`, since `remoteEnv` is project layer, not
   personal layer:

   ```jsonc
   "remoteEnv": { "CONTEXT7_API_KEY": "${localEnv:CONTEXT7_API_KEY}" }
   ```

   then, once per machine:

   ```cmd
   setx CONTEXT7_API_KEY <your-key>
   ```

   (restart VS Code fully; see setup-windows.md for why). Repeat the `remoteEnv` line in
   every project that should reach that server, same as any other provider key: it is not
   part of the personal layer and does not propagate on its own.

4. Rebuild. Run `/mcp` inside pi to confirm the server is registered.

For project-shared servers instead of personal ones, use `.mcp.json` in the project repo
instead of the personal `mcp.json`; see the adapter's own README for the full precedence
order between the two.

## Install Claude Code plugins via pi-claude-marketplace

[`pi-claude-marketplace`](https://github.com/acolomba/pi-claude-marketplace) loads Claude
Code plugin marketplaces (commands, skills, agents, hooks, MCP servers) into pi. Worked
example: `commit-commands`, from the official marketplace.

1. Add the package. `pi-subagents` and `pi-mcp-adapter` are optional but recommended (agent-
   and MCP-backed plugins need them):

   ```json
   { "packages": ["npm:pi-claude-marketplace", "npm:pi-subagents", "npm:pi-mcp-adapter"] }
   ```

2. Declare the desired state in `~/.pi/devcontainer/claude-plugins.json` (also part of the
   fixed personal-layer copy list, landing at `~/.pi/agent/claude-plugins.json`):

   ```json
   {
     "schemaVersion": 1,
     "marketplaces": {
       "claude-plugins-official": {
         "source": "anthropics/claude-plugins-official",
         "autoupdate": true
       }
     },
     "plugins": { "commit-commands@claude-plugins-official": {} }
   }
   ```

   No `/claude:plugin` command needed: pi reconciles this file automatically at its own
   session start ([findings.md#f16](findings.md#f16--the-claude-pluginsjson-sync-runs-at-session-start-not-at-pi-update)).

3. Rebuild. The template's `Dockerfile`/`devcontainer.json` already provision a
   `pi-dc-<project>-claudeplugins` volume for the resulting clones
   ([findings.md#f15](findings.md#f15--pi-claude-marketplace-clones-outside-the-npm-volume)), so
   only the first rebuild pays the clone cost.

4. Confirm inside pi: `/claude:plugin list --installed`, then use the plugin (here, any
   `commit-commands` command).

To add a marketplace pi-claude-marketplace does not know about yet, use
`/claude:plugin marketplace add <owner>/<repo>` interactively once, then copy the resulting
`~/.pi/agent/claude-plugins.json` back into `~/.pi/devcontainer/claude-plugins.json` to make
it permanent, the same pattern as "Make an extension's own config file persist" above.

### Plugins that need `--partial`

A plugin that declares unsupported components (an unmappable hook, an LSP server, a theme --
listed with `/claude:plugin list --partial`) cannot go in `claude-plugins.json`'s `plugins`
map at all: the declarative config has no field for `--partial`, so reconcile always attempts
a full install and fails with `(failed) {no longer installable}`, every time, on every
container
([findings.md#f17](findings.md#f17--claude-pluginsjson-cannot-declare-a-partially-installable-plugin)).
`superpowers`, for example, needs it for its hooks.

Leave that plugin out of the declarative config (its marketplace can still be declared) and
install it once, interactively, per container:

```text
/claude:plugin install --partial superpowers@claude-plugins-official
```

The resulting record lives in `~/.pi/agent/pi-claude-marketplace/state.json`, covered by the
same volume as the clones, so it survives rebuilds of that container. A fresh volume needs
the command again.

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
