// ops_query.odin — query operations: cross-shard search, traversal, gate scoring
package shard

import "core:fmt"
import "core:strings"
import "core:time"

_op_traverse :: proc(node: ^Node, req: Request, allocator := context.allocator) -> string {
	if req.query == "" do return _err_response("query required", allocator)

	max_branches := req.max_branches > 0 ? req.max_branches : 5
	layer := req.layer

	candidates := _traverse_layer0(node, req.query, max_branches, allocator)

	if layer == 0 {
		return _marshal(Response{status = "ok", results = candidates[:]}, allocator)
	}

	cfg := config_get()
	limit := req.thought_count > 0 ? req.thought_count : cfg.default_query_limit
	budget := req.budget > 0 ? req.budget : cfg.default_query_budget
	max_total := cfg.traverse_results > 0 ? cfg.traverse_results : 10
	now := time.now()

	wire := make([dynamic]Wire_Result, allocator)
	chars_used := 0

	candidate_names := make([dynamic]string, context.temp_allocator)
	for c in candidates {
		append(&candidate_names, c.id)
	}

	_traverse_search_shards(
		node,
		candidate_names[:],
		req.query,
		limit,
		budget,
		max_total,
		now,
		&wire,
		&chars_used,
		allocator,
	)

	if layer >= 2 {
		visited := make(map[string]bool, allocator = context.temp_allocator)
		for name in candidate_names {
			visited[name] = true
		}

		related_names := make([dynamic]string, context.temp_allocator)
		for name in candidate_names {
			for entry in node.registry {
				if entry.name == name {
					rel := len(entry.gate_related) > 0 ? entry.gate_related : entry.catalog.related
					if rel != nil {
						for r in rel {
							if r not_in visited {
								visited[r] = true
								append(&related_names, r)
							}
						}
					}
					break
				}
			}
		}

		if len(related_names) > 0 {
			_traverse_search_shards(
				node,
				related_names[:],
				req.query,
				limit,
				budget,
				max_total,
				now,
				&wire,
				&chars_used,
				allocator,
			)
		}
	}

	_sort_wire_results(wire[:])

	for len(wire) > max_total {
		pop(&wire)
	}

	return _marshal(Response{status = "ok", results = wire[:]}, allocator)
}

_traverse_layer0 :: proc(
	node: ^Node,
	query: string,
	max_branches: int,
	allocator := context.allocator,
) -> [dynamic]Wire_Result {
	wire := make([dynamic]Wire_Result, allocator)

	if len(node.vec_index.entries) > 0 {
		results := index_query(node, query, max_branches * 2, context.temp_allocator)
		if results != nil && len(results) > 0 {
			q_tokens := _tokenize(query, context.temp_allocator)
			defer delete(q_tokens, context.temp_allocator)
			for r in results {
				if len(wire) >= max_branches do break
				purpose := ""
				rejected := false
				for entry in node.registry {
					if entry.name == r.name {
						purpose = entry.catalog.purpose
						if entry.gate_negative != nil {
							rejected = _negative_gate_rejects(entry.gate_negative, q_tokens)
						}
						break
					}
				}
				if rejected do continue
				append(
					&wire,
					Wire_Result {
						id = strings.clone(r.name, allocator),
						score = r.score,
						description = strings.clone(purpose, allocator),
					},
				)
			}
			if len(wire) > 0 do return wire
		}
	}

	q_tokens := _tokenize(query, context.temp_allocator)
	defer delete(q_tokens, context.temp_allocator)
	if len(q_tokens) == 0 do return wire

	scored := make([dynamic]Gate_Score, context.temp_allocator)
	defer delete(scored)

	for entry in node.registry {
		gs := _score_gates(entry, q_tokens)
		if gs.score > 0 {
			append(&scored, gs)
		}
	}

	for i := 1; i < len(scored); i += 1 {
		key := scored[i]
		j := i - 1
		for j >= 0 && scored[j].score < key.score {
			scored[j + 1] = scored[j]
			j -= 1
		}
		scored[j + 1] = key
	}

	count := min(len(scored), max_branches)
	for i in 0 ..< count {
		gs := scored[i]
		matched_str := ""
		if len(gs.matched) > 0 {
			matched_str = strings.join(gs.matched[:], ", ", allocator)
		}
		append(
			&wire,
			Wire_Result {
				id = strings.clone(gs.name, allocator),
				score = gs.score,
				description = strings.clone(gs.purpose, allocator),
				content = matched_str,
			},
		)
	}

	return wire
}

_traverse_search_shards :: proc(
	node: ^Node,
	shard_names: []string,
	query: string,
	limit_per_shard: int,
	budget: int,
	max_total: int,
	now: time.Time,
	wire: ^[dynamic]Wire_Result,
	chars_used: ^int,
	allocator := context.allocator,
) {
	for name in shard_names {
		if len(wire) >= max_total do break

		entry_ptr := _find_registry_entry(node, name)
		if entry_ptr == nil do continue

		slot := _slot_get_or_create(node, entry_ptr)
		if !slot.loaded {
			key_hex := _access_resolve_key(name)
			if !_slot_load(slot, key_hex) do continue
		}
		if !slot.key_set {
			key_hex := _access_resolve_key(name)
			if key_hex != "" {
				_slot_set_key(slot, key_hex)
			}
		}
		if !slot.key_set do continue

		slot.last_access = time.now()

		if len(slot.index) == 0 &&
		   (len(slot.blob.processed) > 0 || len(slot.blob.unprocessed) > 0) {
			_slot_build_index(slot)
		}

		if len(slot.index) == 0 do continue
		hits := search_query(slot.index[:], query, context.temp_allocator)
		if hits == nil do continue

		count := 0
		for h in hits {
			if count >= limit_per_shard do break
			if len(wire) >= max_total do break

			thought, found := blob_get(&slot.blob, h.id)
			if !found do continue

			pt, err := thought_decrypt(thought, slot.master, allocator)
			if err != .None do continue

			new_content, new_truncated, new_chars := _truncate_to_budget(
				pt.content,
				budget,
				chars_used^,
			)
			chars_used^ = new_chars

			composite := _composite_score(h.score, thought, now)

			thought_hex := id_to_hex(h.id, context.temp_allocator)
			combined_id := fmt.aprintf("%s/%s", name, thought_hex, allocator = allocator)

			append(
				wire,
				Wire_Result {
					id = combined_id,
					shard_name = strings.clone(name, allocator),
					score = composite,
					description = pt.description,
					content = new_content,
					truncated = new_truncated,
					relevance_score = composite,
				},
			)
			count += 1
		}
	}
}

_op_global_query :: proc(node: ^Node, req: Request, allocator := context.allocator) -> string {
	if req.query == "" do return _err_response("query required", allocator)

	cfg := config_get()
	threshold := req.threshold > 0 ? req.threshold : cfg.global_query_threshold
	limit_per_shard := req.thought_count > 0 ? req.thought_count : cfg.default_query_limit
	budget := req.budget > 0 ? req.budget : cfg.default_query_budget
	max_total := req.limit > 0 ? req.limit : (cfg.traverse_results > 0 ? cfg.traverse_results : 10)
	now := time.now()

	q_tokens := _tokenize(req.query, context.temp_allocator)
	if len(q_tokens) == 0 do return _err_response("query produced no tokens", allocator)

	candidates := make([dynamic]_Scored_Shard, context.temp_allocator)

	if len(node.vec_index.entries) > 0 {
		vec_results := index_query(node, req.query, len(node.registry), context.temp_allocator)
		if vec_results != nil && len(vec_results) > 0 {
			for r in vec_results {
				if r.score >= threshold {
					rejected := false
					for entry in node.registry {
						if entry.name == r.name {
							if entry.gate_negative != nil {
								rejected = _negative_gate_rejects(entry.gate_negative, q_tokens)
							}
							break
						}
					}
					if !rejected {
						append(&candidates, _Scored_Shard{name = r.name, score = r.score})
					}
				}
			}
		}
	}

	if len(candidates) == 0 {
		for entry in node.registry {
			if entry.name == DAEMON_NAME do continue
			gs := _score_gates(entry, q_tokens)
			if gs.score >= threshold {
				append(&candidates, _Scored_Shard{name = gs.name, score = gs.score})
			}
		}
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

	wire := make([dynamic]Wire_Result, allocator)
	shards_searched := 0

	for c in candidates {
		if len(wire) >= max_total do break

		entry_ptr := _find_registry_entry(node, c.name)
		if entry_ptr == nil do continue

		slot := _slot_get_or_create(node, entry_ptr)
		if !slot.loaded {
			key_hex := _access_resolve_key(c.name)
			if !_slot_load(slot, key_hex) do continue
		}
		if !slot.key_set {
			key_hex := _access_resolve_key(c.name)
			if key_hex != "" {
				_slot_set_key(slot, key_hex)
			}
		}
		if !slot.key_set do continue

		slot.last_access = time.now()

		if len(slot.index) == 0 &&
		   (len(slot.blob.processed) > 0 || len(slot.blob.unprocessed) > 0) {
			_slot_build_index(slot)
		}

		if len(slot.index) == 0 do continue
		hits := search_query(slot.index[:], req.query, context.temp_allocator)
		if hits == nil do continue

		shards_searched += 1
		count := 0
		chars_used_acc := 0
		for h in hits {
			if count >= limit_per_shard do break
			if len(wire) >= max_total do break

			thought, found := blob_get(&slot.blob, h.id)
			if !found do continue

			pt, err := thought_decrypt(thought, slot.master, allocator)
			if err != .None do continue

			new_content, new_truncated, _ := _truncate_to_budget(
				pt.content,
				budget,
				chars_used_acc,
			)

			composite := _composite_score(h.score, thought, now)

			thought_hex := id_to_hex(h.id, context.temp_allocator)
			combined_id := fmt.aprintf("%s/%s", c.name, thought_hex, allocator = allocator)

			append(
				&wire,
				Wire_Result {
					id = combined_id,
					shard_name = strings.clone(c.name, allocator),
					score = composite,
					description = pt.description,
					content = new_content,
					truncated = new_truncated,
					relevance_score = composite,
				},
			)
			count += 1
		}
	}

	_sort_wire_results(wire[:])

	for len(wire) > max_total {
		pop(&wire)
	}

	if req.format == "dump" {
		b := strings.builder_make(allocator)
		if len(wire) == 0 {
			strings.write_string(&b, "*No results matched your query.*\n")
		} else {
			current_shard := ""
			for r in wire {
				if r.shard_name != current_shard {
					current_shard = r.shard_name
					fmt.sbprintf(&b, "\n# %s\n", current_shard)
				}
				fmt.sbprintf(&b, "\n### %s\n\n%s\n", r.description, r.content)
			}
		}
		return _marshal(
			Response{status = "ok", content = strings.to_string(b)},
			allocator,
		)
	}
	return _marshal(
		Response {
			status          = "ok",
			results         = wire[:],
			shards_searched = shards_searched,
			total_results   = len(wire),
		},
		allocator,
	)
}

_sort_wire_results :: proc(results: []Wire_Result) {
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

_negative_gate_rejects :: proc(gate_negative: []string, q_tokens: []string) -> bool {
	for neg in gate_negative {
		neg_tokens := _tokenize(neg, context.temp_allocator)
		defer delete(neg_tokens, context.temp_allocator)
		for qt in q_tokens {
			qt_stem := _stem(qt)
			for nt in neg_tokens {
				if qt == nt || qt_stem == _stem(nt) do return true
			}
		}
	}
	return false
}

_score_gates :: proc(entry: Registry_Entry, q_tokens: []string) -> Gate_Score {
	result: Gate_Score
	result.name = entry.name
	result.purpose = entry.catalog.purpose
	result.matched = make([dynamic]string, context.temp_allocator)

	raw_score: f32 = 0
	max_possible: f32 = f32(len(q_tokens)) * 2
	if max_possible == 0 {return result}

	if entry.gate_negative != nil {
		for neg in entry.gate_negative {
			neg_tokens := _tokenize(neg, context.temp_allocator)
			defer delete(neg_tokens, context.temp_allocator)
			for qt in q_tokens {
				for nt in neg_tokens {
					if qt == nt {
						result.score = 0
						return result
					}
				}
			}
		}
	}

	matched_set: map[string]bool
	defer delete(matched_set)

	if entry.gate_positive != nil {
		for pos in entry.gate_positive {
			pos_tokens := _tokenize(pos, context.temp_allocator)
			defer delete(pos_tokens, context.temp_allocator)
			for qt in q_tokens {
				if qt in matched_set do continue
				for pt in pos_tokens {
					if qt == pt {
						raw_score += 2
						matched_set[qt] = true
						append(&result.matched, qt)
						break
					}
				}
			}
		}
	}

	if entry.gate_desc != nil {
		for desc in entry.gate_desc {
			desc_tokens := _tokenize(desc, context.temp_allocator)
			defer delete(desc_tokens, context.temp_allocator)
			for qt in q_tokens {
				if qt in matched_set do continue
				for dt in desc_tokens {
					if qt == dt {
						raw_score += 1
						matched_set[qt] = true
						append(&result.matched, qt)
						break
					}
				}
			}
		}
	}

	cat_name := entry.catalog.name != "" ? entry.catalog.name : entry.name
	name_tokens := _tokenize(cat_name, context.temp_allocator)
	defer delete(name_tokens, context.temp_allocator)
	for qt in q_tokens {
		if qt in matched_set do continue
		for nt in name_tokens {
			if qt == nt {
				raw_score += 1
				matched_set[qt] = true
				append(&result.matched, qt)
				break
			}
		}
	}

	if entry.catalog.purpose != "" {
		purpose_tokens := _tokenize(entry.catalog.purpose, context.temp_allocator)
		defer delete(purpose_tokens, context.temp_allocator)
		for qt in q_tokens {
			if qt in matched_set do continue
			for pt in purpose_tokens {
				if qt == pt {
					raw_score += 1
					matched_set[qt] = true
					append(&result.matched, qt)
					break
				}
			}
		}
	}

	if entry.catalog.tags != nil {
		for tag in entry.catalog.tags {
			tag_tokens := _tokenize(tag, context.temp_allocator)
			defer delete(tag_tokens, context.temp_allocator)
			for qt in q_tokens {
				if qt in matched_set do continue
				for tt in tag_tokens {
					if qt == tt {
						raw_score += 1
						matched_set[qt] = true
						append(&result.matched, qt)
						break
					}
				}
			}
		}
	}

	result.score = min(raw_score / max_possible, 1.0)
	return result
}
