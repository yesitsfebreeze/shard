package shard_unit_test

import "core:bytes"
import "core:strings"
import "core:testing"
import shard "shard:."

// Confirms thought_create produces a valid encrypted thought.
@(test)
test_thought_create_basic :: proc(t: ^testing.T) {
	defer drain_logger()
	master: shard.Master_Key // zero key for test
	id := shard.new_thought_id()
	pt := shard.Thought_Plaintext {
		description = "test thought",
		content     = "this is the content body",
	}
	thought, ok := shard.thought_create(master, id, pt)
	testing.expect(t, ok, "thought_create should succeed")
	testing.expect(t, thought.id == id, "thought id should match")
	testing.expect(t, len(thought.seal_blob) > 0, "seal_blob should be non-empty")
	testing.expect(t, len(thought.body_blob) > 0, "body_blob should be non-empty")
}

// Confirms thought_decrypt roundtrip recovers the original plaintext.
@(test)
test_thought_decrypt_roundtrip :: proc(t: ^testing.T) {
	defer drain_logger()
	master: shard.Master_Key
	id := shard.new_thought_id()
	orig := shard.Thought_Plaintext {
		description = "decrypt test",
		content     = "secret message content here",
	}
	thought, ok := shard.thought_create(master, id, orig)
	testing.expect(t, ok, "thought_create should succeed")

	decrypted, err := shard.thought_decrypt(thought, master)
	defer {
		delete(decrypted.description)
		delete(decrypted.content)
	}
	testing.expect(t, err == .None, "thought_decrypt should succeed")
	testing.expect(t, decrypted.description == orig.description, "description should match")
	testing.expect(t, decrypted.content == orig.content, "content should match")
}

// Confirms thought_decrypt fails with wrong key.
@(test)
test_thought_decrypt_wrong_key :: proc(t: ^testing.T) {
	defer drain_logger()
	master: shard.Master_Key
	wrong_master: shard.Master_Key
	wrong_master[0] = 0xFF // any non-zero key

	id := shard.new_thought_id()
	pt := shard.Thought_Plaintext {
		description = "locked content",
		content     = "should not decrypt",
	}
	thought, ok := shard.thought_create(master, id, pt)
	testing.expect(t, ok, "thought_create should succeed")

	_, err := shard.thought_decrypt(thought, wrong_master)
	testing.expect(t, err != .None, "decrypt should fail with wrong key")
}

// Confirms thought_verify_seal detects tampered descriptions.
@(test)
test_thought_verify_seal :: proc(t: ^testing.T) {
	defer drain_logger()
	master: shard.Master_Key
	id := shard.new_thought_id()
	pt := shard.Thought_Plaintext {
		description = "original description",
		content     = "content",
	}
	thought, ok := shard.thought_create(master, id, pt)
	testing.expect(t, ok, "thought_create should succeed")

	// Valid seal should pass
	valid := shard.thought_verify_seal(thought, master, pt.description)
	testing.expect(t, valid, "seal should verify for correct description")

	// Tampered description should fail
	tampered := shard.thought_verify_seal(thought, master, "modified description")
	testing.expect(t, !tampered, "seal should fail for modified description")
}

// Confirms compute_trust produces consistent results.
@(test)
test_compute_trust :: proc(t: ^testing.T) {
	defer drain_logger()
	key: [32]u8
	msg := "test content for trust"
	plaintext := transmute([]u8)msg

	trust1 := shard.compute_trust(key, plaintext)
	trust2 := shard.compute_trust(key, plaintext)
	testing.expect(t, trust1 == trust2, "trust should be deterministic")

	diff := "different"
	different := shard.compute_trust(key, transmute([]u8)diff)
	testing.expect(t, trust1 != different, "different content should produce different trust")
}

// Confirms derive_key produces consistent per-thought keys.
@(test)
test_derive_key :: proc(t: ^testing.T) {
	defer drain_logger()
	master: shard.Master_Key
	id1 := shard.new_thought_id()
	id2 := shard.new_thought_id()

	key1a := shard.derive_key(master, id1)
	key1b := shard.derive_key(master, id1)
	testing.expect(t, key1a == key1b, "same id should produce same key")

	key2 := shard.derive_key(master, id2)
	testing.expect(t, key1a != key2, "different ids should produce different keys")
}

// Confirms id_to_hex and hex_to_id roundtrip correctly.
@(test)
test_id_hex_roundtrip :: proc(t: ^testing.T) {
	defer drain_logger()
	original := shard.new_thought_id()
	hex_str := shard.id_to_hex(original)
	testing.expect(t, len(hex_str) == 32, "hex string should be 32 chars")

	recovered, ok := shard.hex_to_id(hex_str)
	testing.expect(t, ok, "hex_to_id should succeed for valid hex")
	testing.expect(t, recovered == original, "recovered id should match original")
}

// Confirms hex_to_id rejects invalid input.
@(test)
test_hex_to_id_invalid :: proc(t: ^testing.T) {
	defer drain_logger()
	// Too short
	_, ok := shard.hex_to_id("abc")
	testing.expect(t, !ok, "hex_to_id should reject short input")

	// Not hex
	_, ok = shard.hex_to_id("zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz")
	testing.expect(t, !ok, "hex_to_id should reject non-hex characters")

	// Empty
	_, ok = shard.hex_to_id("")
	testing.expect(t, !ok, "hex_to_id should reject empty string")
}

// Confirms hex_to_key validates and converts correctly.
@(test)
test_hex_to_key :: proc(t: ^testing.T) {
	defer drain_logger()
	// Create a valid 64-char hex string representing 32 bytes
	valid_hex := "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
	key, ok := shard.hex_to_key(valid_hex)
	testing.expect(t, ok, "hex_to_key should accept valid 64-char hex")

	// Check first few bytes match
	testing.expect(t, key[0] == 0x00, "first byte should match")
	testing.expect(t, key[1] == 0x01, "second byte should match")
	testing.expect(t, key[31] == 0x1f, "last byte should match")

	// Invalid lengths should fail
	_, ok = shard.hex_to_key("short")
	testing.expect(t, !ok, "hex_to_key should reject short input")

	_, ok = shard.hex_to_key("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e") // 60 chars
	testing.expect(t, !ok, "hex_to_key should reject 60-char input")
}

// Confirms thought_serialize_bin and thought_parse_bin roundtrip correctly.
@(test)
test_thought_serialize_parse :: proc(t: ^testing.T) {
	defer drain_logger()
	master: shard.Master_Key
	id := shard.new_thought_id()
	pt := shard.Thought_Plaintext {
		description = "serialize test",
		content     = "binary serialization body",
	}
	orig, ok := shard.thought_create(master, id, pt)
	testing.expect(t, ok, "thought_create should succeed")

	// Serialize
	buf := make([dynamic]u8)
	shard.thought_serialize_bin(&buf, orig)

	// Verify some basic structure
	testing.expect(t, len(buf) > 100, "serialized blob should be non-trivial")

	// Parse back
	pos := 0
	parsed, err := shard.thought_parse_bin(buf[:], &pos)
	testing.expect(t, err == .None, "thought_parse_bin should succeed")
	testing.expect(t, parsed.id == orig.id, "parsed id should match")

	// Decrypt to verify content
	decrypted, dec_err := shard.thought_decrypt(parsed, master)
	testing.expect(t, dec_err == .None, "decrypted thought should be valid")
	testing.expect(t, decrypted.description == pt.description, "description should match")
	testing.expect(t, decrypted.content == pt.content, "content should match")
}

// Confirms thought_serialize_bin truncates long agent strings to 255 bytes.
@(test)
test_thought_serialize_agent_truncation :: proc(t: ^testing.T) {
	defer drain_logger()
	master: shard.Master_Key
	id := shard.new_thought_id()
	pt := shard.Thought_Plaintext {
		description = "agent truncation test",
		content     = "body",
	}
	thought, ok := shard.thought_create(master, id, pt)
	testing.expect(t, ok, "thought_create should succeed")

	// Set a very long agent
	long_agent := strings.repeat("a", 301)
	thought.agent = long_agent

	// Serialize - agent should be truncated to 255 bytes
	buf := make([dynamic]u8)
	shard.thought_serialize_bin(&buf, thought)

	pos := 0
	parsed, err := shard.thought_parse_bin(buf[:], &pos)
	testing.expect(t, err == .None, "parse should succeed despite truncation")

	// Agent should be 255 chars (stored as bytes)
	testing.expect(t, len(parsed.agent) == 255, "agent should be truncated to 255 chars")
}
