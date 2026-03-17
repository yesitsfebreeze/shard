# Agent Setup

This file tells you how to install the shard system for your AI tool. Read this, then follow the instructions for your tool.

## Prerequisites

1. Build the shard binary: `just build` (requires [Odin](https://odin-lang.org/) and [just](https://github.com/casey/just))
2. Initialize the workspace: `./shard init` (creates `.shards/`, keychain, config)
3. The MCP server command is: `./shard mcp` (it auto-starts the daemon)

## What Each Tool Needs

Every tool needs two things:
1. **Instructions file** — tells the agent how to work on this codebase
2. **MCP config** — tells the tool how to start the shard MCP server

The instructions live at `.agent/instructions.md`. The MCP config lives at `.agent/mcp.json`.

---

## OpenCode

Create `opencode.json` in the project root:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    "shard": {
      "type": "local",
      "command": ["./shard", "mcp"],
      "enabled": true
    }
  }
}
```

Create `.opencode/agents/` with a single agent file. The agent is defined in `.agent/agents/shard.md`:

- `shard.md` — single agent handling development, review, knowledge query, and knowledge filing

Create an OpenCode agent file that wraps the definition:

```
---
description: Single agent with full access to codebase and shard knowledge base.
mode: primary
tools:
  shard_*: true
  write: true
  edit: true
  bash: true
  read: true
  glob: true
  grep: true
---

Read `.agent/agents/shard.md` for role definition.
Read `.agent/instructions.md` for project rules and shard workflow.
```

OpenCode also reads `CLAUDE.md` at the project root automatically. Create it as a symlink:

```bash
ln -sf .agent/instructions.md CLAUDE.md
```

---

## Claude Code (claude-code, claude CLI)

Claude Code reads `CLAUDE.md` at the project root. Create it as a symlink:

```bash
ln -sf .agent/instructions.md CLAUDE.md
```

For MCP, create `.mcp.json` in the project root:

```json
{
  "mcpServers": {
    "shard": {
      "command": "./shard",
      "args": ["mcp"]
    }
  }
}
```

---

## GitHub Copilot

Copilot reads `.github/copilot-instructions.md`. Create it as a symlink:

```bash
mkdir -p .github
ln -sf ../.agent/instructions.md .github/copilot-instructions.md
```

For MCP, Copilot uses VS Code's MCP settings. Add to `.vscode/settings.json`:

```json
{
  "github.copilot.chat.codeGeneration.instructions": [
    { "file": ".agent/instructions.md" }
  ],
  "mcp": {
    "servers": {
      "shard": {
        "command": "./shard",
        "args": ["mcp"]
      }
    }
  }
}
```

---

## Cursor

Cursor reads `.cursorrules` at the project root. Create it as a symlink:

```bash
ln -sf .agent/instructions.md .cursorrules
```

For MCP, create `.cursor/mcp.json`:

```json
{
  "mcpServers": {
    "shard": {
      "command": "./shard",
      "args": ["mcp"]
    }
  }
}
```

---

## Windsurf

Windsurf reads `.windsurfrules` at the project root. Create it as a symlink:

```bash
ln -sf .agent/instructions.md .windsurfrules
```

For MCP, create `.codeium/windsurf/mcp_config.json`:

```json
{
  "mcpServers": {
    "shard": {
      "command": "./shard",
      "args": ["mcp"]
    }
  }
}
```

---

## Any Other Tool

If your tool reads a specific instructions file, symlink it to `.agent/instructions.md`:

```bash
ln -sf .agent/instructions.md <your-tools-instructions-file>
```

If your tool supports MCP, configure it to run `./shard mcp` as the MCP server command. The server communicates via JSON-RPC 2.0 over stdio.

If your tool does not support MCP, pipe YAML frontmatter messages through the CLI:

```bash
echo '---
op: registry
---' | ./shard connect
```

---

## Quick Install (all tools)

```bash
# Symlinks for instruction files
ln -sf .agent/instructions.md CLAUDE.md
ln -sf .agent/instructions.md .cursorrules
ln -sf .agent/instructions.md .windsurfrules
mkdir -p .github
ln -sf ../.agent/instructions.md .github/copilot-instructions.md
```

The MCP config files are tool-specific and cannot be symlinked — create them per the instructions above.

---

## Staying Up to Date

The `.agent/` directory is the single source of truth for agent instructions. When the shard project updates (new ops, workflow changes, new tools), the `.agent/` directory is updated too.

**For shard's own repo:** `git pull` updates everything. Symlinks point to `.agent/`, so all tools see the latest.

**For projects using shard as a tool:** Install the latest `.agent/` directory from the shard repo:

```bash
# Clone or update the agent configs from the shard repo
curl -sL https://github.com/yesitsfebreeze/shard/archive/main.tar.gz | tar xz --strip-components=1 "shard-main/.agent"
```

Or add shard as a git submodule:

```bash
git submodule add https://github.com/yesitsfebreeze/shard.git .shard-upstream
ln -sf .shard-upstream/.agent .agent
```

Then run `just install` (or create the symlinks manually) to wire your AI tools to the updated instructions.

## After Setup

Once linked, your agent should:

1. Read `.agent/instructions.md` (or the symlink your tool provides)
2. Connect to the shard MCP server
3. Follow the startup workflow:
   - Call `shard_digest` first (compressed knowledge base overview, ~500 tokens)
   - Check events for recent changes
   - Use `shard_query(budget: 2000)` for targeted context loading
   - Read project rules, plan work
