package shard

import "core:fmt"
import "core:strings"
import "core:time"


// _verify_key checks whether a request carries the correct master key.
// Returns true if the key matches. Comparison is constant-time.
@(private)
_verify_key :: proc(node: ^Node, req: Request) -> bool {
	k, ok := hex_to_key(req.key)
	if !ok do return false
	diff: u8 = 0
	for i in 0 ..< 32 do diff |= k[i] ~ node.blob.master[i]
	return diff == 0
}


// request_destroy frees all heap-allocated fields in a Request.
// Safe to call on requests allocated with any allocator (the allocator used
// for the strings must match the one passed here).
request_destroy :: proc(req: ^Request, allocator := context.allocator) {
	if req.op != "" do delete(req.op, allocator)
	if req.id != "" do delete(req.id, allocator)
	if req.description != "" do delete(req.description, allocator)
	if req.content != "" do delete(req.content, allocator)
	if req.query != "" do delete(req.query, allocator)
	if req.name != "" do delete(req.name, allocator)
	if req.data_path != "" do delete(req.data_path, allocator)
	if req.purpose != "" do delete(req.purpose, allocator)
	if req.agent != "" do delete(req.agent, allocator)
	if req.key != "" do delete(req.key, allocator)
	if req.revises != "" do delete(req.revises, allocator)
	if req.lock_id != "" do delete(req.lock_id, allocator)
	if req.alert_id != "" do delete(req.alert_id, allocator)
	if req.action != "" do delete(req.action, allocator)
	if req.event_type != "" do delete(req.event_type, allocator)
	if req.source != "" do delete(req.source, allocator)
	if req.feedback != "" do delete(req.feedback, allocator)
	if req.mode != "" do delete(req.mode, allocator)
	if req.format != "" do delete(req.format, allocator)
	if req.topic != "" do delete(req.topic, allocator)
	for s in req.items do delete(s, allocator)
	delete(req.items, allocator)
	for s in req.ids do delete(s, allocator)
	delete(req.ids, allocator)
	for s in req.tags do delete(s, allocator)
	delete(req.tags, allocator)
	for s in req.related do delete(s, allocator)
	delete(req.related, allocator)
	for s in req.origin_chain do delete(s, allocator)
	delete(req.origin_chain, allocator)
	if req.tasks != nil {
		for &task in req.tasks {
			if task.name != "" do delete(task.name, allocator)
			if task.op != "" do delete(task.op, allocator)
			if task.key != "" do delete(task.key, allocator)
			if task.description != "" do delete(task.description, allocator)
			if task.content != "" do delete(task.content, allocator)
			if task.query != "" do delete(task.query, allocator)
			if task.id != "" do delete(task.id, allocator)
			if task.agent != "" do delete(task.agent, allocator)
		}
		delete(req.tasks, allocator)
	}
}

dispatch :: proc(node: ^Node, payload: string, allocator := context.allocator) -> string {
	req: Request
	ok: bool

	// Only accept JSON
	req, ok = md_parse_request_json(transmute([]u8)payload, allocator)
	if !ok {
		return _err_response("invalid message (expected JSON)", allocator)
	}
	defer request_destroy(&req, allocator)

	// Daemon-specific ops (register, unregister, heartbeat, registry, discover)
	if node.is_daemon {
		if resp, handled := daemon_dispatch(node, req, allocator); handled {
			return resp
		}
	}

	switch req.op {
	// Gate ops — no key required
	case "description":
		return _op_gate_read(node.blob.description[:], allocator)
	case "positive":
		return _op_gate_read(node.blob.positive[:], allocator)
	case "negative":
		return _op_gate_read(node.blob.negative[:], allocator)
	case "related":
		return _op_gate_read(node.blob.related[:], allocator)
	case "set_description":
		return _op_gate_write(node, &node.blob.description, req.items, allocator)
	case "set_positive":
		return _op_gate_write(node, &node.blob.positive, req.items, allocator)
	case "set_negative":
		return _op_gate_write(node, &node.blob.negative, req.items, allocator)
	case "set_related":
		return _op_gate_write(node, &node.blob.related, req.items, allocator)
	case "link":
		return _op_link(node, req, allocator)
	case "unlink":
		return _op_unlink(node, req, allocator)

	// Catalog ops — plaintext identity card, no key required
	case "catalog":
		return _op_catalog(node, allocator)
	case "set_catalog":
		return _op_set_catalog(node, req, allocator)

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
	case "list":
		return _op_list(node, allocator)
	case "revisions":
		if !_verify_key(node, req) do return _err_response("key required (provide key: <64-hex> in request)", allocator)
		return _op_revisions(node, req, allocator)
	case "delete":
		if !_verify_key(node, req) do return _err_response("key required (provide key: <64-hex> in request)", allocator)
		return _op_delete(node, req, allocator)
	case "query":
		if !_verify_key(node, req) do return _err_response("key required (provide key: <64-hex> in request)", allocator)
		return _op_query(node, req, allocator)
	case "gates":
		return _op_gates(node, allocator)
	case "compact":
		if !_verify_key(node, req) do return _err_response("key required (provide key: <64-hex> in request)", allocator)
		return _op_compact(node, req, allocator)
	case "compact_suggest":
		if !_verify_key(node, req) do return _err_response("key required (provide key: <64-hex> in request)", allocator)
		return _op_compact_suggest(node, req, allocator)
	case "stale":
		if !_verify_key(node, req) do return _err_response("key required (provide key: <64-hex> in request)", allocator)
		return _op_stale(node, req, allocator)
	case "feedback":
		if !_verify_key(node, req) do return _err_response("key required (provide key: <64-hex> in request)", allocator)
		return _op_feedback(node, req, allocator)
	case "manifest":
		return _op_manifest(node, req, allocator)
	case "status":
		return _op_status(node, allocator)
	case "shutdown":
		return _op_shutdown(node, allocator)
	case:
		return _err_response(fmt.tprintf("unknown op: %s", req.op), allocator)
	}
}


@(private)
_op_write :: proc(node: ^Node, req: Request, allocator := context.allocator, daemon_node: ^Node = nil) -> string {
	if req.description == "" do return _err_response("description required", allocator)

	id := new_thought_id()
	pt := Thought_Plaintext {
		description = req.description,
		content     = req.content,
	}
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

	// Incremental compaction: fold the new thought into processed immediately.
	// First thought goes straight to processed; revisions merge their chain;
	// standalone thoughts are moved as-is.
	_incremental_compact(node, thought.id, thought.revises)

	// Scan content for thought ID citations and increment cite_count
	_scan_citations(&node.blob, req.content)

	// Update unified search index — use daemon_node when running inside a slot so the
	// daemon's live index is updated rather than the ephemeral temp_node copy.
	_index_node := daemon_node if daemon_node != nil else node
	index_add_thought(_index_node, node.name, id, req.description)

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
		node.pending_alerts[alert_id] = Pending_Alert {
			alert_id   = strings.clone(alert_id),
			shard_name = strings.clone(node.name),
			agent      = strings.clone(req.agent),
			findings   = findings[:],
			request    = _clone_request(req),
			created_at = strings.clone(now),
		}
		return _marshal(
			Response{status = "ok", id = id_hex, alert_id = alert_id, findings = findings[:]},
			allocator,
		)
	}

	return _marshal(Response{status = "ok", id = id_hex}, allocator)
}

// _incremental_compact folds a just-written thought into the processed block.
// Revision chains are merged; standalone thoughts are moved directly.
@(private)
_incremental_compact :: proc(node: ^Node, new_id: Thought_ID, revises_id: Thought_ID) {
	// If this thought revises another, merge the revision chain.
	if revises_id != ZERO_THOUGHT_ID {
		// Walk up to the chain root
		root := revises_id
		for {
			t, ok := blob_get(&node.blob, root)
			if !ok do break
			if t.revises == ZERO_THOUGHT_ID do break
			root = t.revises
		}
		// Collect the full chain: root + all descendants in the blob
		chain := make([dynamic]Thought_ID, context.temp_allocator)
		append(&chain, root)
		_collect_chain_descendants(&node.blob, root, &chain)
		if new_id != root {
			// Ensure the new thought is in the chain
			found := false
			for cid in chain {
				if cid == new_id {found = true; break}
			}
			if !found do append(&chain, new_id)
		}
		if len(chain) >= 2 {
			_merge_revision_chain(node, root, chain[:], false)
			blob_flush(&node.blob)
			return
		}
	}
	// Standalone thought: move directly to processed.
	ids := []Thought_ID{new_id}
	blob_compact(&node.blob, ids)
}

// _collect_chain_descendants finds all thoughts whose revises field
// points to any member of the chain (breadth-first).
@(private)
_collect_chain_descendants :: proc(b: ^Blob, root: Thought_ID, chain: ^[dynamic]Thought_ID) {
	all_thoughts := make([dynamic]^Thought, context.temp_allocator)
	for &t in b.processed do append(&all_thoughts, &t)
	for &t in b.unprocessed do append(&all_thoughts, &t)

	// BFS: keep scanning until no new members found
	for {
		added := false
		for tp in all_thoughts {
			if tp.revises == ZERO_THOUGHT_ID do continue
			// Check if parent is in chain
			parent_in_chain := false
			for cid in chain {
				if tp.revises == cid {parent_in_chain = true; break}
			}
			if !parent_in_chain do continue
			// Check if already in chain
			already := false
			for cid in chain {
				if tp.id == cid {already = true; break}
			}
			if !already {
				append(chain, tp.id)
				added = true
			}
		}
		if !added do break
	}
}

@(private)
_op_update :: proc(node: ^Node, req: Request, allocator := context.allocator, daemon_node: ^Node = nil) -> string {
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
	new_desc := req.description != "" ? req.description : old_pt.description
	new_content := req.content != "" ? req.content : old_pt.content

	// Re-encrypt with same ID (key derived from ID stays the same)
	pt := Thought_Plaintext {
		description = new_desc,
		content     = new_content,
	}
	new_thought, create_ok := thought_create(node.blob.master, id, pt)
	if !create_ok do return _err_response("thought_create failed", allocator)

	// Preserve plaintext metadata, update timestamp
	new_thought.agent = old_thought.agent
	new_thought.created_at = old_thought.created_at
	new_thought.updated_at = _format_time(time.now())
	// Preserve or update TTL
	new_thought.ttl = req.thought_ttl > 0 ? u32(req.thought_ttl) : old_thought.ttl

	if !blob_put(&node.blob, new_thought) do return _err_response("flush failed", allocator)

	// Update unified search index
	_index_node_upd := daemon_node if daemon_node != nil else node
	index_update_thought(_index_node_upd, node.name, id, new_desc)

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

	return _marshal(
		Response {
			status = "ok",
			description = pt.description,
			content = pt.content,
			agent = thought.agent,
			created_at = thought.created_at,
			updated_at = thought.updated_at,
			revisions = revisions,
		},
		allocator,
	)
}


@(private)
_collect_revisions :: proc(
	b: ^Blob,
	parent_id: Thought_ID,
	allocator := context.allocator,
) -> []string {
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
_op_delete :: proc(node: ^Node, req: Request, allocator := context.allocator, daemon_node: ^Node = nil) -> string {
	id, ok := hex_to_id(req.id)
	if !ok do return _err_response("invalid id", allocator)
	if !blob_remove(&node.blob, id) do return _err_response("delete failed", allocator)
	// Remove from unified search index
	_index_node_del := daemon_node if daemon_node != nil else node
	index_remove_thought(_index_node_del, node.name, id)
	return _marshal(Response{status = "ok"}, allocator)
}

// _op_query — compound search+read: searches, then decrypts top N results.
// Returns results with id, score, description, AND content in one shot.
// Default limit is 5 results. Uses the "thought_count" request field as limit.
@(private)
_op_query :: proc(node: ^Node, req: Request, allocator := context.allocator, daemon_node: ^Node = nil) -> string {
	if req.query == "" do return _err_response("query required", allocator)

	_idx_node := daemon_node if daemon_node != nil else node

	// Fulltext mode: decrypt content bodies and return windowed excerpts
	if req.mode == "fulltext" {
		cfg := config_get()
		ctx_lines := req.context_lines > 0 ? req.context_lines : cfg.fulltext_context_lines
		if ctx_lines <= 0 do ctx_lines = 3
		min_score := cfg.fulltext_min_score
		if min_score <= 0 do min_score = 0.10

		shard_name := node.blob.catalog.name != "" ? node.blob.catalog.name : node.name
		se := _find_indexed_shard(_idx_node, node.name)
		thoughts_for_ft: []Indexed_Thought
		if se != nil do thoughts_for_ft = se.thoughts[:]
		excerpts := fulltext_search(
			thoughts_for_ft,
			node.blob,
			node.blob.master,
			shard_name,
			req.query,
			ctx_lines,
			min_score,
			allocator,
		)
		return _marshal(
			Response {
				status           = "ok",
				mode             = "fulltext",
				fulltext_results = excerpts,
				total_results    = len(excerpts),
			},
			allocator,
		)
	}

	se_query := _find_indexed_shard(_idx_node, node.name)
	if se_query == nil do return _err_response("shard not indexed", allocator)
	hits := index_query_thoughts(se_query, req.query)
	// hits uses context.temp_allocator — no defer delete needed

	default_limit := config_get().default_query_limit
	limit := req.thought_count > 0 ? req.thought_count : default_limit
	agent_filter := req.agent
	_eff_budget :: proc(req_budget: int) -> int {
		cfg := config_get()
		if req_budget > 0 do return req_budget
		if !cfg.smart_query do return 0
		if cfg.llm_url == "" || cfg.llm_model == "" do return 0
		return cfg.default_query_budget
	}
	budget := _eff_budget(req.budget)
	now := time.now()

	wire := make([dynamic]Wire_Result, allocator)
	count := 0
	chars_used := 0
	ai_compacted := false
	for h in hits {
		if count >= limit do break
		thought, found := blob_get(&node.blob, h.id)
		if !found do continue
		if agent_filter != "" && thought.agent != agent_filter do continue

		pt, err := thought_decrypt(thought, node.blob.master, allocator)
		if err != .None do continue

		new_content, new_truncated, new_chars, was_ai_compacted := _truncate_to_budget(
			pt.content,
			budget,
			chars_used,
		)
		chars_used = new_chars
		if was_ai_compacted do ai_compacted = true

		composite := _composite_score(h.score, thought, now)
		append(
			&wire,
			Wire_Result {
				id = id_to_hex(h.id, allocator),
				score = composite,
				description = pt.description,
				content = new_content,
				truncated = new_truncated,
				relevance_score = composite,
			},
		)
		count += 1
	}
	if ai_compacted {
		event_node := daemon_node
		if event_node == nil do event_node = node
		if event_node.is_daemon {
			_emit_event(event_node, node.name, "knowledge_changed", req.agent)
		}
	}
	if req.format == "dump" {
		b := strings.builder_make(allocator)
		title := node.blob.catalog.name != "" ? node.blob.catalog.name : node.name
		fmt.sbprintf(&b, "# %s\n", title)
		if node.blob.catalog.purpose != "" {
			fmt.sbprintf(&b, "\n%s\n", node.blob.catalog.purpose)
		}
		if len(wire) > 0 {
			strings.write_string(&b, "\n## Knowledge\n")
			for r in wire {
				fmt.sbprintf(&b, "\n### %s\n\n%s\n", r.description, r.content)
			}
		}
		return _marshal(Response{status = "ok", content = strings.to_string(b)}, allocator)
	}
	return _marshal(Response{status = "ok", results = wire[:]}, allocator)
}

// _op_gates — return all gates (description, positive, negative, related) in one response.
@(private)
_op_gates :: proc(node: ^Node, allocator := context.allocator) -> string {
	return _marshal(
		Response {
			status        = "ok",
			gate_desc     = node.blob.description[:],
			gate_positive = node.blob.positive[:],
			gate_negative = node.blob.negative[:],
			gate_related  = node.blob.related[:],
		},
		allocator,
	)
}

@(private)
_op_compact :: proc(node: ^Node, req: Request, allocator := context.allocator, daemon_node: ^Node = nil) -> string {
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
	chains: map[Thought_ID][dynamic]Thought_ID // root -> [root, child1, child2, ...]
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

	cfg := config_get()
	mode := req.mode != "" ? req.mode : cfg.compact_mode
	lossy := mode == "lossy"

	moved := 0

	// Move standalone thoughts as before
	if len(standalone) > 0 {
		moved += blob_compact(&node.blob, standalone[:])
	}

	// Merge each revision chain
	for root_id, chain_ids in chains {
		merged_ok := _merge_revision_chain(node, root_id, chain_ids[:], lossy, daemon_node)
		if merged_ok do moved += len(chain_ids)
	}

	// Post-compaction validation — verify processed thoughts are readable
	validated := 0
	for t in node.blob.processed {
		pt, err := thought_decrypt(t, node.blob.master, context.temp_allocator)
		if err == .None {
			validated += 1
			delete(pt.description, context.temp_allocator)
			delete(pt.content, context.temp_allocator)
		}
	}

	return _marshal(Response{status = "ok", moved = moved}, allocator)
}

// _merge_revision_chain decrypts all thoughts in a chain, merges their content
// with agent attribution, re-encrypts as a single thought under the root ID,
// places it in processed, and removes the individual chain members.
@(private)
_merge_revision_chain :: proc(
	node: ^Node,
	root_id: Thought_ID,
	chain_ids: []Thought_ID,
	lossy := false,
	daemon_node: ^Node = nil,
) -> bool {
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
		append(
			&entries,
			Decrypted {
				id = cid,
				description = pt.description,
				content = pt.content,
				agent = thought.agent,
				created_at = thought.created_at,
			},
		)
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

	// Build merged content
	merged_content: string
	if lossy {
		// Lossy mode: only keep the latest revision's content
		latest := entries[len(entries) - 1]
		root_desc = latest.description
		merged_content = latest.content
	} else {
		// Lossless mode: concatenate all revisions with agent attribution
		b := strings.builder_make(context.temp_allocator)
		for entry, i in entries {
			if i > 0 do strings.write_string(&b, "\n\n")
			agent := entry.agent != "" ? entry.agent : "unknown"
			fmt.sbprintf(&b, "[%s @ %s]:\n%s", agent, entry.created_at, entry.content)
		}
		merged_content = strings.to_string(b)
	}

	// Create the merged thought under the root ID
	pt := Thought_Plaintext {
		description = root_desc,
		content     = merged_content,
	}
	merged_thought, create_ok := thought_create(node.blob.master, root_id, pt)
	if !create_ok do return false

	// Set metadata on merged thought
	merged_thought.agent = strings.clone("compaction")
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
		// Remove from unified search index
		_idx := daemon_node if daemon_node != nil else node
		index_remove_thought(_idx, node.name, cid)
	}

	// Place merged thought in processed block
	append(&node.blob.processed, merged_thought)

	// Add merged thought to unified search index
	_idx2 := daemon_node if daemon_node != nil else node
	index_add_thought(_idx2, node.name, root_id, root_desc)

	blob_flush(&node.blob)
	return true
}

// =============================================================================
// compact_suggest — analyze shard and return merge/prune proposals
// =============================================================================

@(private)
_op_compact_suggest :: proc(node: ^Node, req: Request, allocator := context.allocator) -> string {
	cfg := config_get()
	mode := req.mode != "" ? req.mode : cfg.compact_mode
	suggestions := make([dynamic]Compact_Suggestion, allocator)

	// All thought IDs (both blocks) for analysis
	all_thoughts := make([dynamic]Thought, context.temp_allocator)
	for t in node.blob.unprocessed do append(&all_thoughts, t)
	for t in node.blob.processed do append(&all_thoughts, t)

	if len(all_thoughts) == 0 {
		return _marshal(Response{status = "ok", suggestions = suggestions[:]}, allocator)
	}

	// 1. Find revision chains — groups where thought.revises points to another thought
	revises_map := make(map[Thought_ID]Thought_ID, allocator = context.temp_allocator) // child -> parent
	id_set := make(map[Thought_ID]bool, allocator = context.temp_allocator)
	for t in all_thoughts {
		id_set[t.id] = true
		if t.revises != ZERO_THOUGHT_ID {
			revises_map[t.id] = t.revises
		}
	}

	// Group chains by root
	chain_roots := make(map[Thought_ID][dynamic]Thought_ID, allocator = context.temp_allocator)
	for child_id, parent_id in revises_map {
		// Walk up to root
		root := parent_id
		for {
			if grand, ok := revises_map[root]; ok {
				root = grand
			} else {
				break
			}
		}
		if root not_in chain_roots {
			chain_roots[root] = make([dynamic]Thought_ID, context.temp_allocator)
			append(&chain_roots[root], root)
		}
		// Only append child if not already present
		found := false
		for existing in chain_roots[root] {
			if existing == child_id {found = true; break}
		}
		if !found do append(&chain_roots[root], child_id)
	}

	for root_id, chain_ids in chain_roots {
		if len(chain_ids) < 2 do continue // no chain to merge

		ids := make([]string, len(chain_ids), allocator)
		for cid, i in chain_ids {
			ids[i] = id_to_hex(cid, allocator)
		}

		// Decrypt root for description
		root_desc := "revision chain"
		if thought, found := blob_get(&node.blob, root_id); found {
			pt, err := thought_decrypt(thought, node.blob.master, context.temp_allocator)
			if err == .None {
				root_desc = fmt.aprintf(
					"%d revisions of \"%s\"",
					len(chain_ids),
					pt.description,
					allocator = allocator,
				)
				delete(pt.description, context.temp_allocator)
				delete(pt.content, context.temp_allocator)
			}
		}

		append(
			&suggestions,
			Compact_Suggestion {
				kind = "revision_chain",
				ids = ids,
				description = root_desc,
				action = "merge",
			},
		)
	}

	// 2. Find potential duplicates — thoughts with very similar descriptions
	Decrypted_Info :: struct {
		id:          Thought_ID,
		description: string,
		content_len: int,
		stale_score: f32,
	}

	decrypted := make([dynamic]Decrypted_Info, context.temp_allocator)
	now := time.now()

	for t in all_thoughts {
		pt, err := thought_decrypt(t, node.blob.master, context.temp_allocator)
		if err != .None do continue
		defer delete(pt.content, context.temp_allocator)

		stale := f32(0.0)
		if t.ttl > 0 {
			age := f32(
				time.duration_seconds(
					time.diff(
						t.updated_at != "" ? _parse_rfc3339(t.updated_at) : _parse_rfc3339(t.created_at),
						now,
					),
				),
			)
			stale = age / f32(t.ttl)
		}

		append(
			&decrypted,
			Decrypted_Info {
				id          = t.id,
				description = pt.description, // kept alive in temp_allocator
				content_len = len(pt.content),
				stale_score = stale,
			},
		)
	}

	// Compare descriptions for duplicates (simple token overlap)
	for i := 0; i < len(decrypted); i += 1 {
		for j := i + 1; j < len(decrypted); j += 1 {
			a := decrypted[i]
			b := decrypted[j]
			// Skip if both are already in a revision chain
			a_in_chain := a.id in revises_map || a.id in chain_roots
			b_in_chain := b.id in revises_map || b.id in chain_roots
			if a_in_chain && b_in_chain do continue

			similarity := _description_similarity(a.description, b.description)
			if similarity >= 0.8 {
				ids := make([]string, 2, allocator)
				ids[0] = id_to_hex(a.id, allocator)
				ids[1] = id_to_hex(b.id, allocator)
				desc := fmt.aprintf(
					"similar descriptions: \"%s\" ≈ \"%s\"",
					a.description,
					b.description,
					allocator = allocator,
				)
				append(
					&suggestions,
					Compact_Suggestion {
						kind = "duplicate",
						ids = ids,
						description = desc,
						action = "deduplicate",
					},
				)
			}
		}
	}

	// 3. In lossy mode, find stale thoughts that could be pruned
	if mode == "lossy" {
		for info in decrypted {
			if info.stale_score > 1.0 {
				ids := make([]string, 1, allocator)
				ids[0] = id_to_hex(info.id, allocator)
				desc := fmt.aprintf(
					"stale (%.1f× past TTL): \"%s\"",
					info.stale_score,
					info.description,
					allocator = allocator,
				)
				append(
					&suggestions,
					Compact_Suggestion {
						kind = "stale",
						ids = ids,
						description = desc,
						action = "prune",
					},
				)
			}
		}
	}

	return _marshal(Response{status = "ok", suggestions = suggestions[:]}, allocator)
}

// _description_similarity computes a simple token Jaccard similarity (0.0-1.0)
@(private)
_description_similarity :: proc(a: string, b: string) -> f32 {
	a_tokens := _tokenize(a, context.temp_allocator)
	defer delete(a_tokens, context.temp_allocator)
	b_tokens := _tokenize(b, context.temp_allocator)
	defer delete(b_tokens, context.temp_allocator)

	if len(a_tokens) == 0 && len(b_tokens) == 0 do return 1.0
	if len(a_tokens) == 0 || len(b_tokens) == 0 do return 0.0

	intersection := 0
	for at in a_tokens {
		for bt in b_tokens {
			if at == bt {
				intersection += 1
				break
			}
		}
	}

	union_size := len(a_tokens) + len(b_tokens) - intersection
	if union_size == 0 do return 0.0
	return f32(intersection) / f32(union_size)
}

@(private)
_op_dump :: proc(node: ^Node, req: Request, allocator := context.allocator) -> string {
	cat := node.blob.catalog
	b := strings.builder_make(allocator)

	// --- frontmatter ---
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

	// --- Filter by query if provided ---
	query := req.query
	q_tokens: []string
	if query != "" {
		q_tokens = _tokenize(query, context.temp_allocator)
		defer delete(q_tokens, context.temp_allocator)
	}

	filtered_processed := make([dynamic]Thought, allocator)
	filtered_unprocessed := make([dynamic]Thought, allocator)

	// Filter processed thoughts
	for thought in node.blob.processed {
		pt, err := thought_decrypt(thought, node.blob.master, context.temp_allocator)
		if err != .None do continue
		defer {
			delete(pt.description, context.temp_allocator)
			delete(pt.content, context.temp_allocator)
		}
		if query == "" || _thought_matches_tokens(pt, q_tokens) {
			append(&filtered_processed, thought)
		}
	}

	// Filter unprocessed thoughts
	for thought in node.blob.unprocessed {
		pt, err := thought_decrypt(thought, node.blob.master, context.temp_allocator)
		if err != .None do continue
		defer {
			delete(pt.description, context.temp_allocator)
			delete(pt.content, context.temp_allocator)
		}
		if query == "" || _thought_matches_tokens(pt, q_tokens) {
			append(&filtered_unprocessed, thought)
		}
	}

	total := len(filtered_processed) + len(filtered_unprocessed)
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

	// --- Decrypt and render filtered thoughts ---
	has_processed := len(filtered_processed) > 0
	has_unprocessed := len(filtered_unprocessed) > 0

	if has_processed {
		strings.write_string(&b, "\n## Knowledge\n")
		for thought in filtered_processed {
			_dump_thought(&b, thought, node.blob.master)
		}
	}

	if has_unprocessed {
		strings.write_string(&b, "\n## Unprocessed\n")
		for thought in filtered_unprocessed {
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
	return _marshal(
		Response{status = "ok", node_name = node.name, thoughts = total, uptime_secs = uptime},
		allocator,
	)
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
_op_gate_write :: proc(
	node: ^Node,
	field: ^[dynamic]string,
	items: []string,
	allocator := context.allocator,
) -> string {
	for &s in field do delete(s)
	clear(field)
	for s in items do append(field, strings.clone(s))
	if !blob_flush(&node.blob) do return _err_response("flush failed", allocator)
	return _marshal(Response{status = "ok"}, allocator)
}


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
			if existing == item {already = true; break}
		}
		if already do continue
		if len(node.blob.related) >= _max_related() {
			return _err_response(
				fmt.tprintf("related list full (max %d)", _max_related()),
				allocator,
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

@(private)
_increment_read_count :: proc(b: ^Blob, id: Thought_ID) {
	for &t in b.processed {
		if t.id == id {t.read_count += 1; if b.path != "" do blob_flush(b); return}
	}
	for &t in b.unprocessed {
		if t.id == id {t.read_count += 1; if b.path != "" do blob_flush(b); return}
	}
}

@(private)
_scan_citations :: proc(b: ^Blob, content: string) {
	if len(content) < 32 do return
	cited := false
	for i := 0; i <= len(content) - 32; i += 1 {
		candidate := content[i:i + 32]
		cid, ok := hex_to_id(candidate)
		if !ok do continue
		// Check if this ID exists in the blob
		for &t in b.processed {
			if t.id == cid {t.cite_count += 1; cited = true; break}
		}
		for &t in b.unprocessed {
			if t.id == cid {t.cite_count += 1; cited = true; break}
		}
	}
	if cited && b.path != "" do blob_flush(b)
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
		append(
			&wire,
			Wire_Result {
				id = id_to_hex(entry.id, allocator),
				score = entry.staleness_score,
				description = pt.description,
				content = pt.content,
				staleness_score = entry.staleness_score,
			},
		)
	}

	return _marshal(Response{status = "ok", results = wire[:]}, allocator)
}

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
		if t.id == id {thought_ptr = &t; break}
	}
	if thought_ptr == nil {
		for &t in node.blob.unprocessed {
			if t.id == id {thought_ptr = &t; break}
		}
	}
	if thought_ptr == nil do return _err_response("thought not found", allocator)

	if req.feedback == "endorse" {
		thought_ptr.cite_count += 5 // endorsement = strong positive signal
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

@(private)
_clone_request :: proc(req: Request, allocator := context.allocator) -> Request {
	return Request {
		op = strings.clone(req.op, allocator),
		id = strings.clone(req.id, allocator),
		description = strings.clone(req.description, allocator),
		content = strings.clone(req.content, allocator),
		query = strings.clone(req.query, allocator),
		items = _clone_strings(req.items, allocator),
		ids = _clone_strings(req.ids, allocator),
		name = strings.clone(req.name, allocator),
		data_path = strings.clone(req.data_path, allocator),
		thought_count = req.thought_count,
		agent = strings.clone(req.agent, allocator),
		key = strings.clone(req.key, allocator),
		purpose = strings.clone(req.purpose, allocator),
		tags = _clone_strings(req.tags, allocator),
		related = _clone_strings(req.related, allocator),
		max_depth = req.max_depth,
		max_branches = req.max_branches,
		layer = req.layer,
		revises = strings.clone(req.revises, allocator),
		lock_id = strings.clone(req.lock_id, allocator),
		ttl = req.ttl,
		alert_id = strings.clone(req.alert_id, allocator),
		action = strings.clone(req.action, allocator),
		event_type = strings.clone(req.event_type, allocator),
		source = strings.clone(req.source, allocator),
		origin_chain = _clone_strings(req.origin_chain, allocator),
		limit = req.limit,
		budget = req.budget,
		thought_ttl = req.thought_ttl,
		freshness_weight = req.freshness_weight,
		feedback = strings.clone(req.feedback, allocator),
	}
}


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
	data := md_marshal_response_json(resp, allocator)
	// Convert the byte array to a string (JSON is valid UTF-8)
	return transmute(string)data
}

@(private)
_err_response :: proc(msg: string, allocator := context.allocator) -> string {
	return _marshal(Response{status = "error", err = msg}, allocator)
}

// _serialize_thought_v4 writes a thought in V4 format (no TTL field).
@(private)
_serialize_thought_v4 :: proc(buf: ^[dynamic]u8, n: Thought) {
	id := n.id
	for b in id do append(buf, b)

	_append_u32(buf, u32(len(n.seal_blob)))
	for b in n.seal_blob do append(buf, b)

	_append_u32(buf, u32(len(n.body_blob)))
	for b in n.body_blob do append(buf, b)

	agent_bytes := transmute([]u8)n.agent
	agent_len := min(len(agent_bytes), 255)
	append(buf, u8(agent_len))
	for i in 0 ..< agent_len do append(buf, agent_bytes[i])

	created_bytes := transmute([]u8)n.created_at
	created_len := min(len(created_bytes), 255)
	append(buf, u8(created_len))
	for i in 0 ..< created_len do append(buf, created_bytes[i])

	updated_bytes := transmute([]u8)n.updated_at
	updated_len := min(len(updated_bytes), 255)
	append(buf, u8(updated_len))
	for i in 0 ..< updated_len do append(buf, updated_bytes[i])

	rev := n.revises
	for b in rev do append(buf, b)
	// NOTE: no TTL field — this is V4 format
}

// _serialize_thought_v5 writes a thought in V5 format (has TTL, no counters).
@(private)
_serialize_thought_v5 :: proc(buf: ^[dynamic]u8, n: Thought) {
	id := n.id
	for b in id do append(buf, b)

	_append_u32(buf, u32(len(n.seal_blob)))
	for b in n.seal_blob do append(buf, b)

	_append_u32(buf, u32(len(n.body_blob)))
	for b in n.body_blob do append(buf, b)

	agent_bytes := transmute([]u8)n.agent
	agent_len := min(len(agent_bytes), 255)
	append(buf, u8(agent_len))
	for i in 0 ..< agent_len do append(buf, agent_bytes[i])

	created_bytes := transmute([]u8)n.created_at
	created_len := min(len(created_bytes), 255)
	append(buf, u8(created_len))
	for i in 0 ..< created_len do append(buf, created_bytes[i])

	updated_bytes := transmute([]u8)n.updated_at
	updated_len := min(len(updated_bytes), 255)
	append(buf, u8(updated_len))
	for i in 0 ..< updated_len do append(buf, updated_bytes[i])

	rev := n.revises
	for b in rev do append(buf, b)

	// TTL: u32 LE
	_append_u32(buf, n.ttl)
	// NOTE: no read_count/cite_count — this is V5 format
}
