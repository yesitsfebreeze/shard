package shard

import "core:crypto/hash"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

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
