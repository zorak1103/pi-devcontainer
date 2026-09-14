# Java as a second, equal devcontainer target — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `templates/java/.devcontainer/` as a fully equal second target alongside
`templates/go/.devcontainer/`, extract the three language-independent scripts into a shared
location so they stop being duplicated, and extend `init-project.sh`/`verify.sh` to handle
both languages through one entry point each.

**Architecture:** `templates/_shared/.devcontainer/` holds `install-pi.sh`, `post-create.sh`,
`sync-personal.js` — copied into every language template by `init-project.sh`, which now
takes a mandatory `<go|java>` argument on first install and auto-detects the language from
the existing `devcontainer.json`'s `"name"` field on `--update`. `templates/java/.devcontainer/`
adds a `Dockerfile` based on `mcr.microsoft.com/devcontainers/java:21-bookworm` plus the
`ghcr.io/devcontainers/features/java:1` feature (Maven + Gradle), and a `devcontainer.json`
that is byte-identical to Go's for every value that must not drift (`PI_VERSION`, hardening,
personal-layer plumbing), enforced by a new test. `scripts/verify.sh` detects the language
the same way and branches only its build-proof check.

**Tech Stack:** Dev Containers spec + `devcontainer` CLI, Docker, `mcr.microsoft.com/devcontainers/java:21-bookworm`, Dev Container Features (`java`, `node`, `mise`), Maven, Gradle, Bash.

**Spec:** `docs/superpowers/specs/2026-09-14-pi-devcontainer-java-design.md`

## Global Constraints

- `PI_VERSION` must be `"0.85.1"` in both `templates/go/.devcontainer/devcontainer.json` and
  `templates/java/.devcontainer/devcontainer.json` — identical string, not just identical value.
- `runArgs`, the full `containerEnv` block's keys, `remoteEnv`, and the three lifecycle hooks
  (`initializeCommand`, `onCreateCommand`, `postCreateCommand`) must be byte-identical between
  the two languages' `devcontainer.json`, enforced by `test/templates.test.sh` (Task 3).
- `"name"` in a language template's `devcontainer.json` must be exactly `"<lang>-pi"` — this is
  load-bearing: `init-project.sh --update` and `verify.sh` both parse it to detect the language.
- `install-pi.sh`, `post-create.sh`, `sync-personal.js` live only in
  `templates/_shared/.devcontainer/`. Never duplicate them into a language template directory.
- Every volume mount point declared in a template's `devcontainer.json` `mounts` array must have
  a matching `mkdir -p ... && chown -R vscode:vscode ...` line in that template's `Dockerfile`,
  otherwise Docker creates it root-owned and unrepairable (`docs/findings.md` F8).
- Container user is always `vscode`; hardening is always
  `runArgs: ["--cap-drop=ALL", "--security-opt", "no-new-privileges"]`. Never add `capAdd` or
  `securityOpt` — additive, cannot subtract what image metadata contributes.
- `sudo` does not work and must not be used in any script.
- The provider API key travels through `remoteEnv` only, never `containerEnv`.
- All shell scripts and JSON/JS files are LF-only, enforced by `.gitattributes`. Lifecycle
  hooks invoke `bash <script>` explicitly; never rely on the executable bit.
- Test scripts use only `grep`/`sed`/`diff`/`awk` — no new dependency (`jq` etc.) on the host
  running the tests, matching `test/docs.test.sh`'s existing style.
- Language of all repository content (docs, comments, commit messages): English. License: MIT.
- Branch: `feature/java-devcontainer` (already created and checked out).

---

### Task 1: Extract shared scripts and rewrite `init-project.sh`'s CLI

**Files:**
- Create: `templates/_shared/.devcontainer/install-pi.sh`
- Create: `templates/_shared/.devcontainer/post-create.sh`
- Create: `templates/_shared/.devcontainer/sync-personal.js`
- Delete: `templates/go/.devcontainer/install-pi.sh`
- Delete: `templates/go/.devcontainer/post-create.sh`
- Delete: `templates/go/.devcontainer/sync-personal.js`
- Modify: `scripts/init-project.sh`
- Modify: `test/init-project.test.sh`

**Interfaces:**
- Produces: `scripts/init-project.sh <go|java> <target-dir>` (first-time install) and
  `scripts/init-project.sh --update <target-dir>` (refresh, language auto-detected). Both are
  consumed directly by a human/CI, and by Task 2's and Task 4's tests.
- Produces: `templates/_shared/.devcontainer/`, consumed by Task 2 (the java template does not
  redeclare these files).

- [ ] **Step 1: Write the failing test**

Replace `test/init-project.test.sh` in full:

```bash
#!/usr/bin/env bash
# Test: init-project.sh copies the right template for the requested language, refuses bad
# input, and --update refreshes an existing install without needing the language repeated.
set -uo pipefail

TARGET="$(mktemp -d)"
trap 'rm -rf "$TARGET"' EXIT

fail=0
check() { if [ "$2" = "$3" ]; then echo "  PASS  $1"; else echo "  FAIL  $1: expected '$3', got '$2'"; fail=1; fi; }

out="$(bash scripts/init-project.sh go "$TARGET" 2>&1)"
rc=$?

check "exit status" "$rc" "0"
for f in devcontainer.json Dockerfile sync-personal.js install-pi.sh post-create.sh; do
  if [ -f "$TARGET/.devcontainer/$f" ]; then echo "  PASS  copied $f"; else echo "  FAIL  missing $f"; fail=1; fi
done

if printf '%s' "$out" | grep -q '.devcontainer/.personal/'; then
  echo "  PASS  reports gitignore entries"
else
  echo "  FAIL  no gitignore hint"; fail=1
fi

# Refuses to clobber an existing configuration
bash scripts/init-project.sh go "$TARGET" >/dev/null 2>&1
if [ $? -ne 0 ]; then echo "  PASS  refuses to overwrite"; else echo "  FAIL  overwrote existing config"; fail=1; fi

# Rejects a target that does not exist
bash scripts/init-project.sh go "$TARGET/does-not-exist" >/dev/null 2>&1
if [ $? -ne 0 ]; then echo "  PASS  rejects missing target"; else echo "  FAIL  accepted missing target"; fail=1; fi

# Rejects an unknown language
UNKNOWN_TARGET="$(mktemp -d)"
bash scripts/init-project.sh rust "$UNKNOWN_TARGET" >/dev/null 2>&1
if [ $? -ne 0 ]; then echo "  PASS  rejects unknown language"; else echo "  FAIL  accepted unknown language"; fail=1; fi
rm -rf "$UNKNOWN_TARGET"

# Rejects a missing language argument entirely (old one-argument form must not silently work)
NOARG_TARGET="$(mktemp -d)"
bash scripts/init-project.sh "$NOARG_TARGET" >/dev/null 2>&1
if [ $? -ne 0 ]; then echo "  PASS  rejects missing language argument"; else echo "  FAIL  accepted a bare target dir"; fail=1; fi
rm -rf "$NOARG_TARGET"

# --update rejects a target with no existing .devcontainer
NOEXIST_TARGET="$(mktemp -d)"
bash scripts/init-project.sh --update "$NOEXIST_TARGET" >/dev/null 2>&1
if [ $? -ne 0 ]; then echo "  PASS  --update rejects missing .devcontainer"; else echo "  FAIL  --update accepted missing .devcontainer"; fail=1; fi
rm -rf "$NOEXIST_TARGET"

# --update detects the language from the existing devcontainer.json; no argument needed for it
echo '  "customization": "keep-me"' >> "$TARGET/.devcontainer/devcontainer.json"
update_out="$(bash scripts/init-project.sh --update "$TARGET" 2>&1)"
update_rc=$?
check "--update exit status" "$update_rc" "0"

if printf '%s' "$update_out" | grep -q '(go)'; then
  echo "  PASS  --update reports the detected language"
else
  echo "  FAIL  --update did not report the detected language"; fail=1
fi

BAK="$(find "$TARGET" -maxdepth 1 -name '.devcontainer.bak-*' | head -n1)"
if [ -n "$BAK" ]; then echo "  PASS  --update creates a backup"; else echo "  FAIL  --update created no backup"; fail=1; fi

if [ -n "$BAK" ] && grep -q 'keep-me' "$BAK/devcontainer.json" 2>/dev/null; then
  echo "  PASS  backup preserves the customization"
else
  echo "  FAIL  backup missing or does not preserve the customization"; fail=1
fi

if ! grep -q 'keep-me' "$TARGET/.devcontainer/devcontainer.json" 2>/dev/null; then
  echo "  PASS  --update installs a fresh devcontainer.json"
else
  echo "  FAIL  --update kept the old customization instead of the fresh template"; fail=1
fi

if printf '%s' "$update_out" | grep -q 'customization'; then
  echo "  PASS  --update prints a diff against the backup"
else
  echo "  FAIL  --update did not print a diff"; fail=1
fi
rm -rf "$TARGET"/.devcontainer.bak-*

# --update refuses to guess when the name field is unrecognizable, rather than silently
# replacing the template with the wrong language's
BAD_TARGET="$(mktemp -d)"
bash scripts/init-project.sh go "$BAD_TARGET" >/dev/null 2>&1
sed -i 's/"go-pi"/"mystery-pi"/' "$BAD_TARGET/.devcontainer/devcontainer.json"
bash scripts/init-project.sh --update "$BAD_TARGET" >/dev/null 2>&1
if [ $? -ne 0 ]; then
  echo "  PASS  --update refuses an unrecognizable name field"
else
  echo "  FAIL  --update guessed a language for an unrecognizable name field"; fail=1
fi
rm -rf "$BAD_TARGET"

exit $fail
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash test/init-project.test.sh`
Expected: multiple FAILs — the current script's signature is `init-project.sh <target-dir>`, so
`init-project.sh go "$TARGET"` tries to treat `go` as the target directory and errors
`target directory does not exist: go`, causing the exit-status check and every "copied X" check
to fail.

- [ ] **Step 3: Move the three shared files (content unchanged)**

```bash
mkdir -p templates/_shared/.devcontainer
git mv templates/go/.devcontainer/install-pi.sh    templates/_shared/.devcontainer/install-pi.sh
git mv templates/go/.devcontainer/post-create.sh   templates/_shared/.devcontainer/post-create.sh
git mv templates/go/.devcontainer/sync-personal.js templates/_shared/.devcontainer/sync-personal.js
```

- [ ] **Step 4: Rewrite `scripts/init-project.sh`**

Replace the file in full:

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

# Reads the "name" field ("go-pi" / "java-pi") out of an existing devcontainer.json and maps
# it back to a template directory name. Hard error rather than a guess: a wrong guess here
# would silently replace a project's template with the wrong language's.
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

# _shared first, language template second: the language template can override a shared file
# by name if it ever genuinely needs to, without special-casing that here.
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

- [ ] **Step 5: Run the test again to verify it passes**

Run: `bash test/init-project.test.sh`
Expected: every line `PASS`, exit status `0`.

- [ ] **Step 6: Commit**

```bash
git add templates/_shared templates/go/.devcontainer scripts/init-project.sh test/init-project.test.sh
git commit -m "feat: extract shared devcontainer scripts, require a language on init-project.sh

install-pi.sh, post-create.sh and sync-personal.js are language-independent and now live
once in templates/_shared/.devcontainer/. init-project.sh takes a mandatory <go|java>
argument for first-time install; --update detects the language itself from the existing
devcontainer.json's name field, so it needs no new argument."
```

---

### Task 2: Add the Java template

**Files:**
- Create: `templates/java/.devcontainer/Dockerfile`
- Create: `templates/java/.devcontainer/devcontainer.json`
- Modify: `test/init-project.test.sh`

**Interfaces:**
- Consumes: `install_template`/`detect_lang` from Task 1 (no code change needed there — the
  `case go|java)` already accepts `java`, it just had nothing to copy until now).
- Produces: `templates/java/.devcontainer/devcontainer.json` with `"name": "java-pi"`,
  consumed by Task 3 (drift check), Task 4 (fixture), Task 5 (`verify.sh` language detection).

- [ ] **Step 1: Write the failing test**

Append to `test/init-project.test.sh`, just before the final `exit $fail`:

```bash
# Java template installs correctly too, including the shared files
JAVA_TARGET="$(mktemp -d)"
bash scripts/init-project.sh java "$JAVA_TARGET" >/dev/null 2>&1
check "java install exit status" "$?" "0"
for f in devcontainer.json Dockerfile sync-personal.js install-pi.sh post-create.sh; do
  if [ -f "$JAVA_TARGET/.devcontainer/$f" ]; then echo "  PASS  java: copied $f"; else echo "  FAIL  java: missing $f"; fail=1; fi
done
if grep -q '"name": "java-pi"' "$JAVA_TARGET/.devcontainer/devcontainer.json"; then
  echo "  PASS  java: devcontainer.json names itself java-pi"
else
  echo "  FAIL  java: devcontainer.json missing/wrong name field"; fail=1
fi
if grep -q 'FROM mcr.microsoft.com/devcontainers/java:21-bookworm' "$JAVA_TARGET/.devcontainer/Dockerfile"; then
  echo "  PASS  java: Dockerfile FROM line correct"
else
  echo "  FAIL  java: Dockerfile FROM line wrong"; fail=1
fi
rm -rf "$JAVA_TARGET"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash test/init-project.test.sh`
Expected: `java install exit status` FAILs with a non-zero rc — `install_template` errors
`ERROR: template not found at .../templates/java/.devcontainer` because the directory does not
exist yet.

- [ ] **Step 3: Create `templates/java/.devcontainer/Dockerfile`**

```dockerfile
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
```

- [ ] **Step 4: Create `templates/java/.devcontainer/devcontainer.json`**

```jsonc
{
  "name": "java-pi",
  "build": { "dockerfile": "Dockerfile" },

  "features": {
    "ghcr.io/devcontainers/features/java:1": {
      "version": "none",
      "installMaven": true,
      "installGradle": true
    },
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
  "postCreateCommand": "bash .devcontainer/post-create.sh"
}
```

Note what is deliberately absent: no `customizations` block. The image's own metadata label
already registers `vscjava.vscode-java-pack` and a matching `java.import.gradle.java.home`
setting — adding it again here would be redundant, the same reason Go's `devcontainer.json`
never lists `golang.Go`.

- [ ] **Step 5: Run the test again to verify it passes**

Run: `bash test/init-project.test.sh`
Expected: every line `PASS`, exit status `0`.

- [ ] **Step 6: Commit**

```bash
git add templates/java test/init-project.test.sh
git commit -m "feat: add the Java devcontainer template

mcr.microsoft.com/devcontainers/java:21-bookworm plus the java feature with
installMaven/installGradle (the base image ships neither by default — confirmed by running
it). devcontainer.json mirrors go-pi's hardening, containerEnv, remoteEnv and lifecycle
hooks exactly; only the image, features, volumes and Dockerfile differ."
```

---

### Task 3: Drift check between the two `devcontainer.json` files

**Files:**
- Create: `test/templates.test.sh`

**Interfaces:**
- Consumes: `templates/go/.devcontainer/devcontainer.json`, `templates/java/.devcontainer/devcontainer.json` (Tasks 1 and 2).
- Produces: nothing consumed by later tasks — this is a standalone regression guard.

- [ ] **Step 1: Write the test**

```bash
#!/usr/bin/env bash
# Test: values that must stay identical across language templates' devcontainer.json do not
# silently drift apart (PI_VERSION, hardening, personal-layer plumbing). See spec decision J4.
set -uo pipefail

GO=templates/go/.devcontainer/devcontainer.json
JAVA=templates/java/.devcontainer/devcontainer.json
fail=0

# Extracts a "key": value line and strips a possible trailing comma, so JSON's
# last-property-has-no-comma rule can't cause a false mismatch.
field() { grep -o "\"$2\"[[:space:]]*:.*" "$1" | sed 's/,[[:space:]]*$//' | head -n1; }

for key in runArgs PI_VERSION PI_CODING_AGENT_SESSION_DIR HISTFILE LANG COLORTERM \
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
```

- [ ] **Step 2: Run it to verify it currently passes**

Run: `bash test/templates.test.sh`
Expected: every line `PASS`, exit status `0` — Tasks 1 and 2 already wrote both files to be
identical on these fields. This step exists to catch an authoring mistake now rather than
trust it silently; if anything FAILs, fix the mismatched file before continuing (do not edit
the test to make it pass).

- [ ] **Step 3: Commit**

```bash
git add test/templates.test.sh
git commit -m "test: assert go-pi and java-pi devcontainer.json agree on shared fields"
```

---

### Task 4: Fix the Go fixture drift, add the Java fixture, assert both match their templates

**Files:**
- Modify: `test/fixture-go/.devcontainer/` (regenerated, not hand-edited)
- Create: `test/fixture-java/.devcontainer/` (generated)
- Create: `test/fixture-java/pom.xml`
- Create: `test/fixture-java/src/main/java/com/example/fixture/Main.java`
- Create: `test/fixture-java/mise.toml`
- Create: `test/fixtures.test.sh`

**Interfaces:**
- Consumes: `scripts/init-project.sh <go|java> <dir>` (Task 1/2).
- Produces: `test/fixture-java/`, consumed by Task 5 (`scripts/verify.sh test/fixture-java`).

- [ ] **Step 1: Write the failing test**

```bash
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

- [ ] **Step 2: Run it to verify it fails**

Run: `bash test/fixtures.test.sh`
Expected: both `FAIL` — `test/fixture-go/.devcontainer` still has the drifted `post-create.sh`
from before Task 1 (missing `mcp.json`/`claude-plugins.json`/`pi update --extensions` lines,
and it still has its own copies of the now-shared scripts instead of matching what
`init-project.sh go` produces today), and `test/fixture-java/.devcontainer` does not exist yet.

- [ ] **Step 3: Regenerate the Go fixture's `.devcontainer`**

```bash
rm -rf test/fixture-go/.devcontainer
bash scripts/init-project.sh go test/fixture-go
```

`init-project.sh` prints a `.gitignore` hint to stdout; ignore it here, `test/fixture-go` is a
fixture, not a real project, and does not need a `.gitignore` update.

- [ ] **Step 4: Generate the Java fixture's `.devcontainer`**

```bash
bash scripts/init-project.sh java test/fixture-java
```

- [ ] **Step 5: Add the Java fixture's sample project**

Create `test/fixture-java/pom.xml`:

```xml
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <groupId>com.example</groupId>
  <artifactId>fixture</artifactId>
  <version>1.0.0</version>
  <packaging>jar</packaging>

  <properties>
    <maven.compiler.source>21</maven.compiler.source>
    <maven.compiler.target>21</maven.compiler.target>
    <project.build.sourceEncoding>UTF-8</project.build.sourceEncoding>
  </properties>

  <dependencies>
    <dependency>
      <groupId>org.apache.commons</groupId>
      <artifactId>commons-lang3</artifactId>
      <version>3.14.0</version>
    </dependency>
  </dependencies>
</project>
```

Create `test/fixture-java/src/main/java/com/example/fixture/Main.java`:

```java
package com.example.fixture;

import org.apache.commons.lang3.StringUtils;

public class Main {
    public static void main(String[] args) {
        System.out.println(StringUtils.capitalize("hello"));
    }
}
```

Create `test/fixture-java/mise.toml` (same illustrative project tool as `fixture-go`, proving
the shim mechanism, not anything Java-specific):

```toml
[tools]
jq = "latest"
```

- [ ] **Step 6: Run the test again to verify it passes**

Run: `bash test/fixtures.test.sh`
Expected: both `PASS`, exit status `0`.

- [ ] **Step 7: Run the full existing suite once to make sure nothing else broke**

Run: `bash test/init-project.test.sh && bash test/templates.test.sh && bash test/fixtures.test.sh`
Expected: all three exit `0`.

- [ ] **Step 8: Commit**

```bash
git add test/fixture-go test/fixture-java test/fixtures.test.sh
git commit -m "fix: regenerate fixture-go's .devcontainer, add fixture-java

fixture-go/.devcontainer had drifted from templates/go/.devcontainer (missing
post-create.sh lines added since). Both fixtures are now generated by init-project.sh
rather than hand-maintained, and test/fixtures.test.sh asserts they stay that way."
```

---

### Task 5: Language-aware `scripts/verify.sh`, verified against real containers

**Files:**
- Modify: `scripts/verify.sh`

**Interfaces:**
- Consumes: `test/fixture-go`, `test/fixture-java` (Task 4).
- Produces: `scripts/verify.sh [workspace-folder]` behaving identically to today for Go, plus
  working for Java.

- [ ] **Step 1: Read the current file to get exact line context**

Run: `grep -n "^WS=\|^MOUNTS=\|^PI_VERSION_EXPECTED\|V4 " scripts/verify.sh`

Expected output includes the lines:
```
WS="${1:-test/fixture-go}"
MOUNTS="/go/pkg/mod /home/vscode/.cache/go-build /home/vscode/.local/share/mise /home/vscode/.pi/agent/npm /home/vscode/.pi/agent/pi-claude-marketplace /home/vscode/.config /home/vscode/.history"
```
and the `V4` block near the end. Use this to locate the exact text for the edits below (line
numbers may differ slightly from what is shown here).

- [ ] **Step 2: Replace the fixed `MOUNTS` line with language detection**

Find:
```bash
MOUNTS="/go/pkg/mod /home/vscode/.cache/go-build /home/vscode/.local/share/mise /home/vscode/.pi/agent/npm /home/vscode/.pi/agent/pi-claude-marketplace /home/vscode/.config /home/vscode/.history"
```

Replace with:
```bash
LANG_DETECTED="$(grep -o '"name"[[:space:]]*:[[:space:]]*"[a-z]*-pi"' "$WS/.devcontainer/devcontainer.json" \
                  | grep -o '[a-z]*-pi' | sed 's/-pi$//')"

case "$LANG_DETECTED" in
  go)
    MOUNTS="/go/pkg/mod /home/vscode/.cache/go-build /home/vscode/.local/share/mise /home/vscode/.pi/agent/npm /home/vscode/.pi/agent/pi-claude-marketplace /home/vscode/.config /home/vscode/.history"
    ;;
  java)
    MOUNTS="/home/vscode/.m2/repository /home/vscode/.gradle /home/vscode/.local/share/mise /home/vscode/.pi/agent/npm /home/vscode/.pi/agent/pi-claude-marketplace /home/vscode/.config /home/vscode/.history"
    ;;
  *)
    echo "ERROR: cannot determine language from $WS/.devcontainer/devcontainer.json" >&2
    exit 1
    ;;
esac
```

(Named `LANG_DETECTED`, not `LANG`, because `LANG` is already the container's locale
environment variable used elsewhere in this same script and must not be shadowed.)

- [ ] **Step 3: Replace the Go-only V4 block with a language branch**

Find:
```bash
# V4 — a real build works and populates the shared module cache
expect_match "V4 GOMODCACHE"   '^/go/pkg/mod$' 'go env GOMODCACHE'
# Bind mounts present host files as root-owned; without a safe.directory entry git refuses
# to run and Go's VCS stamping fails the build.
expect_match "V4b git usable"  'On branch|HEAD detached' 'git status'
expect_match "V4 go build"     '^ok$'          'go mod tidy >/dev/null 2>&1 && go build ./... && echo ok'
expect_match "V4 cache filled" '^yes$'         '[ -d /go/pkg/mod/rsc.io ] && echo yes || echo no'
```

Replace with:
```bash
# V4 — a real build works and populates the shared dependency cache. Bind mounts present
# host files as root-owned; without a safe.directory entry git refuses to run.
if [ "$LANG_DETECTED" = go ]; then
  expect_match "V4 GOMODCACHE"   '^/go/pkg/mod$' 'go env GOMODCACHE'
  expect_match "V4b git usable"  'On branch|HEAD detached' 'git status'
  expect_match "V4 go build"     '^ok$'          'go mod tidy >/dev/null 2>&1 && go build ./... && echo ok'
  expect_match "V4 cache filled" '^yes$'         '[ -d /go/pkg/mod/rsc.io ] && echo yes || echo no'
else
  expect_match "V4b git usable"  'On branch|HEAD detached' 'git status'
  expect_match "V4 mvn build"    '^ok$'          'mvn -q -B compile && echo ok'
  expect_match "V4 cache filled" '^yes$' \
    '[ -d /home/vscode/.m2/repository/org/apache/commons ] && echo yes || echo no'
  # Gradle gets a shim-reachability check only, not a full build: both build tools ship in
  # the image (spec decision J5), only one gets a maintained build fixture.
  expect_match "V4c gradle shim" '/shims/gradle$' 'command -v gradle'
fi
```

- [ ] **Step 4: Run against the Go fixture to confirm no regression**

```bash
devcontainer up --workspace-folder test/fixture-go --remove-existing-container
ANTHROPIC_API_KEY=verify-dummy-not-a-real-key bash scripts/verify.sh test/fixture-go
```

Expected: the same pass count as before this task (check the printed `N passed, 0 failed` —
`N` must match a run of `scripts/verify.sh test/fixture-go` from before Step 2's edit; if it
does not, re-check Step 2/3's edits against the exact prior line count).

- [ ] **Step 5: Run against the Java fixture**

```bash
devcontainer up --workspace-folder test/fixture-java --remove-existing-container
ANTHROPIC_API_KEY=verify-dummy-not-a-real-key bash scripts/verify.sh test/fixture-java
```

Expected: `0 failed`. If `V4 mvn build` fails, run
`devcontainer exec --workspace-folder test/fixture-java bash -c 'mvn -q -B compile'` directly to
see the real Maven error before changing anything else.

- [ ] **Step 6: Commit**

```bash
git add scripts/verify.sh
git commit -m "feat: verify.sh detects go vs java and branches only the build-proof check

MOUNTS and the V4 build check now come from the workspace's own devcontainer.json name
field, the same detection init-project.sh --update uses. Every other check (V1-V3, V5-V9)
is already language-independent and runs unchanged for both."
```

---

### Task 6: Documentation

**Files:**
- Modify: `README.md`
- Modify: `docs/architecture.md`
- Modify: `docs/decisions.md`
- Modify: `docs/how-to.md`
- Modify: `docs/extending.md`
- Modify: `docs/findings.md`

**Interfaces:**
- Consumes: the finished, verified artifacts from Tasks 1–5 (this task documents what exists,
  it does not change behavior).

- [ ] **Step 1: Add three findings to `docs/findings.md`**

Append at the end of the file (after the last existing finding, `F17`):

```markdown
## F18 — The Java image does not bundle Maven or Gradle by default

```bash
docker run --rm mcr.microsoft.com/devcontainers/java:21-bookworm bash -lc 'command -v mvn gradle'
```

Both report nothing: `mvn`/`gradle` are absent even though SDKMAN's candidate directories for
both exist on `PATH` (`/usr/local/sdkman/candidates/{maven,gradle}/current/bin`) — they are
just empty. This mirrors F5 for the Go image almost exactly: there Node/npm sat behind an
unconfigured `nvm`, here Maven/Gradle sit behind an unconfigured SDKMAN.

Resolution: `templates/java/.devcontainer/devcontainer.json` adds
`ghcr.io/devcontainers/features/java:1` explicitly with `installMaven: true, installGradle:
true, version: "none"`. `version: "none"` stops the feature from installing a second JDK next
to the one already in the base image. Verified in a container built from this configuration:
`mvn -version` reports Maven 3.9.16, `gradle -version` reports Gradle 9.7.1, `java -version`
still reports the base image's `21.0.12.1` (no second JDK installed), and both resolve from a
non-interactive `bash -c` — the shape pi's `bash` tool uses.

## F19 — The Java image forces back no capability, unlike Go's `SYS_PTRACE` (F1)

```bash
docker inspect mcr.microsoft.com/devcontainers/java:21-bookworm \
  --format '{{index .Config.Labels "devcontainer.metadata"}}'
```

The label carries `remoteUser: vscode` and feature-recommended VS Code settings/extensions,
but no `capAdd` or `securityOpt` entries. Measured inside a container built with
`runArgs: ["--cap-drop=ALL", "--security-opt", "no-new-privileges"]` and no other flags:

```
CapBnd: 0000000000000000
CapEff: 0000000000000000
```

An **empty** capability ceiling — not the one bit (`0000000000080000`, `SYS_PTRACE`) that Go's
image metadata forces back. Consequence: Java needs no equivalent to decision D7's documented
relaxation; the hardening applies at full strength with no exception to note.

## F20 — Volume mount points behave identically to F8 for the Java image

The same `mkdir -p ... && chown -R vscode:vscode ...` pattern from `templates/go/.devcontainer/Dockerfile`
(F8) was verified against a container built from `templates/java/.devcontainer/Dockerfile`:
every one of the seven mount points (`~/.m2/repository`, `~/.gradle`, `~/.local/share/mise`,
`~/.pi/agent/npm`, `~/.pi/agent/pi-claude-marketplace`, `~/.config`, `~/.history`) came up
owned by `vscode` and writable. No language-specific surprise here; the fix generalizes.
```

- [ ] **Step 2: Update `README.md`**

Find:
```markdown
A VS Code dev container that runs the [pi coding agent](https://pi.dev) in a lightly
hardened, non-root Linux environment, without restricting anything pi can do. The first
target environment is Go.
```

Replace with:
```markdown
A VS Code dev container that runs the [pi coding agent](https://pi.dev) in a lightly
hardened, non-root Linux environment, without restricting anything pi can do. Go and Java
are supported as equal, independently maintained targets.
```

Find:
```markdown
```bash
git clone https://github.com/zorak1103/pi-devcontainer
cd pi-devcontainer
./scripts/init-project.sh /path/to/your/go-project
```
```

Replace with:
```markdown
```bash
git clone https://github.com/zorak1103/pi-devcontainer
cd pi-devcontainer
./scripts/init-project.sh go /path/to/your/go-project     # or: java /path/to/your/java-project
```
```

Find the row in the "What you get" table:
```markdown
| Base | `devcontainer.json` in your project | Go image, Node, mise, pi, the hardening flags |
```

Replace with:
```markdown
| Base | `devcontainer.json` in your project | language image (Go or Java), Node, mise, pi, the hardening flags — see [architecture.md](docs/architecture.md) |
```

- [ ] **Step 3: Update `docs/architecture.md`**

Find the three-layers table row:
```markdown
| Base | `.devcontainer/` in the project | Go image, Node feature, mise feature, pi installation, hardening | this template |
```

Replace with:
```markdown
| Base | `.devcontainer/` in the project | language image (Go or Java), Node feature, mise feature, pi installation, hardening | this template |
```

After that table, before the "Two properties make this work" paragraph, insert:

```markdown
### Template layout

```
templates/
  _shared/.devcontainer/   install-pi.sh, post-create.sh, sync-personal.js — language-independent
  go/.devcontainer/        Dockerfile, devcontainer.json — Go-specific
  java/.devcontainer/      Dockerfile, devcontainer.json — Java-specific
```

`init-project.sh` copies `_shared` first, then the requested language template over it, into
the target project's `.devcontainer/`. A language template's `devcontainer.json` must set
`"name": "<lang>-pi"` — this is how `init-project.sh --update` and `scripts/verify.sh` detect
which language a project is running, without asking again.
```

In the "Shared across all projects" volumes table, add two rows after `pi-dc-mise`:

```markdown
| `pi-dc-m2` | `/home/vscode/.m2/repository` | Maven dependency cache (Java only) |
| `pi-dc-gradle` | `/home/vscode/.gradle` | Gradle dependency/build cache (Java only) |
```

At the end of the "Volumes" section (after the existing "Known limitation" paragraph about
same-basename projects), add:

```markdown
Known limitation: `pi-dc-mise` is shared by every project **and both languages**. The risk
window is `postCreateCommand`'s `mise install`/`mise reshim`, which writes into this volume —
not simply having multiple containers running, which is fine. Do not create or rebuild two
containers at the same time; create or rebuild them one after another. Once a container has
finished its `postCreateCommand`, running it alongside others is unproblematic.
```

- [ ] **Step 4: Update `docs/decisions.md`**

After decision **D6** (Go toolchain), insert a new decision:

```markdown
## D6b — Where the Java toolchain comes from

**Chosen:** the official `mcr.microsoft.com/devcontainers/java:21-bookworm` image, plus the
`ghcr.io/devcontainers/features/java:1` feature with `installMaven: true, installGradle: true`.

Rejected: Maven-only or Gradle-only. Go has one toolchain by convention; the JVM ecosystem
does not force that choice, and picking one for the template would just relocate the decision
onto every adopter who uses the other one. Also rejected: installing Maven/Gradle through
mise instead of the feature — the base image does not bundle either by default (measured, see
[findings.md#f18](findings.md#f18--the-java-image-does-not-bundle-maven-or-gradle-by-default)),
and the feature is the same "trust the official image" reasoning as D6 rather than a
different one.

JDK 21 (LTS) is the image default; a project pins a different version the same way Go
projects pin `go` in `mise.toml` — shims come first on `PATH` and win.

**Cost:** one more feature to resolve at build time; a few hundred extra megabytes for two
build tools most Java projects only use one of.

## D10 — Sharing files across language templates

**Chosen:** `install-pi.sh`, `post-create.sh` and `sync-personal.js` — genuinely
language-independent — live once in `templates/_shared/.devcontainer/`, copied into a
language template's output by `init-project.sh` before the language-specific files.

Rejected: duplicating them per language template. This was the status quo for Go alone, and
it had already produced real drift before Java even existed:
`test/fixture-go/.devcontainer/post-create.sh` fell behind its own template because nothing
asserted they matched.

**Cost:** `devcontainer.json`/`Dockerfile` still cannot be shared this way — the Dev Container
spec has no include/extends mechanism for arbitrary JSON — so `PI_VERSION`, the hardening
`runArgs`, and the `containerEnv`/`remoteEnv`/lifecycle-hook values remain duplicated inside
each language's `devcontainer.json`. `test/templates.test.sh` asserts they stay identical
instead of trusting that by hand.
```

In decision **D8** ("What survives a rebuild"), after the existing volumes discussion, add:

```markdown
Java's `pi-dc-m2` and `pi-dc-gradle` follow the same shared-cache reasoning as `pi-dc-gomod`/
`pi-dc-gobuild`. `pi-dc-mise` itself is shared across languages too, not just across Go
projects — see the known limitation in [architecture.md](architecture.md#volumes) about not
creating two containers at the same time.
```

In decision **D3** ("How the environment reaches a project"), after the existing cost
paragraph, add:

```markdown
Adopting a project now names its language explicitly: `init-project.sh <go|java> <dir>`.
`--update` does not repeat it — it reads the language back out of the existing
`devcontainer.json`'s `name` field, so a project that already exists never needs to state its
language a second time.
```

- [ ] **Step 5: Update `docs/how-to.md`**

Find:
```markdown
```bash
./scripts/init-project.sh /path/to/your/go-project
```

Full walkthrough, including the `.gitignore` entries it prints and the API key setup, in the
[README quick start](../README.md#quick-start).
```

Replace with:
```markdown
```bash
./scripts/init-project.sh go /path/to/your/go-project      # or: java /path/to/your/java-project
```

Full walkthrough, including the `.gitignore` entries it prints and the API key setup, in the
[README quick start](../README.md#quick-start).
```

Find:
```markdown
```bash
./scripts/init-project.sh --update /path/to/your/go-project
```
```

Replace with:
```markdown
```bash
./scripts/init-project.sh --update /path/to/your/go-project
```

No language argument needed here: `--update` reads it back out of the project's existing
`devcontainer.json`.
```

- [ ] **Step 6: Rewrite "A new language target" in `docs/extending.md`**

Find:
```markdown
## A new language target

Copy `templates/go/` to `templates/<language>/` and change two things:

1. the `FROM` line in the `Dockerfile`. The
   [devcontainer images](https://github.com/devcontainers/images) cover most ecosystems, and
   they all follow the same `vscode`-user convention this template relies on.
2. the project `mise.toml` in your project.

Everything else (pi installation, personal layer, hardening, volumes) is
language-independent. Keep the `mkdir`/`chown` block: only the language-specific cache path
changes (`/go/pkg/mod` becomes `~/.cache/pip`, `~/.npm`, `~/.cargo`, and so on).
```

Replace with:
```markdown
## A new language target

A language template contributes exactly two files:
`templates/<language>/.devcontainer/{Dockerfile,devcontainer.json}`. Everything
language-independent (`install-pi.sh`, `post-create.sh`, `sync-personal.js`) already lives
once in `templates/_shared/.devcontainer/` and must not be duplicated into the new directory
— `init-project.sh` copies both automatically.

1. `Dockerfile`: pick the official [devcontainer image](https://github.com/devcontainers/images)
   for the ecosystem (they all follow the same `vscode`-user convention this template relies
   on), then a `mkdir -p ... && chown -R vscode:vscode ...` block covering every mount point
   the new `devcontainer.json` declares — this is not optional, see
   [findings.md#f8](findings.md#f8--named-volumes-on-paths-absent-from-the-image-are-created-root-owned).
2. `devcontainer.json`: copy `runArgs`, `containerEnv`, `remoteEnv`, and the three lifecycle
   hooks (`initializeCommand`, `onCreateCommand`, `postCreateCommand`) byte-for-byte from an
   existing template — these must stay identical across every language template. Set
   `"name"` to `"<language>-pi"`. **This is load-bearing, not cosmetic:**
   `init-project.sh --update` and `scripts/verify.sh` both parse this field to detect which
   template a project uses, with no separate argument for it.
3. Add the language to `scripts/init-project.sh`'s `case "${1:-}" in go|java)` validation.
4. Add a branch for the language to `scripts/verify.sh`'s `MOUNTS`/build-check `case`
   (mirroring the one for `go`/`java`), with a real build proof for the check that matters
   most (a compiler/build-tool invocation that populates the language's dependency cache).
5. Add `test/fixture-<language>/` (a minimal buildable project) and confirm
   `test/fixtures.test.sh` passes for it — fixtures are generated by `init-project.sh`, never
   hand-maintained (this is what let Go's fixture drift from its own template once already).
6. State the language version explicitly in the project-layer `mise.toml` example, the same
   way Go states `go = "1.27"` and Java states `java = "21"` — most language version
   directives are minimums, not pins, and mise does not read them by default
   ([findings.md#f7](findings.md#f7--mise-does-not-read-gomod-by-default)).
```

- [ ] **Step 7: Check the remaining docs for stray Go-only assumptions**

```bash
grep -niE 'go\b|golang' docs/comparison.md docs/threat-model.md docs/providers.md docs/setup-windows.md
```

Expected: no hits that assume Go is the only target (a hit inside a sentence about the
`marcfargas/pi-devcontainers` comparison or about Go's own history is fine and needs no
change — read each hit in context rather than editing on sight). If a hit does state or imply
Go is the only supported language, generalize that sentence the same way Step 2's README edit
did.

- [ ] **Step 8: Run `test/docs.test.sh`**

Run: `bash test/docs.test.sh`
Expected: `PASS documentation complete` — no placeholder markers, no broken relative links, all
required files present and non-empty.

- [ ] **Step 9: Commit**

```bash
git add README.md docs/architecture.md docs/decisions.md docs/how-to.md docs/extending.md docs/findings.md
git commit -m "docs: document Java as a second, equal devcontainer target

Weaves Java into the existing docs next to Go rather than forking a parallel doc tree:
architecture.md gets the templates/_shared layout and the two new shared volumes,
decisions.md gets D6b and D10, extending.md's 'new language target' recipe is rewritten for
the _shared mechanism, and findings.md gets F18-F20 from the real measurements taken while
building templates/java."
```

---

### Task 7: Full regression pass

**Files:** none (verification only)

**Interfaces:** none — this task runs everything built in Tasks 1–6 together.

- [ ] **Step 1: Run every shell test**

```bash
bash test/init-project.test.sh
bash test/templates.test.sh
bash test/fixtures.test.sh
bash test/docs.test.sh
```

Expected: all four exit `0`.

- [ ] **Step 2: Run the acceptance checks against both live containers one more time**

```bash
devcontainer up --workspace-folder test/fixture-go --remove-existing-container
ANTHROPIC_API_KEY=verify-dummy-not-a-real-key bash scripts/verify.sh test/fixture-go

devcontainer up --workspace-folder test/fixture-java --remove-existing-container
ANTHROPIC_API_KEY=verify-dummy-not-a-real-key bash scripts/verify.sh test/fixture-java
```

Expected: both report `0 failed`.

- [ ] **Step 3: Confirm the branch is clean and ahead of `main`**

```bash
git status --short
git log --oneline main..HEAD
```

Expected: no uncommitted changes; the log shows exactly the commits from Tasks 1–6 (plus the
two spec commits made before this plan existed).

- [ ] **Step 4: Hand off**

No commit in this task — it is a verification checkpoint. Report the results of Steps 1–3 and
proceed to `superpowers:finishing-a-development-branch` for how `feature/java-devcontainer`
should be integrated (merge, rebase, or PR), which is outside this plan's scope.
