package shard

import "core:fmt"
import "core:math"
import "core:strings"
import "core:time"
import "core:unicode"

import logger "logger"
import "core:crypto/hash"
import "core:os"
import "core:testing"


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


dispatch :: proc(node: ^Node, payload: string, allocator := context.allocator) -> string {
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
	case "search":
		if !_verify_key(node, req) do return _err_response("key required (provide key: <64-hex> in request)", allocator)
		return _op_search(node, req, allocator)
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
	case "dump":
		if !_verify_key(node, req) do return _err_response("key required (provide key: <64-hex> in request)", allocator)
		return _op_dump(node, req, allocator)
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
_op_write :: proc(node: ^Node, req: Request, allocator := context.allocator) -> string {
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

	// Update search index
	entry := Search_Entry {
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
				if cid == new_id { found = true; break }
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
	for &t in b.processed  do append(&all_thoughts, &t)
	for &t in b.unprocessed do append(&all_thoughts, &t)

	// BFS: keep scanning until no new members found
	for {
		added := false
		for tp in all_thoughts {
			if tp.revises == ZERO_THOUGHT_ID do continue
			// Check if parent is in chain
			parent_in_chain := false
			for cid in chain {
				if tp.revises == cid { parent_in_chain = true; break }
			}
			if !parent_in_chain do continue
			// Check if already in chain
			already := false
			for cid in chain {
				if tp.id == cid { already = true; break }
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
		append(
			&wire,
			Wire_Result {
				id = id_to_hex(h.id, allocator),
				score = composite,
				description = desc,
				relevance_score = composite,
			},
		)
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

		new_content, new_truncated, _ := _truncate_to_budget(pt.content, budget, chars_used)

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
		merged_ok := _merge_revision_chain(node, root_id, chain_ids[:], lossy)
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
_merge_revision_chain :: proc(node: ^Node, root_id: Thought_ID, chain_ids: []Thought_ID, lossy := false) -> bool {
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
	entry := Search_Entry {
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
			if existing == child_id { found = true; break }
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
				root_desc = fmt.aprintf("%d revisions of \"%s\"", len(chain_ids), pt.description, allocator = allocator)
				delete(pt.description, context.temp_allocator)
				delete(pt.content, context.temp_allocator)
			}
		}

		append(&suggestions, Compact_Suggestion {
			kind        = "revision_chain",
			ids         = ids,
			description = root_desc,
			action      = "merge",
		})
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
			age := f32(time.duration_seconds(time.diff(t.updated_at != "" ? _parse_rfc3339(t.updated_at) : _parse_rfc3339(t.created_at), now)))
			stale = age / f32(t.ttl)
		}

		append(&decrypted, Decrypted_Info {
			id          = t.id,
			description = pt.description, // kept alive in temp_allocator
			content_len = len(pt.content),
			stale_score = stale,
		})
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
				desc := fmt.aprintf("similar descriptions: \"%s\" ≈ \"%s\"",
					a.description, b.description, allocator = allocator)
				append(&suggestions, Compact_Suggestion {
					kind        = "duplicate",
					ids         = ids,
					description = desc,
					action      = "deduplicate",
				})
			}
		}
	}

	// 3. In lossy mode, find stale thoughts that could be pruned
	if mode == "lossy" {
		for info in decrypted {
			if info.stale_score > 1.0 {
				ids := make([]string, 1, allocator)
				ids[0] = id_to_hex(info.id, allocator)
				desc := fmt.aprintf("stale (%.1f× past TTL): \"%s\"",
					info.stale_score, info.description, allocator = allocator)
				append(&suggestions, Compact_Suggestion {
					kind        = "stale",
					ids         = ids,
					description = desc,
					action      = "prune",
				})
			}
		}
	}

	return _marshal(
		Response {
			status = "ok",
			suggestions = suggestions[:],
		},
		allocator,
	)
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


build_search_index :: proc(
	index: ^[dynamic]Search_Entry,
	blob: Blob,
	master: Master_Key,
	label: string = "",
) -> bool {
	for &entry in index do delete(entry.embedding)
	clear(index)

	descriptions := make([dynamic]string, context.temp_allocator)
	decrypted_any := false

	_index_thoughts :: proc(
		thoughts: []Thought,
		master: Master_Key,
		index: ^[dynamic]Search_Entry,
		descriptions: ^[dynamic]string,
	) -> bool {
		any := false
		for thought in thoughts {
			pt, err := thought_decrypt(thought, master, context.temp_allocator)
			if err == .None {
				desc := strings.clone(pt.description)
				append(
					index,
					Search_Entry{id = thought.id, description = desc, text_hash = fnv_hash(desc)},
				)
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
			if label != "" do logger.debugf("%s: embedded %d thoughts", label, len(index))
		}
	}

	return decrypted_any
}

search_query :: proc(
	entries: []Search_Entry,
	query: string,
	allocator := context.allocator,
) -> []Search_Result {
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
_vector_search :: proc(
	entries: []Search_Entry,
	query: string,
	allocator := context.allocator,
) -> []Search_Result {
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
_keyword_search :: proc(
	entries: []Search_Entry,
	query: string,
	allocator := context.allocator,
) -> []Search_Result {
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
			if qt == dt || qt_stem == _stem(dt) {matches += 1; break}
		}
	}
	return f32(matches) / f32(len(q_tokens))
}

_stem :: proc(token: string) -> string {
	suffixes := [?]string {
		"tion",
		"sion",
		"ment",
		"ness",
		"ing",
		"ous",
		"ive",
		"ble",
		"ed",
		"er",
		"ly",
		"es",
		"s",
	}
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
	start := -1
	for i := 0; i < len(s); i += 1 {
		c := rune(s[i])
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

// Check if a decrypted thought matches any of the query tokens
@(private)
_thought_matches_tokens :: proc(pt: Thought_Plaintext, tokens: []string) -> bool {
	if len(tokens) == 0 do return true

	// Check description
	desc_lower := strings.to_lower(pt.description, context.temp_allocator)
	defer delete(desc_lower, context.temp_allocator)

	for t in tokens {
		if strings.contains(desc_lower, t) {
			return true
		}
	}

	// Check content
	if pt.content != "" {
		content_lower := strings.to_lower(pt.content, context.temp_allocator)
		defer delete(content_lower, context.temp_allocator)
		for t in tokens {
			if strings.contains(content_lower, t) {
				return true
			}
		}
	}

	return false
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

// _composite_score blends keyword/vector match, freshness, and usage into one score.
// Formula: (match * (kw+vw)) + (freshness * fw) + (usage * uw)
// where kw+vw+fw+uw should sum to ~1.0 (configurable).
@(private)
_composite_score :: proc(base_score: f32, thought: Thought, now: time.Time) -> f32 {
	cfg := config_get()

	// Guard: if all weights are zero, return base_score
	total_weight :=
		cfg.relevance_keyword_weight +
		cfg.relevance_vector_weight +
		cfg.relevance_freshness_weight +
		cfg.relevance_usage_weight
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
	for i in 0 ..< 4 {
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

// =============================================================================
// Search tests
// =============================================================================

// =============================================================================
// Search tests
// =============================================================================

@(test)
test_keyword_search_basic :: proc(t: ^testing.T) {
	entries := []Search_Entry{
		{description = "meeting notes about the roadmap", text_hash = fnv_hash("meeting notes about the roadmap")},
		{description = "grocery list for the weekend", text_hash = fnv_hash("grocery list for the weekend")},
		{description = "roadmap priorities for Q2", text_hash = fnv_hash("roadmap priorities for Q2")},
	}
	results := search_query(entries, "roadmap")
	defer delete(results)
	testing.expect(t, len(results) >= 2, "should find at least 2 roadmap matches")
}

@(test)
test_keyword_search_no_match :: proc(t: ^testing.T) {
	entries := []Search_Entry{
		{description = "meeting notes", text_hash = fnv_hash("meeting notes")},
	}
	results := search_query(entries, "quantum physics")
	defer delete(results)
	testing.expect(t, len(results) == 0, "should find no matches")
}

// =============================================================================
// Dispatch tests
// =============================================================================

// =============================================================================
// Dispatch tests — op routing
// =============================================================================

@(test)
test_dispatch_unknown_op :: proc(t: ^testing.T) {
	node := Node{
		blob = Blob{
			processed   = make([dynamic]Thought),
			unprocessed = make([dynamic]Thought),
			description = make([dynamic]string),
			positive    = make([dynamic]string),
			negative    = make([dynamic]string),
			related     = make([dynamic]string),
		},
	}
	result := dispatch(&node, "---\nop: nonexistent\n---\n")
	testing.expect(t, strings.contains(result, "unknown op"), "unknown op must return error")
}

@(test)
test_dispatch_list_empty :: proc(t: ^testing.T) {
	node := Node{
		blob = Blob{
			processed   = make([dynamic]Thought),
			unprocessed = make([dynamic]Thought),
			description = make([dynamic]string),
			positive    = make([dynamic]string),
			negative    = make([dynamic]string),
			related     = make([dynamic]string),
		},
	}
	result := dispatch(&node, "---\nop: list\n---\n")
	testing.expect(t, strings.contains(result, "status: ok"), "list on empty blob must succeed")
}

@(test)
test_dispatch_status :: proc(t: ^testing.T) {
	node := Node{
		name = "test-node",
		blob = Blob{
			processed   = make([dynamic]Thought),
			unprocessed = make([dynamic]Thought),
			description = make([dynamic]string),
			positive    = make([dynamic]string),
			negative    = make([dynamic]string),
			related     = make([dynamic]string),
		},
	}
	result := dispatch(&node, "---\nop: status\n---\n")
	testing.expect(t, strings.contains(result, "node_name: test-node"), "status must return node name")
}

// =============================================================================
// Staleness TTL tests
// =============================================================================

// =============================================================================
// Staleness TTL tests
// =============================================================================

@(test)
test_staleness_score_immortal :: proc(t: ^testing.T) {
	thought := Thought{ttl = 0, updated_at = "2020-01-01T00:00:00Z"}
	score := _compute_staleness(thought, time.now())
	testing.expect(t, score == 0, "ttl=0 (immortal) must always return staleness 0")
}

@(test)
test_staleness_score_fresh :: proc(t: ^testing.T) {
	// A thought updated "now" with a 1-hour TTL should have very low staleness
	now := time.now()
	now_str := _format_time(now)
	thought := Thought{ttl = 3600, updated_at = now_str}
	score := _compute_staleness(thought, now)
	testing.expect(t, score < 0.01, "recently updated thought must have near-zero staleness")
}

@(test)
test_staleness_score_expired :: proc(t: ^testing.T) {
	// A thought with 60s TTL updated 120 seconds ago should be clamped to 1.0
	now := time.now()
	old := time.time_add(now, -120 * time.Second)
	old_str := _format_time(old)
	thought := Thought{ttl = 60, updated_at = old_str}
	score := _compute_staleness(thought, now)
	testing.expect(t, score >= 1.0, "expired thought must have staleness clamped to 1.0")
}

@(test)
test_stale_op :: proc(t: ^testing.T) {
	key := Master_Key{1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32}
	key_hex := _make_test_key_hex(key)
	now := time.now()

	// Create an immortal thought (should NOT appear in stale results)
	id1 := new_thought_id()
	pt1 := Thought_Plaintext{description = "immortal thought", content = "never stale"}
	thought1, _ := thought_create(key, id1, pt1)
	thought1.ttl = 0
	thought1.updated_at = _format_time(now)

	// Create a stale thought (TTL=60s, updated 120s ago)
	id2 := new_thought_id()
	pt2 := Thought_Plaintext{description = "stale thought", content = "needs review"}
	thought2, _ := thought_create(key, id2, pt2)
	thought2.ttl = 60
	thought2.updated_at = _format_time(time.time_add(now, -120 * time.Second))

	blob := Blob{
		processed   = make([dynamic]Thought),
		unprocessed = make([dynamic]Thought),
		description = make([dynamic]string),
		positive    = make([dynamic]string),
		negative    = make([dynamic]string),
		related     = make([dynamic]string),
		master      = key,
	}
	append(&blob.unprocessed, thought1)
	append(&blob.unprocessed, thought2)

	node := Node{
		blob  = blob,
		index = make([dynamic]Search_Entry),
	}

	result := dispatch(&node, fmt.tprintf("---\nop: stale\nkey: %s\nfreshness_weight: 0.5\n---\n", key_hex))
	testing.expect(t, strings.contains(result, "status: ok"), "stale op must return ok")
	testing.expect(t, strings.contains(result, "stale thought"), "stale thought must appear")
	testing.expect(t, !strings.contains(result, "immortal thought"), "immortal thought must NOT appear")
}

@(test)
test_ttl_serialization :: proc(t: ^testing.T) {
	master: Master_Key
	master[0] = 0x42
	id := new_thought_id()
	pt := Thought_Plaintext{description = "ttl test", content = "ttl body"}
	thought, _ := thought_create(master, id, pt)
	thought.agent = "test-agent"
	thought.created_at = "2026-03-16T00:00:00Z"
	thought.updated_at = "2026-03-16T00:00:00Z"
	thought.ttl = 3600 // 1 hour

	buf := make([dynamic]u8)
	defer delete(buf)
	thought_serialize_bin(&buf, thought)

	pos := 0
	parsed, err := thought_parse_bin(buf[:], &pos)
	testing.expect(t, err == .None, "parse_bin should succeed")
	testing.expect(t, parsed.id == thought.id, "id must round-trip")
	testing.expect(t, parsed.ttl == 3600, "ttl must round-trip")
}

@(test)
test_format_migration_v4 :: proc(t: ^testing.T) {
	// Build a SHRD0004-format blob manually: serialize a thought WITHOUT TTL
	master: Master_Key
	master[0] = 0xCC
	id := new_thought_id()
	pt := Thought_Plaintext{description = "v4 thought", content = "v4 body"}
	thought, _ := thought_create(master, id, pt)
	thought.agent = "v4-agent"
	thought.created_at = "2026-01-01T00:00:00Z"
	thought.updated_at = "2026-01-01T00:00:00Z"

	// Build the blob binary manually using V4 format
	buf := make([dynamic]u8)
	defer delete(buf)

	// processed block: 0 thoughts
	_append_u32(&buf, 0)

	// unprocessed block: 1 thought (V4 format = no TTL)
	_append_u32(&buf, 1)
	_serialize_thought_v4(&buf, thought)

	// catalog block: empty
	_append_u32(&buf, 0)

	// manifest block: empty
	_append_u32(&buf, 0)

	// gates block: empty (4 empty gate lists = 4 x u16(0))
	gates_start := len(buf)
	_append_u16(&buf, 0) // description
	_append_u16(&buf, 0) // positive
	_append_u16(&buf, 0) // negative
	_append_u16(&buf, 0) // related
	gates_size := len(buf) - gates_start

	// Compute hash of content
	content_hash: [32]u8
	hash.hash_bytes_to_buffer(.SHA256, buf[:], content_hash[:])

	// Footer: [gates_size:u32][hash:32][magic:u64]
	footer: [FOOTER_SIZE]u8
	_put_u32(footer[0:], u32(gates_size))
	copy(footer[4:36], content_hash[:])
	_put_u64(footer[36:], SHARD_MAGIC_V4) // V4 magic!

	for b in footer do append(&buf, b)

	// Write to a temp file
	tmp_path := ".shards/_test_v4_migration.shard"
	os.make_directory(".shards")
	os.write_entire_file(tmp_path, buf[:])
	defer os.remove(tmp_path)

	// Load with new code — should migrate V4 thoughts with ttl=0
	blob, ok := blob_load(tmp_path, master)
	testing.expect(t, ok, "blob_load must succeed for V4 format")
	testing.expect(t, len(blob.unprocessed) == 1, "must load 1 unprocessed thought")
	if len(blob.unprocessed) > 0 {
		testing.expect(t, blob.unprocessed[0].ttl == 0, "V4 migrated thought must have ttl=0 (immortal)")
		testing.expect(t, blob.unprocessed[0].id == id, "thought ID must match")
	}
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

@(test)
test_parse_rfc3339 :: proc(t: ^testing.T) {
	ts := _parse_rfc3339("2026-03-16T12:34:56Z")
	zero_time: time.Time
	testing.expect(t, ts != zero_time, "must parse valid RFC3339 timestamp")

	bad := _parse_rfc3339("not a timestamp")
	testing.expect(t, bad == zero_time, "must return zero for invalid input")
}

// =============================================================================
// Relevance scoring tests
// =============================================================================

// =============================================================================
// Relevance scoring tests
// =============================================================================

@(test)
test_counter_serialization :: proc(t: ^testing.T) {
	master: Master_Key
	master[0] = 0x55
	id := new_thought_id()
	pt := Thought_Plaintext{description = "counter test", content = "counter body"}
	thought, _ := thought_create(master, id, pt)
	thought.agent = "test-agent"
	thought.created_at = "2026-03-16T00:00:00Z"
	thought.updated_at = "2026-03-16T00:00:00Z"
	thought.ttl = 3600
	thought.read_count = 42
	thought.cite_count = 7

	buf := make([dynamic]u8)
	defer delete(buf)
	thought_serialize_bin(&buf, thought)

	pos := 0
	parsed, err := thought_parse_bin(buf[:], &pos)
	testing.expect(t, err == .None, "parse_bin should succeed")
	testing.expect(t, parsed.id == thought.id, "id must round-trip")
	testing.expect(t, parsed.ttl == 3600, "ttl must round-trip")
	testing.expect(t, parsed.read_count == 42, "read_count must round-trip")
	testing.expect(t, parsed.cite_count == 7, "cite_count must round-trip")
}

@(test)
test_v5_migration :: proc(t: ^testing.T) {
	// Build a SHRD0005-format blob: serialize a thought WITH TTL but WITHOUT counters
	master: Master_Key
	master[0] = 0xDD
	id := new_thought_id()
	pt := Thought_Plaintext{description = "v5 thought", content = "v5 body"}
	thought, _ := thought_create(master, id, pt)
	thought.agent = "v5-agent"
	thought.created_at = "2026-03-16T00:00:00Z"
	thought.updated_at = "2026-03-16T00:00:00Z"
	thought.ttl = 600

	buf := make([dynamic]u8)
	defer delete(buf)

	// processed block: 0 thoughts
	_append_u32(&buf, 0)

	// unprocessed block: 1 thought (V5 format = has TTL, no counters)
	_append_u32(&buf, 1)
	_serialize_thought_v5(&buf, thought)

	// catalog block: empty
	_append_u32(&buf, 0)

	// manifest block: empty
	_append_u32(&buf, 0)

	// gates block: empty
	gates_start := len(buf)
	_append_u16(&buf, 0)
	_append_u16(&buf, 0)
	_append_u16(&buf, 0)
	_append_u16(&buf, 0)
	gates_size := len(buf) - gates_start

	content_hash: [32]u8
	hash.hash_bytes_to_buffer(.SHA256, buf[:], content_hash[:])

	footer: [FOOTER_SIZE]u8
	_put_u32(footer[0:], u32(gates_size))
	copy(footer[4:36], content_hash[:])
	_put_u64(footer[36:], SHARD_MAGIC_V5)

	for b in footer do append(&buf, b)

	tmp_path := ".shards/_test_v5_migration.shard"
	os.make_directory(".shards")
	os.write_entire_file(tmp_path, buf[:])
	defer os.remove(tmp_path)

	blob, ok := blob_load(tmp_path, master)
	testing.expect(t, ok, "blob_load must succeed for V5 format")
	testing.expect(t, len(blob.unprocessed) == 1, "must load 1 unprocessed thought")
	if len(blob.unprocessed) > 0 {
		testing.expect(t, blob.unprocessed[0].ttl == 600, "V5 migrated thought must preserve ttl")
		testing.expect(t, blob.unprocessed[0].read_count == 0, "V5 migrated thought must have read_count=0")
		testing.expect(t, blob.unprocessed[0].cite_count == 0, "V5 migrated thought must have cite_count=0")
		testing.expect(t, blob.unprocessed[0].id == id, "thought ID must match")
	}
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

@(test)
test_composite_score :: proc(t: ^testing.T) {
	now := time.now()

	// A fresh thought with high usage should score well
	thought := Thought{
		ttl = 3600,
		updated_at = _format_time(now),
		read_count = 50,
		cite_count = 10,
	}
	score := _composite_score(0.8, thought, now)
	testing.expect(t, score > 0.5, "fresh high-usage thought with good match must score > 0.5")

	// An immortal thought with no usage and low match
	thought2 := Thought{
		ttl = 0,
		updated_at = _format_time(now),
		read_count = 0,
		cite_count = 0,
	}
	score2 := _composite_score(0.3, thought2, now)
	testing.expect(t, score2 > 0, "any matching thought must have positive score")
	testing.expect(t, score <= 1.0 || score == 1.0, "score must not exceed 1.0 (approximately)")
}

@(test)
test_feedback_op :: proc(t: ^testing.T) {
	key := Master_Key{1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32}
	key_hex := _make_test_key_hex(key)

	id := new_thought_id()
	pt := Thought_Plaintext{description = "feedback test", content = "test body"}
	thought, _ := thought_create(key, id, pt)
	thought.created_at = _format_time(time.now())
	thought.updated_at = _format_time(time.now())
	thought.read_count = 10
	thought.cite_count = 5

	blob := Blob{
		processed   = make([dynamic]Thought),
		unprocessed = make([dynamic]Thought),
		description = make([dynamic]string),
		positive    = make([dynamic]string),
		negative    = make([dynamic]string),
		related     = make([dynamic]string),
		master      = key,
	}
	append(&blob.unprocessed, thought)

	node := Node{
		blob  = blob,
		index = make([dynamic]Search_Entry),
	}

	id_hex := id_to_hex(id)

	// Test endorse
	result := dispatch(&node, fmt.tprintf("---\nop: feedback\nkey: %s\nid: %s\nfeedback: endorse\n---\n", key_hex, id_hex))
	testing.expect(t, strings.contains(result, "status: ok"), "endorse must return ok")
	// cite_count should have increased by 5
	t_after, _ := blob_get(&node.blob, id)
	testing.expect(t, t_after.cite_count == 10, "endorse must increase cite_count by 5")

	// Test flag
	result2 := dispatch(&node, fmt.tprintf("---\nop: feedback\nkey: %s\nid: %s\nfeedback: flag\n---\n", key_hex, id_hex))
	testing.expect(t, strings.contains(result2, "status: ok"), "flag must return ok")
	t_after2, _ := blob_get(&node.blob, id)
	testing.expect(t, t_after2.read_count == 5, "flag must decrease read_count by 5")
}

@(test)
test_read_increments_counter :: proc(t: ^testing.T) {
	key := Master_Key{1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32}
	key_hex := _make_test_key_hex(key)

	id := new_thought_id()
	pt := Thought_Plaintext{description = "read counter test", content = "test body"}
	thought, _ := thought_create(key, id, pt)
	thought.created_at = _format_time(time.now())
	thought.updated_at = _format_time(time.now())
	thought.read_count = 0

	blob := Blob{
		processed   = make([dynamic]Thought),
		unprocessed = make([dynamic]Thought),
		description = make([dynamic]string),
		positive    = make([dynamic]string),
		negative    = make([dynamic]string),
		related     = make([dynamic]string),
		master      = key,
	}
	append(&blob.unprocessed, thought)

	node := Node{
		blob  = blob,
		index = make([dynamic]Search_Entry),
	}

	id_hex := id_to_hex(id)

	// Read the thought
	result := dispatch(&node, fmt.tprintf("---\nop: read\nkey: %s\nid: %s\n---\n", key_hex, id_hex))
	testing.expect(t, strings.contains(result, "status: ok"), "read must return ok")

	// Check read_count incremented
	t_after, _ := blob_get(&node.blob, id)
	testing.expect(t, t_after.read_count == 1, "read must increment read_count to 1")
}

// =============================================================================
// Digest and budget tests
// =============================================================================

// =============================================================================
// Digest and budget tests
// =============================================================================

@(test)
test_digest_op_returns_ok :: proc(t: ^testing.T) {
	key := Master_Key{1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32}
	key_hex := _make_test_key_hex(key)

	// Create a thought
	id := new_thought_id()
	create_pt := Thought_Plaintext{description = "Architecture overview", content = "Full content about architecture"}
	thought, _ := thought_create(key, id, create_pt)

	// Build a slot with the thought
	slot := new(Shard_Slot)
	slot.name     = "test-shard"
	slot.loaded   = true
	slot.key_set  = true
	slot.master   = key
	slot.blob = Blob{
		processed   = make([dynamic]Thought),
		unprocessed = make([dynamic]Thought),
		description = make([dynamic]string),
		positive    = make([dynamic]string),
		negative    = make([dynamic]string),
		related     = make([dynamic]string),
		master      = key,
		catalog     = Catalog{name = "test-shard", purpose = "Test shard for digest"},
	}
	append(&slot.blob.unprocessed, thought)

	pt, _ := thought_decrypt(thought, key)
	slot.index = make([dynamic]Search_Entry)
	append(&slot.index, Search_Entry{id = thought.id, description = pt.description})

	// Create daemon node
	node := Node{
		name      = "daemon",
		is_daemon = true,
		blob = Blob{
			processed   = make([dynamic]Thought),
			unprocessed = make([dynamic]Thought),
			description = make([dynamic]string),
			positive    = make([dynamic]string),
			negative    = make([dynamic]string),
			related     = make([dynamic]string),
		},
		registry    = make([dynamic]Registry_Entry),
		slots       = make(map[string]^Shard_Slot),
		event_queue = make(Event_Queue),
	}
	append(&node.registry, Registry_Entry{
		name          = "test-shard",
		thought_count = 1,
		catalog       = Catalog{name = "test-shard", purpose = "Test shard for digest"},
	})
	node.slots["test-shard"] = slot

	// Call digest
	req := Request{op = "digest", key = key_hex}
	result, handled := daemon_dispatch(&node, req)
	testing.expect(t, handled, "digest must be handled by daemon")
	testing.expect(t, strings.contains(result, "status: ok"), "digest must return ok")
	testing.expect(t, strings.contains(result, "op: digest"), "digest must include op field")
	testing.expect(t, strings.contains(result, "test-shard"), "digest must include shard name")
	testing.expect(t, strings.contains(result, "Architecture overview"), "digest must include thought description")
}

@(test)
test_budget_query_truncates_content :: proc(t: ^testing.T) {
	key := Master_Key{1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32}
	key_hex := _make_test_key_hex(key)

	// Create a thought with long content
	long_content := "This is a very long content string that should be truncated when budget is applied to the query operation"
	id := new_thought_id()
	create_pt := Thought_Plaintext{description = "Budget test thought", content = long_content}
	thought, _ := thought_create(key, id, create_pt)

	// Build node
	blob := Blob{
		processed   = make([dynamic]Thought),
		unprocessed = make([dynamic]Thought),
		description = make([dynamic]string),
		positive    = make([dynamic]string),
		negative    = make([dynamic]string),
		related     = make([dynamic]string),
		master      = key,
	}
	append(&blob.unprocessed, thought)

	pt, _ := thought_decrypt(thought, key)
	index := make([dynamic]Search_Entry)
	append(&index, Search_Entry{id = thought.id, description = pt.description, text_hash = fnv_hash(pt.description)})

	node := Node{
		blob  = blob,
		index = index,
	}

	// Query with budget of 20 chars
	result := dispatch(&node, fmt.tprintf("---\nop: query\nkey: %s\nquery: Budget test\nbudget: 20\n---\n", key_hex))
	testing.expect(t, strings.contains(result, "status: ok"), "budget query must succeed")
	testing.expect(t, strings.contains(result, "truncated: true"), "truncated flag must be set")
	testing.expect(t, strings.contains(result, "Budget test thought"), "description must be present")
	// The full content should NOT be present
	testing.expect(t, !strings.contains(result, long_content), "full content must not be present when budget is small")
}

@(test)
test_budget_zero_returns_full_content :: proc(t: ^testing.T) {
	key := Master_Key{1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32}
	key_hex := _make_test_key_hex(key)

	content := "Full content that should not be truncated"
	id := new_thought_id()
	create_pt := Thought_Plaintext{description = "Full content test", content = content}
	thought, _ := thought_create(key, id, create_pt)

	blob := Blob{
		processed   = make([dynamic]Thought),
		unprocessed = make([dynamic]Thought),
		description = make([dynamic]string),
		positive    = make([dynamic]string),
		negative    = make([dynamic]string),
		related     = make([dynamic]string),
		master      = key,
	}
	append(&blob.unprocessed, thought)

	pt, _ := thought_decrypt(thought, key)
	index := make([dynamic]Search_Entry)
	append(&index, Search_Entry{id = thought.id, description = pt.description, text_hash = fnv_hash(pt.description)})

	node := Node{
		blob  = blob,
		index = index,
	}

	result := dispatch(&node, fmt.tprintf("---\nop: query\nkey: %s\nquery: Full content\nbudget: 0\n---\n", key_hex))
	testing.expect(t, strings.contains(result, "status: ok"), "query must succeed")
	testing.expect(t, strings.contains(result, content), "full content must be present with budget 0")
	testing.expect(t, !strings.contains(result, "truncated: true"), "truncated must not be set with budget 0")
}

@(test)
test_budget_parse_in_request :: proc(t: ^testing.T) {
	req, ok := md_parse_request("---\nop: query\nbudget: 5000\n---\n")
	testing.expect(t, ok, "parse must succeed")
	testing.expect(t, req.budget == 5000, "budget must be parsed correctly")
}

@(test)
test_truncated_flag_in_marshal :: proc(t: ^testing.T) {
	results := []Wire_Result{
		{id = "abc123", score = 0.9, description = "test", content = "partial...", truncated = true},
		{id = "def456", score = 0.8, description = "test2", content = "full content", truncated = false},
	}
	resp := Response{status = "ok", results = results}
	output := md_marshal_response(resp)
	testing.expect(t, strings.contains(output, "truncated: true"), "truncated flag must appear for truncated result")
	// Count occurrences — should only appear once (for the first result)
	count := strings.count(output, "truncated: true")
	testing.expect(t, count == 1, "truncated: true should appear exactly once")
}

// =============================================================================
// Self-compacting intelligence tests
// =============================================================================

// =============================================================================
// Self-compacting intelligence tests
// =============================================================================

@(test)
test_compact_suggest_empty :: proc(t: ^testing.T) {
	key := Master_Key {
		1,
		2,
		3,
		4,
		5,
		6,
		7,
		8,
		9,
		10,
		11,
		12,
		13,
		14,
		15,
		16,
		17,
		18,
		19,
		20,
		21,
		22,
		23,
		24,
		25,
		26,
		27,
		28,
		29,
		30,
		31,
		32,
	}
	key_hex := _make_test_key_hex(key)

	blob := Blob {
		processed   = make([dynamic]Thought),
		unprocessed = make([dynamic]Thought),
		description = make([dynamic]string),
		positive    = make([dynamic]string),
		negative    = make([dynamic]string),
		related     = make([dynamic]string),
		master      = key,
	}

	node := Node {
		blob  = blob,
		index = make([dynamic]Search_Entry),
	}

	result := dispatch(&node, fmt.tprintf("---\nop: compact_suggest\nkey: %s\n---\n", key_hex))
	testing.expect(
		t,
		strings.contains(result, "status: ok"),
		"compact_suggest on empty shard must return ok",
	)
}

@(test)
test_compact_suggest_revision_chain :: proc(t: ^testing.T) {
	key := Master_Key {
		1,
		2,
		3,
		4,
		5,
		6,
		7,
		8,
		9,
		10,
		11,
		12,
		13,
		14,
		15,
		16,
		17,
		18,
		19,
		20,
		21,
		22,
		23,
		24,
		25,
		26,
		27,
		28,
		29,
		30,
		31,
		32,
	}
	key_hex := _make_test_key_hex(key)

	// Create a revision chain: root -> child
	root_id := new_thought_id()
	child_id := new_thought_id()

	pt_root := Thought_Plaintext {
		description = "architecture overview",
		content     = "v1 content",
	}
	thought_root, _ := thought_create(key, root_id, pt_root)
	thought_root.created_at = _format_time(time.now())
	thought_root.updated_at = _format_time(time.now())

	pt_child := Thought_Plaintext {
		description = "architecture overview updated",
		content     = "v2 content",
	}
	thought_child, _ := thought_create(key, child_id, pt_child)
	thought_child.revises = root_id
	thought_child.created_at = _format_time(time.now())
	thought_child.updated_at = _format_time(time.now())

	blob := Blob {
		processed   = make([dynamic]Thought),
		unprocessed = make([dynamic]Thought),
		description = make([dynamic]string),
		positive    = make([dynamic]string),
		negative    = make([dynamic]string),
		related     = make([dynamic]string),
		master      = key,
	}
	append(&blob.unprocessed, thought_root)
	append(&blob.unprocessed, thought_child)

	node := Node {
		blob  = blob,
		index = make([dynamic]Search_Entry),
	}

	result := dispatch(&node, fmt.tprintf("---\nop: compact_suggest\nkey: %s\n---\n", key_hex))
	testing.expect(t, strings.contains(result, "status: ok"), "compact_suggest must return ok")
	testing.expect(t, strings.contains(result, "revision_chain"), "must detect revision chain")
	testing.expect(t, strings.contains(result, "merge"), "must suggest merge action")
}

@(test)
test_compact_suggest_duplicates :: proc(t: ^testing.T) {
	key := Master_Key {
		1,
		2,
		3,
		4,
		5,
		6,
		7,
		8,
		9,
		10,
		11,
		12,
		13,
		14,
		15,
		16,
		17,
		18,
		19,
		20,
		21,
		22,
		23,
		24,
		25,
		26,
		27,
		28,
		29,
		30,
		31,
		32,
	}
	key_hex := _make_test_key_hex(key)

	// Create two thoughts with very similar descriptions
	id1 := new_thought_id()
	id2 := new_thought_id()

	pt1 := Thought_Plaintext {
		description = "milestone two complete",
		content     = "content A",
	}
	thought1, _ := thought_create(key, id1, pt1)
	thought1.created_at = _format_time(time.now())
	thought1.updated_at = _format_time(time.now())

	pt2 := Thought_Plaintext {
		description = "milestone two complete",
		content     = "content B",
	}
	thought2, _ := thought_create(key, id2, pt2)
	thought2.created_at = _format_time(time.now())
	thought2.updated_at = _format_time(time.now())

	blob := Blob {
		processed   = make([dynamic]Thought),
		unprocessed = make([dynamic]Thought),
		description = make([dynamic]string),
		positive    = make([dynamic]string),
		negative    = make([dynamic]string),
		related     = make([dynamic]string),
		master      = key,
	}
	append(&blob.unprocessed, thought1)
	append(&blob.unprocessed, thought2)

	node := Node {
		blob  = blob,
		index = make([dynamic]Search_Entry),
	}

	result := dispatch(&node, fmt.tprintf("---\nop: compact_suggest\nkey: %s\n---\n", key_hex))
	testing.expect(t, strings.contains(result, "status: ok"), "compact_suggest must return ok")
	testing.expect(t, strings.contains(result, "duplicate"), "must detect duplicates")
	testing.expect(t, strings.contains(result, "deduplicate"), "must suggest deduplicate action")
}

@(test)
test_compact_suggest_lossy_stale :: proc(t: ^testing.T) {
	key := Master_Key {
		1,
		2,
		3,
		4,
		5,
		6,
		7,
		8,
		9,
		10,
		11,
		12,
		13,
		14,
		15,
		16,
		17,
		18,
		19,
		20,
		21,
		22,
		23,
		24,
		25,
		26,
		27,
		28,
		29,
		30,
		31,
		32,
	}
	key_hex := _make_test_key_hex(key)
	now := time.now()

	// Create a stale thought (TTL=60, updated 120s ago)
	id1 := new_thought_id()
	pt1 := Thought_Plaintext {
		description = "old status update",
		content     = "outdated",
	}
	thought1, _ := thought_create(key, id1, pt1)
	thought1.ttl = 60
	thought1.created_at = _format_time(time.time_add(now, -120 * time.Second))
	thought1.updated_at = _format_time(time.time_add(now, -120 * time.Second))

	// Create a fresh thought (should NOT be suggested for pruning)
	id2 := new_thought_id()
	pt2 := Thought_Plaintext {
		description = "current status",
		content     = "fresh",
	}
	thought2, _ := thought_create(key, id2, pt2)
	thought2.ttl = 3600
	thought2.created_at = _format_time(now)
	thought2.updated_at = _format_time(now)

	blob := Blob {
		processed   = make([dynamic]Thought),
		unprocessed = make([dynamic]Thought),
		description = make([dynamic]string),
		positive    = make([dynamic]string),
		negative    = make([dynamic]string),
		related     = make([dynamic]string),
		master      = key,
	}
	append(&blob.unprocessed, thought1)
	append(&blob.unprocessed, thought2)

	node := Node {
		blob  = blob,
		index = make([dynamic]Search_Entry),
	}

	// Lossless mode should NOT suggest pruning
	result_lossless := dispatch(
		&node,
		fmt.tprintf("---\nop: compact_suggest\nkey: %s\nmode: lossless\n---\n", key_hex),
	)
	testing.expect(
		t,
		!strings.contains(result_lossless, "prune"),
		"lossless mode must NOT suggest pruning",
	)

	// Lossy mode should suggest pruning stale thought
	result_lossy := dispatch(
		&node,
		fmt.tprintf("---\nop: compact_suggest\nkey: %s\nmode: lossy\n---\n", key_hex),
	)
	testing.expect(
		t,
		strings.contains(result_lossy, "stale"),
		"lossy mode must detect stale thought",
	)
	testing.expect(t, strings.contains(result_lossy, "prune"), "lossy mode must suggest pruning")
}

@(test)
test_compact_lossy_merge :: proc(t: ^testing.T) {
	key := Master_Key {
		1,
		2,
		3,
		4,
		5,
		6,
		7,
		8,
		9,
		10,
		11,
		12,
		13,
		14,
		15,
		16,
		17,
		18,
		19,
		20,
		21,
		22,
		23,
		24,
		25,
		26,
		27,
		28,
		29,
		30,
		31,
		32,
	}
	key_hex := _make_test_key_hex(key)

	// Create a revision chain
	root_id := new_thought_id()
	child_id := new_thought_id()

	pt_root := Thought_Plaintext {
		description = "test thought",
		content     = "original content",
	}
	thought_root, _ := thought_create(key, root_id, pt_root)
	thought_root.created_at = _format_time(time.time_add(time.now(), -60 * time.Second))
	thought_root.updated_at = _format_time(time.time_add(time.now(), -60 * time.Second))
	thought_root.agent = "agent-a"

	pt_child := Thought_Plaintext {
		description = "test thought updated",
		content     = "revised content",
	}
	thought_child, _ := thought_create(key, child_id, pt_child)
	thought_child.revises = root_id
	thought_child.created_at = _format_time(time.now())
	thought_child.updated_at = _format_time(time.now())
	thought_child.agent = "agent-b"

	root_hex := id_to_hex(root_id)
	child_hex := id_to_hex(child_id)

	blob := Blob {
		processed   = make([dynamic]Thought),
		unprocessed = make([dynamic]Thought),
		description = make([dynamic]string),
		positive    = make([dynamic]string),
		negative    = make([dynamic]string),
		related     = make([dynamic]string),
		master      = key,
	}
	append(&blob.unprocessed, thought_root)
	append(&blob.unprocessed, thought_child)

	node := Node {
		blob  = blob,
		index = make([dynamic]Search_Entry),
	}

	// Lossy compact — should only keep latest revision
	result := dispatch(
		&node,
		fmt.tprintf(
			"---\nop: compact\nkey: %s\nmode: lossy\nids: [%s, %s]\n---\n",
			key_hex,
			root_hex,
			child_hex,
		),
	)
	testing.expect(t, strings.contains(result, "status: ok"), "compact must return ok")
	testing.expect(t, strings.contains(result, "moved: 2"), "must move 2 thoughts")

	// Verify the merged thought has latest content (lossy = only latest)
	testing.expect(t, len(node.blob.processed) == 1, "must have 1 merged thought in processed")
	if len(node.blob.processed) > 0 {
		merged, err := thought_decrypt(node.blob.processed[0], key, context.temp_allocator)
		testing.expect(t, err == .None, "merged thought must decrypt")
		if err == .None {
			testing.expect(
				t,
				strings.contains(merged.content, "revised content"),
				"lossy merge must keep latest content",
			)
			testing.expect(
				t,
				!strings.contains(merged.content, "original content"),
				"lossy merge must NOT keep old content",
			)
		}
	}
}

@(test)
test_description_similarity :: proc(t: ^testing.T) {
	// Identical strings
	testing.expect(
		t,
		_description_similarity("hello world", "hello world") == 1.0,
		"identical must be 1.0",
	)

	// Completely different
	testing.expect(
		t,
		_description_similarity("hello world", "foo bar") == 0.0,
		"different must be 0.0",
	)

	// Partial overlap
	sim := _description_similarity("milestone two complete", "milestone two done")
	testing.expect(t, sim >= 0.5, "partial overlap must be >= 0.5")

	// Empty strings
	testing.expect(t, _description_similarity("", "") == 1.0, "both empty must be 1.0")
	testing.expect(t, _description_similarity("hello", "") == 0.0, "one empty must be 0.0")
}

@(test)
test_extract_suggestion_ids :: proc(t: ^testing.T) {
	// Test JSON suggestion ID extraction used by compact_apply
	resp := `{"status":"ok","suggestion_count":2,"suggestions":[{"kind":"revision_chain","action":"merge","description":"2 revisions of test","ids":["abcdef01234567890abcdef012345678","12345678abcdef0123456789abcdef01"]},{"kind":"duplicate","action":"deduplicate","description":"similar descriptions","ids":["aabbccdd11223344aabbccdd11223344","11223344aabbccddee556677889900aa"]}]}`

	ids := make([dynamic]string, context.temp_allocator)
	_extract_suggestion_ids(resp, &ids)

	testing.expect(t, len(ids) == 4, fmt.tprintf("must extract 4 IDs, got %d", len(ids)))

	// Verify all expected IDs are present
	found_count := 0
	expected := [?]string {
		"abcdef01234567890abcdef012345678",
		"12345678abcdef0123456789abcdef01",
		"aabbccdd11223344aabbccdd11223344",
		"11223344aabbccddee556677889900aa",
	}
	for e in expected {
		for id in ids {
			if id == e {found_count += 1; break}
		}
	}
	testing.expect(
		t,
		found_count == 4,
		fmt.tprintf("must find all 4 expected IDs, found %d", found_count),
	)
}

@(test)
test_extract_suggestion_ids_dedup :: proc(t: ^testing.T) {
	// Same ID in two different suggestions should only appear once
	resp := `{"status":"ok","suggestions":[{"kind":"revision_chain","action":"merge","ids":["abcdef01234567890abcdef012345678"]},{"kind":"duplicate","action":"deduplicate","ids":["abcdef01234567890abcdef012345678"]}]}`

	ids := make([dynamic]string, context.temp_allocator)
	_extract_suggestion_ids(resp, &ids)

	testing.expect(
		t,
		len(ids) == 1,
		fmt.tprintf("duplicate IDs must be deduplicated, got %d", len(ids)),
	)
}

@(test)
test_extract_suggestion_ids_empty :: proc(t: ^testing.T) {
	// No suggestions should yield no IDs
	resp := `{"status":"ok","suggestion_count":0}`

	ids := make([dynamic]string, context.temp_allocator)
	_extract_suggestion_ids(resp, &ids)

	testing.expect(t, len(ids) == 0, "empty suggestions must yield 0 IDs")
}

@(test)
test_compact_via_dispatch :: proc(t: ^testing.T) {
	// Test compact op through dispatch with explicit IDs (simulating MCP shard_compact flow)
	key := Master_Key {
		1,
		2,
		3,
		4,
		5,
		6,
		7,
		8,
		9,
		10,
		11,
		12,
		13,
		14,
		15,
		16,
		17,
		18,
		19,
		20,
		21,
		22,
		23,
		24,
		25,
		26,
		27,
		28,
		29,
		30,
		31,
		32,
	}
	key_hex := _make_test_key_hex(key)

	// Create standalone thoughts
	id1 := new_thought_id()
	id2 := new_thought_id()

	pt1 := Thought_Plaintext {
		description = "first thought",
		content     = "content one",
	}
	thought1, _ := thought_create(key, id1, pt1)
	pt2 := Thought_Plaintext {
		description = "second thought",
		content     = "content two",
	}
	thought2, _ := thought_create(key, id2, pt2)

	id1_hex := id_to_hex(id1)
	id2_hex := id_to_hex(id2)

	blob := Blob {
		processed   = make([dynamic]Thought),
		unprocessed = make([dynamic]Thought),
		description = make([dynamic]string),
		positive    = make([dynamic]string),
		negative    = make([dynamic]string),
		related     = make([dynamic]string),
		master      = key,
	}
	append(&blob.unprocessed, thought1)
	append(&blob.unprocessed, thought2)

	node := Node {
		blob  = blob,
		index = make([dynamic]Search_Entry),
	}

	// Compact both thoughts — should move from unprocessed to processed
	result := dispatch(
		&node,
		fmt.tprintf("---\nop: compact\nkey: %s\nids: [%s, %s]\n---\n", key_hex, id1_hex, id2_hex),
	)
	testing.expect(t, strings.contains(result, "status: ok"), "compact must succeed")
	testing.expect(t, strings.contains(result, "moved: 2"), "must move 2 standalone thoughts")
	testing.expect(t, len(node.blob.unprocessed) == 0, "unprocessed must be empty after compact")
	testing.expect(t, len(node.blob.processed) == 2, "processed must have 2 thoughts")
}

@(test)
test_needs_compaction_event :: proc(t: ^testing.T) {
	// Verify the needs_compaction event type is accepted by notify

	node := Node {
		registry    = make([dynamic]Registry_Entry),
		slots       = make(map[string]^Shard_Slot),
		event_queue = Event_Queue{},
	}

	// Register a shard with related shard
	append(
		&node.registry,
		Registry_Entry {
			name = "test-shard",
			data_path = ".shards/test-shard.shard",
			catalog = Catalog{related = {"other-shard"}},
		},
	)
	append(
		&node.registry,
		Registry_Entry{name = "other-shard", data_path = ".shards/other-shard.shard"},
	)

	// Call _op_notify directly (it's a daemon-level op, not shard-level)
	req := Request {
		source     = "test-shard",
		event_type = "needs_compaction",
		agent      = "test",
	}
	result := _op_notify(&node, req)
	testing.expect(
		t,
		strings.contains(result, "status: ok"),
		"needs_compaction event must be accepted",
	)
}

@(test)
test_incremental_compact_standalone :: proc(t: ^testing.T) {
	// Verify that writing a thought via dispatch immediately places it in processed.
	key := Master_Key {
		1,
		2,
		3,
		4,
		5,
		6,
		7,
		8,
		9,
		10,
		11,
		12,
		13,
		14,
		15,
		16,
		17,
		18,
		19,
		20,
		21,
		22,
		23,
		24,
		25,
		26,
		27,
		28,
		29,
		30,
		31,
		32,
	}
	key_hex := _make_test_key_hex(key)

	blob := Blob {
		processed   = make([dynamic]Thought),
		unprocessed = make([dynamic]Thought),
		description = make([dynamic]string),
		positive    = make([dynamic]string),
		negative    = make([dynamic]string),
		related     = make([dynamic]string),
		master      = key,
	}
	node := Node {
		blob  = blob,
		index = make([dynamic]Search_Entry),
	}

	r1 := dispatch(
		&node,
		fmt.tprintf(
			"---\nop: write\nkey: %s\ndescription: first thought\n---\ncontent one\n",
			key_hex,
		),
	)
	testing.expect(t, strings.contains(r1, "status: ok"), "write 1 must succeed")
	testing.expect(t, len(node.blob.unprocessed) == 0, "unprocessed must be empty after write 1")
	testing.expect(t, len(node.blob.processed) == 1, "processed must have 1 thought after write 1")

	r2 := dispatch(
		&node,
		fmt.tprintf(
			"---\nop: write\nkey: %s\ndescription: second thought\n---\ncontent two\n",
			key_hex,
		),
	)
	testing.expect(t, strings.contains(r2, "status: ok"), "write 2 must succeed")
	testing.expect(t, len(node.blob.unprocessed) == 0, "unprocessed must be empty after write 2")
	testing.expect(
		t,
		len(node.blob.processed) == 2,
		"processed must have 2 thoughts after write 2",
	)
}

@(test)
test_incremental_compact_revision_chain :: proc(t: ^testing.T) {
	// Verify that writing a revision merges the chain into processed.
	key := Master_Key {
		2,
		3,
		4,
		5,
		6,
		7,
		8,
		9,
		10,
		11,
		12,
		13,
		14,
		15,
		16,
		17,
		18,
		19,
		20,
		21,
		22,
		23,
		24,
		25,
		26,
		27,
		28,
		29,
		30,
		31,
		32,
		1,
	}
	key_hex := _make_test_key_hex(key)

	blob := Blob {
		processed   = make([dynamic]Thought),
		unprocessed = make([dynamic]Thought),
		description = make([dynamic]string),
		positive    = make([dynamic]string),
		negative    = make([dynamic]string),
		related     = make([dynamic]string),
		master      = key,
	}
	node := Node {
		blob  = blob,
		index = make([dynamic]Search_Entry),
	}

	r1 := dispatch(
		&node,
		fmt.tprintf(
			"---\nop: write\nkey: %s\ndescription: architecture overview\n---\nv1 content\n",
			key_hex,
		),
	)
	testing.expect(t, strings.contains(r1, "status: ok"), "write root must succeed")
	testing.expect(
		t,
		len(node.blob.processed) == 1,
		"processed must have 1 thought after root write",
	)

	root_id_start := strings.index(r1, "id: ")
	testing.expect(t, root_id_start >= 0, "response must contain id field")
	root_id := r1[root_id_start + 4:]
	if nl := strings.index(root_id, "\n"); nl >= 0 {root_id = root_id[:nl]}
	root_id = strings.trim_space(root_id)

	r2 := dispatch(
		&node,
		fmt.tprintf(
			"---\nop: write\nkey: %s\ndescription: architecture overview updated\nrevises: %s\n---\nv2 content\n",
			key_hex,
			root_id,
		),
	)
	testing.expect(t, strings.contains(r2, "status: ok"), "write revision must succeed")
	testing.expect(
		t,
		len(node.blob.unprocessed) == 0,
		"unprocessed must be empty after revision write",
	)
	testing.expect(
		t,
		len(node.blob.processed) == 1,
		"revision chain must merge into 1 processed thought",
	)

	if len(node.blob.processed) == 1 {
		merged, err := thought_decrypt(node.blob.processed[0], key, context.temp_allocator)
		testing.expect(t, err == .None, "merged thought must decrypt")
		if err == .None {
			testing.expect(
				t,
				strings.contains(merged.content, "v1 content"),
				"lossless merge must contain v1",
			)
			testing.expect(
				t,
				strings.contains(merged.content, "v2 content"),
				"lossless merge must contain v2",
			)
			delete(merged.description, context.temp_allocator)
			delete(merged.content, context.temp_allocator)
		}
	}
}

// =============================================================================
// Integration tests — revision chains and compact
// =============================================================================

@(test)
test_revision_chain_walking :: proc(t: ^testing.T) {
	key := Master_Key{1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32}
	key_hex := _make_test_key_hex(key)

	// Create chain: root -> child1 -> child2
	root_id := new_thought_id()
	child1_id := new_thought_id()
	child2_id := new_thought_id()

	pt_root := Thought_Plaintext{description = "version 1", content = "original"}
	thought_root, _ := thought_create(key, root_id, pt_root)
	thought_root.created_at = _format_time(time.time_add(time.now(), -60 * time.Second))
	thought_root.updated_at = thought_root.created_at
	thought_root.agent = "agent-1"

	pt_child1 := Thought_Plaintext{description = "version 2", content = "updated"}
	thought_child1, _ := thought_create(key, child1_id, pt_child1)
	thought_child1.revises = root_id
	thought_child1.created_at = _format_time(time.time_add(time.now(), -30 * time.Second))
	thought_child1.updated_at = thought_child1.created_at
	thought_child1.agent = "agent-2"

	pt_child2 := Thought_Plaintext{description = "version 3", content = "final"}
	thought_child2, _ := thought_create(key, child2_id, pt_child2)
	thought_child2.revises = child1_id
	thought_child2.created_at = _format_time(time.now())
	thought_child2.updated_at = thought_child2.created_at
	thought_child2.agent = "agent-3"

	blob := Blob{
		processed   = make([dynamic]Thought),
		unprocessed = make([dynamic]Thought),
		description = make([dynamic]string),
		positive    = make([dynamic]string),
		negative    = make([dynamic]string),
		related     = make([dynamic]string),
		master      = key,
	}
	append(&blob.unprocessed, thought_root)
	append(&blob.unprocessed, thought_child1)
	append(&blob.unprocessed, thought_child2)

	node := Node{
		blob  = blob,
		index = make([dynamic]Search_Entry),
	}

	// Use the revisions op to walk the chain
	root_hex := id_to_hex(root_id)
	result := dispatch(&node, fmt.tprintf("---\nop: revisions\nid: %s\nkey: %s\n---\n", root_hex, key_hex))
	testing.expect(t, strings.contains(result, "status: ok"), "revisions op must return ok")
	// Should find the chain (returns ids field)
	testing.expect(t, strings.contains(result, "ids:"), "must have ids field with chain")
}

@(test)
test_compact_merge_into_processed :: proc(t: ^testing.T) {
	key := Master_Key{1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32}
	key_hex := _make_test_key_hex(key)

	root_id := new_thought_id()
	child_id := new_thought_id()
	standalone_id := new_thought_id()

	pt_root := Thought_Plaintext{description = "base thought", content = "v1"}
	thought_root, _ := thought_create(key, root_id, pt_root)
	thought_root.created_at = _format_time(time.time_add(time.now(), -30 * time.Second))
	thought_root.updated_at = thought_root.created_at
	thought_root.agent = "author"

	pt_child := Thought_Plaintext{description = "base thought (updated)", content = "v2"}
	thought_child, _ := thought_create(key, child_id, pt_child)
	thought_child.revises = root_id
	thought_child.created_at = _format_time(time.now())
	thought_child.updated_at = thought_child.created_at
	thought_child.agent = "reviewer"

	pt_standalone := Thought_Plaintext{description = "standalone thought", content = "independent"}
	thought_standalone, _ := thought_create(key, standalone_id, pt_standalone)
	thought_standalone.created_at = _format_time(time.now())
	thought_standalone.updated_at = thought_standalone.created_at

	blob := Blob{
		processed   = make([dynamic]Thought),
		unprocessed = make([dynamic]Thought),
		description = make([dynamic]string),
		positive    = make([dynamic]string),
		negative    = make([dynamic]string),
		related     = make([dynamic]string),
		master      = key,
	}
	append(&blob.unprocessed, thought_root)
	append(&blob.unprocessed, thought_child)
	append(&blob.unprocessed, thought_standalone)

	node := Node{
		blob  = blob,
		index = make([dynamic]Search_Entry),
	}

	root_hex := id_to_hex(root_id)
	child_hex := id_to_hex(child_id)
	standalone_hex := id_to_hex(standalone_id)

	result := dispatch(&node, fmt.tprintf(
		"---\nop: compact\nkey: %s\nids: [%s, %s, %s]\n---\n",
		key_hex, root_hex, child_hex, standalone_hex,
	))
	testing.expect(t, strings.contains(result, "status: ok"), "compact must return ok")
	testing.expect(t, strings.contains(result, "moved: 3"), "must move 3 thoughts")

	// After compact: unprocessed should be empty, processed should have 2
	// (1 merged chain + 1 standalone)
	testing.expect(t, len(node.blob.unprocessed) == 0, "unprocessed must be empty after compact")
	testing.expect(t, len(node.blob.processed) == 2, "processed must have 2 (merged + standalone)")

	// Verify the merged thought contains both versions
	for p in node.blob.processed {
		pt, err := thought_decrypt(p, key, context.temp_allocator)
		if err != .None do continue
		if strings.contains(pt.description, "base thought") {
			testing.expect(t, strings.contains(pt.content, "v1"), "merged must contain v1")
			testing.expect(t, strings.contains(pt.content, "v2"), "merged must contain v2")
		}
	}
}
