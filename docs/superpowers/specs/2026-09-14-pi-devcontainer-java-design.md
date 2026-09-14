# Design: Adding Java as a second, equal dev container target

Date: 2026-09-14
Status: Approved (design), not yet implemented
Branch: `feature/java-devcontainer`

## 1. Purpose

Extend this project from a single target (Go) to two equally supported targets, Go and
Java, without degrading Go and without inventing a general-purpose multi-language
framework for hypothetical future languages. A developer picks a language explicitly when
adopting the template; both languages get the same hardening, the same personal/project
layering, and the same acceptance checks.

Concretely, the change must:

- Ship a `templates/java/.devcontainer/` that a developer can adopt exactly the way
  `templates/go/.devcontainer/` works today: `initializeCommand`/`onCreateCommand`/
  `postCreateCommand`, the personal layer, the hardening flags, the volume plan.
- Keep the three files that are already language-independent
  (`install-pi.sh`, `post-create.sh`, `sync-personal.js`) as a single maintained copy,
  not two.
- Extend `scripts/init-project.sh` and `scripts/verify.sh` to handle both languages through
  one entry point each, not a parallel `-java` script.
- Leave every existing Go behavior intact except the one explicit, intentional breaking
  change to `init-project.sh`'s argument list (section 3).

### Non-goals

- A general plugin/registry mechanism for arbitrary future languages. Two languages get
  two directories and a `case` statement; a third language is a `docs/extending.md` recipe,
  same as before, not new infrastructure.
- A JSON merge/include mechanism for `devcontainer.json`. The format does not support it,
  and building one to remove the small remaining duplication (`PI_VERSION`, hardening
  flags, `containerEnv`) is more machinery than the duplication costs. A drift-check test
  (section 5) does the job instead.
- A full Gradle build fixture. Both build tools ship in the image; only Maven gets a real
  build proof, Gradle gets a shim-reachability check (section 5b).
- CI. Unchanged from the existing "no CI initially" decision.
- Removing or restructuring anything Go-specific that isn't touched by this change.

## 2. Decisions

| # | Decision | Chosen | Rejected alternatives |
|---|---|---|---|
| J1 | How a developer selects a language | Two templates (`templates/go/`, `templates/java/`), explicit language argument to `init-project.sh` | Autodetect from target-directory contents (`go.mod`/`pom.xml`) — silent, surprising on an empty target; a separate `init-project-java.sh` — two entry points to keep in sync |
| J2 | Backward compatibility of `init-project.sh <dir>` | Broken on purpose: the language argument becomes mandatory (`init-project.sh <go\|java> <dir>`) | Defaulting to `go` when omitted — silently wrong the first time a Java user forgets the flag, which is exactly the failure mode J1 was chosen to avoid |
| J3 | Language argument on `--update` | Not required — read from the existing `.devcontainer/devcontainer.json`'s `"name"` field (`go-pi`/`java-pi`), hard error if it can't be determined | Requiring `--update <go\|java> <dir>` too — redundant, and a wrong value would silently replace the template with the wrong language's |
| J4 | Sharing the language-independent scripts | Extract `install-pi.sh`, `post-create.sh`, `sync-personal.js` into `templates/_shared/.devcontainer/`; `init-project.sh` copies `_shared` first, then the language template over it | Duplicating them per language template — the status quo, and it had already drifted once (see finding below) before Java even existed |
| J5 | Java build tooling | Both Maven and Gradle available in the image (`mcr.microsoft.com/devcontainers/java`), following D6's precedent of trusting the official image over reproducing it | Maven-only or Gradle-only — forces a choice the ecosystem itself does not force, unlike Go's single toolchain |
| J6 | Java version pinned in the image | 21 (LTS), overridable per project via `mise.toml`, same override rule as Go's `mise.toml` `go = "1.27"` | 25 (current LTS but young; broader compatibility risk not worth it as the *default*) |
| J7 | The shared `pi-dc-mise` volume | Stays a single global volume, used by Go and Java alike | Splitting into `pi-dc-mise-go`/`pi-dc-mise-java` — the concurrent-write risk this would address already exists between two Go containers today (mise is not documented as install-safe under concurrent writers), so splitting by *language* would fix nothing while adding a naming axis that has to be remembered for every future language |
| J8 | Verification entry point | `scripts/verify.sh` detects the language from the target workspace's `devcontainer.json` `"name"` field, same mechanism as J3, and branches internally | A separate `verify-java.sh` — a second script to keep in sync with every future check added to the common part |
| J9 | Fixture maintenance | `test/fixture-go/.devcontainer` and the new `test/fixture-java/.devcontainer` are asserted (not just written) to be exactly what `init-project.sh` produces from the current templates, via a new test | Continuing to hand-maintain fixtures — this is what let `post-create.sh` drift undetected (section 4) |
| J10 | Documentation structure | Java specifics are woven into the existing docs (`architecture.md`, `decisions.md`, `how-to.md`, `extending.md`) next to their Go equivalents | A dedicated `docs/java.md` — would fork the three-layer mental model into two parallel descriptions of the same architecture |

## 3. A finding made while designing this

`test/fixture-go/.devcontainer/post-create.sh` has already drifted from
`templates/go/.devcontainer/post-create.sh`: the fixture is missing the `mcp.json`/
`claude-plugins.json` copy lines and the `pi update --extensions` block that the template
has had since a later commit. This happened because the fixture is a hand-maintained copy
with no test enforcing equality with the template. It is direct evidence for J4 (extract,
don't duplicate) and J9 (assert fixtures match templates); fixing it is in scope for this
change (section 5a) and is not itself a Java-specific fix — Go's fixture gets corrected as a
side effect of adding the assertion.

## 4. Architecture changes

### 4.1 Template layout

```
templates/
  _shared/.devcontainer/
    install-pi.sh          # language-independent: npm install -g pi
    post-create.sh         # language-independent: personal layer, mise install, git safe.directory
    sync-personal.js       # language-independent: host-side copy of ~/.pi/devcontainer/
  go/.devcontainer/
    Dockerfile
    devcontainer.json
  java/.devcontainer/
    Dockerfile
    devcontainer.json
```

`templates/go/.devcontainer/` loses the three shared files; their content does not change,
only their location. `templates/go/.devcontainer/{Dockerfile,devcontainer.json}` are
untouched by this design beyond what section 4.2 states.

**New load-bearing convention:** a language template's `devcontainer.json` must set
`"name": "<lang>-pi"`. This used to be cosmetic; from J3/J8 onward it is the single value
`--update` and `verify.sh` use to identify which template a project is running. Any future
language target must follow it — this goes into `docs/extending.md`.

### 4.2 Volumes

Added to the existing volume map (`docs/architecture.md`):

| Volume | Mount point | Holds | Scope |
|---|---|---|---|
| `pi-dc-m2` | `/home/vscode/.m2/repository` | Maven dependency cache | shared across all projects, both languages |
| `pi-dc-gradle` | `/home/vscode/.gradle` | Gradle dependency/build cache | shared across all projects, both languages |

`pi-dc-mise` (existing) is now explicitly documented as shared between Go and Java, not
just between Go projects — see J7 and the new known limitation below.

### 4.3 New known limitation: `pi-dc-mise` and concurrent container creation

To add to `docs/architecture.md`'s volumes section and referenced from `docs/decisions.md`
D8:

> `pi-dc-mise` is shared by every project and both languages. The risk window is
> `postCreateCommand`'s `mise install`/`mise reshim`, which writes into this volume — not
> having multiple containers running at once, which is fine. **Do not create or rebuild two
> containers at the same time**; create or rebuild them one after another. Once a container
> has finished its `postCreateCommand`, running it alongside others is unproblematic.

## 5. Artifacts

### 5.1 `scripts/init-project.sh` (rewritten)

```bash
#!/usr/bin/env bash
# Copies a language-specific dev container template into a target project, or refreshes an
# already-adopted one.
#   scripts/init-project.sh <go|java> <target-dir>     first-time install
#   scripts/init-project.sh --update <target-dir>        refresh an existing install
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SHARED="$ROOT/templates/_shared/.devcontainer"

usage() {
  echo "usage: init-project.sh <go|java> <target-dir>" >&2
  echo "       init-project.sh --update <target-dir>" >&2
  exit 1
}

# Reads the "name" field ("go-pi" / "java-pi") out of an existing devcontainer.json and
# maps it back to a template directory name. Hard error rather than a guess: a wrong guess
# here would silently replace a project's template with the wrong language's.
detect_lang() {
  local name
  name="$(grep -o '"name"[[:space:]]*:[[:space:]]*"[a-z]*-pi"' "$1" | grep -o '"[a-z]*-pi"' | tr -d '"')"
  case "$name" in
    go-pi)   echo go ;;
    java-pi) echo java ;;
    *)
      echo "ERROR: cannot determine the template language from $1 (name: '${name:-<missing>}')" >&2
      echo "       expected \"name\": \"go-pi\" or \"name\": \"java-pi\"" >&2
      exit 1
      ;;
  esac
}

# _shared first, language template second: the language template can override a shared
# file by name if it ever genuinely needs to, without special-casing that in this script.
install_template() {
  local lang="$1" dest="$2" src_lang="$ROOT/templates/$1/.devcontainer"
  [ -d "$src_lang" ] || { echo "ERROR: template not found at $src_lang" >&2; exit 1; }
  mkdir -p "$dest"
  cp -r "$SHARED/." "$dest/"
  cp -r "$src_lang/." "$dest/"
}

if [ "${1:-}" = "--update" ]; then
  TARGET="${2:?usage: init-project.sh --update <target-dir>}"
  [ -e "$TARGET/.devcontainer/devcontainer.json" ] || {
    echo "ERROR: $TARGET/.devcontainer/devcontainer.json does not exist — run without --update first" >&2
    exit 1
  }
  LANG="$(detect_lang "$TARGET/.devcontainer/devcontainer.json")"

  BAK="$TARGET/.devcontainer.bak-$(date +%Y%m%d%H%M%S)"
  mv "$TARGET/.devcontainer" "$BAK"
  install_template "$LANG" "$TARGET/.devcontainer"

  echo "Template updated ($LANG). Previous .devcontainer moved to $BAK."
  echo
  echo "Differences (old -> new):"
  diff -ru "$BAK" "$TARGET/.devcontainer" || true
  cat <<EOF

Review the diff above and manually reapply any project-specific customizations into the new
.devcontainer. Once done, remove the backup:

  rm -rf $BAK
EOF
  exit 0
fi

case "${1:-}" in
  go|java) LANG="$1" ;;
  *) usage ;;
esac
TARGET="${2:?usage: init-project.sh <go|java> <target-dir>}"

[ -d "$TARGET" ] || { echo "ERROR: target directory does not exist: $TARGET" >&2; exit 1; }
[ -e "$TARGET/.devcontainer" ] && {
  echo "ERROR: $TARGET/.devcontainer already exists — remove it first, or use --update" >&2
  exit 1
}

install_template "$LANG" "$TARGET/.devcontainer"

cat <<'EOF'
Template installed. Add these lines to the project's .gitignore:

  .devcontainer/.personal/
  .pi/sessions/

Then open the project in VS Code and choose "Reopen in Container".
EOF
```

### 5.2 `templates/java/.devcontainer/Dockerfile`

```dockerfile
FROM mcr.microsoft.com/devcontainers/java:21-bookworm

# A named volume whose target path does not exist in the image is created root-owned, and
# no-new-privileges leaves no sudo to repair it afterwards. Every volume mount point in
# devcontainer.json must appear here. See docs/findings.md, finding F8 (measured for Go;
# applies identically here).
RUN mkdir -p /home/vscode/.m2/repository \
             /home/vscode/.gradle \
             /home/vscode/.local/share/mise \
             /home/vscode/.pi/agent/npm \
             /home/vscode/.pi/agent/pi-claude-marketplace \
             /home/vscode/.config \
             /home/vscode/.history \
 && chown -R vscode:vscode /home/vscode

# See templates/go/.devcontainer/Dockerfile for why this line belongs here and not in
# containerEnv.
ENV PATH="/home/vscode/.local/share/mise/shims:${PATH}"
```

**Flagged for measurement during implementation, not asserted here as fact:** whether
`mcr.microsoft.com/devcontainers/java:21-bookworm` bundles both Maven and Gradle by default
(the assumption behind J5) or needs `ghcr.io/devcontainers/features/java:1` with
`installMaven`/`installGradle` added explicitly; and whether the image's metadata label
forces back any capability the way Go's forced back `SYS_PTRACE` (F1). Both get resolved the
way F1–F8 were: run it, measure it, write the finding, adjust the artifact if the assumption
was wrong.

### 5.3 `templates/java/.devcontainer/devcontainer.json`

```jsonc
{
  "name": "java-pi",
  "build": { "dockerfile": "Dockerfile" },

  "features": {
    "ghcr.io/devcontainers/features/node:2": { "version": "22" },
    "ghcr.io/devcontainers-extra/features/mise:1": {}
  },

  "runArgs": ["--cap-drop=ALL", "--security-opt", "no-new-privileges"],

  "containerEnv": {
    "MISE_DATA_DIR": "/home/vscode/.local/share/mise",
    "MISE_GLOBAL_CONFIG_FILE": "/home/vscode/.config/mise/config.toml",
    "MISE_TRUSTED_CONFIG_PATHS": "/workspaces",
    "PI_VERSION": "0.85.1",
    "PI_CODING_AGENT_SESSION_DIR": "${containerWorkspaceFolder}/.pi/sessions",
    "HISTFILE": "/home/vscode/.history/.bash_history",
    "LANG": "C.UTF-8",
    "COLORTERM": "truecolor"
  },

  "remoteEnv": {
    "ANTHROPIC_API_KEY": "${localEnv:ANTHROPIC_API_KEY}"
  },

  "mounts": [
    "source=pi-dc-m2,target=/home/vscode/.m2/repository,type=volume",
    "source=pi-dc-gradle,target=/home/vscode/.gradle,type=volume",
    "source=pi-dc-mise,target=/home/vscode/.local/share/mise,type=volume",
    "source=pi-dc-${localWorkspaceFolderBasename}-pinpm,target=/home/vscode/.pi/agent/npm,type=volume",
    "source=pi-dc-${localWorkspaceFolderBasename}-claudeplugins,target=/home/vscode/.pi/agent/pi-claude-marketplace,type=volume",
    "source=pi-dc-${localWorkspaceFolderBasename}-config,target=/home/vscode/.config,type=volume",
    "source=pi-dc-${localWorkspaceFolderBasename}-hist,target=/home/vscode/.history,type=volume"
  ],

  "initializeCommand": ["node", ".devcontainer/sync-personal.js"],
  "onCreateCommand": "bash .devcontainer/install-pi.sh",
  "postCreateCommand": "bash .devcontainer/post-create.sh",

  "customizations": {
    "vscode": { "extensions": ["vscjava.vscode-java-pack"] }
  }
}
```

`PI_VERSION`, `runArgs`, the rest of `containerEnv`, `remoteEnv`, and the three lifecycle
hooks are intentionally byte-identical to `templates/go/.devcontainer/devcontainer.json`.
The drift-check test in section 5c enforces that identity mechanically; nobody has to
remember it by hand.

`customizations.vscode.extensions` is a placeholder for whatever the actual image metadata
turns out not to already cover, the same way Go's `golang.Go` turned out to be unnecessary
once F5 was measured (the image's own metadata already registered it). Verify before
committing to this line.

Project layer convention (parallel to Go's `mise.toml` with `go = "1.27"`):

```toml
[tools]
java = "21"
```

### 5.4 `test/fixture-java/`

New fixture, structured like `test/fixture-go/`:

```
test/fixture-java/
  .devcontainer/            # produced by init-project.sh java, asserted equal (5a)
  mise.toml                 # [tools] jq = "latest" — same illustrative tool as fixture-go
  pom.xml                   # trivial Maven project with one real dependency
  src/main/java/.../Main.java
```

`pom.xml` needs one dependency that is cheap and stable to resolve for the "cache actually
filled" check — analogous to `rsc.io/quote` in `fixture-go/go.mod`. A small, dependency-free
utility library (exact choice deferred to implementation) is enough; the point is proving
`~/.m2/repository` gets populated by a real `mvn compile`, not exercising Maven itself.

### 5.5a `test/fixtures.test.sh` (new)

```bash
#!/usr/bin/env bash
# Test: checked-in fixtures are exactly what init-project.sh produces from the current
# templates. Prevents the drift documented in section 3 from recurring, for both languages.
set -uo pipefail
fail=0

check_fixture() {
  local lang="$1" dir="$2" tmp
  tmp="$(mktemp -d)"
  bash scripts/init-project.sh "$lang" "$tmp" >/dev/null
  if diff -rq --exclude=devcontainer-lock.json "$tmp/.devcontainer" "$dir/.devcontainer" >/dev/null 2>&1; then
    echo "  PASS  $dir matches templates/$lang"
  else
    echo "  FAIL  $dir has drifted from templates/$lang"
    diff -rq --exclude=devcontainer-lock.json "$tmp/.devcontainer" "$dir/.devcontainer" || true
    fail=1
  fi
  rm -rf "$tmp"
}

check_fixture go   test/fixture-go
check_fixture java test/fixture-java

exit $fail
```

`devcontainer-lock.json` is excluded: it is written by the `devcontainer` CLI itself during
a real container build, not by `init-project.sh`, and only exists in `fixture-go` today
because that fixture has actually been built at least once.

### 5.5b `test/templates.test.sh` (new) — the drift check promised in section 4/5.3

```bash
#!/usr/bin/env bash
# Test: values that must stay identical across language templates' devcontainer.json do
# not silently drift apart (PI_VERSION, hardening, personal-layer plumbing).
set -uo pipefail

GO=templates/go/.devcontainer/devcontainer.json
JAVA=templates/java/.devcontainer/devcontainer.json
fail=0

field() { grep -o "\"$2\"[^,}]*" "$1" | head -n1; }

for key in PI_VERSION PI_CODING_AGENT_SESSION_DIR HISTFILE LANG COLORTERM \
           MISE_DATA_DIR MISE_GLOBAL_CONFIG_FILE MISE_TRUSTED_CONFIG_PATHS; do
  g="$(field "$GO" "$key")"; j="$(field "$JAVA" "$key")"
  if [ "$g" = "$j" ]; then echo "  PASS  $key matches"; else echo "  FAIL  $key drifted: go='$g' java='$j'"; fail=1; fi
done

for key in runArgs remoteEnv initializeCommand onCreateCommand postCreateCommand; do
  g="$(grep -A3 "\"$key\"" "$GO")"; j="$(grep -A3 "\"$key\"" "$JAVA")"
  if [ "$g" = "$j" ]; then echo "  PASS  $key matches"; else echo "  FAIL  $key drifted"; fail=1; fi
done

exit $fail
```

Exact regexes get hardened during implementation against the real files; the mechanism
(extract comparable fields with `grep`, no new dependency) is the point being fixed here.

### 5.6 `scripts/verify.sh` changes

Language detection, mirroring `detect_lang` in `init-project.sh`:

```bash
WS="${1:-test/fixture-go}"

LANG="$(grep -o '"name"[[:space:]]*:[[:space:]]*"[a-z]*-pi"' "$WS/.devcontainer/devcontainer.json" \
        | grep -o '[a-z]*-pi' | sed 's/-pi$//')"

case "$LANG" in
  go)
    MOUNTS="/go/pkg/mod /home/vscode/.cache/go-build /home/vscode/.local/share/mise \
            /home/vscode/.pi/agent/npm /home/vscode/.pi/agent/pi-claude-marketplace \
            /home/vscode/.config /home/vscode/.history"
    ;;
  java)
    MOUNTS="/home/vscode/.m2/repository /home/vscode/.gradle /home/vscode/.local/share/mise \
            /home/vscode/.pi/agent/npm /home/vscode/.pi/agent/pi-claude-marketplace \
            /home/vscode/.config /home/vscode/.history"
    ;;
  *)
    echo "ERROR: cannot determine language from $WS/.devcontainer/devcontainer.json" >&2
    exit 1
    ;;
esac
```

Every existing check (V1, V2, V2b/c, V3, V3b/c, V5–V9) is language-independent and runs
unchanged for both. Only V4 (the real build) branches:

```bash
if [ "$LANG" = go ]; then
  expect_match "V4 GOMODCACHE"   '^/go/pkg/mod$' 'go env GOMODCACHE'
  expect_match "V4b git usable"  'On branch|HEAD detached' 'git status'
  expect_match "V4 go build"     '^ok$'  'go mod tidy >/dev/null 2>&1 && go build ./... && echo ok'
  expect_match "V4 cache filled" '^yes$' '[ -d /go/pkg/mod/rsc.io ] && echo yes || echo no'
else
  expect_match "V4b git usable"  'On branch|HEAD detached' 'git status'
  expect_match "V4 mvn build"    '^ok$'  'mvn -q -B compile && echo ok'
  expect_match "V4 cache filled" '^yes$' \
    '[ -d /home/vscode/.m2/repository ] && [ -n "$(ls -A /home/vscode/.m2/repository)" ] && echo yes || echo no'
  expect_match "V4c gradle shim" '/shims/gradle$' 'command -v gradle'
fi
```

Gradle gets a shim-reachability check only (V4c), not a build: both build tools are proven
to be *present and on PATH for a non-interactive shell* (the actual thing worth checking,
per the project's existing V3 rationale), while only one gets a full build fixture to
maintain, per J5/section 1's non-goals.

## 6. Documentation changes

| File | Change |
|---|---|
| `README.md` | Opening line changes from "The first target environment is Go" to stating Go and Java as equal targets. Quick start shows both invocations (`init-project.sh go ...` / `init-project.sh java ...`). "What you get" table's Base row becomes language-neutral with a pointer to `architecture.md`. |
| `docs/architecture.md` | Base row generalized; new subsection on `templates/_shared/` plus the two language templates; volumes table gains `pi-dc-m2`/`pi-dc-gradle`; new known-limitation paragraph on `pi-dc-mise` sequencing (section 4.3). |
| `docs/decisions.md` | New D6b "Where the Java toolchain comes from" (Chosen/Rejected/Cost, same shape as D6); new decision documenting the `_shared` extraction (J4); D8 gains the `pi-dc-m2`/`pi-dc-gradle` entries and a cross-reference to the `pi-dc-mise` limitation; D3 updated for the new `init-project.sh` argument shape (J1–J3). |
| `docs/how-to.md` | "Set up a new project" and "Update an existing project" recipes updated to the new command syntax. |
| `docs/extending.md` | "A new language target" rewritten: a template contributes only `Dockerfile` + `devcontainer.json` under `templates/<lang>/.devcontainer/`; it **must** set `"name": "<lang>-pi"` (now load-bearing, J3/J8); the three shared files must not be duplicated; `init-project.sh`'s language `case` and `verify.sh`'s `MOUNTS`/build-check `case` need the new language added. |
| `docs/comparison.md`, `docs/threat-model.md`, `docs/providers.md`, `docs/setup-windows.md` | No content change expected; re-checked during implementation for stray Go-only assumptions. |
| `docs/findings.md` | Gains new F-numbered entries only once the corresponding measurements are actually taken during implementation (the two items flagged in section 5.2). Not written speculatively here. |
| `test/docs.test.sh` | `REQUIRED` list unchanged — no new doc file is introduced (J10). |

## 7. Rollout

This branch's `init-project.sh` change is a deliberate breaking change (J2): every existing
invocation of `init-project.sh <dir>` must become `init-project.sh go <dir>`. This gets
called out explicitly in the README's quick start and, if a changelog exists by the time
this ships, there too. `--update` is unaffected for existing adopters (J3): it keeps working
without any new argument, because it derives the language itself.

## 8. Verification summary

Work is complete when:

- `test/init-project.test.sh` passes with cases for `go`/`java` first-time install, the
  rejected invalid-language case, and `--update` (both the success path and the hard-error
  path for an undetectable `name` field).
- `test/fixtures.test.sh` (new) passes: both fixtures are exactly what `init-project.sh`
  produces from the current templates.
- `test/templates.test.sh` (new) passes: the values required to stay identical across
  `templates/go/.devcontainer/devcontainer.json` and `templates/java/.devcontainer/devcontainer.json`
  actually are.
- `test/docs.test.sh` passes unchanged (no placeholders, no broken links, required files
  present).
- `scripts/verify.sh test/fixture-go` and `scripts/verify.sh test/fixture-java` both pass
  against real containers, including the language-specific V4 block and the shared V1–V3,
  V5–V9 checks.
- Every measurement-pending item in section 5.2 has either been confirmed or has produced a
  new `docs/findings.md` entry and a corresponding artifact adjustment.
