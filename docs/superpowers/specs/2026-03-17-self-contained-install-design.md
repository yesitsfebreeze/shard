# Self-Contained Binary Install + AI Setup

**Date:** 2026-03-17  
**Status:** Approved

## Overview

Users download a single binary, then tell their AI agent `run shard install --ai-help and set me up`. Everything needed to install, configure, and use shard — workspace init, MCP config, agent file setup — is embedded in the binary itself. No source checkout, no build tools, no separate docs.

---

## 1. Release Model

### Branches

| Branch | Purpose |
|--------|---------|
| `main` | Development + nightly builds |
| `release` | Stable — never committed to directly |

### Tags

| Tag | Meaning |
|-----|---------|
| `main` | Latest nightly build (rolling, overwritten on every push to `main`) |
| `vX.X.X` | Stable semver release |

GitHub's `releases/latest/download/` automatically redirects to the newest non-prerelease `vX.X.X` tag.

### Release Triggers

**Nightly (always):** Every push to `main` builds all three platforms and overwrites the `main` release tag.

**Stable (two ways):**
1. **Commit message trigger** — commit to `main` with message matching `^release: v\d+\.\d+\.\d+` (e.g. `release: v0.1.0`)
2. **Manual trigger** — `workflow_dispatch` with a `version` input (e.g. `v0.1.0`)

**Stable release flow:**
1. Extract version from commit message or `workflow_dispatch` input
2. Merge `main` into `release` branch
3. Create and push git tag `vX.X.X` on that commit
4. Build all three platforms
5. Publish GitHub release with tag `vX.X.X`

---

## 2. CI Workflow (`build.yml`)

### Triggers

```yaml
on:
  push:
    branches: [main, release]
  workflow_dispatch:
    inputs:
      version:
        description: 'Release version (e.g. v0.1.0)'
        required: false
```

### Jobs

#### `check-release`
- Runs on push to `main` only
- Reads HEAD commit message
- Sets output `version` if message matches `^release: v\d+\.\d+\.\d+`
- Otherwise sets `version` to empty string

#### `build` (matrix: linux-amd64, macos-arm64, windows-amd64)
- Always runs on push to `main` or `release`, or `workflow_dispatch`
- Builds with `just release` (compile + UPX compress)
- Packages into platform archives
- Uploads as artifacts

#### `publish-nightly`
- Runs after `build`, only when branch is `main` and it is NOT a stable release commit
- Overwrites the `main` release tag with new assets

#### `stable-release`
- Runs when `check-release` outputs a version, OR `workflow_dispatch` provides a version
- Merges `main` into `release` branch (fast-forward or merge commit)
- Creates and pushes git tag `vX.X.X`
- Creates GitHub release with that tag using the build artifacts
- Does NOT overwrite the `main` nightly tag

### Tag name logic

```
if workflow_dispatch.version != "":
    tag = workflow_dispatch.version
elif check-release.version != "":
    tag = check-release.version
else:
    tag = "main"  # nightly
```

---

## 3. README Install Section

Replaces the existing "Install agent instructions" section. Structure:

### Stable install (primary, per platform)

**macOS:**
```bash
curl -fsSL https://github.com/yesitsfebreeze/shard/releases/latest/download/shard-macos-arm64.tar.gz | tar xz && sudo mv shard /usr/local/bin/
```

**Linux:**
```bash
curl -fsSL https://github.com/yesitsfebreeze/shard/releases/latest/download/shard-linux-amd64.tar.gz | tar xz && sudo mv shard /usr/local/bin/
```

**Windows (PowerShell):**
```powershell
$dir = "$env:USERPROFILE\.local\bin"
New-Item -ItemType Directory -Force $dir | Out-Null
Invoke-WebRequest https://github.com/yesitsfebreeze/shard/releases/latest/download/shard-windows-amd64.zip -OutFile shard.zip
Expand-Archive shard.zip -DestinationPath $dir -Force
Remove-Item shard.zip
[Environment]::SetEnvironmentVariable("PATH", "$env:PATH;$dir", "User")
```

### Nightly (secondary, collapsed `<details>` block)

Same commands with `main` instead of `latest`:
- `.../download/main/shard-macos-arm64.tar.gz`
- `.../download/main/shard-linux-amd64.tar.gz`
- `.../download/main/shard-windows-amd64.zip`

### AI setup call-to-action

After the install commands:

```
Then tell your AI agent:
    run `shard install --ai-help` and set me up
```

---

## 4. Command Responsibility Split

### `shard init` — workspace only

Initializes or re-initializes the `.shards/` workspace. No MCP config, no agent files.

1. Creates `.shards/` directory (if not exists)
2. Generates `.shards/config` with defaults (if not exists, or re-generates)
3. Asks about encryption:
   - If enabled: generates 64-hex master key, writes `.shards/keychain`
   - If disabled: skips key generation
4. Prints confirmation. No MCP config output.

`shard init --help` → human help for workspace init  
`shard init --ai-help` → AI reference for workspace init (existing `init.md`, stripped of MCP section)

### `shard install` — full onboarding

Calls `init` (workspace), then handles MCP config + agent instruction file setup in two distinct steps.

1. **Workspace** — delegates to `_run_init()` logic (workspace only, no MCP output)
2. **MCP config files** — detects binary path, writes tool-specific MCP JSON config files for all detected tools. These tell each tool how to start the MCP server (`shard mcp`):
   - `opencode.json` → OpenCode MCP config (always)
   - `.mcp.json` → Claude Code MCP config (always)
   - `.cursor/mcp.json` → Cursor MCP config (if `.cursor/` exists)
   - `.codeium/windsurf/mcp_config.json` → Windsurf MCP config (if `.codeium/` exists)
   - `.vscode/settings.json` → Copilot MCP config, merged into existing file (if `.vscode/` exists)
3. **Agent instruction files** — writes or symlinks the agent instructions file so each tool can find it. These tell each tool how to behave on this codebase:
   - `CLAUDE.md` → symlink to `.agent/instructions.md` (always)
   - `.github/copilot-instructions.md` → symlink to `../.agent/instructions.md` relative to `.github/` — i.e. `../.agent/instructions.md` from the `.github/` directory (if `.vscode/` exists)
   - `.cursorrules` → symlink to `.agent/instructions.md` (if `.cursor/` exists)
   - `.windsurfrules` → symlink to `.agent/instructions.md` (if `.codeium/` exists)

   **Windows symlink fallback:** Windows requires Developer Mode or elevated privileges for symlinks. If symlink creation fails (permission error), fall back to copying the file content instead of symlinking. The fallback copy must be noted in the summary output so the user knows the file is a copy (not a live link) and will need to be updated manually.
4. Prints summary of what was written, what was skipped (already exists), what was not applicable (tool not detected)

`shard install --help` → human help for full install  
`shard install --ai-help` → new dedicated AI setup doc (see Section 5)

### Detection logic for tool presence

| Tool | Detection signal |
|------|-----------------|
| OpenCode | Always (write `opencode.json`) |
| Claude Code | Always (write `CLAUDE.md` + `.mcp.json`) |
| Cursor | `.cursor/` directory exists |
| Windsurf | `.codeium/` directory exists |
| Copilot | `.vscode/` directory exists |

If a config file already exists, `shard install` skips it and reports "already configured".

---

## 5. Embedded AI Setup Doc (`src/help/ai/install.md`)

New file, exposed as `HELP_AI_INSTALL` in `help.odin`, printed by `shard install --ai-help`.

### Content structure

```markdown
# shard install — AI Agent Setup Reference

## What This Command Does
Full onboarding: workspace init + MCP config + agent tool setup.
Run this once after downloading the binary. Safe to re-run.

## Step 1: Verify Binary is in PATH
Run `shard --help`. If not found, place binary at:
- macOS/Linux: /usr/local/bin/shard  (requires sudo)
- Windows: %USERPROFILE%\.local\bin\shard.exe
  Then run: setx PATH "%PATH%;%USERPROFILE%\.local\bin"

## Step 2: Run Install
  shard install
If you cannot provide interactive input, perform manually:
  1. mkdir .shards
  2. Generate a key: openssl rand -hex 32 (or any 64-char hex string)
  3. Write .shards/keychain:
       # Shard master key
       * <64-hex-key>
  4. Write .shards/config:
       [daemon]
       ipc = "shard-daemon"

       [llm]
       # Optional: LLM_URL and EMBED_MODEL for vector search
  (MCP config is handled automatically by shard install — do not add it manually here)

## Step 3: MCP Config
shard install writes config files for all detected tools automatically.
If your tool was not detected, configure it manually:
  command: <path-to-shard-binary> mcp
  [JSON blocks per tool]

## Step 4: Verify
  shard daemon &
  shard mcp
Expect: MCP server starts, lists available tools.

## Step 5: Next Steps
  shard --ai-help       full protocol reference
  shard init --ai-help  workspace setup details
  shard mcp --ai-help   MCP tools reference
```

---

## 6. Code Changes

### `src/help.odin`
Add:
```odin
@(private) HELP_AI_INSTALL :: string(#load("help/ai/install.md"))
```

### `src/main.odin`
Add `case "install":` in the main switch:
```odin
case "install":
    _run_install()
    return
```

Add `_run_install()`:
- Checks args for `--ai-help` → prints `HELP_AI_INSTALL`
- Checks args for `--help` / `-h` → prints `HELP_INSTALL`
- Otherwise: calls workspace init logic, then MCP + agent setup logic

### `src/help/install.txt` (new)
Human-readable help for `shard install --help`.

### `src/help/ai/install.md` (new)
AI reference doc as described in Section 5.

### `src/main.odin` — `_run_init()` refactor
Currently `_run_init()` ends by printing MCP config JSON for the user to copy. That output moves to `_run_install()`. After refactor:
- `_run_init()` = creates `.shards/`, generates config + keychain, prints confirmation. No MCP output.
- `_run_install()` = calls `_run_init()` workspace logic, then writes MCP config files (step 2) and agent instruction files/symlinks (step 3), then prints summary

---

## 7. File Map Changes

| File | Change |
|------|--------|
| `.github/workflows/build.yml` | Add `check-release`, `publish-nightly`, `stable-release` jobs; add `release` branch trigger; add `workflow_dispatch` version input |
| `README.md` | Replace install section with per-platform stable+nightly commands + AI setup CTA |
| `src/main.odin` | Add `case "install":`, `_run_install()`, refactor `_run_init()` |
| `src/help.odin` | Add `HELP_INSTALL` + `HELP_AI_INSTALL` constants |
| `src/help/install.txt` | New: human help for `shard install` |
| `src/help/ai/install.md` | New: AI agent setup reference |
| `src/help/ai/init.md` | Remove MCP config section (now belongs to install) |

---

## 8. Out of Scope

- macOS ARM vs AMD64 detection (only `macos-arm64` build exists for now)
- Automatic PATH modification on Unix (user does it manually via README command)
- `shard update` command (upgrade binary in-place)
- Windows PATH persistence restart notice (out of scope, agent can note it)
