package shard

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:os/os2"
import "core:strings"
import "core:time"

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
		schema = `{"type":"object","properties":{"query":{"type":"string","description":"Search keywords or question"},"shard":{"type":"string","description":"Specific shard to search. Omit for global cross-shard search."},"format":{"type":"string","description":"Output format: results (default, scored list) or dump (full markdown document)","enum":["results","dump"]},"limit":{"type":"integer","description":"Max results (default 5)"},"threshold":{"type":"number","description":"Gate score threshold for cross-shard selection (0.0-1.0)"},"budget":{"type":"integer","description":"Max content chars in response (0 = unlimited)"},"depth":{"type":"integer","description":"Advanced: link-following depth for wikilink traversal (0 = flat)"},"mode":{"type":"string","description":"Search mode: omit for default scored results, 'fulltext' for windowed content body search","enum":["fulltext"]},"context_lines":{"type":"integer","description":"Lines of context above/below each hit in fulltext mode (0 = use config default)"}},"required":["query"]}`,
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
	write_json_value(&b, id_val)
	strings.write_string(&b, `,"result":`)
	strings.write_string(&b, result_json)
	strings.write_string(&b, `}`)
	return strings.to_string(b)
}

_mcp_error :: proc(id_val: json.Value, code: int, message: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"jsonrpc":"2.0","id":`)
	write_json_value(&b, id_val)
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
	write_json_value(&b, id_val)
	strings.write_string(&b, `,"result":{"content":[{"type":"text","text":"`)
	strings.write_string(&b, json_escape(text))
	strings.write_string(&b, `"}]`)
	if is_error {
		strings.write_string(&b, `,"isError":true`)
	}
	strings.write_string(&b, `}}`)
	return strings.to_string(b)
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
		debug("daemon already running")
		return true
	}

	// Daemon not running — spawn it
	info("daemon not running, starting it...")

	exe_path := os.args[0]
	process, err := os2.process_start(os2.Process_Desc{command = {exe_path, "daemon"}})
	if err != nil {
		errf("failed to start daemon: %v", err)
		return false
	}

	// Detach — we don't wait for the daemon to exit
	close_err := os2.process_close(process)
	if close_err != nil {
		warnf("could not detach daemon handle: %v", close_err)
	}

	// Wait for the daemon to come up (ipc_connect already retries internally,
	// but we do a brief sleep first to let the daemon create the IPC endpoint)
	time.sleep(500 * time.Millisecond)

	probe2, ok2 := ipc_connect(DAEMON_NAME)
	if ok2 {
		ipc_close_conn(probe2)
		info("daemon started successfully")
		return true
	}

	warn("daemon started but not yet reachable — will retry on first tool call")
	return true // process was spawned; _daemon_get will retry on first use
}

// =============================================================================
// Main MCP loop — reads JSON-RPC from stdin, dispatches, writes to stdout
// =============================================================================

run_mcp :: proc() {
	info("starting MCP server on stdio")

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
	info("MCP server stopped")
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
		debugf("notification: %s", method)
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
