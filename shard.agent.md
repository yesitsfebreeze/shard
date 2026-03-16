# Shard — AI Agent Guide

You interact with Shard through two interfaces:

- **MCP tools** — tool calls like `shard_query`, `shard_write`, etc. This is your primary interface for reading and writing thoughts.
- **`shard` CLI** — for storage operations (bulk export, format migration, direct IPC). Run `shard --ai-help` for the complete operation reference.

## Session Start

At the beginning of every session, read the help chain to understand the current state of the system:

```bash
shard --ai-help        # full structured reference: ops, message format, workflow, encryption
shard help             # overview of all commands
shard help shard       # detailed operation reference with examples
shard help mcp         # MCP server specifics
```

`shard --ai-help` is the authoritative reference. It contains everything you need to operate shards programmatically. The help output is always current — trust it over any cached documentation.

## Key Concepts

- **Shard**: An encrypted `.shard` file containing thoughts. Has a name, purpose, and topic gates.
- **Thought**: Encrypted unit with a `description` (searchable) and `content` (body).
- **Catalog**: Plaintext identity card (name, purpose, tags, related). No key needed.
- **Gates**: Plaintext routing signals — positive (accepts), negative (rejects). Used to route thoughts to the right shard.
- **Daemon**: Central process managing all shards. Both MCP and CLI talk to it.

## MCP Tools Quick Reference

All tools that target a shard take a `shard` argument. Tools marked (key) require a `key` argument (64-char hex master key).

| Tool | Key | What it does |
|------|-----|-------------|
| `shard_discover` | | List/filter shards from registry |
| `shard_discover_refresh` | | Re-scan `.shards/` and refresh registry |
| `shard_remember` | | Create a new shard with catalog and gates |
| `shard_catalog` | | Read a shard's catalog |
| `shard_gates` | | Read a shard's routing gates |
| `shard_list` | | List all thought IDs |
| `shard_status` | | Health check |
| `shard_query` | key | **Main search.** Vector-routes to shards, keyword-searches thoughts, follows cross-links with `depth` |
| `shard_read` | key | Decrypt and read a thought by ID |
| `shard_write` | key | Write a new encrypted thought |
| `shard_update` | key | Update a thought's description/content |
| `shard_delete` | key | Delete a thought by ID |
| `shard_dump` | key | Export all thoughts as markdown |

For the full protocol, message format, and IPC details, run `shard --ai-help`.
