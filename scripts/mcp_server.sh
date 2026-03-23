#!/bin/bash
export MSYS_NO_PATHCONV=1
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
docker rm -f shard >/dev/null 2>&1
exec docker run --rm -i \
  --name shard \
  --init \
  -p 8080:8080 \
  -v "$SCRIPT_DIR/.temp:/data" \
  -v "$SCRIPT_DIR/app/dist:/srv:ro" \
  -e HOME=/root \
  -e SHARD_KEY="000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f" \
  -e SHARD_DATA=/data \
  --entrypoint /bin/sh \
  shard-int -c '
    mkdir -p /root/.shards
    ln -sf /data/index /root/.shards/index
    exec /app/shard --mcp
  '
