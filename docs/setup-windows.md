# Setup on Windows

Everything here also applies to Linux and macOS except where noted; Windows is called out
because three of its details will cost you time if you meet them unprepared.

## Running the scripts

`init-project.sh` and `verify.sh` are Bash scripts; PowerShell and cmd.exe cannot run them.
Use **Git Bash**, which ships with Git for Windows — Git is already a prerequisite for
cloning this repository, so there is nothing extra to install. Open "Git Bash" from the
Start menu (or right-click a folder and choose "Git Bash Here") and run the commands from
there.

## Docker

Install Docker Desktop and make sure it is running before opening the project. The container
runs `linux/amd64`; on an ARM host Docker Desktop emulates, which works but is slow — the Go
image also publishes `arm64`, so changing the `FROM` line in `.devcontainer/Dockerfile` is
worth it there.

## VS Code

Install the **Dev Containers** extension (`ms-vscode-remote.remote-containers`). The Go
extension does not need to be installed on the host: the base image's metadata requests
`golang.Go` automatically inside the container.

## The API key

The container reads the key from the environment VS Code itself was launched with:

```jsonc
"remoteEnv": { "ANTHROPIC_API_KEY": "${localEnv:ANTHROPIC_API_KEY}" }
```

Set it once as a user environment variable:

```cmd
setx ANTHROPIC_API_KEY sk-ant-...
```

**Then restart VS Code — fully, including any window already open.** `setx` writes to the
registry and affects processes started afterwards. A VS Code that was already running when
you ran it will pass an empty value into the container, and pi will ask you to log in with no
indication why. `post-create.sh` prints a warning when the variable is empty, which is your
signal that this happened.

On Linux and macOS, export it from your shell profile and start VS Code from a shell that has
it, or use your desktop environment's equivalent.

If `${localEnv:…}` is empty, nothing else breaks — the container comes up fine and only pi's
authentication is missing.

Using OpenRouter, another API-key provider, or a self-hosted/proxied endpoint instead? See
[providers.md](providers.md).

### A consequence worth knowing

`remoteEnv` values reach processes started by VS Code or `devcontainer exec`, and nothing
else. If you enter the container with plain `docker exec`, there is no API key. Start pi from
a VS Code terminal, or use `devcontainer exec`. Details in
[findings.md](findings.md#f3--remoteenv-keeps-the-secret-out-of-docker-inspect).

## Line endings

Git on Windows commonly checks files out with CRLF. A shell script with CRLF fails inside the
container with:

```
bash: /workspaces/project/.devcontainer/post-create.sh: /usr/bin/env: bad interpreter: No such file or directory
```

The `.gitattributes` in this repository pins `*.sh`, `*.js` and `Dockerfile` to LF, which
prevents it. **If you copy the template into a project of your own, copy that rule too:**

```gitattributes
*.sh text eol=lf
*.js text eol=lf
Dockerfile text eol=lf
```

The lifecycle hooks additionally invoke `bash <script>` rather than executing the file
directly, so a missing executable bit — which a Windows checkout does not preserve — is not a
second failure mode.

## The host home directory

If you go looking for the usual trick to mount a host home directory:

```jsonc
"mounts": ["source=${localEnv:HOME}${localEnv:USERPROFILE}/…,target=…,type=bind"]
```

it is broken under Git Bash, which sets `HOME` **in addition to** `USERPROFILE`. The idiom
concatenates both and the mount source becomes nonsense. This template avoids the problem
entirely by not mounting the host home: `initializeCommand` runs Node, which resolves
`os.homedir()` correctly on every platform. See
[findings.md](findings.md#f2--localenvhomelocalenvuserprofile-is-broken-when-both-are-set).

## Checking that it worked

```bash
./scripts/verify.sh /path/to/your/project
```

Expect `30 passed, 0 failed`. If `V7b key reaches the container` fails, the API key did not
make it — see above about restarting VS Code.

Then, once, by hand:

```bash
pi -p "say hello"
```

It should answer without prompting about trust and leave a file in `.pi/sessions/`.
