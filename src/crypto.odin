package shard

import "core:bytes"
import "core:crypto"
import "core:crypto/chacha20poly1305"
import "core:crypto/hash"
import "core:crypto/hkdf"
import "core:encoding/hex"
import "core:strings"
import "core:testing"

// derive_key produces a per-thought encryption key from the master key and thought ID.
// key = HKDF-SHA256(ikm=master, salt=nil, info=thought_id, len=32)
derive_key :: proc(master: Master_Key, id: Thought_ID) -> [32]u8 {
	m := master; i := id
	key: [32]u8
	hkdf.extract_and_expand(.SHA256, nil, m[:], i[:], key[:])
	return key
}

// compute_trust binds a key to content. Detects body-replacement attacks.
// trust = SHA256(key || SHA256(plaintext))
compute_trust :: proc(key: [32]u8, plaintext: []u8) -> Trust_Token {
	content_hash: [32]u8
	hash.hash_bytes_to_buffer(.SHA256, plaintext, content_hash[:])
	k := key
	buf: [64]u8
	copy(buf[:32], k[:])
	copy(buf[32:], content_hash[:])
	result: [32]u8
	hash.hash_bytes_to_buffer(.SHA256, buf[:], result[:])
	return Trust_Token(result)
}

@(private)
_encrypt_blob :: proc(key: [32]u8, plaintext: []u8, allocator := context.allocator) -> []u8 {
	nonce: [chacha20poly1305.IV_SIZE]u8
	crypto.rand_bytes(nonce[:])
	ct := make([]u8, len(plaintext), allocator)
	tag: [chacha20poly1305.TAG_SIZE]u8
	k := key
	ctx: chacha20poly1305.Context
	chacha20poly1305.init(&ctx, k[:])
	defer chacha20poly1305.reset(&ctx)
	chacha20poly1305.seal(&ctx, ct, tag[:], nonce[:], nil, plaintext)
	blob := make([]u8, chacha20poly1305.IV_SIZE + len(ct) + chacha20poly1305.TAG_SIZE, allocator)
	copy(blob[:chacha20poly1305.IV_SIZE], nonce[:])
	copy(blob[chacha20poly1305.IV_SIZE:chacha20poly1305.IV_SIZE + len(ct)], ct)
	copy(blob[chacha20poly1305.IV_SIZE + len(ct):], tag[:])
	return blob
}

@(private)
_decrypt_blob :: proc(
	key: [32]u8,
	blob: []u8,
	allocator := context.allocator,
) -> (
	pt: []u8,
	ok: bool,
) {
	MIN :: chacha20poly1305.IV_SIZE + chacha20poly1305.TAG_SIZE
	if len(blob) < MIN do return nil, false
	nonce := blob[:chacha20poly1305.IV_SIZE]
	tag := blob[len(blob) - chacha20poly1305.TAG_SIZE:]
	ct := blob[chacha20poly1305.IV_SIZE:len(blob) - chacha20poly1305.TAG_SIZE]
	pt = make([]u8, len(ct), allocator)
	k := key
	ctx: chacha20poly1305.Context
	chacha20poly1305.init(&ctx, k[:])
	defer chacha20poly1305.reset(&ctx)
	if !chacha20poly1305.open(&ctx, pt, nonce, nil, ct, tag) {
		delete(pt, allocator)
		return nil, false
	}
	return pt, true
}

new_thought_id :: proc() -> (id: Thought_ID) {
	crypto.rand_bytes(id[:])
	return
}

thought_create :: proc(
	master: Master_Key,
	id: Thought_ID,
	pt: Thought_Plaintext,
	allocator := context.allocator,
) -> (
	n: Thought,
	ok: bool,
) {
	full := _join_plaintext(pt, context.temp_allocator)
	defer delete(full, context.temp_allocator)
	key := derive_key(master, id)
	desc_hash: [32]u8
	hash.hash_bytes_to_buffer(.SHA256, transmute([]u8)pt.description, desc_hash[:])
	seal := _encrypt_blob(key, desc_hash[:], allocator)
	body := _encrypt_blob(key, full, allocator)
	trust := compute_trust(key, full)
	return Thought{id = id, trust = trust, seal_blob = seal, body_blob = body}, true
}

thought_decrypt :: proc(
	n: Thought,
	master: Master_Key,
	allocator := context.allocator,
) -> (
	result: Thought_Plaintext,
	err: Thought_Error,
) {
	key := derive_key(master, n.id)
	full, ok := _decrypt_blob(key, n.body_blob, context.temp_allocator)
	if !ok do return {}, .Decrypt_Failed
	defer delete(full, context.temp_allocator)
	pt, split_ok := _split_plaintext(full, allocator)
	if !split_ok do return {}, .No_Separator
	if !thought_verify_seal(n, master, pt.description) {
		delete(pt.description, allocator)
		delete(pt.content, allocator)
		return {}, .Seal_Mismatch
	}
	return pt, .None
}

thought_verify_seal :: proc(
	n: Thought,
	master: Master_Key,
	description_candidate: string,
) -> bool {
	key := derive_key(master, n.id)
	expected: [32]u8
	hash.hash_bytes_to_buffer(.SHA256, transmute([]u8)description_candidate, expected[:])
	actual, ok := _decrypt_blob(key, n.seal_blob, context.temp_allocator)
	if !ok do return false
	defer delete(actual, context.temp_allocator)
	return bytes.equal(actual, expected[:])
}

// Packed binary layout per thought:
//   [id:          16 bytes raw]
//   [seal_len:    u32 LE][seal_blob: raw bytes]
//   [body_len:    u32 LE][body_blob: raw bytes]
//   [agent_len:   u8][agent: utf8 bytes]
//   [created_len: u8][created_at: utf8 bytes]
//   [updated_len: u8][updated_at: utf8 bytes]
//   [revises:     16 bytes raw]
//   [ttl:         u32 LE]        — staleness TTL in seconds (0 = immortal)
//   [read_count:  u32 LE]        — read counter (plaintext)
//   [cite_count:  u32 LE]        — citation counter (plaintext)
thought_serialize_bin :: proc(buf: ^[dynamic]u8, n: Thought) {
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

	_append_u32(buf, n.ttl)
	_append_u32(buf, n.read_count)
	_append_u32(buf, n.cite_count)
}

thought_parse_bin :: proc(
	data: []u8,
	pos: ^int,
	allocator := context.allocator,
) -> (
	n: Thought,
	err: Thought_Error,
) {
	p := pos^

	if p + 16 > len(data) do return {}, .Bad_Format
	copy(n.id[:], data[p:p + 16])
	p += 16

	if p + 4 > len(data) do return {}, .Bad_Format
	seal_len := int(_u32_le(data[p:]))
	p += 4
	if p + seal_len > len(data) do return {}, .Bad_Format
	n.seal_blob = make([]u8, seal_len, allocator)
	copy(n.seal_blob, data[p:p + seal_len])
	p += seal_len

	if p + 4 > len(data) do return {}, .Bad_Format
	body_len := int(_u32_le(data[p:]))
	p += 4
	if p + body_len > len(data) do return {}, .Bad_Format
	n.body_blob = make([]u8, body_len, allocator)
	copy(n.body_blob, data[p:p + body_len])
	p += body_len

	if p + 1 > len(data) do return {}, .Bad_Format
	agent_len := int(data[p]); p += 1
	if p + agent_len > len(data) do return {}, .Bad_Format
	if agent_len > 0 do n.agent = strings.clone(string(data[p:p + agent_len]), allocator)
	p += agent_len

	if p + 1 > len(data) do return {}, .Bad_Format
	created_len := int(data[p]); p += 1
	if p + created_len > len(data) do return {}, .Bad_Format
	if created_len > 0 do n.created_at = strings.clone(string(data[p:p + created_len]), allocator)
	p += created_len

	if p + 1 > len(data) do return {}, .Bad_Format
	updated_len := int(data[p]); p += 1
	if p + updated_len > len(data) do return {}, .Bad_Format
	if updated_len > 0 do n.updated_at = strings.clone(string(data[p:p + updated_len]), allocator)
	p += updated_len

	if p + 16 > len(data) do return {}, .Bad_Format
	copy(n.revises[:], data[p:p + 16])
	p += 16

	if p + 4 > len(data) do return {}, .Bad_Format
	n.ttl = _u32_le(data[p:])
	p += 4

	if p + 4 > len(data) do return {}, .Bad_Format
	n.read_count = _u32_le(data[p:])
	p += 4

	if p + 4 > len(data) do return {}, .Bad_Format
	n.cite_count = _u32_le(data[p:])
	p += 4

	pos^ = p
	return n, .None
}

thought_parse_bin_v5 :: proc(
	data: []u8,
	pos: ^int,
	allocator := context.allocator,
) -> (
	n: Thought,
	err: Thought_Error,
) {
	p := pos^

	// ID: 16 raw bytes
	if p + 16 > len(data) do return {}, .Bad_Format
	copy(n.id[:], data[p:p + 16]); p += 16

	// seal_blob: u32 len + raw bytes
	if p + 4 > len(data) do return {}, .Bad_Format
	seal_len := int(_u32_le(data[p:])); p += 4
	if p + seal_len > len(data) do return {}, .Bad_Format
	n.seal_blob = make([]u8, seal_len, allocator)
	copy(n.seal_blob, data[p:p + seal_len]); p += seal_len

	// body_blob: u32 len + raw bytes
	if p + 4 > len(data) do return {}, .Bad_Format
	body_len := int(_u32_le(data[p:])); p += 4
	if p + body_len > len(data) do return {}, .Bad_Format
	n.body_blob = make([]u8, body_len, allocator)
	copy(n.body_blob, data[p:p + body_len]); p += body_len

	// agent: u8 len + bytes
	if p + 1 > len(data) do return {}, .Bad_Format
	agent_len := int(data[p]); p += 1
	if p + agent_len > len(data) do return {}, .Bad_Format
	if agent_len > 0 do n.agent = strings.clone(string(data[p:p + agent_len]), allocator)
	p += agent_len

	// created_at: u8 len + bytes
	if p + 1 > len(data) do return {}, .Bad_Format
	created_len := int(data[p]); p += 1
	if p + created_len > len(data) do return {}, .Bad_Format
	if created_len > 0 do n.created_at = strings.clone(string(data[p:p + created_len]), allocator)
	p += created_len

	// updated_at: u8 len + bytes
	if p + 1 > len(data) do return {}, .Bad_Format
	updated_len := int(data[p]); p += 1
	if p + updated_len > len(data) do return {}, .Bad_Format
	if updated_len > 0 do n.updated_at = strings.clone(string(data[p:p + updated_len]), allocator)
	p += updated_len

	// revises: 16 raw bytes
	if p + 16 > len(data) do return {}, .Bad_Format
	copy(n.revises[:], data[p:p + 16]); p += 16

	// ttl: u32 LE
	if p + 4 > len(data) do return {}, .Bad_Format
	n.ttl = _u32_le(data[p:]); p += 4

	// V5 has no counters — default to 0
	n.read_count = 0
	n.cite_count = 0

	pos^ = p
	return n, .None
}

thought_parse_bin_v4 :: proc(
	data: []u8,
	pos: ^int,
	allocator := context.allocator,
) -> (
	n: Thought,
	err: Thought_Error,
) {
	p := pos^

	if p + 16 > len(data) do return {}, .Bad_Format
	copy(n.id[:], data[p:p + 16]); p += 16

	if p + 4 > len(data) do return {}, .Bad_Format
	seal_len := int(_u32_le(data[p:])); p += 4
	if p + seal_len > len(data) do return {}, .Bad_Format
	n.seal_blob = make([]u8, seal_len, allocator)
	copy(n.seal_blob, data[p:p + seal_len]); p += seal_len

	if p + 4 > len(data) do return {}, .Bad_Format
	body_len := int(_u32_le(data[p:])); p += 4
	if p + body_len > len(data) do return {}, .Bad_Format
	n.body_blob = make([]u8, body_len, allocator)
	copy(n.body_blob, data[p:p + body_len]); p += body_len

	if p + 1 > len(data) do return {}, .Bad_Format
	agent_len := int(data[p]); p += 1
	if p + agent_len > len(data) do return {}, .Bad_Format
	if agent_len > 0 do n.agent = strings.clone(string(data[p:p + agent_len]), allocator)
	p += agent_len

	if p + 1 > len(data) do return {}, .Bad_Format
	created_len := int(data[p]); p += 1
	if p + created_len > len(data) do return {}, .Bad_Format
	if created_len > 0 do n.created_at = strings.clone(string(data[p:p + created_len]), allocator)
	p += created_len

	if p + 1 > len(data) do return {}, .Bad_Format
	updated_len := int(data[p]); p += 1
	if p + updated_len > len(data) do return {}, .Bad_Format
	if updated_len > 0 do n.updated_at = strings.clone(string(data[p:p + updated_len]), allocator)
	p += updated_len

	if p + 16 > len(data) do return {}, .Bad_Format
	copy(n.revises[:], data[p:p + 16]); p += 16

	// V4 has no TTL — default to 0 (immortal)
	n.ttl = 0

	pos^ = p
	return n, .None
}

@(private)
_join_plaintext :: proc(pt: Thought_Plaintext, allocator := context.allocator) -> []u8 {
	b := strings.builder_make(allocator)
	strings.write_string(&b, pt.description)
	strings.write_string(&b, "\n---\n")
	strings.write_string(&b, pt.content)
	return transmute([]u8)strings.to_string(b)
}

@(private)
_split_plaintext :: proc(
	data: []u8,
	allocator := context.allocator,
) -> (
	pt: Thought_Plaintext,
	ok: bool,
) {
	s := string(data)
	idx := strings.index(s, "\n---\n")
	if idx == -1 do return {}, false
	return Thought_Plaintext {
			description = strings.clone(s[:idx], allocator),
			content = strings.clone(s[idx + 5:], allocator),
		},
		true
}

id_to_hex :: proc(id: Thought_ID, allocator := context.allocator) -> string {
	id_copy := id
	return string(hex.encode(id_copy[:], allocator))
}

hex_to_id :: proc(s: string) -> (id: Thought_ID, ok: bool) {
	if len(s) != 32 do return {}, false
	s_copy := s
	b, decoded := hex.decode(transmute([]u8)s_copy, context.temp_allocator)
	defer delete(b, context.temp_allocator)
	if !decoded || len(b) != 16 do return {}, false
	copy(id[:], b)
	return id, true
}

hex_to_key :: proc(s: string) -> (key: Master_Key, ok: bool) {
	if len(s) != 64 do return {}, false
	b, decoded := hex.decode(transmute([]u8)s, context.temp_allocator)
	defer delete(b, context.temp_allocator)
	if !decoded || len(b) != 32 do return {}, false
	copy(key[:], b)
	return key, true
}

// =============================================================================
// Crypto tests
// =============================================================================

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

