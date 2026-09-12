# Findings

Everything here was measured, not assumed. Several of these contradicted a reasonable
assumption and changed the design; three were caught only when a check failed during
implementation.

They are measurements against a specific base image and a specific Docker version. **Re-run
them when the base image changes.** Every finding carries the command that produced it.

Reference environment: Docker 29.7.2 with a linux/amd64 engine on a Windows host,
`devcontainer` CLI 0.89.0, VS Code 1.137, `mcr.microsoft.com/devcontainers/go:1.27-bookworm`.

## F1 — The Go image re-adds `SYS_PTRACE` and `seccomp=unconfined`

```bash
docker inspect mcr.microsoft.com/devcontainers/go:1.27-bookworm \
  --format '{{index .Config.Labels "devcontainer.metadata"}}'
```

The label carries, from the Go feature:
`{"id":"ghcr.io/devcontainers/features/go:1","init":true,"capAdd":["SYS_PTRACE"],"securityOpt":["seccomp=unconfined"],…}`

The CLI appends these **after** your `runArgs`:

```
docker run … --cap-drop=ALL --security-opt no-new-privileges \
             --init --cap-add SYS_PTRACE --security-opt seccomp=unconfined …
```

`capAdd` and `securityOpt` in `devcontainer.json` are additive; there is no way to subtract
what image metadata contributes, short of overriding the label in a derived image. Accepted:
the net result is one capability instead of fourteen, and Delve debugging works out of the
box.

## F2 — `${localEnv:HOME}${localEnv:USERPROFILE}` is broken when both are set

The common cross-platform idiom for the host home directory assumes exactly one of the two
variables is empty. Git Bash sets `HOME` **in addition to** `USERPROFILE`, so the mount source
became `C:\Users\<user>C:\Users\<user>/.pi/devcontainer` and container creation failed.

Resolution: no host-home mount at all. `initializeCommand` runs Node, which the devcontainer
CLI ships anyway, in array form, sidestepping both host-shell differences and shell quoting.

## F3 — `remoteEnv` keeps the secret out of `docker inspect`

```bash
docker inspect <container> --format '{{json .Config.Env}}' | grep ANTHROPIC   # no match
devcontainer exec --workspace-folder . bash -c 'printenv ANTHROPIC_API_KEY'   # present
docker exec <container> sh -c 'echo ${ANTHROPIC_API_KEY:-<empty>}'            # empty
```

| Mechanism | `docker inspect` | `devcontainer exec` / VS Code | plain `docker exec` |
|---|---|---|---|
| `containerEnv` | visible | yes | yes |
| `remoteEnv` | **absent** | yes | empty |

Consequence, and it is a real one: entering the container with plain `docker exec` gives you
no API key. Start pi from a VS Code terminal or through `devcontainer exec`.

## F4 — `no-new-privileges` disables `sudo`

```
$ sudo -n true
sudo: The "no new privileges" flag is set, which prevents sudo from running as root.
```

The capability drop is not the cause; `no-new-privileges` is. This is the intended posture,
and it means system packages are declared and rebuilt rather than installed ad hoc. See
[extending.md](extending.md#system-packages).

## F5 — The base image has no Node

```bash
docker run --rm mcr.microsoft.com/devcontainers/go:1.27-bookworm \
  bash -lc 'go version; which node npm gopls dlv golangci-lint staticcheck git'
```

`go1.27.1`, and `gopls`, `dlv`, `golangci-lint`, `staticcheck` in `/go/bin`, `GOPATH=/go`,
`git` present. **`node` and `npm` are absent**: the image ships a prepared `nvm` with no Node
version installed. pi needs Node, so the Node feature is not optional.

## F6 — Availability of images, features and tools

Resolvable at the time of writing: `ghcr.io/devcontainers/features/go` (1.3.4),
`ghcr.io/devcontainers/features/node` (2.1.0), `ghcr.io/devcontainers-extra/features/mise`
(1.0.0), `ghcr.io/devcontainers-extra/features/apt-packages` (1.0.6),
`mcr.microsoft.com/devcontainers/go` (1.25/1.26/1.27 on bookworm and trixie, amd64 + arm64).

In the mise registry: `jq`, `yq`, `glab`, `typst`, `golangci-lint`, `ripgrep`, and
`github-cli` (which is `gh`). Absent from it and reached through backends: `jira-cli`,
`gopls`, `dlv`.

## F7 — mise does not read `go.mod` by default

Idiomatic version files are disabled by default, and `go.mod`'s `go X.Y` directive is a
minimum rather than a pin; mise deprecated it as a version source. Declare the project's Go
version explicitly in `mise.toml`.

## F8 — Named volumes on paths absent from the image are created root-owned

```bash
docker run --rm -u vscode -v testvol:/go/pkg/mod \
  mcr.microsoft.com/devcontainers/go:1.27-bookworm \
  sh -c 'ls -ld /go/pkg/mod; touch /go/pkg/mod/x'
```

```
drwxr-xr-x 2 root root /go/pkg/mod
touch: cannot touch '/go/pkg/mod/x': Permission denied
```

Docker initialises an empty named volume from the image directory at the mount point,
including its ownership, but creates that directory as `root` when it does not exist.
Neither `/go/pkg` nor `/home/vscode/.cache` exists in the base image. Combined with F4 there
is no `sudo` to repair it afterwards, so the module cache, build cache, tool directory and pi
package directory would all have been unusable.

Resolution: one derived image layer that creates all seven mount points and chowns them. The
`devcontainer.metadata` label is inherited by the derived image (verified: five entries,
`remoteUser: vscode`), so the `golang.Go` extension, `go.gopath` and the non-root user
survive.

## F9 — `${containerEnv:VAR}` is not resolved inside `containerEnv`

Setting `"PATH": "/home/vscode/.local/share/mise/shims:${containerEnv:PATH}"` in
`containerEnv` produced this in the `docker run` command line:

```
-e PATH=/home/vscode/.local/share/mise/shims:${containerEnv:PATH}
```

The reference was passed through literally. `PATH` became a broken string and the container
exited immediately with `container … is not running`. The reference works in `remoteEnv`,
which resolves against the already-created container; inside `containerEnv` it would have to
resolve against itself.

Resolution: set `PATH` in the `Dockerfile`. A value baked into the image also survives a
plain `docker exec`, which `remoteEnv` would not.

## F10 — A non-root process has no effective capabilities, so `CapEff` proves nothing

The first version of the capability check asserted `CapEff: 0000000000080000`, taken from an
earlier measurement made as `root` via `docker exec`. The container runs as `vscode`:

```
CapPrm: 0000000000000000
CapEff: 0000000000000000
CapBnd: 0000000000080000
```

`CapEff` is zero for any non-root process regardless of hardening: an unhardened container
shows the same zero. The bounding set `CapBnd` is where `--cap-drop=ALL` is visible, and it
is also the ceiling that would survive a setuid transition. The check now asserts both: the
ceiling is one capability, and the process holds none.

A check that passes for the wrong reason is worse than no check.

## F11 — Bind-mounted files are root-owned, so git refuses to run

```
$ git status
fatal: detected dubious ownership in repository at '/workspaces/<project>'
$ stat -c '%U:%G' /workspaces/<project>/.git
root:root
$ id -u
1000
```

The immediate symptom was not a git error but a build failure:

```
$ go build ./...
error obtaining VCS status: exit status 128
        Use -buildvcs=false to disable VCS stamping.
```

Go stamps VCS information into binaries and shells out to git to do it. The same ownership
mismatch breaks the VS Code git integration.

Resolution: `post-create.sh` registers the workspace and its ancestors up to `/workspaces` as
`safe.directory`. This is narrower than the usual `safe.directory '*'` and still covers the
case where the mount root is the repository root, which is what the devcontainer CLI does
when the workspace folder sits inside a git repository.

## F12 — One unresolvable tool aborted the whole container creation

`ubi:ankitpokhrel/jira-cli` failed with `could not find any files matching [jira-cli*] in the
downloaded archive file`: the release ships a binary called `jira`, not one named after the
repository. `mise install` exited non-zero, `set -euo pipefail` propagated it, and
`postCreateCommand` failed, leaving no usable container.

Two fixes, both worth having:

- `aqua:ankitpokhrel/jira-cli` instead. The aqua registry knows the archive layout, so no
  per-tool options are needed. (The `ubi:` backend is also deprecated in favour of `github:`.)
- `mise install` is now non-fatal and prints a warning. The personal layer is hand-edited;
  a typo in it must not leave you without an environment to fix it from.

## F13 — The image already ships some of the tools you might add

`jq` exists at `/usr/bin/jq` in the base image. A check asserting only that `command -v jq`
succeeds would have passed without mise being involved at all. The tool checks therefore
assert the **shim path** (`…/shims/jq`), which is what actually proves the mechanism works.

## F14 — Global pi packages install on the next invocation, with no trust prompt

```bash
mkdir -p /tmp/agent && echo '{"packages": ["npm:pi-zentui"]}' > /tmp/agent/settings.json
PI_CODING_AGENT_DIR=/tmp/agent pi -p "say hi"
```

```
added 1 package, and audited 2 packages in 782ms
found 0 vulnerabilities
[model call follows, unrelated to the install]
```

Copying `settings.json` into `~/.pi/agent/` does not by itself fetch the packages it
declares. pi checks for missing packages at its own startup instead, and it did that here on
a plain `-p` run, before the prompt was even sent. No trust prompt appeared, because trust
only gates project-local files (`.pi/settings.json` and friends); `~/.pi/agent/settings.json`
is outside that boundary.

This is enough to make `personal/settings.json`'s `packages` entry work unattended, but the
fetch happens at the first `pi` invocation inside the container, which is whenever the
developer types something, not at container creation. A first prompt that also has to hit the
npm registry is a slower and less predictable first prompt. `post-create.sh` now runs
`pi update --extensions` right after copying `settings.json`, so the fetch happens during
`postCreateCommand` instead, same as pi's own install in `install-pi.sh`.

## F15 — pi-claude-marketplace clones outside the npm volume

```bash
PI_CODING_AGENT_DIR=/tmp/agent pi update --extensions   # pi-claude-marketplace declared
PI_CODING_AGENT_DIR=/tmp/agent pi -p "say hi"            # claude-plugins.json declared
find /tmp/agent -maxdepth 1
```

```
/tmp/agent/auth.json
/tmp/agent/claude-plugins.json
/tmp/agent/npm
/tmp/agent/pi-claude-marketplace
/tmp/agent/sessions
/tmp/agent/settings.json
```

A declarative `claude-plugins.json` behaves like F14's `packages`: a plain `pi` invocation
reads it and clones whatever marketplaces and plugins it declares, unattended, no `/claude:
plugin` command needed. But the clones (a full git checkout per plugin, and one per
marketplace) land in `~/.pi/agent/pi-claude-marketplace/`, a sibling of `~/.pi/agent/npm/`,
not inside it. The existing `pi-dc-<project>-pinpm` volume covers only `npm/`, so without a
second volume, every container rebuild re-clones every declared marketplace and plugin from
GitHub from scratch.

Resolution: a second per-project volume, `pi-dc-<project>-claudeplugins`, mounted at
`~/.pi/agent/pi-claude-marketplace`. Same F8 rule applies: the path does not exist in the
base image, so it needs the same `mkdir`/`chown` treatment in the `Dockerfile` as every other
mount point.

## F16 — The claude-plugins.json sync runs at session start, not at `pi update`

```bash
PI_CODING_AGENT_DIR=/tmp/agent pi update --extensions   # as in F15
find /tmp/agent -maxdepth 1 -iname pi-claude-marketplace   # nothing yet
PI_CODING_AGENT_DIR=/tmp/agent pi --offline --no-session -p "noop"
find /tmp/agent -maxdepth 1 -iname pi-claude-marketplace   # now present
```

Unlike F14's package fetch, `pi update --extensions` does not run pi-claude-marketplace's
desired-state sync at all; nothing is cloned until an actual `pi` session starts, because the
sync is wired to the extension's session-start hook, not to the update command. `--offline`
does not stop it either: it disables pi's own startup network operations (self-update and
model-catalog checks), and the marketplace/plugin clone is the extension's own network call,
outside that scope.

`post-create.sh` covers this with a throwaway `pi --offline --no-session -p "noop"` right
after `pi update --extensions`. The model call is expected to fail (no real prompt, and
credentials may not even be configured yet at this point in the container's life); only the
side effect, the sync, is wanted. `--no-session` keeps that throwaway run out of
`.pi/sessions/`.
