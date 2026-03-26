package shard

import "core:fmt"
import "core:log"
import "core:strings"

Context_Candidate :: struct {
	id:          Thought_ID,
	description: string,
	content:     string,
	score:       f64,
}

context_clean_word :: proc(word: string) -> string {
	clean := strings.to_lower(
		strings.trim(strings.trim_space(word), "?!.,;:\"'()[]{}"),
		runtime_alloc,
	)
	if len(clean) < 3 do return ""
	return clean
}

context_ephemeral_agent :: proc() -> string {
	id_hex := thought_id_to_hex(new_thought_id())
	if len(id_hex) > 12 do id_hex = id_hex[:12]
	return fmt.aprintf("request:%s", id_hex, allocator = runtime_alloc)
}

context_session_prune :: proc() {
	for len(state.context_sessions) > CONTEXT_SESSION_MAX_ENTRIES {
		oldest_key := ""
		oldest_stamp := ""
		found := false
		for key, session in state.context_sessions {
			stamp := session.last_used_at
			if len(stamp) == 0 do stamp = session.started_at
			if !found || stamp < oldest_stamp {
				found = true
				oldest_key = key
				oldest_stamp = stamp
			}
		}
		if !found do return

		next := make(map[string]Context_Session, runtime_alloc)
		for key, session in state.context_sessions {
			if key == oldest_key do continue
			next[strings.clone(key, runtime_alloc)] = session
		}
		state.context_sessions = next
	}
}

context_session_get_or_create :: proc(agent: string, persist: bool) -> Context_Session {
	normalized_agent := strings.trim_space(agent)
	if len(normalized_agent) == 0 {
		if persist {
			normalized_agent = "anonymous"
		} else {
			normalized_agent = context_ephemeral_agent()
		}
	}
	if persist {
		if existing, ok := state.context_sessions[normalized_agent]; ok do return existing
	}
	now := now_rfc3339()

	session := Context_Session {
		id           = opaque_cache_key("session", normalized_agent),
		agent        = strings.clone(normalized_agent, runtime_alloc),
		started_at   = now,
		last_used_at = now,
	}
	session.recent_queries.allocator = runtime_alloc
	session.dominant_terms.allocator = runtime_alloc
	session.topic_mix.allocator = runtime_alloc
	session.unresolved_threads.allocator = runtime_alloc
	if persist {
		state.context_sessions[strings.clone(normalized_agent, runtime_alloc)] = session
		context_session_prune()
	}
	return session
}

context_session_update_query :: proc(session: ^Context_Session, question: string) {
	session.last_used_at = now_rfc3339()
	trimmed := strings.trim_space(question)
	if len(trimmed) == 0 do return

	session.recent_queries.allocator = runtime_alloc
	append(&session.recent_queries, strings.clone(trimmed, runtime_alloc))
	if len(session.recent_queries) > 8 {
		over := len(session.recent_queries) - 8
		trimmed_queries: [dynamic]string
		trimmed_queries.allocator = runtime_alloc
		for q in session.recent_queries[over:] do append(&trimmed_queries, q)
		session.recent_queries = trimmed_queries
	}

	if strings.contains(trimmed, "?") {
		session.unresolved_threads.allocator = runtime_alloc
		append(&session.unresolved_threads, strings.clone(trimmed, runtime_alloc))
		if len(session.unresolved_threads) > 6 {
			over := len(session.unresolved_threads) - 6
			trimmed_threads: [dynamic]string
			trimmed_threads.allocator = runtime_alloc
			for q in session.unresolved_threads[over:] do append(&trimmed_threads, q)
			session.unresolved_threads = trimmed_threads
		}
	}
}

context_session_infer_topic_mix :: proc(session: ^Context_Session) {
	freq: map[string]f64
	freq.allocator = runtime_alloc

	for q in session.recent_queries {
		for word in strings.split(q, " ", allocator = runtime_alloc) {
			clean := context_clean_word(word)
			if len(clean) == 0 do continue
			freq[clean] = freq[clean] + 1
		}
	}

	terms: [dynamic]Context_Term
	terms.allocator = runtime_alloc
	total := 0.0
	for term, count in freq {
		total += count
		append(&terms, Context_Term{term = strings.clone(term, runtime_alloc), weight = count})
	}

	for i in 0 ..< len(terms) {
		best := i
		for j in i + 1 ..< len(terms) {
			if terms[j].weight > terms[best].weight do best = j
		}
		if best != i {
			tmp := terms[i]
			terms[i] = terms[best]
			terms[best] = tmp
		}
	}

	limit := len(terms)
	if limit > 6 do limit = 6
	dominant: [dynamic]Context_Term
	dominant.allocator = runtime_alloc
	mix: [dynamic]Context_Term
	mix.allocator = runtime_alloc
	for i in 0 ..< limit {
		append(&dominant, terms[i])
		weight := terms[i].weight
		if total > 0 do weight = weight / total
		append(&mix, Context_Term{term = terms[i].term, weight = weight})
	}

	session.dominant_terms = dominant
	session.topic_mix = mix
}

context_candidates_collect :: proc(
	question: string,
	session: Context_Session,
) -> []Context_Candidate {
	term_weights: map[string]f64
	term_weights.allocator = runtime_alloc

	for word in strings.split(question, " ", allocator = runtime_alloc) {
		clean := context_clean_word(word)
		if len(clean) == 0 do continue
		term_weights[clean] = term_weights[clean] + 1.5
	}
	for term in session.topic_mix {
		term_weights[term.term] = term_weights[term.term] + term.weight
	}

	results: [dynamic]Context_Candidate
	results.allocator = runtime_alloc
	s := &state.blob.shard
	for block in ([2][][]u8{s.processed, s.unprocessed}) {
		for blob in block {
			pos := 0
			t, ok := thought_parse(blob, &pos)
			if !ok do continue
			desc, content, decrypt_ok := thought_decrypt(state.key, &t)
			if !decrypt_ok do continue

			score := 0.0
			lower_desc := strings.to_lower(desc, runtime_alloc)
			lower_content := strings.to_lower(content, runtime_alloc)
			for term, weight in term_weights {
				if strings.contains(lower_desc, term) do score += weight * 2
				if strings.contains(lower_content, term) do score += weight
			}
			score += f64(t.read_count) * 0.05
			score += f64(t.cite_count) * 0.1
			if score <= 0 do continue

			append(
				&results,
				Context_Candidate{id = t.id, description = desc, content = content, score = score},
			)
		}
	}

	for i in 0 ..< len(results) {
		best := i
		for j in i + 1 ..< len(results) {
			if results[j].score > results[best].score do best = j
		}
		if best != i {
			tmp := results[i]
			results[i] = results[best]
			results[best] = tmp
		}
	}

	if len(results) == 0 {
		fallback: [dynamic]Context_Candidate
		fallback.allocator = runtime_alloc

		collect_from_block :: proc(block: [][]u8, out: ^[dynamic]Context_Candidate) {
			for i := len(block) - 1; i >= 0; i -= 1 {
				if len(out^) >= CONTEXT_FALLBACK_MAX_THOUGHTS do return
				pos := 0
				t, ok := thought_parse(block[i], &pos)
				if !ok do continue
				desc, content, decrypt_ok := thought_decrypt(state.key, &t)
				if !decrypt_ok do continue
				append(
					out,
					Context_Candidate {
						id = t.id,
						description = desc,
						content = content,
						score = 0.01,
					},
				)
			}
		}

		collect_from_block(s.unprocessed, &fallback)
		if len(fallback) < CONTEXT_FALLBACK_MAX_THOUGHTS do collect_from_block(s.processed, &fallback)
		return fallback[:]
	}

	return results[:]
}

context_descriptions_similar :: proc(a: string, b: string) -> bool {
	left := strings.to_lower(strings.trim_space(a), runtime_alloc)
	right := strings.to_lower(strings.trim_space(b), runtime_alloc)
	if left == right do return true

	left_tokens: map[string]bool
	left_tokens.allocator = runtime_alloc
	for word in strings.split(left, " ", allocator = runtime_alloc) {
		clean := context_clean_word(word)
		if len(clean) > 0 do left_tokens[clean] = true
	}
	if len(left_tokens) == 0 do return false

	common := 0
	right_count := 0
	for word in strings.split(right, " ", allocator = runtime_alloc) {
		clean := context_clean_word(word)
		if len(clean) == 0 do continue
		right_count += 1
		if clean in left_tokens do common += 1
	}
	if right_count == 0 do return false

	denom := len(left_tokens)
	if right_count > denom do denom = right_count
	if denom == 0 do return false
	return f64(common) / f64(denom) >= 0.8
}

context_candidates_micro_compact :: proc(candidates: []Context_Candidate) -> []Context_Candidate {
	compact: [dynamic]Context_Candidate
	compact.allocator = runtime_alloc

	for candidate in candidates {
		duplicate := false
		for kept in compact {
			if context_descriptions_similar(candidate.description, kept.description) {
				duplicate = true
				break
			}
		}
		if duplicate do continue
		append(&compact, candidate)
		if len(compact) >= 8 do break
	}

	return compact[:]
}

context_packet_summary :: proc(candidates: []Context_Candidate) -> string {
	if len(candidates) == 0 do return ""
	if len(candidates[0].description) == 0 {
		return fmt.aprintf(
			"Found %d relevant thoughts",
			len(candidates),
			allocator = runtime_alloc,
		)
	}
	return fmt.aprintf(
		"Found %d relevant thoughts. Top match: %s",
		len(candidates),
		candidates[0].description,
		allocator = runtime_alloc,
	)
}

build_context_packet :: proc(question: string, agent: string) -> Context_Packet {
	maybe_maintenance()
	if !state.has_key do return {}

	persist := len(strings.trim_space(agent)) > 0
	session := context_session_get_or_create(agent, persist)
	context_session_update_query(&session, question)
	context_session_infer_topic_mix(&session)
	if persist {
		state.context_sessions[session.agent] = session
		context_session_prune()
	}

	packet := Context_Packet {
		session_id     = session.id,
		generated_at   = now_rfc3339(),
		based_on_query = strings.clone(question, runtime_alloc),
	}

	s := &state.blob.shard
	if len(s.processed) == 0 && len(s.unprocessed) == 0 do return packet

	shard_name := s.catalog.name
	if len(shard_name) == 0 do shard_name = state.shard_id
	packet.included_shards.allocator = runtime_alloc
	append(&packet.included_shards, strings.clone(shard_name, runtime_alloc))

	candidates := context_candidates_collect(question, session)
	if len(candidates) == 0 do return packet

	compacted := context_candidates_micro_compact(candidates)
	packet.included_thought_ids.allocator = runtime_alloc
	for c in compacted do append(&packet.included_thought_ids, thought_id_to_hex(c.id))
	packet.summary = context_packet_summary(compacted)

	if len(compacted) >= 4 {
		packet.confidence_notes = "high confidence from multiple relevant thoughts"
	} else if len(compacted) >= 1 {
		packet.confidence_notes = "moderate confidence from focused local evidence"
	} else {
		packet.confidence_notes = "low confidence"
	}

	for c in compacted {
		if !cite_count_touch(c.id, 1) {
			log.errorf("Failed to record cite usage for thought %s", thought_id_to_hex(c.id))
		}
	}

	return packet
}

context_packet_render :: proc(packet: Context_Packet) -> string {
	if len(packet.included_thought_ids) == 0 && len(packet.summary) == 0 do return ""

	cache_load()
	b := strings.builder_make(runtime_alloc)
	if len(state.topic_cache) > 0 {
		strings.write_string(&b, "## Active Topics\n\n")
		for key, entry in state.topic_cache {
			label := cache_safe_label(entry)
			id_fragment := cache_display_id_fragment(key)
			if len(entry.author) > 0 {
				fmt.sbprintf(
					&b,
					"- **%s** (id: %s): %s [%s]\n",
					label,
					id_fragment,
					entry.value,
					entry.author,
				)
			} else {
				fmt.sbprintf(&b, "- **%s** (id: %s): %s\n", label, id_fragment, entry.value)
			}
		}
		strings.write_string(&b, "\n")
	}

	if len(state.blob.shard.catalog.name) > 0 {
		fmt.sbprintf(
			&b,
			"## Shard: %s\n\n%s\n\n",
			state.blob.shard.catalog.name,
			state.blob.shard.catalog.purpose,
		)
	}

	if len(packet.summary) > 0 do fmt.sbprintf(&b, "## Summary\n\n%s\n\n", packet.summary)
	if len(packet.confidence_notes) > 0 do fmt.sbprintf(&b, "## Confidence\n\n%s\n\n", packet.confidence_notes)

	for id_hex in packet.included_thought_ids {
		tid, ok := hex_to_thought_id(id_hex)
		if !ok do continue
		desc, content, read_ok := read_thought_core(tid, false)
		if !read_ok do continue
		fmt.sbprintf(&b, "### %s\n\n%s\n\n", desc, content)
	}

	return strings.to_string(b)
}

context_packet_to_json :: proc(packet: Context_Packet) -> string {
	b := strings.builder_make(runtime_alloc)
	strings.write_string(&b, "{")
	fmt.sbprintf(&b, `"session_id":"%s",`, process_json_escape(packet.session_id))
	fmt.sbprintf(&b, `"generated_at":"%s",`, process_json_escape(packet.generated_at))
	fmt.sbprintf(&b, `"based_on_query":"%s",`, process_json_escape(packet.based_on_query))
	strings.write_string(&b, `"included_shards":[`)
	for shard, i in packet.included_shards {
		if i > 0 do strings.write_string(&b, ",")
		fmt.sbprintf(&b, `"%s"`, process_json_escape(shard))
	}
	strings.write_string(&b, `],"included_thought_ids":[`)
	for id_hex, i in packet.included_thought_ids {
		if i > 0 do strings.write_string(&b, ",")
		fmt.sbprintf(&b, `"%s"`, process_json_escape(id_hex))
	}
	fmt.sbprintf(
		&b,
		`],"summary":"%s","confidence_notes":"%s"}`,
		process_json_escape(packet.summary),
		process_json_escape(packet.confidence_notes),
	)
	return strings.to_string(b)
}

build_context :: proc(question: string, agent: string = "") -> string {
	packet := build_context_packet(question, agent)
	return context_packet_render(packet)
}
