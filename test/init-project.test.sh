#!/usr/bin/env bash
# Test: init-project.sh copies the template and reports the gitignore entries.
set -uo pipefail

TARGET="$(mktemp -d)"
trap 'rm -rf "$TARGET"' EXIT

fail=0
check() { if [ "$2" = "$3" ]; then echo "  PASS  $1"; else echo "  FAIL  $1: expected '$3', got '$2'"; fail=1; fi; }

out="$(bash scripts/init-project.sh "$TARGET" 2>&1)"
rc=$?

check "exit status" "$rc" "0"
for f in devcontainer.json Dockerfile sync-personal.js install-pi.sh post-create.sh; do
  if [ -f "$TARGET/.devcontainer/$f" ]; then echo "  PASS  copied $f"; else echo "  FAIL  missing $f"; fail=1; fi
done

if printf '%s' "$out" | grep -q '.devcontainer/.personal/'; then
  echo "  PASS  reports gitignore entries"
else
  echo "  FAIL  no gitignore hint"; fail=1
fi

# Refuses to clobber an existing configuration
bash scripts/init-project.sh "$TARGET" >/dev/null 2>&1
if [ $? -ne 0 ]; then echo "  PASS  refuses to overwrite"; else echo "  FAIL  overwrote existing config"; fail=1; fi

# Rejects a target that does not exist
bash scripts/init-project.sh "$TARGET/does-not-exist" >/dev/null 2>&1
if [ $? -ne 0 ]; then echo "  PASS  rejects missing target"; else echo "  FAIL  accepted missing target"; fail=1; fi

exit $fail
