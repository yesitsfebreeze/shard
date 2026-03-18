#+feature dynamic-literals
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

// _ipc_build serialises a map[string]any to a JSON object string.
// Supported value types: string, int, bool, f64, []string, []any (nested maps).
_ipc_build :: proc(m: map[string]any) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '{')
	first := true
	for k, v in m {
		if !first do strings.write_byte(&b, ',')
		first = false
		strings.write_byte(&b, '"')
		json_escape_to(&b, k)
		strings.write_string(&b, `":`)
		_ipc_write_any(&b, v)
	}
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}

_ipc_write_any :: proc(b: ^strings.Builder, v: any) {
	switch val in v {
	case string:
		strings.write_byte(b, '"')
		json_escape_to(b, val)
		strings.write_byte(b, '"')
	case int:
		strings.write_string(b, fmt.tprintf("%d", val))
	case bool:
		strings.write_string(b, val ? "true" : "false")
	case f64:
		strings.write_string(b, fmt.tprintf("%v", val))
	case []string:
		strings.write_byte(b, '[')
		for s, i in val {
			if i > 0 do strings.write_byte(b, ',')
			strings.write_byte(b, '"')
			json_escape_to(b, s)
			strings.write_byte(b, '"')
		}
		strings.write_byte(b, ']')
	case map[string]any:
		strings.write_string(b, _ipc_build(val))
	case []map[string]any:
		strings.write_byte(b, '[')
		for item, i in val {
			if i > 0 do strings.write_byte(b, ',')
			strings.write_string(b, _ipc_build(item))
		}
		strings.write_byte(b, ']')
	case:
		strings.write_string(b, "null")
	}
}

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
		m := map[string]any{"op" = "discover"}
		_, disc_ok := _daemon_call(_ipc_build(m))
		if !disc_ok do return _mcp_tool_result(id_val, "error: could not connect to daemon", true)
	}

	// If a specific shard is requested, build a combined info card
	if shard_name != "" {
		result_b := strings.builder_make(context.temp_allocator)

		// Catalog
		cat_resp, cat_ok := _daemon_call(_ipc_build(map[string]any{"op" = "catalog", "name" = shard_name}))
		if cat_ok {
			strings.write_string(&result_b, "## Catalog\n\n")
			strings.write_string(&result_b, cat_resp)
			strings.write_string(&result_b, "\n")
		}

		// Gates
		gates_resp, gates_ok := _daemon_call(_ipc_build(map[string]any{"op" = "gates", "name" = shard_name}))
		if gates_ok {
			strings.write_string(&result_b, "## Gates\n\n")
			strings.write_string(&result_b, gates_resp)
			strings.write_string(&result_b, "\n")
		}

		// Status
		status_resp, status_ok := _daemon_call(_ipc_build(map[string]any{"op" = "status", "name" = shard_name}))
		if status_ok {
			strings.write_string(&result_b, "## Status\n\n")
			strings.write_string(&result_b, status_resp)
			strings.write_string(&result_b, "\n")
		}

		// List (thought IDs)
		list_resp, list_ok := _daemon_call(_ipc_build(map[string]any{"op" = "list", "name" = shard_name}))
		if list_ok {
			strings.write_string(&result_b, "## Thoughts\n\n")
			strings.write_string(&result_b, list_resp)
			strings.write_string(&result_b, "\n")
		}

		// If key available, get thought descriptions via query op
		key := _mcp_resolve_key(args, shard_name)
		if key != "" {
			m := map[string]any {
				"op"            = "query",
				"name"          = shard_name,
				"key"           = key,
				"query"         = "*",
				"thought_count" = 100,
			}
			query_resp, query_ok := _daemon_call(_ipc_build(m))
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
	m := map[string]any{"op" = "digest"}
	if query != "" do m["query"] = query
	if key != "" do m["key"] = key

	resp, ok := _daemon_call(_ipc_build(m))
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

	format             := md_json_get_str(args, "format")
	threshold_val, has_threshold := md_json_get_float(args, "threshold")

	layer_val := md_json_get_int(args, "layer")
	layer := layer_val

	mode_val           := md_json_get_str(args, "mode")
	context_lines_val  := md_json_get_int(args, "context_lines")

	// traverse
	if layer > 0 && shard_name == "" && max_depth <= 0 {
		m := map[string]any {
			"op"          = "traverse",
			"query"       = query,
			"key"         = key,
			"layer"       = layer,
			"max_branches" = limit > 0 ? limit : 5,
		}
		if limit > 0 do m["thought_count"] = limit
		if budget > 0 do m["budget"] = budget

		resp, ok := _daemon_call(_ipc_build(m))
		if !ok do return _mcp_tool_result(id_val, "error: could not connect to daemon", true)
		return _mcp_tool_result(id_val, resp)
	}

	// single-shard query
	if shard_name != "" && max_depth <= 0 {
		m := map[string]any {
			"op"            = "query",
			"name"          = shard_name,
			"key"           = key,
			"query"         = query,
			"thought_count" = limit,
		}
		if budget > 0 do m["budget"] = budget
		if format != "" do m["format"] = format
		if mode_val != "" do m["mode"] = mode_val
		if context_lines_val > 0 do m["context_lines"] = context_lines_val

		resp, ok := _daemon_call(_ipc_build(m))
		if !ok do return _mcp_tool_result(id_val, fmt.tprintf("error: could not query shard '%s'", shard_name), true)
		return _mcp_tool_result(id_val, resp)
	}

	// global query
	m := map[string]any {
		"op"    = "global_query",
		"query" = query,
		"key"   = key,
	}
	if limit > 0 do m["limit"] = limit
	if budget > 0 do m["budget"] = budget
	if format != "" do m["format"] = format
	if has_threshold do m["threshold"] = threshold_val
	if mode_val != "" do m["mode"] = mode_val
	if context_lines_val > 0 do m["context_lines"] = context_lines_val

	resp, ok := _daemon_call(_ipc_build(m))
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
	op := chain ? "revisions" : "read"
	m := map[string]any {
		"op"   = op,
		"name" = shard_name,
		"key"  = key,
		"id"   = thought_id,
	}
	resp, ok := _daemon_call(_ipc_build(m))
	if !ok do return _mcp_tool_result(id_val, fmt.tprintf("error: could not connect to shard '%s'", shard_name), true)
	return _mcp_tool_result(id_val, resp)
}

// shard_write — "Store this"
//   With id (update): call update op
//   Without id, with revises: call write op with revises
//   Without id, without revises: call write op (create)
_tool_write :: proc(id_val: json.Value, args: json.Object) -> string {
	shard_name := md_json_get_str(args, "shard")
	desc       := md_json_get_str(args, "description")
	content    := md_json_get_str(args, "content")
	thought_id := md_json_get_str(args, "id")
	revises    := md_json_get_str(args, "revises")
	agent      := md_json_get_str(args, "agent")
	if shard_name == "" do return _mcp_tool_result(id_val, "error: shard name required", true)
	key := _mcp_resolve_key(args, shard_name)
	if key == "" do return _mcp_tool_result(id_val, "error: no key found (pass key, set SHARD_KEY, or add to .shards/keychain)", true)

	// Update mode
	if thought_id != "" {
		m := map[string]any {
			"op"   = "update",
			"name" = shard_name,
			"key"  = key,
			"id"   = thought_id,
		}
		if desc != "" do m["description"] = desc
		if content != "" do m["content"] = content
		if agent != "" do m["agent"] = agent
		resp, ok := _daemon_call(_ipc_build(m))
		if !ok do return _mcp_tool_result(id_val, fmt.tprintf("error: could not connect to shard '%s'", shard_name), true)
		return _mcp_tool_result(id_val, resp)
	}

	// Create mode
	if desc == "" do return _mcp_tool_result(id_val, "error: description required for new thoughts", true)

	m := map[string]any {
		"op"          = "write",
		"name"        = shard_name,
		"key"         = key,
		"description" = desc,
	}
	if content != "" do m["content"] = content
	if revises != "" do m["revises"] = revises
	if agent != "" do m["agent"] = agent

	resp, ok := _daemon_call(_ipc_build(m))
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

	m := map[string]any {
		"op"   = "delete",
		"name" = shard_name,
		"key"  = key,
		"id"   = thought_id,
	}
	resp, ok := _daemon_call(_ipc_build(m))
	if !ok do return _mcp_tool_result(id_val, fmt.tprintf("error: could not connect to shard '%s'", shard_name), true)
	return _mcp_tool_result(id_val, resp)
}

// shard_remember — "Create a new category"
_tool_remember :: proc(id_val: json.Value, args: json.Object) -> string {
	name    := md_json_get_str(args, "name")
	purpose := md_json_get_str(args, "purpose")
	if name == "" do return _mcp_tool_result(id_val, "error: name required", true)
	if purpose == "" do return _mcp_tool_result(id_val, "error: purpose required", true)

	tags     := md_json_get_str_array(args, "tags")
	related  := md_json_get_str_array(args, "related")
	positive := md_json_get_str_array(args, "positive")

	m := map[string]any {
		"op"      = "remember",
		"name"    = name,
		"purpose" = purpose,
	}
	if tags != nil && len(tags) > 0 do m["tags"] = tags
	if related != nil && len(related) > 0 do m["related"] = related
	if positive != nil && len(positive) > 0 do m["items"] = positive

	resp, ok := _daemon_call(_ipc_build(m))
	if !ok do return _mcp_tool_result(id_val, "error: could not connect to daemon", true)
	return _mcp_tool_result(id_val, resp)
}

// shard_consumption_log — view recent agent activity across all shards (daemon-level, no key needed)
_tool_consumption_log :: proc(id_val: json.Value, args: json.Object) -> string {
	shard_name := md_json_get_str(args, "shard")
	agent      := md_json_get_str(args, "agent")
	limit      := md_json_get_int(args, "limit")

	m := map[string]any{"op" = "consumption_log"}
	if shard_name != "" do m["name"] = shard_name
	if agent != "" do m["agent"] = agent
	if limit > 0 do m["limit"] = limit

	resp, ok := _daemon_call(_ipc_build(m))
	if !ok do return _mcp_tool_result(id_val, "error: could not connect to daemon", true)
	return _mcp_tool_result(id_val, resp)
}

_tool_cache_write :: proc(id_val: json.Value, args: json.Object) -> string {
	topic     := md_json_get_str(args, "topic")
	content   := md_json_get_str(args, "content")
	agent     := md_json_get_str(args, "agent")
	max_bytes := md_json_get_int(args, "max_bytes")
	if topic == "" do return _mcp_tool_result(id_val, "error: topic required", true)
	if content == "" do return _mcp_tool_result(id_val, "error: content required", true)

	m := map[string]any {
		"op"      = "cache",
		"action"  = "write",
		"topic"   = topic,
		"content" = content,
	}
	if agent != "" do m["agent"] = agent
	if max_bytes > 0 do m["max_bytes"] = max_bytes

	resp, ok := _daemon_call(_ipc_build(m))
	if !ok do return _mcp_tool_result(id_val, "error: could not connect to daemon", true)
	return _mcp_tool_result(id_val, resp)
}

_tool_cache_read :: proc(id_val: json.Value, args: json.Object) -> string {
	topic := md_json_get_str(args, "topic")
	if topic == "" do return _mcp_tool_result(id_val, "error: topic required", true)

	m := map[string]any{"op" = "cache", "action" = "read", "topic" = topic}
	resp, ok := _daemon_call(_ipc_build(m))
	if !ok do return _mcp_tool_result(id_val, "error: could not connect to daemon", true)
	return _mcp_tool_result(id_val, resp)
}

_tool_cache_list :: proc(id_val: json.Value, args: json.Object) -> string {
	m := map[string]any{"op" = "cache", "action" = "list"}
	resp, ok := _daemon_call(_ipc_build(m))
	if !ok do return _mcp_tool_result(id_val, "error: could not connect to daemon", true)
	return _mcp_tool_result(id_val, resp)
}

// shard_events — "What changed?"
//   With source + event_type: call notify op (emit mode)
//   With shard only: call events op (read mode)
_tool_events :: proc(id_val: json.Value, args: json.Object) -> string {
	source     := md_json_get_str(args, "source")
	event_type := md_json_get_str(args, "event_type")
	shard_name := md_json_get_str(args, "shard")
	agent      := md_json_get_str(args, "agent")

	// Emit mode
	if source != "" && event_type != "" {
		m := map[string]any {
			"op"         = "notify",
			"source"     = source,
			"event_type" = event_type,
		}
		if agent != "" do m["agent"] = agent
		resp, ok := _daemon_call(_ipc_build(m))
		if !ok do return _mcp_tool_result(id_val, "error: could not connect to daemon", true)
		return _mcp_tool_result(id_val, resp)
	}

	// Read mode
	if shard_name != "" {
		m := map[string]any{"op" = "events", "name" = shard_name}
		resp, ok := _daemon_call(_ipc_build(m))
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

	m := map[string]any {
		"op"   = "stale",
		"name" = shard_name,
		"key"  = key,
	}
	if has_threshold do m["freshness_weight"] = threshold_f64

	resp, ok := _daemon_call(_ipc_build(m))
	if !ok do return _mcp_tool_result(id_val, fmt.tprintf("error: could not query shard '%s'", shard_name), true)
	return _mcp_tool_result(id_val, resp)
}

// shard_feedback — "This thought is useful/not useful"
_tool_feedback :: proc(id_val: json.Value, args: json.Object) -> string {
	shard_name := md_json_get_str(args, "shard")
	thought_id := md_json_get_str(args, "id")
	feedback   := md_json_get_str(args, "feedback")
	if shard_name == "" do return _mcp_tool_result(id_val, "error: shard name required", true)
	if thought_id == "" do return _mcp_tool_result(id_val, "error: thought id required", true)
	if feedback != "endorse" && feedback != "flag" do return _mcp_tool_result(id_val, "error: feedback must be 'endorse' or 'flag'", true)
	key := _mcp_resolve_key(args, shard_name)
	if key == "" do return _mcp_tool_result(id_val, "error: no key found (pass key, set SHARD_KEY, or add to .shards/keychain)", true)

	m := map[string]any {
		"op"       = "feedback",
		"name"     = shard_name,
		"key"      = key,
		"id"       = thought_id,
		"feedback" = feedback,
	}
	resp, ok := _daemon_call(_ipc_build(m))
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

	// Build tasks as a slice of maps for _ipc_write_any to serialise
	task_list := make([]map[string]any, len(tasks_arr), context.temp_allocator)

	for item, i in tasks_arr {
		obj, is_obj := item.(json.Object)
		if !is_obj do continue

		shard_name := md_json_get_str(obj, "shard")
		op         := md_json_get_str(obj, "op")
		key        := _mcp_resolve_key(obj, shard_name)
		desc       := md_json_get_str(obj, "description")
		content    := md_json_get_str(obj, "content")
		query      := md_json_get_str(obj, "query")
		thought_id := md_json_get_str(obj, "id")
		agent      := md_json_get_str(obj, "agent")

		t := map[string]any {
			"name" = shard_name,
			"op"   = op,
		}
		if key != "" do t["key"] = key
		if desc != "" do t["description"] = desc
		if content != "" do t["content"] = content
		if query != "" do t["query"] = query
		if thought_id != "" do t["id"] = thought_id
		if agent != "" do t["agent"] = agent
		task_list[i] = t
	}

	m := map[string]any {
		"op"    = "fleet",
		"tasks" = task_list[:],
	}
	resp, ok := _daemon_call(_ipc_build(m))
	if !ok do return _mcp_tool_result(id_val, "error: could not connect to daemon", true)
	return _mcp_tool_result(id_val, resp)
}

// shard_compact_suggest — analyze a shard and return compaction suggestions
_tool_compact_suggest :: proc(id_val: json.Value, args: json.Object) -> string {
	shard_name := md_json_get_str(args, "shard")
	if shard_name == "" do return _mcp_tool_result(id_val, "error: shard name required", true)

	key  := _mcp_resolve_key(args, shard_name)
	mode := md_json_get_str(args, "mode")

	m := map[string]any {
		"op"   = "compact_suggest",
		"name" = shard_name,
		"key"  = key,
	}
	if mode != "" do m["mode"] = mode

	resp, ok := _daemon_call(_ipc_build(m))
	if !ok do return _mcp_tool_result(id_val, "error: could not connect to daemon", true)
	return _mcp_tool_result(id_val, resp)
}

// shard_compact — execute compaction on specific thought IDs
_tool_compact :: proc(id_val: json.Value, args: json.Object) -> string {
	shard_name := md_json_get_str(args, "shard")
	if shard_name == "" do return _mcp_tool_result(id_val, "error: shard name required", true)

	key  := _mcp_resolve_key(args, shard_name)
	mode := md_json_get_str(args, "mode")

	ids_val, ids_ok := args["ids"]
	if !ids_ok do return _mcp_tool_result(id_val, "error: ids required", true)
	ids_arr, is_arr := ids_val.(json.Array)
	if !is_arr || len(ids_arr) == 0 do return _mcp_tool_result(id_val, "error: ids must be a non-empty array", true)

	ids := make([dynamic]string, 0, len(ids_arr), context.temp_allocator)
	for v in ids_arr {
		if id_str, is_str := v.(json.String); is_str {
			append(&ids, string(id_str))
		}
	}

	m := map[string]any {
		"op"   = "compact",
		"name" = shard_name,
		"key"  = key,
		"ids"  = ids[:],
	}
	if mode != "" do m["mode"] = mode

	resp, ok := _daemon_call(_ipc_build(m))
	if !ok do return _mcp_tool_result(id_val, "error: could not connect to daemon", true)
	return _mcp_tool_result(id_val, resp)
}

// shard_compact_apply — one-shot self-compaction: suggest then compact
_tool_compact_apply :: proc(id_val: json.Value, args: json.Object) -> string {
	shard_name := md_json_get_str(args, "shard")
	if shard_name == "" do return _mcp_tool_result(id_val, "error: shard name required", true)

	key  := _mcp_resolve_key(args, shard_name)
	mode := md_json_get_str(args, "mode")

	// Step 1: compact_suggest
	suggest_m := map[string]any {
		"op"   = "compact_suggest",
		"name" = shard_name,
		"key"  = key,
	}
	if mode != "" do suggest_m["mode"] = mode

	suggest_resp, suggest_ok := _daemon_call(_ipc_build(suggest_m))
	if !suggest_ok do return _mcp_tool_result(id_val, "error: could not connect to daemon for suggest", true)

	// Parse suggestion response to extract IDs
	all_ids := make([dynamic]string, context.temp_allocator)
	_extract_suggestion_ids(suggest_resp, &all_ids)

	if len(all_ids) == 0 {
		return _mcp_tool_result(id_val, suggest_resp)
	}

	// Step 2: compact with all collected IDs
	compact_m := map[string]any {
		"op"   = "compact",
		"name" = shard_name,
		"key"  = key,
		"ids"  = all_ids[:],
	}
	if mode != "" do compact_m["mode"] = mode

	compact_resp, compact_ok := _daemon_call(_ipc_build(compact_m))
	if !compact_ok do return _mcp_tool_result(id_val, "error: could not connect to daemon for compact", true)

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
