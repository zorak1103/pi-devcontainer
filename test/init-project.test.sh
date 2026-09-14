#!/usr/bin/env bash
# Test: init-project.sh copies the right template for the requested language, refuses bad
# input, and --update refreshes an existing install without needing the language repeated.
set -uo pipefail

TARGET="$(mktemp -d)"
trap 'rm -rf "$TARGET"' EXIT

fail=0
check() { if [ "$2" = "$3" ]; then echo "  PASS  $1"; else echo "  FAIL  $1: expected '$3', got '$2'"; fail=1; fi; }

out="$(bash scripts/init-project.sh go "$TARGET" 2>&1)"
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
bash scripts/init-project.sh go "$TARGET" >/dev/null 2>&1
if [ $? -ne 0 ]; then echo "  PASS  refuses to overwrite"; else echo "  FAIL  overwrote existing config"; fail=1; fi

# Rejects a target that does not exist
bash scripts/init-project.sh go "$TARGET/does-not-exist" >/dev/null 2>&1
if [ $? -ne 0 ]; then echo "  PASS  rejects missing target"; else echo "  FAIL  accepted missing target"; fail=1; fi

# Rejects an unknown language
UNKNOWN_TARGET="$(mktemp -d)"
bash scripts/init-project.sh rust "$UNKNOWN_TARGET" >/dev/null 2>&1
if [ $? -ne 0 ]; then echo "  PASS  rejects unknown language"; else echo "  FAIL  accepted unknown language"; fail=1; fi
rm -rf "$UNKNOWN_TARGET"

# Rejects a missing language argument entirely (old one-argument form must not silently work)
NOARG_TARGET="$(mktemp -d)"
bash scripts/init-project.sh "$NOARG_TARGET" >/dev/null 2>&1
if [ $? -ne 0 ]; then echo "  PASS  rejects missing language argument"; else echo "  FAIL  accepted a bare target dir"; fail=1; fi
rm -rf "$NOARG_TARGET"

# --update rejects a target with no existing .devcontainer
NOEXIST_TARGET="$(mktemp -d)"
bash scripts/init-project.sh --update "$NOEXIST_TARGET" >/dev/null 2>&1
if [ $? -ne 0 ]; then echo "  PASS  --update rejects missing .devcontainer"; else echo "  FAIL  --update accepted missing .devcontainer"; fail=1; fi
rm -rf "$NOEXIST_TARGET"

# --update detects the language from the existing devcontainer.json; no argument needed for it
echo '  "customization": "keep-me"' >> "$TARGET/.devcontainer/devcontainer.json"
update_out="$(bash scripts/init-project.sh --update "$TARGET" 2>&1)"
update_rc=$?
check "--update exit status" "$update_rc" "0"

if printf '%s' "$update_out" | grep -q '(go)'; then
  echo "  PASS  --update reports the detected language"
else
  echo "  FAIL  --update did not report the detected language"; fail=1
fi

BAK="$(find "$TARGET" -maxdepth 1 -name '.devcontainer.bak-*' | head -n1)"
if [ -n "$BAK" ]; then echo "  PASS  --update creates a backup"; else echo "  FAIL  --update created no backup"; fail=1; fi

if [ -n "$BAK" ] && grep -q 'keep-me' "$BAK/devcontainer.json" 2>/dev/null; then
  echo "  PASS  backup preserves the customization"
else
  echo "  FAIL  backup missing or does not preserve the customization"; fail=1
fi

if ! grep -q 'keep-me' "$TARGET/.devcontainer/devcontainer.json" 2>/dev/null; then
  echo "  PASS  --update installs a fresh devcontainer.json"
else
  echo "  FAIL  --update kept the old customization instead of the fresh template"; fail=1
fi

if printf '%s' "$update_out" | grep -q 'customization'; then
  echo "  PASS  --update prints a diff against the backup"
else
  echo "  FAIL  --update did not print a diff"; fail=1
fi
rm -rf "$TARGET"/.devcontainer.bak-*

# --update refuses to guess when the name field is unrecognizable, rather than silently
# replacing the template with the wrong language's
BAD_TARGET="$(mktemp -d)"
bash scripts/init-project.sh go "$BAD_TARGET" >/dev/null 2>&1
sed -i 's/"go-pi"/"mystery-pi"/' "$BAD_TARGET/.devcontainer/devcontainer.json"
bash scripts/init-project.sh --update "$BAD_TARGET" >/dev/null 2>&1
if [ $? -ne 0 ]; then
  echo "  PASS  --update refuses an unrecognizable name field"
else
  echo "  FAIL  --update guessed a language for an unrecognizable name field"; fail=1
fi
rm -rf "$BAD_TARGET"

exit $fail
