#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
python3 "$SCRIPT_DIR/shard-call.py" compact '{}' >/tmp/v3-shard-compact.log 2>/tmp/v3-shard-compact.err || true
python3 "$SCRIPT_DIR/context-cache-refresh.py" >/tmp/v3-shard-build-context.log 2>/tmp/v3-shard-build-context.err || true
