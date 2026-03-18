package shard

import "core:crypto"
import "core:encoding/hex"
import "core:fmt"
import "base:runtime"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

// =============================================================================
// HTTP MCP transport — JSON-RPC 2.0 over HTTP/1.1 + SSE
// =============================================================================
//
// Usage:  shard mcp --http [port]
//
// Routes:
//   POST /rpc                    — stateless JSON-RPC, returns response inline
//   GET  /sse                    — opens SSE stream, sends endpoint event
//   POST /message?sessionId=<id> — dispatches JSON-RPC, pushes result to SSE
//
// Threading: one OS thread per accepted connection (thread.create + start).
// Session store is mutex-guarded for concurrent access.
// Daemon IPC is serialised via _daemon_mu (defined in mcp.odin).
//

// =============================================================================
// Session store
// =============================================================================

HTTP_Session :: struct {
	id:    string,
	conn:  HTTP_Conn,
	alive: bool,
	mu:    sync.Mutex, // guards writes to this session's conn
}

Session_Store :: struct {
	mu:       sync.Mutex,
	sessions: map[string]^HTTP_Session,
}

_session_store_init :: proc(store: ^Session_Store) {
	store.sessions = make(map[string]^HTTP_Session)
}

_session_store_destroy :: proc(store: ^Session_Store) {
	for _, s in store.sessions do free(s)
	delete(store.sessions)
}

_session_register :: proc(store: ^Session_Store, session: ^HTTP_Session) {
	sync.mutex_lock(&store.mu)
	defer sync.mutex_unlock(&store.mu)
	store.sessions[session.id] = session
}

_session_remove :: proc(store: ^Session_Store, id: string) {
	sync.mutex_lock(&store.mu)
	defer sync.mutex_unlock(&store.mu)
	if s, ok := store.sessions[id]; ok {
		s.alive = false
		delete_key(&store.sessions, id)
		free(s)
	}
}

// _session_push sends an SSE message event to the named session.
// Returns false if session not found or write failed.
_session_push :: proc(store: ^Session_Store, id: string, event_data: string) -> bool {
	// Hold store lock only for the brief map lookup
	sync.mutex_lock(&store.mu)
	s, ok := store.sessions[id]
	sync.mutex_unlock(&store.mu)
	if !ok do return false

	// Hold session lock for the actual I/O
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)
	if !s.alive do return false

	msg := fmt.tprintf("event: message\ndata: %s\n\n", event_data)
	return http_send(s.conn, transmute([]u8)msg)
}

// _session_new_id generates a crypto-random 32 lowercase hex char session ID.
_session_new_id :: proc(allocator := context.allocator) -> string {
	raw: [16]u8
	crypto.rand_bytes(raw[:])
	return string(hex.encode(raw[:], allocator))
}

// =============================================================================
// HTTP request parsing
// =============================================================================

HTTP_Request :: struct {
	method:         string,
	path:           string,
	query:          string, // everything after '?' in the URI
	content_length: int,
	body:           string,
}

// _http_read_request reads one HTTP/1.1 request from conn.
// body_buf is allocated with the provided allocator and must be deleted by
// the caller when non-nil. method/path/query are also allocated strings.
_http_read_request :: proc(
	conn: HTTP_Conn,
	allocator := context.allocator,
) -> (
	req: HTTP_Request,
	body_buf: []u8,
	ok: bool,
) {
	header_buf := make([dynamic]u8, 0, 4096, context.temp_allocator)
	read_buf: [4096]u8
	header_end := -1

	// Read until we find the blank line separating headers from body
	for header_end == -1 {
		n, recv_ok := http_recv(conn, read_buf[:])
		if !recv_ok || n == 0 do return {}, nil, false
		append(&header_buf, ..read_buf[:n])
		for i in 0 ..< len(header_buf) - 3 {
			if header_buf[i] == '\r' && header_buf[i + 1] == '\n' &&
			   header_buf[i + 2] == '\r' && header_buf[i + 3] == '\n' {
				header_end = i
				break
			}
		}
		if len(header_buf) > 65536 do return {}, nil, false // guard against huge headers
	}

	header_section := string(header_buf[:header_end])
	body_prefix    := header_buf[header_end + 4:] // bytes already read past headers

	// Parse request line: METHOD URI HTTP/1.x
	lines := strings.split_lines(header_section, context.temp_allocator)
	if len(lines) == 0 do return {}, nil, false
	parts := strings.fields(lines[0], context.temp_allocator)
	if len(parts) < 2 do return {}, nil, false

	req.method = strings.clone(parts[0], allocator)
	uri := parts[1]
	if q := strings.index(uri, "?"); q != -1 {
		req.path  = strings.clone(uri[:q], allocator)
		req.query = strings.clone(uri[q + 1:], allocator)
	} else {
		req.path = strings.clone(uri, allocator)
	}

	// Scan remaining header lines for Content-Length
	for line in lines[1:] {
		lower := strings.to_lower(line, context.temp_allocator)
		if strings.has_prefix(lower, "content-length:") {
			val := strings.trim_space(line[15:])
			if cl, parse_ok := strconv.parse_int(val); parse_ok {
				req.content_length = cl
			}
		}
	}

	// Read body if Content-Length > 0
	if req.content_length > 0 {
		body_data := make([]u8, req.content_length, allocator)
		prefix_len := min(len(body_prefix), req.content_length)
		copy(body_data[:prefix_len], body_prefix[:prefix_len])
		total := prefix_len
		for total < req.content_length {
			n, recv_ok := http_recv(conn, body_data[total:])
			if !recv_ok || n == 0 {
				delete(body_data, allocator)
				return {}, nil, false
			}
			total += n
		}
		req.body = string(body_data)
		return req, body_data, true
	}

	return req, nil, true
}

// =============================================================================
// HTTP response helpers
// =============================================================================

_http_respond :: proc(conn: HTTP_Conn, status: string, content_type: string, body: string) {
	resp := fmt.tprintf(
		"HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s",
		status, content_type, len(body), body,
	)
	http_send(conn, transmute([]u8)resp)
}

_http_respond_json :: proc(conn: HTTP_Conn, status: string, body: string) {
	_http_respond(conn, status, "application/json", body)
}

_http_respond_error :: proc(conn: HTTP_Conn, status: string, msg: string) {
	body := fmt.tprintf(`{"error":"%s"}`, json_escape(msg))
	_http_respond_json(conn, status, body)
}

// =============================================================================
// Per-connection thread task
// =============================================================================

HTTP_Conn_Task :: struct {
	conn:  HTTP_Conn,
	store: ^Session_Store,
	ctx:   runtime.Context,
}

// _http_handle_conn is the thread entry point for each accepted connection.
// Owns the conn and task; both are freed/closed on return.
_http_handle_conn :: proc(t: ^thread.Thread) {
	task    := cast(^HTTP_Conn_Task)t.user_args[0]
	context  = task.ctx
	conn    := task.conn
	store   := task.store
	free(task)
	defer http_close_conn(conn)

	req, body_buf, ok := _http_read_request(conn)
	defer if body_buf != nil do delete(body_buf)

	if !ok {
		_http_respond_error(conn, "400 Bad Request", "invalid or incomplete request")
		return
	}

	switch {
	case req.method == "POST" && req.path == "/rpc":
		_route_rpc(conn, req.body)
	case req.method == "GET" && req.path == "/sse":
		_route_sse(conn, store)
	case req.method == "POST" && req.path == "/message":
		_route_message(conn, store, req.query, req.body)
	case:
		_http_respond_error(conn, "404 Not Found", "not found")
	}
}

// =============================================================================
// Route handlers
// =============================================================================

// POST /rpc — stateless one-shot JSON-RPC, response returned inline
_route_rpc :: proc(conn: HTTP_Conn, body: string) {
	if body == "" {
		_http_respond_error(conn, "400 Bad Request", "empty body")
		return
	}
	resp := _process_jsonrpc(body)
	// Send BEFORE freeing temp allocator — resp points into temp-allocated memory
	if resp == "" do resp = `{"jsonrpc":"2.0","id":null,"result":null}`
	_http_respond_json(conn, "200 OK", resp)
	free_all(context.temp_allocator)
}

// GET /sse — open SSE stream, register session, send endpoint event, keep alive
_route_sse :: proc(conn: HTTP_Conn, store: ^Session_Store) {
	session       := new(HTTP_Session)
	session.id     = _session_new_id()
	session.conn   = conn
	session.alive  = true
	_session_register(store, session)
	defer _session_remove(store, session.id)

	// SSE response headers — no Content-Length, connection stays open
	headers := "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n"
	if !http_send(conn, transmute([]u8)headers) do return

	// Tell the MCP client where to POST messages for this session
	endpoint := fmt.tprintf("event: endpoint\ndata: /message?sessionId=%s\n\n", session.id)
	if !http_send(conn, transmute([]u8)endpoint) do return

	infof("http: SSE session opened: %s", session.id)

	// Ping loop — keeps the connection alive and detects disconnection
	for {
		time.sleep(15 * time.Second)
		sync.mutex_lock(&session.mu)
		alive := session.alive
		sync.mutex_unlock(&session.mu)
		if !alive do break
		ping := ": ping\n\n"
		if !http_send(conn, transmute([]u8)ping) do break
	}

	infof("http: SSE session closed: %s", session.id)
}

// POST /message?sessionId=<id> — dispatch JSON-RPC, push response to SSE stream
_route_message :: proc(conn: HTTP_Conn, store: ^Session_Store, query: string, body: string) {
	// Extract sessionId from query string
	session_id := ""
	q := query
	for part in strings.split_iterator(&q, "&") {
		if strings.has_prefix(part, "sessionId=") {
			session_id = part[10:]
			break
		}
	}
	if session_id == "" {
		_http_respond_error(conn, "400 Bad Request", "missing sessionId")
		return
	}
	if body == "" {
		_http_respond_error(conn, "400 Bad Request", "empty body")
		return
	}

	resp := _process_jsonrpc(body)
	// Push BEFORE freeing temp allocator — resp points into temp-allocated memory
	// Empty response = notification (no id), no push needed
	if resp != "" {
		if !_session_push(store, session_id, resp) {
			free_all(context.temp_allocator)
			_http_respond_error(conn, "404 Not Found", "session not found or disconnected")
			return
		}
	}
	free_all(context.temp_allocator)

	// 202 Accepted — actual JSON-RPC response is delivered via SSE, not here
	_http_respond(conn, "202 Accepted", "text/plain", "")
}

// =============================================================================
// Entry point
// =============================================================================

run_mcp_http :: proc(port: int, host: string) {
	infof("starting HTTP MCP server on %s:%d", host, port)
	config_load()
	_daemon_auto_start()

	listener, ok := http_listen(host, port)
	if !ok {
		errf("http: failed to bind %s:%d — is the port already in use?", host, port)
		return
	}
	defer http_close_listener(&listener)

	store: Session_Store
	_session_store_init(&store)
	defer _session_store_destroy(&store)

	infof("http: POST http://%s:%d/rpc   for stateless curl calls", host, port)
	infof("http: GET  http://%s:%d/sse   for MCP host SSE connections", host, port)

	for {
		conn, accept_ok := http_accept(&listener)
		if !accept_ok {
			warn("http: accept failed, retrying...")
			continue
		}

		task       := new(HTTP_Conn_Task)
		task.conn   = conn
		task.store  = &store
		task.ctx    = context

		t := thread.create(_http_handle_conn)
		t.user_args[0] = task
		thread.start(t)
	}
}
