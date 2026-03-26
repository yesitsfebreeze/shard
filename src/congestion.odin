package shard

import "core:bytes"
import "core:crypto/hash"
import "core:encoding/endian"
import "core:log"
import "core:os"

congestion_append_bytes :: proc(payload: []u8) -> bool {
	target := state.working_copy if len(state.working_copy) > 0 else state.exe_path
	fd, err := os.open(target, os.O_WRONLY | os.O_APPEND)
	if err != nil do return false
	defer os.close(fd)

	entry: [dynamic]u8
	entry.allocator = runtime_alloc
	append_u32(&entry, u32(len(payload)))
	for b in payload {
		append(&entry, b)
	}
	written, write_err := os.write(fd, entry[:])
	if write_err != nil || written != len(entry) {
		log.error("congestion_append: failed to write framed payload")
		return false
	}
	return true
}

congestion_append :: proc(thought_blob: []u8) -> bool {
	return congestion_append_bytes(thought_blob)
}

congestion_append_scd1 :: proc(opcode: u8, thought_id: Thought_ID, delta: u32) -> bool {
	if opcode != SCD1_OP_READ && opcode != SCD1_OP_CITE do return false
	payload := make([]u8, SCD1_FRAME_SIZE, runtime_alloc)
	magic_arr := SCD1_MAGIC
	for i := 0; i < 4; i += 1 {
		payload[i] = magic_arr[i]
	}
	payload[4] = opcode
	for i := 0; i < 16; i += 1 {
		payload[5 + i] = thought_id[i]
	}
	endian.put_u32(payload[21:], .Little, delta)
	return congestion_append_bytes(payload)
}

congestion_apply_scd1 :: proc(payload: []u8) -> bool {
	if len(payload) != SCD1_FRAME_SIZE do return false
	if payload[0] != SCD1_MAGIC[0] || payload[1] != SCD1_MAGIC[1] || payload[2] != SCD1_MAGIC[2] || payload[3] != SCD1_MAGIC[3] do return false
	thought_id: Thought_ID
	for i := 0; i < 16; i += 1 {
		thought_id[i] = payload[5 + i]
	}
	delta, delta_ok := endian.get_u32(payload[21:], .Little)
	if !delta_ok do return false

	if payload[4] == SCD1_OP_READ {
		if thought_counter_append_mutate(&state.blob.shard.processed, thought_id, .Read, delta) {
			return true
		}
		return thought_counter_append_mutate(
			&state.blob.shard.unprocessed,
			thought_id,
			.Read,
			delta,
		)
	}
	if payload[4] == SCD1_OP_CITE {
		if thought_counter_append_mutate(&state.blob.shard.processed, thought_id, .Cite, delta) {
			return true
		}
		return thought_counter_append_mutate(
			&state.blob.shard.unprocessed,
			thought_id,
			.Cite,
			delta,
		)
	}
	return false
}

congestion_apply_legacy :: proc(payload: []u8) {
	new_unprocessed: [dynamic][]u8
	new_unprocessed.allocator = runtime_alloc
	for entry in state.blob.shard.unprocessed do append(&new_unprocessed, entry)
	append(&new_unprocessed, payload)
	state.blob.shard.unprocessed = new_unprocessed[:]
}

congestion_replay :: proc(persist_if_idle: bool = true) {
	target := state.working_copy if len(state.working_copy) > 0 else state.exe_path
	raw, ok := os.read_entire_file(target, runtime_alloc)
	if !ok || len(raw) < SHARD_FOOTER_SIZE + SHARD_MAGIC_SIZE do return

	magic_end := -1
	for candidate := len(raw); candidate > SHARD_MAGIC_SIZE; candidate -= 1 {
		magic_pos := candidate - SHARD_MAGIC_SIZE
		val, val_ok := endian.get_u64(raw[magic_pos:], .Little)
		if !val_ok || val != SHARD_MAGIC do continue

		if candidate < SHARD_FOOTER_SIZE do continue
		data_size_pos := candidate - (SHARD_MAGIC_SIZE + SHARD_HASH_SIZE + 4)
		data_size, ds_ok := endian.get_u32(raw[data_size_pos:], .Little)
		if !ds_ok do continue

		data_start := candidate - SHARD_FOOTER_SIZE - int(data_size)
		data_end := data_start + int(data_size) + 4
		if data_start < 0 || data_end > candidate do continue

		hash_pos := candidate - SHARD_MAGIC_SIZE - SHARD_HASH_SIZE
		stored_hash := raw[hash_pos:hash_pos + SHARD_HASH_SIZE]
		computed_hash: [SHARD_HASH_SIZE]u8
		hash.hash_bytes_to_buffer(.SHA256, raw[data_start:data_end], computed_hash[:])
		if !bytes.equal(stored_hash, computed_hash[:]) do continue

		magic_end = candidate
		break
	}

	if magic_end <= SHARD_MAGIC_SIZE do return
	pending_start := magic_end
	if pending_start >= len(raw) do return

	pending := raw[pending_start:]
	if len(pending) == 0 do return

	if state.congestion_replay_cursor < 0 do state.congestion_replay_cursor = 0
	if state.congestion_replay_cursor > len(pending) do state.congestion_replay_cursor = 0

	if state.congestion_replay_cursor >= len(pending) {
		if persist_if_idle &&
		   !state.is_fork &&
		   state.active_request_children == 0 &&
		   state.congestion_replay_dirty {
			if blob_write_self() {
				state.congestion_replay_cursor = 0
				state.congestion_replay_dirty = false
			}
		}
		return
	}

	pos := state.congestion_replay_cursor
	legacy_count := 0
	scd1_count := 0
	unknown_count := 0
	for pos + 4 <= len(pending) {
		size, size_ok := endian.get_u32(pending[pos:pos + 4], .Little)
		if !size_ok do break
		pos += 4
		end := pos + int(size)
		if end > len(pending) {
			log.error("congestion_replay: truncated payload, stopping")
			break
		}
		payload := pending[pos:end]
		is_magic :=
			len(payload) >= 4 &&
			payload[0] == SCD1_MAGIC[0] &&
			payload[1] == SCD1_MAGIC[1] &&
			payload[2] == SCD1_MAGIC[2] &&
			payload[3] == SCD1_MAGIC[3]
		if is_magic && len(payload) == SCD1_FRAME_SIZE {
			if congestion_apply_scd1(payload) {
				scd1_count += 1
			} else {
				unknown_count += 1
				log.errorf("congestion_replay: malformed SCD1 frame opcode 0x%02x", payload[4])
			}
		} else if is_magic {
			unknown_count += 1
			log.errorf("congestion_replay: malformed SCD1 frame length %d", len(payload))
		} else {
			congestion_apply_legacy(payload)
			legacy_count += 1
		}
		pos = end
	}

	if pos > state.congestion_replay_cursor {
		state.congestion_replay_cursor = pos
	}
	if legacy_count > 0 || scd1_count > 0 || unknown_count > 0 {
		state.congestion_replay_dirty = true
		if !state.blob.has_data && legacy_count > 0 do state.blob.has_data = true
		log.infof(
			"Congestion replay: applied %d legacy, %d SCD1, %d unknown frames",
			legacy_count,
			scd1_count,
			unknown_count,
		)
	}

	if persist_if_idle &&
	   !state.is_fork &&
	   state.active_request_children == 0 &&
	   state.congestion_replay_dirty {
		if blob_write_self() {
			state.congestion_replay_cursor = 0
			state.congestion_replay_dirty = false
		}
	}
}
