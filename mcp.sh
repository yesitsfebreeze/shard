#!/bin/bash
DIR="$(cd "$(dirname "$0")" && pwd)"
docker compose -f "$DIR/docker-compose.yml" rm -sf shard >/dev/null 2>&1
exec docker compose -f "$DIR/docker-compose.yml" run --rm -i --service-ports shard --mcp
