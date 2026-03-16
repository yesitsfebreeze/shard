package shard

import "core:crypto/hash"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

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
