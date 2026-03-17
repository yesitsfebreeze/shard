# shard daemon — AI Agent Reference

## What It Does

The daemon is a central shard process that manages all shards in-memory. It:
- Listens on IPC endpoint 'shard-daemon'
- Auto-discovers `.shard` files in `.shards/` on startup
- Loads shard blobs on demand, evicts idle shards after 5 minutes
- Persists registry (shard list + metadata) in its own blob's manifest

## Starting

```bash
shard daemon &
# Or with custom data path:
shard daemon --data .shards/my-daemon.shard
```

The daemon is also started automatically by `shard mcp` if not already running.

## Daemon Operations (no key required)

These ops target 'shard-daemon' via IPC:

### registry — List all shards

```json
{
  "op": "registry"
}
```

Response:
```json
{
  "status": "ok",
  "registry": [
    {
      "name": "notes",
      "data_path": ".shards/notes.shard",
      "thought_count": 5,
      "catalog": {
        "name": "notes",
        "purpose": "meeting notes",
        "tags": ["work", "notes"]
      },
      "gate_desc": ["meeting notes", "project docs"],
      "gate_positive": ["planning", "architecture"],
      "gate_negative": ["spam", "off-topic"]
    }
  ]
}
```

### registry with query — Filter by keyword

```json
{
  "op": "registry",
  "query": "notes"
}
```

### discover — Re-scan .shards/

```json
{
  "op": "discover"
}
```

### traverse — Gate filtering with ranking

Evaluates all shards' gates against a query, returns candidates ranked by relevance. Uses vector embeddings if configured (LLM_URL + EMBED_MODEL), otherwise keyword scoring.

```json
{
  "op": "traverse",
  "query": "encryption authentication",
  "max_branches": 5
}
```

### digest — Compressed knowledge base overview

```json
{
  "op": "digest",
  "key": "<64-hex master key>"
}
```

Returns: markdown TOC with shard names, purposes, thought counts, thought descriptions (~500 tokens). Use as your first call to orient.

## Routing Ops Through Daemon

To target a specific shard, include `name: <shard>`:

```json
{
  "op": "search",
  "name": "notes",
  "key": "<64-hex master key>",
  "query": "meeting"
}
```

All standard shard ops work this way. See `shard --ai-help` for the full operation reference.