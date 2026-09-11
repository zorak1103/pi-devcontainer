# Decisions

Each section states the question, what was considered, what was chosen, and what the choice
costs. That last part is usually missing from design documents.

## D1 — Where the provider credentials live

**Chosen:** the API key is passed into the container through `remoteEnv`.

Rejected: a host-side credential broker, which keeps the key out of the container entirely
but adds a moving part to every launch; and authenticating inside the container with a
container-local volume, which is clean but makes every fresh container a login.

**Cost:** the key is inside the container. A compromised agent can read it. This is accepted
explicitly, and it is why the threat model below is about blast radius rather than secrecy.
`remoteEnv` at least keeps it out of `docker inspect`. See [findings.md](findings.md#f3--remoteenv-keeps-the-secret-out-of-docker-inspect).
See [threat-model.md](threat-model.md).

## D2 — What the hardening defends against

**Chosen:** filesystem blast radius plus the cheap container hardening: non-root,
`--cap-drop=ALL`, `no-new-privileges`.

Rejected: network egress filtering. It is the obvious next step and it was declined
deliberately. Go projects hit it first and hardest: module proxies, private registries, and
`GOPROXY` fail in ways that present as a cryptic timeout in the middle of an agent run
rather than as a clear "blocked". A control that gets disabled after two days of friction is
worse than no control, because you stop thinking about it. Also rejected: a read-only root
filesystem, which fights pi's own writes.

**Cost:** an agent that can reach the network can exfiltrate. This setup bounds what a
misbehaving agent can *touch*, not what it can *tell*. See [threat-model.md](threat-model.md).

## D3 — How the environment reaches a project

**Chosen:** a copyable template (`scripts/init-project.sh`), with a Dev Container Feature as
the later step.

Rejected for now: publishing a prebuilt base image, which would cut container start time but
requires a registry and a release process before anything has proven itself; and starting
with a Feature, which is the right end state but premature before the mount strategy is
settled.

**Cost:** updating the template in a project is a re-copy. `install-pi.sh` is already written
as a standalone script so the move to a Feature is mechanical.

## D4 — How tools that are not in the base image get in

**Chosen:** mise as a single tool plane. Tools are declared in TOML and installed at container
create.

Rejected: one Dev Container Feature per tool, which bakes tools into the image but makes
every new tool an image rebuild and has no coverage for niche tools; and hand-written
`Dockerfile` installs, which means writing download and architecture logic per tool.

This decision carries more weight than it appears to. pi has no MCP. Its extension mechanism
is CLI tools with documentation. If adding a tool is expensive, the agent's capabilities
ossify. mise's `ubi:`/`github:` backend installs any GitHub release, so there is no ceiling.

**Cost:** one more abstraction, network access at container create, and a cache volume to
make rebuilds fast.

## D5 — How the personal layer reaches the container

**Chosen:** a dedicated host directory `~/.pi/devcontainer/`, copied in.

Rejected: mounting the host `~/.pi/agent` read-only. It needs no maintenance, but read-only
breaks `pi install` and `pi update`, a Windows `shellPath` in those settings points at a
`bash.exe` that does not exist in the container, and `auth.json` would have to be actively
masked; an omission there leaks credentials silently. Also rejected: committing personal
preferences into each project repository.

**Cost:** a second settings file to maintain. In exchange the host configuration is never
touched and there is no path-rewriting machinery.

## D6 — Where the Go toolchain comes from

**Chosen:** the official `mcr.microsoft.com/devcontainers/go` image, plus one thin derived
layer.

Rejected: a slim base plus the Go feature, and installing Go through mise. The official image
already carries `gopls`, `dlv`, `golangci-lint`, `staticcheck`, the non-root user and the
matching VS Code settings; reproducing that to save a few hundred megabytes trades working
integration for image size.

mise remains available as an override: a project that pins Go in `mise.toml` wins, because
the shims come first on `PATH`.

**Cost:** the image is about a gigabyte, and its metadata dictates part of the security
posture ([F1](findings.md#f1--the-go-image-re-adds-sys_ptrace-and-seccompunconfined)).

## D7 — Delve and capabilities

**Chosen:** drop everything; accept the one capability the image forces back.

The original intent was a hard default with a documented relaxation for debugging. Measuring
[F1](findings.md#f1--the-go-image-re-adds-sys_ptrace-and-seccompunconfined) made that moot:
`SYS_PTRACE` cannot be removed without overriding the image's metadata label, so Delve works
and the commented-out relaxation line would have been theatre.

**Cost:** one capability more than the ideal. The ceiling is one instead of fourteen.

## D8 — What survives a rebuild

**Chosen:** expensive caches shared across all projects, state kept per project. pi sessions
go to `.pi/sessions` inside the workspace, which removes a volume entirely and puts sessions
on the host next to the work they describe.

Rejected: strict per-project isolation, which makes every new project pay the full download
cost; and a single shared home volume, which would let one project read another's sessions
and tokens.

**Cost:** the shared module cache is a cross-project write path. A malicious agent in one
project could in principle poison it for another. The cache is content-addressed and `go.sum`
catches tampering, which is what makes the trade acceptable. It is a trade, not a non-issue.

Measured payoff: a full container rebuild with warm caches takes about ten seconds.

## D9 — Language and license

**Chosen:** English throughout, MIT.

**Cost:** none worth noting. The design conversation happened in German; the repository is
for whoever finds it.

## Supplementary decisions

**No `sudo`.** Keeping `no-new-privileges` means system packages are declared in
`devcontainer.json` and applied by a rebuild. This is more reproducible than ad-hoc
`apt install`, and the rebuild costs seconds with warm caches. The cost is friction the first
time you need a package.

**`mise install` is non-fatal.** A single unresolvable tool aborted an entire container
creation during development ([F12](findings.md#f12--one-unresolvable-tool-aborted-the-whole-container-creation)).
The personal layer is hand-edited, and a typo in it must not leave you without an environment
in which to fix it. It fails loudly and continues.

**No live model call in the acceptance checks.** `verify.sh` is meant to be runnable freely,
which it would not be if every run cost tokens. The one test that needs a model is documented
as manual in the README.

**No CI initially.** The artifact is one JSON file, a short Dockerfile and three scripts; a
smoke test against a real container says more than mocks would. A Feature release would
change that.

## Trust inside the container

pi runs with `defaultProjectTrust: "always"` and mise with
`MISE_TRUSTED_CONFIG_PATHS=/workspaces`.

This is a deliberate lowering of a safeguard. A hostile repository gets its project
extensions executed when pi starts, and its `mise.toml` may set environment variables. The
justification is that the trust boundary is the container wall rather than a line inside it,
and the benefit is concrete: no trust prompts, and non-interactive `pi -p` works.

Two qualifications keep this honest. `AGENTS.md` and other context files are loaded
regardless of trust, so this setting does not govern prompt-injection exposure at all. And
when you are reviewing an untrusted third-party repository, the countermeasure is a separate
container, not `defaultProjectTrust: "ask"`.
