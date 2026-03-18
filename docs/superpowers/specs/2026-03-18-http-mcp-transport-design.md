# HTTP MCP Transport — Design Spec

**Date:** 2026-03-18  
**Status:** Approved  
**Author:** claude-sonnet-4-6

---

## Overview

Add an HTTP transport mode to the `shard mcp` command so that it can act as a
persistent server reachable by both curl scripts and AI hosts that support the
MCP HTTP+SSE transport spec. The existing stdio transport and all daemon IPC
logic remain unchanged.

**Invocation:**
```
shard mcp              # existing stdio mode (unchanged)
shard mcp --http       # HTTP mode, port from config (default 3000)
shard mcp --http 8080  # HTTP mode, explicit port override
```

---

## Goals

- Serve MCP JSON-RPC 2.0 over HTTP so AI hosts (Claude Code, Cursor, etc.) can
  connect via the standard MCP HTTP+SSE transport.
- Serve a stateless `POST /rpc` endpoint that returns JSON synchronously, so
  shell scripts and CI pipelines can `curl` any shard tool directly.
- Be multithreaded from day one: one OS thread per accepted connection.
- Remain a single self-contained binary — no external dependencies, no runtime.
- Default to localhost-only binding for safety.

---

## Architecture

```
┌─────────────────────────────────┐
│  shard mcp --http [port]        │
│  run_mcp_http() in mcp_http.odin│
└────────────┬────────────────────┘
             │ TCP :port (HTTP/1.1)
    ┌────────▼────────────────────┐
    │   HTTP server               │
    │  POST /rpc     (stateless)  │
    │  GET  /sse     (SSE stream) │
    │  POST /message?sessionId=X  │
    └────────┬────────────────────┘
             │ reuses _process_jsonrpc() and _daemon_call() unchanged
    ┌────────▼────────────────────┐
    │   shard daemon (IPC)        │
    └─────────────────────────────┘
```

The key insight: `_process_jsonrpc(line: string) -> string` in `mcp.odin` is
already transport-agnostic. The HTTP server is purely a new transport shim over
the same logic.

---

## New Files

| File | Purpose |
|------|---------|
| `src/mcp_http.odin` | Entry point `run_mcp_http(port, host)`, session management, route dispatch, HTTP request parsing |
| `src/http_server_windows.odin` | TCP listen/accept/send/recv/close — Windows (mirrors `ipc_windows.odin`) |
| `src/http_server_posix.odin` | TCP listen/accept/send/recv/close — POSIX (mirrors `ipc_posix.odin`) |

## Modified Files

| File | Change |
|------|--------|
| `src/main.odin` | Parse `--http [port]` flag in `case "mcp":` branch; call `run_mcp_http` |
| `src/config.odin` | Add `http_port: int` and `http_host: string` fields to `Shard_Config` |
| `src/default.config` | Add `HTTP_PORT 3000` and `HTTP_HOST 127.0.0.1` with comments |

---

## HTTP Server Abstraction (`http_server_*.odin`)

Platform files expose a uniform interface following the exact style of
`ipc_windows.odin` / `ipc_posix.odin`:

```odin
HTTP_Listener :: struct { ... }
HTTP_Conn     :: struct { ... }

http_listen       :: proc(host: string, port: int) -> (HTTP_Listener, bool)
http_accept       :: proc(listener: ^HTTP_Listener) -> (HTTP_Conn, bool)
http_send         :: proc(conn: HTTP_Conn, data: []u8) -> bool
http_recv         :: proc(conn: HTTP_Conn, buf: []u8) -> (int, bool)
http_close_conn   :: proc(conn: HTTP_Conn)
http_close_listener :: proc(listener: ^HTTP_Listener)
```

Windows: `WSAStartup` + `bind`/`listen`/`accept` via Winsock (`ws2_32`).  
POSIX: standard `socket`/`bind`/`listen`/`accept` syscalls (same as IPC posix).

---

## Routes

| Method | Path | Behaviour |
|--------|------|-----------|
| `POST` | `/rpc` | Read body → `_process_jsonrpc()` → `200 OK` JSON. Stateless. |
| `GET` | `/sse` | Assign a crypto-random 128-bit session ID (32 lowercase hex chars via `crypto.rand_bytes`), register session, hold connection open, send SSE `endpoint` event, then send `: ping` keep-alive comments every 15s. |
| `POST` | `/message?sessionId=<id>` | Look up session → `_process_jsonrpc()` → if result is non-empty push as SSE `message` event (empty = notification, skip push) → return `202 Accepted`. The JSON-RPC response is delivered async over the SSE stream, **not** in the 202 body. |
| `*` | any other | `404 Not Found` |

### SSE Wire Format

```
HTTP/1.1 200 OK
Content-Type: text/event-stream
Cache-Control: no-cache
Connection: keep-alive

event: endpoint
data: /message?sessionId=abc123def456

: ping

event: message
data: {"jsonrpc":"2.0","id":1,"result":{...}}

```

### Plain curl Example

```bash
curl -X POST http://localhost:3000/rpc \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call",
       "params":{"name":"shard_discover","arguments":{}}}'
```

---

## HTTP Request Parser

Minimal hand-written parser in `mcp_http.odin` — only what the routes need:

```odin
HTTP_Request :: struct {
    method:         string,   // "GET" or "POST"
    path:           string,   // "/rpc", "/sse", "/message"
    query:          string,   // "sessionId=abc123"
    content_length: int,
    body:           string,
}
```

Parses:
- Request line: method, path+query
- `Content-Length` header
- Blank-line separator
- Body (read exactly `content_length` bytes)

No chunked encoding, no multipart, no TLS. Clean but not general-purpose.

---

## Threading Model

**One OS thread per accepted connection.** The accept loop (main thread) calls
`thread.run_with_data(_http_handle_conn, task)` for every connection. Each
thread owns its `HTTP_Conn` and exits when the connection closes.
`thread.run_with_data` auto-destroys the thread on exit — no join needed.

```odin
HTTP_Conn_Task :: struct {
    conn:    HTTP_Conn,
    store:   ^Session_Store,
    ctx:     runtime.Context,   // Odin context propagation
}
```

Each connection thread calls `free_all(context.temp_allocator)` after each
`_process_jsonrpc` call. This is required because `_process_jsonrpc` uses
`context.temp_allocator` for the JSON parse tree; without a periodic free,
long-lived SSE-holding threads would grow unbounded.

### Session Store

Shared across threads; guarded by a `sync.Mutex`:

```odin
Session_Store :: struct {
    mu:       sync.Mutex,
    sessions: map[string]^HTTP_Session,
}

HTTP_Session :: struct {
    id:    string,
    conn:  HTTP_Conn,
    alive: bool,
    mu:    sync.Mutex,   // guards writes to this session's conn
}
```

Locking protocol (two-level):
1. Acquire `store.mu` → look up session by ID → release `store.mu`
2. Acquire `session.mu` → write SSE event to `session.conn` → release `session.mu`

Store mutex is held only for the brief map lookup; session mutex guards the
actual I/O. This prevents a slow SSE write from blocking new session registrations.

### Daemon IPC — Mutex-Guarded

`shard mcp` (stdio) and `shard mcp --http` are mutually exclusive — only one
runs per process invocation. They do **not** share a process, so there is no
cross-mode conflict.

Within the HTTP mode, the shared `_daemon_conn` globals in `mcp.odin` gain a
`sync.Mutex` that lives in `mcp.odin` alongside them:

```odin
_daemon_mu:   sync.Mutex       // new — guards _daemon_conn and _daemon_connected
_daemon_conn: IPC_Conn         // existing
_daemon_connected: bool        // existing
```

`_daemon_call` acquires `_daemon_mu` for the full send+recv then releases it.
The stdio `run_mcp` path is single-threaded and never contends on this mutex —
the lock is a no-op cost in that mode. Calls are short-lived so contention in
HTTP mode is negligible.

---

## Error Handling

| Situation | Response |
|-----------|----------|
| TCP accept failure | log + retry loop continues |
| Client disconnects mid-request | close conn, thread exits |
| Malformed HTTP / missing Content-Length | `400 Bad Request` |
| Unknown route | `404 Not Found` |
| Unknown `sessionId` | `404 Not Found` |
| Daemon unreachable | `503 Service Unavailable` with JSON-RPC error body |
| Any internal error | `500 Internal Server Error` |

All error responses use consistent JSON body:
```json
{"error": "description of problem"}
```

No silent drops — every connection receives a valid HTTP response before closing
(except on TCP-level failures outside our control).

---

## Config

New fields in `Shard_Config`:

```odin
http_port: int    // default 3000
http_host: string // default "127.0.0.1"
```

New keys in `default.config`:

```
# HTTP MCP transport (shard mcp --http)
HTTP_PORT 3000
HTTP_HOST 127.0.0.1
```

`HTTP_HOST` defaults to loopback. To expose on the network: `HTTP_HOST 0.0.0.0`.
This is a deliberate safety default — the daemon holds decryption keys in memory.

CLI `--http [port]` overrides `HTTP_PORT` only. `HTTP_HOST` is config-only to
discourage accidental network exposure.

---

## Implementation Order

1. `http_server_windows.odin` + `http_server_posix.odin` — TCP primitives
2. `mcp_http.odin` — HTTP parser, session store, route handlers, `run_mcp_http`
3. `src/config.odin` + `default.config` — new config keys
4. `src/main.odin` — wire up `--http` flag

Each step is independently testable. TCP primitives can be tested with `curl`
before the MCP logic is wired in.

---

## Out of Scope

- TLS / HTTPS (terminate at a reverse proxy if needed)
- Authentication / API keys on the HTTP layer (daemon handles key resolution already)
- HTTP/2 or HTTP/3
- Chunked transfer encoding
- WebSocket transport
