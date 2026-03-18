# Shard MCP Server via HTTP

Runs the Shard MCP server exposed on port 8080 via HTTP/JSON-RPC.

## Quick Start

```bash
# Build and run
docker compose up -d

# Test it
curl -X POST http://localhost:8080/mcp \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
```

## Endpoints

- `POST /mcp` - JSON-RPC 2.0 MCP requests
- `GET /health` - Health check

## MCP Tools Available

- `shard_discover` - List/query shards
- `shard_query` - Search thoughts
- `shard_read` - Read a thought
- `shard_write` - Write a thought
- `shard_delete` - Delete a thought
- `shard_remember` - Create a new shard
- `shard_events` - Read/emit events
- `shard_stale` - Find stale thoughts
- `shard_feedback` - Endorse/flag thoughts
- `shard_fleet` - Batch operations
- `shard_compact_*` - Compaction tools
- `shard_cache_*` - Context cache

## Configuration

Data persists in `/root/.shards` (Docker volume). To use encryption, mount a keychain file:

```yaml
services:
  shard:
    volumes:
      - ./keychain:/root/.shards/keychain:ro
```

## MCP Client Connection

Example OpenCode config:
```json
{
  "mcp": {
    "shard": {
      "type": "http",
      "url": "http://localhost:8080/mcp"
    }
  }
}
```
