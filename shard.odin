package shard

import "core:bytes"
import "core:crypto"
import "core:crypto/chacha20poly1305"
import "core:crypto/hash"
import "core:crypto/hkdf"
import "core:encoding/endian"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:os/os2"
import "core:path/filepath"
import "core:strings"
import "core:unicode"

VERSION :: "0.1.0"
SHARD_MAGIC :: u64(0x5348524430303036)
SHARD_MAGIC_SIZE :: 8
SHARD_HASH_SIZE :: 32
SHARD_FOOTER_SIZE :: SHARD_MAGIC_SIZE + SHARD_HASH_SIZE + 4
SHARDS_DIR :: ".shards"
INDEX_DIR :: "index"
RUN_DIR :: "run"
IDLE_TIMEOUT_MS :: 30_000
LOG_FILE :: "shard.log"
BODY_SEPARATOR :: "\n---\n"

HELP_TEXT :: [Command][2]string {
	.Help    = {string(#load("help/help.txt")), string(#load("help/help.ai.txt"))},
	.Daemon  = {string(#load("help/daemon.txt")), string(#load("help/daemon.ai.txt"))},
	.Version = {string(#load("help/version.txt")), string(#load("help/version.ai.txt"))},
	.Info    = {string(#load("help/info.txt")), string(#load("help/info.ai.txt"))},
	.Mcp     = {string(#load("help/daemon.txt")), string(#load("help/daemon.ai.txt"))},
	.None    = {string(#load("help/help.txt")), string(#load("help/help.ai.txt"))},
}

Command :: enum {
	None,
	Daemon,
	Mcp,
	Help,
	Version,
	Info,
}

Thought_ID :: distinct [16]u8
Trust_Token :: distinct [32]u8
Key :: distinct [32]u8

Thought :: struct {
	id:         Thought_ID,
	trust:      Trust_Token,
	seal_blob:  []u8,
	body_blob:  []u8,
	agent:      string,
	created_at: string,
	updated_at: string,
	revises:    Thought_ID,
	ttl:        u32,
	read_count: u32,
	cite_count: u32,
}

Catalog :: struct {
	name:    string `json:"name"`,
	purpose: string `json:"purpose"`,
	tags:    []string `json:"tags"`,
	created: string `json:"created"`,
}

Gates :: struct {
	description: string,
	accept:      []string,
	reject:      []string,
}

Shard_Data :: struct {
	catalog:     Catalog,
	gates:       Gates,
	manifest:    string,
	processed:   [][]u8,
	unprocessed: [][]u8,
}

Blob :: struct {
	exe_code: []u8,
	shard:    Shard_Data,
	has_data: bool,
}

Index_Entry :: struct {
	shard_id:  string,
	exe_path:  string,
	prev_path: string,
}

IPC_Result :: enum {
	Ok,
	Timeout,
	Error,
}

MSG_MAX_SIZE :: 16 * 1024 * 1024

State :: struct {
	exe_path:     string,
	exe_dir:      string,
	shard_id:     string,
	index_dir:    string,
	run_dir:      string,
	working_copy: string,
	command:      Command,
	ai_mode:      bool,
	blob:         Blob,
	key:          Key,
	has_key:      bool,
}

state: ^State
runtime_arena: ^mem.Arena
runtime_alloc: mem.Allocator
console_logger: log.Logger
file_logger: log.Logger
multi_logger: log.Logger
log_file_handle: os.Handle

logger_init :: proc() {
	log_file_handle = os.INVALID_HANDLE
	console_logger = log.create_console_logger(.Debug)

	log_path := filepath.join({state.exe_dir, LOG_FILE}, runtime_alloc)
	handle, err := os.open(log_path, os.O_WRONLY | os.O_CREATE | os.O_APPEND)
	if err == nil {
		log_file_handle = handle
		file_logger = log.create_file_logger(handle, .Debug)
		multi_logger = log.create_multi_logger(console_logger, file_logger)
	} else {
		multi_logger = console_logger
	}
}

logger_shutdown :: proc() {
	if log_file_handle != os.INVALID_HANDLE {
		log.destroy_multi_logger(multi_logger)
		log.destroy_file_logger(file_logger)
		os.close(log_file_handle)
	}
	log.destroy_console_logger(console_logger)
}

shutdown :: proc(code: int = 0) {
	logger_shutdown()
	if runtime_arena != nil do mem.arena_free_all(runtime_arena)
	os.exit(code)
}

startup :: proc() {
	runtime_arena = new(mem.Arena)
	mem.arena_init(runtime_arena, make([]byte, 16 * mem.Megabyte))
	runtime_alloc = mem.arena_allocator(runtime_arena)

	state = new(State, runtime_alloc)

	exe_path, exe_err := os2.get_executable_path(runtime_alloc)
	if exe_err != nil do shutdown(1)
	state.exe_path = exe_path
	state.exe_dir = filepath.dir(exe_path, runtime_alloc)

	logger_init()

	home := os.get_env("HOME", runtime_alloc)
	if len(home) == 0 do shutdown(1)
	state.index_dir = filepath.join({home, SHARDS_DIR, INDEX_DIR}, runtime_alloc)
	state.run_dir = filepath.join({home, SHARDS_DIR, RUN_DIR}, runtime_alloc)

	blob_read_self()
	load_key()

	state.shard_id = resolve_shard_id()
	index_cleanup_prev()
}

index_cleanup_prev :: proc() {
	current, prev, ok := index_read(state.shard_id)
	if !ok || len(prev) == 0 || prev == state.exe_path do return

	if os.exists(prev) {
		os.remove(prev)
		log.infof("Deleted previous revision: %s", prev)
	}
	index_write(state.shard_id, current)
}

block_read_u32 :: proc(data: []u8, pos: int) -> (u32, bool) {
	if pos + 4 > len(data) do return 0, false
	return endian.get_u32(data[pos:pos + 4], .Little)
}

block_read_bytes :: proc(data: []u8, pos: int) -> ([]u8, int, bool) {
	size, ok := block_read_u32(data, pos)
	if !ok do return nil, pos, false
	start := pos + 4
	end := start + int(size)
	if end > len(data) do return nil, pos, false
	return data[start:end], end, true
}

block_read_thoughts :: proc(data: []u8, pos: int) -> ([][]u8, int, bool) {
	count, ok := block_read_u32(data, pos)
	if !ok do return nil, pos, false

	cursor := pos + 4
	thoughts := make([][]u8, count, runtime_alloc)
	for i in 0 ..< int(count) {
		blob: []u8
		blob, cursor, ok = block_read_bytes(data, cursor)
		if !ok do return nil, pos, false
		thoughts[i] = blob
	}
	return thoughts, cursor, true
}

block_write_u32 :: proc(buf: []u8, pos: int, val: u32) -> int {
	endian.put_u32(buf[pos:], .Little, val)
	return pos + 4
}

block_write_bytes :: proc(buf: []u8, pos: int, data: []u8) -> int {
	p := block_write_u32(buf, pos, u32(len(data)))
	copy(buf[p:], data)
	return p + len(data)
}

block_write_thoughts :: proc(buf: []u8, pos: int, thoughts: [][]u8) -> int {
	p := block_write_u32(buf, pos, u32(len(thoughts)))
	for t in thoughts do p = block_write_bytes(buf, p, t)
	return p
}

thoughts_size :: proc(thoughts: [][]u8) -> int {
	total := 4
	for t in thoughts do total += 4 + len(t)
	return total
}

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

blob_write_self :: proc() -> bool {
	target := state.working_copy if len(state.working_copy) > 0 else state.exe_path

	s := &state.blob.shard
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

	total := len(state.blob.exe_code) + data_size + SHARD_FOOTER_SIZE
	buf := make([]u8, total, runtime_alloc)

	pos := 0
	copy(buf, state.blob.exe_code)
	pos += len(state.blob.exe_code)

	pos = block_write_thoughts(buf, pos, s.processed)
	pos = block_write_thoughts(buf, pos, s.unprocessed)
	pos = block_write_bytes(buf, pos, transmute([]u8)catalog_json)
	pos = block_write_bytes(buf, pos, transmute([]u8)s.manifest)
	pos = block_write_bytes(buf, pos, transmute([]u8)gates_text)

	pos = block_write_u32(buf, pos, u32(data_size))

	data_start := len(state.blob.exe_code)
	data_end := pos
	blob_hash: [32]u8
	hash.hash_bytes_to_buffer(.SHA256, buf[data_start:data_end], blob_hash[:])
	copy(buf[pos:pos + SHARD_HASH_SIZE], blob_hash[:])
	pos += SHARD_HASH_SIZE

	endian.put_u64(buf[pos:], .Little, SHARD_MAGIC)

	tmp_path := strings.concatenate({target, ".tmp"}, runtime_alloc)
	if !os.write_entire_file(tmp_path, buf) do return false
	if os.rename(tmp_path, target) != nil do return false

	log.infof("Wrote shard data to %s (%d bytes)", target, total)
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

gates_serialize :: proc(g: ^Gates) -> string {
	parts: [dynamic]string
	parts.allocator = runtime_alloc

	append(&parts, g.description)
	append(&parts, "\n---accept\n")
	append(&parts, strings.join(g.accept, "\n", allocator = runtime_alloc))
	append(&parts, "\n---reject\n")
	append(&parts, strings.join(g.reject, "\n", allocator = runtime_alloc))

	return strings.concatenate(parts[:], runtime_alloc)
}

gates_parse :: proc(data: []u8) -> Gates {
	g: Gates
	text := string(data)

	accept_idx := strings.index(text, "\n---accept\n")
	reject_idx := strings.index(text, "\n---reject\n")
	if accept_idx < 0 || reject_idx < 0 {
		g.description = text
		return g
	}

	g.description = text[:accept_idx]

	accept_start := accept_idx + len("\n---accept\n")
	accept_text := text[accept_start:reject_idx]
	if len(accept_text) > 0 {
		g.accept = strings.split(accept_text, "\n", allocator = runtime_alloc)
	}

	reject_start := reject_idx + len("\n---reject\n")
	reject_text := text[reject_start:]
	if len(reject_text) > 0 {
		g.reject = strings.split(reject_text, "\n", allocator = runtime_alloc)
	}

	return g
}

Gate_Result :: enum {
	Accept,
	Reject,
	No_Match,
}

gates_check :: proc(g: ^Gates, description: string, content: string) -> Gate_Result {
	text := strings.to_lower(
		strings.concatenate({description, " ", content}, runtime_alloc),
		runtime_alloc,
	)

	for term in g.reject {
		if len(term) > 0 && strings.contains(text, strings.to_lower(term, runtime_alloc)) {
			return .Reject
		}
	}

	if len(g.accept) == 0 do return .No_Match

	for term in g.accept {
		if len(term) > 0 && strings.contains(text, strings.to_lower(term, runtime_alloc)) {
			return .Accept
		}
	}

	return .No_Match
}

Query_Result :: struct {
	id:          Thought_ID,
	description: string,
	score:       int,
}

query_thoughts :: proc(keyword: string) -> []Query_Result {
	if !state.has_key do return {}

	needle := strings.to_lower(keyword, runtime_alloc)
	results: [dynamic]Query_Result
	results.allocator = runtime_alloc

	s := &state.blob.shard
	for block in ([2][][]u8{s.processed, s.unprocessed}) {
		for blob in block {
			pos := 0
			t, ok := thought_parse(blob, &pos)
			if !ok do continue

			desc, _, decrypt_ok := thought_decrypt(state.key, &t)
			if !decrypt_ok do continue

			lower_desc := strings.to_lower(desc, runtime_alloc)
			if strings.contains(lower_desc, needle) {
				append(&results, Query_Result{
					id          = t.id,
					description = desc,
					score       = 1,
				})
			}
		}
	}
	return results[:]
}

new_thought_id :: proc() -> (id: Thought_ID) {
	crypto.rand_bytes(id[:])
	return
}

thought_id_to_hex :: proc(id: Thought_ID, allocator := runtime_alloc) -> string {
	hex_chars := "0123456789abcdef"
	buf := make([]u8, 32, allocator)
	for b, i in id {
		buf[i * 2] = hex_chars[b >> 4]
		buf[i * 2 + 1] = hex_chars[b & 0x0f]
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

append_raw :: proc(buf: ^[dynamic]u8, data: []u8) {
	for b in data do append(buf, b)
}

append_u32 :: proc(buf: ^[dynamic]u8, val: u32) {
	b: [4]u8
	endian.put_u32(b[:], .Little, val)
	for x in b do append(buf, x)
}

append_str8 :: proc(buf: ^[dynamic]u8, s: string) {
	append(buf, u8(min(len(s), 255)))
	for i in 0 ..< min(len(s), 255) do append(buf, s[i])
}

read_raw :: proc(data: []u8, pos: ^int, out: []u8) -> bool {
	if pos^ + len(out) > len(data) do return false
	copy(out, data[pos^:pos^ + len(out)])
	pos^ += len(out)
	return true
}

read_u32 :: proc(data: []u8, pos: ^int) -> (val: u32, ok: bool) {
	if pos^ + 4 > len(data) do return 0, false
	val, ok = endian.get_u32(data[pos^:pos^ + 4], .Little)
	if ok do pos^ += 4
	return val, ok
}

read_blob :: proc(data: []u8, pos: ^int) -> (result: []u8, ok: bool) {
	size := read_u32(data, pos) or_return
	if pos^ + int(size) > len(data) do return nil, false
	result = make([]u8, size, runtime_alloc)
	copy(result, data[pos^:pos^ + int(size)])
	pos^ += int(size)
	return result, true
}

read_str8 :: proc(data: []u8, pos: ^int) -> (result: string, ok: bool) {
	if pos^ >= len(data) do return "", false
	length := int(data[pos^])
	pos^ += 1
	if pos^ + length > len(data) do return "", false
	result = strings.clone(string(data[pos^:pos^ + length]), runtime_alloc)
	pos^ += length
	return result, true
}

load_key :: proc() {
	key_hex := os.get_env("SHARD_KEY", runtime_alloc)
	if len(key_hex) == 0 do return

	k, ok := hex_to_key(key_hex)
	if !ok {
		log.error("SHARD_KEY must be exactly 64 hex characters (32 bytes)")
		return
	}
	state.key = k
	state.has_key = true
	log.info("Encryption key loaded from SHARD_KEY")
}

hex_to_key :: proc(s: string) -> (key: Key, ok: bool) {
	if len(s) != 64 do return {}, false
	b, decoded := hex.decode(transmute([]u8)s, runtime_alloc)
	if !decoded || len(b) != 32 do return {}, false
	copy(key[:], b)
	return key, true
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

verify_seal :: proc(t: ^Thought, master: Key, description: string) -> bool {
	key := derive_key(master, t.id)
	expected: [32]u8
	hash.hash_bytes_to_buffer(.SHA256, transmute([]u8)description, expected[:])
	actual, ok := decrypt_blob(key, t.seal_blob)
	if !ok do return false
	return bytes.equal(actual, expected[:])
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

write_thought :: proc(
	description: string,
	content: string,
	agent: string = "",
) -> (
	Thought_ID,
	bool,
) {
	if !state.has_key {
		log.error("Cannot write thought: no encryption key (set SHARD_KEY)")
		return {}, false
	}

	gate_result := gates_check(&state.blob.shard.gates, description, content)
	if gate_result == .Reject {
		log.warn("Thought rejected by gates")
		return {}, false
	}

	id := new_thought_id()
	body_blob, seal_blob, trust := thought_encrypt(state.key, id, description, content)

	t := Thought {
		id         = id,
		trust      = trust,
		seal_blob  = seal_blob,
		body_blob  = body_blob,
		agent      = agent,
		created_at = "", // TODO: RFC3339 timestamp
		updated_at = "",
		ttl        = 0,
	}

	buf: [dynamic]u8
	buf.allocator = runtime_alloc
	thought_serialize(&buf, &t)

	s := &state.blob.shard
	new_unprocessed := make([dynamic][]u8, len(s.unprocessed), runtime_alloc)
	for entry in s.unprocessed do append(&new_unprocessed, entry)
	append(&new_unprocessed, buf[:])
	s.unprocessed = new_unprocessed[:]

	if !state.blob.has_data do state.blob.has_data = true

	if !blob_write_self() {
		log.errorf("Failed to persist thought %s", thought_id_to_hex(id))
		return {}, false
	}

	log.infof("Wrote thought %s (%d bytes body)", thought_id_to_hex(id), len(body_blob))
	return id, true
}

read_thought :: proc(target_id: Thought_ID) -> (description: string, content: string, ok: bool) {
	if !state.has_key {
		log.error("Cannot read thought: no encryption key (set SHARD_KEY)")
		return "", "", false
	}

	s := &state.blob.shard
	for block in ([2][][]u8{s.processed, s.unprocessed}) {
		for blob in block {
			pos := 0
			t, parse_ok := thought_parse(blob, &pos)
			if !parse_ok do continue
			if t.id == target_id {
				return thought_decrypt(state.key, &t)
			}
		}
	}
	return "", "", false
}

slugify :: proc(name: string) -> string {
	buf := make([dynamic]u8, 0, len(name), runtime_alloc)
	prev_dash := true
	for r in name {
		if unicode.is_letter(r) || unicode.is_digit(r) {
			append(&buf, u8(unicode.to_lower(r)))
			prev_dash = false
		} else if !prev_dash && len(buf) > 0 {
			append(&buf, '-')
			prev_dash = true
		}
	}
	if len(buf) > 0 && buf[len(buf) - 1] == '-' {
		pop(&buf)
	}
	if len(buf) > 64 {
		return string(buf[:64])
	}
	return string(buf[:])
}

resolve_shard_id :: proc() -> string {
	if state.blob.has_data && len(state.blob.shard.catalog.name) > 0 {
		return slugify(state.blob.shard.catalog.name)
	}
	h: [32]u8
	hash.hash_bytes_to_buffer(.SHA256, transmute([]u8)state.exe_path, h[:])
	hex_chars := "0123456789abcdef"
	buf := make([]u8, 16, runtime_alloc)
	for i in 0 ..< 8 {
		buf[i * 2] = hex_chars[h[i] >> 4]
		buf[i * 2 + 1] = hex_chars[h[i] & 0x0f]
	}
	return string(buf)
}

ensure_dir :: proc(path: string) {
	if !os.exists(path) {
		parent := filepath.dir(path, runtime_alloc)
		if !os.exists(parent) do os.make_directory(parent)
		os.make_directory(path)
	}
}

index_read :: proc(shard_id: string) -> (current: string, prev: string, ok: bool) {
	path := filepath.join({state.index_dir, shard_id}, runtime_alloc)
	content, read_ok := os.read_entire_file(path, runtime_alloc)
	if !read_ok do return "", "", false

	lines := strings.split(string(content), "\n", allocator = runtime_alloc)
	if len(lines) >= 1 && len(strings.trim_space(lines[0])) > 0 {
		current = strings.trim_space(lines[0])
	}
	if len(lines) >= 2 && len(strings.trim_space(lines[1])) > 0 {
		prev = strings.trim_space(lines[1])
	}
	return current, prev, len(current) > 0
}

index_write :: proc(shard_id: string, current: string, prev: string = "") -> bool {
	ensure_dir(state.index_dir)

	path := filepath.join({state.index_dir, shard_id}, runtime_alloc)
	content: string
	if len(prev) > 0 {
		content = strings.concatenate({current, "\n", prev, "\n"}, runtime_alloc)
	} else {
		content = strings.concatenate({current, "\n"}, runtime_alloc)
	}

	return os.write_entire_file(path, transmute([]u8)content)
}

index_list :: proc() -> []Index_Entry {
	ensure_dir(state.index_dir)

	dh, err := os.open(state.index_dir)
	if err != nil do return {}
	defer os.close(dh)

	entries, _ := os.read_dir(dh, -1, runtime_alloc)
	result: [dynamic]Index_Entry
	result.allocator = runtime_alloc

	for entry in entries {
		if entry.is_dir do continue
		current, prev, ok := index_read(entry.name)
		if ok {
			append(
				&result,
				Index_Entry {
					shard_id = strings.clone(entry.name, runtime_alloc),
					exe_path = current,
					prev_path = prev,
				},
			)
		}
	}
	return result[:]
}

parse_args :: proc() -> Command {
	args := os.args[1:]
	if len(args) == 0 do return .None

	cmd := Command.None
	for arg in args {
		switch arg {
		case "--ai":
			state.ai_mode = true
		case "--daemon", "-d":
			cmd = .Daemon
		case "--mcp":
			cmd = .Mcp
		case "--help", "-h":
			cmd = .Help
		case "--version", "-v":
			cmd = .Version
		case "--info", "-i":
			cmd = .Info
		case:
			if strings.has_prefix(arg, "-") {
				fmt.println("Unknown flag:", arg)
				fmt.print(HELP_TEXT[.Help][0])
				shutdown(1)
			}
		}
	}
	return cmd
}

working_copy_start :: proc() -> bool {
	ensure_dir(state.run_dir)
	state.working_copy = filepath.join({state.run_dir, state.shard_id}, runtime_alloc)
	raw, ok := os.read_entire_file(state.exe_path, runtime_alloc)
	if !ok do return false
	if !os.write_entire_file(state.working_copy, raw) do return false

	os2.chmod(
		state.working_copy,
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

	log.infof("Working copy created: %s", state.working_copy)
	return true
}

daemon_run :: proc() {
	log.infof("Shard daemon started: %s (id: %s)", state.exe_path, state.shard_id)

	if !working_copy_start() {
		log.error("Failed to create working copy")
		return
	}

	index_write(state.shard_id, state.exe_path)

	listener, listen_ok := ipc_listen(state.shard_id)
	if !listen_ok {
		log.error("Failed to start IPC listener")
		return
	}
	defer ipc_close_listener(&listener)

	log.infof("Listening on %s (idle timeout: %d ms)", listener.path, IDLE_TIMEOUT_MS)

	for {
		conn, result := ipc_accept_timed(&listener, i32(IDLE_TIMEOUT_MS))

		switch result {
		case .Timeout:
			log.info("Idle timeout reached, shutting down.")
			return
		case .Error:
			log.error("Accept error, shutting down.")
			return
		case .Ok:
			handle_connection(conn)
		}
	}
}

REQUEST_ARENA_SIZE :: 1 * mem.Megabyte

handle_connection :: proc(conn: IPC_Conn) {
	defer ipc_close(conn)

	request_arena: mem.Arena
	request_buf := make([]byte, REQUEST_ARENA_SIZE, runtime_alloc)
	mem.arena_init(&request_arena, request_buf)
	defer mem.arena_free_all(&request_arena)

	ctx := context
	ctx.allocator = mem.arena_allocator(&request_arena)

	context = ctx
	handle_request(conn)
}

handle_request :: proc(conn: IPC_Conn) {

	msg, ok := ipc_recv_msg(conn)
	if !ok {
		log.warn("Failed to read message from connection")
		return
	}

	log.infof("Received %d bytes", len(msg))

	// TODO: parse JSON-RPC request, dispatch to operations
	response := transmute([]u8)string("{\"error\":\"not implemented\"}")
	ipc_send_msg(conn, response)
}

MCP_PROTOCOL_VERSION :: "2024-11-05"
MCP_SERVER_NAME :: "shard"

mcp_run :: proc() {
	log.info("MCP server started on stdio")
	index_write(state.shard_id, state.exe_path)

	buf := make([]u8, 65536, runtime_alloc)
	line_buf := strings.builder_make(runtime_alloc)

	for {
		n, err := os.read(os.stdin, buf[:])
		if err != nil || n <= 0 do break

		strings.write_bytes(&line_buf, buf[:n])
		accumulated := strings.to_string(line_buf)

		for {
			nl := strings.index(accumulated, "\n")
			if nl == -1 do break

			line := strings.trim_right(accumulated[:nl], "\r")
			accumulated = accumulated[nl + 1:]

			if len(strings.trim_space(line)) == 0 do continue

			resp := mcp_process(line)
			if len(resp) > 0 {
				fmt.println(resp)
			}
		}

		strings.builder_reset(&line_buf)
		if len(accumulated) > 0 {
			strings.write_string(&line_buf, accumulated)
		}
	}
}

mcp_process :: proc(line: string) -> string {
	parsed, parse_err := json.parse(transmute([]u8)line, allocator = runtime_alloc)
	if parse_err != nil do return mcp_error(nil, -32700, "parse error")

	obj, is_obj := parsed.(json.Object)
	if !is_obj do return mcp_error(nil, -32600, "invalid request")

	method_val, has_method := obj["method"]
	if !has_method do return mcp_error(nil, -32600, "missing method")
	method, is_str := method_val.(json.String)
	if !is_str do return mcp_error(nil, -32600, "method must be string")

	id_val, has_id := obj["id"]
	if !has_id do return ""

	switch method {
	case "initialize":
		return mcp_initialize(id_val)
	case "tools/list":
		return mcp_tools_list(id_val)
	case "tools/call":
		params, params_ok := obj["params"].(json.Object)
		if !params_ok do return mcp_error(id_val, -32602, "missing params")
		return mcp_tools_call(id_val, params)
	case:
		return mcp_error(id_val, -32601, "method not found")
	}
}

mcp_result :: proc(id_val: json.Value, result_json: string) -> string {
	b := strings.builder_make(runtime_alloc)
	strings.write_string(&b, `{"jsonrpc":"2.0","id":`)
	mcp_write_value(&b, id_val)
	strings.write_string(&b, `,"result":`)
	strings.write_string(&b, result_json)
	strings.write_string(&b, `}`)
	return strings.to_string(b)
}

mcp_error :: proc(id_val: json.Value, code: int, message: string) -> string {
	b := strings.builder_make(runtime_alloc)
	strings.write_string(&b, `{"jsonrpc":"2.0","id":`)
	mcp_write_value(&b, id_val)
	fmt.sbprintf(&b, `,"error":{"code":%d,"message":"`, code)
	strings.write_string(&b, mcp_json_escape(message))
	strings.write_string(&b, `"}}`)
	return strings.to_string(b)
}

mcp_tool_result :: proc(id_val: json.Value, text: string, is_error: bool = false) -> string {
	b := strings.builder_make(runtime_alloc)
	strings.write_string(&b, `{"jsonrpc":"2.0","id":`)
	mcp_write_value(&b, id_val)
	strings.write_string(&b, `,"result":{"content":[{"type":"text","text":"`)
	strings.write_string(&b, mcp_json_escape(text))
	strings.write_string(&b, `"}]`)
	if is_error do strings.write_string(&b, `,"isError":true`)
	strings.write_string(&b, `}}`)
	return strings.to_string(b)
}

mcp_write_value :: proc(b: ^strings.Builder, val: json.Value) {
	switch v in val {
	case json.Null:
		strings.write_string(b, "null")
	case json.Integer:
		fmt.sbprintf(b, "%d", v)
	case json.Float:
		fmt.sbprintf(b, "%f", v)
	case json.String:
		strings.write_string(b, `"`)
		strings.write_string(b, mcp_json_escape(v))
		strings.write_string(b, `"`)
	case json.Boolean:
		strings.write_string(b, "true" if v else "false")
	case json.Array, json.Object:
		strings.write_string(b, "null")
	}
}

mcp_json_escape :: proc(s: string) -> string {
	b := strings.builder_make(runtime_alloc)
	for c in s {
		switch c {
		case '"':
			strings.write_string(&b, `\"`)
		case '\\':
			strings.write_string(&b, `\\`)
		case '\n':
			strings.write_string(&b, `\n`)
		case '\r':
			strings.write_string(&b, `\r`)
		case '\t':
			strings.write_string(&b, `\t`)
		case:
			strings.write_rune(&b, c)
		}
	}
	return strings.to_string(b)
}

mcp_initialize :: proc(id_val: json.Value) -> string {
	b := strings.builder_make(runtime_alloc)
	fmt.sbprintf(&b, `{{"protocolVersion":"%s"`, MCP_PROTOCOL_VERSION)
	strings.write_string(&b, `,"capabilities":{"tools":{}}`)
	fmt.sbprintf(&b, `,"serverInfo":{{"name":"%s","version":"%s"}}`, MCP_SERVER_NAME, VERSION)
	strings.write_string(&b, `}`)
	return mcp_result(id_val, strings.to_string(b))
}

MCP_TOOLS_JSON :: `[{"name":"shard_write","description":"Write a thought to this shard","inputSchema":{"type":"object","properties":{"description":{"type":"string"},"content":{"type":"string"},"agent":{"type":"string"}},"required":["description","content"]}},{"name":"shard_read","description":"Read a thought by ID","inputSchema":{"type":"object","properties":{"id":{"type":"string","description":"32-char hex thought ID"}},"required":["id"]}},{"name":"shard_query","description":"Search thoughts by keyword","inputSchema":{"type":"object","properties":{"keyword":{"type":"string"}},"required":["keyword"]}},{"name":"shard_info","description":"Get shard metadata","inputSchema":{"type":"object","properties":{}}}]`

mcp_tools_list :: proc(id_val: json.Value) -> string {
	return mcp_result(id_val, fmt.aprintf(`{{"tools":%s}}`, MCP_TOOLS_JSON, allocator = runtime_alloc))
}

mcp_tools_call :: proc(id_val: json.Value, params: json.Object) -> string {
	name_val, has_name := params["name"]
	if !has_name do return mcp_error(id_val, -32602, "missing tool name")
	tool_name, is_str := name_val.(json.String)
	if !is_str do return mcp_error(id_val, -32602, "tool name must be string")

	args, _ := params["arguments"].(json.Object)

	switch tool_name {
	case "shard_write":
		return mcp_tool_write(id_val, args)
	case "shard_read":
		return mcp_tool_read(id_val, args)
	case "shard_query":
		return mcp_tool_query(id_val, args)
	case "shard_info":
		return mcp_tool_info(id_val)
	case:
		return mcp_error(id_val, -32602, "unknown tool")
	}
}

mcp_tool_write :: proc(id_val: json.Value, args: json.Object) -> string {
	desc, _ := args["description"].(json.String)
	content, _ := args["content"].(json.String)
	agent, _ := args["agent"].(json.String)

	if len(desc) == 0 do return mcp_tool_result(id_val, "missing description", true)
	if len(content) == 0 do return mcp_tool_result(id_val, "missing content", true)

	id, ok := write_thought(desc, content, agent)
	if !ok do return mcp_tool_result(id_val, "write failed (check key/gates)", true)

	return mcp_tool_result(id_val, fmt.aprintf("wrote thought %s", thought_id_to_hex(id), allocator = runtime_alloc))
}

mcp_tool_read :: proc(id_val: json.Value, args: json.Object) -> string {
	id_hex, _ := args["id"].(json.String)
	if len(id_hex) == 0 do return mcp_tool_result(id_val, "missing id", true)

	tid, ok := hex_to_thought_id(id_hex)
	if !ok do return mcp_tool_result(id_val, "invalid id (must be 32 hex chars)", true)

	desc, content, read_ok := read_thought(tid)
	if !read_ok do return mcp_tool_result(id_val, "thought not found or decrypt failed", true)

	return mcp_tool_result(id_val, fmt.aprintf("# %s\n\n%s", desc, content, allocator = runtime_alloc))
}

mcp_tool_query :: proc(id_val: json.Value, args: json.Object) -> string {
	keyword, _ := args["keyword"].(json.String)
	if len(keyword) == 0 do return mcp_tool_result(id_val, "missing keyword", true)

	results := query_thoughts(keyword)
	if len(results) == 0 do return mcp_tool_result(id_val, "no matches")

	b := strings.builder_make(runtime_alloc)
	fmt.sbprintf(&b, "%d results:\n", len(results))
	for r in results {
		fmt.sbprintf(&b, "- %s: %s\n", thought_id_to_hex(r.id), r.description)
	}
	return mcp_tool_result(id_val, strings.to_string(b))
}

mcp_tool_info :: proc(id_val: json.Value) -> string {
	b := strings.builder_make(runtime_alloc)
	fmt.sbprintf(&b, "shard v%s\n", VERSION)
	fmt.sbprintf(&b, "id: %s\n", state.shard_id)
	fmt.sbprintf(&b, "exe: %s\n", state.exe_path)
	fmt.sbprintf(&b, "has data: %v\n", state.blob.has_data)
	if state.blob.has_data {
		s := &state.blob.shard
		fmt.sbprintf(&b, "catalog: %s\n", s.catalog.name)
		fmt.sbprintf(&b, "thoughts: %d processed, %d unprocessed\n",
			len(s.processed), len(s.unprocessed))
	}
	fmt.sbprintf(&b, "has key: %v\n", state.has_key)
	return mcp_tool_result(id_val, strings.to_string(b))
}

daemon_shutdown :: proc() {
	if len(state.working_copy) > 0 && state.working_copy != state.exe_path {
		index_write(state.shard_id, state.working_copy, state.exe_path)
		log.infof(
			"Index updated: %s -> %s (prev: %s)",
			state.shard_id,
			state.working_copy,
			state.exe_path,
		)
	}
	log.infof("Shard daemon stopped: %s", state.exe_path)
}

main :: proc() {
	startup()
	context.logger = multi_logger
	defer shutdown()

	log.infof("shard v%s started from %s (id: %s)", VERSION, state.exe_path, state.shard_id)

	state.command = parse_args()

	switch state.command {
	case .Help:
		help := HELP_TEXT[.Help]
		fmt.print(help[int(state.ai_mode)])
	case .Version:
		if state.ai_mode {
			fmt.println("shard", VERSION)
		} else {
			fmt.println("shard v" + VERSION)
		}
	case .Info:
		info_help := HELP_TEXT[.Info]
		if state.ai_mode {
			fmt.print(info_help[int(state.ai_mode)])
		} else {
			fmt.println("shard v" + VERSION)
			fmt.println("exe path:    ", state.exe_path)
			fmt.println("shard id:    ", state.shard_id)
			fmt.println("exe code:    ", len(state.blob.exe_code), "bytes")
			fmt.println("has data:    ", state.blob.has_data)
			if state.blob.has_data {
				s := &state.blob.shard
				fmt.printfln(
					"catalog:      name=%s purpose=%s tags=%d",
					s.catalog.name,
					s.catalog.purpose,
					len(s.catalog.tags),
				)
				fmt.printfln(
					"gates:        accept=%d reject=%d",
					len(s.gates.accept),
					len(s.gates.reject),
				)
				fmt.printfln(
					"thoughts:     processed=%d unprocessed=%d",
					len(s.processed),
					len(s.unprocessed),
				)
				fmt.println("manifest:    ", len(s.manifest), "bytes")
			}
			fmt.println("index dir:   ", state.index_dir)
			peers := index_list()
			fmt.println("known shards:", len(peers))
			for p in peers {
				fmt.printfln("  - %s -> %s", p.shard_id, p.exe_path)
			}
		}
	case .Mcp:
		mcp_run()
	case .Daemon, .None:
		daemon_run()
		defer daemon_shutdown()
	}
}
