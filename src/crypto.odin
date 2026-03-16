package shard

import "core:bytes"
import "core:crypto"
import "core:crypto/chacha20poly1305"
import "core:crypto/hash"
import "core:crypto/hkdf"
import "core:encoding/base64"
import "core:encoding/hex"
import "core:strings"

// =============================================================================
// Key derivation
// =============================================================================

// derive_key produces a per-thought encryption key from the master key and thought ID.
// key = HKDF-SHA256(ikm=master, salt=nil, info=thought_id, len=32)
derive_key :: proc(master: Master_Key, id: Thought_ID) -> [32]u8 {
	m := master; i := id
	key: [32]u8
	hkdf.extract_and_expand(.SHA256, nil, m[:], i[:], key[:])
	return key
}


// =============================================================================
// Trust tokens
// =============================================================================

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

// =============================================================================
// ChaCha20-Poly1305 encrypt / decrypt
// =============================================================================

@(private)
_encrypt_blob :: proc(key: [32]u8, plaintext: []u8, allocator := context.allocator) -> []u8 {
	nonce: [chacha20poly1305.IV_SIZE]u8
	crypto.rand_bytes(nonce[:])
	ct  := make([]u8, len(plaintext), allocator)
	tag : [chacha20poly1305.TAG_SIZE]u8
	k   := key
	ctx : chacha20poly1305.Context
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
_decrypt_blob :: proc(key: [32]u8, blob: []u8, allocator := context.allocator) -> (pt: []u8, ok: bool) {
	MIN :: chacha20poly1305.IV_SIZE + chacha20poly1305.TAG_SIZE
	if len(blob) < MIN do return nil, false
	nonce := blob[:chacha20poly1305.IV_SIZE]
	tag   := blob[len(blob) - chacha20poly1305.TAG_SIZE:]
	ct    := blob[chacha20poly1305.IV_SIZE : len(blob) - chacha20poly1305.TAG_SIZE]
	pt     = make([]u8, len(ct), allocator)
	k     := key
	ctx   : chacha20poly1305.Context
	chacha20poly1305.init(&ctx, k[:])
	defer chacha20poly1305.reset(&ctx)
	if !chacha20poly1305.open(&ctx, pt, nonce, nil, ct, tag) {
		delete(pt, allocator)
		return nil, false
	}
	return pt, true
}

// =============================================================================
// Thought creation / decryption
// =============================================================================

new_thought_id :: proc() -> (id: Thought_ID) {
	crypto.rand_bytes(id[:])
	return
}

thought_create :: proc(
	master:    Master_Key,
	id:        Thought_ID,
	pt:        Thought_Plaintext,
	allocator  := context.allocator,
) -> (n: Thought, ok: bool) {
	full := _join_plaintext(pt, context.temp_allocator)
	defer delete(full, context.temp_allocator)
	key := derive_key(master, id)
	desc_hash: [32]u8
	hash.hash_bytes_to_buffer(.SHA256, transmute([]u8)pt.description, desc_hash[:])
	seal  := _encrypt_blob(key, desc_hash[:], allocator)
	body  := _encrypt_blob(key, full, allocator)
	trust := compute_trust(key, full)
	return Thought{id = id, trust = trust, seal_blob = seal, body_blob = body}, true
}

thought_decrypt :: proc(
	n:        Thought,
	master:   Master_Key,
	allocator := context.allocator,
) -> (result: Thought_Plaintext, err: Thought_Error) {
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

thought_verify_seal :: proc(n: Thought, master: Master_Key, description_candidate: string) -> bool {
	key := derive_key(master, n.id)
	expected: [32]u8
	hash.hash_bytes_to_buffer(.SHA256, transmute([]u8)description_candidate, expected[:])
	actual, ok := _decrypt_blob(key, n.seal_blob, context.temp_allocator)
	if !ok do return false
	defer delete(actual, context.temp_allocator)
	return bytes.equal(actual, expected[:])
}

// =============================================================================
// Thought parsing — legacy text format (SHRD0002, read-only)
// =============================================================================

thought_parse :: proc(data: string, allocator := context.allocator) -> (n: Thought, err: Thought_Error) {
	lines := strings.split(data, "\n", context.temp_allocator)
	defer delete(lines, context.temp_allocator)
	if len(lines) < 4 do return {}, .Bad_Format
	id_line   := lines[0]
	seal_line := lines[1]
	if len(id_line) != 32 do return {}, .Bad_Format

	// Find the "---" separator
	sep_idx := -1
	for i in 2 ..< len(lines) {
		if lines[i] == "---" { sep_idx = i; break }
	}
	if sep_idx == -1 do return {}, .Bad_Format

	// Parse metadata lines between seal and separator
	for i in 2 ..< sep_idx {
		line := lines[i]
		if colon := strings.index(line, ":"); colon >= 0 {
			key := line[:colon]
			val := line[colon + 1:]
			switch key {
			case "agent":      n.agent      = strings.clone(val, allocator)
			case "created_at": n.created_at = strings.clone(val, allocator)
			case "updated_at": n.updated_at = strings.clone(val, allocator)
			}
		}
	}

	body_line := strings.join(lines[sep_idx + 1:], "\n", context.temp_allocator)
	defer delete(body_line, context.temp_allocator)

	id_bytes, id_ok := hex.decode(transmute([]u8)id_line, allocator)
	if !id_ok || len(id_bytes) != 16 { delete(id_bytes, allocator); return {}, .Bad_Encoding }
	defer delete(id_bytes, allocator)
	copy(n.id[:], id_bytes)
	seal_bytes, seal_err := base64.decode(seal_line, allocator = allocator)
	if seal_err != nil do return {}, .Bad_Encoding
	n.seal_blob = seal_bytes
	body_bytes, body_err := base64.decode(body_line, allocator = allocator)
	if body_err != nil { delete(seal_bytes, allocator); return {}, .Bad_Encoding }
	n.body_blob = body_bytes
	return n, .None
}

// =============================================================================
// Thought serialization — BINARY format (SHRD0003)
// =============================================================================
//
// Packed binary layout per thought:
//   [id:          16 bytes raw]
//   [seal_len:    u32 LE][seal_blob: raw bytes]
//   [body_len:    u32 LE][body_blob: raw bytes]
//   [agent_len:   u8][agent: utf8 bytes]
//   [created_len: u8][created_at: utf8 bytes]
//   [updated_len: u8][updated_at: utf8 bytes]
//

thought_serialize_bin :: proc(buf: ^[dynamic]u8, n: Thought) {
	// ID: 16 raw bytes
	id := n.id
	for b in id do append(buf, b)

	// seal_blob: u32 len + raw bytes
	_append_u32(buf, u32(len(n.seal_blob)))
	for b in n.seal_blob do append(buf, b)

	// body_blob: u32 len + raw bytes
	_append_u32(buf, u32(len(n.body_blob)))
	for b in n.body_blob do append(buf, b)

	// agent: u8 len + bytes (max 255, but agent is capped at 64)
	agent_bytes := transmute([]u8)n.agent
	agent_len := min(len(agent_bytes), 255)
	append(buf, u8(agent_len))
	for i in 0 ..< agent_len do append(buf, agent_bytes[i])

	// created_at: u8 len + bytes
	created_bytes := transmute([]u8)n.created_at
	created_len := min(len(created_bytes), 255)
	append(buf, u8(created_len))
	for i in 0 ..< created_len do append(buf, created_bytes[i])

	// updated_at: u8 len + bytes
	updated_bytes := transmute([]u8)n.updated_at
	updated_len := min(len(updated_bytes), 255)
	append(buf, u8(updated_len))
	for i in 0 ..< updated_len do append(buf, updated_bytes[i])
}

thought_parse_bin :: proc(data: []u8, pos: ^int, allocator := context.allocator) -> (n: Thought, err: Thought_Error) {
	p := pos^

	// ID: 16 raw bytes
	if p + 16 > len(data) do return {}, .Bad_Format
	copy(n.id[:], data[p:p + 16])
	p += 16

	// seal_blob: u32 len + raw bytes
	if p + 4 > len(data) do return {}, .Bad_Format
	seal_len := int(_u32_le(data[p:]))
	p += 4
	if p + seal_len > len(data) do return {}, .Bad_Format
	n.seal_blob = make([]u8, seal_len, allocator)
	copy(n.seal_blob, data[p:p + seal_len])
	p += seal_len

	// body_blob: u32 len + raw bytes
	if p + 4 > len(data) do return {}, .Bad_Format
	body_len := int(_u32_le(data[p:]))
	p += 4
	if p + body_len > len(data) do return {}, .Bad_Format
	n.body_blob = make([]u8, body_len, allocator)
	copy(n.body_blob, data[p:p + body_len])
	p += body_len

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

	pos^ = p
	return n, .None
}

// =============================================================================
// Plaintext join / split helpers
// =============================================================================

@(private)
_join_plaintext :: proc(pt: Thought_Plaintext, allocator := context.allocator) -> []u8 {
	b := strings.builder_make(allocator)
	strings.write_string(&b, pt.description)
	strings.write_string(&b, "\n---\n")
	strings.write_string(&b, pt.content)
	return transmute([]u8)strings.to_string(b)
}

@(private)
_split_plaintext :: proc(data: []u8, allocator := context.allocator) -> (pt: Thought_Plaintext, ok: bool) {
	s   := string(data)
	idx := strings.index(s, "\n---\n")
	if idx == -1 do return {}, false
	return Thought_Plaintext{
		description = strings.clone(s[:idx], allocator),
		content     = strings.clone(s[idx + 5:], allocator),
	}, true
}

// =============================================================================
// Hex helpers
// =============================================================================

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
