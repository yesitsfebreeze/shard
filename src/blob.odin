package shard

import "core:bytes"
import "core:crypto/hash"
import "core:encoding/endian"
import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:os"
import "core:os/os2"
import "core:path/filepath"
import "core:strings"
import "core:time"


blob_read_self :: proc() {
	raw, ok := os.read_entire_file(state.exe_path, runtime_alloc)
	if !ok {
		log.errorf("Failed to read own binary at: %s", state.exe_path)
		shutdown(1)
	}

	if len(raw) < SHARD_FOOTER_SIZE {
		state.blob = Blob {
			exe_code = raw,
		}
		return
	}

	magic, magic_ok := endian.get_u64(raw[len(raw) - SHARD_MAGIC_SIZE:], .Little)
	if !magic_ok || magic != SHARD_MAGIC {
		state.blob = Blob {
			exe_code = raw,
		}
		return
	}

	data_size, ds_ok := block_read_u32(raw, len(raw) - SHARD_FOOTER_SIZE)
	if !ds_ok {
		state.blob = Blob {
			exe_code = raw,
		}
		return
	}

	total_appended := int(data_size) + SHARD_FOOTER_SIZE
	if total_appended > len(raw) {
		state.blob = Blob {
			exe_code = raw,
		}
		return
	}

	split := len(raw) - total_appended

	hash_start := split
	hash_end := len(raw) - SHARD_HASH_SIZE - SHARD_MAGIC_SIZE
	stored_hash := raw[hash_end:hash_end + SHARD_HASH_SIZE]
	computed_hash: [32]u8
	hash.hash_bytes_to_buffer(.SHA256, raw[hash_start:hash_end], computed_hash[:])
	if !bytes.equal(stored_hash, computed_hash[:]) {
		log.error("Shard data hash mismatch — data may be corrupted")
		state.blob = Blob {
			exe_code = raw[:split],
		}
		return
	}

	data := raw[split:split + int(data_size)]
	shard := shard_data_parse(data)

	state.blob = Blob {
		exe_code = raw[:split],
		shard    = shard,
		has_data = true,
	}
	vec_load_from_manifest(&state.blob.shard)
	log.infof(
		"Loaded shard data: %d bytes, processed=%d unprocessed=%d",
		data_size,
		len(shard.processed),
		len(shard.unprocessed),
	)
}

shard_data_parse :: proc(data: []u8) -> Shard_Data {
	sd: Shard_Data
	ok: bool
	pos := 0

	sd.processed, pos, ok = block_read_thoughts(data, pos)
	if !ok do return sd
	sd.unprocessed, pos, ok = block_read_thoughts(data, pos)
	if !ok do return sd

	catalog_bytes: []u8
	catalog_bytes, pos, ok = block_read_bytes(data, pos)
	if !ok do return sd
	sd.catalog = catalog_parse(catalog_bytes)

	manifest_bytes: []u8
	manifest_bytes, pos, ok = block_read_bytes(data, pos)
	if !ok do return sd
	sd.manifest = string(manifest_bytes)

	gates_bytes: []u8
	gates_bytes, pos, ok = block_read_bytes(data, pos)
	if !ok do return sd
	sd.gates = gates_parse(gates_bytes)

	return sd
}

blob_serialize :: proc(exe_code: []u8, s: ^Shard_Data) -> []u8 {
	catalog_json := catalog_serialize(&s.catalog)
	gates_text := gates_serialize(&s.gates)

	data_size :=
		thoughts_size(s.processed) +
		thoughts_size(s.unprocessed) +
		4 +
		len(catalog_json) +
		4 +
		len(s.manifest) +
		4 +
		len(gates_text)

	total := len(exe_code) + data_size + SHARD_FOOTER_SIZE
	buf := make([]u8, total, runtime_alloc)

	pos := 0
	copy(buf, exe_code)
	pos += len(exe_code)

	pos = block_write_thoughts(buf, pos, s.processed)
	pos = block_write_thoughts(buf, pos, s.unprocessed)
	pos = block_write_bytes(buf, pos, transmute([]u8)catalog_json)
	pos = block_write_bytes(buf, pos, transmute([]u8)s.manifest)
	pos = block_write_bytes(buf, pos, transmute([]u8)gates_text)

	pos = block_write_u32(buf, pos, u32(data_size))

	data_start := len(exe_code)
	data_end := pos
	blob_hash: [32]u8
	hash.hash_bytes_to_buffer(.SHA256, buf[data_start:data_end], blob_hash[:])
	copy(buf[pos:pos + SHARD_HASH_SIZE], blob_hash[:])
	pos += SHARD_HASH_SIZE

	endian.put_u64(buf[pos:], .Little, SHARD_MAGIC)
	return buf
}

blob_writing: bool

u32_saturating_add :: proc(a: u32, b: u32) -> u32 {
	max := u32(0xffffffff)
	if a > max - b {
		return max
	}
	return a + b
}

thought_counter_apply :: proc(t: ^Thought, op: Thought_Counter_Op, delta: u32) {
	switch op {
	case .Read:
		t.read_count = u32_saturating_add(t.read_count, delta)
	case .Cite:
		t.cite_count = u32_saturating_add(t.cite_count, delta)
	}
}

thought_counter_append_mutate :: proc(
	block: ^[][]u8,
	target_id: Thought_ID,
	op: Thought_Counter_Op,
	delta: u32,
) -> bool {
	for i := 0; i < len(block^); i += 1 {
		blob := block^[i]
		pos := 0
		t, parse_ok := thought_parse(blob, &pos)
		if !parse_ok do continue
		if t.id != target_id do continue

		thought_counter_apply(&t, op, delta)
		updated: [dynamic]u8
		updated.allocator = runtime_alloc
		thought_serialize(&updated, &t)
		block^[i] = updated[:]
		return true
	}
	return false
}

thought_counter_touch :: proc(thought_id: Thought_ID, op: Thought_Counter_Op, delta: u32) -> bool {
	if !state.has_key {
		log.error("Cannot update thought counters: no encryption key (set SHARD_KEY)")
		return false
	}

	updated := thought_counter_append_mutate(&state.blob.shard.processed, thought_id, op, delta)
	if !updated {
		updated = thought_counter_append_mutate(
			&state.blob.shard.unprocessed,
			thought_id,
			op,
			delta,
		)
	}
	if !updated {
		log.errorf("Counter update for unknown thought id %s", thought_id_to_hex(thought_id))
		return false
	}

	if state.is_fork {
		opcode := SCD1_OP_READ
		switch op {
		case .Cite:
			opcode = SCD1_OP_CITE
		case .Read:
			opcode = SCD1_OP_READ
		}
		if !congestion_append_scd1(opcode, thought_id, delta) {
			log.errorf(
				"Failed to append counter update for thought %s",
				thought_id_to_hex(thought_id),
			)
			return false
		}
	}

	return true
}

read_count_touch :: proc(thought_id: Thought_ID, delta: u32) -> bool {
	return thought_counter_touch(thought_id, .Read, delta)
}

cite_count_touch :: proc(thought_id: Thought_ID, delta: u32) -> bool {
	return thought_counter_touch(thought_id, .Cite, delta)
}

blob_write_self :: proc() -> bool {
	if state.is_fork {
		log.error("blob_write_self called from forked child, refusing (use congestion_append)")
		return false
	}
	if !blob_writing {
		blob_writing = true
		congestion_replay(false)
		blob_writing = false
	}
	target := state.working_copy if len(state.working_copy) > 0 else state.exe_path

	vec_save_to_manifest(&state.blob.shard)
	buf := blob_serialize(state.blob.exe_code, &state.blob.shard)

	tmp_path := strings.concatenate({target, ".tmp"}, runtime_alloc)
	if !os.write_entire_file(tmp_path, buf) do return false
	if os.rename(tmp_path, target) != nil do return false
	os2.chmod(
		target,
		{
			.Read_User,
			.Write_User,
			.Execute_User,
			.Read_Group,
			.Execute_Group,
			.Read_Other,
			.Execute_Other,
		},
	)

	log.infof("Wrote shard data to %s (%d bytes)", target, len(buf))
	return true
}

catalog_serialize :: proc(c: ^Catalog) -> string {
	data, err := json.marshal(c^, allocator = runtime_alloc)
	if err != nil do return "{}"
	return string(data)
}

catalog_parse :: proc(data: []u8) -> Catalog {
	c: Catalog
	json.unmarshal(data, &c, allocator = runtime_alloc)
	return c
}

each_thought :: proc(
	s: ^Shard_Data,
	key: Key,
	cb: proc(t: ^Thought, desc: string, content: string, ud: rawptr) -> bool,
	user_data: rawptr = nil,
) {
	for block in ([2][][]u8{s.processed, s.unprocessed}) {
		for blob in block {
			pos := 0
			t, ok := thought_parse(blob, &pos)
			if !ok do continue
			desc, content, decrypt_ok := thought_decrypt(key, &t)
			if !decrypt_ok do continue
			if !cb(&t, desc, content, user_data) do return
		}
	}
}

maybe_maintenance :: proc() {
	if !state.needs_maintenance do return
	if state.is_fork do return
	state.needs_maintenance = false

	s := &state.blob.shard
	if len(s.unprocessed) > 0 {
		compact()
	}

	maybe_archive()

	threshold := state.max_thoughts
	if threshold <= 0 do threshold = 500
	total := len(s.processed) + len(s.unprocessed)
	if total < threshold do return

	peers := index_list()
	if len(peers) == 0 && !state.has_llm {
		log.info("Maintenance: over threshold but no LLM for topic inference, skipping split")
		return
	}

	log.infof("Maintenance: %d thoughts exceeds threshold %d, evaluating split", total, threshold)
	split_state, _, has_split := cache_load_split_state()
	if has_split && split_state.active {
		log.info("Maintenance: split already active, routing will handle distribution")
		return
	}

	cache_load()
	dummy_desc := "maintenance auto-split evaluation"
	dummy_content := ""
	route_to_peer(dummy_desc, dummy_content, "maintenance")
}

maybe_archive :: proc() {
	ttl_days := state.config.ttl_days
	if ttl_days <= 0 do ttl_days = 365

	created := state.blob.shard.catalog.created
	if len(created) == 0 do return

	created_year, created_mon, created_day := parse_rfc3339_date(created)
	if created_year == 0 do return

	now := time.now()
	now_y, now_mon, now_d := time.date(now)
	elapsed_days :=
		(now_y - created_year) * 365 + (int(now_mon) - created_mon) * 30 + (now_d - created_day)
	if elapsed_days < ttl_days do return

	archive_base := state.config.archive_dir
	if len(archive_base) == 0 {
		archive_base = filepath.join({state.run_dir, "archive"}, runtime_alloc)
	}

	now_h, _, _ := time.clock(now)
	archive_path := filepath.join(
		{
			archive_base,
			fmt.aprintf("%04d", now_y, allocator = runtime_alloc),
			fmt.aprintf("%02d", int(now_mon), allocator = runtime_alloc),
			fmt.aprintf("%02d", now_d, allocator = runtime_alloc),
			fmt.aprintf("%02d", now_h, allocator = runtime_alloc),
		},
		runtime_alloc,
	)
	ensure_dir(archive_path)

	target := state.working_copy if len(state.working_copy) > 0 else state.exe_path
	archive_file := filepath.join({archive_path, state.shard_id}, runtime_alloc)

	src_data, read_ok := os.read_entire_file(target, runtime_alloc)
	if !read_ok {
		log.error("Archive: failed to read shard binary for archival")
		return
	}
	if !os.write_entire_file(archive_file, src_data) {
		log.error("Archive: failed to write archive copy, aborting (no data lost)")
		return
	}

	verify_data, verify_ok := os.read_entire_file(archive_file, runtime_alloc)
	if !verify_ok || len(verify_data) != len(src_data) {
		log.error("Archive: verification failed, archive may be incomplete, aborting clear")
		return
	}

	s := &state.blob.shard
	s.processed = nil
	s.unprocessed = nil
	s.catalog.created = now_rfc3339()
	if blob_write_self() {
		log.infof("Archive: shard archived to %s, active shard cleared", archive_file)
		emit_event(
			.Compact,
			fmt.aprintf("archived to %s", archive_file, allocator = runtime_alloc),
		)
	} else {
		log.error("Archive: failed to clear shard after archival")
	}
}


compact :: proc() -> bool {
	if state.is_fork {
		log.info("Compact skipped in forked child (deferred to parent)")
		return true
	}
	congestion_replay()
	s := &state.blob.shard
	if len(s.unprocessed) == 0 {
		log.info("Nothing to compact")
		return true
	}

	merged := make([dynamic][]u8, len(s.processed), runtime_alloc)
	for entry in s.processed do append(&merged, entry)
	for entry in s.unprocessed do append(&merged, entry)

	s.processed = merged[:]
	s.unprocessed = nil

	if !blob_write_self() {
		log.error("Failed to persist compaction")
		return false
	}

	log.infof("Compacted: %d thoughts now processed", len(s.processed))
	emit_event(.Compact, fmt.aprintf("%d", len(s.processed), allocator = runtime_alloc))
	return true
}

shard_init :: proc() -> bool {
	args := os.args[1:]
	init_path := ""
	found_init := false
	for arg in args {
		if found_init {
			init_path = arg
			break
		}
		if arg == "--init" do found_init = true
	}

	if len(init_path) == 0 {
		log.error("--init requires a descriptor JSON file path")
		return false
	}

	raw, ok := os.read_entire_file(init_path, runtime_alloc)
	if !ok {
		log.errorf("Failed to read descriptor: %s", init_path)
		return false
	}

	cleaned := strip_jsonc_comments(string(raw))
	desc: Init_Descriptor
	if json.unmarshal(transmute([]u8)cleaned, &desc, allocator = runtime_alloc) != nil {
		log.errorf("Failed to parse descriptor JSON: %s", init_path)
		return false
	}

	s := &state.blob.shard
	if len(desc.name) > 0 do s.catalog.name = desc.name
	if len(desc.purpose) > 0 do s.catalog.purpose = desc.purpose
	if len(desc.tags) > 0 do s.catalog.tags = desc.tags

	g := &s.gates
	if len(desc.gate) > 0 do g.gate = desc.gate
	if len(desc.intake_prompt) > 0 do g.intake_prompt = desc.intake_prompt
	if len(desc.links) > 0 do g.shard_links = desc.links

	if len(desc.descriptors) > 0 {
		descs := make([]Descriptor, len(desc.descriptors), runtime_alloc)
		for d, i in desc.descriptors {
			descs[i] = Descriptor {
				format     = d.format,
				match_rule = d.match_rule,
				structure  = d.structure,
				links      = d.links,
			}
		}
		g.descriptors = descs
	}

	gates_embed(g)

	if !state.blob.has_data do state.blob.has_data = true
	state.shard_id = resolve_shard_id()

	if !blob_write_self() {
		log.error("Failed to persist descriptor")
		return false
	}

	index_write(state.shard_id, state.exe_path)
	log.infof("Initialized shard '%s' from %s", desc.name, init_path)
	return true
}
