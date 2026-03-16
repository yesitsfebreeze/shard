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
	{
		name = "shard_query",
		description = "Smart search across one or all shards. Returns the top matching thoughts with full decrypted content in one call. If no shard is specified, searches ALL shards using gate matching to find the most relevant ones. Good for simple lookups in a known shard.",
		schema = `{"type":"object","properties":{"key":{"type":"string","description":"64-hex master key"},"query":{"type":"string","description":"Search keywords or question"},"shard":{"type":"string","description":"Optional: specific shard name. If omitted, searches all shards."},"limit":{"type":"integer","description":"Max results to return (default 5)"}},"required":["key","query"]}`,
	},
	{
		name = "shard_explore",
		description = "Deep graph exploration of the knowledge base. Starting from gate-matched shards, recursively follows cross-links (related shards and [[wikilinks]] in content) to find all relevant thoughts. Returns results grouped by shard with a full exploration trace showing the traversal path. Use this for complex questions that may span multiple shards — it automatically discovers connections you didn't know about.",
		schema = `{"type":"object","properties":{"key":{"type":"string","description":"64-hex master key"},"query":{"type":"string","description":"Search keywords or question"},"limit":{"type":"integer","description":"Max total results to return (default 10)"},"depth":{"type":"integer","description":"Max link-following depth (default 3)"}},"required":["key","query"]}`,
	},
	{
		name = "shard_remember",
		description = "Create a new shard with catalog and gates in one shot. The shard is registered with the daemon and ready for writes immediately. No key needed (the shard file is created empty; thoughts are encrypted on write).",
		schema = `{"type":"object","properties":{"name":{"type":"string","description":"Shard name (used as filename and IPC identifier)"},"purpose":{"type":"string","description":"What this shard is for (free text)"},"tags":{"type":"array","items":{"type":"string"},"description":"Catalog tags for discovery and routing"},"related":{"type":"array","items":{"type":"string"},"description":"Names of related shards"},"positive":{"type":"array","items":{"type":"string"},"description":"Positive gate entries — topics this shard accepts"}},"required":["name","purpose"]}`,
	},
	{
		name = "shard_discover_refresh",
		description = "Re-scan the .shards/ directory and refresh the daemon registry. Use this after manually creating .shard files or if a shard is missing from discovery. Returns the updated registry. No key needed.",
		schema = `{"type":"object","properties":{},"required":[]}`,
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

// Extract a string array from a json.Object (for JSON arrays of strings)
_json_get_str_array :: proc(obj: json.Object, key: string, allocator := context.temp_allocator) -> []string {
	val, ok := obj[key]
	if !ok do return nil
	#partial switch v in val {
	case json.Array:
		result := make([]string, len(v), allocator)
		count := 0
		for item in v {
			#partial switch s in item {
			case string:
				result[count] = s
				count += 1
			}
		}
		return result[:count]
	}
	return nil
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
	case "shard_read":     return _tool_read(id_val, args)
	case "shard_write":    return _tool_write(id_val, args)
	case "shard_update":   return _tool_update(id_val, args)
	case "shard_delete":   return _tool_delete(id_val, args)
	case "shard_list":     return _tool_list(id_val, args)
	case "shard_status":   return _tool_status(id_val, args)
	case "shard_dump":     return _tool_dump(id_val, args)
	case "shard_query":    return _tool_query(id_val, args)
	case "shard_explore":  return _tool_explore(id_val, args)
	case "shard_remember":         return _tool_remember(id_val, args)
	case "shard_discover_refresh": return _tool_discover_refresh(id_val, args)
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

_tool_discover_refresh :: proc(id_val: json.Value, args: json.Object) -> string {
	msg := "---\nop: discover\n---\n"
	resp, ok := _daemon_call(msg)
	if !ok do return _mcp_tool_result(id_val, "error: could not connect to daemon", true)
	return _mcp_tool_result(id_val, resp)
}

_tool_remember :: proc(id_val: json.Value, args: json.Object) -> string {
	name := _json_get_str(args, "name")
	purpose := _json_get_str(args, "purpose")
	if name == "" do return _mcp_tool_result(id_val, "error: name required", true)
	if purpose == "" do return _mcp_tool_result(id_val, "error: purpose required", true)

	tags := _json_get_str_array(args, "tags")
	related := _json_get_str_array(args, "related")
	positive := _json_get_str_array(args, "positive")

	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "---\n")
	strings.write_string(&b, "op: remember\n")
	fmt.sbprintf(&b, "name: %s\n", name)
	fmt.sbprintf(&b, "purpose: %s\n", purpose)
	if tags != nil && len(tags) > 0 {
		strings.write_string(&b, "tags: [")
		for t, i in tags {
			if i > 0 do strings.write_string(&b, ", ")
			strings.write_string(&b, t)
		}
		strings.write_string(&b, "]\n")
	}
	if related != nil && len(related) > 0 {
		strings.write_string(&b, "related: [")
		for r, i in related {
			if i > 0 do strings.write_string(&b, ", ")
			strings.write_string(&b, r)
		}
		strings.write_string(&b, "]\n")
	}
	if positive != nil && len(positive) > 0 {
		strings.write_string(&b, "items: [")
		for p, i in positive {
			if i > 0 do strings.write_string(&b, ", ")
			strings.write_string(&b, p)
		}
		strings.write_string(&b, "]\n")
	}
	strings.write_string(&b, "---\n")

	resp, ok := _daemon_call(strings.to_string(b))
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

	msg := fmt.tprintf("---\nop: gates\nname: %s\n---\n", shard_name)
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

_tool_query :: proc(id_val: json.Value, args: json.Object) -> string {
	key := _json_get_str(args, "key")
	query := _json_get_str(args, "query")
	shard_name := _json_get_str(args, "shard")
	if key == "" do return _mcp_tool_result(id_val, "error: key required", true)
	if query == "" do return _mcp_tool_result(id_val, "error: query required", true)

	query_cfg := config_get()
	limit_i64, has_limit := _json_get_int(args, "limit")
	limit := has_limit ? int(limit_i64) : query_cfg.default_query_limit
	if limit <= 0 do limit = query_cfg.default_query_limit

	// If a specific shard is given, just query it directly
	if shard_name != "" {
		msg := fmt.tprintf(
			"---\nop: query\nname: %s\nkey: %s\nquery: %s\nthought_count: %d\n---\n",
			shard_name, key, query, limit,
		)
		resp, ok := _daemon_call(msg)
		if !ok do return _mcp_tool_result(id_val, fmt.tprintf("error: could not query shard '%s'", shard_name), true)
		return _mcp_tool_result(id_val, resp)
	}

	// No shard specified — cross-shard query:
	// 1. Use traverse to find relevant shards (vector or keyword)
	// 2. Query top shards and aggregate results

	trav_resp, trav_ok := _daemon_call(fmt.tprintf("---\nop: traverse\nquery: %s\nmax_branches: 10\n---\n", query))
	if !trav_ok do return _mcp_tool_result(id_val, "error: could not connect to daemon", true)

	shard_names := _extract_result_ids(trav_resp)
	defer delete(shard_names)

	if len(shard_names) == 0 {
		// Fall back to unfiltered registry
		all_resp, all_ok := _daemon_call("---\nop: registry\n---\n")
		if !all_ok do return _mcp_tool_result(id_val, "error: could not connect to daemon", true)
		delete(shard_names) // free the empty dynamic array before replacing
		shard_names = _extract_shard_names(all_resp)
	}

	// Query each relevant shard and aggregate
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "---\nstatus: ok\n---\n")
	total_results := 0
	per_shard_limit := limit  // ask each shard for the full limit, we'll cap total

	for name in shard_names {
		if total_results >= limit do break

		remaining := limit - total_results
		ask := remaining < per_shard_limit ? remaining : per_shard_limit

		msg := fmt.tprintf(
			"---\nop: query\nname: %s\nkey: %s\nquery: %s\nthought_count: %d\n---\n",
			name, key, query, ask,
		)
		resp, ok := _daemon_call(msg)
		if !ok do continue

		// Check if the response has results (not an error or empty)
		if strings.contains(resp, "results:") {
			fmt.sbprintf(&b, "\n## %s\n\n%s\n", name, resp)
			total_results += _count_yaml_results(resp)
		}
	}

	if total_results == 0 {
		return _mcp_tool_result(id_val, "---\nstatus: ok\n---\nNo matching thoughts found across any shard.")
	}

	return _mcp_tool_result(id_val, strings.to_string(b))
}

// _extract_shard_names parses a registry YAML response and extracts shard names.
_extract_shard_names :: proc(resp: string, allocator := context.allocator) -> [dynamic]string {
	names := make([dynamic]string, allocator)
	for line in strings.split(resp, "\n") {
		trimmed := strings.trim_space(line)
		if strings.has_prefix(trimmed, "- name:") || strings.has_prefix(trimmed, "name:") {
			// Extract value after "name:"
			colon := strings.index(trimmed, ":")
			if colon >= 0 {
				val := strings.trim_space(trimmed[colon + 1:])
				if val != "" && val != "daemon" {
					append(&names, strings.clone(val, allocator))
				}
			}
		}
	}
	return names
}

// _count_yaml_results counts result entries in a marshaled YAML response by matching
// the exact indented list-item prefix "  - id: " (2-space indent). This avoids false
// positives from user content that might contain "- id:" at other indent levels.
_count_yaml_results :: proc(resp: string) -> int {
	count := 0
	rest := resp
	for {
		idx := strings.index(rest, "\n  - id: ")
		if idx == -1 do break
		count += 1
		rest = rest[idx + 1:]
	}
	// Check if the response starts with "  - id: " (no leading newline)
	if strings.has_prefix(resp, "  - id: ") {
		count += 1
	}
	return count
}

// _extract_result_ids parses a traverse YAML response and extracts shard names from "- id:" lines.
_extract_result_ids :: proc(resp: string, allocator := context.allocator) -> [dynamic]string {
	ids := make([dynamic]string, allocator)
	for line in strings.split(resp, "\n") {
		trimmed := strings.trim_space(line)
		if strings.has_prefix(trimmed, "- id:") {
			val := strings.trim_space(trimmed[len("- id:"):])
			if val != "" {
				append(&ids, strings.clone(val, allocator))
			}
		}
	}
	return ids
}

// =============================================================================
// shard_explore — deep graph traversal over the shard network
// =============================================================================
//
// Algorithm (BFS):
//   1. Get the full registry, find shards whose gates match the query
//   2. For each shard in the queue (breadth-first):
//      a. Read its gates to discover related shards
//      b. Query it for matching thoughts (returns content)
//      c. Scan content for [[wikilinks]] to other shards
//      d. Add related + wikilinked shards to the queue (if not visited)
//   3. Repeat until queue empty, result limit reached, or max depth exceeded
//   4. Return all results + an exploration trace showing the traversal path
//

Explore_Queue_Entry :: struct {
	name:   string,
	depth:  int,
	source: string,
}

_tool_explore :: proc(id_val: json.Value, args: json.Object) -> string {
	key := _json_get_str(args, "key")
	query := _json_get_str(args, "query")
	if key == "" do return _mcp_tool_result(id_val, "error: key required", true)
	if query == "" do return _mcp_tool_result(id_val, "error: query required", true)

	explore_cfg := config_get()
	limit_i64, has_limit := _json_get_int(args, "limit")
	limit := has_limit ? int(limit_i64) : explore_cfg.explore_max_results
	if limit <= 0 do limit = explore_cfg.explore_max_results

	depth_i64, has_depth := _json_get_int(args, "depth")
	max_depth := has_depth ? int(depth_i64) : explore_cfg.explore_max_depth
	if max_depth <= 0 do max_depth = explore_cfg.explore_max_depth

	// Step 1: Get full registry to know all valid shard names
	reg_resp, reg_ok := _daemon_call("---\nop: registry\n---\n")
	if !reg_ok do return _mcp_tool_result(id_val, "error: could not connect to daemon", true)

	all_names := _extract_shard_names(reg_resp)
	defer delete(all_names)

	valid_shards: map[string]bool
	defer delete(valid_shards)
	for name in all_names {
		valid_shards[name] = true
	}

	// Step 2: Find initial shards via vector-enhanced traverse
	trav_resp, trav_ok := _daemon_call(fmt.tprintf("---\nop: traverse\nquery: %s\nmax_branches: 10\n---\n", query))
	if !trav_ok do return _mcp_tool_result(id_val, "error: could not connect to daemon", true)

	initial_names := _extract_result_ids(trav_resp)
	defer delete(initial_names)

	// If no gate matches at all, fall back to searching everything
	if len(initial_names) == 0 {
		for name in all_names {
			append(&initial_names, strings.clone(name))
		}
	}

	// Step 3: BFS exploration
	visited: map[string]bool
	defer delete(visited)

	queue := make([dynamic]Explore_Queue_Entry, context.temp_allocator)
	queue_front := 0
	for name in initial_names {
		append(&queue, Explore_Queue_Entry{name = name, depth = 0, source = "gate-match"})
	}

	result_b := strings.builder_make(context.temp_allocator)
	trace_b := strings.builder_make(context.temp_allocator)
	total_results := 0
	step := 0

	strings.write_string(&trace_b, "## Exploration trace\n\n")

	for queue_front < len(queue) && total_results < limit {
		// Pop front (O(1) via index advance)
		entry := queue[queue_front]
		queue_front += 1

		if entry.depth > max_depth do continue
		if entry.name in visited do continue
		visited[entry.name] = true
		step += 1

		// 1. Get gates — gives us related shards
		related := make([dynamic]string, context.temp_allocator)
		gates_resp, gates_ok := _daemon_call(fmt.tprintf("---\nop: gates\nname: %s\n---\n", entry.name))
		if gates_ok {
			related = _extract_related_from_resp(gates_resp)
		}

		// 2. Query this shard for matching thoughts
		remaining := limit - total_results
		query_resp, query_ok := _daemon_call(fmt.tprintf(
			"---\nop: query\nname: %s\nkey: %s\nquery: %s\nthought_count: %d\n---\n",
			entry.name, key, query, remaining,
		))

		matches_found := 0
		new_links: map[string]bool
		defer delete(new_links)

		if query_ok && strings.contains(query_resp, "results:") {
			// Count results by matching the exact YAML list-item indent
			matches_found = _count_yaml_results(query_resp)
			total_results += matches_found

			// Extract wikilinks from the entire response (descriptions + content)
			wikilinks := _extract_wikilinks(query_resp)
			defer delete(wikilinks)
			for wl in wikilinks {
				if wl not_in visited && wl in valid_shards {
					new_links[wl] = true
				}
			}

			// Append results to output
			if matches_found > 0 {
				fmt.sbprintf(&result_b, "\n## %s\n\n%s\n", entry.name, query_resp)
			}
		}

		// 3. Add related shards as new links
		for r in related {
			if r not_in visited && r in valid_shards {
				new_links[r] = true
			}
		}

		// 4. Queue all discovered links
		for link in new_links {
			already_queued := false
			for q in queue {
				if q.name == link { already_queued = true; break }
			}
			if !already_queued {
				append(&queue, Explore_Queue_Entry{
					name   = link,
					depth  = entry.depth + 1,
					source = entry.name,
				})
			}
		}

		// 5. Write trace line
		fmt.sbprintf(&trace_b, "%d. [%s] via %s → %d results", step, entry.name, entry.source, matches_found)
		link_count := 0
		for link in new_links {
			if link_count == 0 {
				strings.write_string(&trace_b, " → discovered: ")
			} else {
				strings.write_string(&trace_b, ", ")
			}
			fmt.sbprintf(&trace_b, "[[%s]]", link)
			link_count += 1
		}
		strings.write_string(&trace_b, "\n")
	}

	// Step 4: Build final response
	final_b := strings.builder_make(context.temp_allocator)
	strings.write_string(&final_b, "---\nstatus: ok\n")
	fmt.sbprintf(&final_b, "total_results: %d\n", total_results)
	fmt.sbprintf(&final_b, "shards_explored: %d\n", step)
	fmt.sbprintf(&final_b, "max_depth: %d\n", max_depth)
	strings.write_string(&final_b, "---\n\n")

	strings.write_string(&final_b, strings.to_string(trace_b))
	strings.write_string(&final_b, "\n")

	if total_results > 0 {
		strings.write_string(&final_b, "## Results\n")
		strings.write_string(&final_b, strings.to_string(result_b))
	} else {
		strings.write_string(&final_b, "No matching thoughts found during exploration.\n")
	}

	// Note unexplored shards in queue (hit limits)
	if queue_front < len(queue) {
		strings.write_string(&final_b, "\n## Not explored (limit reached)\n\n")
		for i in queue_front ..< len(queue) {
			q := queue[i]
			if q.name not_in visited {
				fmt.sbprintf(&final_b, "- [[%s]] (depth %d, from %s)\n", q.name, q.depth, q.source)
			}
		}
	}

	return _mcp_tool_result(id_val, strings.to_string(final_b))
}

// _extract_related_from_resp parses a gates YAML response and extracts the related list.
_extract_related_from_resp :: proc(resp: string, allocator := context.temp_allocator) -> [dynamic]string {
	related := make([dynamic]string, allocator)
	for line in strings.split(resp, "\n") {
		trimmed := strings.trim_space(line)
		if strings.has_prefix(trimmed, "related:") {
			val := strings.trim_space(trimmed[len("related:"):])
			if strings.has_prefix(val, "[") && strings.has_suffix(val, "]") {
				inner := val[1:len(val) - 1]
				for part in strings.split(inner, ",") {
					name := strings.trim_space(part)
					if name != "" {
						append(&related, name)
					}
				}
			}
			break
		}
	}
	return related
}

// _extract_wikilinks finds all [[...]] patterns in text and returns the link targets.
_extract_wikilinks :: proc(text: string, allocator := context.temp_allocator) -> [dynamic]string {
	links := make([dynamic]string, allocator)
	seen: map[string]bool
	defer delete(seen)
	rest := text
	for {
		start := strings.index(rest, "[[")
		if start == -1 do break
		rest = rest[start + 2:]
		end := strings.index(rest, "]]")
		if end == -1 do break
		link := strings.trim_space(rest[:end])
		if link != "" && link not_in seen {
			seen[link] = true
			append(&links, link)
		}
		rest = rest[end + 2:]
	}
	return links
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

	// Load config
	config_load()

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
