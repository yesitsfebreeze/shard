#!/usr/bin/env python3
import json
import os
import subprocess
import sys


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: shard-call.py <tool_name> [json_arguments]", file=sys.stderr)
        return 2

    tool_name = sys.argv[1]
    raw_args = sys.argv[2] if len(sys.argv) >= 3 else "{}"
    try:
        tool_args = json.loads(raw_args)
        if not isinstance(tool_args, dict):
            raise ValueError("arguments must be a JSON object")
    except Exception as exc:
        print(f"invalid args JSON: {exc}", file=sys.stderr)
        return 2

    repo_root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
    shard_bin = os.environ.get(
        "SHARD_BIN", os.path.join(repo_root, ".shards", "bin", "shard")
    )
    req = {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "tools/call",
        "params": {
            "name": tool_name,
            "arguments": tool_args,
        },
    }

    proc = subprocess.run(
        [shard_bin, "--mcp"],
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
        print("no response", file=sys.stderr)
        return 1
    msg = json.loads(lines[-1])
    if "error" in msg:
        print(json.dumps(msg["error"], ensure_ascii=True), file=sys.stderr)
        return 1
    content = msg.get("result", {}).get("content", [])
    if content and isinstance(content, list) and isinstance(content[0], dict):
        text = content[0].get("text", "")
        if text:
            print(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
