# shard mcp — AI Agent Reference

## What It Does

Starts a Model Context Protocol server on stdio (JSON-RPC 2.0). The MCP server connects to the daemon via IPC internally. If the daemon is not already running, it starts automatically as a background process.

## Starting

```bash
shard mcp
```

## Protocol

- `initialize` — Server info + capabilities
- `notifications/initialized` — (no response)
- `tools/list` — List available tools
- `tools/call` — Execute a tool

## Available Tools

| Tool | Key? | Description |
|------|------|-------------|
| `shard_digest` | Auto | **Start here.** Compressed overview of entire knowledge base — names, purposes, thought counts, descriptions. ~500 tokens. Optional `query` to filter. |
| `shard_query` | Yes | **The main search tool.** Vector-routes to relevant shards, keyword-searches for matching thoughts. `shard` = direct lookup. `depth` > 0 = cross-shard BFS. Supports `budget` parameter. |
| `shard_access` | Auto | Describe what you need, get the best matching shard's content. Supports `budget` parameter. |
| `shard_discover` | No | List/filter shards from the registry |
| `shard_discover_refresh` | No | Re-scan .shards/ directory and refresh registry |
| `shard_remember` | No | Create a new shard with catalog and gates in one shot |
| `shard_catalog` | No | Read a shard's catalog |
| `shard_gates` | No | Read a shard's routing gates |
| `shard_list` | No | List all thought IDs |
| `shard_status` | No | Health check (name, thoughts, uptime) |
| `shard_read` | Yes | Decrypt and read a thought by ID |
| `shard_write` | Yes | Write a new encrypted thought |
| `shard_update` | Yes | Update a thought's description/content |
| `shard_delete` | Yes | Delete a thought by ID |
| `shard_dump` | Yes | Export all thoughts as markdown (use sparingly — prefer digest + budget query) |
| `shard_consumption_log` | No | View recent agent activity log |

## Recommended Pattern

1. `shard_digest()` — get the map (~500 tokens)
2. `shard_query(query="...", budget=2000)` — get targeted context with budget cap
3. `shard_read(shard="...", id="...")` — drill into a specific truncated result (only if needed)

## Cross-Shard Search

- `shard_query(query="...", budget=2000)` — searches all shards, budget-capped
- `shard_query(query="...", shard="notes")` — direct single-shard lookup (fastest)
- `shard_query(query="...", depth=2)` — follows related-shard links and `[[wikilinks]]` in content (BFS graph traversal)

All tools that target a shard take a `shard` argument (the shard name). Tools marked "Key" require a `key` argument. Tools marked "Auto" auto-resolve keys from the keychain.