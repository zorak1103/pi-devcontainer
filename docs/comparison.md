# Comparison with `marcfargas/pi-devcontainers`

[`marcfargas/pi-devcontainers`](https://github.com/marcfargas/pi-devcontainers) (MIT) was the
starting point for this project. It was evaluated, found unsuitable for this particular goal,
and several of its ideas were adopted anyway. This document records both halves honestly,
because "we looked at X and wrote our own" is worth nothing without saying why.

## What it does

`pidc` is a host-side CLI that wraps the `devcontainer` CLI. It reads your project's
`devcontainer.json`, reads pi's `settings.json`, resolves extension and skill paths, merges
everything into a temporary `devcontainer.json`, launches the container, and starts pi inside
it through [holdpty](https://github.com/marcfargas/holdpty) so the session survives detaching.

Its motivation is stated plainly in its README: pi on a Windows ARM host hits native module
builds, path separator differences and symlink behaviour. Running pi in a Linux container
solves all of it at once.

## The constraint that shapes it

One design decision drives most of the rest: **the project's `devcontainer.json` is never
modified.** From there, six consequences follow with no room to manoeuvre:

1. The merged configuration must live in a temporary directory, referenced with `--config`.
2. The `devcontainer` CLI's `exec` cannot find that configuration, so `docker exec` is used
   instead.
3. `docker exec` does not apply `remoteEnv`, so terminal and locale variables must be
   injected explicitly with `-e` on every call.
4. `remoteUser` must be resolved by hand, and the container home derived from it.
5. The CLI has no `down`/`status`, so a state file maps workspaces to container IDs.
6. Because the whole pi configuration directory is mounted, Windows paths inside
   `settings.json` must be rewritten and a patched copy mounted over the original.

Its `DEVIATIONS.md` documents all of this candidly, which is more than most projects do.

## Why it does not fit this goal

| Finding | Evidence |
|---|---|
| Not VS Code–compatible, by design | VS Code reads only `.devcontainer/devcontainer.json` from the workspace. A temp config passed via `--config` is invisible to it. "Attach to Running Container" is the closest workaround and loses `remoteEnv` and the lifecycle hooks. |
| The Feature image is not publicly available | `ghcr.io/marcfargas/devcontainer-features/pi:0` returns `DENIED` from the GHCR token endpoint, where `devcontainers/features/go` returns a tag list. |
| It installs a different pi | `packages/feature/install.sh` installs `@mariozechner/pi-coding-agent` (npm 0.73.1). This project targets `@earendil-works/pi-coding-agent` 0.85.1, and the Feature has no option for the package name. |
| The configuration layout predates pi 0.85 | It mounts `~/.pi` read-only with writable overlays for `todos/` and `memoria/`. pi 0.85 writes to `~/.pi/agent/{sessions,npm}`, `trust.json` and `models-store.json`. |
| The security posture is inverted relative to this goal | The entire host `~/.pi` is bind-mounted in, including `auth.json`. |
| `npx pidc` does not resolve | npm returns 404 for `pidc`; the published names are `pi-devcontainers` and `@marcfargas/pi-devcontainers`. |

None of these are defects in its own terms. It is not trying to integrate with VS Code, and
mounting the pi configuration is the point when your goal is "my host pi setup, but on Linux".

## What was adopted

- **An isolated pi runtime.** `pidc` installs Node and pi into `/opt/pi` so they cannot
  collide with the project's toolchain. Here the same separation comes from the Node feature
  plus a pinned pi version, with `install-pi.sh` deliberately written as a standalone script
  so it can become a Feature's `install.sh` later, which is `pidc`'s architecture, arrived at
  from the other direction.
- **Packaging pi as a Dev Container Feature.** The right end state; deferred until the rest
  is proven.
- **Layered mounts separating resources from credentials.** The mechanism is reused; the
  contents differ, because credentials stay out here.
- **Chaining rather than overwriting lifecycle commands.**
- **Explicit terminal and locale environment.** pi's TUI needs truecolor and UTF-8, and no
  base image guarantees them.

## What was not adopted, and why

- **Host-side configuration merging.** Accepting a committed `devcontainer.json` deletes the
  entire consequence chain above. VS Code then reads the same file the CLI does.
- **`holdpty` session management.** With VS Code, "run pi" is opening a terminal and typing
  `pi`. The attach/detach machinery and its state file solve a problem that only exists
  without an IDE.
- **Read-only `~/.pi` with writable volume overlays.** Copying a small, purpose-built
  configuration in is simpler than mounting the real one read-only and patching holes in it,
  and it cannot leak `auth.json` by omission.
- **Windows path patching of `settings.json`, monorepo-root mounts, and the
  `/mnt/host/<drive>` symlink fix.** All three exist to support extensions referenced by
  local host paths. Using pi *packages* instead (portable specs that install inside the
  container) removes the need for all of them. This was the single largest simplification.

## The honest summary

Two projects, two problems. `pi-devcontainers` answers "how do I run my existing host pi
setup on Linux without touching my repositories", and for that its design is coherent,
including the parts that look heavy from outside. This project answers "how do I give an
agent a hardened, VS Code–native environment I can extend freely", and for that the same
constraint would have been a liability.
