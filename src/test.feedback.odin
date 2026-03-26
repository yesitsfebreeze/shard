package shard

import "core:mem"
import "core:os"
import "core:testing"

ensure_feedback_state :: proc(force_reset: bool = false) {
	if force_reset || state == nil {
		runtime_arena = new(mem.Arena)
		mem.arena_init(runtime_arena, make([]byte, RUNTIME_ARENA_SIZE))
		runtime_alloc = mem.arena_allocator(runtime_arena)
		state = new(State, runtime_alloc)
		state.exe_path = "/tmp/shard-feedback-test-bin"
	}

	if force_reset || state == nil {
		state.topic_cache = make(map[string]Cache_Entry, runtime_alloc)
		state.context_sessions = make(map[string]Context_Session, runtime_alloc)
		state.cache_dir = ""
		state.exe_dir = ""
		state.working_copy = ""
		state.command = .None
		state.has_llm = false
		state.has_embed = false
		state.is_fork = false
		state.active_request_children = 0
		state.congestion_replay_cursor = 0
		state.congestion_replay_dirty = false
		state.has_key = false
		state.has_cache_key_fallback = false
		state.cache_key_fallback = Key{}
		state.blob = Blob{}
		state.blob.shard.processed = nil
		state.blob.shard.unprocessed = nil
		state.key = Key{}
		state.shard_id = ""
		state.needs_maintenance = false
	}
}

build_test_thought :: proc(
	key: Key,
	description: string,
	content: string,
) -> (id: Thought_ID, blob: []u8) {
	id = new_thought_id()
	body, seal, trust := thought_encrypt(key, id, description, content)
	t := Thought {
		id         = id,
		trust      = trust,
		seal_blob  = seal,
		body_blob  = body,
		agent      = "test",
		created_at = now_rfc3339(),
		updated_at = "",
		ttl        = 0,
	}
	buf: [dynamic]u8
	buf.allocator = runtime_alloc
	thought_serialize(&buf, &t)
	blob = buf[:]
	return
}

find_thought_counters :: proc(
	s: ^Shard_Data,
	target_id: Thought_ID,
) -> (read_count: u32, cite_count: u32, found: bool) {
	for blob in s.processed {
		pos := 0
		t, ok := thought_parse(blob, &pos)
		if !ok do continue
		if t.id == target_id {
			return t.read_count, t.cite_count, true
		}
	}

	for blob in s.unprocessed {
		pos := 0
		t, ok := thought_parse(blob, &pos)
		if !ok do continue
		if t.id == target_id {
			return t.read_count, t.cite_count, true
		}
	}

	return 0, 0, false
}

@(test)
test_read_count_does_not_leak_from_render :: proc(t: ^testing.T) {
	ensure_feedback_state(true)
	old_shard_id := state.shard_id
	old_has_key := state.has_key
	old_key := state.key
	defer {
		state.shard_id = old_shard_id
		state.has_key = old_has_key
		state.key = old_key
	}

	state.shard_id = "feedback-read"
	key, key_ok := hex_to_key("00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff")
	assert(key_ok)
	state.key = key
	state.has_key = true

	id, blob := build_test_thought(key, "read count test", "verify explicit and render reads")

	state.blob.has_data = true
	state.blob.shard = Shard_Data {
		catalog = Catalog {name = "feedback-read", purpose = "read usage"},
		unprocessed = [][]u8{blob},
	}
	assert(len(state.blob.shard.unprocessed) == 1)
	parse_pos := 0
	parsed, parse_ok := thought_parse(state.blob.shard.unprocessed[0], &parse_pos)
	assert(parse_ok)
	assert(parsed.id == id)
	_, _, parse_ok = thought_decrypt(key, &parsed)
	assert(parse_ok)
	manual_found := false
	for block in ([2][][]u8{state.blob.shard.processed, state.blob.shard.unprocessed}) {
		for blob_entry in block {
			pos := 0
			manual_parsed, parse_ok2 := thought_parse(blob_entry, &pos)
			if parse_ok2 && manual_parsed.id == id {
				manual_found = true
			}
		}
	}
	assert(manual_found)

	_, _, ok := read_thought_core(id, false)
	assert(ok)
	read_count, cite_count, found := find_thought_counters(&state.blob.shard, id)
	assert(found)
	assert(read_count == 0)
	assert(cite_count == 0)

	_, _, ok = read_thought_core(id, true)
	assert(ok)
	parse_pos = 0
	_, parse_ok = thought_parse(state.blob.shard.unprocessed[0], &parse_pos)
	// confirm parse still works after read path touched
	assert(parse_ok)
	read_count, cite_count, found = find_thought_counters(&state.blob.shard, id)
	assert(found)
	assert(read_count == 1)
	assert(cite_count == 0)
}

@(test)
test_cite_count_updates_during_context_packet :: proc(t: ^testing.T) {
	ensure_feedback_state(true)
	old_has_key := state.has_key
	old_key := state.key
	old_shard_id := state.shard_id
	defer {
		state.has_key = old_has_key
		state.key = old_key
		state.shard_id = old_shard_id
	}

	state.shard_id = "feedback-cite"
	key, key_ok := hex_to_key("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
	assert(key_ok)
	state.key = key
	state.has_key = true

	id_a, blob_a := build_test_thought(key, "Context packet sample", "This thought should be cited in packets.")
	id_b, blob_b := build_test_thought(key, "Unrelated", "Docker pinned image")
	_ = id_b
	_ = blob_b
	state.blob.has_data = true
	state.blob.shard = Shard_Data {
		catalog = Catalog {name = "feedback-cite", purpose = "cite usage"},
		processed = [][]u8{blob_a},
		unprocessed = [][]u8{blob_b},
	}

	packet := build_context_packet("context packet sample", "agent-alpha")
	assert(len(packet.included_thought_ids) > 0)
	assert(len(packet.included_shards) == 1)

	included_a := false
	for id_hex in packet.included_thought_ids {
		if id_hex == thought_id_to_hex(id_a) {
			included_a = true
		}
	}
	assert(included_a)

	_, _, found := find_thought_counters(&state.blob.shard, id_a)
	assert(found)
	read_count, cite_count, _ := find_thought_counters(&state.blob.shard, id_a)
	assert(cite_count >= 1)
	assert(read_count == 0)
}

@(test)
test_congestion_replay_applies_scd1_and_legacy :: proc(t: ^testing.T) {
	ensure_feedback_state(true)
	old_has_key := state.has_key
	old_key := state.key
	old_working_copy := state.working_copy
	defer {
		state.has_key = old_has_key
		state.key = old_key
		state.working_copy = old_working_copy
	}

	state.exe_path = "/tmp/shard-feedback-test-exe"
	key, key_ok := hex_to_key("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
	assert(key_ok)
	state.key = key
	state.has_key = true

	base_id, base_blob := build_test_thought(key, "base thought", "base for replay")
	read_update_id, read_update_blob := build_test_thought(key, "read count target", "updated through SCD1")
	state.blob.has_data = true
	state.blob.shard = Shard_Data {
		catalog = Catalog {name = "feedback-replay", purpose = "replay"},
		processed = [][]u8{base_blob},
		unprocessed = [][]u8{read_update_blob},
	}

	target_path := "/tmp/shard-feedback-replay.bin"
	state.working_copy = target_path
	state.blob.exe_code = nil
	if os.exists(target_path) do os.remove(target_path)
	state.is_fork = false
	assert(blob_write_self())

	legacy_id, legacy_blob := build_test_thought(key, "legacy thought", "added via legacy congestion")
	assert(congestion_append(legacy_blob))
	assert(congestion_append_scd1(SCD1_OP_READ, read_update_id, 3))

	state.congestion_replay_cursor = 0
	state.congestion_replay_dirty = false
	defer {
		os.remove(target_path)
	}
	congestion_replay(false)

	read_count, cite_count, found_update := find_thought_counters(&state.blob.shard, read_update_id)
	assert(found_update)
	assert(cite_count == 0)
	legacy_read, legacy_cite, legacy_found := find_thought_counters(&state.blob.shard, legacy_id)
	assert(legacy_found)
	assert(read_count == 3)
	_, base_hits, base_found := find_thought_counters(&state.blob.shard, base_id)
	assert(base_found)
	assert(base_hits == 0)
	assert(legacy_read == 0)
	assert(legacy_cite == 0)

	assert(!congestion_append_scd1(0x99, base_id, 7))
}
