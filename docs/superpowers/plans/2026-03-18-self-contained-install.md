# Self-Contained Binary Install Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Embed everything needed to install and set up shard in the binary itself — so a user can download the exe, run `shard install --ai-help`, and their agent handles the rest end-to-end.

**Architecture:** Split `shard init` (workspace only) from `shard install` (full onboarding: workspace + MCP configs + agent instruction files). Add a new `src/help/ai/install.md` embedded at compile time. Update CI to publish stable releases from `vX.X.X` tags triggered by `release: vX.X.X` commit messages.

**Tech Stack:** Odin, GitHub Actions, `just`

**Spec:** `docs/superpowers/specs/2026-03-17-self-contained-install-design.md`

---

## File Map

| File | Action | Responsibility |
|------|--------|---------------|
| `src/main.odin` | Modify | Add `case "install":`, `_run_install()`, refactor `_run_init()` to workspace-only |
| `src/help.odin` | Modify | Add `HELP_INSTALL` + `HELP_AI_INSTALL` constants |
| `src/help/install.txt` | Create | Human-readable help for `shard install --help` |
| `src/help/ai/install.md` | Create | AI agent full setup reference for `shard install --ai-help` |
| `src/help/ai/init.md` | Modify | Remove MCP config section (now belongs to install) |
| `src/help/overview.txt` | Modify | Add `install` to command list |
| `.github/workflows/build.yml` | Modify | Add `check-release` + `stable-release` jobs, `workflow_dispatch` version input |

---

## Task 1: Refactor `_run_init()` to workspace-only

**Files:**
- Modify: `src/main.odin:236-340`

The current `_run_init()` does 4 things: create `.shards/`, write config, generate keychain, print MCP JSON. Step 4 (MCP JSON) moves to `_run_install()`. We extract a shared helper `_run_workspace_init()` that `_run_init()` and `_run_install()` both call.

- [ ] **Step 1: Extract `_workspace_init()` helper**

In `src/main.odin`, add a new private proc just above `_run_init()` that contains the workspace-only logic (steps 1–3 of current `_run_init()`). It takes no args and returns the generated `key_hex` so install can use it for the summary:

```odin
@(private)
_workspace_init :: proc() -> (key_hex: string) {
    logger.info("=== Shard workspace setup ===")
    logger.info("")

    already_exists := os.exists(".shards")
    if already_exists {
        logger.info(".shards/ directory already exists — will skip existing files.")
    } else {
        os.make_directory(".shards")
        logger.info("Created .shards/")
    }

    if os.exists(CONFIG_PATH) {
        logger.infof("  %s already exists — skipping.", CONFIG_PATH)
    } else {
        s := DEFAULT_CONFIG_FILE
        if os.write_entire_file(CONFIG_PATH, s) {
            logger.infof("  Created %s", CONFIG_PATH)
        } else {
            logger.errf("  warning: could not write %s", CONFIG_PATH)
        }
    }

    if os.exists(KEYCHAIN_PATH) {
        logger.infof("  %s already exists — skipping key setup.", KEYCHAIN_PATH)
    } else {
        logger.info("")
        logger.info("Encryption protects your thoughts at rest with ChaCha20-Poly1305.")
        logger.info("A single master key is used for all shards in this workspace.")
        logger.info("")
        choice := _prompt("Enable encryption? (Y/n): ")

        if choice == "n" || choice == "N" {
            logger.info("")
            logger.info("Encryption disabled. Thoughts will be stored in plaintext.")
            logger.info("You can enable encryption later by creating .shards/keychain manually.")
        } else {
            master: Master_Key
            crypto.rand_bytes(master[:])
            hex_out := hex.encode(master[:], context.temp_allocator)
            key_hex = strings.clone(string(hex_out))

            kc_content := fmt.tprintf(
                "# Shard master key — applies to all shards in this workspace\n# DO NOT share this file. If you lose this key, encrypted thoughts are unrecoverable.\n* %s\n",
                key_hex,
            )
            if os.write_entire_file(KEYCHAIN_PATH, transmute([]u8)kc_content) {
                logger.info("")
                logger.info("Generated master key and saved to .shards/keychain")
                logger.info("")
                logger.infof("  KEY: %s", key_hex)
                logger.info("")
                logger.info("  This is a one-time secret. Back it up somewhere safe.")
                logger.info("  If you lose this key, your encrypted thoughts cannot be recovered.")
            } else {
                logger.errf("  warning: could not write %s", KEYCHAIN_PATH)
            }
        }
    }
    return key_hex
}
```

- [ ] **Step 2: Simplify `_run_init()` to call `_workspace_init()` then print confirmation**

Replace the body of `_run_init()` (lines 247–340) with:

```odin
_run_init :: proc() {
    for arg in os.args[2:] {
        if arg == "--help" || arg == "-h" {
            _print_help(HELP_INIT)
            return
        } else if arg == "--ai-help" {
            _print_help(HELP_AI_INIT)
            return
        }
    }

    _workspace_init()

    logger.info("")
    logger.info("=== Workspace ready ===")
    logger.info("")
    logger.info("Run \"shard install\" to configure your AI tool (MCP + agent setup).")
    logger.info("Or run \"shard daemon &\" and \"shard mcp\" to start manually.")
}
```

- [ ] **Step 3: Build to verify no compile errors**

```bash
just test-build
```
Expected: `All tests were successful.`

- [ ] **Step 4: Commit**

```bash
git add src/main.odin
git commit -m "refactor: extract _workspace_init(), make _run_init() workspace-only"
```

---

## Task 2: Add `src/help/install.txt` and `src/help/ai/install.md`

**Files:**
- Create: `src/help/install.txt`
- Create: `src/help/ai/install.md`
- Modify: `src/help/ai/init.md` (remove MCP config section)
- Modify: `src/help/overview.txt` (add `install` to command list)

- [ ] **Step 1: Write `src/help/install.txt`**

```
shard install — full workspace + AI tool setup

Usage:
  shard install [--help] [--ai-help]

What it does:
  1. Initializes .shards/ workspace (same as shard init)
  2. Writes MCP config files for detected AI tools
  3. Creates agent instruction file symlinks for detected AI tools

Detected tools:
  OpenCode    opencode.json
  Claude Code CLAUDE.md + .mcp.json
  Cursor      .cursor/mcp.json + .cursorrules  (if .cursor/ exists)
  Windsurf    .codeium/windsurf/mcp_config.json + .windsurfrules  (if .codeium/ exists)
  Copilot     .vscode/settings.json + .github/copilot-instructions.md  (if .vscode/ exists)

Safe to re-run. Skips files that already exist.

Flags:
  --help       Show this help
  --ai-help    Print structured AI agent setup reference

AI AGENTS: Run "shard install --ai-help" for step-by-step setup instructions.
```

- [ ] **Step 2: Write `src/help/ai/install.md`**

```markdown
# shard install — AI Agent Setup Reference

> Run this after downloading the shard binary. Safe to re-run.

## Step 1: Verify Binary is in PATH

Run: `shard --help`

If the command is not found, place the binary at the correct location:

**macOS / Linux:**
```bash
sudo mv shard /usr/local/bin/
```

**Windows (PowerShell):**
```powershell
$dir = "$env:USERPROFILE\.local\bin"
New-Item -ItemType Directory -Force $dir | Out-Null
Move-Item shard.exe $dir
[Environment]::SetEnvironmentVariable("PATH", "$env:PATH;$dir", "User")
# Note: PATH change takes effect in new terminal sessions only
```

## Step 2: Initialize Workspace

Run: `shard install`

This creates `.shards/`, generates encryption key, writes config, and configures all detected AI tools automatically.

If you cannot provide interactive input (the command asks "Enable encryption? (Y/n)"), perform workspace setup manually:

1. `mkdir .shards`
2. Generate a key: `openssl rand -hex 32` (or any 64-char hex string)
3. Write `.shards/keychain`:
   ```
   # Shard master key
   * <64-hex-key>
   ```
4. Write `.shards/config`:
   ```
   [daemon]
   ipc = "shard-daemon"

   [llm]
   # Optional: LLM_URL and LLM_MODEL for vector search and AI features
   ```
5. Then run `shard install` again — it will skip the workspace steps and proceed to MCP + agent setup.

(MCP config is handled automatically by `shard install` — do not add it manually.)

## Step 3: Verify MCP Config

`shard install` writes MCP config files for all detected tools. If your tool was not detected, configure it manually:

```json
{
  "mcpServers": {
    "shard": {
      "type": "stdio",
      "command": "<path-to-shard-binary>",
      "args": ["mcp"]
    }
  }
}
```

Replace `<path-to-shard-binary>` with the full path (e.g. `/usr/local/bin/shard` or `C:\Users\you\.local\bin\shard.exe`).

## Step 4: Verify Setup

```bash
shard daemon &
shard mcp
```

Expected: MCP server starts and lists available tools (shard_discover, shard_query, shard_write, etc.).

If the daemon is already running, `shard mcp` connects to it automatically.

## Step 5: Next Steps

```
shard --ai-help             full protocol reference
shard init --ai-help        workspace setup details
shard mcp --ai-help         MCP tools reference
shard daemon --ai-help      daemon operations
```

## Key Resolution

The keychain at `.shards/keychain` resolves encryption keys automatically for all MCP tool calls. Agents do not need to manage keys directly — the daemon handles it.

## Creating Shards

No pre-creation needed. Use `shard_remember` to create shards on the fly:
- `shard_discover` — see all existing shards
- `shard_remember` — create a new shard with name, purpose, and gates
- `shard_query` — search across all shards
```

- [ ] **Step 3: Update `src/help/ai/init.md` — remove MCP config section**

The current Step 5 in `init.md` ("Configure MCP in your AI client") now belongs to `install`. Remove it. The file should end after step 4 (write `.shards/config`), and the Key Resolution section remains unchanged.

Edit `src/help/ai/init.md`: remove lines:
```
5. Configure MCP in your AI client:
   ```json
   {
     "mcpServers": {
       "shard": {
         "type": "stdio",
         "command": "<path-to-shard-binary>",
         "args": ["mcp"]
       }
     }
   }
   ```
```
And update the numbered list so it ends at 4. Add a note at the end:
```
MCP configuration is handled by `shard install`. Run `shard install --ai-help` for the full setup flow.
```

- [ ] **Step 4: Update `src/help/overview.txt` — add `install` command**

Add `install` to the Commands section, just below `init`:
```
  install      Full setup: workspace init + MCP config + agent tool integration
```

- [ ] **Step 5: Build to verify no compile errors**

```bash
just test-build
```
Expected: `All tests were successful.`

- [ ] **Step 6: Commit**

```bash
git add src/help/install.txt src/help/ai/install.md src/help/ai/init.md src/help/overview.txt
git commit -m "docs: add install help files, update init.md and overview.txt"
```

---

## Task 3: Wire `HELP_INSTALL` + `HELP_AI_INSTALL` into `help.odin`

**Files:**
- Modify: `src/help.odin`

- [ ] **Step 1: Add two new constants to `src/help.odin`**

After the existing human-readable block (after `HELP_MCP`), add:
```odin
@(private) HELP_INSTALL    :: string(#load("help/install.txt"))
```

After the existing AI reference block (after `HELP_AI_DUMP`), add:
```odin
@(private) HELP_AI_INSTALL :: string(#load("help/ai/install.md"))
```

- [ ] **Step 2: Build to verify `#load` paths resolve**

```bash
just test-build
```
Expected: `All tests were successful.`

- [ ] **Step 3: Commit**

```bash
git add src/help.odin
git commit -m "feat: embed HELP_INSTALL and HELP_AI_INSTALL constants"
```

---

## Task 4: Add `_run_install()` and `case "install":` in `src/main.odin`

**Files:**
- Modify: `src/main.odin`

This is the main logic task. `_run_install()` calls `_workspace_init()`, then writes MCP config files (step 2), then writes agent instruction symlinks/copies (step 3), then prints a summary.

- [ ] **Step 1: Add `case "install":` to the main switch**

In `main()`, after `case "init":`, add:
```odin
case "install":
    _run_install()
    return
```

- [ ] **Step 2: Add `_run_install()` proc**

Add after `_run_init()` in `src/main.odin`:

```odin
// =============================================================================
// shard install — workspace init + MCP config + agent tool setup
// =============================================================================

@(private)
_run_install :: proc() {
    for arg in os.args[2:] {
        if arg == "--help" || arg == "-h" {
            _print_help(HELP_INSTALL)
            return
        } else if arg == "--ai-help" {
            _print_help(HELP_AI_INSTALL)
            return
        }
    }

    // Step 1: workspace
    key_hex := _workspace_init()
    _ = key_hex

    // Step 2: MCP config files
    logger.info("")
    logger.info("=== Configuring AI tools ===")
    logger.info("")

    exe_path := os.args[0]
    exe_json, _ := strings.replace_all(exe_path, `\`, `\\`)

    _install_write_mcp_opencode(exe_path)
    _install_write_mcp_claude(exe_json)
    if os.exists(".cursor") {
        _install_write_mcp_cursor(exe_json)
    }
    if os.exists(".codeium") {
        _install_write_mcp_windsurf(exe_json)
    }
    if os.exists(".vscode") {
        _install_write_mcp_copilot(exe_json)
    }

    // Step 3: agent instruction files
    logger.info("")
    logger.info("=== Writing agent instruction files ===")
    logger.info("")

    _install_symlink_or_copy("CLAUDE.md", ".agent/instructions.md")
    if os.exists(".cursor") {
        _install_symlink_or_copy(".cursorrules", ".agent/instructions.md")
    }
    if os.exists(".codeium") {
        _install_symlink_or_copy(".windsurfrules", ".agent/instructions.md")
    }
    if os.exists(".vscode") {
        os.make_directory(".github")
        _install_symlink_or_copy(".github/copilot-instructions.md", "../.agent/instructions.md")
    }

    logger.info("")
    logger.info("=== Install complete ===")
    logger.info("")
    logger.info("Start the daemon and MCP server:")
    logger.info("  shard daemon &")
    logger.info("  shard mcp")
    logger.info("")
    logger.info("For AI agents: run \"shard install --ai-help\" for the full setup reference.")
}
```

- [ ] **Step 3: Add MCP config writer helpers**

Add these helper procs after `_run_install()`. Each writes one tool's MCP config file, skipping if it already exists and reporting what it did:

```odin
@(private)
_install_write_file :: proc(path: string, content: string) -> (wrote: bool) {
    if os.exists(path) {
        logger.infof("  %s — already exists, skipping", path)
        return false
    }
    if os.write_entire_file(path, transmute([]u8)content) {
        logger.infof("  %s — written", path)
        return true
    }
    logger.errf("  %s — warning: could not write", path)
    return false
}

@(private)
_install_write_mcp_opencode :: proc(exe_path: string) {
    content := fmt.tprintf(`{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    "shard": {
      "type": "local",
      "command": ["%s", "mcp"],
      "enabled": true
    }
  }
}
`, exe_path)
    _install_write_file("opencode.json", content)
}

@(private)
_install_write_mcp_claude :: proc(exe_json: string) {
    content := fmt.tprintf(`{
  "mcpServers": {
    "shard": {
      "command": "%s",
      "args": ["mcp"]
    }
  }
}
`, exe_json)
    _install_write_file(".mcp.json", content)
}

@(private)
_install_write_mcp_cursor :: proc(exe_json: string) {
    os.make_directory(".cursor")
    content := fmt.tprintf(`{
  "mcpServers": {
    "shard": {
      "command": "%s",
      "args": ["mcp"]
    }
  }
}
`, exe_json)
    _install_write_file(".cursor/mcp.json", content)
}

@(private)
_install_write_mcp_windsurf :: proc(exe_json: string) {
    os.make_directory(".codeium")
    os.make_directory(".codeium/windsurf")
    content := fmt.tprintf(`{
  "mcpServers": {
    "shard": {
      "command": "%s",
      "args": ["mcp"]
    }
  }
}
`, exe_json)
    _install_write_file(".codeium/windsurf/mcp_config.json", content)
}

@(private)
_install_write_mcp_copilot :: proc(exe_json: string) {
    // VS Code settings.json — write only if it doesn't exist yet.
    // Spec note: merging into an existing settings.json is intentionally out of scope
    // (too risky to corrupt existing user config). If the file already exists, we skip
    // it and instruct the user to add the shard MCP entry manually.
    settings_path := ".vscode/settings.json"
    if os.exists(settings_path) {
        logger.infof("  %s — already exists, skipping (add shard MCP config manually)", settings_path)
        return
    }
    os.make_directory(".vscode")
    content := fmt.tprintf(`{
  "github.copilot.chat.codeGeneration.instructions": [
    { "file": ".agent/instructions.md" }
  ],
  "mcp": {
    "servers": {
      "shard": {
        "command": "%s",
        "args": ["mcp"]
      }
    }
  }
}
`, exe_json)
    os.write_entire_file(settings_path, transmute([]u8)content)
    logger.infof("  %s — written", settings_path)
}
```

- [ ] **Step 4: Add `_install_symlink_or_copy()` helper**

This tries to create a symlink; on failure (Windows without Developer Mode) it falls back to copying the file:

```odin
@(private)
_install_symlink_or_copy :: proc(link_path: string, target: string) {
    if os.exists(link_path) {
        logger.infof("  %s — already exists, skipping", link_path)
        return
    }

    // Try symlink first
    when ODIN_OS == .Windows {
        // On Windows, symlinks require Developer Mode or elevated privileges.
        // Try; fall back to copy on failure.
        err := os.symlink(target, link_path)
        if err == nil {
            logger.infof("  %s -> %s (symlink)", link_path, target)
            return
        }
        // Symlink failed — fall back to copy
        // Resolve the actual source path relative to link location
        src_content, ok := os.read_entire_file(target)
        if !ok {
            logger.errf("  %s — warning: could not read source %s for copy fallback", link_path, target)
            return
        }
        defer delete(src_content)
        if os.write_entire_file(link_path, src_content) {
            logger.infof("  %s — copied (symlink unavailable; re-run install after updates)", link_path)
        } else {
            logger.errf("  %s — warning: could not write", link_path)
        }
    } else {
        err := os.symlink(target, link_path)
        if err == nil {
            logger.infof("  %s -> %s (symlink)", link_path, target)
        } else {
            logger.errf("  %s — warning: symlink failed: %v", link_path, err)
        }
    }
}
```

- [ ] **Step 5: Build to verify no compile errors**

```bash
just test-build
```
Expected: `All tests were successful.`

- [ ] **Step 6: Smoke-test manually**

```bash
./bin/shard install --help       # should print install.txt
./bin/shard install --ai-help    # should print ai/install.md
```

- [ ] **Step 7: Commit**

```bash
git add src/main.odin
git commit -m "feat: add shard install command with MCP config + agent file setup"
```

---

## Task 5: Update CI workflow for semver stable releases

**Files:**
- Modify: `.github/workflows/build.yml`

- [ ] **Step 1: Add `workflow_dispatch` version input and `release` branch trigger**

Replace the current `on:` block:
```yaml
on:
  push:
    branches: [main]
    tags: ['v*']
  workflow_dispatch:
    inputs:
      tag:
        description: 'Release tag (e.g. v0.1.0)'
        required: true
```

With:
```yaml
on:
  push:
    branches: [main, release]
  workflow_dispatch:
    inputs:
      version:
        description: 'Stable release version (e.g. v0.1.0). Leave empty for nightly.'
        required: false
        default: ''
```

Note: `release` branch is included so that when the `stable-release` job force-pushes `main` into `release`, any branch-protection CI checks on `release` still run. The `check-release` job only extracts a version on pushes to `main` — on pushes to `release` it outputs an empty version, which causes `publish-nightly` to skip and `stable-release` to skip, so no duplicate release is triggered.

- [ ] **Step 2: Add `check-release` job**

Add this job after the `on:` block, before `jobs: build:`:

```yaml
jobs:
  check-release:
    runs-on: ubuntu-latest
    outputs:
      version: ${{ steps.extract.outputs.version }}
    steps:
      - uses: actions/checkout@v5
      - name: Extract release version from commit message
        id: extract
        run: |
          VERSION=""
          if [[ "${{ github.event_name }}" == "workflow_dispatch" && -n "${{ github.event.inputs.version }}" ]]; then
            VERSION="${{ github.event.inputs.version }}"
          elif [[ "${{ github.event_name }}" == "push" ]]; then
            MSG=$(git log -1 --format='%s')
            if [[ "$MSG" =~ ^release:\ (v[0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
              VERSION="${BASH_REMATCH[1]}"
            fi
          fi
          echo "version=$VERSION" >> "$GITHUB_OUTPUT"
          if [[ -n "$VERSION" ]]; then
            echo "Stable release: $VERSION"
          else
            echo "Nightly build"
          fi
```

- [ ] **Step 3: Make `build` job depend on `check-release` correctly**

The `check-release` job must not block `build` when triggered by `workflow_dispatch` or a push to `release`. Use `always()` in the `needs` condition so `build` runs regardless of whether `check-release` ran:

```yaml
  build:
    needs: check-release
    if: always()
    strategy:
      ...
```

This ensures `build` always runs on any trigger, while still consuming the `check-release` output when it's available (empty string if not a `main` push).

- [ ] **Step 4: Add `publish-nightly` job**

Replace the existing `release:` job with two separate jobs. First, the nightly job:

```yaml
  publish-nightly:
    needs: [check-release, build]
    runs-on: ubuntu-latest
    # Only publish nightly when this is NOT a stable release
    if: needs.check-release.outputs.version == ''
    steps:
      - name: Download artifacts
        uses: actions/download-artifact@v5
        with:
          path: release-assets
          merge-multiple: true

      - name: Publish nightly release
        uses: softprops/action-gh-release@v2
        with:
          tag_name: main
          name: "Nightly"
          prerelease: true
          generate_release_notes: false
          files: release-assets/*
```

- [ ] **Step 5: Add `stable-release` job**

```yaml
  stable-release:
    needs: [check-release, build]
    runs-on: ubuntu-latest
    # Only run when a release version was detected
    if: needs.check-release.outputs.version != ''
    steps:
      - uses: actions/checkout@v5
        with:
          fetch-depth: 0
          token: ${{ secrets.GITHUB_TOKEN }}

      - name: Configure git
        run: |
          git config user.name "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"

      - name: Merge main into release branch and tag
        run: |
          VERSION="${{ needs.check-release.outputs.version }}"
          git fetch origin
          git checkout -B release origin/main
          git push origin release --force
          git tag "$VERSION"
          git push origin "$VERSION"

      - name: Download artifacts
        uses: actions/download-artifact@v5
        with:
          path: release-assets
          merge-multiple: true

      - name: Publish stable release
        uses: softprops/action-gh-release@v2
        with:
          tag_name: ${{ needs.check-release.outputs.version }}
          name: ${{ needs.check-release.outputs.version }}
          prerelease: false
          generate_release_notes: true
          files: release-assets/*
```

- [ ] **Step 6: Verify the final `build.yml` is clean**

After completing Steps 1–5, confirm:
- No references to the old `tag` workflow_dispatch input remain
- No references to `tags: ['v*']` remain in the `on:` block
- The old single `release:` job is fully replaced by `publish-nightly` + `stable-release`

- [ ] **Step 7: Commit**

```bash
git add .github/workflows/build.yml
git commit -m "ci: add semver stable release via commit message trigger and workflow_dispatch"
```

---

## Out of Scope (deferred)

- `README.md` install section — already updated separately before this plan was written; no changes needed here.

---

## Task 6: Final verification

- [ ] **Step 1: Run full test suite**

```bash
just test
```
Expected: all tests pass.

- [ ] **Step 2: Verify help commands**

```bash
./bin/shard --help
./bin/shard install --help
./bin/shard install --ai-help
./bin/shard init --help
./bin/shard init --ai-help
```

Each should print its respective embedded doc without error.

- [ ] **Step 3: Verify `shard init` no longer prints MCP config**

```bash
echo "n" | ./bin/shard init
```
Expected: creates `.shards/`, confirms workspace ready, mentions `shard install` for MCP setup. No MCP JSON block printed.

- [ ] **Step 4: Verify `shard install` writes tool configs**

```bash
mkdir -p .cursor .vscode
echo "n" | ./bin/shard install
ls opencode.json .mcp.json CLAUDE.md .cursor/mcp.json .cursorrules .vscode/
```
Expected: all files present, summary printed.

- [ ] **Step 5: Final commit if any fixes needed, then done**

```bash
git add -A
git commit -m "fix: post-integration cleanup"
```
