# HTTP MCP Transport Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add HTTP+SSE transport to `shard mcp` so it works as a persistent server reachable by both AI hosts (MCP SSE protocol) and curl scripts (POST /rpc).

**Architecture:** A minimal hand-written HTTP/1.1 TCP server in two platform files (`http_server_windows.odin`, `http_server_posix.odin`) exposes a uniform interface. `mcp_http.odin` owns route dispatch, session store, threading, and HTTP parsing — all reusing the existing `_process_jsonrpc()` unchanged. One OS thread per accepted connection via `thread.create` + `thread.start`.

**Tech Stack:** Odin `core:thread`, `core:sync`, `core:crypto`, `core:encoding/hex`, `core:sys/windows` (Winsock), `core:sys/posix` — all stdlib, zero external deps.

---

## File Map

| Action | File | Responsibility |
|--------|------|---------------|
| Create | `src/http_server_windows.odin` | Winsock TCP listen/accept/send/recv/close |
| Create | `src/http_server_posix.odin` | POSIX TCP listen/accept/send/recv/close |
| Create | `src/mcp_http.odin` | HTTP parser, session store, route handlers, `run_mcp_http` |
| Modify | `src/mcp.odin` | Add `_daemon_mu sync.Mutex`; wrap `_daemon_call` in mutex |
| Modify | `src/config.odin` | Add `http_port: int`, `http_host: string` to `Shard_Config` |
| Modify | `src/default.config` | Add `HTTP_PORT` and `HTTP_HOST` commented keys |
| Modify | `src/main.odin` | Parse `--http [port]` flag in `case "mcp":` branch |
| Create | `tests/unit/test_mcp_http.odin` | Unit tests for session store logic |

---

## Task 1: TCP primitives — Windows (`src/http_server_windows.odin`)

**Files:**
- Create: `src/http_server_windows.odin`

Reference: `src/ipc_windows.odin` — same style, Winsock TCP instead of named pipes.

- [ ] **Step 1: Create the file with Winsock TCP**

Full file content: `#+build windows`, `HTTP_Listener{socket: win.SOCKET}`, `HTTP_Conn{socket: win.SOCKET}`. Procedures: `http_listen(host,port)` calls `WSAStartup(0x0202)`, `win.socket(AF_INET,SOCK_STREAM,IPPROTO_TCP)`, `SO_REUSEADDR`, fills `sockaddr_in` with `inet_addr(host)` and `_http_htons(port)`, calls `bind`+`listen(128)`. `http_accept` calls `win.accept`. `http_send` loops `win.send`. `http_recv` calls `win.recv`, returns `(int,bool)`. `http_close_conn` calls `shutdown(SD_BOTH)`+`closesocket`. `http_close_listener` calls `closesocket`+`WSACleanup`. Private `_http_htons(x u16) -> u16` swaps bytes.

- [ ] **Step 2: Build**

```
just build
```

Expected: compiles cleanly on Windows.

---

## Task 2: TCP primitives — POSIX (`src/http_server_posix.odin`)

**Files:**
- Create: `src/http_server_posix.odin`

Reference: `src/ipc_posix.odin` — same style, `AF_INET` TCP instead of `AF_UNIX`.

- [ ] **Step 1: Create the file with POSIX TCP**

Full file content: `#+build linux, darwin, freebsd, openbsd, netbsd`, `HTTP_Listener{fd: posix.FD}`, `HTTP_Conn{fd: posix.FD}`. Procedures: `http_listen` calls `posix.socket(.INET,.STREAM,0)`, `SO_REUSEADDR`, fills `sockaddr_in` with `inet_pton(host)` and `_http_htons_p(port)`, calls `bind`+`listen(128)`. `http_accept` calls `posix.accept`. `http_send` loops `posix.send`. `http_recv` calls `posix.recv`. `http_close_conn` calls `shutdown(.RDWR)`+`close`. `http_close_listener` calls `close`. Private `_http_htons_p` swaps bytes.

- [ ] **Step 2: Build**

```
just build
```

---

## Task 3: Config additions

**Files:**
- Modify: `src/config.odin`
- Modify: `src/default.config`

- [ ] **Step 1: Add two fields to `Shard_Config` struct after `log_max_size: int`**

```odin
	// HTTP MCP transport
	http_port: int,    // port for shard mcp --http (default 3000)
	http_host: string, // bind address (default "127.0.0.1")
```

- [ ] **Step 2: Add defaults to `DEFAULT_CONFIG` after `log_max_size = 10,`**

```odin
	http_port = 3000,
	http_host = "127.0.0.1",
```

- [ ] **Step 3: Add two cases to the `switch key` block in `config_load`**

```odin
	case "HTTP_PORT":
		_global_config.http_port = _parse_int(val, 3000)
	case "HTTP_HOST":
		_global_config.http_host = strings.clone(val)
```

- [ ] **Step 4: Append to `src/default.config`**

```
# --- HTTP MCP transport (shard mcp --http) ---
# HTTP_PORT 3000
# HTTP_HOST 127.0.0.1
```

- [ ] **Step 5: Build**

```
just build
```

---

## Task 4: Daemon IPC mutex (`src/mcp.odin`)

**Files:**
- Modify: `src/mcp.odin`

- [ ] **Step 1: Add `"core:sync"` to the import block**

- [ ] **Step 2: Add `_daemon_mu` after `_daemon_connected: bool`**

```odin
_daemon_mu: sync.Mutex // guards _daemon_conn for concurrent HTTP threads
```

- [ ] **Step 3: Wrap `_daemon_call` body in `sync.mutex_lock/unlock(&_daemon_mu)` + `defer`**

The lock/unlock wraps the entire proc body. The existing logic inside is unchanged.

- [ ] **Step 4: Build**

```
just build
```

---

## Task 5: `src/mcp_http.odin` — full implementation

**Files:**
- Create: `src/mcp_http.odin`

This file contains everything: session types, session store, HTTP parser, response helpers, per-connection thread handler, three route handlers, and `run_mcp_http`.

- [ ] **Step 1: Create `src/mcp_http.odin`**

Imports: `core:crypto`, `core:encoding/hex`, `core:fmt`, `core:runtime`, `core:strconv`, `core:strings`, `core:sync`, `core:thread`, `core:time`.

**Session store types:**
```odin
HTTP_Session :: struct {
    id: string, conn: HTTP_Conn, alive: bool, mu: sync.Mutex,
}
Session_Store :: struct {
    mu: sync.Mutex, sessions: map[string]^HTTP_Session,
}
```

**Session store procs:**
- `_session_store_init(store)` — `make(map[string]^HTTP_Session)`
- `_session_store_destroy(store)` — free all sessions, delete map
- `_session_register(store, session)` — lock store.mu, insert, unlock
- `_session_remove(store, id)` — lock store.mu, mark alive=false, delete key, free session, unlock
- `_session_push(store, id, event_data) -> bool` — lock store.mu briefly to get session ptr, then lock session.mu, send `"event: message\ndata: %s\n\n"`, return success
- `_session_new_id(allocator) -> string` — `crypto.rand_bytes([16]u8)`, `hex.encode`, return 32-char string

**HTTP_Request struct:** `method, path, query, content_length: int, body: string`

**`_http_read_request(conn, allocator) -> (HTTP_Request, body_buf []u8, ok bool)`:**
- Reads into `[dynamic]u8` header_buf until `\r\n\r\n` found (max 64KB)
- Parses request line: method, URI → splits on `?` into path + query
- Scans headers for `Content-Length:` (case-insensitive prefix match)
- If `content_length > 0`: allocates body_buf, copies header overflow bytes first, reads remaining bytes from conn
- Returns req, body_buf (caller deletes), ok

**Response helpers:**
- `_http_respond(conn, status, content_type, body)` — writes `HTTP/1.1 {status}\r\nContent-Type: {ct}\r\nContent-Length: {len}\r\nConnection: close\r\n\r\n{body}`
- `_http_respond_json(conn, status, body)` — calls `_http_respond` with `application/json`
- `_http_respond_error(conn, status, msg)` — JSON body `{"error":"..."}` via `json_escape`

**`HTTP_Conn_Task :: struct { conn: HTTP_Conn, store: ^Session_Store, ctx: runtime.Context }`**

**`_http_handle_conn(t: ^thread.Thread)`:**
- Cast `t.user_args[0]` to `^HTTP_Conn_Task`, set `context = task.ctx`, copy conn+store, `free(task)`
- `defer http_close_conn(conn)`
- Call `_http_read_request(conn)`, defer delete body_buf if non-nil
- On parse failure → `_http_respond_error("400 Bad Request", ...)`
- Switch on method+path: POST /rpc → `_route_rpc`, GET /sse → `_route_sse`, POST /message → `_route_message`, else → `_http_respond_error("404 Not Found", ...)`

**`_route_rpc(conn, body)`:**
- Empty body → 400. Call `_process_jsonrpc(body)`, `free_all(context.temp_allocator)`. Empty result → fallback JSON. `_http_respond_json("200 OK", resp)`.

**`_route_sse(conn, store)`:**
- `new(HTTP_Session)`, `_session_new_id()`, register, `defer _session_remove`
- Send SSE headers (`Content-Type: text/event-stream`, `Cache-Control: no-cache`, `Connection: keep-alive`)
- Send `"event: endpoint\ndata: /message?sessionId=%s\n\n"`
- Ping loop: `time.sleep(15s)`, check `session.alive`, send `": ping\n\n"`, break on send failure

**`_route_message(conn, store, query, body)`:**
- Extract `sessionId=` from query string (split on `&`)
- Missing sessionId or empty body → 400
- Call `_process_jsonrpc(body)`, `free_all(context.temp_allocator)`
- Non-empty resp → `_session_push`; on failure → 404
- `_http_respond("202 Accepted", "text/plain", "")`

**`run_mcp_http(port, host)`:**
- `config_load()`, `_daemon_auto_start()`
- `http_listen(host, port)` → on failure log+return
- `defer http_close_listener`
- Init Session_Store, `defer _session_store_destroy`
- Log two info lines (POST /rpc URL, GET /sse URL)
- Accept loop: `http_accept` → on failure log+continue; `new(HTTP_Conn_Task)`, fill fields, `thread.create(_http_handle_conn)`, set `t.user_args[0] = task`, `thread.start(t)`

- [ ] **Step 2: Build**

```
just build
```

---

## Task 6: Wire up `--http` flag in `src/main.odin`

**Files:**
- Modify: `src/main.odin`

- [ ] **Step 1: Replace `case "mcp":` branch**

Find:
```odin
		case "mcp":
			run_mcp()
			return
```

Replace with:
```odin
		case "mcp":
			use_http  := false
			http_port := 0
			mcp_args  := os.args[2:]
			for i := 0; i < len(mcp_args); i += 1 {
				if mcp_args[i] == "--http" {
					use_http = true
					if i+1 < len(mcp_args) {
						if p, ok := strconv.parse_int(mcp_args[i+1]); ok {
							http_port = p
							i += 1
						}
					}
				}
			}
			if use_http {
				cfg := config_load()
				if http_port == 0 do http_port = cfg.http_port
				run_mcp_http(http_port, cfg.http_host)
			} else {
				run_mcp()
			}
			return
```

Note: `"core:strconv"` is already imported in `main.odin`. No import change needed.

- [ ] **Step 2: Build**

```
just build
```

---

## Task 7: Unit tests (`tests/unit/test_mcp_http.odin`)

**Files:**
- Create: `tests/unit/test_mcp_http.odin`

- [ ] **Step 1: Create the test file**

```odin
package shard_unit_test

import "core:testing"
import shard "shard:."

@(test)
test_session_new_id_is_32_hex :: proc(t: ^testing.T) {
	defer drain_logger()
	id := shard._session_new_id()
	defer delete(id)
	testing.expect_value(t, len(id), 32)
	for ch in id {
		testing.expect(
			t,
			(ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f'),
			"session ID chars should be lowercase hex",
		)
	}
}

@(test)
test_session_push_missing_returns_false :: proc(t: ^testing.T) {
	defer drain_logger()
	store: shard.Session_Store
	shard._session_store_init(&store)
	defer shard._session_store_destroy(&store)

	ok := shard._session_push(&store, "nonexistent-id", "data")
	testing.expect(t, !ok, "push to nonexistent session should return false")
}

@(test)
test_session_register_and_remove :: proc(t: ^testing.T) {
	defer drain_logger()
	store: shard.Session_Store
	shard._session_store_init(&store)
	defer shard._session_store_destroy(&store)

	session := new(shard.HTTP_Session)
	session.id    = "test-abc123"
	session.alive = true
	shard._session_register(&store, session)
	shard._session_remove(&store, "test-abc123")

	ok := shard._session_push(&store, "test-abc123", "hello")
	testing.expect(t, !ok, "push after remove should return false")
}
```

- [ ] **Step 2: Run unit tests**

```
odin test ./tests/unit -collection:shard=./src -define:ODIN_TEST_LOG_LEVEL=warning
```

Expected: all pass.

- [ ] **Step 3: Full build + tests**

```
just build
```

---

## Task 8: Manual smoke test

- [ ] **Step 1: Start daemon + HTTP server**

```bash
./bin/shard daemon &
sleep 1
./bin/shard mcp --http 3000 &
sleep 1
```

- [ ] **Step 2: Verify tools/list via /rpc**

```bash
curl -s -X POST http://localhost:3000/rpc \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
```

Expected: JSON with `"tools":[...]` array of 17 tools.

- [ ] **Step 3: Verify shard_discover via /rpc**

```bash
curl -s -X POST http://localhost:3000/rpc \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"shard_discover","arguments":{}}}'
```

Expected: JSON with shard table of contents in `result.content[0].text`.

- [ ] **Step 4: Verify SSE stream (terminal 1)**

```bash
curl -N http://localhost:3000/sse
```

Expected (then blocks):
```
event: endpoint
data: /message?sessionId=<32hexchars>

```

- [ ] **Step 5: Send message via SSE (terminal 2)**

```bash
curl -s -X POST "http://localhost:3000/message?sessionId=<id-from-step-4>" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/list","params":{}}'
```

Expected: terminal 2 returns `202` (empty body). Terminal 1 receives:
```
event: message
data: {"jsonrpc":"2.0","id":3,"result":{"tools":[...]}}

```

---

## Task 9: Commit

- [ ] **Step 1: Stage and commit all changes**

```bash
git add src/http_server_windows.odin \
        src/http_server_posix.odin \
        src/mcp_http.odin \
        src/mcp.odin \
        src/config.odin \
        src/default.config \
        src/main.odin \
        tests/unit/test_mcp_http.odin
git commit -m "feat: add HTTP+SSE MCP transport (shard mcp --http)"
```

---

## Known Constraints

- No TLS — use a reverse proxy (nginx, caddy) if HTTPS is needed.
- `HTTP_HOST` is config-only (not a CLI flag) to prevent accidental network exposure.
- SSE ping loop occupies one thread per open `GET /sse` connection. Acceptable for the expected small number of AI host connections (typically 1-2).
- `thread.create` + `thread.start` is used (vs `thread.run_with_data`) for explicit context propagation via `HTTP_Conn_Task.ctx`.
