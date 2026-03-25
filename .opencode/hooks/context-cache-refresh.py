#!/usr/bin/env python3
import base64
import json
import os
import subprocess


_REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SHARD_BIN = os.environ.get(
    "SHARD_BIN", os.path.join(_REPO_ROOT, ".shards", "bin", "shard")
)
CACHE_KEY = os.environ.get("SHARD_CONTEXT_CACHE_KEY", "v3_context_cache")
TASK = os.environ.get(
    "SHARD_CONTEXT_TASK", f"Maintain working context for {_REPO_ROOT}"
)


def call_tool(name: str, arguments: dict) -> str:
    req = {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "tools/call",
        "params": {"name": name, "arguments": arguments},
    }
    proc = subprocess.run(
        [SHARD_BIN, "--mcp"],
        input=(json.dumps(req, separators=(",", ":")) + "\n").encode(),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=dict(os.environ),
    )
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.decode(errors="replace"))

    lines = [
        line.strip()
        for line in proc.stdout.decode(errors="replace").splitlines()
        if line.strip()
    ]
    if not lines:
        raise RuntimeError("no response from shard")
    msg = json.loads(lines[-1])
    if "error" in msg:
        raise RuntimeError(json.dumps(msg["error"], ensure_ascii=True))
    content = msg.get("result", {}).get("content", [])
    if content and isinstance(content, list) and isinstance(content[0], dict):
        return content[0].get("text", "")
    return ""


def main() -> int:
    context = call_tool("build_context", {"task": TASK})
    encoded = "b64:" + base64.b64encode(context.encode("utf-8")).decode("ascii")
    call_tool(
        "cache_set",
        {
            "key": CACHE_KEY,
            "value": encoded,
            "author": "opencode",
        },
    )
    print(f"cached {len(context)} chars to {CACHE_KEY}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
