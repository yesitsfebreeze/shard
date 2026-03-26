package shard

import "core:bytes"
import "core:crypto"
import "core:crypto/chacha20poly1305"
import "core:crypto/hash"
import "core:crypto/hkdf"
import "core:encoding/endian"
import "core:log"
import "core:strings"

load_blob_from_raw :: proc(raw: []u8) -> Blob {
	if len(raw) < SHARD_FOOTER_SIZE do return {}

	magic, magic_ok := endian.get_u64(raw[len(raw) - SHARD_MAGIC_SIZE:], .Little)
	if !magic_ok || magic != SHARD_MAGIC do return {}

	data_size, ds_ok := block_read_u32(raw, len(raw) - SHARD_FOOTER_SIZE)
	if !ds_ok do return {}

	total_appended := int(data_size) + SHARD_FOOTER_SIZE
	if total_appended > len(raw) do return {}

	split := len(raw) - total_appended

	hash_end := len(raw) - SHARD_HASH_SIZE - SHARD_MAGIC_SIZE
	stored_hash := raw[hash_end:hash_end + SHARD_HASH_SIZE]
	computed_hash: [32]u8
	hash.hash_bytes_to_buffer(.SHA256, raw[split:hash_end], computed_hash[:])
	if !bytes.equal(stored_hash, computed_hash[:]) {
		log.error("Peer shard data hash mismatch — rejecting corrupted peer")
		return {}
	}

	data := raw[split:split + int(data_size)]
	shard := shard_data_parse(data)

	return Blob{exe_code = raw[:split], shard = shard, has_data = true}
}

new_thought_id :: proc() -> (id: Thought_ID) {
	crypto.rand_bytes(id[:])
	return
}

thought_id_to_hex :: proc(id: Thought_ID, allocator := runtime_alloc) -> string {
	h := HEX_CHARS
	buf := make([]u8, 32, allocator)
	for b, i in id {
		buf[i * 2] = h[b >> 4]
		buf[i * 2 + 1] = h[b & 0x0f]
	}
	return string(buf)
}

hex_to_thought_id :: proc(s: string) -> (id: Thought_ID, ok: bool) {
	if len(s) != 32 do return id, false
	for i in 0 ..< 16 {
		hi := hex_val(s[i * 2]) or_return
		lo := hex_val(s[i * 2 + 1]) or_return
		id[i] = (hi << 4) | lo
	}
	return id, true
}

hex_val :: proc(c: u8) -> (val: u8, ok: bool) {
	switch c {
	case '0' ..= '9':
		return c - '0', true
	case 'a' ..= 'f':
		return c - 'a' + 10, true
	case 'A' ..= 'F':
		return c - 'A' + 10, true
	}
	return 0, false
}

thought_serialize :: proc(buf: ^[dynamic]u8, t: ^Thought) {
	append_raw(buf, t.id[:])
	append_u32(buf, u32(len(t.seal_blob)))
	append_raw(buf, t.seal_blob)
	append_u32(buf, u32(len(t.body_blob)))
	append_raw(buf, t.body_blob)
	append_str8(buf, t.agent)
	append_str8(buf, t.created_at)
	append_str8(buf, t.updated_at)
	append_raw(buf, t.revises[:])
	append_u32(buf, t.ttl)
	append_u32(buf, t.read_count)
	append_u32(buf, t.cite_count)
	append_raw(buf, t.trust[:])
}

thought_parse :: proc(data: []u8, pos: ^int) -> (t: Thought, ok: bool) {
	read_raw(data, pos, t.id[:]) or_return
	t.seal_blob = read_blob(data, pos) or_return
	t.body_blob = read_blob(data, pos) or_return
	t.agent = read_str8(data, pos) or_return
	t.created_at = read_str8(data, pos) or_return
	t.updated_at = read_str8(data, pos) or_return
	read_raw(data, pos, t.revises[:]) or_return
	t.ttl = read_u32(data, pos) or_return
	t.read_count = read_u32(data, pos) or_return
	t.cite_count = read_u32(data, pos) or_return
	read_raw(data, pos, t.trust[:]) or_return
	return t, true
}

thoughts_size :: proc(thoughts: [][]u8) -> int {
	total := 4
	for t in thoughts do total += 4 + len(t)
	return total
}


derive_key :: proc(master: Key, id: Thought_ID) -> [32]u8 {
	m := master
	i := id
	derived: [32]u8
	hkdf.extract_and_expand(.SHA256, nil, m[:], i[:], derived[:])
	return derived
}

encrypt_blob :: proc(key: [32]u8, plaintext: []u8) -> []u8 {
	IV :: chacha20poly1305.IV_SIZE
	TAG :: chacha20poly1305.TAG_SIZE

	blob := make([]u8, IV + len(plaintext) + TAG, runtime_alloc)
	crypto.rand_bytes(blob[:IV])

	tag: [TAG]u8
	k := key
	ctx: chacha20poly1305.Context
	chacha20poly1305.init(&ctx, k[:])
	defer chacha20poly1305.reset(&ctx)
	chacha20poly1305.seal(&ctx, blob[IV:IV + len(plaintext)], tag[:], blob[:IV], nil, plaintext)
	copy(blob[IV + len(plaintext):], tag[:])
	return blob
}

decrypt_blob :: proc(key: [32]u8, blob: []u8) -> (pt: []u8, ok: bool) {
	MIN :: chacha20poly1305.IV_SIZE + chacha20poly1305.TAG_SIZE
	if len(blob) < MIN do return nil, false

	nonce := blob[:chacha20poly1305.IV_SIZE]
	tag := blob[len(blob) - chacha20poly1305.TAG_SIZE:]
	ct := blob[chacha20poly1305.IV_SIZE:len(blob) - chacha20poly1305.TAG_SIZE]

	pt = make([]u8, len(ct), runtime_alloc)
	k := key

	ctx: chacha20poly1305.Context
	chacha20poly1305.init(&ctx, k[:])
	defer chacha20poly1305.reset(&ctx)

	if !chacha20poly1305.open(&ctx, pt, nonce, nil, ct, tag) {
		return nil, false
	}
	return pt, true
}

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

compute_seal :: proc(key: [32]u8, description: string) -> []u8 {
	desc_hash: [32]u8
	hash.hash_bytes_to_buffer(.SHA256, transmute([]u8)description, desc_hash[:])
	return encrypt_blob(key, desc_hash[:])
}

thought_encrypt :: proc(
	master: Key,
	id: Thought_ID,
	description: string,
	content: string,
) -> (
	body_blob: []u8,
	seal_blob: []u8,
	trust: Trust_Token,
) {
	key := derive_key(master, id)
	plaintext := strings.concatenate({description, BODY_SEPARATOR, content}, runtime_alloc)
	body_blob = encrypt_blob(key, transmute([]u8)plaintext)
	seal_blob = compute_seal(key, description)
	trust = compute_trust(key, transmute([]u8)plaintext)
	return
}

thought_decrypt :: proc(
	master: Key,
	t: ^Thought,
) -> (
	description: string,
	content: string,
	ok: bool,
) {
	key := derive_key(master, t.id)
	plaintext := decrypt_blob(key, t.body_blob) or_return

	text := string(plaintext)
	sep_idx := strings.index(text, BODY_SEPARATOR)
	if sep_idx < 0 do return "", "", false

	description = strings.clone(text[:sep_idx], runtime_alloc)
	content = strings.clone(text[sep_idx + len(BODY_SEPARATOR):], runtime_alloc)
	return description, content, true
}
