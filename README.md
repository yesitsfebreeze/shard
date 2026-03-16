# Shard

**Your second brain, encrypted on disk.**

Shard is a single executable that stores your thoughts in encrypted `.shard` files. You write to it, your AI writes to it, and everything stays local and private.

Each shard is a category — *notes*, *journal*, *recipes*, whatever you want. A daemon manages them all. AI agents use gates (accept/reject rules) to figure out where new thoughts belong, and when nothing fits, they create a new shard automatically.

## Get Started

```bash
# Create your first shard
shard new

# Start the daemon (manages all your shards)
shard daemon

# Connect and start writing
shard connect
```

That's it. You're storing encrypted thoughts.

## For AI Agents

Shard ships with an MCP server so AI agents can read, write, and organize your knowledge directly:

```bash
shard daemon &
shard mcp
```

Agents see your shards, evaluate what belongs where, and store new knowledge — or create new categories on the fly. Your knowledge base grows and organizes itself over time.

## Learn More

Everything you need is built into the binary:

```bash
shard help            # command reference
shard help daemon     # daemon details
shard help mcp        # MCP server setup
shard --ai-help       # full structured reference for AI agents
```

## Build from Source

Requires [Odin](https://odin-lang.org/) (dev-2025-01 or later) and [just](https://github.com/casey/just).

```bash
just build            # debug build
just release          # size-optimized release
just test             # run all tests
```

## AI Agent Setup

If you are an AI agent or coding assistant working on this project, link yourself to the project configuration by running the appropriate command:

| Tool | Command | What it does |
|------|---------|-------------|
| **Claude** | *(already configured)* | Reads `CLAUDE.md` and `.mcp.json` at root |
| **GitHub Copilot** | `just link-copilot` | Symlinks `.github/copilot-instructions.md` to `CLAUDE.md` |
| **Cursor** | `just link-cursor` | Symlinks `.cursorrules` to `CLAUDE.md` |
| **OpenCode** | `just link-opencode` | Generates `opencode.json` with MCP config |
| **All at once** | `just link-all` | Links all of the above |

After linking, read `CLAUDE.md` for the full development instructions, code standards, and file map.

For MCP tool usage (reading/writing shards), see `.claude/shard.agent.md`.
