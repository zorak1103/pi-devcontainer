FROM mcr.microsoft.com/devcontainers/java:21-bookworm

# A named volume whose target path does not exist in the image is created root-owned, and
# no-new-privileges leaves no sudo to repair it afterwards. Every volume mount point in
# devcontainer.json must appear here. See docs/findings.md, finding F8 (measured for Go;
# confirmed identically here — see docs/findings.md F19/F20 once written in Task 6).
RUN mkdir -p /home/vscode/.m2/repository \
             /home/vscode/.gradle \
             /home/vscode/.local/share/mise \
             /home/vscode/.pi/agent/npm \
             /home/vscode/.pi/agent/pi-claude-marketplace \
             /home/vscode/.config \
             /home/vscode/.history \
 && chown -R vscode:vscode /home/vscode

# Shims first, so tools are visible to NON-INTERACTIVE shells — which is how pi's bash
# tool runs commands, and where shell-init hooks such as `mise activate` never apply.
ENV PATH="/home/vscode/.local/share/mise/shims:${PATH}"
