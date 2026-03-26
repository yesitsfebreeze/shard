package shard

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "transport"

PROCESS_PROTOCOL_VERSION :: "2024-11-05"
PROCESS_SERVER_NAME :: "shard"

Process_Tool_Callback :: proc(id_val: json.Value, args: json.Object) -> string

Process_Tool_Descriptor :: struct {
	name:              string,
	handler:           Process_Tool_Callback,
	http_method:       string,
	http_path:         string,
	http_path_prefix:  bool,
}

PROCESS_TOOLS :: [20]Process_Tool_Descriptor {
	{"shard_write", process_tool_write, "POST", "/write", false},
	{"shard_read", process_tool_read, "POST", "/read", false},
	{"shard_query", process_tool_query, "POST", "/query", false},
	{"shard_meta_single", process_tool_meta_single, "", "", false},
	{"shard_meta_batch", process_tool_meta_batch, "", "", false},
	{"shard_info", process_tool_info, "GET", "/info", false},
	{"shard_list", process_tool_shard_list, "GET", "/list", false},
	{"cache_set", process_tool_cache_set, "POST", "/cache", false},
	{"cache_get", process_tool_cache_get, "GET", "/cache/", true},
	{"cache_delete", process_tool_cache_delete, "DELETE", "/cache", false},
	{"cache_list", process_tool_cache_list, "GET", "/cache", false},
	{"build_context", process_tool_build_context, "POST", "/context", false},
	{"fleet_query", process_tool_fleet_query, "POST", "/fleet/query", false},
	{"create_shard", process_tool_create_shard, "POST", "/shard", false},
	{"vec_search", process_tool_vec_search, "POST", "/vec/search", false},
	{"shard_ask", process_tool_shard_ask, "POST", "/ask", false},
	{"shard_ingest", process_tool_shard_ingest, "POST", "/ingest", false},
	{"fleet_ask", process_tool_fleet_ask, "POST", "/fleet/ask", false},
	{"compact", process_tool_compact, "POST", "/compact", false},
	{"shard_write_batch", process_tool_write_batch, "", "", false},
}

process_http_tool_resolver :: proc(method: string, path: string) -> (string, string, bool) {
	for tool in PROCESS_TOOLS {
		if len(tool.http_method) == 0 || len(tool.http_path) == 0 do continue
		if method != tool.http_method do continue

		if tool.http_path_prefix {
			if !strings.has_prefix(path, tool.http_path) do continue
			key := path[len(tool.http_path):]
			if len(key) == 0 do continue
			if strings.contains(key, "/") do continue
			return tool.name, key, true
		}

		if path == tool.http_path {
			return tool.name, "", true
		}
	}

	return "", "", false
}

process_tool_by_name :: proc(tool_name: string) -> (Process_Tool_Descriptor, bool) {
	for tool in PROCESS_TOOLS {
		if tool.name == tool_name do return tool, true
	}
	return Process_Tool_Descriptor{}, false
}

process_tool_compact :: proc(id_val: json.Value, args: json.Object) -> string {
	_ = args
	if compact() {
		return process_tool_result(
			id_val,
			fmt.aprintf(
				"compacted: %d processed",
				len(state.blob.shard.processed),
				allocator = runtime_alloc,
			),
		)
	}
	return process_tool_result(id_val, "compact failed", true)
}

process_request :: proc(line: string) -> string {
	parsed, parse_err := json.parse(transmute([]u8)line, allocator = runtime_alloc)
	if parse_err != nil do return process_error(json.Null{}, -32700, "parse error")

	if arr, is_arr := parsed.(json.Array); is_arr {
		if len(arr) == 0 do return process_error(json.Null{}, -32600, "invalid request")
		responses := strings.builder_make(runtime_alloc)
		wrote := false
		for item in arr {
			obj, ok := item.(json.Object)
			if !ok {
				resp := process_error(json.Null{}, -32600, "invalid request")
				if wrote do strings.write_string(&responses, ",")
				strings.write_string(&responses, resp)
				wrote = true
				continue
			}

			resp := process_request_object(obj)
			if len(resp) == 0 do continue
			if wrote do strings.write_string(&responses, ",")
			strings.write_string(&responses, resp)
			wrote = true
		}

		if !wrote do return ""
		return fmt.aprintf("[%s]", strings.to_string(responses), allocator = runtime_alloc)
	}

	obj, is_obj := parsed.(json.Object)
	if !is_obj do return process_error(json.Null{}, -32600, "invalid request")
	return process_request_object(obj)
}

process_stdio :: proc() {
	index_write(state.shard_id, state.exe_path)
	transport.Transport_Stdio_Run(process_request, runtime_alloc)
}

process_line_normalize_response :: proc(resp: string) -> string {
	return transport.Transport_Line_Normalize_Response(resp, runtime_alloc)
}

process_request_object :: proc(obj: json.Object) -> string {
	method_val, has_method := obj["method"]
	if !has_method do return process_error(json.Null{}, -32600, "missing method")
	method, is_str := method_val.(json.String)
	if !is_str do return process_error(json.Null{}, -32600, "method must be string")

	id_val, has_id := obj["id"]
	if !has_id do return ""

	switch method {
	case "initialize":
		return process_initialize(id_val)
	case "tools/list":
		return process_tools_list(id_val)
	case "tools/call":
		params, params_ok := obj["params"].(json.Object)
		if !params_ok do return process_error(id_val, -32602, "missing params")
		return process_tools_call(id_val, params)
	case:
		return process_error(id_val, -32601, "method not found")
	}
}

process_result :: proc(id_val: json.Value, result_json: string) -> string {
	b := strings.builder_make(runtime_alloc)
	strings.write_string(&b, `{"jsonrpc":"2.0","id":`)
	process_write_value(&b, id_val)
	strings.write_string(&b, `,"result":`)
	strings.write_string(&b, result_json)
	strings.write_string(&b, `}`)
	return strings.to_string(b)
}

process_error :: proc(id_val: json.Value, code: int, message: string) -> string {
	b := strings.builder_make(runtime_alloc)
	strings.write_string(&b, `{"jsonrpc":"2.0","id":`)
	process_write_value(&b, id_val)
	strings.write_string(&b, `,"error":{"code":`)
	fmt.sbprintf(&b, `%d`, code)
	strings.write_string(&b, `,"message":"`)
	strings.write_string(&b, process_json_escape(message))
	strings.write_string(&b, `"}}`)
	return strings.to_string(b)
}

process_tool_result :: proc(id_val: json.Value, text: string, is_error: bool = false) -> string {
	b := strings.builder_make(runtime_alloc)
	strings.write_string(&b, `{"jsonrpc":"2.0","id":`)
	process_write_value(&b, id_val)
	strings.write_string(&b, `,"result":{"content":[{"type":"text","text":"`)
	strings.write_string(&b, process_json_escape(text))
	strings.write_string(&b, `"}]`)
	if is_error do strings.write_string(&b, `,"isError":true`)
	strings.write_string(&b, `}}`)
	return strings.to_string(b)
}

process_write_value :: proc(b: ^strings.Builder, val: json.Value) {
	switch v in val {
	case json.Null:
		strings.write_string(b, "null")
	case json.Integer:
		fmt.sbprintf(b, "%d", v)
	case json.Float:
		fmt.sbprintf(b, "%f", v)
	case json.String:
		strings.write_string(b, `"`)
		strings.write_string(b, process_json_escape(v))
		strings.write_string(b, `"`)
	case json.Boolean:
		strings.write_string(b, "true" if v else "false")
	case json.Array, json.Object:
		strings.write_string(b, "null")
	}
}

process_json_escape :: proc(s: string) -> string {
	return json_escape(s, runtime_alloc)
}

process_initialize :: proc(id_val: json.Value) -> string {
	b := strings.builder_make(runtime_alloc)
	strings.write_string(&b, `{"protocolVersion":"`)
	strings.write_string(&b, PROCESS_PROTOCOL_VERSION)
	strings.write_string(&b, `","capabilities":{"tools":{}}`)
	strings.write_string(&b, `,"serverInfo":{"name":"`)
	strings.write_string(&b, PROCESS_SERVER_NAME)
	strings.write_string(&b, `","version":"`)
	strings.write_string(&b, VERSION)
	strings.write_string(&b, `"}}`)
	return process_result(id_val, strings.to_string(b))
}

PROCESS_TOOLS_JSON :: string(#load("help/tools.json"))

process_tools_list :: proc(id_val: json.Value) -> string {
	b := strings.builder_make(runtime_alloc)
	strings.write_string(&b, `{"tools":`)
	strings.write_string(&b, PROCESS_TOOLS_JSON)
	strings.write_string(&b, `}`)
	return process_result(
		id_val,
		strings.to_string(b),
	)
}

Process_Meta_Response :: struct {
	body:   string,
	status: string,
	ok:     bool,
}

meta_single_response :: proc(bucket: int, shard_id: string) -> Process_Meta_Response {
	_, ok := meta_bucket_label(bucket)
	if !ok {
		return Process_Meta_Response {
			body = json_error_payload("invalid_bucket", "bucket must be integer >= 0", bucket, runtime_alloc),
			status = "400 Bad Request",
			ok = false,
		}
	}
	item, found := meta_item_for_shard(shard_id, bucket)
	if !found {
		return Process_Meta_Response {
			body = json_error_payload("shard_not_found", "shard not found", -1, runtime_alloc),
			status = "404 Not Found",
			ok = false,
		}
	}
	encoded, err := json.marshal(item, allocator = runtime_alloc)
	if err != nil {
		return Process_Meta_Response {
			body = json_error_payload("invalid_request", "failed to encode meta response", -1, runtime_alloc),
			status = "500 Internal Server Error",
			ok = false,
		}
	}
	return Process_Meta_Response {body = string(encoded), status = "200 OK", ok = true}
}

meta_batch_response_ids :: proc(bucket: int, ids: [dynamic]string) -> Process_Meta_Response {
	window, ok := meta_bucket_label(bucket)
	if !ok {
		return Process_Meta_Response {
			body = json_error_payload("invalid_bucket", "bucket must be integer >= 0", bucket, runtime_alloc),
			status = "400 Bad Request",
			ok = false,
		}
	}

	items := make([dynamic]Meta_Item, 0, runtime_alloc)
	missing := make([dynamic]string, 0, runtime_alloc)
	for id in ids {
		single, found := meta_item_for_shard(id, bucket)
		if !found {
			append(&missing, strings.clone(id, runtime_alloc))
			continue
		}
		append(&items, Meta_Item {
			id = single.id,
			name = single.name,
			thought_count = single.thought_count,
			linked_shard_ids = single.linked_shard_ids,
			stats = single.stats,
		})
	}

	resp := Meta_Batch_Response {
		bucket = bucket,
		window = window,
		items = items,
		missing_ids = missing,
	}

	encoded, err := json.marshal(resp, allocator = runtime_alloc)
	if err != nil {
		return Process_Meta_Response {
			body = json_error_payload("invalid_request", "failed to encode meta batch response", -1, runtime_alloc),
			status = "500 Internal Server Error",
			ok = false,
		}
	}

	return Process_Meta_Response {body = string(encoded), status = "200 OK", ok = true}
}

process_http_tool_handler :: proc(tool_name: string, body: string) -> string {
	args := body if len(body) > 0 else "{}"
	rpc := strings.builder_make(runtime_alloc)
	strings.write_string(&rpc, `{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"`)
	strings.write_string(&rpc, process_json_escape(tool_name))
	strings.write_string(&rpc, `","arguments":`)
	strings.write_string(&rpc, args)
	strings.write_string(&rpc, `}}`)
	return process_request(strings.to_string(rpc))
}

process_http_meta_single_handler :: proc(bucket: int, shard_id: string) -> (string, string, bool) {
	resp := meta_single_response(bucket, shard_id)
	return resp.body, resp.status, resp.ok
}

process_http_meta_batch_handler :: proc(bucket: int, ids: [dynamic]string) -> (string, string, bool) {
	resp := meta_batch_response_ids(bucket, ids)
	return resp.body, resp.status, resp.ok
}

process_tools_call :: proc(id_val: json.Value, params: json.Object) -> string {
	name_val, has_name := params["name"]
	if !has_name do return process_error(id_val, -32602, "missing tool name")
	tool_name, is_str := name_val.(json.String)
	if !is_str do return process_error(id_val, -32602, "tool name must be string")

	args, has_args := params["arguments"].(json.Object)
	if !has_args do args = json.Object{}

	tool, found := process_tool_by_name(string(tool_name))
	if !found do return process_error(id_val, -32602, "unknown tool")
	if tool.name == "vec_search" && len(args) == 0 {
		args = json.Object{}
	}
	return tool.handler(id_val, args)
}

process_tool_write :: proc(id_val: json.Value, args: json.Object) -> string {
	desc, _ := args["description"].(json.String)
	content, _ := args["content"].(json.String)
	agent, _ := args["agent"].(json.String)

	if len(desc) == 0 do return process_tool_result(id_val, "missing description", true)
	if len(content) == 0 do return process_tool_result(id_val, "missing content", true)

	id, ok := write_thought(desc, content, agent)
	if !ok do return process_tool_result(id_val, "write failed (check key/gates)", true)

	return process_tool_result(
		id_val,
		fmt.aprintf("wrote thought %s", thought_id_to_hex(id), allocator = runtime_alloc),
	)
}

process_tool_read :: proc(id_val: json.Value, args: json.Object) -> string {
	id_hex, _ := args["id"].(json.String)
	if len(id_hex) == 0 do return process_tool_result(id_val, "missing id", true)

	tid, ok := hex_to_thought_id(id_hex)
	if !ok do return process_tool_result(id_val, "invalid id (must be 32 hex chars)", true)

	desc, content, read_ok := read_thought_core(tid, true)
	if !read_ok do return process_tool_result(id_val, "thought not found or decrypt failed", true)
	meta_record_access()

	return process_tool_result(
		id_val,
		fmt.aprintf("# %s\n\n%s", desc, content, allocator = runtime_alloc),
	)
}

process_tool_query :: proc(id_val: json.Value, args: json.Object) -> string {
	keyword, _ := args["keyword"].(json.String)

	target, _ := args["shard"].(json.String)
	results: []Query_Result
	if len(target) > 0 && target != state.shard_id {
		results = query_peer(target, keyword)
	} else {
		results = query_thoughts(keyword)
	}
	if len(results) == 0 do return process_tool_result(id_val, "no matches")
	meta_record_access()

	b := strings.builder_make(runtime_alloc)
	fmt.sbprintf(&b, "%d results:\n", len(results))
	for r in results {
		fmt.sbprintf(&b, "- %s: %s\n", thought_id_to_hex(r.id), r.description)
	}
	return process_tool_result(id_val, strings.to_string(b))
}

process_tool_meta_single :: proc(id_val: json.Value, args: json.Object) -> string {
	bucket_val, has_bucket := args["bucket"]
	if !has_bucket do return process_tool_result(id_val, "missing bucket", true)
	bucket, ok := parse_non_negative_int_from_json(bucket_val)
	if !ok do return process_tool_result(id_val, "invalid bucket", true)

	shard_id, has_shard := args["shard"].(json.String)
	if !has_shard || len(shard_id) == 0 do return process_tool_result(id_val, "missing shard", true)

	resp := meta_single_response(bucket, shard_id)
	if !resp.ok do return process_tool_result(id_val, resp.body, true)
	return process_tool_result(id_val, resp.body)
}

process_tool_meta_batch :: proc(id_val: json.Value, args: json.Object) -> string {
	bucket_val, has_bucket := args["bucket"]
	if !has_bucket do return process_tool_result(id_val, "missing bucket", true)
	bucket, ok := parse_non_negative_int_from_json(bucket_val)
	if !ok do return process_tool_result(id_val, "invalid bucket", true)

	ids_val, has_ids := args["ids"]
	if !has_ids {
		resp := meta_batch_response_ids(bucket, make([dynamic]string, 0, runtime_alloc))
		if !resp.ok do return process_tool_result(id_val, resp.body, true)
		return process_tool_result(id_val, resp.body)
	}

	ids, ids_ok := parse_json_string_array(ids_val, runtime_alloc)
	if !ids_ok {
		return process_tool_result(id_val, "ids must be an array of strings", true)
	}

	resp := meta_batch_response_ids(bucket, ids)
	if !resp.ok do return process_tool_result(id_val, resp.body, true)
	return process_tool_result(id_val, resp.body)
}

process_tool_info :: proc(id_val: json.Value, args: json.Object) -> string {
	_ = args
	b := strings.builder_make(runtime_alloc)
	fmt.sbprintf(&b, "shard v%s\n", VERSION)
	fmt.sbprintf(&b, "id: %s\n", state.shard_id)
	fmt.sbprintf(&b, "exe: %s\n", state.exe_path)
	fmt.sbprintf(&b, "has data: %v\n", state.blob.has_data)
	if state.blob.has_data {
		s := &state.blob.shard
		fmt.sbprintf(&b, "catalog: %s\n", s.catalog.name)
		fmt.sbprintf(
			&b,
			"thoughts: %d processed, %d unprocessed\n",
			len(s.processed),
			len(s.unprocessed),
		)
	}
	fmt.sbprintf(&b, "has key: %v\n", state.has_key)
	peers := index_list()
	fmt.sbprintf(&b, "known shards: %d\n", len(peers))
	return process_tool_result(id_val, strings.to_string(b))
}

process_tool_shard_list :: proc(id_val: json.Value, args: json.Object) -> string {
	_ = args
	peers := index_list()
	if len(peers) == 0 do return process_tool_result(id_val, "no shards registered")
	index_sort_tree(peers)

	b := strings.builder_make(runtime_alloc)
	fmt.sbprintf(&b, "%d shards:\n", len(peers))
	for peer in peers {
		prefix := index_depth_prefix(peer.depth)
		label := peer.shard_id
		if len(prefix) > 0 do label = strings.concatenate({prefix, peer.shard_id}, runtime_alloc)
		raw, ok := os.read_entire_file(peer.exe_path, runtime_alloc)
		if !ok {
			fmt.sbprintf(&b, "- %s (%s, unreachable: %s)\n", label, peer.tree_path, peer.exe_path)
			continue
		}
		blob := load_blob_from_raw(raw)
		if blob.has_data {
			s := &blob.shard
			name := s.catalog.name if len(s.catalog.name) > 0 else peer.shard_id
			fmt.sbprintf(
				&b,
				"- %s: %s (%d thoughts, path=%s)\n",
				label,
				name,
				len(s.processed) + len(s.unprocessed),
				peer.tree_path,
			)
		} else {
			fmt.sbprintf(&b, "- %s (empty, path=%s)\n", label, peer.tree_path)
		}
	}
	return process_tool_result(id_val, strings.to_string(b))
}

process_tool_cache_set :: proc(id_val: json.Value, args: json.Object) -> string {
	key, _ := args["key"].(json.String)
	value, _ := args["value"].(json.String)
	author, _ := args["author"].(json.String)
	expires, _ := args["expires"].(json.String)
	if len(key) == 0 do return process_tool_result(id_val, "missing key", true)
	entry := Cache_Entry {
		value   = strings.clone(value, runtime_alloc),
		author  = strings.clone(author, runtime_alloc),
		expires = strings.clone(expires, runtime_alloc),
	}
	state.topic_cache[strings.clone(key, runtime_alloc)] = entry
	cache_save_key(key, entry)
	return process_tool_result(id_val, "cache entry set")
}

process_tool_cache_get :: proc(id_val: json.Value, args: json.Object) -> string {
	key, _ := args["key"].(json.String)
	if len(key) == 0 do return process_tool_result(id_val, "missing key", true)
	cache_load()
	entry, ok := state.topic_cache[key]
	if !ok do return process_tool_result(id_val, "not found", true)
	return process_tool_result(id_val, entry.value)
}

process_tool_cache_delete :: proc(id_val: json.Value, args: json.Object) -> string {
	key, _ := args["key"].(json.String)
	if len(key) == 0 do return process_tool_result(id_val, "missing key", true)
	cache_delete_key(key)
	return process_tool_result(id_val, "cache entry deleted")
}

process_tool_cache_list :: proc(id_val: json.Value, args: json.Object) -> string {
	_ = args
	cache_load()
	if len(state.topic_cache) == 0 do return process_tool_result(id_val, "cache empty")
	b := strings.builder_make(runtime_alloc)
	for key, entry in state.topic_cache {
		label := cache_safe_label(entry)
		opaque_key := cache_display_key(key)
		if len(entry.author) > 0 {
			fmt.sbprintf(&b, "%s | %s: %s [%s]\n", opaque_key, label, entry.value, entry.author)
		} else {
			fmt.sbprintf(&b, "%s | %s: %s\n", opaque_key, label, entry.value)
		}
	}
	return process_tool_result(id_val, strings.to_string(b))
}

process_tool_build_context :: proc(id_val: json.Value, args: json.Object) -> string {
	task, _ := args["task"].(json.String)
	if len(task) == 0 do return process_tool_result(id_val, "missing task", true)
	agent, _ := args["agent"].(json.String)
	format, _ := args["format"].(json.String)

	packet := build_context_packet(task, agent)
	if len(packet.included_thought_ids) == 0 && len(packet.summary) == 0 {
		return process_tool_result(id_val, "no context available")
	}

	if format == "packet" {
		return process_tool_result(id_val, context_packet_to_json(packet))
	}

	ctx := context_packet_render(packet)
	if len(ctx) == 0 do return process_tool_result(id_val, "no context available")
	meta_record_access()
	return process_tool_result(id_val, ctx)
}

process_tool_fleet_query :: proc(id_val: json.Value, args: json.Object) -> string {
	keyword, _ := args["keyword"].(json.String)
	if len(keyword) == 0 do return process_tool_result(id_val, "missing keyword", true)

	results := fleet_query(keyword)
	if len(results) == 0 do return process_tool_result(id_val, "no peers available")

	b := strings.builder_make(runtime_alloc)
	for r in results {
		if r.ok {
			fmt.sbprintf(&b, "%s: %s\n", r.shard_id, r.response)
		} else {
			fmt.sbprintf(&b, "%s: (unreachable)\n", r.shard_id)
		}
	}
	return process_tool_result(id_val, strings.to_string(b))
}

process_tool_create_shard :: proc(id_val: json.Value, args: json.Object) -> string {
	name, _ := args["name"].(json.String)
	purpose, _ := args["purpose"].(json.String)
	if len(name) == 0 do return process_tool_result(id_val, "missing name", true)
	if !create_shard(name, purpose) do return process_tool_result(id_val, "failed to create shard", true)
	return process_tool_result(
		id_val,
		fmt.aprintf("created shard '%s'", name, allocator = runtime_alloc),
	)
}

process_tool_vec_search :: proc(id_val: json.Value, args: json.Object) -> string {
	query, _ := args["query"].(json.String)
	if len(query) == 0 do return process_tool_result(id_val, "missing query", true)
	if !state.has_embed do return process_tool_result(id_val, "no embedding model configured (set EMBED_MODEL)", true)

	top_k := 5
	if k, ok := args["top_k"].(json.Integer); ok && k > 0 {
		top_k = int(k)
	}

	results := vec_search(query, top_k)
	if len(results) == 0 do return process_tool_result(id_val, "no matches")

	b := strings.builder_make(runtime_alloc)
	fmt.sbprintf(&b, "%d results:\n", len(results))
	for r in results {
		fmt.sbprintf(&b, "- %s: %s (score: %d)\n", thought_id_to_hex(r.id), r.description, r.score)
	}
	return process_tool_result(id_val, strings.to_string(b))
}

process_tool_shard_ask :: proc(id_val: json.Value, args: json.Object) -> string {
	question, _ := args["question"].(json.String)
	if len(question) == 0 do return process_tool_result(id_val, "missing question", true)
	agent, _ := args["agent"].(json.String)
	target, _ := args["shard"].(json.String)
	if len(target) > 0 && target != state.shard_id {
		answer, ok := ask_peer(target, question)
		if !ok do return process_tool_result(id_val, answer, true)
		return process_tool_result(
			id_val,
			fmt.aprintf("[%s] %s", target, answer, allocator = runtime_alloc),
		)
	}
	answer, ok := shard_ask(question, agent)
	if !ok do return process_tool_result(id_val, answer, true)
	return process_tool_result(id_val, answer)
}

process_tool_shard_ingest :: proc(id_val: json.Value, args: json.Object) -> string {
	data, _ := args["data"].(json.String)
	if len(data) == 0 do return process_tool_result(id_val, "missing data", true)
	format, _ := args["format"].(json.String)

	results, ok := shard_ingest(data, format)
	if !ok do return process_tool_result(id_val, "ingest failed (check LLM config)", true)

	b := strings.builder_make(runtime_alloc)
	stored := 0
	routed := 0

	self_name := state.blob.shard.catalog.name
	for r in results {
		is_self :=
			len(r.route_to) == 0 ||
			r.route_to == state.shard_id ||
			r.route_to == self_name ||
			strings.to_lower(r.route_to, runtime_alloc) == strings.to_lower(self_name, runtime_alloc)

		if is_self {
			id, write_ok := write_thought(r.description, r.content)
			if write_ok {
				stored += 1
				fmt.sbprintf(&b, "stored %s: %s\n", thought_id_to_hex(id), r.description)
			}
		} else {
			_, peer_ok := load_peer_blob(r.route_to)
			if peer_ok {
				routed += 1
				fmt.sbprintf(&b, "routed to %s: %s\n", r.route_to, r.description)
			} else {
				id, write_ok := write_thought(r.description, r.content)
				if write_ok {
					stored += 1
					fmt.sbprintf(
						&b,
						"stored %s (no peer %s): %s\n",
						thought_id_to_hex(id),
						r.route_to,
						r.description,
					)
				}
			}
		}
	}

	fmt.sbprintf(&b, "\n%d stored, %d routed", stored, routed)
	return process_tool_result(id_val, strings.to_string(b))
}

process_tool_fleet_ask :: proc(id_val: json.Value, args: json.Object) -> string {
	question, _ := args["question"].(json.String)
	if len(question) == 0 do return process_tool_result(id_val, "missing question", true)
	answer := fleet_ask(question)
	return process_tool_result(id_val, answer)
}

process_tool_write_batch :: proc(id_val: json.Value, args: json.Object) -> string {
	thoughts_json, _ := args["thoughts"].(json.String)
	if len(thoughts_json) == 0 do return process_tool_result(id_val, "missing thoughts", true)

	parsed, err := json.parse(transmute([]u8)thoughts_json, allocator = runtime_alloc)
	if err != nil do return process_tool_result(id_val, "invalid JSON array", true)
	arr, arr_ok := parsed.(json.Array)
	if !arr_ok do return process_tool_result(id_val, "expected JSON array", true)

	s := &state.blob.shard
	count := 0
	for item in arr {
		obj, obj_ok := item.(json.Object)
		if !obj_ok do continue
		desc, _ := obj["description"].(json.String)
		content, _ := obj["content"].(json.String)
		if len(desc) == 0 do continue

		if thought_exists(desc) do continue

		id := new_thought_id()
		body_blob, seal_blob, trust := thought_encrypt(state.key, id, desc, content)
		t := Thought {
			id         = id,
			trust      = trust,
			seal_blob  = seal_blob,
			body_blob  = body_blob,
			created_at = now_rfc3339(),
		}

		buf: [dynamic]u8
		buf.allocator = runtime_alloc
		thought_serialize(&buf, &t)

		new_unprocessed: [dynamic][]u8
		new_unprocessed.allocator = runtime_alloc
		for entry in s.unprocessed do append(&new_unprocessed, entry)
		append(&new_unprocessed, buf[:])
		s.unprocessed = new_unprocessed[:]
		count += 1
	}

	if count == 0 do return process_tool_result(id_val, "no new thoughts (all duplicates or empty)")
	if !state.blob.has_data do state.blob.has_data = true

	if len(s.catalog.name) == 0 && count > 0 {
		first_obj, _ := arr[0].(json.Object)
		first_desc, _ := first_obj["description"].(json.String)
		s.catalog.name = first_desc
		s.catalog.purpose = first_desc
		s.catalog.created = now_rfc3339()
		state.shard_id = resolve_shard_id()
	}

	if !blob_write_self() do return process_tool_result(id_val, "persist failed", true)
	index_write(state.shard_id, state.exe_path)
	return process_tool_result(
		id_val,
		fmt.aprintf("wrote %d thoughts in one persist", count, allocator = runtime_alloc),
	)
}
