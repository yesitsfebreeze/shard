package shard

import "core:fmt"
import "core:math"
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
	k, ok := hex_to_key(req.key)
	if !ok do return false
	diff: u8 = 0
	for i in 0..<32 do diff |= k[i] ~ node.blob.master[i]
	return diff == 0
}

// =============================================================================
// Dispatch — routes incoming ops to handlers
// =============================================================================

dispatch :: proc(node: ^Node, payload: string, allocator := context.allocator) -> string {
	// Detect format: JSON starts with { or [
	req: Request
	ok: bool
	is_json := false
	
	trimmed := strings.trim_space(payload)
	if len(trimmed) > 0 && trimmed[0] == '{' {
		is_json = true
		req, ok = md_parse_request_json(transmute([]u8)payload, allocator)
	} else {
		req, ok = md_parse_request(payload, allocator)
	}
	
	_set_request_json(is_json)
	
	if !ok {
		return _err_response("invalid message (expected JSON or YAML frontmatter)", allocator)
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
	case "revisions":
		if !_verify_key(node, req) do return _err_response("key required (provide key: <64-hex> in request)", allocator)
		return _op_revisions(node, req, allocator)
	case "delete":
		if !_verify_key(node, req) do return _err_response("key required (provide key: <64-hex> in request)", allocator)
		return _op_delete(node, req, allocator)
	case "search":
		if !_verify_key(node, req) do return _err_response("key required (provide key: <64-hex> in request)", allocator)
		return _op_search(node, req, allocator)
	case "query":
		if !_verify_key(node, req) do return _err_response("key required (provide key: <64-hex> in request)", allocator)
		return _op_query(node, req, allocator)
	case "gates":    return _op_gates(node, allocator)
	case "compact":
		if !_verify_key(node, req) do return _err_response("key required (provide key: <64-hex> in request)", allocator)
		return _op_compact(node, req, allocator)
	case "dump":
		if !_verify_key(node, req) do return _err_response("key required (provide key: <64-hex> in request)", allocator)
		return _op_dump(node, allocator)
	case "stale":
		if !_verify_key(node, req) do return _err_response("key required (provide key: <64-hex> in request)", allocator)
		return _op_stale(node, req, allocator)
	case "feedback":
		if !_verify_key(node, req) do return _err_response("key required (provide key: <64-hex> in request)", allocator)
		return _op_feedback(node, req, allocator)
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
		thought.agent = strings.clone(req.agent)
	}
	thought.created_at = strings.clone(now)
	thought.updated_at = strings.clone(now)

	// Staleness TTL
	if req.thought_ttl > 0 {
		thought.ttl = u32(req.thought_ttl)
	}

	// Revision linking
	if req.revises != "" {
		parent_id, rev_ok := hex_to_id(req.revises)
		if !rev_ok do return _err_response("invalid revises id", allocator)
		_, parent_found := blob_get(&node.blob, parent_id)
		if !parent_found do return _err_response("parent thought not found", allocator)
		thought.revises = parent_id
	}

	if !blob_put(&node.blob, thought) do return _err_response("flush failed", allocator)

	// Scan content for thought ID citations and increment cite_count
	_scan_citations(&node.blob, req.content)

	// Update search index
	entry := Search_Entry{
		id          = id,
		description = strings.clone(req.description),
		text_hash   = fnv_hash(req.description),
	}
	if embed_ready() {
		emb, emb_ok := embed_text(req.description, context.temp_allocator)
		if emb_ok {
			stored := make([]f32, len(emb))
			copy(stored, emb)
			entry.embedding = stored
		}
	}
	append(&node.index, entry)

	// Post-write content scan (informational — never blocks the write)
	// If the AI flags something, an alert is created for the user to review.
	// The thought is already persisted regardless of findings.
	id_hex := id_to_hex(id, allocator)
	findings := scan_content(req.description, req.content)
	if len(findings) > 0 {
		alert_id := new_random_hex()
		if node.pending_alerts == nil {
			node.pending_alerts = make(map[string]Pending_Alert)
		}
		node.pending_alerts[alert_id] = Pending_Alert{
			alert_id   = strings.clone(alert_id),
			shard_name = strings.clone(node.name),
			agent      = strings.clone(req.agent),
			findings   = findings[:],
			request    = _clone_request(req),
			created_at = strings.clone(now),
		}
		return _marshal(Response{
			status   = "ok",
			id       = id_hex,
			alert_id = alert_id,
			findings = findings[:],
		}, allocator)
	}

	return _marshal(Response{status = "ok", id = id_hex}, allocator)
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
	// Preserve or update TTL
	new_thought.ttl = req.thought_ttl > 0 ? u32(req.thought_ttl) : old_thought.ttl

	if !blob_put(&node.blob, new_thought) do return _err_response("flush failed", allocator)

	// Update search index
	for &entry in node.index {
		if entry.id == id {
			new_hash := fnv_hash(new_desc)
			delete(entry.description)
			entry.description = strings.clone(new_desc)
			if new_hash != entry.text_hash {
				entry.text_hash = new_hash
				delete(entry.embedding)
				entry.embedding = nil
				if embed_ready() {
					emb, emb_ok := embed_text(new_desc, context.temp_allocator)
					if emb_ok {
						stored := make([]f32, len(emb))
						copy(stored, emb)
						entry.embedding = stored
					}
				}
			}
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

	// Increment read counter
	_increment_read_count(&node.blob, id)

	// Collect revision chain: find all thoughts that revise this one
	revisions := _collect_revisions(&node.blob, id, allocator)

	return _marshal(Response{
		status      = "ok",
		description = pt.description,
		content     = pt.content,
		agent       = thought.agent,
		created_at  = thought.created_at,
		updated_at  = thought.updated_at,
		revisions   = revisions,
	}, allocator)
}

// _collect_revisions finds all direct children (thoughts whose revises == parent_id).
@(private)
_collect_revisions :: proc(b: ^Blob, parent_id: Thought_ID, allocator := context.allocator) -> []string {
	rev_ids := make([dynamic]string, context.temp_allocator)
	_scan_block :: proc(thoughts: []Thought, parent_id: Thought_ID, rev_ids: ^[dynamic]string) {
		for t in thoughts {
			if t.revises == parent_id {
				append(rev_ids, id_to_hex(t.id, context.temp_allocator))
			}
		}
	}
	_scan_block(b.processed[:], parent_id, &rev_ids)
	_scan_block(b.unprocessed[:], parent_id, &rev_ids)
	if len(rev_ids) == 0 do return nil
	result := make([]string, len(rev_ids), allocator)
	for id, i in rev_ids do result[i] = strings.clone(id, allocator)
	return result
}

// _op_revisions walks the full revision chain for a thought.
// Returns IDs from root -> latest in chronological order.
@(private)
_op_revisions :: proc(node: ^Node, req: Request, allocator := context.allocator) -> string {
	id, ok := hex_to_id(req.id)
	if !ok do return _err_response("invalid id", allocator)
	_, found := blob_get(&node.blob, id)
	if !found do return _err_response("thought not found", allocator)

	// Walk up to root
	root := id
	for {
		t, t_found := blob_get(&node.blob, root)
		if !t_found do break
		if t.revises == ZERO_THOUGHT_ID do break
		root = t.revises
	}

	// Walk down from root collecting all revisions (BFS)
	chain := make([dynamic]string, allocator)
	append(&chain, id_to_hex(root, allocator))
	queue := make([dynamic]Thought_ID, context.temp_allocator)
	append(&queue, root)
	front := 0
	for front < len(queue) {
		current := queue[front]
		front += 1
		// Find children
		for t in node.blob.processed {
			if t.revises == current {
				append(&chain, id_to_hex(t.id, allocator))
				append(&queue, t.id)
			}
		}
		for t in node.blob.unprocessed {
			if t.revises == current {
				append(&chain, id_to_hex(t.id, allocator))
				append(&queue, t.id)
			}
		}
	}

	return _marshal(Response{status = "ok", ids = chain[:]}, allocator)
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
		if node.index[i].id == id {
			delete(node.index[i].embedding)
			ordered_remove(&node.index, i)
			break
		}
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
	now := time.now()

	wire := make([dynamic]Wire_Result, allocator)
	for h in hits {
		thought, found := blob_get(&node.blob, h.id)
		if !found do continue
		if agent_filter != "" && thought.agent != agent_filter do continue
		// Find description from index
		desc := ""
		for entry in node.index {
			if entry.id == h.id {
				desc = entry.description
				break
			}
		}
		composite := _composite_score(h.score, thought, now)
		append(&wire, Wire_Result{
			id              = id_to_hex(h.id, allocator),
			score           = composite,
			description     = desc,
			relevance_score = composite,
		})
	}
	return _marshal(Response{status = "ok", results = wire[:]}, allocator)
}

// _op_query — compound search+read: searches, then decrypts top N results.
// Returns results with id, score, description, AND content in one shot.
// Default limit is 5 results. Uses the "thought_count" request field as limit.
@(private)
_op_query :: proc(node: ^Node, req: Request, allocator := context.allocator) -> string {
	if req.query == "" do return _err_response("query required", allocator)
	hits := search_query(node.index[:], req.query, context.temp_allocator)
	defer delete(hits, context.temp_allocator)

	default_limit := config_get().default_query_limit
	limit := req.thought_count > 0 ? req.thought_count : default_limit
	agent_filter := req.agent
	budget := req.budget > 0 ? req.budget : config_get().default_query_budget
	now := time.now()

	wire := make([dynamic]Wire_Result, allocator)
	count := 0
	chars_used := 0
	for h in hits {
		if count >= limit do break
		thought, found := blob_get(&node.blob, h.id)
		if !found do continue
		if agent_filter != "" && thought.agent != agent_filter do continue

		pt, err := thought_decrypt(thought, node.blob.master, allocator)
		if err != .None do continue

		content := pt.content
		truncated := false
		if budget > 0 {
			remaining := budget - chars_used
			if remaining <= 0 {
				content = ""
				truncated = true
			} else if len(content) > remaining {
				content = content[:remaining]
				truncated = true
			}
		}
		chars_used += len(content)

		composite := _composite_score(h.score, thought, now)
		append(&wire, Wire_Result{
			id              = id_to_hex(h.id, allocator),
			score           = composite,
			description     = pt.description,
			content         = content,
			truncated       = truncated,
			relevance_score = composite,
		})
		count += 1
	}
	return _marshal(Response{status = "ok", results = wire[:]}, allocator)
}

// _op_gates — return all gates (description, positive, negative, related) in one response.
@(private)
_op_gates :: proc(node: ^Node, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "---\n")
	strings.write_string(&b, "status: ok\n")

	// Description gate
	if len(node.blob.description) > 0 {
		_write_inline_list(&b, "description", node.blob.description[:])
	}
	// Positive gate
	if len(node.blob.positive) > 0 {
		_write_inline_list(&b, "positive", node.blob.positive[:])
	}
	// Negative gate
	if len(node.blob.negative) > 0 {
		_write_inline_list(&b, "negative", node.blob.negative[:])
	}
	// Related gate
	if len(node.blob.related) > 0 {
		_write_inline_list(&b, "related", node.blob.related[:])
	}
	strings.write_string(&b, "---\n")
	return strings.to_string(b)
}

@(private)
_op_compact :: proc(node: ^Node, req: Request, allocator := context.allocator) -> string {
	if req.ids == nil || len(req.ids) == 0 do return _err_response("ids required", allocator)

	// Parse all target IDs
	target_ids := make([]Thought_ID, len(req.ids), context.temp_allocator)
	defer delete(target_ids, context.temp_allocator)
	for s, i in req.ids {
		id, ok := hex_to_id(s)
		if !ok do return _err_response(fmt.tprintf("invalid id: %s", s), allocator)
		target_ids[i] = id
	}

	// Build a set of target IDs for quick lookup
	target_set: map[Thought_ID]bool
	defer delete(target_set)
	for id in target_ids do target_set[id] = true

	// Find revision chains among targets: group by root ID
	// A chain is: root -> child1 -> child2 etc. where each child.revises == parent
	chains: map[Thought_ID][dynamic]Thought_ID  // root -> [root, child1, child2, ...]
	defer {
		for _, chain in chains do delete(chain)
		delete(chains)
	}
	standalone := make([dynamic]Thought_ID, context.temp_allocator)
	defer delete(standalone)

	for id in target_ids {
		thought, found := blob_get(&node.blob, id)
		if !found do continue

		if thought.revises != ZERO_THOUGHT_ID && thought.revises in target_set {
			// Part of a chain — find root
			root := id
			for {
				t, ok := blob_get(&node.blob, root)
				if !ok do break
				if t.revises == ZERO_THOUGHT_ID || !(t.revises in target_set) do break
				root = t.revises
			}
			if root not_in chains {
				chains[root] = make([dynamic]Thought_ID, context.temp_allocator)
				append(&chains[root], root)
			}
			if id != root do append(&chains[root], id)
		} else if id not_in chains {
			// Could be a root with children, or standalone
			has_children := false
			for other_id in target_ids {
				if other_id == id do continue
				t, ok := blob_get(&node.blob, other_id)
				if ok && t.revises == id {
					has_children = true
					break
				}
			}
			if has_children {
				if id not_in chains {
					chains[id] = make([dynamic]Thought_ID, context.temp_allocator)
					append(&chains[id], id)
				}
			} else {
				append(&standalone, id)
			}
		}
	}

	moved := 0

	// Move standalone thoughts as before
	if len(standalone) > 0 {
		moved += blob_compact(&node.blob, standalone[:])
	}

	// Merge each revision chain
	for root_id, chain_ids in chains {
		merged_ok := _merge_revision_chain(node, root_id, chain_ids[:])
		if merged_ok do moved += len(chain_ids)
	}

	return _marshal(Response{status = "ok", moved = moved}, allocator)
}

// _merge_revision_chain decrypts all thoughts in a chain, merges their content
// with agent attribution, re-encrypts as a single thought under the root ID,
// places it in processed, and removes the individual chain members.
@(private)
_merge_revision_chain :: proc(node: ^Node, root_id: Thought_ID, chain_ids: []Thought_ID) -> bool {
	if len(chain_ids) == 0 do return false

	// Collect and decrypt all thoughts in the chain, ordered by created_at
	Decrypted :: struct {
		id:          Thought_ID,
		description: string,
		content:     string,
		agent:       string,
		created_at:  string,
	}

	entries := make([dynamic]Decrypted, context.temp_allocator)
	defer {
		for e in entries {
			delete(e.description, context.temp_allocator)
			delete(e.content, context.temp_allocator)
		}
		delete(entries)
	}

	root_desc := ""
	for cid in chain_ids {
		thought, found := blob_get(&node.blob, cid)
		if !found do continue
		pt, err := thought_decrypt(thought, node.blob.master, context.temp_allocator)
		if err != .None do continue
		append(&entries, Decrypted{
			id          = cid,
			description = pt.description,
			content     = pt.content,
			agent       = thought.agent,
			created_at  = thought.created_at,
		})
		if cid == root_id do root_desc = pt.description
	}

	if len(entries) == 0 do return false

	// Sort by created_at (simple string comparison works for RFC3339)
	for i := 1; i < len(entries); i += 1 {
		key := entries[i]
		j := i - 1
		for j >= 0 && entries[j].created_at > key.created_at {
			entries[j + 1] = entries[j]
			j -= 1
		}
		entries[j + 1] = key
	}

	// Use the root's description, or the first entry's if root wasn't found
	if root_desc == "" do root_desc = entries[0].description

	// Build merged content with agent attribution
	b := strings.builder_make(context.temp_allocator)
	for entry, i in entries {
		if i > 0 do strings.write_string(&b, "\n\n")
		agent := entry.agent != "" ? entry.agent : "unknown"
		fmt.sbprintf(&b, "[%s @ %s]:\n%s", agent, entry.created_at, entry.content)
	}
	merged_content := strings.to_string(b)

	// Create the merged thought under the root ID
	pt := Thought_Plaintext{description = root_desc, content = merged_content}
	merged_thought, create_ok := thought_create(node.blob.master, root_id, pt)
	if !create_ok do return false

	// Set metadata on merged thought
	merged_thought.agent      = strings.clone("compaction")
	merged_thought.created_at = entries[0].created_at
	merged_thought.updated_at = _format_time(time.now())

	// Remove all chain members from both blocks
	for cid in chain_ids {
		for i := 0; i < len(node.blob.processed); i += 1 {
			if node.blob.processed[i].id == cid {
				ordered_remove(&node.blob.processed, i)
				break
			}
		}
		for i := 0; i < len(node.blob.unprocessed); i += 1 {
			if node.blob.unprocessed[i].id == cid {
				ordered_remove(&node.blob.unprocessed, i)
				break
			}
		}
		// Remove from search index
		for i := 0; i < len(node.index); i += 1 {
			if node.index[i].id == cid {
				delete(node.index[i].embedding)
				delete(node.index[i].description)
				ordered_remove(&node.index, i)
				break
			}
		}
	}

	// Place merged thought in processed block
	append(&node.blob.processed, merged_thought)

	// Update search index for the merged thought
	entry := Search_Entry{
		id          = root_id,
		description = strings.clone(root_desc),
		text_hash   = fnv_hash(root_desc),
	}
	if embed_ready() {
		emb, emb_ok := embed_text(root_desc, context.temp_allocator)
		if emb_ok {
			stored := make([]f32, len(emb))
			copy(stored, emb)
			entry.embedding = stored
		}
	}
	append(&node.index, entry)

	blob_flush(&node.blob)
	return true
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
		delete(node.blob.manifest)
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
	for &s in field do delete(s)
	clear(field)
	for s in items do append(field, strings.clone(s))
	if !blob_flush(&node.blob) do return _err_response("flush failed", allocator)
	return _marshal(Response{status = "ok"}, allocator)
}

// =============================================================================
// Link ops — add/remove entries in the related gate list
// =============================================================================

// MAX_RELATED is now configurable via .shards/config (max_related)
_max_related :: proc() -> int {
	return config_get().max_related
}

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
		if len(node.blob.related) >= _max_related() {
			return _err_response(
				fmt.tprintf("related list full (max %d)", _max_related()), allocator,
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
	if req.name != "" {
		delete(cat.name)
		cat.name = strings.clone(req.name)
	}
	if req.purpose != "" {
		delete(cat.purpose)
		cat.purpose = strings.clone(req.purpose)
	}
	if req.tags != nil {
		for t in cat.tags do delete(t)
		delete(cat.tags)
		cat.tags = _clone_strings(req.tags)
	}
	if req.related != nil {
		for r in cat.related do delete(r)
		delete(cat.related)
		cat.related = _clone_strings(req.related)
	}
	if cat.created == "" {
		cat.created = _format_time(time.now())
	}
	if !blob_flush(&node.blob) do return _err_response("flush failed", allocator)
	return _marshal(Response{status = "ok", catalog = node.blob.catalog}, allocator)
}

// =============================================================================
// Search index
// =============================================================================

build_search_index :: proc(index: ^[dynamic]Search_Entry, blob: Blob, master: Master_Key, label: string = "") -> bool {
	for &entry in index do delete(entry.embedding)
	clear(index)

	descriptions := make([dynamic]string, context.temp_allocator)
	decrypted_any := false

	_index_thoughts :: proc(thoughts: []Thought, master: Master_Key, index: ^[dynamic]Search_Entry, descriptions: ^[dynamic]string) -> bool {
		any := false
		for thought in thoughts {
			pt, err := thought_decrypt(thought, master, context.temp_allocator)
			if err == .None {
				desc := strings.clone(pt.description)
				append(index, Search_Entry{
					id          = thought.id,
					description = desc,
					text_hash   = fnv_hash(desc),
				})
				append(descriptions, desc)
				delete(pt.description, context.temp_allocator)
				delete(pt.content, context.temp_allocator)
				any = true
			}
		}
		return any
	}

	if _index_thoughts(blob.processed[:], master, index, &descriptions) do decrypted_any = true
	if _index_thoughts(blob.unprocessed[:], master, index, &descriptions) do decrypted_any = true

	if embed_ready() && len(descriptions) > 0 {
		embeddings, ok := embed_texts(descriptions[:], context.temp_allocator)
		if ok && len(embeddings) == len(index) {
			for &entry, i in index {
				stored := make([]f32, len(embeddings[i]))
				copy(stored, embeddings[i])
				entry.embedding = stored
			}
			if label != "" do fmt.eprintfln("%s: embedded %d thoughts", label, len(index))
		}
	}

	return decrypted_any
}

search_query :: proc(entries: []Search_Entry, query: string, allocator := context.allocator) -> []Search_Result {
	if embed_ready() && _entries_have_embeddings(entries) {
		results := _vector_search(entries, query, allocator)
		if results != nil && len(results) > 0 {
			return results
		}
	}
	return _keyword_search(entries, query, allocator)
}

@(private)
_entries_have_embeddings :: proc(entries: []Search_Entry) -> bool {
	if len(entries) == 0 do return false
	return entries[0].embedding != nil
}

@(private)
_vector_search :: proc(entries: []Search_Entry, query: string, allocator := context.allocator) -> []Search_Result {
	q_embed, ok := embed_text(query, context.temp_allocator)
	if !ok do return nil

	results := make([dynamic]Search_Result, allocator)
	for entry in entries {
		if entry.embedding == nil do continue
		score := cosine_similarity(q_embed, entry.embedding)
		if score > 0.3 {
			append(&results, Search_Result{id = entry.id, score = score})
		}
	}
	_sort_results(results[:])
	return results[:]
}

@(private)
_keyword_search :: proc(entries: []Search_Entry, query: string, allocator := context.allocator) -> []Search_Result {
	q_tokens := _tokenize(query, context.temp_allocator)
	defer delete(q_tokens, context.temp_allocator)
	if len(q_tokens) == 0 do return nil

	results := make([dynamic]Search_Result, allocator)
	for entry in entries {
		score := _keyword_score(q_tokens, entry.description)
		if score <= 0 do continue
		append(&results, Search_Result{id = entry.id, score = score})
	}
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
		qt_stem := _stem(qt)
		for dt in d_tokens {
			if qt == dt || qt_stem == _stem(dt) { matches += 1; break }
		}
	}
	return f32(matches) / f32(len(q_tokens))
}

_stem :: proc(token: string) -> string {
	suffixes := [?]string{"tion", "sion", "ment", "ness", "ing", "ous", "ive", "ble", "ed", "er", "ly", "es", "s"}
	for suffix in suffixes {
		if len(token) > len(suffix) + 2 && strings.has_suffix(token, suffix) {
			return token[:len(token) - len(suffix)]
		}
	}
	return token
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
// Relevance scoring — composite score blending match, freshness, and usage
// =============================================================================

// _composite_score blends keyword/vector match, freshness, and usage into one score.
// Formula: (match * (kw+vw)) + (freshness * fw) + (usage * uw)
// where kw+vw+fw+uw should sum to ~1.0 (configurable).
@(private)
_composite_score :: proc(base_score: f32, thought: Thought, now: time.Time) -> f32 {
	cfg := config_get()

	// Guard: if all weights are zero, return base_score
	total_weight := cfg.relevance_keyword_weight + cfg.relevance_vector_weight +
	                cfg.relevance_freshness_weight + cfg.relevance_usage_weight
	if total_weight == 0 do return base_score

	// Match component (keyword or vector — already computed)
	match_weight := cfg.relevance_keyword_weight + cfg.relevance_vector_weight
	match_component := base_score * match_weight

	// Freshness component: 1.0 = perfectly fresh, 0.0 = fully stale
	freshness: f32 = 1.0
	if thought.ttl > 0 {
		staleness := _compute_staleness(thought, now)
		freshness = 1.0 - staleness
	}
	freshness_component := freshness * cfg.relevance_freshness_weight

	// Usage component: log-scaled read+cite count, normalized to 0-1
	usage: f32 = 0
	total_usage := f32(thought.read_count) + f32(thought.cite_count) * 2.0
	if total_usage > 0 {
		// log2(1 + total) / log2(1 + 100) — caps at ~1.0 for 100 interactions
		usage = math.log2(1.0 + total_usage) / math.log2(f32(101.0))
		usage = min(usage, 1.0)
	}
	usage_component := usage * cfg.relevance_usage_weight

	return match_component + freshness_component + usage_component
}

// =============================================================================
// Relevance helpers — counter increments and citation scanning
// =============================================================================

@(private)
_increment_read_count :: proc(b: ^Blob, id: Thought_ID) {
	for &t in b.processed {
		if t.id == id { t.read_count += 1; if b.path != "" do blob_flush(b); return }
	}
	for &t in b.unprocessed {
		if t.id == id { t.read_count += 1; if b.path != "" do blob_flush(b); return }
	}
}

@(private)
_scan_citations :: proc(b: ^Blob, content: string) {
	if len(content) < 32 do return
	cited := false
	for i := 0; i <= len(content) - 32; i += 1 {
		candidate := content[i:i+32]
		cid, ok := hex_to_id(candidate)
		if !ok do continue
		// Check if this ID exists in the blob
		for &t in b.processed {
			if t.id == cid { t.cite_count += 1; cited = true; break }
		}
		for &t in b.unprocessed {
			if t.id == cid { t.cite_count += 1; cited = true; break }
		}
	}
	if cited && b.path != "" do blob_flush(b)
}

// =============================================================================
// Staleness computation
// =============================================================================

// _compute_staleness calculates how stale a thought is based on its TTL.
// Returns 0.0 for immortal thoughts (ttl=0), or a value in [0.0, 1.0] where
// 1.0 means fully expired. Based on elapsed time since updated_at vs TTL.
_compute_staleness :: proc(thought: Thought, now: time.Time) -> f32 {
	if thought.ttl == 0 do return 0 // immortal
	if thought.updated_at == "" do return 1 // no timestamp = maximally stale

	updated := _parse_rfc3339(thought.updated_at)
	zero_time: time.Time
	if updated == zero_time do return 1 // unparseable = maximally stale

	elapsed_secs := time.duration_seconds(time.diff(updated, now))
	if elapsed_secs < 0 do elapsed_secs = 0
	ratio := f32(elapsed_secs) / f32(thought.ttl)
	return min(ratio, 1.0)
}

// _parse_rfc3339 parses "YYYY-MM-DDThh:mm:ssZ" into time.Time.
// Returns zero time on failure.
@(private)
_parse_rfc3339 :: proc(s: string) -> time.Time {
	// Expected format: 2026-03-16T12:34:56Z (exactly 20 chars)
	if len(s) < 19 do return {}
	y, y_ok := _atoi4(s[0:4])
	m, m_ok := _atoi2(s[5:7])
	d, d_ok := _atoi2(s[8:10])
	h, h_ok := _atoi2(s[11:13])
	mn, mn_ok := _atoi2(s[14:16])
	sc, sc_ok := _atoi2(s[17:19])
	if !y_ok || !m_ok || !d_ok || !h_ok || !mn_ok || !sc_ok do return {}

	dt, dt_ok := time.datetime_to_time(i64(y), i64(m), i64(d), i64(h), i64(mn), i64(sc))
	if !dt_ok do return {}
	return dt
}

@(private)
_atoi2 :: proc(s: string) -> (int, bool) {
	if len(s) < 2 do return 0, false
	d0 := int(s[0]) - '0'
	d1 := int(s[1]) - '0'
	if d0 < 0 || d0 > 9 || d1 < 0 || d1 > 9 do return 0, false
	return d0 * 10 + d1, true
}

@(private)
_atoi4 :: proc(s: string) -> (int, bool) {
	if len(s) < 4 do return 0, false
	result := 0
	for i in 0..<4 {
		d := int(s[i]) - '0'
		if d < 0 || d > 9 do return 0, false
		result = result * 10 + d
	}
	return result, true
}

// _op_stale returns thoughts exceeding a staleness threshold, sorted by staleness.
@(private)
_op_stale :: proc(node: ^Node, req: Request, allocator := context.allocator) -> string {
	threshold := req.freshness_weight > 0 ? req.freshness_weight : f32(0.5)
	now := time.now()

	Stale_Entry :: struct {
		id:              Thought_ID,
		staleness_score: f32,
	}
	stale := make([dynamic]Stale_Entry, context.temp_allocator)

	// Scan both blocks
	for thought in node.blob.processed {
		score := _compute_staleness(thought, now)
		if score >= threshold do append(&stale, Stale_Entry{id = thought.id, staleness_score = score})
	}
	for thought in node.blob.unprocessed {
		score := _compute_staleness(thought, now)
		if score >= threshold do append(&stale, Stale_Entry{id = thought.id, staleness_score = score})
	}

	// Sort by staleness descending (most stale first)
	for i := 1; i < len(stale); i += 1 {
		key := stale[i]
		j := i - 1
		for j >= 0 && stale[j].staleness_score < key.staleness_score {
			stale[j + 1] = stale[j]
			j -= 1
		}
		stale[j + 1] = key
	}

	// Build wire results with decrypted content
	wire := make([dynamic]Wire_Result, allocator)
	for entry in stale {
		thought, found := blob_get(&node.blob, entry.id)
		if !found do continue
		pt, err := thought_decrypt(thought, node.blob.master, allocator)
		if err != .None do continue
		append(&wire, Wire_Result{
			id              = id_to_hex(entry.id, allocator),
			score           = entry.staleness_score,
			description     = pt.description,
			content         = pt.content,
			staleness_score = entry.staleness_score,
		})
	}

	return _marshal(Response{status = "ok", results = wire[:]}, allocator)
}

// =============================================================================
// Feedback op — endorse or flag a thought to adjust relevance
// =============================================================================

@(private)
_op_feedback :: proc(node: ^Node, req: Request, allocator := context.allocator) -> string {
	id, ok := hex_to_id(req.id)
	if !ok do return _err_response("invalid id", allocator)
	if req.feedback != "endorse" && req.feedback != "flag" {
		return _err_response("feedback must be 'endorse' or 'flag'", allocator)
	}

	// Find the thought
	thought_ptr: ^Thought = nil
	for &t in node.blob.processed {
		if t.id == id { thought_ptr = &t; break }
	}
	if thought_ptr == nil {
		for &t in node.blob.unprocessed {
			if t.id == id { thought_ptr = &t; break }
		}
	}
	if thought_ptr == nil do return _err_response("thought not found", allocator)

	if req.feedback == "endorse" {
		thought_ptr.cite_count += 5  // endorsement = strong positive signal
	} else {
		// flag = reduce read_count (floor at 0)
		if thought_ptr.read_count >= 5 {
			thought_ptr.read_count -= 5
		} else {
			thought_ptr.read_count = 0
		}
	}

	if node.blob.path != "" {
		if !blob_flush(&node.blob) do return _err_response("flush failed", allocator)
	}
	return _marshal(Response{status = "ok", id = id_to_hex(id, allocator)}, allocator)
}

// =============================================================================
// Request cloning — deep copies all string/slice fields for safe storage
// =============================================================================

@(private)
_clone_request :: proc(req: Request, allocator := context.allocator) -> Request {
	return Request{
		op            = strings.clone(req.op, allocator),
		id            = strings.clone(req.id, allocator),
		description   = strings.clone(req.description, allocator),
		content       = strings.clone(req.content, allocator),
		query         = strings.clone(req.query, allocator),
		items         = _clone_strings(req.items, allocator),
		ids           = _clone_strings(req.ids, allocator),
		name          = strings.clone(req.name, allocator),
		data_path     = strings.clone(req.data_path, allocator),
		thought_count = req.thought_count,
		agent         = strings.clone(req.agent, allocator),
		key           = strings.clone(req.key, allocator),
		purpose       = strings.clone(req.purpose, allocator),
		tags          = _clone_strings(req.tags, allocator),
		related       = _clone_strings(req.related, allocator),
		max_depth     = req.max_depth,
		max_branches  = req.max_branches,
		layer         = req.layer,
		revises       = strings.clone(req.revises, allocator),
		lock_id       = strings.clone(req.lock_id, allocator),
		ttl           = req.ttl,
		alert_id      = strings.clone(req.alert_id, allocator),
		action        = strings.clone(req.action, allocator),
		event_type    = strings.clone(req.event_type, allocator),
		source        = strings.clone(req.source, allocator),
		origin_chain     = _clone_strings(req.origin_chain, allocator),
		limit            = req.limit,
		budget           = req.budget,
		thought_ttl      = req.thought_ttl,
		freshness_weight = req.freshness_weight,
		feedback         = strings.clone(req.feedback, allocator),
	}
}

// =============================================================================
// Response helpers
// =============================================================================

_request_is_json :: proc() -> bool {
	return _last_request_was_json
}

_set_request_json :: proc(is_json: bool) {
	_last_request_was_json = is_json
}

@(private)
_last_request_was_json: bool

@(private)
_marshal :: proc(resp: Response, allocator := context.allocator) -> string {
	// Return same format as request
	if _last_request_was_json {
		data := md_marshal_response_json(resp, allocator)
		if data != nil {
			return string(data)
		}
	}
	return md_marshal_response(resp, allocator)
}

@(private)
_err_response :: proc(msg: string, allocator := context.allocator) -> string {
	return _marshal(Response{status = "error", err = msg}, allocator)
}
