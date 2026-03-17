package shard

import "core:encoding/json"
import "core:fmt"
import "core:strconv"
import "core:strings"

// =============================================================================
// Markdown wire format — YAML frontmatter + Markdown body
// =============================================================================
//
// All IPC messages use this format:
//
//   ---
//   key: value
//   list: [a, b, c]
//   ---
//   Body content here (maps to "content" field).
//
// The body after the closing --- is always the content/body field.
// Everything else goes in the YAML frontmatter as key: value pairs.
//
// This format is directly compatible with Obsidian markdown files —
// responses can be dumped to .md files without transformation.

FRONTMATTER_DELIM :: "---"

// =============================================================================
// Request parsing
// =============================================================================

md_parse_request :: proc(input: string, allocator := context.allocator) -> (Request, bool) {
	req: Request

	lines := strings.split(input, "\n")
	defer delete(lines)

	if len(lines) == 0 do return req, false

	// First line must be ---
	if strings.trim_right(lines[0], "\r \t") != FRONTMATTER_DELIM {
		return req, false
	}

	// Find closing ---
	close_idx := -1
	for i := 1; i < len(lines); i += 1 {
		if strings.trim_right(lines[i], "\r \t") == FRONTMATTER_DELIM {
			close_idx = i
			break
		}
	}
	if close_idx == -1 do return req, false

	// Parse YAML key: value lines
	for i := 1; i < close_idx; i += 1 {
		line := strings.trim_right(lines[i], "\r")
		colon := strings.index(line, ":")
		if colon == -1 do continue

		key := strings.trim_space(line[:colon])
		val := strings.trim_space(line[colon + 1:])

		switch key {
		case "op":            req.op            = strings.clone(val, allocator)
		case "id":            req.id            = strings.clone(val, allocator)
		case "description":   req.description   = strings.clone(val, allocator)
		case "query":         req.query         = strings.clone(val, allocator)
		case "name":          req.name          = strings.clone(val, allocator)
		case "data_path":     req.data_path     = strings.clone(val, allocator)
		case "purpose":       req.purpose       = strings.clone(val, allocator)
		case "thought_count": req.thought_count, _ = strconv.parse_int(val)
		case "agent":         req.agent          = strings.clone(val, allocator)
		case "key":           req.key            = strings.clone(val, allocator)
		case "items":         req.items         = _parse_inline_list(val, allocator)
		case "ids":           req.ids           = _parse_inline_list(val, allocator)
		case "tags":          req.tags          = _parse_inline_list(val, allocator)
		case "related":       req.related       = _parse_inline_list(val, allocator)
		case "max_depth":     req.max_depth, _    = strconv.parse_int(val)
		case "max_branches":  req.max_branches, _ = strconv.parse_int(val)
		case "layer":         req.layer, _        = strconv.parse_int(val)
		case "revises":       req.revises         = strings.clone(val, allocator)
		case "lock_id":       req.lock_id         = strings.clone(val, allocator)
		case "ttl":           req.ttl, _          = strconv.parse_int(val)
		case "alert_id":      req.alert_id        = strings.clone(val, allocator)
		case "action":        req.action           = strings.clone(val, allocator)
		case "event_type":    req.event_type       = strings.clone(val, allocator)
		case "source":        req.source           = strings.clone(val, allocator)
		case "origin_chain":  req.origin_chain     = _parse_inline_list(val, allocator)
		case "limit":         req.limit, _          = strconv.parse_int(val)
		case "budget":        req.budget, _         = strconv.parse_int(val)
		case "thought_ttl":   req.thought_ttl, _    = strconv.parse_int(val)
		case "freshness_weight":
			fw, fw_ok := strconv.parse_f64(val)
			if fw_ok do req.freshness_weight = f32(fw)
		case "feedback":      req.feedback       = strings.clone(val, allocator)
		case "mode":          req.mode           = strings.clone(val, allocator)
		case "threshold":
			th, th_ok := strconv.parse_f64(val)
			if th_ok do req.threshold = f32(th)
		}
	}

	// Body = everything after closing --- (maps to content)
	if close_idx + 1 < len(lines) {
		body_parts := make([dynamic]string, context.temp_allocator)
		for i := close_idx + 1; i < len(lines); i += 1 {
			append(&body_parts, strings.trim_right(lines[i], "\r"))
		}
		body := strings.join(body_parts[:], "\n", allocator)
		if body != "" {
			req.content = body
		}
	}

	return req, true
}

// Parse [a, b, c] inline YAML list
@(private)
_parse_inline_list :: proc(val: string, allocator := context.allocator) -> []string {
	trimmed := strings.trim_space(val)
	if !strings.has_prefix(trimmed, "[") || !strings.has_suffix(trimmed, "]") {
		// Single value — treat as one-element list
		if trimmed != "" {
			result := make([]string, 1, allocator)
			result[0] = strings.clone(trimmed, allocator)
			return result
		}
		return nil
	}
	inner := trimmed[1:len(trimmed) - 1]
	if strings.trim_space(inner) == "" do return nil

	parts := strings.split(inner, ",")
	defer delete(parts)

	result := make([]string, len(parts), allocator)
	for p, i in parts {
		result[i] = strings.clone(strings.trim_space(p), allocator)
	}
	return result
}

// =============================================================================
// Response serialization
// =============================================================================

md_marshal_response :: proc(resp: Response, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)

	strings.write_string(&b, "---\n")

	// Status — always present
	fmt.sbprintf(&b, "status: %s\n", resp.status)

	// Error
	if resp.err != "" {
		fmt.sbprintf(&b, "error: %s\n", resp.err)
	}

	// Scalar fields
	if resp.id != "" {
		fmt.sbprintf(&b, "id: %s\n", resp.id)
	}
	if resp.description != "" {
		fmt.sbprintf(&b, "description: %s\n", resp.description)
	}
	if resp.moved != 0 {
		fmt.sbprintf(&b, "moved: %d\n", resp.moved)
	}

	// Agent identity
	if resp.agent != "" {
		fmt.sbprintf(&b, "agent: %s\n", resp.agent)
	}
	if resp.created_at != "" {
		fmt.sbprintf(&b, "created_at: %s\n", resp.created_at)
	}
	if resp.updated_at != "" {
		fmt.sbprintf(&b, "updated_at: %s\n", resp.updated_at)
	}

	// Status op fields
	if resp.node_name != "" {
		fmt.sbprintf(&b, "node_name: %s\n", resp.node_name)
	}
	if resp.thoughts != 0 {
		fmt.sbprintf(&b, "thoughts: %d\n", resp.thoughts)
	}
	if resp.uptime_secs != 0 {
		fmt.sbprintf(&b, "uptime_secs: %.1f\n", resp.uptime_secs)
	}

	// Transaction lock
	if resp.lock_id != "" {
		fmt.sbprintf(&b, "lock_id: %s\n", resp.lock_id)
	}

	// Content alert
	if resp.alert_id != "" {
		fmt.sbprintf(&b, "alert_id: %s\n", resp.alert_id)
	}
	if resp.findings != nil && len(resp.findings) > 0 {
		strings.write_string(&b, "findings:\n")
		for f in resp.findings {
			fmt.sbprintf(&b, "  - category: %s\n    snippet: %s\n", f.category, f.snippet)
		}
	}

	// Simple lists
	if resp.ids != nil && len(resp.ids) > 0 {
		_write_inline_list(&b, "ids", resp.ids)
	}
	if resp.items != nil && len(resp.items) > 0 {
		_write_inline_list(&b, "items", resp.items)
	}
	if resp.revisions != nil && len(resp.revisions) > 0 {
		_write_inline_list(&b, "revisions", resp.revisions)
	}

	// Search results
	if resp.results != nil && len(resp.results) > 0 {
		strings.write_string(&b, "results:\n")
		for r in resp.results {
			fmt.sbprintf(&b, "  - id: %s\n    score: %.2f\n", r.id, r.score)
			if r.shard_name != "" {
				fmt.sbprintf(&b, "    shard_name: %s\n", r.shard_name)
			}
			if r.description != "" {
				fmt.sbprintf(&b, "    description: %s\n", r.description)
			}
			if r.content != "" {
				fmt.sbprintf(&b, "    content: %s\n", r.content)
			}
			if r.staleness_score != 0 {
				fmt.sbprintf(&b, "    staleness_score: %.2f\n", r.staleness_score)
			}
			if r.relevance_score != 0 {
				fmt.sbprintf(&b, "    relevance_score: %.2f\n", r.relevance_score)
			}
			if r.truncated {
				strings.write_string(&b, "    truncated: true\n")
			}
		}
	}

	// Catalog
	if resp.catalog.name != "" || resp.catalog.purpose != "" {
		_write_catalog(&b, resp.catalog, "  ")
	}

	// Registry
	if resp.registry != nil && len(resp.registry) > 0 {
		strings.write_string(&b, "registry:\n")
		for entry in resp.registry {
			fmt.sbprintf(&b, "  - name: %s\n", entry.name)
			if entry.data_path != "" {
				fmt.sbprintf(&b, "    data_path: %s\n", entry.data_path)
			}
			fmt.sbprintf(&b, "    thought_count: %d\n", entry.thought_count)
			if entry.needs_attention {
				strings.write_string(&b, "    needs_attention: true\n")
			}
			if entry.needs_compaction {
				strings.write_string(&b, "    needs_compaction: true\n")
			}
			if entry.catalog.name != "" || entry.catalog.purpose != "" {
				_write_catalog(&b, entry.catalog, "      ")
			}
			if entry.gate_desc != nil && len(entry.gate_desc) > 0 {
				_write_inline_list(&b, "    gate_desc", entry.gate_desc)
			}
			if entry.gate_positive != nil && len(entry.gate_positive) > 0 {
				_write_inline_list(&b, "    gate_positive", entry.gate_positive)
			}
			if entry.gate_negative != nil && len(entry.gate_negative) > 0 {
				_write_inline_list(&b, "    gate_negative", entry.gate_negative)
			}
			if entry.gate_related != nil && len(entry.gate_related) > 0 {
				_write_inline_list(&b, "    gate_related", entry.gate_related)
			}
		}
	}

	// Events
	if resp.events != nil && len(resp.events) > 0 {
		fmt.sbprintf(&b, "event_count: %d\n", len(resp.events))
		strings.write_string(&b, "events:\n")
		for ev in resp.events {
			fmt.sbprintf(&b, "  - source: %s\n    event_type: %s\n    agent: %s\n    timestamp: %s\n",
				ev.source, ev.event_type, ev.agent, ev.timestamp)
			if ev.origin_chain != nil && len(ev.origin_chain) > 0 {
				_write_inline_list(&b, "    origin_chain", ev.origin_chain)
			}
		}
	}

	// Staleness score (stale op)
	if resp.staleness_score != 0 {
		fmt.sbprintf(&b, "staleness_score: %.2f\n", resp.staleness_score)
	}

	// Relevance score
	if resp.relevance_score != 0 {
		fmt.sbprintf(&b, "relevance_score: %.2f\n", resp.relevance_score)
	}

	// Cross-shard query fields
	if resp.shards_searched != 0 {
		fmt.sbprintf(&b, "shards_searched: %d\n", resp.shards_searched)
	}
	if resp.total_results != 0 {
		fmt.sbprintf(&b, "total_results: %d\n", resp.total_results)
	}

	// Fleet results
	if resp.fleet_results != nil && len(resp.fleet_results) > 0 {
		fmt.sbprintf(&b, "task_count: %d\n", len(resp.fleet_results))
		strings.write_string(&b, "fleet_results:\n")
		for r in resp.fleet_results {
			fmt.sbprintf(&b, "  - name: %s\n    status: %s\n", r.name, r.status)
		}
	}

	// Consumption log
	if resp.consumption_log != nil && len(resp.consumption_log) > 0 {
		fmt.sbprintf(&b, "record_count: %d\n", len(resp.consumption_log))
		strings.write_string(&b, "consumption_log:\n")
		for rec in resp.consumption_log {
			fmt.sbprintf(&b, "  - agent: %s\n    shard: %s\n    op: %s\n    timestamp: %s\n",
				rec.agent, rec.shard, rec.op, rec.timestamp)
		}
	}

	// Compact suggestions
	if resp.suggestions != nil && len(resp.suggestions) > 0 {
		fmt.sbprintf(&b, "suggestion_count: %d\n", len(resp.suggestions))
		strings.write_string(&b, "suggestions:\n")
		for s in resp.suggestions {
			fmt.sbprintf(&b, "  - kind: %s\n    action: %s\n    description: %s\n", s.kind, s.action, s.description)
			if s.ids != nil && len(s.ids) > 0 {
				strings.write_string(&b, "    ids: [")
				for id, i in s.ids {
					if i > 0 do strings.write_string(&b, ", ")
					strings.write_string(&b, id)
				}
				strings.write_string(&b, "]\n")
			}
		}
	}

	strings.write_string(&b, "---\n")

	// Body = content field
	if resp.content != "" {
		strings.write_string(&b, resp.content)
	}

	// Fleet results: detailed content in body
	if resp.fleet_results != nil && len(resp.fleet_results) > 0 {
		for r in resp.fleet_results {
			if r.content != "" {
				fmt.sbprintf(&b, "\n## %s\n\n%s\n", r.name, r.content)
			}
		}
	}

	// Streaming
	if resp.more {
		strings.write_string(&b, "more: true\n")
	}

	return strings.to_string(b)
}

// =============================================================================
// YAML helpers
// =============================================================================

@(private)
_write_inline_list :: proc(b: ^strings.Builder, key: string, items: []string) {
	fmt.sbprintf(b, "%s: [", key)
	for s, i in items {
		if i > 0 do strings.write_string(b, ", ")
		strings.write_string(b, s)
	}
	strings.write_string(b, "]\n")
}

@(private)
_write_catalog :: proc(b: ^strings.Builder, cat: Catalog, indent: string = "  ") {
	strings.write_string(b, "catalog:\n")
	if cat.name != "" {
		fmt.sbprintf(b, "%sname: %s\n", indent, cat.name)
	}
	if cat.purpose != "" {
		fmt.sbprintf(b, "%spurpose: %s\n", indent, cat.purpose)
	}
	if cat.tags != nil && len(cat.tags) > 0 {
		fmt.sbprintf(b, "%stags: [", indent)
		for t, i in cat.tags {
			if i > 0 do strings.write_string(b, ", ")
			strings.write_string(b, t)
		}
		strings.write_string(b, "]\n")
	}
	if cat.related != nil && len(cat.related) > 0 {
		fmt.sbprintf(b, "%srelated: [", indent)
		for r, i in cat.related {
			if i > 0 do strings.write_string(b, ", ")
			strings.write_string(b, r)
		}
		strings.write_string(b, "]\n")
	}
	if cat.created != "" {
		fmt.sbprintf(b, "%screated: %s\n", indent, cat.created)
	}
}

// =============================================================================
// JSON wire format — primary API format
// =============================================================================

md_json_get_str :: proc(obj: json.Object, key: string) -> string {
	if val, ok := obj[key]; ok {
		#partial switch v in val {
		case string:
			return v
		}
	}
	return ""
}

md_json_get_int :: proc(obj: json.Object, key: string) -> int {
	if val, ok := obj[key]; ok {
		#partial switch v in val {
		case i64:
			return int(v)
		case f64:
			return int(v)
		}
	}
	return 0
}

md_json_get_f64 :: proc(obj: json.Object, key: string) -> f64 {
	if val, ok := obj[key]; ok {
		#partial switch v in val {
		case f64:
			return v
		case i64:
			return f64(v)
		}
	}
	return 0.0
}

md_json_get_bool :: proc(obj: json.Object, key: string) -> (bool, bool) {
	if val, ok := obj[key]; ok {
		#partial switch v in val {
		case bool:
			return v, true
		}
	}
	return false, false
}

md_json_get_obj :: proc(obj: json.Object, key: string) -> (json.Object, bool) {
	if val, ok := obj[key]; ok {
		#partial switch v in val {
		case json.Object:
			return v, true
		}
	}
	return {}, false
}

md_json_get_str_array :: proc(obj: json.Object, key: string, allocator := context.allocator) -> []string {
	if val, ok := obj[key]; ok {
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
	}
	return nil
}

md_json_str_array_to_json :: proc(arr: []string, allocator := context.allocator) -> json.Array {
	if arr == nil || len(arr) == 0 do return nil
	result := make(json.Array, len(arr), allocator)
	for s, i in arr {
		result[i] = s
	}
	return result
}

md_parse_request_json :: proc(data: []u8, allocator := context.allocator) -> (Request, bool) {
	req: Request
	parsed, parse_err := json.parse(data, allocator = allocator)
	if parse_err != nil do return req, false
	defer json.destroy_value(parsed, allocator)
	
	obj, is_obj := parsed.(json.Object)
	if !is_obj do return req, false
	
	req.op = md_json_get_str(obj, "op")
	req.id = md_json_get_str(obj, "id")
	req.description = md_json_get_str(obj, "description")
	req.content = md_json_get_str(obj, "content")
	req.query = md_json_get_str(obj, "query")
	req.name = md_json_get_str(obj, "name")
	req.data_path = md_json_get_str(obj, "data_path")
	req.purpose = md_json_get_str(obj, "purpose")
	req.agent = md_json_get_str(obj, "agent")
	req.key = md_json_get_str(obj, "key")
	req.revises = md_json_get_str(obj, "revises")
	req.lock_id = md_json_get_str(obj, "lock_id")
	req.alert_id = md_json_get_str(obj, "alert_id")
	req.action = md_json_get_str(obj, "action")
	req.event_type = md_json_get_str(obj, "event_type")
	req.source = md_json_get_str(obj, "source")
	req.feedback = md_json_get_str(obj, "feedback")
	req.mode = md_json_get_str(obj, "mode")
	
	req.thought_count = md_json_get_int(obj, "thought_count")
	req.max_depth = md_json_get_int(obj, "max_depth")
	req.max_branches = md_json_get_int(obj, "max_branches")
	req.layer = md_json_get_int(obj, "layer")
	req.ttl = md_json_get_int(obj, "ttl")
	req.limit = md_json_get_int(obj, "limit")
	req.budget = md_json_get_int(obj, "budget")
	req.thought_ttl = md_json_get_int(obj, "thought_ttl")
	
	req.freshness_weight = f32(md_json_get_f64(obj, "freshness_weight"))
	req.threshold = f32(md_json_get_f64(obj, "threshold"))
	
	req.items = md_json_get_str_array(obj, "items")
	req.ids = md_json_get_str_array(obj, "ids")
	req.tags = md_json_get_str_array(obj, "tags")
	req.related = md_json_get_str_array(obj, "related")
	req.origin_chain = md_json_get_str_array(obj, "origin_chain")
	
	if tasks_val, ok := obj["tasks"]; ok {
		if tasks_arr, is_arr := tasks_val.(json.Array); is_arr {
			tasks := make([]Fleet_Task, len(tasks_arr), allocator)
			for item, i in tasks_arr {
				task_obj, is_task_obj := item.(json.Object)
				if is_task_obj {
					tasks[i] = Fleet_Task{
						name = md_json_get_str(task_obj, "name"),
						op = md_json_get_str(task_obj, "op"),
						key = md_json_get_str(task_obj, "key"),
						description = md_json_get_str(task_obj, "description"),
						content = md_json_get_str(task_obj, "content"),
						query = md_json_get_str(task_obj, "query"),
						id = md_json_get_str(task_obj, "id"),
						agent = md_json_get_str(task_obj, "agent"),
					}
				}
			}
			req.tasks = tasks
		}
	}
	
	return req, true
}

md_marshal_response_json :: proc(resp: Response, allocator := context.allocator) -> []u8 {
	b := strings.builder_make(allocator)
	
	strings.write_string(&b, "{")
	_write_json_field(&b, "status", resp.status)
	if resp.err != "" {
		strings.write_string(&b, ",")
		_write_json_field(&b, "error", resp.err)
	}
	if resp.id != "" {
		strings.write_string(&b, ",")
		_write_json_field(&b, "id", resp.id)
	}
	if resp.description != "" {
		strings.write_string(&b, ",")
		_write_json_field(&b, "description", resp.description)
	}
	if resp.content != "" {
		strings.write_string(&b, ",")
		_write_json_field(&b, "content", resp.content)
	}
	if resp.agent != "" {
		strings.write_string(&b, ",")
		_write_json_field(&b, "agent", resp.agent)
	}
	if resp.created_at != "" {
		strings.write_string(&b, ",")
		_write_json_field(&b, "created_at", resp.created_at)
	}
	if resp.updated_at != "" {
		strings.write_string(&b, ",")
		_write_json_field(&b, "updated_at", resp.updated_at)
	}
	if resp.node_name != "" {
		strings.write_string(&b, ",")
		_write_json_field(&b, "node_name", resp.node_name)
	}
	if resp.thoughts != 0 {
		strings.write_string(&b, `,"thoughts":`)
		fmt.sbprintf(&b, "%d", resp.thoughts)
	}
	if resp.uptime_secs != 0 {
		strings.write_string(&b, `,"uptime_secs":`)
		fmt.sbprintf(&b, "%v", resp.uptime_secs)
	}
	if resp.lock_id != "" {
		strings.write_string(&b, ",")
		_write_json_field(&b, "lock_id", resp.lock_id)
	}
	if resp.alert_id != "" {
		strings.write_string(&b, ",")
		_write_json_field(&b, "alert_id", resp.alert_id)
	}
	if resp.moved != 0 {
		strings.write_string(&b, `,"moved":`)
		fmt.sbprintf(&b, "%d", resp.moved)
	}
	if resp.staleness_score != 0 {
		strings.write_string(&b, `,"staleness_score":`)
		fmt.sbprintf(&b, "%v", resp.staleness_score)
	}
	if resp.relevance_score != 0 {
		strings.write_string(&b, `,"relevance_score":`)
		fmt.sbprintf(&b, "%v", resp.relevance_score)
	}
	if resp.shards_searched != 0 {
		strings.write_string(&b, `,"shards_searched":`)
		fmt.sbprintf(&b, "%d", resp.shards_searched)
	}
	if resp.total_results != 0 {
		strings.write_string(&b, `,"total_results":`)
		fmt.sbprintf(&b, "%d", resp.total_results)
	}
	
	if len(resp.ids) > 0 {
		strings.write_string(&b, `,"ids":`)
		_write_json_array(&b, resp.ids)
	}
	if len(resp.items) > 0 {
		strings.write_string(&b, `,"items":`)
		_write_json_array(&b, resp.items)
	}
	if len(resp.revisions) > 0 {
		strings.write_string(&b, `,"revisions":`)
		_write_json_array(&b, resp.revisions)
	}
	
	if len(resp.results) > 0 {
		strings.write_string(&b, `,"results":[`)
		for r, i in resp.results {
			if i > 0 do strings.write_string(&b, ",")
			strings.write_string(&b, `{`)
			_write_json_field(&b, "id", r.id)
			if r.shard_name != "" {
				strings.write_string(&b, ",")
				_write_json_field(&b, "shard_name", r.shard_name)
			}
			strings.write_string(&b, `,"score":`)
			fmt.sbprintf(&b, "%v", r.score)
			if r.description != "" {
				strings.write_string(&b, ",")
				_write_json_field(&b, "description", r.description)
			}
			if r.content != "" {
				strings.write_string(&b, ",")
				_write_json_field(&b, "content", r.content)
			}
			if r.truncated {
				strings.write_string(&b, `,"truncated":true`)
			}
			if r.staleness_score != 0 {
				strings.write_string(&b, `,"staleness_score":`)
				fmt.sbprintf(&b, "%v", r.staleness_score)
			}
			if r.relevance_score != 0 {
				strings.write_string(&b, `,"relevance_score":`)
				fmt.sbprintf(&b, "%v", r.relevance_score)
			}
			strings.write_string(&b, "}")
		}
		strings.write_string(&b, "]")
	}
	
	if resp.catalog.name != "" || resp.catalog.purpose != "" {
		strings.write_string(&b, `,"catalog":{`)
		_write_json_field(&b, "name", resp.catalog.name)
		if resp.catalog.purpose != "" {
			strings.write_string(&b, ",")
			_write_json_field(&b, "purpose", resp.catalog.purpose)
		}
		if resp.catalog.created != "" {
			strings.write_string(&b, ",")
			_write_json_field(&b, "created", resp.catalog.created)
		}
		if len(resp.catalog.tags) > 0 {
			strings.write_string(&b, `,"tags":`)
			_write_json_array(&b, resp.catalog.tags)
		}
		if len(resp.catalog.related) > 0 {
			strings.write_string(&b, `,"related":`)
			_write_json_array(&b, resp.catalog.related)
		}
		strings.write_string(&b, "}")
	}
	
	if len(resp.registry) > 0 {
		strings.write_string(&b, `,"registry":[`)
		for r, i in resp.registry {
			if i > 0 do strings.write_string(&b, ",")
			strings.write_string(&b, `{`)
			_write_json_field(&b, "name", r.name)
			strings.write_string(&b, `,"thought_count":`)
			fmt.sbprintf(&b, "%d", r.thought_count)
			if r.data_path != "" {
				strings.write_string(&b, ",")
				_write_json_field(&b, "data_path", r.data_path)
			}
			if r.needs_attention {
				strings.write_string(&b, `,"needs_attention":true`)
			}
			if r.needs_compaction {
				strings.write_string(&b, `,"needs_compaction":true`)
			}
			if r.catalog.name != "" {
				strings.write_string(&b, `,"catalog":{`)
				_write_json_field(&b, "name", r.catalog.name)
				if r.catalog.purpose != "" {
					strings.write_string(&b, ",")
					_write_json_field(&b, "purpose", r.catalog.purpose)
				}
				strings.write_string(&b, "}")
			}
			strings.write_string(&b, "}")
		}
		strings.write_string(&b, "]")
	}
	
	if len(resp.events) > 0 {
		strings.write_string(&b, `,"event_count":`)
		fmt.sbprintf(&b, "%d", len(resp.events))
		strings.write_string(&b, `,"events":[`)
		for e, i in resp.events {
			if i > 0 do strings.write_string(&b, ",")
			strings.write_string(&b, `{`)
			_write_json_field(&b, "source", e.source)
			strings.write_string(&b, ",")
			_write_json_field(&b, "event_type", e.event_type)
			strings.write_string(&b, ",")
			_write_json_field(&b, "agent", e.agent)
			strings.write_string(&b, ",")
			_write_json_field(&b, "timestamp", e.timestamp)
			if len(e.origin_chain) > 0 {
				strings.write_string(&b, ",")
				_write_json_field(&b, "origin_chain", e.origin_chain[0])
			}
			strings.write_string(&b, "}")
		}
		strings.write_string(&b, "]")
	}
	
	if len(resp.fleet_results) > 0 {
		strings.write_string(&b, `,"task_count":`)
		fmt.sbprintf(&b, "%d", len(resp.fleet_results))
		strings.write_string(&b, `,"fleet_results":[`)
		for r, i in resp.fleet_results {
			if i > 0 do strings.write_string(&b, ",")
			strings.write_string(&b, `{`)
			_write_json_field(&b, "name", r.name)
			strings.write_string(&b, ",")
			_write_json_field(&b, "status", r.status)
			if r.content != "" {
				strings.write_string(&b, ",")
				_write_json_field(&b, "content", r.content)
			}
			strings.write_string(&b, "}")
		}
		strings.write_string(&b, "]")
	}
	
	if len(resp.consumption_log) > 0 {
		strings.write_string(&b, `,"record_count":`)
		fmt.sbprintf(&b, "%d", len(resp.consumption_log))
		strings.write_string(&b, `,"consumption_log":[`)
		for rec, i in resp.consumption_log {
			if i > 0 do strings.write_string(&b, ",")
			strings.write_string(&b, `{`)
			_write_json_field(&b, "agent", rec.agent)
			strings.write_string(&b, ",")
			_write_json_field(&b, "shard", rec.shard)
			strings.write_string(&b, ",")
			_write_json_field(&b, "op", rec.op)
			strings.write_string(&b, ",")
			_write_json_field(&b, "timestamp", rec.timestamp)
			strings.write_string(&b, "}")
		}
		strings.write_string(&b, "]")
	}

	if resp.suggestions != nil && len(resp.suggestions) > 0 {
		strings.write_string(&b, `,"suggestion_count":`)
		fmt.sbprintf(&b, "%d", len(resp.suggestions))
		strings.write_string(&b, `,"suggestions":[`)
		for s, i in resp.suggestions {
			if i > 0 do strings.write_string(&b, ",")
			strings.write_string(&b, `{`)
			_write_json_field(&b, "kind", s.kind)
			strings.write_string(&b, ",")
			_write_json_field(&b, "action", s.action)
			strings.write_string(&b, ",")
			_write_json_field(&b, "description", s.description)
			if s.ids != nil && len(s.ids) > 0 {
				strings.write_string(&b, `,"ids":[`)
				for id, j in s.ids {
					if j > 0 do strings.write_string(&b, ",")
					strings.write_string(&b, `"`)
					strings.write_string(&b, id)
					strings.write_string(&b, `"`)
				}
				strings.write_string(&b, "]")
			}
			strings.write_string(&b, "}")
		}
		strings.write_string(&b, "]")
	}
	
	if resp.more {
		strings.write_string(&b, `,"more":true`)
	}
	
	strings.write_string(&b, "}")
	
	return transmute([]u8)strings.to_string(b)
}

_write_json_field :: proc(b: ^strings.Builder, key: string, value: string) {
	strings.write_string(b, `"`)
	strings.write_string(b, key)
	strings.write_string(b, `":"`)
	_json_escape_to(b, value)
	strings.write_string(b, `"`)
}

_write_json_array :: proc(b: ^strings.Builder, items: []string) {
	strings.write_string(b, "[")
	for s, i in items {
		if i > 0 do strings.write_string(b, ",")
		strings.write_string(b, `"`)
		_json_escape_to(b, s)
		strings.write_string(b, `"`)
	}
	strings.write_string(b, "]")
}

_json_escape_to :: proc(b: ^strings.Builder, s: string) {
	for ch in s {
		switch ch {
		case '"':  strings.write_string(b, `\"`)
		case '\\': strings.write_string(b, `\\`)
		case '\n': strings.write_string(b, `\n`)
		case '\r': strings.write_string(b, `\r`)
		case '\t': strings.write_string(b, `\t`)
		case: strings.write_rune(b, ch)
		}
	}
}

// json_escape returns a JSON-escaped string (wrapper for convenience)
json_escape :: proc(s: string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	_json_escape_to(&b, s)
	return strings.to_string(b)
}
