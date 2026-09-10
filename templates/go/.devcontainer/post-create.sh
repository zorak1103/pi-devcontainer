#!/usr/bin/env bash
# Applies the personal configuration layer and installs declared tools.
set -euo pipefail

P=".devcontainer/.personal"

mkdir -p ~/.pi/agent ~/.pi/agent/skills ~/.config/mise "$PI_CODING_AGENT_SESSION_DIR"

# Copied, never mounted: the container keeps a writable copy and the host stays untouched.
# Refreshed on every create, so edits to the personal layer take effect on rebuild.
[ -f "$P/settings.json" ] && cp    "$P/settings.json" ~/.pi/agent/settings.json
[ -f "$P/AGENTS.md"     ] && cp    "$P/AGENTS.md"     ~/.pi/agent/AGENTS.md
[ -f "$P/mise.toml"     ] && cp    "$P/mise.toml"     ~/.config/mise/config.toml
[ -d "$P/skills"        ] && cp -r "$P/skills/."      ~/.pi/agent/skills/

[ -n "${ANTHROPIC_API_KEY:-}" ] || \
  echo "WARNING: ANTHROPIC_API_KEY is empty — see docs/setup-windows.md"

# Bind-mounted files appear as root-owned to the container user, so git refuses to touch
# the workspace ("dubious ownership"). That breaks `go build` VCS stamping and the VS Code
# git integration. Register the workspace and its ancestors up to /workspaces — narrower
# than the usual wildcard, and it covers the case where the mount root is the repo root.
d="$PWD"
while [ "$d" != "/" ] && [ "$d" != "/workspaces" ]; do
  git config --global --add safe.directory "$d"
  d="$(dirname "$d")"
done

# A single unresolvable tool must not brick the container: the personal layer is
# hand-edited, and a typo there would otherwise leave no usable environment to fix it
# from. Fail loudly, carry on.
mise install || echo "WARNING: 'mise install' reported failures — see the output above; other tools are unaffected"
mise reshim
