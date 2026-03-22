#!/bin/bash
# MCP server wrapper — runs shard --mcp inside Docker with stdio piped through
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
exec docker run --rm -i \
  -v "$SCRIPT_DIR/.temp:/data" \
  -e HOME=/root \
  -e SHARD_KEY="000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f" \
  --entrypoint /bin/bash \
  shard-int -c '
    mkdir -p /root/.shards
    cp /data/_config.jsonc /root/.shards/_config.jsonc 2>/dev/null
    /app/shard --mcp
  '
