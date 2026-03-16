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

All agent configuration lives in `.agent/`. To set up your AI tool:

```bash
just install            # creates symlinks for all supported tools
```

Or read `.agent/setup.md` for per-tool instructions (OpenCode, Copilot, Cursor, Windsurf, Claude Code, or any MCP-compatible tool).

The agent instructions are at `.agent/instructions.md`. The MCP server (`shard mcp`) gives agents direct access to the shared knowledge base.
