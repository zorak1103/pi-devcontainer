#!/usr/bin/env bash
# Copies a language-specific dev container template into a target project, or refreshes an
# already-adopted one.
#   scripts/init-project.sh <go|java> <target-dir>     first-time install
#   scripts/init-project.sh --update <target-dir>        refresh an existing install
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SHARED="$ROOT/templates/_shared/.devcontainer"

usage() {
  echo "usage: init-project.sh <go|java> <target-dir>" >&2
  echo "       init-project.sh --update <target-dir>" >&2
  exit 1
}

# Reads the "name" field ("go-pi" / "java-pi") out of an existing devcontainer.json and maps
# it back to a template directory name. Hard error rather than a guess: a wrong guess here
# would silently replace a project's template with the wrong language's. The `|| true` on the
# extraction pipeline matters under `set -euo pipefail`: without it, a devcontainer.json with
# no matching "name" field would fail the pipeline itself (empty grep, pipefail) and exit
# before ever reaching this function's own, more helpful error message below.
detect_lang() {
  local name
  name="$(grep -o '"name"[[:space:]]*:[[:space:]]*"[a-z]*-pi"' "$1" | grep -o '"[a-z]*-pi"' | tr -d '"')" || true
  case "$name" in
    go-pi)   echo go ;;
    java-pi) echo java ;;
    *)
      echo "ERROR: cannot determine the template language from $1 (name: '${name:-<missing>}')" >&2
      echo "       expected \"name\": \"go-pi\" or \"name\": \"java-pi\"" >&2
      exit 1
      ;;
  esac
}

# _shared first, language template second: the language template can override a shared file
# by name if it ever genuinely needs to, without special-casing that here.
install_template() {
  local lang="$1" dest="$2" src_lang="$ROOT/templates/$1/.devcontainer"
  [ -d "$src_lang" ] || { echo "ERROR: template not found at $src_lang" >&2; exit 1; }
  mkdir -p "$dest"
  cp -r "$SHARED/." "$dest/"
  cp -r "$src_lang/." "$dest/"
}

if [ "${1:-}" = "--update" ]; then
  TARGET="${2:?usage: init-project.sh --update <target-dir>}"
  [ -e "$TARGET/.devcontainer/devcontainer.json" ] || {
    echo "ERROR: $TARGET/.devcontainer/devcontainer.json does not exist — run without --update first" >&2
    exit 1
  }
  TPL_LANG="$(detect_lang "$TARGET/.devcontainer/devcontainer.json")"

  BAK="$TARGET/.devcontainer.bak-$(date +%Y%m%d%H%M%S)"
  mv "$TARGET/.devcontainer" "$BAK"
  install_template "$TPL_LANG" "$TARGET/.devcontainer"

  echo "Template updated ($TPL_LANG). Previous .devcontainer moved to $BAK."
  echo
  echo "Differences (old -> new):"
  diff -ru "$BAK" "$TARGET/.devcontainer" || true
  cat <<EOF

Review the diff above and manually reapply any project-specific customizations into the new
.devcontainer. Once done, remove the backup:

  rm -rf $BAK
EOF
  exit 0
fi

case "${1:-}" in
  go|java) TPL_LANG="$1" ;;
  *) usage ;;
esac
TARGET="${2:?usage: init-project.sh <go|java> <target-dir>}"

[ -d "$TARGET" ] || { echo "ERROR: target directory does not exist: $TARGET" >&2; exit 1; }
[ -e "$TARGET/.devcontainer" ] && {
  echo "ERROR: $TARGET/.devcontainer already exists — remove it first, or use --update" >&2
  exit 1
}

install_template "$TPL_LANG" "$TARGET/.devcontainer"

cat <<'EOF'
Template installed. Add these lines to the project's .gitignore:

  .devcontainer/.personal/
  .pi/sessions/

Then open the project in VS Code and choose "Reopen in Container".
EOF
