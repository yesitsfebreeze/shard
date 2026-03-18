package shard

import "core:encoding/json"
import "core:fmt"
import "core:strings"

// =============================================================================
// MCP tool handlers — one proc per shard_* tool
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

	mode_val          := md_json_get_str(args, "mode")
	context_lines_val := md_json_get_int(args, "context_lines")

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
		if mode_val != "" do fmt.sbprintf(&b2, `,"mode":"%s"`, json_escape(mode_val))
		if context_lines_val > 0 do fmt.sbprintf(&b2, `,"context_lines":%d`, context_lines_val)
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
	if mode_val != "" do fmt.sbprintf(&b, `,"mode":"%s"`, json_escape(mode_val))
	if context_lines_val > 0 do fmt.sbprintf(&b, `,"context_lines":%d`, context_lines_val)
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
