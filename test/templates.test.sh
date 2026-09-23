#!/usr/bin/env bash
# Test: values that must stay identical across language templates' devcontainer.json do not
# silently drift apart (PI_VERSION, hardening, personal-layer plumbing). See spec decision J4.
set -uo pipefail

GO=templates/go/.devcontainer/devcontainer.json
JAVA=templates/java/.devcontainer/devcontainer.json
BASE=templates/base/.devcontainer/devcontainer.json
fail=0

# Extracts a "key": value line and strips a possible trailing comma, so JSON's
# last-property-has-no-comma rule can't cause a false mismatch. Assumes each key's value sits
# on one line (true for every field checked below); a value ever reformatted across multiple
# lines would only compare its first line here.
field() { grep -o "\"$2\"[[:space:]]*:.*" "$1" | sed 's/,[[:space:]]*$//' | head -n1; }

for tpl in "$JAVA" "$BASE"; do
  for key in runArgs PI_VERSION OPENSPEC_VERSION PI_CODING_AGENT_SESSION_DIR HISTFILE LANG COLORTERM \
             MISE_DATA_DIR MISE_GLOBAL_CONFIG_FILE MISE_TRUSTED_CONFIG_PATHS \
             ANTHROPIC_API_KEY GCP_API_KEY OPENROUTER_API_KEY CONTEXT7_API_KEY BRAVE_API_KEY \
             initializeCommand onCreateCommand postCreateCommand; do
    g="$(field "$GO" "$key")"
    o="$(field "$tpl" "$key")"
    if [ -z "$g" ]; then
      echo "  FAIL  $key not found in $GO"; fail=1; continue
    fi
    if [ "$g" = "$o" ]; then
      echo "  PASS  $(basename "$(dirname "$(dirname "$tpl")")"): $key matches"
    else
      echo "  FAIL  $(basename "$(dirname "$(dirname "$tpl")")"): $key drifted: go='$g' other='$o'"
      fail=1
    fi
  done
done

exit $fail
