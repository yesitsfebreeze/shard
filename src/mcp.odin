package shard

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"

// =============================================================================
// MCP server — JSON-RPC 2.0 over stdio
// =============================================================================
//
// Usage:  shard mcp
//
// Reads JSON-RPC messages from stdin (one per line), writes responses to stdout.
// All diagnostic output goes to stderr. Connects to the daemon via IPC; the
// daemon loads shard blobs in-process and routes ops by the `name:` field.
//
// Protocol:
//   initialize        → server info + capabilities
//   notifications/initialized  → (no response)
//   tools/list        → list of available tools
//   tools/call        → execute a tool
//

MCP_SERVER_NAME    :: "shard-mcp"
MCP_SERVER_VERSION :: "0.2.0"
MCP_PROTOCOL_VERSION :: "2024-11-05"

// =============================================================================
// Daemon connection — single persistent IPC connection to the daemon
// =============================================================================

_daemon_conn: IPC_Conn
_daemon_connected: bool

_daemon_get :: proc() -> (IPC_Conn, bool) {
	if _daemon_connected do return _daemon_conn, true
	conn, ok := ipc_connect(DAEMON_NAME)
	if !ok do return {}, false
	_daemon_conn = conn
	_daemon_connected = true
	return conn, true
}

_daemon_invalidate :: proc() {
	if _daemon_connected {
		ipc_close_conn(_daemon_conn)
		_daemon_connected = false
	}
}

// _daemon_call sends a YAML frontmatter message to the daemon and returns the response.
_daemon_call :: proc(message: string, allocator := context.allocator) -> (string, bool) {
	conn, ok := _daemon_get()
	if !ok do return "", false

	data := transmute([]u8)message
	if !ipc_send_msg(conn, data) {
		_daemon_invalidate()
		return "", false
	}

	resp, recv_ok := ipc_recv_msg(conn, allocator)
	if !recv_ok {
		_daemon_invalidate()
		return "", false
	}
	return string(resp), true
}

// =============================================================================
// Tool definitions
// =============================================================================

Tool_Def :: struct {
	name:        string,
	description: string,
	schema:      string, // JSON string for inputSchema
}

_tools := [?]Tool_Def{
	{
		name = "shard_discover",
		description = "List all known shards from the daemon registry. Returns shard names, alive status, catalogs, and gates. No key needed.",
		schema = `{"type":"object","properties":{"query":{"type":"string","description":"Optional keyword to filter shards"}},"required":[]}`,
	},
	{
		name = "shard_catalog",
		description = "Read a shard's catalog (plaintext identity card: name, purpose, tags, related shards). No key needed.",
		schema = `{"type":"object","properties":{"shard":{"type":"string","description":"Shard name"}},"required":["shard"]}`,
	},
	{
		name = "shard_gates",
		description = "Read a shard's routing gates: description, positive (accepts), and negative (rejects). No key needed.",
		schema = `{"type":"object","properties":{"shard":{"type":"string","description":"Shard name"}},"required":["shard"]}`,
	},
	{
		name = "shard_search",
		description = "Search a shard's thought descriptions by keyword. Returns matching thought IDs and scores. Requires key.",
		schema = `{"type":"object","properties":{"shard":{"type":"string","description":"Shard name"},"key":{"type":"string","description":"64-hex master key"},"query":{"type":"string","description":"Search keywords"}},"required":["shard","key","query"]}`,
	},
	{
		name = "shard_read",
		description = "Decrypt and read a thought by ID. Returns description and content. Requires key.",
		schema = `{"type":"object","properties":{"shard":{"type":"string","description":"Shard name"},"key":{"type":"string","description":"64-hex master key"},"id":{"type":"string","description":"Thought ID (32 hex chars)"}},"required":["shard","key","id"]}`,
	},
	{
		name = "shard_write",
		description = "Write a new encrypted thought to a shard. Returns the new thought ID. Requires key.",
		schema = `{"type":"object","properties":{"shard":{"type":"string","description":"Shard name"},"key":{"type":"string","description":"64-hex master key"},"description":{"type":"string","description":"Thought description (searchable)"},"content":{"type":"string","description":"Thought body content"}},"required":["shard","key","description","content"]}`,
	},
	{
		name = "shard_update",
		description = "Update an existing thought's description and/or content. Omitted fields keep current values. Requires key.",
		schema = `{"type":"object","properties":{"shard":{"type":"string","description":"Shard name"},"key":{"type":"string","description":"64-hex master key"},"id":{"type":"string","description":"Thought ID"},"description":{"type":"string","description":"New description (optional)"},"content":{"type":"string","description":"New content (optional)"}},"required":["shard","key","id"]}`,
	},
	{
		name = "shard_delete",
		description = "Delete a thought by ID. Requires key.",
		schema = `{"type":"object","properties":{"shard":{"type":"string","description":"Shard name"},"key":{"type":"string","description":"64-hex master key"},"id":{"type":"string","description":"Thought ID"}},"required":["shard","key","id"]}`,
	},
	{
		name = "shard_list",
		description = "List all thought IDs in a shard. No key needed.",
		schema = `{"type":"object","properties":{"shard":{"type":"string","description":"Shard name"}},"required":["shard"]}`,
	},
	{
		name = "shard_status",
		description = "Get shard health check: node name, role, thought count, uptime. No key needed.",
		schema = `{"type":"object","properties":{"shard":{"type":"string","description":"Shard name"}},"required":["shard"]}`,
	},
	{
		name = "shard_dump",
		description = "Dump all thoughts in a shard as a markdown document. Requires key.",
		schema = `{"type":"object","properties":{"shard":{"type":"string","description":"Shard name"},"key":{"type":"string","description":"64-hex master key"}},"required":["shard","key"]}`,
	},
}

// =============================================================================
// JSON-RPC helpers
// =============================================================================

// Extract a string field from a json.Object
_json_get_str :: proc(obj: json.Object, key: string) -> string {
	val, ok := obj[key]
	if !ok do return ""
	#partial switch v in val {
	case string:
		return v
	}
	return ""
}

// Extract an integer field from a json.Object
_json_get_int :: proc(obj: json.Object, key: string) -> (i64, bool) {
	val, ok := obj[key]
	if !ok do return 0, false
	#partial switch v in val {
	case i64:
		return v, true
	case f64:
		return i64(v), true
	}
	return 0, false
}

// Extract an object field from a json.Object
_json_get_obj :: proc(obj: json.Object, key: string) -> (json.Object, bool) {
	val, ok := obj[key]
	if !ok do return {}, false
	#partial switch v in val {
	case json.Object:
		return v, true
	}
	return {}, false
}

// =============================================================================
// Response builders
// =============================================================================

_mcp_result :: proc(id_val: json.Value, result_json: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"jsonrpc":"2.0","id":`)
	_write_json_value(&b, id_val)
	strings.write_string(&b, `,"result":`)
	strings.write_string(&b, result_json)
	strings.write_string(&b, `}`)
	return strings.to_string(b)
}

_mcp_error :: proc(id_val: json.Value, code: int, message: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"jsonrpc":"2.0","id":`)
	_write_json_value(&b, id_val)
	strings.write_string(&b, `,"error":{"code":`)
	fmt.sbprintf(&b, "%d", code)
	strings.write_string(&b, `,"message":"`)
	strings.write_string(&b, _json_escape(message))
	strings.write_string(&b, `"}}`)
	return strings.to_string(b)
}

_mcp_tool_result :: proc(id_val: json.Value, text: string, is_error: bool = false) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"jsonrpc":"2.0","id":`)
	_write_json_value(&b, id_val)
	strings.write_string(&b, `,"result":{"content":[{"type":"text","text":"`)
	strings.write_string(&b, _json_escape(text))
	strings.write_string(&b, `"}]`)
	if is_error {
		strings.write_string(&b, `,"isError":true`)
	}
	strings.write_string(&b, `}}`)
	return strings.to_string(b)
}

_write_json_value :: proc(b: ^strings.Builder, val: json.Value) {
	#partial switch v in val {
	case i64:
		fmt.sbprintf(b, "%d", v)
	case f64:
		fmt.sbprintf(b, "%v", v)
	case string:
		strings.write_string(b, `"`)
		strings.write_string(b, _json_escape(v))
		strings.write_string(b, `"`)
	case:
		strings.write_string(b, "null")
	}
}

_json_escape :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for ch in s {
		switch ch {
		case '"':  strings.write_string(&b, `\"`)
		case '\\': strings.write_string(&b, `\\`)
		case '\n': strings.write_string(&b, `\n`)
		case '\r': strings.write_string(&b, `\r`)
		case '\t': strings.write_string(&b, `\t`)
		case:      strings.write_rune(&b, ch)
		}
	}
	return strings.to_string(b)
}

// =============================================================================
// MCP message handlers
// =============================================================================

_handle_initialize :: proc(id_val: json.Value) -> string {
	return _mcp_result(id_val, `{` +
		`"protocolVersion":"` + MCP_PROTOCOL_VERSION + `",` +
		`"capabilities":{"tools":{}},` +
		`"serverInfo":{"name":"` + MCP_SERVER_NAME + `","version":"` + MCP_SERVER_VERSION + `"}` +
	`}`)
}

_handle_tools_list :: proc(id_val: json.Value) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"tools":[`)
	for tool, i in _tools {
		if i > 0 do strings.write_string(&b, `,`)
		strings.write_string(&b, `{"name":"`)
		strings.write_string(&b, tool.name)
		strings.write_string(&b, `","description":"`)
		strings.write_string(&b, _json_escape(tool.description))
		strings.write_string(&b, `","inputSchema":`)
		strings.write_string(&b, tool.schema)
		strings.write_string(&b, `}`)
	}
	strings.write_string(&b, `]}`)
	return _mcp_result(id_val, strings.to_string(b))
}

_handle_tools_call :: proc(id_val: json.Value, params: json.Object) -> string {
	tool_name := _json_get_str(params, "name")
	args, args_ok := _json_get_obj(params, "arguments")
	if !args_ok {
		return _mcp_error(id_val, -32602, "missing arguments")
	}

	switch tool_name {
	case "shard_discover": return _tool_discover(id_val, args)
	case "shard_catalog":  return _tool_catalog(id_val, args)
	case "shard_gates":    return _tool_gates(id_val, args)
	case "shard_search":   return _tool_search(id_val, args)
	case "shard_read":     return _tool_read(id_val, args)
	case "shard_write":    return _tool_write(id_val, args)
	case "shard_update":   return _tool_update(id_val, args)
	case "shard_delete":   return _tool_delete(id_val, args)
	case "shard_list":     return _tool_list(id_val, args)
	case "shard_status":   return _tool_status(id_val, args)
	case "shard_dump":     return _tool_dump(id_val, args)
	case:
		return _mcp_error(id_val, -32602, fmt.tprintf("unknown tool: %s", tool_name))
	}
}

// =============================================================================
// Tool implementations — build YAML frontmatter messages routed through daemon
// =============================================================================
//
// All shard-specific ops include `name: <shard>` so the daemon routes them
// to the correct in-process slot. The daemon loads shard blobs on demand.
//

_tool_discover :: proc(id_val: json.Value, args: json.Object) -> string {
	query := _json_get_str(args, "query")
	msg: string
	if query != "" {
		msg = fmt.tprintf("---\nop: registry\nquery: %s\n---\n", query)
	} else {
		msg = "---\nop: registry\n---\n"
	}
	resp, ok := _daemon_call(msg)
	if !ok do return _mcp_tool_result(id_val, "error: could not connect to daemon", true)
	return _mcp_tool_result(id_val, resp)
}

_tool_catalog :: proc(id_val: json.Value, args: json.Object) -> string {
	shard_name := _json_get_str(args, "shard")
	if shard_name == "" do return _mcp_tool_result(id_val, "error: shard name required", true)

	msg := fmt.tprintf("---\nop: catalog\nname: %s\n---\n", shard_name)
	resp, ok := _daemon_call(msg)
	if !ok do return _mcp_tool_result(id_val, fmt.tprintf("error: could not connect to shard '%s'", shard_name), true)
	return _mcp_tool_result(id_val, resp)
}

_tool_gates :: proc(id_val: json.Value, args: json.Object) -> string {
	shard_name := _json_get_str(args, "shard")
	if shard_name == "" do return _mcp_tool_result(id_val, "error: shard name required", true)

	b := strings.builder_make(context.temp_allocator)

	desc, ok1 := _daemon_call(fmt.tprintf("---\nop: description\nname: %s\n---\n", shard_name))
	if !ok1 do return _mcp_tool_result(id_val, fmt.tprintf("error: could not connect to shard '%s'", shard_name), true)
	strings.write_string(&b, "=== description ===\n")
	strings.write_string(&b, desc)

	pos, ok2 := _daemon_call(fmt.tprintf("---\nop: positive\nname: %s\n---\n", shard_name))
	if ok2 {
		strings.write_string(&b, "\n=== positive ===\n")
		strings.write_string(&b, pos)
	}

	neg, ok3 := _daemon_call(fmt.tprintf("---\nop: negative\nname: %s\n---\n", shard_name))
	if ok3 {
		strings.write_string(&b, "\n=== negative ===\n")
		strings.write_string(&b, neg)
	}

	return _mcp_tool_result(id_val, strings.to_string(b))
}

_tool_search :: proc(id_val: json.Value, args: json.Object) -> string {
	shard_name := _json_get_str(args, "shard")
	key := _json_get_str(args, "key")
	query := _json_get_str(args, "query")
	if shard_name == "" do return _mcp_tool_result(id_val, "error: shard name required", true)
	if key == "" do return _mcp_tool_result(id_val, "error: key required", true)
	if query == "" do return _mcp_tool_result(id_val, "error: query required", true)

	msg := fmt.tprintf("---\nop: search\nname: %s\nkey: %s\nquery: %s\n---\n", shard_name, key, query)
	resp, ok := _daemon_call(msg)
	if !ok do return _mcp_tool_result(id_val, fmt.tprintf("error: could not connect to shard '%s'", shard_name), true)
	return _mcp_tool_result(id_val, resp)
}

_tool_read :: proc(id_val: json.Value, args: json.Object) -> string {
	shard_name := _json_get_str(args, "shard")
	key := _json_get_str(args, "key")
	thought_id := _json_get_str(args, "id")
	if shard_name == "" do return _mcp_tool_result(id_val, "error: shard name required", true)
	if key == "" do return _mcp_tool_result(id_val, "error: key required", true)
	if thought_id == "" do return _mcp_tool_result(id_val, "error: thought id required", true)

	msg := fmt.tprintf("---\nop: read\nname: %s\nkey: %s\nid: %s\n---\n", shard_name, key, thought_id)
	resp, ok := _daemon_call(msg)
	if !ok do return _mcp_tool_result(id_val, fmt.tprintf("error: could not connect to shard '%s'", shard_name), true)
	return _mcp_tool_result(id_val, resp)
}

_tool_write :: proc(id_val: json.Value, args: json.Object) -> string {
	shard_name := _json_get_str(args, "shard")
	key := _json_get_str(args, "key")
	desc := _json_get_str(args, "description")
	content := _json_get_str(args, "content")
	if shard_name == "" do return _mcp_tool_result(id_val, "error: shard name required", true)
	if key == "" do return _mcp_tool_result(id_val, "error: key required", true)
	if desc == "" do return _mcp_tool_result(id_val, "error: description required", true)

	msg := fmt.tprintf("---\nop: write\nname: %s\nkey: %s\ndescription: %s\n---\n%s", shard_name, key, desc, content)
	resp, ok := _daemon_call(msg)
	if !ok do return _mcp_tool_result(id_val, fmt.tprintf("error: could not connect to shard '%s'", shard_name), true)
	return _mcp_tool_result(id_val, resp)
}

_tool_update :: proc(id_val: json.Value, args: json.Object) -> string {
	shard_name := _json_get_str(args, "shard")
	key := _json_get_str(args, "key")
	thought_id := _json_get_str(args, "id")
	desc := _json_get_str(args, "description")
	content := _json_get_str(args, "content")
	if shard_name == "" do return _mcp_tool_result(id_val, "error: shard name required", true)
	if key == "" do return _mcp_tool_result(id_val, "error: key required", true)
	if thought_id == "" do return _mcp_tool_result(id_val, "error: thought id required", true)

	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "---\n")
	strings.write_string(&b, "op: update\n")
	fmt.sbprintf(&b, "name: %s\n", shard_name)
	fmt.sbprintf(&b, "key: %s\n", key)
	fmt.sbprintf(&b, "id: %s\n", thought_id)
	if desc != "" do fmt.sbprintf(&b, "description: %s\n", desc)
	strings.write_string(&b, "---\n")
	if content != "" do strings.write_string(&b, content)

	resp, ok := _daemon_call(strings.to_string(b))
	if !ok do return _mcp_tool_result(id_val, fmt.tprintf("error: could not connect to shard '%s'", shard_name), true)
	return _mcp_tool_result(id_val, resp)
}

_tool_delete :: proc(id_val: json.Value, args: json.Object) -> string {
	shard_name := _json_get_str(args, "shard")
	key := _json_get_str(args, "key")
	thought_id := _json_get_str(args, "id")
	if shard_name == "" do return _mcp_tool_result(id_val, "error: shard name required", true)
	if key == "" do return _mcp_tool_result(id_val, "error: key required", true)
	if thought_id == "" do return _mcp_tool_result(id_val, "error: thought id required", true)

	msg := fmt.tprintf("---\nop: delete\nname: %s\nkey: %s\nid: %s\n---\n", shard_name, key, thought_id)
	resp, ok := _daemon_call(msg)
	if !ok do return _mcp_tool_result(id_val, fmt.tprintf("error: could not connect to shard '%s'", shard_name), true)
	return _mcp_tool_result(id_val, resp)
}

_tool_list :: proc(id_val: json.Value, args: json.Object) -> string {
	shard_name := _json_get_str(args, "shard")
	if shard_name == "" do return _mcp_tool_result(id_val, "error: shard name required", true)

	msg := fmt.tprintf("---\nop: list\nname: %s\n---\n", shard_name)
	resp, ok := _daemon_call(msg)
	if !ok do return _mcp_tool_result(id_val, fmt.tprintf("error: could not connect to shard '%s'", shard_name), true)
	return _mcp_tool_result(id_val, resp)
}

_tool_status :: proc(id_val: json.Value, args: json.Object) -> string {
	shard_name := _json_get_str(args, "shard")
	if shard_name == "" do return _mcp_tool_result(id_val, "error: shard name required", true)

	msg := fmt.tprintf("---\nop: status\nname: %s\n---\n", shard_name)
	resp, ok := _daemon_call(msg)
	if !ok do return _mcp_tool_result(id_val, fmt.tprintf("error: could not connect to shard '%s'", shard_name), true)
	return _mcp_tool_result(id_val, resp)
}

_tool_dump :: proc(id_val: json.Value, args: json.Object) -> string {
	shard_name := _json_get_str(args, "shard")
	key := _json_get_str(args, "key")
	if shard_name == "" do return _mcp_tool_result(id_val, "error: shard name required", true)
	if key == "" do return _mcp_tool_result(id_val, "error: key required", true)

	msg := fmt.tprintf("---\nop: dump\nname: %s\nkey: %s\n---\n", shard_name, key)
	resp, ok := _daemon_call(msg)
	if !ok do return _mcp_tool_result(id_val, fmt.tprintf("error: could not connect to shard '%s'", shard_name), true)
	return _mcp_tool_result(id_val, resp)
}

// =============================================================================
// Main MCP loop — reads JSON-RPC from stdin, dispatches, writes to stdout
// =============================================================================

run_mcp :: proc() {
	fmt.eprintln("shard-mcp: starting MCP server on stdio")

	// Read lines from stdin
	buf := make([]u8, 65536)  // 64KB read buffer
	defer delete(buf)
	line_builder := strings.builder_make()
	defer strings.builder_destroy(&line_builder)

	for {
		n, err := os.read(os.stdin, buf[:])
		if err != nil || n <= 0 do break

		// Append to line builder and process complete lines
		strings.write_bytes(&line_builder, buf[:n])
		accumulated := strings.to_string(line_builder)

		for {
			nl := strings.index(accumulated, "\n")
			if nl == -1 do break

			line := strings.trim_right(accumulated[:nl], "\r")
			accumulated = accumulated[nl + 1:]

			if strings.trim_space(line) == "" do continue

			resp := _process_jsonrpc(line)
			if resp != "" {
				fmt.println(resp)
			}
		}

		// Keep any remaining partial line
		if accumulated != "" {
			remainder := strings.clone(accumulated)
			strings.builder_reset(&line_builder)
			strings.write_string(&line_builder, remainder)
			delete(remainder)
		} else {
			strings.builder_reset(&line_builder)
		}
	}

	// Cleanup daemon connection
	_daemon_invalidate()
	fmt.eprintln("shard-mcp: stopped")
}

_process_jsonrpc :: proc(line: string) -> string {
	// Parse JSON
	parsed, parse_err := json.parse(transmute([]u8)line)
	if parse_err != nil {
		return _mcp_error(json.Value(nil), -32700, "parse error")
	}

	obj, is_obj := parsed.(json.Object)
	if !is_obj {
		return _mcp_error(json.Value(nil), -32600, "invalid request")
	}

	method := _json_get_str(obj, "method")
	id_val, has_id := obj["id"]

	// Notifications have no id — no response expected
	if !has_id || method == "notifications/initialized" {
		fmt.eprintfln("shard-mcp: notification: %s", method)
		return ""
	}

	switch method {
	case "initialize":
		return _handle_initialize(id_val)
	case "tools/list":
		return _handle_tools_list(id_val)
	case "tools/call":
		params, params_ok := _json_get_obj(obj, "params")
		if !params_ok {
			return _mcp_error(id_val, -32602, "missing params")
		}
		return _handle_tools_call(id_val, params)
	case:
		return _mcp_error(id_val, -32601, fmt.tprintf("method not found: %s", method))
	}
}
