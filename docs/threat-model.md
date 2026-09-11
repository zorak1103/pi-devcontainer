# Threat model

What this container's hardening bounds, and what it explicitly does not. The reasoning
behind each point lives in [decisions.md](decisions.md); the measurements behind that
reasoning are in [findings.md](findings.md).

## In scope: blast radius of a misbehaving agent

The agent inside the container runs arbitrary shell commands on your behalf, including ones
it got wrong or was tricked into. The goal is bounding what that can *touch*.

- Runs as non-root (`vscode`, uid 1000). See [D2](decisions.md#d2--what-the-hardening-defends-against).
- Capabilities drop to one. `--cap-drop=ALL`, with `SYS_PTRACE` forced back by the base
  image's own metadata. See [F1](findings.md#f1--the-go-image-re-adds-sys_ptrace-and-seccompunconfined).
- `no-new-privileges` disables `sudo`, even though the binary is present. See
  [F4](findings.md#f4--no-new-privileges-disables-sudo).
- The API key does not appear in `docker inspect`. It reaches the container only through
  `remoteEnv`. See [F3](findings.md#f3--remoteenv-keeps-the-secret-out-of-docker-inspect).
- The host home is never mounted. The personal layer is copied, not bind-mounted, and
  `~/.pi/agent/auth.json` never enters the container. See
  [D5](decisions.md#d5--how-the-personal-layer-reaches-the-container).

## Out of scope, by explicit decision

### The key lives in the container

A compromised agent can read the API key. `remoteEnv` keeps it out of `docker inspect` and
nothing more. The model is about blast radius, not secrecy. See
[D1](decisions.md#d1--where-the-provider-credentials-live).

### Network egress is unrestricted

An agent that can reach the network can exfiltrate. Egress filtering was considered and
rejected: it breaks Go module proxies and private registries, and the failure surfaces as a
cryptic mid-run timeout rather than a clear block. A control that gets disabled after two
days of friction is worse than no control. See
[D2](decisions.md#d2--what-the-hardening-defends-against).

### The shared module cache crosses project boundaries

`pi-dc-gomod` and `pi-dc-gobuild` are shared across all projects for rebuild speed. A
malicious agent in one project could in principle poison a cached module for another.
Content addressing and `go.sum` catch tampering, which is what makes the trade acceptable.
It is still a trade. See [D8](decisions.md#d8--what-survives-a-rebuild).

### Trust is lowered inside the container

`defaultProjectTrust: "always"` and `MISE_TRUSTED_CONFIG_PATHS=/workspaces` let a hostile
repository's project extensions and `mise.toml` run without a prompt. The trust boundary
sits at the container wall, not inside it. This setting does not govern prompt-injection
exposure: `AGENTS.md` and other context files load regardless of trust. Reviewing an
untrusted third-party repository calls for a separate container, not for setting this back
to `"ask"`. See "Trust inside the container" in
[decisions.md](decisions.md#trust-inside-the-container).
