// ops_read.odin — read operations: shard access, digest, slot loading, key management
package shard

import "core:fmt"
import "core:strings"
import "core:time"

_op_requires_key :: proc(op: string) -> bool {
	switch op {
	case "write",
	     "read",
	     "update",
	     "delete",
	     "search",
	     "query",
	     "compact",
	     "compact_suggest",
	     "dump",
	     "revisions",
	     "stale",
	     "feedback":
		return true
	}
	return false
}

_op_access :: proc(node: ^Node, req: Request, allocator := context.allocator) -> string {
	if req.query == "" do return _err_response("query required", allocator)

	max_results := 5

	Candidate :: struct {
		name:  string,
		score: f32,
	}
	candidates := make([dynamic]Candidate, context.temp_allocator)

	if len(node.vec_index.entries) > 0 {
		results := index_query(node, req.query, max_results * 2, context.temp_allocator)
		if results != nil {
			q_tokens := _tokenize(req.query, context.temp_allocator)
			for r in results {
				rejected := false
				for entry in node.registry {
					if entry.name == r.name {
						if entry.gate_negative != nil {
							rejected = _negative_gate_rejects(entry.gate_negative, q_tokens)
						}
						break
					}
				}
				if rejected do continue
				if r.score >= ACCESS_MIN_SCORE {
					append(&candidates, Candidate{name = r.name, score = r.score})
				}
			}
		}
	}

	if len(candidates) == 0 {
		q_tokens := _tokenize(req.query, context.temp_allocator)
		if len(q_tokens) == 0 do return _err_response("query produced no tokens", allocator)

		all_tokens := make([dynamic]string, context.temp_allocator)
		for t in q_tokens do append(&all_tokens, t)
		if req.items != nil {
			for item in req.items {
				item_tokens := _tokenize(item, context.temp_allocator)
				for t in item_tokens do append(&all_tokens, t)
			}
		}

		for entry in node.registry {
			gs := _score_gates(entry, all_tokens[:])
			if gs.score >= ACCESS_MIN_SCORE {
				append(&candidates, Candidate{name = gs.name, score = gs.score})
			}
		}
	}

	if len(candidates) == 0 {
		return _marshal(
			Response {
				status = "no_match",
				description = "no shard matched the query — use remember to create one",
			},
			allocator,
		)
	}

	for i := 1; i < len(candidates); i += 1 {
		key := candidates[i]
		j := i - 1
		for j >= 0 && candidates[j].score < key.score {
			candidates[j + 1] = candidates[j]
			j -= 1
		}
		candidates[j + 1] = key
	}

	best := candidates[0]

	entry_idx := -1
	for e, i in node.registry {
		if e.name == best.name {
			entry_idx = i
			break
		}
	}
	if entry_idx < 0 {
		return _err_response("matched shard not in registry", allocator)
	}
	entry := &node.registry[entry_idx]

	key_hex := req.key
	if key_hex == "" {
		key_hex = _access_resolve_key(best.name)
	}

	slot := _slot_get_or_create(node, entry)
	if !slot.loaded {
		if !_slot_load(slot, key_hex) {
			return _err_response(fmt.tprintf("could not load shard '%s'", best.name), allocator)
		}
	}
	if key_hex != "" && !slot.key_set {
		_slot_set_key(slot, key_hex)
	}
	slot.last_access = time.now()

	_record_consumption(node, req.agent, best.name, "access")

	limit := req.thought_count > 0 ? req.thought_count : config_get().default_query_limit
	budget := req.budget > 0 ? req.budget : config_get().default_query_budget
	wire := make([dynamic]Wire_Result, allocator)

	if slot.key_set && len(slot.index) > 0 {
		hits := search_query(slot.index[:], req.query, context.temp_allocator)
		count := 0
		chars_used_acc := 0
		for h in hits {
			if count >= limit do break
			thought, found := blob_get(&slot.blob, h.id)
			if !found do continue
			pt, err := thought_decrypt(thought, slot.master, allocator)
			if err != .None do continue

			new_content, new_truncated, _ := _truncate_to_budget(
				pt.content,
				budget,
				chars_used_acc,
			)

			append(
				&wire,
				Wire_Result {
					id = id_to_hex(h.id, allocator),
					score = h.score,
					description = pt.description,
					content = new_content,
					truncated = new_truncated,
				},
			)
			count += 1
		}
	}

	hint := ""
	if len(candidates) > 1 {
		alt_names := make([dynamic]string, context.temp_allocator)
		cap := min(len(candidates), 4)
		for i in 1 ..< cap {
			append(&alt_names, candidates[i].name)
		}
		hint = fmt.aprintf(
			"also matched: %s",
			strings.join(alt_names[:], ", ", context.temp_allocator),
		)
	}

	return _marshal(
		Response {
			status = "ok",
			node_name = best.name,
			catalog = entry.catalog,
			results = wire[:],
			description = hint,
		},
		allocator,
	)
}

_op_digest :: proc(node: ^Node, req: Request, allocator := context.allocator) -> string {
	use_filter := req.query != ""
	q_tokens: []string
	if use_filter {
		q_tokens = _tokenize(req.query, context.temp_allocator)
	}

	// Build markdown body
	b := strings.builder_make(context.temp_allocator)

	for &entry in node.registry {
		if use_filter && len(q_tokens) > 0 {
			gs := _score_gates(entry, q_tokens)
			if gs.score < ACCESS_MIN_SCORE do continue
		}

		fmt.sbprintf(&b, "\n## %s\n", entry.name)
		if entry.catalog.purpose != "" {
			fmt.sbprintf(&b, "**Purpose:** %s\n", entry.catalog.purpose)
		}
		fmt.sbprintf(&b, "**Thoughts:** %d\n", entry.thought_count)
		if entry.catalog.tags != nil && len(entry.catalog.tags) > 0 {
			strings.write_string(&b, "**Tags:** ")
			for tag, i in entry.catalog.tags {
				if i > 0 do strings.write_string(&b, ", ")
				strings.write_string(&b, tag)
			}
			strings.write_string(&b, "\n")
		}

		key_hex := req.key
		if key_hex == "" {
			key_hex = _access_resolve_key(entry.name)
		}

		slot := _slot_get_or_create(node, &entry)
		if !slot.loaded {
			_slot_load(slot, key_hex)
		}
		if key_hex != "" && !slot.key_set {
			_slot_set_key(slot, key_hex)
		}

		if slot.loaded && slot.key_set {
			slot.last_access = time.now()

			if len(slot.blob.processed) > 0 {
				strings.write_string(&b, "### Processed\n")
				for thought in slot.blob.processed {
					pt, err := thought_decrypt(thought, slot.master, context.temp_allocator)
					if err != .None do continue
					fmt.sbprintf(&b, "- %s\n", pt.description)
				}
			}

			if len(slot.blob.unprocessed) > 0 {
				strings.write_string(&b, "### Unprocessed\n")
				for thought in slot.blob.unprocessed {
					pt, err := thought_decrypt(thought, slot.master, context.temp_allocator)
					if err != .None do continue
					fmt.sbprintf(&b, "- %s\n", pt.description)
				}
			}
		} else if slot.loaded {
			strings.write_string(&b, "*No key available — descriptions not shown*\n")
		}
	}

	content := strings.clone(strings.to_string(b), allocator)
	return _marshal(
		Response{status = "ok", node_name = "digest", thoughts = len(node.registry), content = content},
		allocator,
	)
}

_access_resolve_key :: proc(shard_name: string) -> string {
	kc, ok := keychain_load(context.temp_allocator)
	if !ok do return ""
	key, found := keychain_lookup(kc, shard_name)
	if found do return key
	return ""
}

_find_registry_entry :: proc(node: ^Node, name: string) -> ^Registry_Entry {
	for &entry in node.registry {
		if entry.name == name {
			return &entry
		}
	}
	return nil
}

_slot_get_or_create :: proc(node: ^Node, entry: ^Registry_Entry) -> ^Shard_Slot {
	if slot, ok := node.slots[entry.name]; ok {
		return slot
	}
	slot := new(Shard_Slot)
	slot.name = entry.name
	slot.data_path = entry.data_path
	slot.loaded = false
	slot.key_set = false
	slot.last_access = time.now()
	node.slots[entry.name] = slot
	return slot
}

_slot_load :: proc(slot: ^Shard_Slot, key_hex: string = "") -> bool {
	master: Master_Key
	has_key := false

	if key_hex != "" {
		if k, ok := hex_to_key(key_hex); ok {
			master = k
			has_key = true
		}
	}

	blob, ok := blob_load(slot.data_path, master)
	if !ok do return false

	slot.blob = blob
	slot.loaded = true
	slot.master = master

	// Unencrypted mode: zero master key — treat as keyed so ops and index work.
	is_zero: u8 = 0
	for b in master do is_zero |= b
	slot.key_set = has_key || is_zero == 0

	if slot.key_set {
		_slot_build_index(slot)
	}

	return true
}

_slot_set_key :: proc(slot: ^Shard_Slot, key_hex: string) {
	k, ok := hex_to_key(key_hex)
	if !ok do return

	slot.master = k
	slot.blob.master = slot.master
	slot.key_set = true
	_slot_build_index(slot)
}

_slot_build_index :: proc(slot: ^Shard_Slot) {
	build_search_index(&slot.index, slot.blob, slot.master, fmt.tprintf("daemon/%s", slot.name))
}

_slot_verify_key :: proc(slot: ^Shard_Slot, key_hex: string) -> bool {
	// Unencrypted mode: zero master key accepts any request (key optional).
	is_zero: u8 = 0
	for b in slot.master do is_zero |= b
	if is_zero == 0 do return true

	if !slot.key_set do return false
	k, ok := hex_to_key(key_hex)
	if !ok do return false
	diff: u8 = 0
	for i in 0 ..< 32 do diff |= k[i] ~ slot.master[i]
	return diff == 0
}
