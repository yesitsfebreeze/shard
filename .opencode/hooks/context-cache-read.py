#!/usr/bin/env python3
import base64
import json
import os
import subprocess
import sys


_REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SHARD_BIN = os.environ.get(
    "SHARD_BIN", os.path.join(_REPO_ROOT, ".shards", "bin", "shard")
)
CACHE_KEY = os.environ.get("SHARD_CONTEXT_CACHE_KEY", "v3_context_cache")


def main() -> int:
    req = {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "tools/call",
        "params": {
            "name": "cache_get",
            "arguments": {"key": CACHE_KEY},
        },
    }
    proc = subprocess.run(
        [SHARD_BIN, "--mcp"],
        input=(json.dumps(req, separators=(",", ":")) + "\n").encode(),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=dict(os.environ),
    )
    if proc.returncode != 0:
        sys.stderr.write(proc.stderr.decode(errors="replace"))
        return proc.returncode

    lines = [
        line.strip()
        for line in proc.stdout.decode(errors="replace").splitlines()
        if line.strip()
    ]
    if not lines:
        return 1
    msg = json.loads(lines[-1])
    if "error" in msg:
        return 1

    content = msg.get("result", {}).get("content", [])
    text = ""
    if content and isinstance(content, list) and isinstance(content[0], dict):
        text = content[0].get("text", "")

    if text == "cache miss":
        return 0

    if text == "not found":
        return 0

    if text.startswith("b64:"):
        try:
            text = base64.b64decode(text[4:]).decode("utf-8", errors="replace")
        except Exception:
            return 1

    sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
