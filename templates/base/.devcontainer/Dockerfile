FROM mcr.microsoft.com/devcontainers/base:ubuntu

# A named volume whose target path does not exist in the image is created root-owned, and
# no-new-privileges leaves no sudo to repair it afterwards. Every volume mount point in
# devcontainer.json must appear here. See docs/findings.md, findings F8, F19 and F20.
# No language caches: base carries no build toolchain by design.
RUN mkdir -p /home/vscode/.local/share/mise \
             /home/vscode/.pi/agent/npm \
             /home/vscode/.pi/agent/pi-claude-marketplace \
             /home/vscode/.config \
             /home/vscode/.history \
 && chown -R vscode:vscode /home/vscode

# Shims first, so tools are visible to NON-INTERACTIVE shells — which is how pi's bash
# tool runs commands, and where shell-init hooks such as `mise activate` never apply.
# This belongs here rather than in containerEnv: ${containerEnv:PATH} is not resolved
# inside containerEnv itself, and a value set here also survives a plain docker exec.
# (Same reasoning as templates/go and templates/java; kept in all three files since
# devcontainer.json/Dockerfile cannot be shared across templates — see decisions.md D10.)
ENV PATH="/home/vscode/.local/share/mise/shims:${PATH}"