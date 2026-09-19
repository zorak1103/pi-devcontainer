#!/usr/bin/env bash
# Installs the OpenSpec CLI (https://openspec.dev). Node/npm is required, same as pi's own
# install in install-pi.sh.
set -euo pipefail

command -v npm >/dev/null || {
  echo "ERROR: node/npm not found. The node feature in devcontainer.json is required." >&2
  exit 1
}

npm install -g --ignore-scripts "@fission-ai/openspec@${OPENSPEC_VERSION:-latest}"
openspec --version
