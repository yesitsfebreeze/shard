#!/bin/bash
DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$DIR/.shards/bin/shard" --mcp
