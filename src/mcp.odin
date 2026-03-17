package shard

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:os/os2"
import "core:strings"
import "core:time"

import logger "logger"

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
//   initialize        -> server info + capabilities
//   notifications/initialized  -> (no response)
//   tools/list        -> list of available tools
//   tools/call        -> execute a tool
//

MCP_SERVER_NAME :: "shard-mcp"
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

// _daemon_call sends a JSON message to the daemon and returns the response.
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
// Keychain — lazy-loaded, auto-resolves keys for MCP tools
// =============================================================================

_mcp_keychain: Keychain
_mcp_keychain_loaded: bool

// Priority: explicit key param > SHARD_KEY env > keychain entry > keychain wildcard.
_mcp_resolve_key :: proc(args: json.Object, shard_name: string) -> string {
	key := md_json_get_str(args, "key")
	if key != "" do return key

	if env_key, env_ok := os.lookup_env("SHARD_KEY"); env_ok && env_key != "" {
		return env_key
	}

	if !_mcp_keychain_loaded {
		_mcp_keychain, _ = keychain_load()
		_mcp_keychain_loaded = true
	}
	if kc_key, found := keychain_lookup(_mcp_keychain, shard_name); found {
		return kc_key
	}

	return ""
}

// =============================================================================
// Tool definitions
// =============================================================================

Tool_Def :: struct {
	name:        string,
	description: string,
	schema:      string, // JSON string for inputSchema
}

_tools := [?]Tool_Def {
	{
		name = "shard_discover",
		description = "What exists? No params returns a full table of contents (shard names, purposes, thought counts, tags, thought descriptions). Pass shard to get that shard's full info card (catalog + gates + status + thought list). Pass query to filter shards by topic. Pass refresh:true to re-scan disk first.",
		schema = `{"type":"object","properties":{"shard":{"type":"string","description":"Specific shard to inspect (returns catalog + gates + status + thoughts)"},"query":{"type":"string","description":"Filter shards by topic keyword"},"refresh":{"type":"boolean","description":"Re-scan .shards/ directory before returning results"}},"required":[]}`,
	},
	{
		name = "shard_query",
		description = "Universal search. Returns scored results by default, or a markdown document when format=dump. Omit shard for cross-shard search across all shards above gate relevance threshold; provide shard for direct single-shard lookup. Advanced: set depth>0 for wikilink BFS traversal.",
		schema = `{"type":"object","properties":{"query":{"type":"string","description":"Search keywords or question"},"shard":{"type":"string","description":"Specific shard to search. Omit for global cross-shard search."},"format":{"type":"string","description":"Output format: results (default, scored list) or dump (full markdown document)","enum":["results","dump"]},"limit":{"type":"integer","description":"Max results (default 5)"},"threshold":{"type":"number","description":"Gate score threshold for cross-shard selection (0.0-1.0)"},"budget":{"type":"integer","description":"Max content chars in response (0 = unlimited)"},"depth":{"type":"integer","description":"Advanced: link-following depth for wikilink traversal (0 = flat)"}},"required":["query"]}`,
	},
	{
		name = "shard_read",
		description = "Read a specific thought by ID. Returns description and decrypted content. Set chain:true to get the full revision chain instead.",
		schema = `{"type":"object","properties":{"shard":{"type":"string","description":"Shard name"},"id":{"type":"string","description":"Thought ID (32 hex chars)"},"chain":{"type":"boolean","description":"If true, return full revision chain (root to latest)"}},"required":["shard","id"]}`,
	},
	{
		name = "shard_write",
		description = "Store a thought. Omit id to create new. Provide id to update existing (only changed fields needed). Provide revises to create a revision link to an existing thought.",
		schema = `{"type":"object","properties":{"shard":{"type":"string","description":"Shard name"},"description":{"type":"string","description":"Thought description (required for create, optional for update)"},"content":{"type":"string","description":"Thought body content"},"id":{"type":"string","description":"Thought ID to update (omit for create)"},"revises":{"type":"string","description":"Thought ID being revised (creates revision link)"},"agent":{"type":"string","description":"Agent identity"}},"required":["shard"]}`,
	},
	{
		name = "shard_delete",
		description = "Delete a thought by ID.",
		schema = `{"type":"object","properties":{"shard":{"type":"string","description":"Shard name"},"id":{"type":"string","description":"Thought ID"}},"required":["shard","id"]}`,
	},
	{
		name = "shard_remember",
		description = "Create a new shard with catalog and gates in one shot. Ready for writes immediately.",
		schema = `{"type":"object","properties":{"name":{"type":"string","description":"Shard name (used as filename and IPC identifier)"},"purpose":{"type":"string","description":"What this shard is for (free text)"},"tags":{"type":"array","items":{"type":"string"},"description":"Catalog tags for discovery and routing"},"related":{"type":"array","items":{"type":"string"},"description":"Names of related shards"},"positive":{"type":"array","items":{"type":"string"},"description":"Positive gate entries — topics this shard accepts"}},"required":["name","purpose"]}`,
	},
	{
		name = "shard_events",
		description = "Read or emit events. With shard: get pending events for that shard (read mode). With source + event_type: emit an event notification to related shards (write mode).",
		schema = `{"type":"object","properties":{"shard":{"type":"string","description":"Shard name to get events for (read mode)"},"source":{"type":"string","description":"Shard emitting the event (write mode)"},"event_type":{"type":"string","description":"Event type for emit: knowledge_changed, compacted, gates_updated, needs_compaction","enum":["knowledge_changed","compacted","gates_updated","needs_compaction"]},"agent":{"type":"string","description":"Agent identity that caused the event"}},"required":[]}`,
	},
	{
		name = "shard_stale",
		description = "Find stale thoughts that need review. Returns thoughts sorted by staleness (most stale first). Threshold 0.0-1.0 controls minimum staleness to include (default 0.5).",
		schema = `{"type":"object","properties":{"shard":{"type":"string","description":"Shard name"},"threshold":{"type":"number","description":"Minimum staleness score 0.0-1.0 (default 0.5)"}},"required":["shard"]}`,
	},
	{
		name = "shard_feedback",
		description = "Endorse or flag a thought to adjust its relevance score. Endorsing boosts the thought in future search results; flagging reduces it.",
		schema = `{"type":"object","properties":{"shard":{"type":"string","description":"Shard name"},"id":{"type":"string","description":"Thought ID (32 hex chars)"},"feedback":{"type":"string","description":"'endorse' to boost or 'flag' to reduce relevance","enum":["endorse","flag"]}},"required":["shard","id","feedback"]}`,
	},
	{
		name = "shard_fleet",
		description = "Execute multiple shard operations in parallel. Each task targets a shard and operation. Tasks on different shards run concurrently; tasks on the same shard are serialized. Returns aggregated results.",
		schema = `{"type":"object","properties":{"tasks":{"type":"array","items":{"type":"object","properties":{"shard":{"type":"string","description":"Target shard name"},"op":{"type":"string","description":"Operation: query, read, write, stale","enum":["query","read","write","stale"]},"description":{"type":"string","description":"For write ops: thought description"},"content":{"type":"string","description":"For write ops: thought body"},"query":{"type":"string","description":"For query/search ops: search terms"},"id":{"type":"string","description":"For read ops: thought ID"},"agent":{"type":"string","description":"Agent identity"}},"required":["shard","op"]},"description":"Array of tasks to execute in parallel"}},"required":["tasks"]}`,
	},
	{
		name = "shard_compact_suggest",
		description = "Analyze a shard and return compaction suggestions: revision chains to merge, duplicate thoughts to deduplicate, and stale thoughts to prune. Does not modify data — returns proposals for review. Use mode 'lossy' to also suggest pruning stale thoughts.",
		schema = `{"type":"object","properties":{"shard":{"type":"string","description":"Shard name to analyze"},"mode":{"type":"string","description":"Compaction mode: 'lossless' (default) or 'lossy' (also suggests pruning stale thoughts)","enum":["lossless","lossy"]}},"required":["shard"]}`,
	},
	{
		name = "shard_compact",
		description = "Execute compaction on specific thoughts by ID. Moves standalone thoughts from unprocessed to processed. Merges revision chains into a single thought. Use compact_suggest first to get IDs, or provide known IDs directly.",
		schema = `{"type":"object","properties":{"shard":{"type":"string","description":"Shard name"},"ids":{"type":"array","items":{"type":"string"},"description":"Thought IDs to compact (from compact_suggest results)"},"mode":{"type":"string","description":"Compaction mode: 'lossless' (default, preserves all content) or 'lossy' (keeps only latest revision)","enum":["lossless","lossy"]}},"required":["shard","ids"]}`,
	},
	{
		name = "shard_compact_apply",
		description = "One-shot self-compaction: analyzes a shard for revision chains, duplicates, and (in lossy mode) stale thoughts, then automatically compacts all suggested thoughts. Returns what was done. Equivalent to running compact_suggest then compact on the results.",
		schema = `{"type":"object","properties":{"shard":{"type":"string","description":"Shard name to auto-compact"},"mode":{"type":"string","description":"Compaction mode: 'lossless' (default) or 'lossy' (also prunes stale thoughts)","enum":["lossless","lossy"]}},"required":["shard"]}`,
	},
	{
		name = "shard_consumption_log",
		description = "View recent agent activity log. Shows which agents accessed which shards and when. Useful for understanding agent coordination patterns and identifying knowledge gaps (shards with unprocessed thoughts but no recent agent visits).",
		schema = `{"type":"object","properties":{"shard":{"type":"string","description":"Filter by shard name (optional)"},"agent":{"type":"string","description":"Filter by agent name (optional)"},"limit":{"type":"integer","description":"Max records to return (default 50)"}},"required":[]}`,
	},
	{
		name = "shard_cache_write",
		description = "Write context to a named topic cache. Topics are shared across all agents — any agent reading the same topic sees your entry. Oldest entries are evicted when max_bytes is exceeded (FIFO). On write, the entry is also synced to context-mode's session index so it becomes searchable via ctx_search.",
		schema = `{"type":"object","properties":{"topic":{"type":"string","description":"Cache topic name (e.g. 'auth-refactor', 'api-design')"},"content":{"type":"string","description":"Context to cache"},"agent":{"type":"string","description":"Agent identity (optional)"},"max_bytes":{"type":"integer","description":"Max total bytes for this topic (set on first write; 0 = unlimited)"}},"required":["topic","content"]}`,
	},
	{
		name = "shard_cache_read",
		description = "Read all cached entries for a topic as a markdown context document. Returns entries in chronological order with agent and timestamp headers.",
		schema = `{"type":"object","properties":{"topic":{"type":"string","description":"Cache topic name"}},"required":["topic"]}`,
	},
	{
		name = "shard_cache_list",
		description = "List all active cache topics with entry counts and sizes. Use this to discover existing topics before writing, or to select a pre-existing topic.",
		schema = `{"type":"object","properties":{},"required":[]}`,
	},
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
	strings.write_string(&b, json_escape(message))
	strings.write_string(&b, `"}}`)
	return strings.to_string(b)
}

_mcp_tool_result :: proc(id_val: json.Value, text: string, is_error: bool = false) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"jsonrpc":"2.0","id":`)
	_write_json_value(&b, id_val)
	strings.write_string(&b, `,"result":{"content":[{"type":"text","text":"`)
	strings.write_string(&b, json_escape(text))
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
		strings.write_string(b, json_escape(v))
		strings.write_string(b, `"`)
	case:
		strings.write_string(b, "null")
	}
}

// =============================================================================
// MCP message handlers
// =============================================================================

_handle_initialize :: proc(id_val: json.Value) -> string {
	return _mcp_result(
		id_val,
		`{` +
		`"protocolVersion":"` +
		MCP_PROTOCOL_VERSION +
		`",` +
		`"capabilities":{"tools":{}},` +
		`"serverInfo":{"name":"` +
		MCP_SERVER_NAME +
		`","version":"` +
		MCP_SERVER_VERSION +
		`"}` +
		`}`,
	)
}

_handle_tools_list :: proc(id_val: json.Value) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"tools":[`)
	for tool, i in _tools {
		if i > 0 do strings.write_string(&b, `,`)
		strings.write_string(&b, `{"name":"`)
		strings.write_string(&b, tool.name)
		strings.write_string(&b, `","description":"`)
		strings.write_string(&b, json_escape(tool.description))
		strings.write_string(&b, `","inputSchema":`)
		strings.write_string(&b, tool.schema)
		strings.write_string(&b, `}`)
	}
	strings.write_string(&b, `]}`)
	return _mcp_result(id_val, strings.to_string(b))
}

_handle_tools_call :: proc(id_val: json.Value, params: json.Object) -> string {
	tool_name := md_json_get_str(params, "name")
	args, args_ok := md_json_get_obj(params, "arguments")
	if !args_ok {
		return _mcp_error(id_val, -32602, "missing arguments")
	}

	switch tool_name {
	case "shard_discover":
		return _tool_discover(id_val, args)
	case "shard_query":
		return _tool_query(id_val, args)
	case "shard_read":
		return _tool_read(id_val, args)
	case "shard_write":
		return _tool_write(id_val, args)
	case "shard_delete":
		return _tool_delete(id_val, args)
	case "shard_remember":
		return _tool_remember(id_val, args)
	case "shard_events":
		return _tool_events(id_val, args)
	case "shard_stale":
		return _tool_stale(id_val, args)
	case "shard_feedback":
		return _tool_feedback(id_val, args)
	case "shard_fleet":
		return _tool_fleet(id_val, args)
	case "shard_compact_suggest":
		return _tool_compact_suggest(id_val, args)
	case "shard_compact":
		return _tool_compact(id_val, args)
	case "shard_compact_apply":
		return _tool_compact_apply(id_val, args)
	case "shard_consumption_log":
		return _tool_consumption_log(id_val, args)
	case "shard_cache_write":
		return _tool_cache_write(id_val, args)
	case "shard_cache_read":
		return _tool_cache_read(id_val, args)
	case "shard_cache_list":
		return _tool_cache_list(id_val, args)
	case:
		return _mcp_error(id_val, -32602, fmt.tprintf("unknown tool: %s", tool_name))
	}
}

// =============================================================================
// Tool implementations — build JSON messages routed through daemon
// =============================================================================
//
// All shard-specific ops include "name" so the daemon routes them to the
// correct in-process slot. The daemon loads shard blobs on demand.
//

// shard_discover — "What exists?"
//   No params -> digest (full table of contents)
//   shard -> catalog + gates + status + thought list for that shard
//   query -> digest filtered by topic
//   refresh -> re-scan disk first, then return
_tool_discover :: proc(id_val: json.Value, args: json.Object) -> string {
	shard_name := md_json_get_str(args, "shard")
	query := md_json_get_str(args, "query")
	refresh, _ := md_json_get_bool(args, "refresh")

	// If refresh requested, call discover op first to re-scan disk
	if refresh {
		_, disc_ok := _daemon_call(`{"op":"discover"}`)
		if !disc_ok do return _mcp_tool_result(id_val, "error: could not connect to daemon", true)
	}

	// If a specific shard is requested, build a combined info card
	if shard_name != "" {
		result_b := strings.builder_make(context.temp_allocator)

		// Catalog
		cat_resp, cat_ok := _daemon_call(
			fmt.tprintf(`{"op":"catalog","name":"%s"}`, json_escape(shard_name)),
		)
		if cat_ok {
			strings.write_string(&result_b, "## Catalog\n\n")
			strings.write_string(&result_b, cat_resp)
			strings.write_string(&result_b, "\n")
		}

		// Gates
		gates_resp, gates_ok := _daemon_call(
			fmt.tprintf(`{"op":"gates","name":"%s"}`, json_escape(shard_name)),
		)
		if gates_ok {
			strings.write_string(&result_b, "## Gates\n\n")
			strings.write_string(&result_b, gates_resp)
			strings.write_string(&result_b, "\n")
		}

		// Status
		status_resp, status_ok := _daemon_call(
			fmt.tprintf(`{"op":"status","name":"%s"}`, json_escape(shard_name)),
		)
		if status_ok {
			strings.write_string(&result_b, "## Status\n\n")
			strings.write_string(&result_b, status_resp)
			strings.write_string(&result_b, "\n")
		}

		// List (thought IDs)
		list_resp, list_ok := _daemon_call(
			fmt.tprintf(`{"op":"list","name":"%s"}`, json_escape(shard_name)),
		)
		if list_ok {
			strings.write_string(&result_b, "## Thoughts\n\n")
			strings.write_string(&result_b, list_resp)
			strings.write_string(&result_b, "\n")
		}

		// If key available, get thought descriptions via query op
		key := _mcp_resolve_key(args, shard_name)
		if key != "" {
			query_resp, query_ok := _daemon_call(
				fmt.tprintf(
					`{"op":"query","name":"%s","key":"%s","query":"*","thought_count":100}`,
					json_escape(shard_name),
					json_escape(key),
				),
			)
			if query_ok {
				strings.write_string(&result_b, "## Thought Descriptions\n\n")
				strings.write_string(&result_b, query_resp)
				strings.write_string(&result_b, "\n")
			}
		}

		if !cat_ok && !gates_ok && !status_ok && !list_ok {
			return _mcp_tool_result(
				id_val,
				fmt.tprintf("error: could not connect to shard '%s'", shard_name),
				true,
			)
		}

		return _mcp_tool_result(id_val, strings.to_string(result_b))
	}

	// Default: call digest op for full table of contents (optionally filtered)
	key := _mcp_resolve_key(args, "*")
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"op":"digest"`)
	if query != "" {
		strings.write_string(&b, `,"query":"`)
		strings.write_string(&b, json_escape(query))
		strings.write_string(&b, `"`)
	}
	if key != "" {
		strings.write_string(&b, `,"key":"`)
		strings.write_string(&b, json_escape(key))
		strings.write_string(&b, `"`)
	}
	strings.write_string(&b, "}")

	resp, ok := _daemon_call(strings.to_string(b))
	if !ok do return _mcp_tool_result(id_val, "error: could not connect to daemon", true)
	return _mcp_tool_result(id_val, resp)
}

// shard_query — "Find me something"
//   With shard: call query op directly
//   Without shard (default): search all shards via global_query
//   With layer > 0 and no shard: cross-shard layered traversal
_tool_query :: proc(id_val: json.Value, args: json.Object) -> string {
	query := md_json_get_str(args, "query")
	shard_name := md_json_get_str(args, "shard")
	if query == "" do return _mcp_tool_result(id_val, "error: query required", true)
	key := _mcp_resolve_key(args, shard_name != "" ? shard_name : "*")
	if key == "" do return _mcp_tool_result(id_val, "error: no key found (pass key, set SHARD_KEY, or add to .shards/keychain)", true)

	cfg := config_get()
	limit_val := md_json_get_int(args, "limit")
	limit := limit_val > 0 ? limit_val : cfg.default_query_limit
	if limit <= 0 do limit = cfg.default_query_limit

	depth_val := md_json_get_int(args, "depth")
	max_depth := depth_val

	budget_val := md_json_get_int(args, "budget")
	budget := budget_val

	format         := md_json_get_str(args, "format")
	threshold_val, has_threshold := md_json_get_float(args, "threshold")

	layer_val := md_json_get_int(args, "layer")
	layer := layer_val

	// If layer > 0 and no specific shard, use traverse with layer parameter.
	// Note: format=dump is not forwarded to traverse — traverse does not support it.
	// Callers using layer>0 always receive scored Wire_Results regardless of format.
	if layer > 0 && shard_name == "" && max_depth <= 0 {
		b := strings.builder_make(context.temp_allocator)
		fmt.sbprintf(&b, `{"op":"traverse","query":"%s"`, json_escape(query))
		if key != "" {
			strings.write_string(&b, `,"key":"`)
			strings.write_string(&b, json_escape(key))
			strings.write_string(&b, `"`)
		}
		fmt.sbprintf(&b, `,"layer":%d,"max_branches":%d`, layer, limit > 0 ? limit : 5)
		if limit > 0 do fmt.sbprintf(&b, `,"thought_count":%d`, limit)
		if budget > 0 do fmt.sbprintf(&b, `,"budget":%d`, budget)
		strings.write_string(&b, "}")

		resp, ok := _daemon_call(strings.to_string(b))
		if !ok do return _mcp_tool_result(id_val, "error: could not connect to daemon", true)
		return _mcp_tool_result(id_val, resp)
	}

	// If a specific shard is given and no cross-link traversal, query directly
	if shard_name != "" && max_depth <= 0 {
		b2 := strings.builder_make(context.temp_allocator)
		fmt.sbprintf(
			&b2,
			`{"op":"query","name":"%s","key":"%s","query":"%s","thought_count":%d`,
			json_escape(shard_name),
			json_escape(key),
			json_escape(query),
			limit,
		)
		if budget > 0 do fmt.sbprintf(&b2, `,"budget":%d`, budget)
		if format != "" do fmt.sbprintf(&b2, `,"format":"%s"`, json_escape(format))
		strings.write_string(&b2, "}")
		msg := strings.to_string(b2)
		resp, ok := _daemon_call(msg)
		if !ok do return _mcp_tool_result(id_val, fmt.tprintf("error: could not query shard '%s'", shard_name), true)
		return _mcp_tool_result(id_val, resp)
	}

	// No shard specified: search all shards via global_query
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `{"op":"global_query","query":"%s"`, json_escape(query))
	if key != "" {
		strings.write_string(&b, `,"key":"`)
		strings.write_string(&b, json_escape(key))
		strings.write_string(&b, `"`)
	}
	if limit > 0 do fmt.sbprintf(&b, `,"limit":%d`, limit)
	if budget > 0 do fmt.sbprintf(&b, `,"budget":%d`, budget)
	if format != "" do fmt.sbprintf(&b, `,"format":"%s"`, json_escape(format))
	if has_threshold do fmt.sbprintf(&b, `,"threshold":%f`, threshold_val)
	strings.write_string(&b, "}")

	resp, ok := _daemon_call(strings.to_string(b))
	if !ok do return _mcp_tool_result(id_val, "error: could not connect to daemon", true)
	return _mcp_tool_result(id_val, resp)
}

// shard_read — "Give me this specific thing"
//   Normal: call read op
//   With chain: call revisions op
_tool_read :: proc(id_val: json.Value, args: json.Object) -> string {
	shard_name := md_json_get_str(args, "shard")
	thought_id := md_json_get_str(args, "id")
	if shard_name == "" do return _mcp_tool_result(id_val, "error: shard name required", true)
	if thought_id == "" do return _mcp_tool_result(id_val, "error: thought id required", true)
	key := _mcp_resolve_key(args, shard_name)
	if key == "" do return _mcp_tool_result(id_val, "error: no key found (pass key, set SHARD_KEY, or add to .shards/keychain)", true)

	chain, _ := md_json_get_bool(args, "chain")
	if chain {
		msg := fmt.tprintf(
			`{"op":"revisions","name":"%s","key":"%s","id":"%s"}`,
			json_escape(shard_name),
			json_escape(key),
			json_escape(thought_id),
		)
		resp, ok := _daemon_call(msg)
		if !ok do return _mcp_tool_result(id_val, fmt.tprintf("error: could not connect to shard '%s'", shard_name), true)
		return _mcp_tool_result(id_val, resp)
	}

	msg := fmt.tprintf(
		`{"op":"read","name":"%s","key":"%s","id":"%s"}`,
		json_escape(shard_name),
		json_escape(key),
		json_escape(thought_id),
	)
	resp, ok := _daemon_call(msg)
	if !ok do return _mcp_tool_result(id_val, fmt.tprintf("error: could not connect to shard '%s'", shard_name), true)
	return _mcp_tool_result(id_val, resp)
}

// shard_write — "Store this"
//   With id (update): call update op
//   Without id, with revises: call write op with revises
//   Without id, without revises: call write op (create)
_tool_write :: proc(id_val: json.Value, args: json.Object) -> string {
	shard_name := md_json_get_str(args, "shard")
	desc := md_json_get_str(args, "description")
	content := md_json_get_str(args, "content")
	thought_id := md_json_get_str(args, "id")
	revises := md_json_get_str(args, "revises")
	agent := md_json_get_str(args, "agent")
	if shard_name == "" do return _mcp_tool_result(id_val, "error: shard name required", true)
	key := _mcp_resolve_key(args, shard_name)
	if key == "" do return _mcp_tool_result(id_val, "error: no key found (pass key, set SHARD_KEY, or add to .shards/keychain)", true)

	// Update mode: id is provided
	if thought_id != "" {
		b := strings.builder_make(context.temp_allocator)
		fmt.sbprintf(
			&b,
			`{"op":"update","name":"%s","key":"%s","id":"%s"`,
			json_escape(shard_name),
			json_escape(key),
			json_escape(thought_id),
		)
		if desc != "" {
			strings.write_string(&b, `,"description":"`)
			strings.write_string(&b, json_escape(desc))
			strings.write_string(&b, `"`)
		}
		if content != "" {
			strings.write_string(&b, `,"content":"`)
			strings.write_string(&b, json_escape(content))
			strings.write_string(&b, `"`)
		}
		if agent != "" {
			strings.write_string(&b, `,"agent":"`)
			strings.write_string(&b, json_escape(agent))
			strings.write_string(&b, `"`)
		}
		strings.write_string(&b, "}")
		resp, ok := _daemon_call(strings.to_string(b))
		if !ok do return _mcp_tool_result(id_val, fmt.tprintf("error: could not connect to shard '%s'", shard_name), true)
		return _mcp_tool_result(id_val, resp)
	}

	// Create mode: no id
	if desc == "" do return _mcp_tool_result(id_val, "error: description required for new thoughts", true)

	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(
		&b,
		`{"op":"write","name":"%s","key":"%s","description":"%s"`,
		json_escape(shard_name),
		json_escape(key),
		json_escape(desc),
	)
	if content != "" {
		strings.write_string(&b, `,"content":"`)
		strings.write_string(&b, json_escape(content))
		strings.write_string(&b, `"`)
	}
	if revises != "" {
		strings.write_string(&b, `,"revises":"`)
		strings.write_string(&b, json_escape(revises))
		strings.write_string(&b, `"`)
	}
	if agent != "" {
		strings.write_string(&b, `,"agent":"`)
		strings.write_string(&b, json_escape(agent))
		strings.write_string(&b, `"`)
	}
	strings.write_string(&b, "}")

	resp, ok := _daemon_call(strings.to_string(b))
	if !ok do return _mcp_tool_result(id_val, fmt.tprintf("error: could not connect to shard '%s'", shard_name), true)
	return _mcp_tool_result(id_val, resp)
}

// shard_delete — "Remove this"
_tool_delete :: proc(id_val: json.Value, args: json.Object) -> string {
	shard_name := md_json_get_str(args, "shard")
	thought_id := md_json_get_str(args, "id")
	if shard_name == "" do return _mcp_tool_result(id_val, "error: shard name required", true)
	if thought_id == "" do return _mcp_tool_result(id_val, "error: thought id required", true)
	key := _mcp_resolve_key(args, shard_name)
	if key == "" do return _mcp_tool_result(id_val, "error: no key found (pass key, set SHARD_KEY, or add to .shards/keychain)", true)

	msg := fmt.tprintf(
		`{"op":"delete","name":"%s","key":"%s","id":"%s"}`,
		json_escape(shard_name),
		json_escape(key),
		json_escape(thought_id),
	)
	resp, ok := _daemon_call(msg)
	if !ok do return _mcp_tool_result(id_val, fmt.tprintf("error: could not connect to shard '%s'", shard_name), true)
	return _mcp_tool_result(id_val, resp)
}

// shard_remember — "Create a new category"
_tool_remember :: proc(id_val: json.Value, args: json.Object) -> string {
	name := md_json_get_str(args, "name")
	purpose := md_json_get_str(args, "purpose")
	if name == "" do return _mcp_tool_result(id_val, "error: name required", true)
	if purpose == "" do return _mcp_tool_result(id_val, "error: purpose required", true)

	tags := md_json_get_str_array(args, "tags")
	related := md_json_get_str_array(args, "related")
	positive := md_json_get_str_array(args, "positive")

	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(
		&b,
		`{"op":"remember","name":"%s","purpose":"%s"`,
		json_escape(name),
		json_escape(purpose),
	)
	if tags != nil && len(tags) > 0 {
		strings.write_string(&b, `,"tags":["`)
		for t, i in tags {
			if i > 0 do strings.write_string(&b, ",\"")
			strings.write_string(&b, json_escape(t))
			strings.write_string(&b, `"`)
		}
		strings.write_string(&b, "]")
	}
	if related != nil && len(related) > 0 {
		strings.write_string(&b, `,"related":["`)
		for r, i in related {
			if i > 0 do strings.write_string(&b, ",\"")
			strings.write_string(&b, json_escape(r))
			strings.write_string(&b, `"`)
		}
		strings.write_string(&b, "]")
	}
	if positive != nil && len(positive) > 0 {
		strings.write_string(&b, `,"items":["`)
		for p, i in positive {
			if i > 0 do strings.write_string(&b, ",\"")
			strings.write_string(&b, json_escape(p))
			strings.write_string(&b, `"`)
		}
		strings.write_string(&b, "]")
	}
	strings.write_string(&b, "}")

	resp, ok := _daemon_call(strings.to_string(b))
	if !ok do return _mcp_tool_result(id_val, "error: could not connect to daemon", true)
	return _mcp_tool_result(id_val, resp)
}

// shard_consumption_log — view recent agent activity across all shards (daemon-level, no key needed)
_tool_consumption_log :: proc(id_val: json.Value, args: json.Object) -> string {
	shard_name := md_json_get_str(args, "shard")
	agent := md_json_get_str(args, "agent")
	limit := md_json_get_int(args, "limit")

	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"op":"consumption_log"`)
	if shard_name != "" {
		strings.write_string(&b, `,"name":"`)
		strings.write_string(&b, json_escape(shard_name))
		strings.write_string(&b, `"`)
	}
	if agent != "" {
		strings.write_string(&b, `,"agent":"`)
		strings.write_string(&b, json_escape(agent))
		strings.write_string(&b, `"`)
	}
	if limit > 0 do fmt.sbprintf(&b, `,"limit":%d`, limit)
	strings.write_string(&b, "}")

	resp, ok := _daemon_call(strings.to_string(b))
	if !ok do return _mcp_tool_result(id_val, "error: could not connect to daemon", true)
	return _mcp_tool_result(id_val, resp)
}

_tool_cache_write :: proc(id_val: json.Value, args: json.Object) -> string {
	topic := md_json_get_str(args, "topic")
	content := md_json_get_str(args, "content")
	agent := md_json_get_str(args, "agent")
	max_bytes := md_json_get_int(args, "max_bytes")
	if topic == "" do return _mcp_tool_result(id_val, "error: topic required", true)
	if content == "" do return _mcp_tool_result(id_val, "error: content required", true)

	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"op":"cache","action":"write","topic":"`)
	strings.write_string(&b, json_escape(topic))
	strings.write_string(&b, `","content":"`)
	strings.write_string(&b, json_escape(content))
	strings.write_string(&b, `"`)
	if agent != "" {
		strings.write_string(&b, `,"agent":"`)
		strings.write_string(&b, json_escape(agent))
		strings.write_string(&b, `"`)
	}
	if max_bytes > 0 do fmt.sbprintf(&b, `,"max_bytes":%d`, max_bytes)
	strings.write_string(&b, "}")

	resp, ok := _daemon_call(strings.to_string(b))
	if !ok do return _mcp_tool_result(id_val, "error: could not connect to daemon", true)
	return _mcp_tool_result(id_val, resp)
}

_tool_cache_read :: proc(id_val: json.Value, args: json.Object) -> string {
	topic := md_json_get_str(args, "topic")
	if topic == "" do return _mcp_tool_result(id_val, "error: topic required", true)

	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"op":"cache","action":"read","topic":"`)
	strings.write_string(&b, json_escape(topic))
	strings.write_string(&b, `"}`)

	resp, ok := _daemon_call(strings.to_string(b))
	if !ok do return _mcp_tool_result(id_val, "error: could not connect to daemon", true)
	return _mcp_tool_result(id_val, resp)
}

_tool_cache_list :: proc(id_val: json.Value, args: json.Object) -> string {
	resp, ok := _daemon_call(`{"op":"cache","action":"list"}`)
	if !ok do return _mcp_tool_result(id_val, "error: could not connect to daemon", true)
	return _mcp_tool_result(id_val, resp)
}

// shard_events — "What changed?"
//   With source + event_type: call notify op (emit mode)
//   With shard only: call events op (read mode)
_tool_events :: proc(id_val: json.Value, args: json.Object) -> string {
	source := md_json_get_str(args, "source")
	event_type := md_json_get_str(args, "event_type")
	shard_name := md_json_get_str(args, "shard")
	agent := md_json_get_str(args, "agent")

	// Emit mode: source + event_type provided
	if source != "" && event_type != "" {
		b := strings.builder_make(context.temp_allocator)
		fmt.sbprintf(
			&b,
			`{"op":"notify","source":"%s","event_type":"%s"`,
			json_escape(source),
			json_escape(event_type),
		)
		if agent != "" {
			strings.write_string(&b, `,"agent":"`)
			strings.write_string(&b, json_escape(agent))
			strings.write_string(&b, `"`)
		}
		strings.write_string(&b, "}")

		resp, ok := _daemon_call(strings.to_string(b))
		if !ok do return _mcp_tool_result(id_val, "error: could not connect to daemon", true)
		return _mcp_tool_result(id_val, resp)
	}

	// Read mode: shard provided
	if shard_name != "" {
		msg := fmt.tprintf(`{"op":"events","name":"%s"}`, json_escape(shard_name))
		resp, ok := _daemon_call(msg)
		if !ok do return _mcp_tool_result(id_val, "error: could not connect to daemon", true)
		return _mcp_tool_result(id_val, resp)
	}

	return _mcp_tool_result(
		id_val,
		"error: provide 'shard' for read mode or 'source' + 'event_type' for emit mode",
		true,
	)
}

// shard_stale — "What needs review?"
_tool_stale :: proc(id_val: json.Value, args: json.Object) -> string {
	shard_name := md_json_get_str(args, "shard")
	if shard_name == "" do return _mcp_tool_result(id_val, "error: shard name required", true)
	key := _mcp_resolve_key(args, shard_name)
	if key == "" do return _mcp_tool_result(id_val, "error: no key found (pass key, set SHARD_KEY, or add to .shards/keychain)", true)

	threshold_f64, has_threshold := md_json_get_float(args, "threshold")

	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(
		&b,
		`{"op":"stale","name":"%s","key":"%s"`,
		json_escape(shard_name),
		json_escape(key),
	)
	if has_threshold {
		fmt.sbprintf(&b, `,"freshness_weight":%v`, threshold_f64)
	}
	strings.write_string(&b, "}")

	resp, ok := _daemon_call(strings.to_string(b))
	if !ok do return _mcp_tool_result(id_val, fmt.tprintf("error: could not query shard '%s'", shard_name), true)
	return _mcp_tool_result(id_val, resp)
}

// shard_feedback — "This thought is useful/not useful"
_tool_feedback :: proc(id_val: json.Value, args: json.Object) -> string {
	shard_name := md_json_get_str(args, "shard")
	thought_id := md_json_get_str(args, "id")
	feedback := md_json_get_str(args, "feedback")
	if shard_name == "" do return _mcp_tool_result(id_val, "error: shard name required", true)
	if thought_id == "" do return _mcp_tool_result(id_val, "error: thought id required", true)
	if feedback != "endorse" && feedback != "flag" do return _mcp_tool_result(id_val, "error: feedback must be 'endorse' or 'flag'", true)
	key := _mcp_resolve_key(args, shard_name)
	if key == "" do return _mcp_tool_result(id_val, "error: no key found (pass key, set SHARD_KEY, or add to .shards/keychain)", true)

	msg := fmt.tprintf(
		`{"op":"feedback","name":"%s","key":"%s","id":"%s","feedback":"%s"}`,
		json_escape(shard_name),
		json_escape(key),
		json_escape(thought_id),
		json_escape(feedback),
	)
	resp, ok := _daemon_call(msg)
	if !ok do return _mcp_tool_result(id_val, fmt.tprintf("error: could not connect to shard '%s'", shard_name), true)
	return _mcp_tool_result(id_val, resp)
}

// shard_fleet — "Do many things at once"
_tool_fleet :: proc(id_val: json.Value, args: json.Object) -> string {
	tasks_val, tasks_ok := args["tasks"]
	if !tasks_ok do return _mcp_tool_result(id_val, "error: tasks required", true)

	tasks_arr, is_arr := tasks_val.(json.Array)
	if !is_arr do return _mcp_tool_result(id_val, "error: tasks must be an array", true)
	if len(tasks_arr) == 0 do return _mcp_tool_result(id_val, "error: tasks array is empty", true)

	// Build JSON fleet request with tasks array
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"op":"fleet","tasks":[`)

	for item, i in tasks_arr {
		if i > 0 do strings.write_string(&b, ",")
		obj, is_obj := item.(json.Object)
		if !is_obj do continue

		shard_name := md_json_get_str(obj, "shard")
		op := md_json_get_str(obj, "op")
		key := _mcp_resolve_key(obj, shard_name)
		desc := md_json_get_str(obj, "description")
		content := md_json_get_str(obj, "content")
		query := md_json_get_str(obj, "query")
		thought_id := md_json_get_str(obj, "id")
		agent := md_json_get_str(obj, "agent")

		strings.write_string(&b, `{"name":"`)
		strings.write_string(&b, json_escape(shard_name))
		strings.write_string(&b, `","op":"`)
		strings.write_string(&b, json_escape(op))
		strings.write_string(&b, `"`)
		if key != "" {
			strings.write_string(&b, `,"key":"`)
			strings.write_string(&b, json_escape(key))
			strings.write_string(&b, `"`)
		}
		if desc != "" {
			strings.write_string(&b, `,"description":"`)
			strings.write_string(&b, json_escape(desc))
			strings.write_string(&b, `"`)
		}
		if content != "" {
			strings.write_string(&b, `,"content":"`)
			strings.write_string(&b, json_escape(content))
			strings.write_string(&b, `"`)
		}
		if query != "" {
			strings.write_string(&b, `,"query":"`)
			strings.write_string(&b, json_escape(query))
			strings.write_string(&b, `"`)
		}
		if thought_id != "" {
			strings.write_string(&b, `,"id":"`)
			strings.write_string(&b, json_escape(thought_id))
			strings.write_string(&b, `"`)
		}
		if agent != "" {
			strings.write_string(&b, `,"agent":"`)
			strings.write_string(&b, json_escape(agent))
			strings.write_string(&b, `"`)
		}
		strings.write_string(&b, `}`)
	}
	strings.write_string(&b, "]}")

	resp, ok := _daemon_call(strings.to_string(b))
	if !ok do return _mcp_tool_result(id_val, "error: could not connect to daemon", true)
	return _mcp_tool_result(id_val, resp)
}

// shard_compact_suggest — analyze a shard and return compaction suggestions
_tool_compact_suggest :: proc(id_val: json.Value, args: json.Object) -> string {
	shard_name := md_json_get_str(args, "shard")
	if shard_name == "" do return _mcp_tool_result(id_val, "error: shard name required", true)

	key := _mcp_resolve_key(args, shard_name)
	mode := md_json_get_str(args, "mode")

	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(
		&b,
		`{"op":"compact_suggest","name":"%s","key":"%s"`,
		json_escape(shard_name),
		json_escape(key),
	)
	if mode != "" {
		strings.write_string(&b, `,"mode":"`)
		strings.write_string(&b, json_escape(mode))
		strings.write_string(&b, `"`)
	}
	strings.write_string(&b, "}")

	resp, ok := _daemon_call(strings.to_string(b))
	if !ok do return _mcp_tool_result(id_val, "error: could not connect to daemon", true)
	return _mcp_tool_result(id_val, resp)
}

// shard_compact — execute compaction on specific thought IDs
_tool_compact :: proc(id_val: json.Value, args: json.Object) -> string {
	shard_name := md_json_get_str(args, "shard")
	if shard_name == "" do return _mcp_tool_result(id_val, "error: shard name required", true)

	key := _mcp_resolve_key(args, shard_name)
	mode := md_json_get_str(args, "mode")

	// Extract IDs array
	ids_val, ids_ok := args["ids"]
	if !ids_ok do return _mcp_tool_result(id_val, "error: ids required", true)
	ids_arr, is_arr := ids_val.(json.Array)
	if !is_arr || len(ids_arr) == 0 do return _mcp_tool_result(id_val, "error: ids must be a non-empty array", true)

	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(
		&b,
		`{"op":"compact","name":"%s","key":"%s"`,
		json_escape(shard_name),
		json_escape(key),
	)
	if mode != "" {
		strings.write_string(&b, `,"mode":"`)
		strings.write_string(&b, json_escape(mode))
		strings.write_string(&b, `"`)
	}
	strings.write_string(&b, `,"ids":[`)
	first_id := true
	for v in ids_arr {
		id_str, is_str := v.(json.String)
		if is_str {
			if !first_id do strings.write_string(&b, ",")
			strings.write_string(&b, `"`)
			strings.write_string(&b, json_escape(id_str))
			strings.write_string(&b, `"`)
			first_id = false
		}
	}
	strings.write_string(&b, "]}")

	resp, ok := _daemon_call(strings.to_string(b))
	if !ok do return _mcp_tool_result(id_val, "error: could not connect to daemon", true)
	return _mcp_tool_result(id_val, resp)
}

// shard_compact_apply — one-shot self-compaction: suggest then compact
_tool_compact_apply :: proc(id_val: json.Value, args: json.Object) -> string {
	shard_name := md_json_get_str(args, "shard")
	if shard_name == "" do return _mcp_tool_result(id_val, "error: shard name required", true)

	key := _mcp_resolve_key(args, shard_name)
	mode := md_json_get_str(args, "mode")

	// Step 1: Run compact_suggest
	suggest_b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(
		&suggest_b,
		`{"op":"compact_suggest","name":"%s","key":"%s"`,
		json_escape(shard_name),
		json_escape(key),
	)
	if mode != "" {
		strings.write_string(&suggest_b, `,"mode":"`)
		strings.write_string(&suggest_b, json_escape(mode))
		strings.write_string(&suggest_b, `"`)
	}
	strings.write_string(&suggest_b, "}")

	suggest_resp, suggest_ok := _daemon_call(strings.to_string(suggest_b))
	if !suggest_ok do return _mcp_tool_result(id_val, "error: could not connect to daemon for suggest", true)

	// Parse the suggestion response to extract IDs
	// Suggestions come back as JSON with `suggestions` array containing objects with `ids` arrays
	all_ids := make([dynamic]string, context.temp_allocator)
	_extract_suggestion_ids(suggest_resp, &all_ids)

	if len(all_ids) == 0 {
		return _mcp_tool_result(id_val, suggest_resp) // nothing to compact, return the suggest response
	}

	// Step 2: Run compact with all collected IDs
	compact_b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(
		&compact_b,
		`{"op":"compact","name":"%s","key":"%s"`,
		json_escape(shard_name),
		json_escape(key),
	)
	if mode != "" {
		strings.write_string(&compact_b, `,"mode":"`)
		strings.write_string(&compact_b, json_escape(mode))
		strings.write_string(&compact_b, `"`)
	}
	strings.write_string(&compact_b, `,"ids":[`)
	for id, i in all_ids {
		if i > 0 do strings.write_string(&compact_b, ",")
		strings.write_string(&compact_b, `"`)
		strings.write_string(&compact_b, json_escape(id))
		strings.write_string(&compact_b, `"`)
	}
	strings.write_string(&compact_b, "]}")

	compact_resp, compact_ok := _daemon_call(strings.to_string(compact_b))
	if !compact_ok do return _mcp_tool_result(id_val, "error: could not connect to daemon for compact", true)

	// Return a combined result: what was suggested + what was compacted
	result_b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&result_b, "Suggestions found: %d\n\n## Suggestions\n\n", len(all_ids))
	strings.write_string(&result_b, suggest_resp)
	strings.write_string(&result_b, "\n## Compaction Result\n\n")
	strings.write_string(&result_b, compact_resp)

	return _mcp_tool_result(id_val, strings.to_string(result_b))
}

// _extract_suggestion_ids parses a compact_suggest JSON response and collects all thought IDs.
// JSON structure: {"suggestions":[{"ids":["id1","id2"],...},...]}
_extract_suggestion_ids :: proc(resp: string, ids: ^[dynamic]string) {
	parsed, err := json.parse(transmute([]u8)resp, allocator = context.temp_allocator)
	if err != nil do return
	defer json.destroy_value(parsed, context.temp_allocator)

	root_obj, is_obj := parsed.(json.Object)
	if !is_obj do return

	suggestions_val, has_suggestions := root_obj["suggestions"]
	if !has_suggestions do return

	suggestions_arr, is_arr := suggestions_val.(json.Array)
	if !is_arr do return

	for suggestion in suggestions_arr {
		s_obj, s_is_obj := suggestion.(json.Object)
		if !s_is_obj do continue
		ids_val, has_ids := s_obj["ids"]
		if !has_ids do continue
		ids_arr, ids_is_arr := ids_val.(json.Array)
		if !ids_is_arr do continue
		for id_val in ids_arr {
			id_str, is_str := id_val.(json.String)
			if !is_str do continue
			if len(id_str) != 32 do continue
			// Dedup
			found := false
			for existing in ids^ {
				if existing == string(id_str) {found = true; break}
			}
			if !found do append(ids, string(id_str))
		}
	}
}

// Extract a float field from a json.Object
md_json_get_float :: proc(obj: json.Object, key: string) -> (f64, bool) {
	val, ok := obj[key]
	if !ok do return 0, false
	#partial switch v in val {
	case f64:
		return v, true
	case i64:
		return f64(v), true
	}
	return 0, false
}


// =============================================================================
// Daemon auto-start — spawns the daemon if it isn't running
// =============================================================================

// _daemon_auto_start checks if the daemon is reachable. If not, spawns it as
// a background process using the current executable with the "daemon" argument.
// Returns true if the daemon is reachable (was already running or started successfully).
@(private)
_daemon_auto_start :: proc() -> bool {
	// Quick probe: try to connect
	probe, ok := ipc_connect(DAEMON_NAME)
	if ok {
		ipc_close_conn(probe)
		logger.debug("daemon already running")
		return true
	}

	// Daemon not running — spawn it
	logger.info("daemon not running, starting it...")

	exe_path := os.args[0]
	process, err := os2.process_start(os2.Process_Desc{command = {exe_path, "daemon"}})
	if err != nil {
		logger.errf("failed to start daemon: %v", err)
		return false
	}

	// Detach — we don't wait for the daemon to exit
	close_err := os2.process_close(process)
	if close_err != nil {
		logger.warnf("could not detach daemon handle: %v", close_err)
	}

	// Wait for the daemon to come up (ipc_connect already retries internally,
	// but we do a brief sleep first to let the daemon create the IPC endpoint)
	time.sleep(500 * time.Millisecond)

	probe2, ok2 := ipc_connect(DAEMON_NAME)
	if ok2 {
		ipc_close_conn(probe2)
		logger.info("daemon started successfully")
		return true
	}

	logger.warn("daemon started but not yet reachable — will retry on first tool call")
	return true // process was spawned; _daemon_get will retry on first use
}

// =============================================================================
// Main MCP loop — reads JSON-RPC from stdin, dispatches, writes to stdout
// =============================================================================

run_mcp :: proc() {
	logger.info("starting MCP server on stdio")

	// Load config
	config_load()

	// Auto-start daemon if not running
	_daemon_auto_start()

	// Read lines from stdin
	buf := make([]u8, 65536) // 64KB read buffer
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
	logger.info("MCP server stopped")
}

_process_jsonrpc :: proc(line: string) -> string {
	// Parse JSON — allocate into temp so the tree is freed at end of message cycle
	parsed, parse_err := json.parse(transmute([]u8)line, allocator = context.temp_allocator)
	if parse_err != nil {
		return _mcp_error(json.Value(nil), -32700, "parse error")
	}
	defer json.destroy_value(parsed, context.temp_allocator)

	obj, is_obj := parsed.(json.Object)
	if !is_obj {
		return _mcp_error(json.Value(nil), -32600, "invalid request")
	}

	method := md_json_get_str(obj, "method")
	id_val, has_id := obj["id"]

	// Notifications have no id — no response expected
	if !has_id || method == "notifications/initialized" {
		logger.debugf("notification: %s", method)
		return ""
	}

	switch method {
	case "initialize":
		return _handle_initialize(id_val)
	case "tools/list":
		return _handle_tools_list(id_val)
	case "tools/call":
		params, params_ok := md_json_get_obj(obj, "params")
		if !params_ok {
			return _mcp_error(id_val, -32602, "missing params")
		}
		return _handle_tools_call(id_val, params)
	case:
		return _mcp_error(id_val, -32601, fmt.tprintf("method not found: %s", method))
	}
}
