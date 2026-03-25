#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
python3 "$SCRIPT_DIR/context-cache-refresh.py" >/tmp/v3-shard-build-context.log 2>/tmp/v3-shard-build-context.err || true
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
python3 "$SCRIPT_DIR/shard-call.py" shard_write "{\"description\":\"v3_session_started\",\"content\":\"OpenCode session started for $REPO_ROOT\",\"agent\":\"opencode\"}" >/tmp/v3-shard-session.log 2>/tmp/v3-shard-session.err || true
