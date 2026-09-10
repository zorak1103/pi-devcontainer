FROM mcr.microsoft.com/devcontainers/go:1.27-bookworm

# A named volume whose target path does not exist in the image is created root-owned,
# and no-new-privileges leaves no sudo to repair it afterwards. Every volume mount point
# in devcontainer.json must appear here. See docs/findings.md, finding F8.
RUN mkdir -p /go/pkg/mod \
             /home/vscode/.cache/go-build \
             /home/vscode/.local/share/mise \
             /home/vscode/.pi/agent/npm \
             /home/vscode/.config \
             /home/vscode/.history \
 && chown -R vscode:vscode /go/pkg /home/vscode
