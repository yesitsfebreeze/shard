#!/bin/sh
set -e

PORT="${PORT:-8080}"

echo "[shard] starting daemon..."
shard daemon &
DAEMON_PID=$!

# Wait for daemon IPC socket to be ready
sleep 1

echo "[shard] daemon pid=$DAEMON_PID"
echo "[shard] starting HTTP MCP server on 0.0.0.0:${PORT}..."

# --http-host 0.0.0.0 binds on all interfaces (required inside a container)
# The config default is 127.0.0.1 which would be unreachable from outside
exec shard mcp --http "${PORT}" --http-host 0.0.0.0
