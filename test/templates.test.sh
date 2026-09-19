#!/usr/bin/env bash
# Test: values that must stay identical across language templates' devcontainer.json do not
# silently drift apart (PI_VERSION, hardening, personal-layer plumbing). See spec decision J4.
set -uo pipefail

GO=templates/go/.devcontainer/devcontainer.json
JAVA=templates/java/.devcontainer/devcontainer.json
fail=0

# Extracts a "key": value line and strips a possible trailing comma, so JSON's
# last-property-has-no-comma rule can't cause a false mismatch. Assumes each key's value sits
# on one line (true for every field checked below); a value ever reformatted across multiple
# lines would only compare its first line here.
field() { grep -o "\"$2\"[[:space:]]*:.*" "$1" | sed 's/,[[:space:]]*$//' | head -n1; }

for key in runArgs PI_VERSION OPENSPEC_VERSION PI_CODING_AGENT_SESSION_DIR HISTFILE LANG COLORTERM \
           MISE_DATA_DIR MISE_GLOBAL_CONFIG_FILE MISE_TRUSTED_CONFIG_PATHS \
           ANTHROPIC_API_KEY initializeCommand onCreateCommand postCreateCommand; do
  g="$(field "$GO" "$key")"
  j="$(field "$JAVA" "$key")"
  if [ -z "$g" ]; then
    echo "  FAIL  $key not found in $GO"; fail=1; continue
  fi
  if [ "$g" = "$j" ]; then
    echo "  PASS  $key matches"
  else
    echo "  FAIL  $key drifted: go='$g' java='$j'"
    fail=1
  fi
done

exit $fail
