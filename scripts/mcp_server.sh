#!/bin/bash
export MSYS_NO_PATHCONV=1
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
exec docker run --rm -i \
  --init \
  -v "$SCRIPT_DIR/.temp:/data" \
  -e HOME=/root \
  -e SHARD_KEY="000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f" \
  --entrypoint /bin/sh \
  shard-int -c 'mkdir -p /root/.shards; cp /data/_config.jsonc /root/.shards/_config.jsonc 2>/dev/null; exec /app/shard --mcp'
