#!/usr/bin/env python3
import http.server
import json
import os
import subprocess
import threading
import time

PORT = int(os.environ.get("PORT", 8080))
SHARD_KEY = os.environ.get("SHARD_KEY", "test-key-do-not-use-in-prod")
DATA_DIR = "/data"

_shard_proc: subprocess.Popen | None = None
_daemon_proc: subprocess.Popen | None = None
_shard_lock = threading.Lock()

INITIALIZE_MSG = json.dumps(
    {
        "jsonrpc": "2.0",
        "id": 0,
        "method": "initialize",
        "params": {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "http-bridge", "version": "1"},
        },
    }
)

INITIALIZED_NOTIFICATION = json.dumps(
    {
        "jsonrpc": "2.0",
        "method": "notifications/initialized",
        "params": {},
    }
)


def shard_env() -> dict:
    env = os.environ.copy()
    env["SHARD_KEY"] = SHARD_KEY
    return env


def start_daemon():
    global _daemon_proc
    print("[shard] starting daemon")
    _daemon_proc = subprocess.Popen(
        ["shard", "daemon"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        cwd=DATA_DIR,
        env=shard_env(),
    )
    # Give the daemon time to create its IPC socket
    time.sleep(1)
    print(f"[shard] daemon pid={_daemon_proc.pid}")


def read_json_line(proc: subprocess.Popen) -> bytes:
    """Read stdout lines, skipping [INFO] log lines, return first JSON line."""
    assert proc.stdout
    while True:
        line = proc.stdout.readline()
        if not line:
            return b""
        stripped = line.strip()
        if stripped.startswith(b"{"):
            return stripped


def start_shard_proc() -> subprocess.Popen:
    print("[shard] starting shard mcp process")
    proc = subprocess.Popen(
        ["shard", "mcp"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        cwd=DATA_DIR,
        env=shard_env(),
    )
    assert proc.stdin

    # MCP handshake
    proc.stdin.write(INITIALIZE_MSG.encode() + b"\n")
    proc.stdin.flush()
    read_json_line(proc)  # consume initialize response

    proc.stdin.write(INITIALIZED_NOTIFICATION.encode() + b"\n")
    proc.stdin.flush()

    print(f"[shard] mcp pid={proc.pid} ready")
    return proc


def get_shard_proc() -> subprocess.Popen:
    global _shard_proc
    if _shard_proc is None or _shard_proc.poll() is not None:
        _shard_proc = start_shard_proc()
    return _shard_proc


def call_shard(payload: bytes) -> bytes:
    with _shard_lock:
        try:
            proc = get_shard_proc()
            assert proc.stdin
            proc.stdin.write(payload + b"\n")
            proc.stdin.flush()
            line = read_json_line(proc)
            if not line:
                assert proc.stderr
                stderr = proc.stderr.read()
                _shard_proc = None
                return json.dumps(
                    {
                        "jsonrpc": "2.0",
                        "error": {
                            "code": -32603,
                            "message": f"shard mcp died: {stderr.decode(errors='replace')}",
                        },
                        "id": None,
                    }
                ).encode()
            return line
        except Exception as e:
            return json.dumps(
                {
                    "jsonrpc": "2.0",
                    "error": {"code": -32603, "message": str(e)},
                    "id": None,
                }
            ).encode()


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):  # noqa: A002
        print(format % args)

    def send_json(self, status: int, body: bytes):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/health":
            self.send_json(200, b'{"status":"ok"}')
        else:
            self.send_json(404, b'{"error":"not found"}')

    def do_POST(self):
        if self.path != "/mcp":
            self.send_json(404, b'{"error":"not found"}')
            return

        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)

        try:
            json.loads(body)
        except json.JSONDecodeError as e:
            self.send_json(
                400,
                json.dumps(
                    {
                        "jsonrpc": "2.0",
                        "error": {"code": -32700, "message": f"Parse error: {e}"},
                        "id": None,
                    }
                ).encode(),
            )
            return

        self.send_json(200, call_shard(body))


if __name__ == "__main__":
    start_daemon()
    get_shard_proc()
    server = http.server.HTTPServer(("0.0.0.0", PORT), Handler)
    print(f"shard-http listening on port {PORT}")
    server.serve_forever()
