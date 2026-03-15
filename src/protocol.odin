package shard

import "core:encoding/hex"
import "core:fmt"
import "core:strings"
import "core:time"
import "core:unicode"

// =============================================================================
// Per-request key verification
// =============================================================================

// _verify_key checks whether a request carries the correct master key.
// Returns true if the key matches. Comparison is constant-time.
@(private)
_verify_key :: proc(node: ^Node, req: Request) -> bool {
	if req.key == "" do return false
	if len(req.key) != 64 do return false
	key_bytes, ok := hex.decode(transmute([]u8)req.key, context.temp_allocator)
	if !ok || len(key_bytes) != 32 do return false
	defer delete(key_bytes, context.temp_allocator)
	master := node.blob.master
	// Constant-time comparison
	diff: u8 = 0
	for i in 0..<32 do diff |= key_bytes[i] ~ master[i]
	return diff == 0
}

// =============================================================================
// Dispatch — routes incoming ops to handlers
// =============================================================================

dispatch :: proc(node: ^Node, line: string, allocator := context.allocator) -> string {
	req, ok := md_parse_request(line, allocator)
	if !ok {
		return _err_response("invalid message (expected YAML frontmatter)", allocator)
	}

	// Daemon-specific ops (register, unregister, heartbeat, registry, discover)
	if node.is_daemon {
		if resp, handled := daemon_dispatch(node, req, allocator); handled {
			return resp
		}
	}

	switch req.op {
	// Gate ops — no key required
	case "description":     return _op_gate_read(node.blob.description[:], allocator)
	case "positive":        return _op_gate_read(node.blob.positive[:], allocator)
	case "negative":        return _op_gate_read(node.blob.negative[:], allocator)
	case "related":         return _op_gate_read(node.blob.related[:], allocator)
	case "set_description": return _op_gate_write(node, &node.blob.description, req.items, allocator)
	case "set_positive":    return _op_gate_write(node, &node.blob.positive,    req.items, allocator)
	case "set_negative":    return _op_gate_write(node, &node.blob.negative,    req.items, allocator)
	case "set_related":     return _op_gate_write(node, &node.blob.related,     req.items, allocator)
	case "link":            return _op_link(node, req, allocator)
	case "unlink":          return _op_unlink(node, req, allocator)

	// Catalog ops — plaintext identity card, no key required
	case "catalog":         return _op_catalog(node, allocator)
	case "set_catalog":     return _op_set_catalog(node, req, allocator)

	// Content ops — require per-request key authentication
	case "write":
		if !_verify_key(node, req) do return _err_response("key required (provide key: <64-hex> in request)", allocator)
		return _op_write(node, req, allocator)
	case "read":
		if !_verify_key(node, req) do return _err_response("key required (provide key: <64-hex> in request)", allocator)
		return _op_read(node, req, allocator)
	case "update":
		if !_verify_key(node, req) do return _err_response("key required (provide key: <64-hex> in request)", allocator)
		return _op_update(node, req, allocator)
	case "list":     return _op_list(node, allocator)
	case "delete":
		if !_verify_key(node, req) do return _err_response("key required (provide key: <64-hex> in request)", allocator)
		return _op_delete(node, req, allocator)
	case "search":
		if !_verify_key(node, req) do return _err_response("key required (provide key: <64-hex> in request)", allocator)
		return _op_search(node, req, allocator)
	case "compact":
		if !_verify_key(node, req) do return _err_response("key required (provide key: <64-hex> in request)", allocator)
		return _op_compact(node, req, allocator)
	case "dump":
		if !_verify_key(node, req) do return _err_response("key required (provide key: <64-hex> in request)", allocator)
		return _op_dump(node, allocator)
	case "manifest": return _op_manifest(node, req, allocator)
	case "status":   return _op_status(node, allocator)
	case "shutdown": return _op_shutdown(node, allocator)
	case:
		return _err_response(fmt.tprintf("unknown op: %s", req.op), allocator)
	}
}

// =============================================================================
// Op handlers
// =============================================================================

@(private)
_op_write :: proc(node: ^Node, req: Request, allocator := context.allocator) -> string {
	if req.description == "" do return _err_response("description required", allocator)
	id := new_thought_id()
	pt := Thought_Plaintext{description = req.description, content = req.content}
	thought, ok := thought_create(node.blob.master, id, pt)
	if !ok do return _err_response("thought_create failed", allocator)

	// Agent identity: set agent and timestamps
	now := _format_time(time.now())
	if req.agent != "" {
		agent := req.agent
		// Enforce 64-char limit
		if len(agent) > 64 do agent = agent[:64]
		thought.agent = strings.clone(agent)
	}
	thought.created_at = strings.clone(now)
	thought.updated_at = strings.clone(now)

	if !blob_put(&node.blob, thought) do return _err_response("flush failed", allocator)
	// Update search index
	append(&node.index, Search_Entry{id = id, description = strings.clone(req.description)})
	return _marshal(Response{status = "ok", id = id_to_hex(id, allocator)}, allocator)
}

@(private)
_op_update :: proc(node: ^Node, req: Request, allocator := context.allocator) -> string {
	id, ok := hex_to_id(req.id)
	if !ok do return _err_response("invalid id", allocator)

	// Thought must exist
	old_thought, found := blob_get(&node.blob, id)
	if !found do return _err_response("thought not found", allocator)

	// Decrypt old to get current values
	old_pt, decrypt_err := thought_decrypt(old_thought, node.blob.master, context.temp_allocator)
	if decrypt_err != .None do return _err_response("decrypt failed", allocator)
	defer {
		delete(old_pt.description, context.temp_allocator)
		delete(old_pt.content, context.temp_allocator)
	}

	// Merge: use new values where provided, keep old where not
	new_desc    := req.description != "" ? req.description : old_pt.description
	new_content := req.content != "" ? req.content : old_pt.content

	// Re-encrypt with same ID (key derived from ID stays the same)
	pt := Thought_Plaintext{description = new_desc, content = new_content}
	new_thought, create_ok := thought_create(node.blob.master, id, pt)
	if !create_ok do return _err_response("thought_create failed", allocator)

	// Preserve plaintext metadata, update timestamp
	new_thought.agent      = old_thought.agent
	new_thought.created_at = old_thought.created_at
	new_thought.updated_at = _format_time(time.now())

	if !blob_put(&node.blob, new_thought) do return _err_response("flush failed", allocator)

	// Update search index
	for &entry in node.index {
		if entry.id == id {
			entry.description = strings.clone(new_desc)
			break
		}
	}

	return _marshal(Response{status = "ok", id = id_to_hex(id, allocator)}, allocator)
}

@(private)
_op_read :: proc(node: ^Node, req: Request, allocator := context.allocator) -> string {
	id, ok := hex_to_id(req.id)
	if !ok do return _err_response("invalid id", allocator)
	thought, found := blob_get(&node.blob, id)
	if !found do return _err_response("thought not found", allocator)
	pt, err := thought_decrypt(thought, node.blob.master, allocator)
	if err != .None do return _err_response("decrypt failed", allocator)
	return _marshal(Response{
		status      = "ok",
		description = pt.description,
		content     = pt.content,
		agent       = thought.agent,
		created_at  = thought.created_at,
		updated_at  = thought.updated_at,
	}, allocator)
}

@(private)
_op_list :: proc(node: ^Node, allocator := context.allocator) -> string {
	ids := blob_ids(&node.blob, context.temp_allocator)
	defer delete(ids, context.temp_allocator)
	hex_ids := make([]string, len(ids), allocator)
	for id, i in ids do hex_ids[i] = id_to_hex(id, allocator)
	return _marshal(Response{status = "ok", ids = hex_ids}, allocator)
}

@(private)
_op_delete :: proc(node: ^Node, req: Request, allocator := context.allocator) -> string {
	id, ok := hex_to_id(req.id)
	if !ok do return _err_response("invalid id", allocator)
	if !blob_remove(&node.blob, id) do return _err_response("delete failed", allocator)
	// Remove from index
	for i := 0; i < len(node.index); i += 1 {
		if node.index[i].id == id { ordered_remove(&node.index, i); break }
	}
	return _marshal(Response{status = "ok"}, allocator)
}

@(private)
_op_search :: proc(node: ^Node, req: Request, allocator := context.allocator) -> string {
	if req.query == "" do return _err_response("query required", allocator)
	hits := search_query(node.index[:], req.query, context.temp_allocator)
	defer delete(hits, context.temp_allocator)

	// Optional agent filter
	agent_filter := req.agent

	wire := make([dynamic]Wire_Result, allocator)
	for h in hits {
		if agent_filter != "" {
			// Look up thought to check agent
			thought, found := blob_get(&node.blob, h.id)
			if !found do continue
			if thought.agent != agent_filter do continue
		}
		append(&wire, Wire_Result{id = id_to_hex(h.id, allocator), score = h.score})
	}
	return _marshal(Response{status = "ok", results = wire[:]}, allocator)
}

@(private)
_op_compact :: proc(node: ^Node, req: Request, allocator := context.allocator) -> string {
	if req.ids == nil || len(req.ids) == 0 do return _err_response("ids required", allocator)
	target_ids := make([]Thought_ID, len(req.ids), context.temp_allocator)
	defer delete(target_ids, context.temp_allocator)
	for s, i in req.ids {
		id, ok := hex_to_id(s)
		if !ok do return _err_response(fmt.tprintf("invalid id: %s", s), allocator)
		target_ids[i] = id
	}
	moved := blob_compact(&node.blob, target_ids)
	return _marshal(Response{status = "ok", moved = moved}, allocator)
}

@(private)
_op_dump :: proc(node: ^Node, allocator := context.allocator) -> string {
	cat := node.blob.catalog
	b := strings.builder_make(allocator)

	// --- YAML frontmatter ---
	strings.write_string(&b, "---\n")
	fmt.sbprintf(&b, "status: ok\n")

	if cat.name != "" {
		fmt.sbprintf(&b, "title: %s\n", cat.name)
	}
	if cat.purpose != "" {
		fmt.sbprintf(&b, "purpose: %s\n", cat.purpose)
	}
	if cat.tags != nil && len(cat.tags) > 0 {
		strings.write_string(&b, "tags: [")
		for t, i in cat.tags {
			if i > 0 do strings.write_string(&b, ", ")
			strings.write_string(&b, t)
		}
		strings.write_string(&b, "]\n")
	}
	if cat.related != nil && len(cat.related) > 0 {
		strings.write_string(&b, "related: [")
		for r, i in cat.related {
			if i > 0 do strings.write_string(&b, ", ")
			strings.write_string(&b, r)
		}
		strings.write_string(&b, "]\n")
	}
	if cat.created != "" {
		fmt.sbprintf(&b, "created: %s\n", cat.created)
	}
	fmt.sbprintf(&b, "exported: %s\n", _format_time(time.now()))

	total := len(node.blob.processed) + len(node.blob.unprocessed)
	fmt.sbprintf(&b, "thoughts: %d\n", total)
	strings.write_string(&b, "---\n")

	// --- Title ---
	title := cat.name != "" ? cat.name : node.name
	fmt.sbprintf(&b, "\n# %s\n", title)
	if cat.purpose != "" {
		fmt.sbprintf(&b, "\n%s\n", cat.purpose)
	}

	// --- Related shards as wikilinks ---
	if cat.related != nil && len(cat.related) > 0 {
		strings.write_string(&b, "\n## Related\n\n")
		for r, i in cat.related {
			if i > 0 do strings.write_string(&b, " | ")
			fmt.sbprintf(&b, "[[%s]]", r)
		}
		strings.write_string(&b, "\n")
	}

	// --- Decrypt and render all thoughts ---
	// Processed first (AI-ordered), then unprocessed
	has_processed := len(node.blob.processed) > 0
	has_unprocessed := len(node.blob.unprocessed) > 0

	if has_processed {
		strings.write_string(&b, "\n## Knowledge\n")
		for thought in node.blob.processed {
			_dump_thought(&b, thought, node.blob.master)
		}
	}

	if has_unprocessed {
		strings.write_string(&b, "\n## Unprocessed\n")
		for thought in node.blob.unprocessed {
			_dump_thought(&b, thought, node.blob.master)
		}
	}

	return strings.to_string(b)
}

@(private)
_dump_thought :: proc(b: ^strings.Builder, thought: Thought, master: Master_Key) {
	pt, err := thought_decrypt(thought, master, context.temp_allocator)
	if err != .None {
		strings.write_string(b, "\n### [decrypt failed]\n")
		return
	}
	defer {
		delete(pt.description, context.temp_allocator)
		delete(pt.content, context.temp_allocator)
	}

	fmt.sbprintf(b, "\n### %s\n", pt.description)
	if pt.content != "" {
		fmt.sbprintf(b, "\n%s\n", pt.content)
	}
}

@(private)
_op_manifest :: proc(node: ^Node, req: Request, allocator := context.allocator) -> string {
	if req.content != "" {
		node.blob.manifest = strings.clone(req.content)
		if !blob_flush(&node.blob) do return _err_response("flush failed", allocator)
		return _marshal(Response{status = "ok"}, allocator)
	}
	return _marshal(Response{status = "ok", content = node.blob.manifest}, allocator)
}

@(private)
_op_status :: proc(node: ^Node, allocator := context.allocator) -> string {
	now := time.now()
	uptime := time.duration_seconds(time.diff(node.start_time, now))
	total := len(node.blob.processed) + len(node.blob.unprocessed)
	return _marshal(Response{
		status      = "ok",
		node_name   = node.name,
		thoughts    = total,
		uptime_secs = uptime,
	}, allocator)
}

@(private)
_op_shutdown :: proc(node: ^Node, allocator := context.allocator) -> string {
	node.running = false
	return _marshal(Response{status = "ok"}, allocator)
}

@(private)
_op_gate_read :: proc(list: []string, allocator := context.allocator) -> string {
	items := make([]string, len(list), allocator)
	for s, i in list do items[i] = s
	return _marshal(Response{status = "ok", items = items}, allocator)
}

@(private)
_op_gate_write :: proc(node: ^Node, field: ^[dynamic]string, items: []string, allocator := context.allocator) -> string {
	clear(field)
	for s in items do append(field, strings.clone(s))
	if !blob_flush(&node.blob) do return _err_response("flush failed", allocator)
	return _marshal(Response{status = "ok"}, allocator)
}

// =============================================================================
// Link ops — add/remove entries in the related gate list
// =============================================================================

MAX_RELATED :: 32

@(private)
_op_link :: proc(node: ^Node, req: Request, allocator := context.allocator) -> string {
	if req.items == nil || len(req.items) == 0 {
		return _err_response("items required", allocator)
	}
	for item in req.items {
		// Skip duplicates
		already := false
		for existing in node.blob.related {
			if existing == item { already = true; break }
		}
		if already do continue
		if len(node.blob.related) >= MAX_RELATED {
			return _err_response(
				fmt.tprintf("related list full (max %d)", MAX_RELATED), allocator,
			)
		}
		append(&node.blob.related, strings.clone(item))
	}
	if !blob_flush(&node.blob) do return _err_response("flush failed", allocator)
	return _marshal(Response{status = "ok", items = node.blob.related[:]}, allocator)
}

@(private)
_op_unlink :: proc(node: ^Node, req: Request, allocator := context.allocator) -> string {
	if req.items == nil || len(req.items) == 0 {
		return _err_response("items required", allocator)
	}
	for item in req.items {
		for i := 0; i < len(node.blob.related); i += 1 {
			if node.blob.related[i] == item {
				ordered_remove(&node.blob.related, i)
				break
			}
		}
	}
	if !blob_flush(&node.blob) do return _err_response("flush failed", allocator)
	return _marshal(Response{status = "ok", items = node.blob.related[:]}, allocator)
}

// =============================================================================
// Catalog ops
// =============================================================================

@(private)
_op_catalog :: proc(node: ^Node, allocator := context.allocator) -> string {
	return _marshal(Response{status = "ok", catalog = node.blob.catalog}, allocator)
}

@(private)
_op_set_catalog :: proc(node: ^Node, req: Request, allocator := context.allocator) -> string {
	cat := &node.blob.catalog
	if req.name != ""    do cat.name    = strings.clone(req.name)
	if req.purpose != "" do cat.purpose = strings.clone(req.purpose)
	if req.tags != nil   do cat.tags    = _clone_strings(req.tags)
	if req.related != nil do cat.related = _clone_strings(req.related)
	if cat.created == "" {
		cat.created = _format_time(time.now())
	}
	if !blob_flush(&node.blob) do return _err_response("flush failed", allocator)
	return _marshal(Response{status = "ok", catalog = node.blob.catalog}, allocator)
}

// =============================================================================
// Search
// =============================================================================

search_query :: proc(entries: []Search_Entry, query: string, allocator := context.allocator) -> []Search_Result {
	q_tokens := _tokenize(query, context.temp_allocator)
	defer delete(q_tokens, context.temp_allocator)
	if len(q_tokens) == 0 do return nil

	results := make([dynamic]Search_Result, allocator)
	for entry in entries {
		score := _keyword_score(q_tokens, entry.description)
		if score <= 0 do continue
		append(&results, Search_Result{id = entry.id, score = score})
	}
	// Sort by score descending
	_sort_results(results[:])
	return results[:]
}

@(private)
_keyword_score :: proc(q_tokens: []string, description: string) -> f32 {
	d_tokens := _tokenize(description, context.temp_allocator)
	defer delete(d_tokens, context.temp_allocator)
	if len(q_tokens) == 0 do return 0
	matches := 0
	for qt in q_tokens {
		for dt in d_tokens {
			if qt == dt { matches += 1; break }
		}
	}
	return f32(matches) / f32(len(q_tokens))
}

@(private)
_tokenize :: proc(s: string, allocator := context.allocator) -> []string {
	tokens := make([dynamic]string, allocator)
	start  := -1
	for i := 0; i < len(s); i += 1 {
		c       := rune(s[i])
		is_word := unicode.is_letter(c) || unicode.is_digit(c)
		if is_word && start == -1 {
			start = i
		} else if !is_word && start != -1 {
			append(&tokens, strings.to_lower(s[start:i], allocator))
			start = -1
		}
	}
	if start != -1 do append(&tokens, strings.to_lower(s[start:], allocator))
	return tokens[:]
}

@(private)
_sort_results :: proc(results: []Search_Result) {
	// Simple insertion sort — fine for typical result counts
	for i := 1; i < len(results); i += 1 {
		key := results[i]
		j := i - 1
		for j >= 0 && results[j].score < key.score {
			results[j + 1] = results[j]
			j -= 1
		}
		results[j + 1] = key
	}
}

// =============================================================================
// Response helpers
// =============================================================================

@(private)
_marshal :: proc(resp: Response, allocator := context.allocator) -> string {
	return md_marshal_response(resp, allocator)
}

@(private)
_err_response :: proc(msg: string, allocator := context.allocator) -> string {
	return _marshal(Response{status = "error", err = msg}, allocator)
}
