#!/usr/bin/env bash
# Test: checked-in fixtures are exactly what init-project.sh produces from the current
# templates. Prevents the drift found in the design spec (fixture-go's post-create.sh had
# fallen behind its own template) from recurring, for both languages.
set -uo pipefail
fail=0

check_fixture() {
  local lang="$1" dir="$2" tmp
  tmp="$(mktemp -d)"
  bash scripts/init-project.sh "$lang" "$tmp" >/dev/null
  # devcontainer-lock.json is written by the devcontainer CLI, not init-project.sh; .personal/
  # is written by sync-personal.js's initializeCommand the moment a real `devcontainer up` runs
  # against this fixture. Neither comes from init-project.sh, so neither belongs in this diff.
  if diff -rq --exclude=devcontainer-lock.json --exclude=.personal "$tmp/.devcontainer" "$dir/.devcontainer" >/dev/null 2>&1; then
    echo "  PASS  $dir matches templates/$lang"
  else
    echo "  FAIL  $dir has drifted from templates/$lang"
    diff -rq --exclude=devcontainer-lock.json --exclude=.personal "$tmp/.devcontainer" "$dir/.devcontainer" || true
    fail=1
  fi
  rm -rf "$tmp"
}

check_fixture go   test/fixture-go
check_fixture java test/fixture-java

exit $fail
