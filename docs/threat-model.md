# Threat Model

What this container's hardening is meant to bound, and what it explicitly is not. Short by
design: the reasoning behind each point lives in [decisions.md](decisions.md), the
measurements behind that reasoning in [findings.md](findings.md).

## In scope: blast radius of a misbehaving agent

The premise is that the agent inside the container will run arbitrary shell commands on your
behalf, including ones it got wrong or was tricked into. The goal is bounding what that can
*touch*.

- **Runs as non-root** (`vscode`, uid 1000) — see [D2](decisions.md#d2--what-the-hardening-defends-against).
- **Capabilities dropped to one.** `--cap-drop=ALL`, with `SYS_PTRACE` forced back by the base
  image's own metadata — [F1](findings.md#f1--the-go-image-re-adds-sys_ptrace-and-seccompunconfined).
- **`no-new-privileges`,** so `sudo` does not work even though the binary is present —
  [F4](findings.md#f4--no-new-privileges-disables-sudo).
- **The API key is not visible in `docker inspect`.** It reaches the container only through
  `remoteEnv` — [F3](findings.md#f3--remoteenv-keeps-the-secret-out-of-docker-inspect).
- **Your host home is never mounted.** The personal layer is copied, not bind-mounted, and
  `~/.pi/agent/auth.json` never enters the container — [D5](decisions.md#d5--how-the-personal-layer-reaches-the-container).

## Out of scope, by explicit decision

**The API key is inside the container.** A compromised agent can read it — remoteEnv keeps it
out of `docker inspect`, nothing more. This is why the model is about blast radius, not
secrecy — [D1](decisions.md#d1--where-the-provider-credentials-live).

**Network egress is unrestricted.** An agent that can reach the network can exfiltrate.
Egress filtering was considered and rejected: it breaks Go module proxies and private
registries in ways that surface as a cryptic mid-run timeout rather than a clear "blocked",
and a control that gets disabled after two days of friction is worse than no control —
[D2](decisions.md#d2--what-the-hardening-defends-against).

**The shared module cache is a cross-project write path.** `pi-dc-gomod` and `pi-dc-gobuild`
are shared across all projects for rebuild speed. A malicious agent in one project could in
principle poison a cached module for another. Content addressing and `go.sum` catch tampering,
which is what makes the trade acceptable — but it is a trade —
[D8](decisions.md#d8--what-survives-a-rebuild).

**Trust is deliberately lowered inside the container.** `defaultProjectTrust: "always"` and
`MISE_TRUSTED_CONFIG_PATHS=/workspaces` mean a hostile repository's project extensions and
`mise.toml` run without a prompt. The trust boundary is the container wall, not a line inside
it. This does **not** govern prompt-injection exposure — `AGENTS.md` and other context files
load regardless of trust. Reviewing an untrusted third-party repository calls for a separate
container, not flipping this setting back to `"ask"` — see "Trust inside the container" in
[decisions.md](decisions.md#trust-inside-the-container).

## Summary

Lightly hardened, and the emphasis is on *lightly*: this bounds the blast radius of a
misbehaving agent, it does not contain a determined attacker, and it does not stop
exfiltration by a network-capable agent.
