# CLAUDE.md

Project knowledge lives in the shards. Use the shard MCP tools to query it.

## Quick Reference

- `shard_ask` — ask anything about this project
- `shard_query` — keyword search
- `fleet_ask` — ask all shards
- `shard_list` — see registered shards
- `shard_write` — add knowledge

## Build

```bash
docker build -f scripts/Dockerfile.integration -t shard-int .
docker run --rm shard-int /app/test.sh          # unit tests
docker run --rm -v "$(pwd)/.temp:/data" shard-int  # integration tests
```

## Rules

- Single file: `shard.odin`. No comments. No dead code.
- Linux only. Docker build.
- Delete replaced functions immediately.
