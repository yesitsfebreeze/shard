package shard

import "core:crypto/hash"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"

split_tokenize :: proc(text: string) -> [dynamic]string {
	tokens: [dynamic]string
	tokens.allocator = runtime_alloc
	if len(text) == 0 do return tokens

	normalized: [dynamic]u8
	normalized.allocator = runtime_alloc
	prev_sep := true
	for ch in transmute([]u8)text {
		c := ch
		if c >= 'A' && c <= 'Z' {
			c = c - 'A' + 'a'
		}
		is_word := (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')
		if is_word {
			append(&normalized, c)
			prev_sep = false
		} else if !prev_sep {
			append(&normalized, ' ')
			prev_sep = true
		}
	}

	cleaned := strings.trim_space(string(normalized[:]))
	if len(cleaned) == 0 do return tokens

	seen: map[string]bool
	seen.allocator = runtime_alloc
	for part in strings.split(cleaned, " ", allocator = runtime_alloc) {
		if len(part) < 3 do continue
		if _, exists := seen[part]; exists do continue
		seen[part] = true
		append(&tokens, part)
	}

	return tokens
}

split_score_text_against_signal :: proc(text: string, signal: string) -> f64 {
	text_tokens := split_tokenize(text)
	if len(text_tokens) == 0 do return 0

	signal_tokens := split_tokenize(signal)
	if len(signal_tokens) == 0 do return 0

	signal_set: map[string]bool
	signal_set.allocator = runtime_alloc
	for token in signal_tokens do signal_set[token] = true

	hits := 0
	for token in text_tokens {
		if token in signal_set {
			hits += 1
		}
	}

	return f64(hits) / f64(len(text_tokens))
}

split_router_keyword_hints :: proc(entry: Cache_Entry) -> (string, string) {
	raw := strings.trim_space(entry.value)
	if len(raw) == 0 || raw[0] != '{' do return "", ""

	parsed, err := json.parse(transmute([]u8)raw, allocator = runtime_alloc)
	if err != nil do return "", ""
	obj, ok := parsed.(json.Object)
	if !ok do return "", ""

	a_fields := []string {
		"topic_a_hints",
		"topic_a_keywords",
		"topic_a_terms",
		"a_hints",
		"a_keywords",
	}
	b_fields := []string {
		"topic_b_hints",
		"topic_b_keywords",
		"topic_b_terms",
		"b_hints",
		"b_keywords",
	}
	a_hint := ""
	b_hint := ""
	if hint_text, hint_ok := json_first_non_empty_text(obj, a_fields, runtime_alloc); hint_ok {
		a_hint = hint_text
	}
	if hint_text, hint_ok := json_first_non_empty_text(obj, b_fields, runtime_alloc); hint_ok {
		b_hint = hint_text
	}

	if hints_value, has := obj["router_hints"]; has {
		if hints_obj, hints_ok := hints_value.(json.Object); hints_ok {
			if len(a_hint) == 0 {
				a_hint, _ = json_first_non_empty_text(hints_obj, []string{"topic_a", "a", "left"}, runtime_alloc)
			}
			if len(b_hint) == 0 {
				b_hint, _ = json_first_non_empty_text(hints_obj, []string{"topic_b", "b", "right"}, runtime_alloc)
			}
		}
	}

	return a_hint, b_hint
}

split_topic_is_placeholder :: proc(topic: string) -> bool {
	t := strings.to_lower(strings.trim_space(topic), runtime_alloc)
	if len(t) == 0 do return true
	if t == "topic-a" || t == "topic-b" || t == "topic_a" || t == "topic_b" do return true
	if strings.has_suffix(t, "-topic-a") || strings.has_suffix(t, "-topic-b") do return true
	if strings.has_suffix(t, "_topic_a") || strings.has_suffix(t, "_topic_b") do return true
	return false
}

split_state_needs_topic_resolution :: proc(split_state: Split_State) -> bool {
	if !split_state.active do return false
	if split_topic_is_placeholder(split_state.topic_a) do return true
	if split_topic_is_placeholder(split_state.topic_b) do return true
	if split_state.topic_a == split_state.topic_b do return true
	return false
}

split_collect_text_for_naming :: proc(
	description: string,
	content: string,
	max_thoughts: int = 24,
) -> string {
	b := strings.builder_make(runtime_alloc)
	if len(description) > 0 {
		strings.write_string(&b, description)
		strings.write_string(&b, "\n")
	}
	if len(content) > 0 {
		strings.write_string(&b, content)
		strings.write_string(&b, "\n")
	}

	if !state.has_key || !state.blob.has_data {
		return strings.to_string(b)
	}

	s := &state.blob.shard
	count := 0
	for block in ([2][][]u8{s.unprocessed, s.processed}) {
		for blob in block {
			if count >= max_thoughts do return strings.to_string(b)
			pos := 0
			t, ok := thought_parse(blob, &pos)
			if !ok do continue
			desc, text, dec_ok := thought_decrypt(state.key, &t)
			if !dec_ok do continue
			if len(desc) > 0 {
				strings.write_string(&b, desc)
				strings.write_string(&b, "\n")
			}
			if len(text) > 0 {
				strings.write_string(&b, text)
				strings.write_string(&b, "\n")
			}
			count += 1
		}
	}

	return strings.to_string(b)
}

split_clean_title :: proc(raw: string) -> string {
	tokens := split_tokenize(raw)
	if len(tokens) == 0 do return ""
	b := strings.builder_make(runtime_alloc)
	for tok, i in tokens {
		if i >= 5 do break
		if i > 0 do strings.write_string(&b, " ")
		strings.write_string(&b, tok)
	}
	return strings.to_string(b)
}

split_parse_topics_from_llm :: proc(raw: string) -> (string, string, string, bool) {
	trimmed := strings.trim_space(raw)
	if len(trimmed) == 0 do return "", "", "", false

	json_line := trimmed
	if trimmed[0] != '{' {
		for line in strings.split(trimmed, "\n", allocator = runtime_alloc) {
			line_trim := strings.trim_space(line)
			if len(line_trim) > 0 && line_trim[0] == '{' {
				json_line = line_trim
				break
			}
		}
	}
	if len(json_line) == 0 || json_line[0] != '{' do return "", "", "", false

	parsed, err := json.parse(transmute([]u8)json_line, allocator = runtime_alloc)
	if err != nil do return "", "", "", false
	obj, ok := parsed.(json.Object)
	if !ok do return "", "", "", false

	title_a, _ := json_first_non_empty_string(obj, []string{"topic_a_title", "topic_a", "a_title", "a"}, runtime_alloc)
	title_b, _ := json_first_non_empty_string(obj, []string{"topic_b_title", "topic_b", "b_title", "b"}, runtime_alloc)
	label, _ := json_first_non_empty_string(obj, []string{"label", "reason", "split_reason", "title"}, runtime_alloc)

	title_a = split_clean_title(title_a)
	title_b = split_clean_title(title_b)
	label = split_clean_title(label)

	if len(title_a) == 0 || len(title_b) == 0 do return "", "", "", false
	if title_a == title_b do return "", "", "", false
	return title_a, title_b, label, true
}

split_infer_topics_with_llm :: proc(seed: string) -> (string, string, string, bool) {
	if !state.has_llm do return "", "", "", false
	if len(strings.trim_space(seed)) == 0 do return "", "", "", false

	system := "Return ONLY one JSON object with keys topic_a_title, topic_b_title, label. Pick two distinct short topic titles (1-4 words each) that explain why this shard should split. No markdown."
	user := fmt.aprintf("Shard id: %s\n\nContext:\n%s", state.shard_id, seed, allocator = runtime_alloc)
	response, ok := llm_chat(system, user)
	if !ok do return "", "", "", false
	return split_parse_topics_from_llm(response)
}

split_infer_topics_fallback :: proc(seed: string) -> (string, string, string) {
	tokens := split_tokenize(seed)
	if len(tokens) == 0 {
		return "cluster one", "cluster two", "auto split by fallback"
	}

	counts: map[string]int
	counts.allocator = runtime_alloc
	for tok in tokens {
		if len(tok) < 4 do continue
		if tok == "this" || tok == "that" || tok == "with" || tok == "from" || tok == "have" || tok == "were" || tok == "into" do continue
		counts[tok] += 1
	}

	scored: [dynamic]string
	scored.allocator = runtime_alloc
	for tok, _ in counts {
		append(&scored, tok)
	}
	for i in 0 ..< len(scored) {
		for j in i + 1 ..< len(scored) {
			if counts[scored[j]] > counts[scored[i]] {
				scored[i], scored[j] = scored[j], scored[i]
			}
		}
	}

	title_a := "cluster one"
	title_b := "cluster two"
	if len(scored) > 0 do title_a = strings.concatenate({scored[0], " focus"}, runtime_alloc)
	if len(scored) > 1 {
		title_b = strings.concatenate({scored[1], " focus"}, runtime_alloc)
	} else {
		title_b = strings.concatenate({title_a, " secondary"}, runtime_alloc)
	}

	label := fmt.aprintf("auto split by %s and %s", title_a, title_b, allocator = runtime_alloc)
	return title_a, title_b, label
}

split_build_topic_name_and_id :: proc(title: string, ordinal: int) -> (string, string) {
	clean_title := split_clean_title(title)
	if len(clean_title) == 0 {
		clean_title = fmt.aprintf("cluster %d", ordinal, allocator = runtime_alloc)
	}
	name := fmt.aprintf("%s %s", state.shard_id, clean_title, allocator = runtime_alloc)
	return name, slugify(name)
}

split_peer_exists :: proc(peers: []Index_Entry, shard_id: string) -> bool {
	for peer in peers {
		if peer.shard_id == shard_id do return true
	}
	return false
}

split_resolve_named_topics :: proc(
	split_state: Split_State,
	peers: []Index_Entry,
	description: string,
	content: string,
) -> (
	Split_State,
	bool,
) {
	if !split_state_needs_topic_resolution(split_state) do return split_state, false

	seed := split_collect_text_for_naming(description, content)
	title_a, title_b, label, has_llm_titles := split_infer_topics_with_llm(seed)
	if !has_llm_titles {
		title_a, title_b, label = split_infer_topics_fallback(seed)
	}

	name_a, id_a := split_build_topic_name_and_id(title_a, 1)
	name_b, id_b := split_build_topic_name_and_id(title_b, 2)
	if id_b == id_a {
		name_b = fmt.aprintf("%s alternate", name_b, allocator = runtime_alloc)
		id_b = slugify(name_b)
	}

	if !split_peer_exists(peers, id_a) {
		purpose_a := fmt.aprintf("Auto-split topic from %s: %s", state.shard_id, title_a, allocator = runtime_alloc)
		_ = create_shard(name_a, purpose_a)
	}
	if !split_peer_exists(peers, id_b) {
		purpose_b := fmt.aprintf("Auto-split topic from %s: %s", state.shard_id, title_b, allocator = runtime_alloc)
		_ = create_shard(name_b, purpose_b)
	}

	resolved := split_state
	resolved.topic_a = id_a
	resolved.topic_b = id_b
	if len(strings.trim_space(label)) > 0 {
		resolved.label = label
	} else if len(strings.trim_space(resolved.label)) == 0 ||
	   resolved.label == "auto split state" {
		resolved.label = "auto split state"
	}

	entry := Cache_Entry {
		value   = split_state_normalized_value(resolved),
		author  = "system",
		expires = "",
	}
	cache_key := split_state_cache_key()
	state.topic_cache[strings.clone(cache_key, runtime_alloc)] = entry
	cache_save_key(cache_key, entry)

	return resolved, true
}

split_route_target_hash_fallback :: proc(
	description: string,
	content: string,
	topic_a: string,
	topic_b: string,
) -> string {
	if len(topic_a) == 0 do return topic_b
	if len(topic_b) == 0 do return topic_a

	material := strings.to_lower(strings.concatenate({description, "\n", content}, runtime_alloc), runtime_alloc)
	digest: [32]u8
	hash.hash_bytes_to_buffer(.SHA256, transmute([]u8)material, digest[:])
	if (digest[0] & 1) == 0 {
		return topic_a
	}
	return topic_b
}

split_route_target_semantic :: proc(
	description: string,
	content: string,
	topic_a: string,
	topic_b: string,	topic_a_signal: string,
	topic_b_signal: string,
	split_state_entry: Cache_Entry,
	has_split_state_entry: bool,
) -> (
	string,
	bool,
) {
	if len(topic_a) == 0 || len(topic_b) == 0 do return "", false
	thought_text := strings.concatenate({description, "\n", content}, runtime_alloc)

	score_a := split_score_text_against_signal(thought_text, topic_a_signal)
	score_b := split_score_text_against_signal(thought_text, topic_b_signal)

	if has_split_state_entry {
		hint_a, hint_b := split_router_keyword_hints(split_state_entry)
		score_a += split_score_text_against_signal(thought_text, hint_a) * 0.5
		score_b += split_score_text_against_signal(thought_text, hint_b) * 0.5
	}

	if score_a <= 0 && score_b <= 0 do return "", false

	delta := math.abs(score_a - score_b)
	if delta < 0.000001 do return "", false

	if score_a > score_b {
		return topic_a, true
	}
	return topic_b, true
}

split_peer_signal_text :: proc(peers: []Index_Entry, target: string) -> string {
	if len(target) == 0 do return ""
	for peer in peers {
		if peer.shard_id != target do continue
		raw, ok := os.read_entire_file(peer.exe_path, runtime_alloc)
		if !ok do break
		blob := load_blob_from_raw(raw)
		if !blob.has_data do break

		s := &blob.shard
		b := strings.builder_make(runtime_alloc)
		strings.write_string(&b, target)
		if len(s.catalog.name) > 0 {
			strings.write_string(&b, " ")
			strings.write_string(&b, s.catalog.name)
		}
		if len(s.catalog.purpose) > 0 {
			strings.write_string(&b, " ")
			strings.write_string(&b, s.catalog.purpose)
		}
		if len(s.gates.gate) > 0 {
			strings.write_string(&b, " ")
			strings.write_string(&b, s.gates.gate)
		}
		return strings.to_string(b)
	}
	return ""
}

split_try_peer_write :: proc(msg_bytes: []u8, peers: []Index_Entry, target: string) -> bool {
	if len(target) == 0 || target == state.shard_id do return false
	for peer in peers {
		if peer.shard_id != target do continue
		conn, ok := ipc_connect(ipc_socket_path(peer.shard_id))
		if !ok do return false
		defer ipc_close(conn)

		if !ipc_send_msg(conn, msg_bytes) do return false
		resp, recv_ok := ipc_recv_msg(conn)
		if !recv_ok do return false

		resp_str := string(resp)
		if strings.contains(resp_str, "isError") do return false
		return true
	}
	return false
}

split_mark_pretried_targets :: proc(
	tried: ^map[string]bool,
	split_state: Split_State,
	has_split_state: bool,
) {
	if !has_split_state do return
	if len(split_state.topic_a) > 0 do tried^[split_state.topic_a] = true
	if len(split_state.topic_b) > 0 do tried^[split_state.topic_b] = true
}
