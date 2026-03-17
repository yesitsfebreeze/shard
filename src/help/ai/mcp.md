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
| `shard_discover` | No | **Start here.** Full table of contents — names, purposes, thought counts, descriptions. Pass `query` to filter by topic. Pass `shard` for a specific shard's info card. Pass `refresh:true` to re-scan disk first. |
| `shard_query` | Yes | **The main search tool.** Keyword+vector routes to relevant shards. `shard` = direct lookup. `depth` > 0 = cross-shard BFS. `budget` caps content chars returned. |
| `shard_read` | Yes | Read a specific thought by ID. `chain:true` returns the full revision history. |
| `shard_write` | Yes | Write a new thought or update an existing one. Provide `revises` to create a revision link. |
| `shard_delete` | Yes | Delete a thought by ID. |
| `shard_dump` | Yes | Export all thoughts as a markdown document (use sparingly — prefer `shard_query` with `budget`). |
| `shard_remember` | No | Create a new shard with catalog and gates in one shot. |
| `shard_events` | No | Read pending events for a shard, or emit an event to related shards. |
| `shard_stale` | Yes | Find thoughts that need review, sorted by staleness. |
| `shard_feedback` | Yes | Endorse or flag a thought to adjust its relevance score. |
| `shard_fleet` | No | Execute multiple shard operations in parallel across shards. |
| `shard_compact_suggest` | Yes | Analyze a shard and return compaction proposals (chains, duplicates, stale). Read-only. |
| `shard_compact` | Yes | Execute compaction on specific thought IDs from compact_suggest results. |
| `shard_compact_apply` | Yes | One-shot: analyze and compact a shard automatically. |
| `shard_consumption_log` | No | View recent agent activity log. Filter by `shard` or `agent`. `limit` caps records returned (default 50). |

## Recommended Agent Cycle

Follow this 6-step cycle for consistent, observable behavior:

1. **DISCOVER** — `shard_discover()` — get the full table of contents. Check `needs_attention: true` entries — these are shards with unprocessed content and no recent agent visits.
2. **EVALUATE** — inspect gates and catalog of candidate shards to decide which are relevant to your task.
3. **CONSUME** — `shard_query(query="...", budget=2000)` or `shard_read(shard="...", id="...")` — retrieve content. Use `budget` to cap tokens.
4. **ASSESS** — evaluate quality and freshness. Use `shard_stale(shard="...")` for thoughts that may be outdated.
5. **CONTRIBUTE** — `shard_write` new thoughts, `shard_feedback` to endorse/flag existing ones, `shard_compact_apply` to compact revision chains.
6. **NOTIFY** — `shard_events(source="...", event_type="knowledge_changed")` — the daemon auto-notifies related shards on write, but explicit events help coordinate with other agents.

## Cross-Shard Search

- `shard_query(query="...", budget=2000)` — searches all shards, budget-capped
- `shard_query(query="...", shard="notes")` — direct single-shard lookup (fastest)
- `shard_query(query="...", depth=2)` — follows related-shard links and `[[wikilinks]]` in content (BFS graph traversal)

All tools that target a shard take a `shard` argument (the shard name). Tools marked "Key?" require a `key` argument (or set `SHARD_KEY` env var, or add to `.shards/keychain`).