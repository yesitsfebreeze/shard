package shard

import "core:testing"

// =============================================================================
// Crypto tests — key derivation, encrypt/decrypt, thought round-trip
// =============================================================================

@(test)
test_derive_key_deterministic :: proc(t: ^testing.T) {
	master: Master_Key
	master[0] = 0xAB
	id: Thought_ID
	id[0] = 0x01
	k1 := derive_key(master, id)
	k2 := derive_key(master, id)
	testing.expect(t, k1 == k2, "derive_key must be deterministic")
}

@(test)
test_derive_key_different_ids :: proc(t: ^testing.T) {
	master: Master_Key
	master[0] = 0xAB
	id1: Thought_ID
	id1[0] = 0x01
	id2: Thought_ID
	id2[0] = 0x02
	k1 := derive_key(master, id1)
	k2 := derive_key(master, id2)
	testing.expect(t, k1 != k2, "different IDs must produce different keys")
}

@(test)
test_thought_create_decrypt_round_trip :: proc(t: ^testing.T) {
	master: Master_Key
	master[0] = 0xDE; master[1] = 0xAD
	id := new_thought_id()
	pt := Thought_Plaintext{description = "test desc", content = "test body"}
	thought, ok := thought_create(master, id, pt)
	testing.expect(t, ok, "thought_create should succeed")

	decrypted, err := thought_decrypt(thought, master)
	testing.expect(t, err == .None, "thought_decrypt should succeed")
	testing.expect(t, decrypted.description == "test desc", "description must round-trip")
	testing.expect(t, decrypted.content == "test body", "content must round-trip")
}

@(test)
test_thought_wrong_key_fails :: proc(t: ^testing.T) {
	master: Master_Key
	master[0] = 0xDE
	wrong: Master_Key
	wrong[0] = 0xFF
	id := new_thought_id()
	pt := Thought_Plaintext{description = "secret", content = "data"}
	thought, _ := thought_create(master, id, pt)

	_, err := thought_decrypt(thought, wrong)
	testing.expect(t, err != .None, "decrypting with wrong key must fail")
}

@(test)
test_thought_serialize_bin_round_trip :: proc(t: ^testing.T) {
	master: Master_Key
	master[0] = 0x42
	id := new_thought_id()
	pt := Thought_Plaintext{description = "bin test", content = "bin body"}
	thought, _ := thought_create(master, id, pt)
	thought.agent = "test-agent"
	thought.created_at = "2026-03-16T00:00:00Z"
	thought.updated_at = "2026-03-16T00:00:00Z"

	// Set a revises link
	parent_id := new_thought_id()
	thought.revises = parent_id

	buf := make([dynamic]u8)
	defer delete(buf)
	thought_serialize_bin(&buf, thought)

	pos := 0
	parsed, err := thought_parse_bin(buf[:], &pos)
	testing.expect(t, err == .None, "parse_bin should succeed")
	testing.expect(t, parsed.id == thought.id, "id must round-trip")
	testing.expect(t, parsed.agent == "test-agent", "agent must round-trip")
	testing.expect(t, parsed.revises == parent_id, "revises must round-trip")
}
