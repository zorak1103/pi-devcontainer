#!/usr/bin/env bash
# Applies the personal configuration layer and installs declared tools.
set -euo pipefail

mkdir -p ~/.pi/agent ~/.pi/agent/skills ~/.config/mise "$PI_CODING_AGENT_SESSION_DIR"

mise install
mise reshim
