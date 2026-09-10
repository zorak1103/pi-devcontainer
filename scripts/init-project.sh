#!/usr/bin/env bash
# Copies the Go dev container template into a target project.
#   scripts/init-project.sh <target-dir>
set -euo pipefail

TARGET="${1:?usage: init-project.sh <target-dir>}"
SRC="$(cd "$(dirname "$0")/.." && pwd)/templates/go/.devcontainer"

[ -d "$SRC" ] || { echo "ERROR: template not found at $SRC" >&2; exit 1; }
[ -d "$TARGET" ] || { echo "ERROR: target directory does not exist: $TARGET" >&2; exit 1; }

if [ -e "$TARGET/.devcontainer" ]; then
  echo "ERROR: $TARGET/.devcontainer already exists — remove it first" >&2
  exit 1
fi

cp -r "$SRC" "$TARGET/.devcontainer"

cat <<'EOF'
Template installed. Add these lines to the project's .gitignore:

  .devcontainer/.personal/
  .pi/sessions/

Then open the project in VS Code and choose "Reopen in Container".
EOF
