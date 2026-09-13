#!/usr/bin/env bash
# Copies the Go dev container template into a target project, or refreshes an
# already-adopted one.
#   scripts/init-project.sh <target-dir>            first-time install
#   scripts/init-project.sh --update <target-dir>    refresh an existing install
set -euo pipefail

UPDATE=0
if [ "${1:-}" = "--update" ]; then
  UPDATE=1
  shift
fi

TARGET="${1:?usage: init-project.sh [--update] <target-dir>}"
SRC="$(cd "$(dirname "$0")/.." && pwd)/templates/go/.devcontainer"

[ -d "$SRC" ] || { echo "ERROR: template not found at $SRC" >&2; exit 1; }
[ -d "$TARGET" ] || { echo "ERROR: target directory does not exist: $TARGET" >&2; exit 1; }

if [ "$UPDATE" -eq 1 ]; then
  [ -e "$TARGET/.devcontainer" ] || {
    echo "ERROR: $TARGET/.devcontainer does not exist — run without --update first" >&2
    exit 1
  }

  BAK="$TARGET/.devcontainer.bak-$(date +%Y%m%d%H%M%S)"
  mv "$TARGET/.devcontainer" "$BAK"
  cp -r "$SRC" "$TARGET/.devcontainer"

  echo "Template updated. Previous .devcontainer moved to $BAK."
  echo
  echo "Differences (old -> new):"
  diff -ru "$BAK" "$TARGET/.devcontainer" || true
  cat <<EOF

Review the diff above and manually reapply any project-specific customizations
(for example devcontainer.json remoteEnv entries or an apt-packages feature) into
the new .devcontainer. Once done, remove the backup:

  rm -rf $BAK
EOF
  exit 0
fi

if [ -e "$TARGET/.devcontainer" ]; then
  echo "ERROR: $TARGET/.devcontainer already exists — remove it first, or use --update" >&2
  exit 1
fi

cp -r "$SRC" "$TARGET/.devcontainer"

cat <<'EOF'
Template installed. Add these lines to the project's .gitignore:

  .devcontainer/.personal/
  .pi/sessions/

Then open the project in VS Code and choose "Reopen in Container".
EOF
