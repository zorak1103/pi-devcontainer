# Environment

You are running inside a dev container (Debian, non-root user `vscode`), not on the host.

- No `sudo`, no `apt install`. This is intentional, not broken.
- New CLI tool: `mise use -g <tool>` (backends: aqua, ubi, go, npm, pipx).
- System packages require an entry in `.devcontainer/devcontainer.json` plus a rebuild.
- Writable: the workspace under `/workspaces` and the caches. The host is unreachable.
- Sessions are stored in `.pi/sessions` inside the project.
