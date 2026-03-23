# CLAUDE.md

Run `./shard --help --ai` for full documentation. Everything is in the binary.

## Quick Start

```bash
docker build -f scripts/Dockerfile -t shard-int .
./shard --mcp          # MCP server
./shard --help --ai    # Full AI documentation
```

## Rules

Single file `shard.odin`. No comments. No dead code. Linux only. Docker build.
