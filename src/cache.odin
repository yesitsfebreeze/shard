package shard

import "core:fmt"
import "core:encoding/json"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:log"

cache_load :: proc() {
	ensure_dir(state.cache_dir)
	dh, err := os.open(state.cache_dir)
	if err != nil do return
	defer os.close(dh)

	entries, _ := os.read_dir(dh, -1, runtime_alloc)
	now := now_rfc3339()
	for entry in entries {
		if entry.is_dir do continue
		path := filepath.join({state.cache_dir, entry.name}, runtime_alloc)
		raw, ok := os.read_entire_file(path, runtime_alloc)
		if !ok do continue
		lines := strings.split(string(raw), "\n", allocator = runtime_alloc)
		if len(lines) < 1 do continue
		v := lines[0]
		a := lines[1] if len(lines) > 1 else ""
		e := lines[2] if len(lines) > 2 else ""
		if len(e) > 0 && e < now {
			os.remove(path)
			continue
		}
		state.topic_cache[strings.clone(entry.name, runtime_alloc)] = Cache_Entry {
			value   = strings.clone(v, runtime_alloc),
			author  = strings.clone(a, runtime_alloc),
			expires = strings.clone(e, runtime_alloc),
		}
	}
	cache_log_migration_note()
}

cache_save :: proc() {
	ensure_dir(state.cache_dir)
	for key, entry in state.topic_cache {
		cache_save_key(key, entry)
	}
}

cache_save_key :: proc(key: string, entry: Cache_Entry) {
	ensure_dir(state.cache_dir)
	path := filepath.join({state.cache_dir, key}, runtime_alloc)
	content := strings.concatenate({entry.value, "\n", entry.author, "\n", entry.expires}, runtime_alloc)
	os.write_entire_file(path, transmute([]u8)content)
}

cache_delete_key :: proc(key: string) {
	path := filepath.join({state.cache_dir, key}, runtime_alloc)
	os.remove(path)
	delete_key(&state.topic_cache, key)
}

cache_key_requires_migration :: proc(key: string) -> bool {
	if strings.has_prefix(key, "answer:") {
	if !string_has_colon_suffix_of_hex(key, 24) do return true
		return false
	}
	if key == legacy_split_state_cache_key() do return true
	return false
}

cache_log_migration_note :: proc() {
	if state.cache_migration_note_logged do return
	for key in state.topic_cache {
		if cache_key_requires_migration(key) {
			log.info(
				"Release note: cache keys now use opaque format; legacy keys auto-migrate on read",
			)
			state.cache_migration_note_logged = true
			return
		}
	}
}

legacy_answer_cache_key :: proc(question: string) -> string {
	return fmt.aprintf("answer:%s", question, allocator = runtime_alloc)
}

legacy_answer_cache_key_truncated :: proc(question: string) -> string {
	legacy_question := question
	if len(legacy_question) > 50 {
		legacy_question = legacy_question[:50]
	}
	return legacy_answer_cache_key(legacy_question)
}

cache_lookup_legacy_answer_entry :: proc(question: string) -> (Cache_Entry, string, bool) {
	legacy_key := legacy_answer_cache_key(question)
	if cached, found := state.topic_cache[legacy_key]; found {
		return cached, legacy_key, true
	}

	legacy_key_truncated := legacy_answer_cache_key_truncated(question)
	if legacy_key_truncated != legacy_key {
		if cached, found := state.topic_cache[legacy_key_truncated]; found {
			return cached, legacy_key_truncated, true
		}
	}

	return Cache_Entry{}, "", false
}

cache_migrate_legacy_answer_entry :: proc(
	cache_key: string,
	question: string,
) -> (
	Cache_Entry,
	string,
	bool,
) {
	if cached, legacy_key, found := cache_lookup_legacy_answer_entry(question); found {
		state.topic_cache[strings.clone(cache_key, runtime_alloc)] = Cache_Entry {
			value   = strings.clone(cached.value, runtime_alloc),
			author  = strings.clone(cached.author, runtime_alloc),
			expires = strings.clone(cached.expires, runtime_alloc),
		}
		delete_key(&state.topic_cache, legacy_key)
		return cached, legacy_key, true
	}

	return Cache_Entry{}, "", false
}

split_state_cache_key :: proc() -> string {
	return opaque_cache_key("split-state", state.shard_id)
}

legacy_split_state_cache_key :: proc() -> string {
	return fmt.aprintf("%s_split_state", state.shard_id, allocator = runtime_alloc)
}

split_state_normalized_value :: proc(state_in: Split_State) -> string {
	b := strings.builder_make(runtime_alloc)
	strings.write_string(&b, `{"active":`)
	if state_in.active {
		strings.write_string(&b, "true")
	} else {
		strings.write_string(&b, "false")
	}
	if len(state_in.topic_a) > 0 {
		fmt.sbprintf(&b, `,"topic_a":"%s"`, process_json_escape(state_in.topic_a))
	}
	if len(state_in.topic_b) > 0 {
		fmt.sbprintf(&b, `,"topic_b":"%s"`, process_json_escape(state_in.topic_b))
	}
	label := state_in.label
	if len(strings.trim_space(label)) == 0 {
		label = "auto split state"
	}
	fmt.sbprintf(&b, `,"label":"%s"}`, process_json_escape(label))
	return strings.to_string(b)
}

split_state_from_entry :: proc(entry: Cache_Entry) -> (Split_State, bool) {
	raw := strings.trim_space(entry.value)
	if raw == "active" {
		return Split_State{active = true, label = "auto split state"}, true
	}
	if len(raw) == 0 || raw[0] != '{' do return {}, false

	parsed, err := json.parse(transmute([]u8)raw, allocator = runtime_alloc)
	if err != nil do return {}, false
	obj, ok := parsed.(json.Object)
	if !ok do return {}, false

	result := Split_State{}
	if active, active_ok := obj["active"].(json.Boolean); active_ok {
		result.active = bool(active)
	}
	if status, status_ok := obj["status"].(json.String); status_ok {
		if strings.to_lower(strings.trim_space(status), runtime_alloc) == "active" {
			result.active = true
		}
	}
	if topic_a, topic_a_ok := obj["topic_a"].(json.String); topic_a_ok {
		result.topic_a = strings.clone(topic_a, runtime_alloc)
	}
	if topic_b, topic_b_ok := obj["topic_b"].(json.String); topic_b_ok {
		result.topic_b = strings.clone(topic_b, runtime_alloc)
	}
	if label, label_ok := obj["label"].(json.String); label_ok {
		result.label = strings.clone(strings.trim_space(label), runtime_alloc)
	}
	if len(result.label) == 0 && result.active {
		result.label = "auto split state"
	}
	if result.active ||
	   len(result.topic_a) > 0 ||
	   len(result.topic_b) > 0 ||
	   len(result.label) > 0 {
		return result, true
	}
	return {}, false
}

cache_load_split_state :: proc() -> (Split_State, Cache_Entry, bool) {
	new_key := split_state_cache_key()
	if entry, found := state.topic_cache[new_key]; found {
		ss, ss_ok := split_state_from_entry(entry)
		if ss_ok do return ss, entry, true
		return {}, entry, false
	}

	legacy_key := legacy_split_state_cache_key()
	if entry, found := state.topic_cache[legacy_key]; found {
		migrated := entry
		normalized, normalized_ok := split_state_from_entry(entry)
		if normalized_ok {
			migrated.value = split_state_normalized_value(normalized)
		}
		state.topic_cache[strings.clone(new_key, runtime_alloc)] = Cache_Entry {
			value   = strings.clone(migrated.value, runtime_alloc),
			author  = strings.clone(migrated.author, runtime_alloc),
			expires = strings.clone(migrated.expires, runtime_alloc),
		}
		cache_save_key(new_key, migrated)
		cache_delete_key(legacy_key)
		if normalized_ok {
			return normalized, migrated, true
		}
	}
	return {}, {}, false
}

cache_label_from_structured_value :: proc(value: string) -> (string, bool) {
	raw := strings.trim_space(value)
	if len(raw) == 0 || raw[0] != '{' do return "", false
	parsed, err := json.parse(transmute([]u8)raw, allocator = runtime_alloc)
	if err != nil do return "", false
	obj, ok := parsed.(json.Object)
	if !ok do return "", false
	fields := [4]string{"label", "topic", "name", "title"}
	if cleaned, label_ok := json_first_non_empty_string(obj, fields[:], runtime_alloc); label_ok {
		return cleaned, true
	}
	return "", false
}

cache_safe_label :: proc(entry: Cache_Entry) -> string {
	if split_state, ok := split_state_from_entry(entry); ok {
		if len(split_state.label) > 0 do return split_state.label
		if split_state.active do return "auto split state"
	}
	if label, ok := cache_label_from_structured_value(entry.value); ok do return label
	if entry.author == "llm" do return "cached answer"
	return "cache entry"
}

cache_key_is_opaque :: proc(key: string) -> bool {
	return string_has_colon_suffix_of_hex(key, 24)
}

cache_display_key :: proc(key: string) -> string {
	if cache_key_is_opaque(key) do return key
	return opaque_cache_key("cache", key)
}

cache_display_id_fragment :: proc(key: string) -> string {
	opaque := cache_display_key(key)
	suffix, has_suffix := string_suffix_after_char(opaque, ":", runtime_alloc)
	if !has_suffix do return opaque
	start := len(opaque) - len(suffix)
	end := start + 8
	if end > len(opaque) do end = len(opaque)
	return strings.concatenate({opaque[:start], opaque[start:end]}, runtime_alloc)
}
