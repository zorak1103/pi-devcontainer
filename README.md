# pi-devcontainer

A VS Code dev container that runs the [pi coding agent](https://pi.dev) in a lightly
hardened, non-root Linux environment, without restricting anything pi can do. The first
target environment is Go.

The agent gets a real toolchain and a workspace it can write to. It does not get your host
filesystem, your SSH keys, your other repositories, or your pi credentials. Adding a new CLI
tool is one line and no image rebuild, which matters more than it sounds: pi has no MCP, so
[CLI tools *are* the extension mechanism](docs/extending.md).

## Prerequisites

- Docker (Docker Desktop on Windows or macOS)
- VS Code with the **Dev Containers** extension
- Git, with Git Bash on Windows (needed for `git clone` anyway, and the shell the scripts
  below run in)
- Optional, for the acceptance checks: the [`devcontainer` CLI](https://github.com/devcontainers/cli)

## Quick start

```bash
git clone https://github.com/zorak1103/pi-devcontainer
cd pi-devcontainer
./scripts/init-project.sh /path/to/your/go-project
```

(Windows: run these in Git Bash, not PowerShell or cmd, since the scripts are `.sh` files.)

Add the two lines the script prints to your project's `.gitignore`, set your API key once
(see [docs/setup-windows.md](docs/setup-windows.md); on Windows this needs a VS Code
restart; for OpenRouter or another provider, see [docs/providers.md](docs/providers.md)),
then open the project in VS Code and choose **Reopen in Container**. In the
container's terminal:

```bash
pi
```

Optionally, create `~/.pi/devcontainer/` for settings, tools and context that follow you
across projects. [`personal/`](personal/) is a working template. Without it the container
still comes up, with pi's defaults.

## What you get

| Layer | Lives in | Holds |
|---|---|---|
| Base | `devcontainer.json` in your project | Go image, Node, mise, pi, the hardening flags |
| Personal | `~/.pi/devcontainer/` on your host | your pi settings, model/provider config, MCP servers, Claude plugins, your tools, your global `AGENTS.md` |
| Project | committed in the repo | project toolchain, `AGENTS.md`, project pi settings |

The personal layer is **copied** into the container, never mounted, so it stays writable
inside and untouched outside. Details in [docs/architecture.md](docs/architecture.md).

## Verifying an installation

```bash
./scripts/verify.sh /path/to/your/go-project
```

30 checks against the live container: pi's version, the packages, tools reachable from a
*non-interactive* shell, a real Go build, the capability ceiling, that `sudo` is refused,
that the API key is absent from `docker inspect`, and that every volume is writable.

`verify.sh` deliberately makes **no model call**. One test is therefore manual:

```bash
pi -p "say hello"
```

It must answer without a trust prompt and leave a session file in `.pi/sessions/`.

## Security posture

Lightly hardened, and the emphasis is on *lightly*: this bounds the blast radius of a
misbehaving agent, it does not contain a determined attacker. Non-root, capabilities dropped
to one, `no-new-privileges`, the API key kept out of `docker inspect`, the host home never
mounted. Just as deliberately out of scope: the key still lives in the container, and
network egress is unrestricted. See [docs/threat-model.md](docs/threat-model.md).

## Documentation

| Document | Contents |
|---|---|
| [architecture.md](docs/architecture.md) | the three layers, the mount and volume map, what each script does |
| [decisions.md](docs/decisions.md) | every design decision, its alternatives, and what it costs |
| [findings.md](docs/findings.md) | measurements against the real base image, with reproduction commands |
| [setup-windows.md](docs/setup-windows.md) | Docker Desktop, the API key, the CRLF trap |
| [how-to.md](docs/how-to.md) | recipes: add/remove a pi package, persist an extension's config, set up a new project |
| [providers.md](docs/providers.md) | configuring OpenRouter, other API-key providers, and self-hosted/proxied endpoints |
| [threat-model.md](docs/threat-model.md) | what the hardening bounds, and what it explicitly does not |
| [extending.md](docs/extending.md) | adding tools, system packages, pi resources, new language targets |
| [comparison.md](docs/comparison.md) | how this relates to `marcfargas/pi-devcontainers` |

If you read one, read [findings.md](docs/findings.md). Half of this project's design exists
because a measurement contradicted a reasonable assumption.

## Credits

- [pi](https://pi.dev) by earendil-works.
- [`marcfargas/pi-devcontainers`](https://github.com/marcfargas/pi-devcontainers) (MIT):
  the origin of several ideas here, including the isolated pi runtime and the layered-mount
  approach. It solves a different problem: running pi on a Windows ARM host without an IDE.
  [comparison.md](docs/comparison.md) explains what was adopted and what was not.
- [mise](https://mise.jdx.dev) for the tool plane.

## License

[MIT](LICENSE)
