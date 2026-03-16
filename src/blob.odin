package shard

import "core:crypto/hash"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"

// =============================================================================
// .shard file format
// =============================================================================
//
// SHRD0003 (current) — binary thoughts:
//
//   [PROCESSED BLOCK]        — count-prefixed binary thoughts (AI-ordered)
//   [UNPROCESSED BLOCK]      — count-prefixed binary thoughts (append-only)
//   [CATALOG BLOCK]          — length-prefixed plaintext JSON
//   [MANIFEST BLOCK]         — length-prefixed plaintext YAML
//   [GATES BLOCK]            — plaintext routing signals
//   [gates_size:  u32 LE]    — 4 bytes
//   [blob_hash:   u8×32]     — SHA256 of all preceding bytes
//   [MAGIC:       u64 LE]    — "SHRD0003" = 0x5348524430303033
//
// Binary thoughts store raw bytes (16-byte IDs, raw ciphertext blobs)
// instead of base64/hex encoding, saving ~30% on thought data.
//
// SHRD0002 (legacy) — text thoughts:
//
//   Same block layout but thoughts use text serialization (hex IDs,
//   base64-encoded ciphertext, text metadata). Files are auto-detected
//   on load and always re-saved as SHRD0003 on flush.
//

SHARD_MAGIC_V3 :: u64(0x5348524430303033) // "SHRD0003" LE
SHARD_MAGIC_V2 :: u64(0x5348524430303032) // "SHRD0002" LE
FOOTER_SIZE    :: 44                      // gates_size(4) + blob_hash(32) + magic(8)

// =============================================================================
// Blob load — auto-detects SHRD0002 (legacy) vs SHRD0003 (binary)
// =============================================================================

blob_load :: proc(
	path:      string,
	master:    Master_Key,
	allocator  := context.allocator,
) -> (b: Blob, ok: bool) {
	b.path        = strings.clone(path, allocator)
	b.master      = master
	b.processed   = make([dynamic]Thought, allocator)
	b.unprocessed = make([dynamic]Thought, allocator)
	b.description = make([dynamic]string, allocator)
	b.positive    = make([dynamic]string, allocator)
	b.negative    = make([dynamic]string, allocator)
	b.related     = make([dynamic]string, allocator)

	data, read_ok := os.read_entire_file(path, context.temp_allocator)
	if !read_ok {
		// New blob — empty is valid.
		return b, true
	}
	defer delete(data, context.temp_allocator)

	file_size := len(data)
	if file_size < FOOTER_SIZE do return b, true // too small, treat as empty

	// Read footer
	footer := data[file_size - FOOTER_SIZE:]
	magic := _u64_le(footer[36:])

	switch magic {
	case SHARD_MAGIC_V3:
		return _blob_load_common(&b, data, file_size, .Binary, allocator)
	case SHARD_MAGIC_V2:
		return _blob_load_common(&b, data, file_size, .Text, allocator)
	case:
		return b, true // unknown magic, treat as empty
	}
}

Thought_Block_Format :: enum { Binary, Text }

@(private)
_blob_load_common :: proc(
	b: ^Blob, data: []u8, file_size: int,
	thought_fmt: Thought_Block_Format,
	allocator := context.allocator,
) -> (Blob, bool) {
	footer := data[file_size - FOOTER_SIZE:]

	// Verify hash: SHA256 of everything before the footer
	stored_hash := footer[4:36]
	computed_hash: [32]u8
	hash.hash_bytes_to_buffer(.SHA256, data[:file_size - FOOTER_SIZE], computed_hash[:])
	for i in 0 ..< 32 {
		if stored_hash[i] != computed_hash[i] do return b^, false // corrupt
	}

	gates_size  := int(_u32_le(footer[0:]))
	data_end    := file_size - FOOTER_SIZE
	gates_start := data_end - gates_size

	// Parse gates
	if gates_size > 0 {
		_parse_gates(&b.description, &b.positive, &b.negative, &b.related, data[gates_start:data_end], allocator)
	}

	// Everything before gates is: processed + unprocessed + catalog + manifest
	content := data[:gates_start]
	pos := 0

	switch thought_fmt {
	case .Binary:
		pos += _parse_thought_block_bin(&b.processed, content[pos:], allocator)
		pos += _parse_thought_block_bin(&b.unprocessed, content[pos:], allocator)
	case .Text:
		pos += _parse_thought_block_text(&b.processed, content[pos:], allocator)
		pos += _parse_thought_block_text(&b.unprocessed, content[pos:], allocator)
	}

	pos += _parse_catalog(&b.catalog, content[pos:], allocator)
	_parse_manifest(&b.manifest, content[pos:], allocator)

	return b^, true
}

// =============================================================================
// Blob flush — always writes SHRD0003 (binary thoughts)
// =============================================================================

blob_flush :: proc(b: ^Blob) -> bool {
	buf := make([dynamic]u8, context.temp_allocator)
	defer delete(buf)

	// Write binary thought blocks
	_serialize_thought_block_bin(&buf, b.processed[:])
	_serialize_thought_block_bin(&buf, b.unprocessed[:])

	// Write catalog block (length-prefixed JSON)
	_serialize_catalog(&buf, b.catalog)

	// Write manifest block
	if len(b.manifest) > 0 {
		mfb := transmute([]u8)b.manifest
		_append_u32(&buf, u32(len(mfb)))
		for byte in mfb do append(&buf, byte)
	} else {
		_append_u32(&buf, 0)
	}

	// Write gates block
	gates := make([dynamic]u8, context.temp_allocator)
	defer delete(gates)
	_append_gate_list(&gates, b.description[:])
	_append_gate_list(&gates, b.positive[:])
	_append_gate_list(&gates, b.negative[:])
	_append_gate_list(&gates, b.related[:])
	for byte in gates do append(&buf, byte)

	// Compute hash of everything so far
	blob_hash: [32]u8
	hash.hash_bytes_to_buffer(.SHA256, buf[:], blob_hash[:])

	// Build footer: [gates_size:u32][blob_hash:u8×32][magic:u64]
	footer: [FOOTER_SIZE]u8
	_put_u32(footer[0:], u32(len(gates)))
	copy(footer[4:36], blob_hash[:])
	_put_u64(footer[36:], SHARD_MAGIC_V3)

	// Write to disk atomically: write temp then rename
	tmp_path := strings.concatenate({b.path, ".tmp"}, context.temp_allocator)
	defer delete(tmp_path, context.temp_allocator)

	f, err := os.open(tmp_path, os.O_WRONLY | os.O_CREATE | os.O_TRUNC, 0o644)
	if err != nil do return false
	defer os.close(f)

	if len(buf) > 0 {
		_, werr := os.write(f, buf[:])
		if werr != nil do return false
	}
	_, ferr := os.write(f, footer[:])
	if ferr != nil do return false

	// Close before rename (required on Windows)
	os.close(f)

	// Rename temp → final
	if os.rename(tmp_path, b.path) != nil {
		os.remove(tmp_path)
		return false
	}
	return true
}

// =============================================================================
// Blob convenience ops
// =============================================================================

blob_put :: proc(b: ^Blob, thought: Thought) -> bool {
	// Check if already exists in either block (update in-place)
	for &existing, i in b.processed {
		if existing.id == thought.id { b.processed[i] = thought; return blob_flush(b) }
	}
	for &existing, i in b.unprocessed {
		if existing.id == thought.id { b.unprocessed[i] = thought; return blob_flush(b) }
	}
	// New thought goes to unprocessed
	append(&b.unprocessed, thought)
	return blob_flush(b)
}

blob_get :: proc(b: ^Blob, id: Thought_ID) -> (thought: Thought, ok: bool) {
	// Check processed first
	for thought in b.processed {
		if thought.id == id do return thought, true
	}
	for thought in b.unprocessed {
		if thought.id == id do return thought, true
	}
	return {}, false
}

blob_remove :: proc(b: ^Blob, id: Thought_ID) -> bool {
	for i in 0 ..< len(b.processed) {
		if b.processed[i].id == id {
			ordered_remove(&b.processed, i)
			return blob_flush(b)
		}
	}
	for i in 0 ..< len(b.unprocessed) {
		if b.unprocessed[i].id == id {
			ordered_remove(&b.unprocessed, i)
			return blob_flush(b)
		}
	}
	return false
}

blob_ids :: proc(b: ^Blob, allocator := context.allocator) -> []Thought_ID {
	total := len(b.processed) + len(b.unprocessed)
	ids := make([]Thought_ID, total, allocator)
	for thought, i in b.processed do ids[i] = thought.id
	off := len(b.processed)
	for thought, i in b.unprocessed do ids[off + i] = thought.id
	return ids
}

// blob_compact moves named thoughts from unprocessed → processed in the given order.
blob_compact :: proc(b: ^Blob, ids: []Thought_ID) -> int {
	moved := 0
	for target_id in ids {
		for i in 0 ..< len(b.unprocessed) {
			if b.unprocessed[i].id == target_id {
				append(&b.processed, b.unprocessed[i])
				ordered_remove(&b.unprocessed, i)
				moved += 1
				break
			}
		}
	}
	if moved > 0 do blob_flush(b)
	return moved
}

// =============================================================================
// Binary thought block serialization (SHRD0003)
// =============================================================================

@(private)
_serialize_thought_block_bin :: proc(buf: ^[dynamic]u8, thoughts: []Thought) {
	_append_u32(buf, u32(len(thoughts)))
	for thought in thoughts {
		thought_serialize_bin(buf, thought)
	}
}

@(private)
_parse_thought_block_bin :: proc(thoughts: ^[dynamic]Thought, data: []u8, allocator := context.allocator) -> int {
	if len(data) < 4 do return 0
	pos   := 0
	count := int(_u32_le(data[pos:]))
	pos   += 4
	for _ in 0 ..< count {
		thought, err := thought_parse_bin(data, &pos, allocator)
		if err != .None do break
		append(thoughts, thought)
	}
	return pos
}

// =============================================================================
// Legacy text thought block serialization (SHRD0002)
// =============================================================================

@(private)
_parse_thought_block_text :: proc(thoughts: ^[dynamic]Thought, data: []u8, allocator := context.allocator) -> int {
	if len(data) < 4 do return 0
	pos   := 0
	count := int(_u32_le(data[pos:]))
	pos   += 4
	for _ in 0 ..< count {
		if pos + 4 > len(data) do break
		size := int(_u32_le(data[pos:]))
		pos  += 4
		if pos + size > len(data) do break
		thought, err := thought_parse(string(data[pos:pos + size]), allocator)
		pos += size
		if err != .None do continue
		append(thoughts, thought)
	}
	return pos
}

// =============================================================================
// Catalog serialization (length-prefixed JSON, plaintext)
// =============================================================================

@(private)
_serialize_catalog :: proc(buf: ^[dynamic]u8, cat: Catalog) {
	data, err := json.marshal(cat)
	if err != nil {
		_append_u32(buf, 0)
		return
	}
	defer delete(data)
	_append_u32(buf, u32(len(data)))
	for byte in data do append(buf, byte)
}

@(private)
_parse_catalog :: proc(cat: ^Catalog, data: []u8, allocator := context.allocator) -> int {
	if len(data) < 4 do return 0
	n := int(_u32_le(data[:4]))
	if n == 0 do return 4
	if 4 + n > len(data) do return 4
	json.unmarshal(data[4:4 + n], cat, allocator = allocator)
	return 4 + n
}

// =============================================================================
// Manifest serialization
// =============================================================================

@(private)
_parse_manifest :: proc(manifest: ^string, data: []u8, allocator := context.allocator) {
	if len(data) < 4 do return
	n := int(_u32_le(data[:4]))
	if 4 + n > len(data) do return
	if n > 0 do manifest^ = strings.clone(string(data[4:4 + n]), allocator)
}

// =============================================================================
// Gates serialization
// =============================================================================

@(private)
_append_gate_list :: proc(buf: ^[dynamic]u8, list: []string) {
	_append_u16(buf, u16(len(list)))
	for s in list {
		b := transmute([]u8)s
		l := min(len(b), 256)
		append(buf, u8(l))
		for i in 0 ..< l do append(buf, b[i])
	}
}

@(private)
_parse_gate_list :: proc(out: ^[dynamic]string, data: []u8, off: ^int, allocator := context.allocator) {
	if off^ + 2 > len(data) do return
	count := int(_u16_le(data[off^:]))
	off^  += 2
	for _ in 0 ..< count {
		if off^ >= len(data) do return
		l    := int(data[off^]); off^ += 1
		if off^ + l > len(data) do return
		append(out, strings.clone(string(data[off^:off^ + l]), allocator))
		off^ += l
	}
}

@(private)
_parse_gates :: proc(
	desc, pos, neg, rel: ^[dynamic]string,
	data:                []u8,
	allocator            := context.allocator,
) {
	off := 0
	_parse_gate_list(desc, data, &off, allocator)
	_parse_gate_list(pos,  data, &off, allocator)
	_parse_gate_list(neg,  data, &off, allocator)
	_parse_gate_list(rel,  data, &off, allocator)  // backwards compat: old files just won't have this data
}

// =============================================================================
// Migration — re-save a shard in the latest format (SHRD0003)
// =============================================================================

// blob_compress loads a shard file (any version) and re-saves it as SHRD0003.
// Returns (old_size, new_size, ok).
blob_compress :: proc(path: string, master: Master_Key) -> (old_size: int, new_size: int, ok: bool) {
	// Get original file size without reading the whole file into temp allocator
	old_sz := os.file_size_from_path(path)
	if old_sz < 0 do return 0, 0, false
	old_size = int(old_sz)

	// Load (auto-detects V2 or V3)
	blob, load_ok := blob_load(path, master)
	if !load_ok do return old_size, 0, false

	// Flush always writes V3
	if !blob_flush(&blob) do return old_size, 0, false

	// Get new file size
	new_sz := os.file_size_from_path(path)
	if new_sz < 0 do return old_size, 0, false
	new_size = int(new_sz)

	return old_size, new_size, true
}

// =============================================================================
// Binary encoding helpers
// =============================================================================

_append_u16 :: proc(buf: ^[dynamic]u8, v: u16) {
	append(buf, u8(v), u8(v >> 8))
}

_append_u32 :: proc(buf: ^[dynamic]u8, v: u32) {
	append(buf, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24))
}

@(private)
_u16_le :: proc(b: []u8) -> u16 {
	return u16(b[0]) | u16(b[1]) << 8
}

@(private)
_u32_le :: proc(b: []u8) -> u32 {
	return u32(b[0]) | u32(b[1]) << 8 | u32(b[2]) << 16 | u32(b[3]) << 24
}

@(private)
_u64_le :: proc(b: []u8) -> u64 {
	return u64(b[0]) | u64(b[1]) << 8 | u64(b[2]) << 16 | u64(b[3]) << 24 |
	       u64(b[4]) << 32 | u64(b[5]) << 40 | u64(b[6]) << 48 | u64(b[7]) << 56
}

@(private)
_put_u32 :: proc(b: []u8, v: u32) {
	b[0] = u8(v); b[1] = u8(v >> 8); b[2] = u8(v >> 16); b[3] = u8(v >> 24)
}

_put_u64 :: proc(b: []u8, v: u64) {
	b[0] = u8(v);      b[1] = u8(v >> 8);  b[2] = u8(v >> 16); b[3] = u8(v >> 24)
	b[4] = u8(v >> 32); b[5] = u8(v >> 40); b[6] = u8(v >> 48); b[7] = u8(v >> 56)
}
