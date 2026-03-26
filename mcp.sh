#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
LOCAL_BIN="$DIR/.shards/bin/shard"
HOME_DIR="${HOME:-}"

if [ -z "$HOME_DIR" ]; then
  echo "mcp.sh: HOME is not set" >&2
  exit 1
fi

USER_BIN_DIR="$HOME_DIR/.shards/bin"
USER_BIN="$USER_BIN_DIR/shard"

mkdir -p "$USER_BIN_DIR"

if [ -f "$LOCAL_BIN" ] && { [ ! -f "$USER_BIN" ] || [ "$LOCAL_BIN" -nt "$USER_BIN" ]; }; then
  cp "$LOCAL_BIN" "$USER_BIN"
  chmod 755 "$USER_BIN"
fi

if [ ! -x "$USER_BIN" ]; then
  echo "mcp.sh: shard binary not found at $USER_BIN" >&2
  exit 1
fi

exec "$USER_BIN" --mcp
