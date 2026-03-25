package shard

import "core:bytes"
import "core:c"
import "core:crypto"
import "core:crypto/chacha20poly1305"
import "core:crypto/hash"
import "core:crypto/hkdf"
import "core:encoding/endian"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:math"
import "core:mem"
import "core:os"
import "core:os/os2"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"
import "core:time"
import "core:unicode"

VERSION :: "0.1.0"
SHARD_MAGIC :: u64(0x5348524430303036)
SHARD_MAGIC_SIZE :: 8
SHARD_HASH_SIZE :: 32
SHARD_FOOTER_SIZE :: SHARD_MAGIC_SIZE + SHARD_HASH_SIZE + 4
SHARDS_DIR :: ".shards"
CONFIG_FILE :: "_config.jsonc"
INDEX_DIR :: "index"
RUN_DIR :: "run"
DEFAULT_IDLE_TIMEOUT_MS :: 30_000
DEFAULT_HTTP_PORT :: 8080
DEFAULT_MAX_THOUGHTS :: 10_000
LOG_FILE :: "shard.log"
RUNTIME_ARENA_SIZE :: 64 * mem.Megabyte
REQUEST_ARENA_SIZE :: 1 * mem.Megabyte
LISTEN_BACKLOG :: 128
GATE_ACCEPT_THRESHOLD :: 0.7
GATE_REJECT_THRESHOLD :: 0.3
LLM_TIMEOUT_SECONDS :: "120"
HTTP_READ_BUF :: 8192
MCP_READ_BUF :: 65536
STR8_MAX_LEN :: 255
BODY_SEPARATOR :: "\n---\n"
HEX_CHARS :: "0123456789abcdef"

HELP_TEXT :: [Command][2]string {
	.Help    = {string(#load("help/help.txt")), string(#load("help/help.ai.txt"))},
	.Daemon  = {string(#load("help/daemon.txt")), string(#load("help/daemon.ai.txt"))},
	.Version = {string(#load("help/version.txt")), string(#load("help/version.ai.txt"))},
	.Info    = {string(#load("help/info.txt")), string(#load("help/info.ai.txt"))},
	.Mcp     = {string(#load("help/daemon.txt")), string(#load("help/daemon.ai.txt"))},
	.Compact = {string(#load("help/info.txt")), string(#load("help/info.ai.txt"))},
	.Init    = {string(#load("help/info.txt")), string(#load("help/info.ai.txt"))},
	.None    = {string(#load("help/help.txt")), string(#load("help/help.ai.txt"))},
}

Command :: enum {
	None,
	Daemon,
	Mcp,
	Compact,
	Init,
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

Descriptor :: struct {
	format:     string `json:"format"`,
	match_rule: string `json:"match"`,
	structure:  string `json:"structure"`,
	links:      string `json:"links"`,
}

Gates :: struct {
	gate:           string,
	gate_embedding: []f64,
	descriptors:    []Descriptor,
	intake_prompt:  string,
	shard_links:    []string,
}

Config :: struct {
	llm_url:         string `json:"llm_url"`,
	llm_key:         string `json:"llm_key"`,
	llm_model:       string `json:"llm_model"`,
	embed_model:     string `json:"embed_model"`,
	shard_key:       string `json:"shard_key"`,
	idle_timeout_ms: int `json:"idle_timeout_ms"`,
	http_port:       int `json:"http_port"`,
	max_thoughts:    int `json:"max_thoughts"`,
	shard_dir:       string `json:"shard_dir"`,
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

Cache_Entry :: struct {
	value:   string `json:"value"`,
	author:  string `json:"author"`,
	expires: string `json:"expires"`,
}

Split_State :: struct {
	active:  bool,
	topic_a: string,
	topic_b: string,
	label:   string,
}

IPC_Listener :: struct {
	fd:   posix.FD,
	path: string,
}

IPC_Conn :: struct {
	fd: posix.FD,
}

IPC_Result :: enum {
	Ok,
	Timeout,
	Error,
}

Vec_Entry :: struct {
	id:        Thought_ID,
	desc:      string,
	embedding: []f64,
}

MSG_MAX_SIZE :: 16 * 1024 * 1024

State :: struct {
	exe_path:     string,
	exe_dir:      string,
	shards_dir:   string,
	shard_id:     string,
	index_dir:    string,
	run_dir:      string,
	working_copy: string,
	command:      Command,
	ai_mode:      bool,
	config:       Config,
	blob:         Blob,
	key:          Key,
	has_key:      bool,
	idle_timeout: int,
	http_port:    int,
	max_thoughts: int,
	llm_url:      string,
	llm_key:      string,
	llm_model:    string,
	has_llm:      bool,
	embed_model:  string,
	has_embed:    bool,
	vec_index:    [dynamic]Vec_Entry,
	topic_cache:  map[string]Cache_Entry,
	cache_dir:    string,
	cache_key_fallback: Key,
	has_cache_key_fallback: bool,
}

state: ^State
runtime_arena: ^mem.Arena
runtime_alloc: mem.Allocator
console_logger: log.Logger
file_logger: log.Logger
multi_logger: log.Logger
log_file_handle: os.Handle

logger_init :: proc(use_stderr: bool = false) {
	log_file_handle = os.INVALID_HANDLE
	if use_stderr {
		console_logger = log.create_file_logger(os.stderr, .Debug)
	} else {
		console_logger = log.create_console_logger(.Debug)
	}

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
	mem.arena_init(runtime_arena, make([]byte, RUNTIME_ARENA_SIZE))
	runtime_alloc = mem.arena_allocator(runtime_arena)

	state = new(State, runtime_alloc)
	state.topic_cache.allocator = runtime_alloc

	exe_path, exe_err := os2.get_executable_path(runtime_alloc)
	if exe_err != nil do shutdown(1)
	state.exe_path = exe_path
	state.exe_dir = filepath.dir(exe_path, runtime_alloc)

	is_mcp := false
	for arg in os.args[1:] {if arg == "--mcp" {is_mcp = true; break}}
	logger_init(is_mcp)

	home := os.get_env("HOME", runtime_alloc)
	if len(home) == 0 do shutdown(1)
	state.shards_dir = filepath.join({home, SHARDS_DIR}, runtime_alloc)
	state.index_dir = filepath.join({state.shards_dir, INDEX_DIR}, runtime_alloc)
	state.run_dir = filepath.join({state.shards_dir, RUN_DIR}, runtime_alloc)
	data_dir := os.get_env("SHARD_DATA", runtime_alloc)
	if len(data_dir) == 0 do data_dir = state.shards_dir
	state.cache_dir = filepath.join({data_dir, "cache"}, runtime_alloc)

	load_config()
	blob_read_self()
	load_key()
	congestion_replay()
	load_llm_config()

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
	vec_load_from_manifest(&state.blob.shard)
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
	vec_save_to_manifest(s)
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
	os2.chmod(
		target,
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

	log.infof("Wrote shard data to %s (%d bytes)", target, total)
	return true
}

congestion_append :: proc(thought_blob: []u8) -> bool {
	target := state.working_copy if len(state.working_copy) > 0 else state.exe_path
	fd, err := os.open(target, os.O_WRONLY | os.O_APPEND)
	if err != nil do return false
	defer os.close(fd)
	size_buf: [4]u8
	endian.put_u32(size_buf[:], .Little, u32(len(thought_blob)))
	os.write(fd, size_buf[:])
	os.write(fd, thought_blob)
	return true
}

congestion_replay :: proc() {
	target := state.working_copy if len(state.working_copy) > 0 else state.exe_path
	raw, ok := os.read_entire_file(target, runtime_alloc)
	if !ok || len(raw) < SHARD_FOOTER_SIZE + SHARD_MAGIC_SIZE do return

	magic_end := len(raw)
	for magic_end > SHARD_MAGIC_SIZE {
		val, val_ok := endian.get_u64(raw[magic_end - SHARD_MAGIC_SIZE:], .Little)
		if val_ok && val == SHARD_MAGIC do break
		magic_end -= 1
	}
	if magic_end <= SHARD_MAGIC_SIZE do return

	pending_start := magic_end
	if pending_start >= len(raw) do return

	pending := raw[pending_start:]
	if len(pending) == 0 do return

	s := &state.blob.shard
	pos := 0
	count := 0
	for pos + 4 <= len(pending) {
		size, size_ok := endian.get_u32(pending[pos:pos + 4], .Little)
		if !size_ok do break
		pos += 4
		end := pos + int(size)
		if end > len(pending) do break

		new_unprocessed: [dynamic][]u8
		new_unprocessed.allocator = runtime_alloc
		for entry in s.unprocessed do append(&new_unprocessed, entry)
		blob := make([]u8, size, runtime_alloc)
		copy(blob, pending[pos:end])
		append(&new_unprocessed, blob)
		s.unprocessed = new_unprocessed[:]

		pos = end
		count += 1
	}

	if count > 0 {
		if !state.blob.has_data do state.blob.has_data = true
		blob_write_self()
		log.infof("Congestion replay: merged %d pending thoughts", count)
	}
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

Gates_JSON :: struct {
	gate:          string `json:"gate"`,
	descriptors:   []Descriptor_JSON `json:"descriptors"`,
	intake_prompt: string `json:"intake_prompt"`,
	shard_links:   []string `json:"links"`,
}

Descriptor_JSON :: struct {
	format:     string `json:"format"`,
	match_rule: string `json:"match"`,
	structure:  string `json:"structure"`,
	links:      string `json:"links"`,
}

gates_serialize :: proc(g: ^Gates) -> string {
	gj := Gates_JSON {
		gate          = g.gate,
		intake_prompt = g.intake_prompt,
		shard_links   = g.shard_links,
	}
	if len(g.descriptors) > 0 {
		dj := make([]Descriptor_JSON, len(g.descriptors), runtime_alloc)
		for d, i in g.descriptors {
			dj[i] = Descriptor_JSON {
				format     = d.format,
				match_rule = d.match_rule,
				structure  = d.structure,
				links      = d.links,
			}
		}
		gj.descriptors = dj
	}
	data, err := json.marshal(gj, allocator = runtime_alloc)
	if err != nil do return "{}"
	return string(data)
}

gates_parse :: proc(data: []u8) -> Gates {
	g: Gates
	if len(data) == 0 do return g

	gj: Gates_JSON
	if json.unmarshal(data, &gj, allocator = runtime_alloc) != nil {
		g.gate = string(data)
		return g
	}

	g.gate = gj.gate
	g.intake_prompt = gj.intake_prompt
	g.shard_links = gj.shard_links

	if len(gj.descriptors) > 0 {
		descs := make([]Descriptor, len(gj.descriptors), runtime_alloc)
		for d, i in gj.descriptors {
			descs[i] = Descriptor {
				format     = d.format,
				match_rule = d.match_rule,
				structure  = d.structure,
				links      = d.links,
			}
		}
		g.descriptors = descs
	}

	return g
}

gates_embed :: proc(g: ^Gates) {
	if !state.has_embed || len(g.gate) == 0 do return
	embedding, ok := embed_text(g.gate)
	if ok do g.gate_embedding = embedding
}

Gate_Result :: enum {
	Accept,
	Reject,
	No_Match,
}

gates_check :: proc(g: ^Gates, description: string, content: string) -> Gate_Result {
	if len(g.gate) == 0 do return .No_Match

	if len(g.gate_embedding) > 0 && state.has_embed {
		text := strings.concatenate({description, " ", content}, runtime_alloc)
		text_vec, ok := embed_text(text)
		if ok {
			similarity := cosine_similarity(g.gate_embedding, text_vec)
			if similarity > GATE_ACCEPT_THRESHOLD do return .Accept
			if similarity < GATE_REJECT_THRESHOLD do return .Reject
		}
	}

	lower_gate := strings.to_lower(g.gate, runtime_alloc)
	lower_text := strings.to_lower(
		strings.concatenate({description, " ", content}, runtime_alloc),
		runtime_alloc,
	)
	words := strings.split(lower_gate, " ", allocator = runtime_alloc)
	for word in words {
		trimmed := strings.trim_space(word)
		if len(trimmed) >= 3 && strings.contains(lower_text, trimmed) {
			return .Accept
		}
	}

	return .No_Match
}

gates_describe_for_llm :: proc(g: ^Gates) -> string {
	b := strings.builder_make(runtime_alloc)
	if len(g.gate) > 0 {
		fmt.sbprintf(&b, "Gate: %s\n", g.gate)
	}
	for d, i in g.descriptors {
		fmt.sbprintf(&b, "\nDescriptor %d:\n", i + 1)
		if len(d.format) > 0 do fmt.sbprintf(&b, "  Format: %s\n", d.format)
		if len(d.match_rule) > 0 do fmt.sbprintf(&b, "  Match: %s\n", d.match_rule)
		if len(d.structure) > 0 do fmt.sbprintf(&b, "  Structure: %s\n", d.structure)
		if len(d.links) > 0 do fmt.sbprintf(&b, "  Links: %s\n", d.links)
	}
	if len(g.intake_prompt) > 0 {
		fmt.sbprintf(&b, "\nIntake: %s\n", g.intake_prompt)
	}
	if len(g.shard_links) > 0 {
		fmt.sbprintf(
			&b,
			"Linked shards: %s\n",
			strings.join(g.shard_links, ", ", allocator = runtime_alloc),
		)
	}
	return strings.to_string(b)
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

			desc, content, decrypt_ok := thought_decrypt(state.key, &t)
			if !decrypt_ok do continue

			lower_desc := strings.to_lower(desc, runtime_alloc)
			lower_content := strings.to_lower(content, runtime_alloc)
			if strings.contains(lower_desc, needle) || strings.contains(lower_content, needle) {
				append(&results, Query_Result{id = t.id, description = desc, score = 1})
			}
		}
	}
	return results[:]
}

compact :: proc() -> bool {
	congestion_replay()
	s := &state.blob.shard
	if len(s.unprocessed) == 0 {
		log.info("Nothing to compact")
		return true
	}

	merged := make([dynamic][]u8, len(s.processed), runtime_alloc)
	for entry in s.processed do append(&merged, entry)
	for entry in s.unprocessed do append(&merged, entry)

	s.processed = merged[:]
	s.unprocessed = nil

	if !blob_write_self() {
		log.error("Failed to persist compaction")
		return false
	}

	log.infof("Compacted: %d thoughts now processed", len(s.processed))
	emit_event(.Compact, fmt.aprintf("%d", len(s.processed), allocator = runtime_alloc))
	return true
}


Init_Descriptor :: struct {
	name:          string `json:"name"`,
	purpose:       string `json:"purpose"`,
	tags:          []string `json:"tags"`,
	gate:          string `json:"gate"`,
	descriptors:   []Descriptor_JSON `json:"descriptors"`,
	intake_prompt: string `json:"intake_prompt"`,
	links:         []string `json:"links"`,
}

shard_init :: proc() -> bool {
	args := os.args[1:]
	init_path := ""
	found_init := false
	for arg in args {
		if found_init {
			init_path = arg
			break
		}
		if arg == "--init" do found_init = true
	}

	if len(init_path) == 0 {
		log.error("--init requires a descriptor JSON file path")
		return false
	}

	raw, ok := os.read_entire_file(init_path, runtime_alloc)
	if !ok {
		log.errorf("Failed to read descriptor: %s", init_path)
		return false
	}

	cleaned := strip_jsonc_comments(string(raw))
	desc: Init_Descriptor
	if json.unmarshal(transmute([]u8)cleaned, &desc, allocator = runtime_alloc) != nil {
		log.errorf("Failed to parse descriptor JSON: %s", init_path)
		return false
	}

	s := &state.blob.shard
	if len(desc.name) > 0 do s.catalog.name = desc.name
	if len(desc.purpose) > 0 do s.catalog.purpose = desc.purpose
	if len(desc.tags) > 0 do s.catalog.tags = desc.tags

	g := &s.gates
	if len(desc.gate) > 0 do g.gate = desc.gate
	if len(desc.intake_prompt) > 0 do g.intake_prompt = desc.intake_prompt
	if len(desc.links) > 0 do g.shard_links = desc.links

	if len(desc.descriptors) > 0 {
		descs := make([]Descriptor, len(desc.descriptors), runtime_alloc)
		for d, i in desc.descriptors {
			descs[i] = Descriptor {
				format     = d.format,
				match_rule = d.match_rule,
				structure  = d.structure,
				links      = d.links,
			}
		}
		g.descriptors = descs
	}

	gates_embed(g)

	if !state.blob.has_data do state.blob.has_data = true
	state.shard_id = resolve_shard_id()

	if !blob_write_self() {
		log.error("Failed to persist descriptor")
		return false
	}

	index_write(state.shard_id, state.exe_path)
	log.infof("Initialized shard '%s' from %s", desc.name, init_path)
	return true
}


cache_load :: proc() {
	ensure_dir(state.cache_dir)
	dh, err := os.open(state.cache_dir)
	if err != nil do return
	defer os.close(dh)

	entries, _ := os.read_dir(dh, -1, runtime_alloc)
	now := now_rfc3339()
	for entry in entries {
		if entry.is_dir do continue
		path := filepath.join({state.cache_dir, entry.name}, runtime_alloc)
		raw, ok := os.read_entire_file(path, runtime_alloc)
		if !ok do continue
		lines := strings.split(string(raw), "\n", allocator = runtime_alloc)
		if len(lines) < 1 do continue
		v := lines[0]
		a := lines[1] if len(lines) > 1 else ""
		e := lines[2] if len(lines) > 2 else ""
		if len(e) > 0 && e < now {
			os.remove(path)
			continue
		}
		state.topic_cache[strings.clone(entry.name, runtime_alloc)] = Cache_Entry {
			value   = strings.clone(v, runtime_alloc),
			author  = strings.clone(a, runtime_alloc),
			expires = strings.clone(e, runtime_alloc),
		}
	}
}

cache_save :: proc() {
	ensure_dir(state.cache_dir)
	for key, entry in state.topic_cache {
		cache_save_key(key, entry)
	}
}

cache_save_key :: proc(key: string, entry: Cache_Entry) {
	ensure_dir(state.cache_dir)
	path := filepath.join({state.cache_dir, key}, runtime_alloc)
	content := strings.concatenate(
		{entry.value, "\n", entry.author, "\n", entry.expires},
		runtime_alloc,
	)
	os.write_entire_file(path, transmute([]u8)content)
}

cache_delete_key :: proc(key: string) {
	path := filepath.join({state.cache_dir, key}, runtime_alloc)
	os.remove(path)
	delete_key(&state.topic_cache, key)
}

legacy_answer_cache_key :: proc(question: string) -> string {
	return fmt.aprintf("answer:%s", question, allocator = runtime_alloc)
}

split_state_cache_key :: proc() -> string {
	return opaque_cache_key("split-state", state.shard_id)
}

legacy_split_state_cache_key :: proc() -> string {
	return fmt.aprintf("%s_split_state", state.shard_id, allocator = runtime_alloc)
}

split_state_normalized_value :: proc(state_in: Split_State) -> string {
	b := strings.builder_make(runtime_alloc)
	strings.write_string(&b, `{"active":`)
	if state_in.active {
		strings.write_string(&b, "true")
	} else {
		strings.write_string(&b, "false")
	}
	if len(state_in.topic_a) > 0 {
		fmt.sbprintf(&b, `,"topic_a":"%s"`, mcp_json_escape(state_in.topic_a))
	}
	if len(state_in.topic_b) > 0 {
		fmt.sbprintf(&b, `,"topic_b":"%s"`, mcp_json_escape(state_in.topic_b))
	}
	label := state_in.label
	if len(strings.trim_space(label)) == 0 {
		label = "auto split state"
	}
	fmt.sbprintf(&b, `,"label":"%s"}`, mcp_json_escape(label))
	return strings.to_string(b)
}

split_state_from_entry :: proc(entry: Cache_Entry) -> (Split_State, bool) {
	raw := strings.trim_space(entry.value)
	if raw == "active" {
		return Split_State {
			active = true,
			label = "auto split state",
		}, true
	}
	if len(raw) == 0 || raw[0] != '{' do return {}, false

	parsed, err := json.parse(transmute([]u8)raw, allocator = runtime_alloc)
	if err != nil do return {}, false
	obj, ok := parsed.(json.Object)
	if !ok do return {}, false

	result := Split_State {}
	if active, active_ok := obj["active"].(json.Boolean); active_ok {
		result.active = bool(active)
	}
	if status, status_ok := obj["status"].(json.String); status_ok {
		if strings.to_lower(strings.trim_space(status), runtime_alloc) == "active" {
			result.active = true
		}
	}
	if topic_a, topic_a_ok := obj["topic_a"].(json.String); topic_a_ok {
		result.topic_a = strings.clone(topic_a, runtime_alloc)
	}
	if topic_b, topic_b_ok := obj["topic_b"].(json.String); topic_b_ok {
		result.topic_b = strings.clone(topic_b, runtime_alloc)
	}
	if label, label_ok := obj["label"].(json.String); label_ok {
		result.label = strings.clone(strings.trim_space(label), runtime_alloc)
	}
	if len(result.label) == 0 && result.active {
		result.label = "auto split state"
	}
	if result.active || len(result.topic_a) > 0 || len(result.topic_b) > 0 || len(result.label) > 0 {
		return result, true
	}
	return {}, false
}

cache_load_split_state :: proc() -> (Split_State, bool) {
	new_key := split_state_cache_key()
	if entry, found := state.topic_cache[new_key]; found {
		return split_state_from_entry(entry)
	}

	legacy_key := legacy_split_state_cache_key()
	if entry, found := state.topic_cache[legacy_key]; found {
		normalized, normalized_ok := split_state_from_entry(entry)
		migrated := entry
		if normalized_ok {
			migrated.value = split_state_normalized_value(normalized)
		}
		state.topic_cache[strings.clone(new_key, runtime_alloc)] = Cache_Entry {
			value   = strings.clone(migrated.value, runtime_alloc),
			author  = strings.clone(migrated.author, runtime_alloc),
			expires = strings.clone(migrated.expires, runtime_alloc),
		}
		cache_save_key(new_key, migrated)
		cache_delete_key(legacy_key)
		if normalized_ok {
			return normalized, true
		}
	}
	return {}, false
}

cache_label_from_structured_value :: proc(value: string) -> (string, bool) {
	raw := strings.trim_space(value)
	if len(raw) == 0 || raw[0] != '{' do return "", false
	parsed, err := json.parse(transmute([]u8)raw, allocator = runtime_alloc)
	if err != nil do return "", false
	obj, ok := parsed.(json.Object)
	if !ok do return "", false
	for field in [4]string{"label", "topic", "name", "title"} {
		if s, ok := obj[field].(json.String); ok {
			clean := strings.trim_space(s)
			if len(clean) > 0 do return strings.clone(clean, runtime_alloc), true
		}
	}
	return "", false
}

cache_safe_label :: proc(entry: Cache_Entry) -> string {
	if split_state, ok := split_state_from_entry(entry); ok {
		if len(split_state.label) > 0 do return split_state.label
		if split_state.active do return "auto split state"
	}
	if label, ok := cache_label_from_structured_value(entry.value); ok do return label
	if entry.author == "llm" do return "cached answer"
	return "cache entry"
}

build_context :: proc(question: string) -> string {
	if !state.has_key do return ""

	s := &state.blob.shard
	if len(s.processed) == 0 && len(s.unprocessed) == 0 do return ""

	cache_load()

	b := strings.builder_make(runtime_alloc)

	if len(state.topic_cache) > 0 {
		strings.write_string(&b, "## Active Topics\n\n")
		for _, entry in state.topic_cache {
			label := cache_safe_label(entry)
			if len(entry.author) > 0 {
				fmt.sbprintf(&b, "- **%s**: %s [%s]\n", label, entry.value, entry.author)
			} else {
				fmt.sbprintf(&b, "- **%s**: %s\n", label, entry.value)
			}
		}
		strings.write_string(&b, "\n")
	}

	if len(s.catalog.name) > 0 {
		fmt.sbprintf(&b, "## Shard: %s\n\n%s\n\n", s.catalog.name, s.catalog.purpose)
	}

	words := strings.split(
		strings.to_lower(question, runtime_alloc),
		" ",
		allocator = runtime_alloc,
	)
	seen: map[Thought_ID]bool
	seen.allocator = runtime_alloc
	matched: [dynamic]Query_Result
	matched.allocator = runtime_alloc
	for word in words {
		clean := strings.trim(strings.trim_space(word), "?!.,;:\"'()[]{}")
		if len(clean) < 3 do continue
		for r in query_thoughts(clean) {
			if r.id not_in seen {
				seen[r.id] = true
				append(&matched, r)
			}
		}
	}

	if len(matched) > 0 {
		for r in matched {
			_, content, ok := read_thought(r.id)
			if !ok do continue
			fmt.sbprintf(&b, "### %s\n\n%s\n\n", r.description, content)
		}
	} else {
		for block in ([2][][]u8{s.processed, s.unprocessed}) {
			for blob in block {
				pos := 0
				t, ok := thought_parse(blob, &pos)
				if !ok do continue
				desc, content, decrypt_ok := thought_decrypt(state.key, &t)
				if !decrypt_ok do continue
				fmt.sbprintf(&b, "### %s\n\n%s\n\n", desc, content)
			}
		}
	}

	return strings.to_string(b)
}

Event_Kind :: enum {
	Write,
	Compact,
	Gate_Change,
}

emit_event :: proc(kind: Event_Kind, detail: string) {
	peers := index_list()
	if len(peers) <= 1 do return

	b := strings.builder_make(runtime_alloc)
	kind_str: string
	switch kind {
	case .Write:
		kind_str = "write"
	case .Compact:
		kind_str = "compact"
	case .Gate_Change:
		kind_str = "gate_change"
	}
	fmt.sbprintf(
		&b,
		`{{"event":"%s","shard":"%s","detail":"%s"}}`,
		kind_str,
		mcp_json_escape(state.shard_id),
		mcp_json_escape(detail),
	)
	msg := transmute([]u8)strings.to_string(b)

	for peer in peers {
		if peer.shard_id == state.shard_id do continue
		conn, ok := ipc_connect(ipc_socket_path(peer.shard_id))
		if !ok do continue
		ipc_send_msg(conn, msg)
		ipc_close(conn)
	}
}

Fleet_Result :: struct {
	shard_id: string,
	response: string,
	ok:       bool,
}

fleet_ask :: proc(question: string) -> string {
	if !state.has_llm do return "no LLM configured"

	peers := index_list()
	answers: [dynamic]string
	answers.allocator = runtime_alloc

	local_ctx := build_context(question)
	if len(local_ctx) > 0 {
		answer, ok := shard_ask(question)
		if ok {
			append(
				&answers,
				fmt.aprintf("[%s] %s", state.shard_id, answer, allocator = runtime_alloc),
			)
		}
	}

	lower_q := strings.to_lower(question, runtime_alloc)
	for peer in peers {
		if peer.shard_id == state.shard_id do continue

		raw, read_ok := os.read_entire_file(peer.exe_path, runtime_alloc)
		if !read_ok do continue

		peer_blob := load_blob_from_raw(raw)
		if !peer_blob.has_data do continue

		cat_name := strings.to_lower(peer_blob.shard.catalog.name, runtime_alloc)
		cat_purpose := strings.to_lower(peer_blob.shard.catalog.purpose, runtime_alloc)
		catalog_relevant := false
		for word in strings.split(lower_q, " ", allocator = runtime_alloc) {
			w := strings.trim(strings.trim_space(word), "?!.,")
			if len(w) >= 3 && (strings.contains(cat_name, w) || strings.contains(cat_purpose, w)) {
				catalog_relevant = true
				break
			}
		}
		if !catalog_relevant && len(cat_name) > 0 do continue

		peer_ctx := build_context_from_blob(&peer_blob, question)
		if len(peer_ctx) == 0 do continue

		system := fmt.aprintf(
			"You are a knowledge assistant. Answer based ONLY on the context below. Be concise. If the context doesn't contain the answer, say so.\n\n%s",
			peer_ctx,
			allocator = runtime_alloc,
		)

		answer, ok := llm_chat(system, question)
		if ok &&
		   !strings.contains(answer, "don't have") &&
		   !strings.contains(answer, "no information") &&
		   !strings.contains(answer, "not provided") {
			append(
				&answers,
				fmt.aprintf("[%s] %s", peer.shard_id, answer, allocator = runtime_alloc),
			)
		}
	}

	if len(answers) == 0 do return "no shard had relevant knowledge"
	return strings.join(answers[:], "\n\n", allocator = runtime_alloc)
}

load_peer_blob :: proc(shard_id: string) -> (Blob, bool) {
	peers := index_list()
	for peer in peers {
		if peer.shard_id == shard_id {
			raw, ok := os.read_entire_file(peer.exe_path, runtime_alloc)
			if !ok do return {}, false
			blob := load_blob_from_raw(raw)
			return blob, blob.has_data
		}
	}
	return {}, false
}

query_peer :: proc(shard_id: string, keyword: string) -> []Query_Result {
	blob, ok := load_peer_blob(shard_id)
	if !ok do return {}
	return query_blob(&blob, keyword)
}

query_blob :: proc(b: ^Blob, keyword: string) -> []Query_Result {
	if !state.has_key do return {}
	needle := strings.to_lower(keyword, runtime_alloc)
	results: [dynamic]Query_Result
	results.allocator = runtime_alloc

	s := &b.shard
	for block in ([2][][]u8{s.processed, s.unprocessed}) {
		for blob in block {
			pos := 0
			t, parse_ok := thought_parse(blob, &pos)
			if !parse_ok do continue
			desc, content, decrypt_ok := thought_decrypt(state.key, &t)
			if !decrypt_ok do continue
			lower_desc := strings.to_lower(desc, runtime_alloc)
			lower_content := strings.to_lower(content, runtime_alloc)
			if strings.contains(lower_desc, needle) || strings.contains(lower_content, needle) {
				append(&results, Query_Result{id = t.id, description = desc, score = 1})
			}
		}
	}
	return results[:]
}

ask_peer :: proc(shard_id: string, question: string) -> (string, bool) {
	if !state.has_llm do return "no LLM configured", false

	blob, ok := load_peer_blob(shard_id)
	if !ok do return "shard not found", false

	ctx := build_context_from_blob(&blob, question)
	if len(ctx) == 0 do return "no relevant knowledge", false

	system := fmt.aprintf(
		"You are a knowledge assistant. Answer based ONLY on the context below. Be concise. If the context doesn't contain the answer, say so.\n\n%s",
		ctx,
		allocator = runtime_alloc,
	)
	return llm_chat(system, question)
}

load_blob_from_raw :: proc(raw: []u8) -> Blob {
	if len(raw) < SHARD_FOOTER_SIZE do return {}

	magic, magic_ok := endian.get_u64(raw[len(raw) - SHARD_MAGIC_SIZE:], .Little)
	if !magic_ok || magic != SHARD_MAGIC do return {}

	data_size, ds_ok := block_read_u32(raw, len(raw) - SHARD_FOOTER_SIZE)
	if !ds_ok do return {}

	total_appended := int(data_size) + SHARD_FOOTER_SIZE
	if total_appended > len(raw) do return {}

	split := len(raw) - total_appended
	data := raw[split:split + int(data_size)]
	shard := shard_data_parse(data)

	return Blob{exe_code = raw[:split], shard = shard, has_data = true}
}

build_context_from_blob :: proc(b: ^Blob, question: string) -> string {
	if !state.has_key do return ""
	s := &b.shard
	if len(s.processed) == 0 && len(s.unprocessed) == 0 do return ""

	out := strings.builder_make(runtime_alloc)
	if len(s.catalog.name) > 0 {
		fmt.sbprintf(&out, "## Shard: %s\n\n%s\n\n", s.catalog.name, s.catalog.purpose)
	}

	for block in ([2][][]u8{s.processed, s.unprocessed}) {
		for blob in block {
			pos := 0
			t, ok := thought_parse(blob, &pos)
			if !ok do continue
			desc, content, decrypt_ok := thought_decrypt(state.key, &t)
			if !decrypt_ok do continue
			fmt.sbprintf(&out, "### %s\n\n%s\n\n", desc, content)
		}
	}

	return strings.to_string(out)
}

fleet_query :: proc(keyword: string) -> []Fleet_Result {
	peers := index_list()
	results: [dynamic]Fleet_Result
	results.allocator = runtime_alloc

	for peer in peers {
		if peer.shard_id == state.shard_id do continue
		sock_path := ipc_socket_path(peer.shard_id)
		conn, conn_ok := ipc_connect(sock_path)
		if !conn_ok {
			append(&results, Fleet_Result{shard_id = peer.shard_id, ok = false})
			continue
		}
		defer ipc_close(conn)

		msg := fmt.aprintf(
			`{{"method":"query","keyword":"%s"}}`,
			mcp_json_escape(keyword),
			allocator = runtime_alloc,
		)
		if !ipc_send_msg(conn, transmute([]u8)msg) {
			append(&results, Fleet_Result{shard_id = peer.shard_id, ok = false})
			continue
		}

		resp, recv_ok := ipc_recv_msg(conn)
		append(
			&results,
			Fleet_Result {
				shard_id = peer.shard_id,
				response = string(resp) if recv_ok else "",
				ok = recv_ok,
			},
		)
	}
	return results[:]
}

create_shard :: proc(name: string, purpose: string) -> bool {
	data_dir := os.get_env("SHARD_DATA", runtime_alloc)
	shard_dir := state.run_dir
	if len(data_dir) > 0 {
		shard_dir = filepath.join({data_dir, "shards"}, runtime_alloc)
	}
	ensure_dir(shard_dir)

	new_id := slugify(name)
	new_path := filepath.join({shard_dir, new_id}, runtime_alloc)

	if !os.write_entire_file(new_path, state.blob.exe_code) {
		log.errorf("Failed to create shard binary: %s", new_path)
		return false
	}
	os2.chmod(
		new_path,
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

	catalog_json := fmt.aprintf(
		`{{"name":"%s","purpose":"%s","tags":[],"created":""}}`,
		mcp_json_escape(name),
		mcp_json_escape(purpose),
		allocator = runtime_alloc,
	)

	data_size := 4 + 4 + 4 + len(catalog_json) + 4 + 4
	total := len(state.blob.exe_code) + data_size + SHARD_FOOTER_SIZE
	buf := make([]u8, total, runtime_alloc)

	pos := 0
	copy(buf, state.blob.exe_code)
	pos += len(state.blob.exe_code)

	pos = block_write_u32(buf, pos, 0)
	pos = block_write_u32(buf, pos, 0)
	pos = block_write_bytes(buf, pos, transmute([]u8)catalog_json)
	pos = block_write_bytes(buf, pos, nil)
	pos = block_write_bytes(buf, pos, nil)

	pos = block_write_u32(buf, pos, u32(data_size))

	data_start := len(state.blob.exe_code)
	blob_hash: [32]u8
	hash.hash_bytes_to_buffer(.SHA256, buf[data_start:pos], blob_hash[:])
	copy(buf[pos:pos + SHARD_HASH_SIZE], blob_hash[:])
	pos += SHARD_HASH_SIZE

	endian.put_u64(buf[pos:], .Little, SHARD_MAGIC)

	if !os.write_entire_file(new_path, buf) {
		log.errorf("Failed to write shard data: %s", new_path)
		return false
	}

	index_write(new_id, new_path)
	log.infof("Created shard '%s' at %s", name, new_path)
	return true
}

now_rfc3339 :: proc() -> string {
	now := time.now()
	y, mon, d := time.date(now)
	h, min, s := time.clock(now)
	return fmt.aprintf(
		"%04d-%02d-%02dT%02d:%02d:%02dZ",
		y,
		int(mon),
		d,
		h,
		min,
		s,
		allocator = runtime_alloc,
	)
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

append_raw :: proc(buf: ^[dynamic]u8, data: []u8) {
	for b in data do append(buf, b)
}

append_u32 :: proc(buf: ^[dynamic]u8, val: u32) {
	b: [4]u8
	endian.put_u32(b[:], .Little, val)
	for x in b do append(buf, x)
}

append_str8 :: proc(buf: ^[dynamic]u8, s: string) {
	append(buf, u8(min(len(s), STR8_MAX_LEN)))
	for i in 0 ..< min(len(s), STR8_MAX_LEN) do append(buf, s[i])
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

strip_jsonc_comments :: proc(input: string) -> string {
	b := strings.builder_make(runtime_alloc)
	in_string := false
	i := 0
	for i < len(input) {
		if in_string {
			if input[i] == '\\' && i + 1 < len(input) {
				strings.write_byte(&b, input[i])
				strings.write_byte(&b, input[i + 1])
				i += 2
				continue
			}
			if input[i] == '"' do in_string = false
			strings.write_byte(&b, input[i])
			i += 1
		} else {
			if input[i] == '"' {
				in_string = true
				strings.write_byte(&b, input[i])
				i += 1
			} else if i + 1 < len(input) && input[i] == '/' && input[i + 1] == '/' {
				for i < len(input) && input[i] != '\n' do i += 1
			} else if i + 1 < len(input) && input[i] == '/' && input[i + 1] == '*' {
				i += 2
				for i + 1 < len(input) && !(input[i] == '*' && input[i + 1] == '/') do i += 1
				if i + 1 < len(input) do i += 2
			} else {
				strings.write_byte(&b, input[i])
				i += 1
			}
		}
	}
	return strings.to_string(b)
}

load_config :: proc() {
	state.idle_timeout = DEFAULT_IDLE_TIMEOUT_MS
	state.http_port = DEFAULT_HTTP_PORT
	state.max_thoughts = DEFAULT_MAX_THOUGHTS

	config_path := filepath.join({state.shards_dir, CONFIG_FILE}, runtime_alloc)
	raw, ok := os.read_entire_file(config_path, runtime_alloc)
	if !ok do return

	cleaned := strip_jsonc_comments(string(raw))
	err := json.unmarshal(transmute([]u8)cleaned, &state.config, allocator = runtime_alloc)
	if err != nil {
		log.errorf("Failed to parse config: %s", config_path)
		return
	}

	c := &state.config
	if c.idle_timeout_ms > 0 do state.idle_timeout = c.idle_timeout_ms
	if c.http_port > 0 do state.http_port = c.http_port
	if c.max_thoughts > 0 do state.max_thoughts = c.max_thoughts

	log.infof("Config loaded from %s", config_path)
}

load_key :: proc() {
	key_hex := os.get_env("SHARD_KEY", runtime_alloc)
	if len(key_hex) == 0 do key_hex = state.config.shard_key
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

load_llm_config :: proc() {
	c := &state.config
	state.llm_url = os.get_env("LLM_URL", runtime_alloc)
	if len(state.llm_url) == 0 do state.llm_url = c.llm_url
	state.llm_key = os.get_env("LLM_KEY", runtime_alloc)
	if len(state.llm_key) == 0 do state.llm_key = c.llm_key
	state.llm_model = os.get_env("LLM_MODEL", runtime_alloc)
	if len(state.llm_model) == 0 do state.llm_model = c.llm_model
	state.has_llm = len(state.llm_url) > 0 && len(state.llm_model) > 0
	if state.has_llm {
		log.infof("LLM configured: %s model=%s", state.llm_url, state.llm_model)
	}
	state.embed_model = os.get_env("EMBED_MODEL", runtime_alloc)
	if len(state.embed_model) == 0 do state.embed_model = c.embed_model
	state.has_embed = len(state.llm_url) > 0 && len(state.embed_model) > 0
	state.vec_index.allocator = runtime_alloc
}

embed_text :: proc(text: string) -> ([]f64, bool) {
	if !state.has_embed do return nil, false

	url := strings.concatenate(
		{strings.trim_right(state.llm_url, "/"), "/embeddings"},
		runtime_alloc,
	)

	b := strings.builder_make(runtime_alloc)
	strings.write_string(&b, `{"model":"`)
	strings.write_string(&b, mcp_json_escape(state.embed_model))
	strings.write_string(&b, `","input":"`)
	strings.write_string(&b, mcp_json_escape(text))
	strings.write_string(&b, `"}`)

	cmd: [dynamic]string
	cmd.allocator = runtime_alloc
	append(&cmd, "curl", "-s", "-S", "--max-time", "30", "-X", "POST")
	append(&cmd, "-H", "Content-Type: application/json")
	if len(state.llm_key) > 0 {
		append(
			&cmd,
			"-H",
			fmt.aprintf("Authorization: Bearer %s", state.llm_key, allocator = runtime_alloc),
		)
	}
	append(&cmd, "-d", strings.to_string(b), url)

	result, stdout, _, err := os2.process_exec(os2.Process_Desc{command = cmd[:]}, runtime_alloc)
	if err != nil || result.exit_code != 0 do return nil, false

	parsed, parse_err := json.parse(stdout, allocator = runtime_alloc)
	if parse_err != nil do return nil, false

	obj, _ := parsed.(json.Object)
	data_arr, _ := obj["data"].(json.Array)
	if len(data_arr) == 0 do return nil, false

	first, _ := data_arr[0].(json.Object)
	embedding, _ := first["embedding"].(json.Array)
	if len(embedding) == 0 do return nil, false

	vec := make([]f64, len(embedding), runtime_alloc)
	for v, i in embedding {
		switch n in v {
		case json.Float:
			vec[i] = n
		case json.Integer:
			vec[i] = f64(n)
		case json.Null, json.Boolean, json.String, json.Array, json.Object:
			vec[i] = 0
		}
	}
	return vec, true
}

thought_exists :: proc(description: string) -> bool {
	if !state.has_key do return false
	lower := strings.to_lower(description, runtime_alloc)
	s := &state.blob.shard
	for block in ([2][][]u8{s.processed, s.unprocessed}) {
		for blob in block {
			pos := 0
			t, ok := thought_parse(blob, &pos)
			if !ok do continue
			desc, _, decrypt_ok := thought_decrypt(state.key, &t)
			if !decrypt_ok do continue
			if strings.to_lower(desc, runtime_alloc) == lower do return true
		}
	}
	return false
}

vec_index_thought :: proc(id: Thought_ID, description: string) {
	embedding, ok := embed_text(description)
	if !ok do return
	append(&state.vec_index, Vec_Entry{id = id, desc = description, embedding = embedding})
}

vec_save_to_manifest :: proc(s: ^Shard_Data) {
	if len(state.vec_index) == 0 do return
	b := strings.builder_make(runtime_alloc)
	for entry, i in state.vec_index {
		if i > 0 do strings.write_string(&b, "\n")
		strings.write_string(&b, thought_id_to_hex(entry.id))
		strings.write_string(&b, "\t")
		strings.write_string(&b, entry.desc)
		strings.write_string(&b, "\t")
		for v, j in entry.embedding {
			if j > 0 do strings.write_string(&b, ",")
			fmt.sbprintf(&b, "%.6f", v)
		}
	}
	s.manifest = strings.to_string(b)
}

vec_load_from_manifest :: proc(s: ^Shard_Data) {
	if len(s.manifest) == 0 do return
	lines := strings.split(s.manifest, "\n", allocator = runtime_alloc)
	for line in lines {
		parts := strings.split(line, "\t", allocator = runtime_alloc)
		if len(parts) < 3 do continue
		id, id_ok := hex_to_thought_id(parts[0])
		if !id_ok do continue
		vals := strings.split(parts[2], ",", allocator = runtime_alloc)
		embedding := make([]f64, len(vals), runtime_alloc)
		for v, i in vals {
			f: f64 = 0
			neg := false
			j := 0
			if len(v) > 0 && v[0] == '-' {neg = true; j = 1}
			whole: f64 = 0
			for j < len(v) && v[j] != '.' {
				whole = whole * 10 + f64(v[j] - '0')
				j += 1
			}
			frac: f64 = 0
			scale: f64 = 0.1
			if j < len(v) && v[j] == '.' {
				j += 1
				for j < len(v) {
					frac += f64(v[j] - '0') * scale
					scale *= 0.1
					j += 1
				}
			}
			f = whole + frac
			if neg do f = -f
			embedding[i] = f
		}
		append(
			&state.vec_index,
			Vec_Entry {
				id = id,
				desc = strings.clone(parts[1], runtime_alloc),
				embedding = embedding,
			},
		)
	}
	if len(state.vec_index) > 0 {
		log.infof("Loaded %d vectors from manifest", len(state.vec_index))
	}
}

vec_search :: proc(query: string, top_k: int = 5) -> []Query_Result {
	query_vec, ok := embed_text(query)
	if !ok do return {}

	Scored :: struct {
		id:    Thought_ID,
		desc:  string,
		score: f64,
	}
	scored: [dynamic]Scored
	scored.allocator = runtime_alloc

	for entry in state.vec_index {
		score := cosine_similarity(query_vec, entry.embedding)
		append(&scored, Scored{id = entry.id, desc = entry.desc, score = score})
	}

	for i in 0 ..< len(scored) {
		for j in i + 1 ..< len(scored) {
			if scored[j].score > scored[i].score {
				scored[i], scored[j] = scored[j], scored[i]
			}
		}
	}

	n := min(top_k, len(scored))
	results := make([]Query_Result, n, runtime_alloc)
	for i in 0 ..< n {
		results[i] = Query_Result {
			id          = scored[i].id,
			description = scored[i].desc,
			score       = int(scored[i].score * 1000),
		}
	}
	return results
}

cosine_similarity :: proc(a: []f64, b: []f64) -> f64 {
	if len(a) != len(b) || len(a) == 0 do return 0

	dot: f64 = 0
	mag_a: f64 = 0
	mag_b: f64 = 0
	for i in 0 ..< len(a) {
		dot += a[i] * b[i]
		mag_a += a[i] * a[i]
		mag_b += b[i] * b[i]
	}

	denom := math.sqrt(mag_a) * math.sqrt(mag_b)
	if denom == 0 do return 0
	return dot / denom
}

llm_chat :: proc(system_prompt: string, user_prompt: string) -> (string, bool) {
	if !state.has_llm do return "", false

	url := strings.concatenate(
		{strings.trim_right(state.llm_url, "/"), "/chat/completions"},
		runtime_alloc,
	)

	b := strings.builder_make(runtime_alloc)
	strings.write_string(&b, `{"model":"`)
	strings.write_string(&b, mcp_json_escape(state.llm_model))
	strings.write_string(&b, `","messages":[{"role":"system","content":"`)
	strings.write_string(&b, mcp_json_escape(system_prompt))
	strings.write_string(&b, `"},{"role":"user","content":"`)
	strings.write_string(&b, mcp_json_escape(user_prompt))
	strings.write_string(&b, `"}]}`)

	cmd: [dynamic]string
	cmd.allocator = runtime_alloc
	append(&cmd, "curl", "-s", "-S", "--max-time", LLM_TIMEOUT_SECONDS, "-X", "POST")
	append(&cmd, "-H", "Content-Type: application/json")
	if len(state.llm_key) > 0 {
		append(
			&cmd,
			"-H",
			fmt.aprintf("Authorization: Bearer %s", state.llm_key, allocator = runtime_alloc),
		)
	}
	append(&cmd, "-d", strings.to_string(b), url)

	result, stdout, stderr, err := os2.process_exec(
		os2.Process_Desc{command = cmd[:]},
		runtime_alloc,
	)
	if err != nil {
		log.errorf("LLM curl error: %v", err)
		return "", false
	}
	if result.exit_code != 0 {
		log.errorf("LLM curl exit %d: %s", result.exit_code, string(stderr))
		return "", false
	}

	parsed, parse_err := json.parse(stdout, allocator = runtime_alloc)
	if parse_err != nil {
		log.errorf("LLM response parse error: %s", string(stdout[:min(len(stdout), 200)]))
		return "", false
	}

	obj, _ := parsed.(json.Object)
	choices, _ := obj["choices"].(json.Array)
	if len(choices) == 0 do return "", false
	first, _ := choices[0].(json.Object)
	message, _ := first["message"].(json.Object)
	content, _ := message["content"].(json.String)
	return strings.clone(content, runtime_alloc), true
}

shard_ask :: proc(question: string) -> (string, bool) {
	if !state.has_llm do return "no LLM configured (set LLM_URL, LLM_KEY, LLM_MODEL)", false

	cache_load()
	cache_key := opaque_cache_key("answer", question)
	if cached, found := state.topic_cache[cache_key]; found {
		log.info("Cache hit for question")
		return cached.value, true
	}
	legacy_key := legacy_answer_cache_key(question)
	if cached, found := state.topic_cache[legacy_key]; found {
		state.topic_cache[strings.clone(cache_key, runtime_alloc)] = Cache_Entry {
			value   = strings.clone(cached.value, runtime_alloc),
			author  = strings.clone(cached.author, runtime_alloc),
			expires = strings.clone(cached.expires, runtime_alloc),
		}
		cache_save_key(cache_key, cached)
		cache_delete_key(legacy_key)
		log.info("Cache hit for question (legacy key migrated)")
		return cached.value, true
	}

	ctx := build_context(question)
	if len(ctx) == 0 {
		log.infof("Shard %s not relevant to: %s", state.shard_id, question)
		return "this shard has no relevant knowledge for that question", false
	}

	related := find_related_shards(question)
	if len(related) > 0 {
		ctx = strings.concatenate({ctx, "\n## Related Shards\n\n", related}, runtime_alloc)
	}

	log.infof("Shard %s is relevant, %d bytes of context", state.shard_id, len(ctx))

	system := fmt.aprintf(
		"You are a knowledge assistant. Answer based ONLY on the context below. Be concise. If the context doesn't contain the answer, say so. If related shards are listed, mention them.\n\n%s",
		ctx,
		allocator = runtime_alloc,
	)

	answer, ok := llm_chat(system, question)
	if ok {
		state.topic_cache[strings.clone(cache_key, runtime_alloc)] = Cache_Entry {
			value   = strings.clone(answer, runtime_alloc),
			author  = "llm",
			expires = "",
		}
		cache_save()
	}
	return answer, ok
}

opaque_cache_key :: proc(namespace: string, raw: string) -> string {
	material := state.key
	if !state.has_key {
		if !state.has_cache_key_fallback {
			fallback: [32]u8
			crypto.rand_bytes(fallback[:])
			state.cache_key_fallback = Key(fallback)
			state.has_cache_key_fallback = true
		}
		material = state.cache_key_fallback
	}

	input := strings.concatenate({namespace, "\x00", raw}, runtime_alloc)
	digest: [32]u8
	m := material
	hkdf.extract_and_expand(.SHA256, nil, m[:], transmute([]u8)input, digest[:])

	h := HEX_CHARS
	buf := make([]u8, 24, runtime_alloc)
	for i in 0 ..< 12 {
		b := digest[i]
		buf[i * 2] = h[b >> 4]
		buf[i * 2 + 1] = h[b & 0x0f]
	}

	return fmt.aprintf("%s:%s", namespace, string(buf), allocator = runtime_alloc)
}

when ODIN_TEST {
	test_opaque_cache_key :: proc() {
		old_has_key := state.has_key
		old_key := state.key
		old_cache_key_fallback := state.cache_key_fallback
		old_has_cache_key_fallback := state.has_cache_key_fallback
		old_cache_dir := state.cache_dir
		old_topic_cache := state.topic_cache
		old_blob := state.blob
		old_shard_id := state.shard_id
		defer {
			state.has_key = old_has_key
			state.key = old_key
			state.cache_key_fallback = old_cache_key_fallback
			state.has_cache_key_fallback = old_has_cache_key_fallback
			state.cache_dir = old_cache_dir
			state.topic_cache = old_topic_cache
			state.blob = old_blob
			state.shard_id = old_shard_id
		}

		question := "How do we rotate API keys safely?"
		key_1, ok_1 := hex_to_key("00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff")
		key_2, ok_2 := hex_to_key("ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100")
		assert(ok_1)
		assert(ok_2)

		state.key = key_1
		state.has_key = true
		state.has_cache_key_fallback = false
		key_a := opaque_cache_key("answer", question)
		key_b := opaque_cache_key("answer", question)
		key_c := opaque_cache_key("answer", "How do we rotate cache salts safely?")
		state.key = key_2
		key_d := opaque_cache_key("answer", question)

		state.has_key = false
		state.has_cache_key_fallback = false
		fallback_a := opaque_cache_key("answer", question)
		fallback_b := opaque_cache_key("answer", question)

		assert(key_a == key_b)
		assert(key_a != key_c)
		assert(key_a != key_d)
		assert(fallback_a == fallback_b)
		assert(strings.has_prefix(key_a, "answer:"))
		assert(len(key_a) == len("answer:") + 24)

		lower_key := strings.to_lower(key_a, runtime_alloc)
		words := strings.split(strings.to_lower(question, runtime_alloc), " ", allocator = runtime_alloc)
		for word in words {
			clean := strings.trim(strings.trim_space(word), "?!.,;:\"'()[]{}")
			if len(clean) < 3 do continue
			assert(!strings.contains(lower_key, clean))
		}

		tmp_name := fmt.aprintf("cache-test-%s", slugify(now_rfc3339()), allocator = runtime_alloc)
		state.cache_dir = filepath.join({state.exe_dir, tmp_name}, runtime_alloc)
		ensure_dir(state.cache_dir)
		cache_save_key(key_a, Cache_Entry{value = "cached", author = "llm", expires = ""})
		dh, dir_err := os.open(state.cache_dir)
		assert(dir_err == nil)
		if dir_err == nil {
			entries, _ := os.read_dir(dh, -1, runtime_alloc)
			os.close(dh)
			for entry in entries {
				lower_name := strings.to_lower(entry.name, runtime_alloc)
				for word in words {
					clean := strings.trim(strings.trim_space(word), "?!.,;:\"'()[]{}")
					if len(clean) < 3 do continue
					assert(!strings.contains(lower_name, clean))
				}
			}
		}
		cache_delete_key(key_a)
		os.remove(state.cache_dir)

		state.topic_cache = make(map[string]Cache_Entry, runtime_alloc)
		state.topic_cache[strings.clone(key_a, runtime_alloc)] = Cache_Entry {
			value   = "cached answer text",
			author  = "llm",
			expires = "",
		}
		state.blob = Blob {
			has_data = true,
			shard = Shard_Data {
				catalog = Catalog{name = "privacy", purpose = "privacy"},
			},
		}
		state.shard_id = "privacy"
		id := new_thought_id()
		body, seal, trust := thought_encrypt(state.key, id, "privacy thought", "details")
		t := Thought {
			id         = id,
			trust      = trust,
			seal_blob  = seal,
			body_blob  = body,
			agent      = "test",
			created_at = now_rfc3339(),
			updated_at = "",
			ttl        = 0,
		}
		buf: [dynamic]u8
		buf.allocator = runtime_alloc
		thought_serialize(&buf, &t)
		state.blob.shard.unprocessed = [][]u8{buf[:]}

		ctx := build_context("privacy")
		assert(!strings.contains(ctx, key_a))
	}
}

find_related_shards :: proc(question: string) -> string {
	peers := index_list()
	if len(peers) <= 1 do return ""

	b := strings.builder_make(runtime_alloc)
	for peer in peers {
		if peer.shard_id == state.shard_id do continue
		raw, ok := os.read_entire_file(peer.exe_path, runtime_alloc)
		if !ok do continue
		blob := load_blob_from_raw(raw)
		if !blob.has_data do continue
		s := &blob.shard
		if len(s.catalog.name) > 0 {
			fmt.sbprintf(&b, "- %s: %s\n", s.catalog.name, s.catalog.purpose)
		}
	}
	return strings.to_string(b)
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

	if thought_exists(description) {
		log.infof("Duplicate thought skipped: %s", description)
		return {}, false
	}

	gate_result := gates_check(&state.blob.shard.gates, description, content)
	if gate_result == .Reject {
		routed_id, routed := route_to_peer(description, content, agent)
		if routed do return routed_id, true
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
		created_at = now_rfc3339(),
		updated_at = "",
		ttl        = 0,
	}

	buf: [dynamic]u8
	buf.allocator = runtime_alloc
	thought_serialize(&buf, &t)

	s := &state.blob.shard
	new_unprocessed: [dynamic][]u8
	was_empty := len(s.unprocessed) <= 1 && len(s.processed) == 0

	new_unprocessed.allocator = runtime_alloc
	for entry in s.unprocessed do append(&new_unprocessed, entry)
	append(&new_unprocessed, buf[:])
	s.unprocessed = new_unprocessed[:]

	if !state.blob.has_data do state.blob.has_data = true

	if len(s.catalog.name) == 0 {
		s.catalog.name = description
		s.catalog.purpose = description
		s.catalog.created = now_rfc3339()
		state.shard_id = resolve_shard_id()
		log.infof("Auto-catalog: %s", s.catalog.name)
	}

	persist_ok := false
	if was_empty {
		persist_ok = blob_write_self()
	} else {
		persist_ok = congestion_append(buf[:])
		if !persist_ok do persist_ok = blob_write_self()
	}
	if !persist_ok {
		log.errorf("Failed to persist thought %s", thought_id_to_hex(id))
		return {}, false
	}

	log.infof("Wrote thought %s (%d bytes body)", thought_id_to_hex(id), len(body_blob))
	emit_event(.Write, thought_id_to_hex(id))
	vec_index_thought(id, description)
	gates_auto_learn(s)
	return id, true
}

gates_auto_learn :: proc(s: ^Shard_Data) {
	thought_count := len(s.processed) + len(s.unprocessed)
	if thought_count < 5 || thought_count % 5 != 0 do return
	if len(s.gates.gate) > 0 do return
	if !state.has_key do return

	descs: [dynamic]string
	descs.allocator = runtime_alloc
	for block in ([2][][]u8{s.processed, s.unprocessed}) {
		for blob in block {
			pos := 0
			t, ok := thought_parse(blob, &pos)
			if !ok do continue
			desc, _, decrypt_ok := thought_decrypt(state.key, &t)
			if !decrypt_ok do continue
			append(&descs, desc)
		}
	}
	if len(descs) == 0 do return

	s.gates.gate = strings.join(descs[:], " ", allocator = runtime_alloc)
	gates_embed(&s.gates)
	log.infof("Auto-learned gate from %d thought descriptions", len(descs))
}

Ingest_Result :: struct {
	description: string,
	content:     string,
	route_to:    string,
}

shard_ingest :: proc(raw_data: string, format: string = "") -> ([]Ingest_Result, bool) {
	if !state.has_llm do return nil, false

	g := &state.blob.shard.gates
	desc_text := gates_describe_for_llm(g)

	b := strings.builder_make(runtime_alloc)
	strings.write_string(&b, "You are a data intake processor for a shard.\n\n")
	if len(desc_text) > 0 {
		strings.write_string(&b, "Shard configuration:\n")
		strings.write_string(&b, desc_text)
		strings.write_string(&b, "\n")
	}

	cat := &state.blob.shard.catalog
	if len(cat.name) > 0 {
		fmt.sbprintf(&b, "Shard: %s — %s\n\n", cat.name, cat.purpose)
	}

	strings.write_string(&b, "Extract one or more thoughts from the incoming data.\n")
	strings.write_string(&b, "For each thought, output a JSON line:\n")
	strings.write_string(
		&b,
		"{\"description\":\"short title\",\"content\":\"full detail\",\"route_to\":\"\"}\n\n",
	)
	strings.write_string(&b, "IMPORTANT RULES:\n")
	strings.write_string(&b, "- Leave route_to EMPTY to store in THIS shard (the default)\n")
	strings.write_string(
		&b,
		"- ONLY set route_to if the content clearly belongs in a DIFFERENT linked shard\n",
	)
	fmt.sbprintf(&b, "- NEVER route to \"%s\" (that is this shard)\n", state.shard_id)
	strings.write_string(&b, "- Output ONLY JSON lines, no other text\n")

	system := strings.to_string(b)

	user := raw_data
	if len(format) > 0 {
		user = fmt.aprintf("Format: %s\n\n%s", format, raw_data, allocator = runtime_alloc)
	}

	response, ok := llm_chat(system, user)
	if !ok do return nil, false

	results: [dynamic]Ingest_Result
	results.allocator = runtime_alloc

	lines := strings.split(response, "\n", allocator = runtime_alloc)
	for line in lines {
		trimmed := strings.trim_space(line)
		if len(trimmed) == 0 || trimmed[0] != '{' do continue

		parsed, err := json.parse(transmute([]u8)trimmed, allocator = runtime_alloc)
		if err != nil do continue

		obj, obj_ok := parsed.(json.Object)
		if !obj_ok do continue

		desc, _ := obj["description"].(json.String)
		content, _ := obj["content"].(json.String)
		route, _ := obj["route_to"].(json.String)

		if len(desc) > 0 {
			append(
				&results,
				Ingest_Result {
					description = strings.clone(desc, runtime_alloc),
					content = strings.clone(content, runtime_alloc),
					route_to = strings.clone(route, runtime_alloc),
				},
			)
		}
	}

	return results[:], len(results) > 0
}

route_to_peer :: proc(description: string, content: string, agent: string) -> (Thought_ID, bool) {
	msg := fmt.aprintf(
		`{{"method":"tools/call","id":1,"params":{{"name":"shard_write","arguments":{{"description":"%s","content":"%s","agent":"%s"}}}}}}`,
		mcp_json_escape(description),
		mcp_json_escape(content),
		mcp_json_escape(agent),
		allocator = runtime_alloc,
	)
	msg_bytes := transmute([]u8)msg

	peers := index_list()
	cache_load()
	split_state, has_split_state := cache_load_split_state()
	tried: map[string]bool
	tried.allocator = runtime_alloc
	if has_split_state && split_state.active {
		for target in [2]string{split_state.topic_a, split_state.topic_b} {
			if len(target) == 0 || target == state.shard_id || target in tried do continue
			tried[target] = true
			for peer in peers {
				if peer.shard_id != target do continue
				conn, ok := ipc_connect(ipc_socket_path(peer.shard_id))
				if !ok do break
				defer ipc_close(conn)

				if !ipc_send_msg(conn, msg_bytes) do break
				resp, recv_ok := ipc_recv_msg(conn)
				if !recv_ok do break

				resp_str := string(resp)
				if strings.contains(resp_str, "isError") do break

				log.infof("Routed thought to preferred split peer %s", peer.shard_id)
				return {}, true
			}
		}
	}
	for peer in peers {
		if peer.shard_id == state.shard_id || peer.shard_id in tried do continue
		conn, ok := ipc_connect(ipc_socket_path(peer.shard_id))
		if !ok do continue
		defer ipc_close(conn)

		if !ipc_send_msg(conn, msg_bytes) do continue
		resp, recv_ok := ipc_recv_msg(conn)
		if !recv_ok do continue

		resp_str := string(resp)
		if strings.contains(resp_str, "isError") do continue

		log.infof("Routed thought to peer %s", peer.shard_id)
		return {}, true
	}

	log.info("No peer accepted thought, creating new shard")
	name := fmt.aprintf(
		"auto-%s",
		description[:min(len(description), 20)],
		allocator = runtime_alloc,
	)
	if create_shard(slugify(name), description) {
		return {}, true
	}
	return {}, false
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
	hx := HEX_CHARS
	buf := make([]u8, 16, runtime_alloc)
	for i in 0 ..< 8 {
		buf[i * 2] = hx[h[i] >> 4]
		buf[i * 2 + 1] = hx[h[i] & 0x0f]
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
		case "--compact":
			cmd = .Compact
		case "--init":
			cmd = .Init
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

ipc_socket_path :: proc(shard_id: string) -> string {
	return fmt.aprintf("/tmp/shard-%s.sock", shard_id, allocator = runtime_alloc)
}

ipc_listen :: proc(shard_id: string) -> (IPC_Listener, bool) {
	sock_path := ipc_socket_path(shard_id)
	path_cstr := strings.clone_to_cstring(sock_path, runtime_alloc)
	posix.unlink(path_cstr)

	fd := posix.socket(.UNIX, .STREAM)
	if fd == -1 do return {}, false

	addr: posix.sockaddr_un
	addr.sun_family = .UNIX
	path_bytes := transmute([]u8)sock_path
	for i in 0 ..< min(len(path_bytes), len(addr.sun_path) - 1) {
		addr.sun_path[i] = path_bytes[i]
	}

	if posix.bind(fd, cast(^posix.sockaddr)&addr, size_of(addr)) != .OK {
		posix.close(fd)
		return {}, false
	}

	if posix.listen(fd, LISTEN_BACKLOG) != .OK {
		posix.close(fd)
		posix.unlink(path_cstr)
		return {}, false
	}

	return IPC_Listener{fd = fd, path = sock_path}, true
}

ipc_connect :: proc(sock_path: string) -> (IPC_Conn, bool) {
	fd := posix.socket(.UNIX, .STREAM)
	if fd == -1 do return {}, false

	addr: posix.sockaddr_un
	addr.sun_family = .UNIX
	path_bytes := transmute([]u8)sock_path
	for i in 0 ..< min(len(path_bytes), len(addr.sun_path) - 1) {
		addr.sun_path[i] = path_bytes[i]
	}

	if posix.connect(fd, cast(^posix.sockaddr)&addr, size_of(addr)) != .OK {
		posix.close(fd)
		return {}, false
	}

	return IPC_Conn{fd = fd}, true
}

ipc_close_listener :: proc(listener: ^IPC_Listener) {
	posix.close(listener.fd)
	path_cstr := strings.clone_to_cstring(listener.path, runtime_alloc)
	posix.unlink(path_cstr)
}

ipc_accept_timed :: proc(listener: ^IPC_Listener, timeout_ms: i32) -> (IPC_Conn, IPC_Result) {
	pfd: posix.pollfd
	pfd.fd = listener.fd
	pfd.events = {.IN}

	n := posix.poll(&pfd, 1, c.int(timeout_ms))
	if n == 0 do return {}, .Timeout
	if n < 0 do return {}, .Error

	client_fd := posix.accept(listener.fd, nil, nil)
	if client_fd == -1 do return {}, .Error
	return IPC_Conn{fd = client_fd}, .Ok
}

ipc_close :: proc(conn: IPC_Conn) {
	posix.close(conn.fd)
}

ipc_send :: proc(conn: IPC_Conn, data: []u8) -> bool {
	total: uint = 0
	for total < len(data) {
		n := posix.send(conn.fd, raw_data(data[total:]), len(data) - total, {})
		if n <= 0 do return false
		total += uint(n)
	}
	return true
}

ipc_recv_exact :: proc(conn: IPC_Conn, buf: []u8) -> bool {
	total: uint = 0
	for total < len(buf) {
		n := posix.recv(conn.fd, raw_data(buf[total:]), len(buf) - total, {})
		if n <= 0 do return false
		total += uint(n)
	}
	return true
}

ipc_send_msg :: proc(conn: IPC_Conn, data: []u8) -> bool {
	if len(data) > MSG_MAX_SIZE do return false
	header: [4]u8
	endian.put_u32(header[:], .Little, u32(len(data)))
	if !ipc_send(conn, header[:]) do return false
	return len(data) == 0 || ipc_send(conn, data)
}

ipc_recv_msg :: proc(conn: IPC_Conn) -> ([]u8, bool) {
	header: [4]u8
	if !ipc_recv_exact(conn, header[:]) do return nil, false
	size_val, size_ok := endian.get_u32(header[:], .Little)
	if !size_ok do return nil, false
	size := int(size_val)
	if size <= 0 || size > MSG_MAX_SIZE do return nil, false
	buf := make([]u8, size, runtime_alloc)
	if !ipc_recv_exact(conn, buf) do return nil, false
	return buf, true
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

	log.infof("Listening on %s (idle timeout: %d ms)", listener.path, state.idle_timeout)

	http_pid := posix.fork()
	if http_pid == 0 {
		ipc_close_listener(&listener)
		http_run()
		os.exit(0)
	} else if http_pid > 0 {
		log.infof("HTTP server forked (pid: %d)", i32(http_pid))
	}

	for {
		conn, result := ipc_accept_timed(&listener, i32(state.idle_timeout))

		switch result {
		case .Timeout:
			log.info("Idle timeout reached, shutting down.")
			return
		case .Error:
			log.error("Accept error, shutting down.")
			return
		case .Ok:
			pid := posix.fork()
			if pid == 0 {
				ipc_close_listener(&listener)
				handle_connection(conn)
				os.exit(0)
			} else if pid > 0 {
				ipc_close(conn)
				posix.waitpid(-1, nil, {.NOHANG})
			} else {
				handle_connection(conn)
			}
		}
	}
}

handle_connection :: proc(conn: IPC_Conn) {
	defer ipc_close(conn)

	request_arena: mem.Arena
	request_buf := make([]byte, REQUEST_ARENA_SIZE, runtime_alloc)
	mem.arena_init(&request_arena, request_buf)
	defer mem.arena_free_all(&request_arena)

	ctx := context
	ctx.allocator = mem.arena_allocator(&request_arena)
	context = ctx

	msg, ok := ipc_recv_msg(conn)
	if !ok do return

	response := mcp_process(string(msg))
	if len(response) > 0 do ipc_send_msg(conn, transmute([]u8)response)
}

http_run :: proc() {
	port := state.http_port
	port_str := os.get_env("PORT", runtime_alloc)
	if len(port_str) > 0 {
		parsed := 0
		for c in port_str {
			if c >= '0' && c <= '9' do parsed = parsed * 10 + int(c - '0')
		}
		if parsed > 0 do port = parsed
	}

	posix.signal(
		transmute(posix.Signal)i32(13),
		transmute(proc "cdecl" (_: posix.Signal))uintptr(1),
	)

	fd := posix.socket(.INET, .STREAM)
	if fd == -1 {
		log.error("Failed to create HTTP socket")
		return
	}
	defer posix.close(fd)

	opt: i32 = 1
	posix.setsockopt(fd, posix.SOL_SOCKET, .REUSEADDR, &opt, size_of(i32))

	addr: posix.sockaddr_in
	addr.sin_family = .INET
	addr.sin_port = posix.in_port_t(u16(port))
	addr.sin_addr.s_addr = posix.in_addr_t(0)

	if posix.bind(fd, cast(^posix.sockaddr)&addr, size_of(addr)) != .OK {
		log.errorf("Failed to bind HTTP port %d", port)
		return
	}

	if posix.listen(fd, LISTEN_BACKLOG) != .OK {
		log.error("Failed to listen on HTTP socket")
		return
	}

	log.infof("HTTP server listening on port %d", port)

	for {
		client_addr: posix.sockaddr
		addr_len: posix.socklen_t = size_of(posix.sockaddr)
		client_fd := posix.accept(fd, &client_addr, &addr_len)
		if client_fd == -1 {
			log.errorf("HTTP accept failed: fd=%d", i32(fd))
			continue
		}
		log.infof("HTTP accepted connection: client_fd=%d", i32(client_fd))
		pid := posix.fork()
		if pid == 0 {
			posix.close(fd)
			http_handle(client_fd)
			os.exit(0)
		} else if pid > 0 {
			posix.close(client_fd)
			posix.waitpid(-1, nil, {.NOHANG})
		} else {
			log.error("HTTP fork failed, handling inline")
			http_handle(client_fd)
		}
	}
}

http_content_type :: proc(path: string) -> string {
	if strings.has_suffix(path, ".html") do return "text/html; charset=utf-8"
	if strings.has_suffix(path, ".js") do return "application/javascript"
	if strings.has_suffix(path, ".css") do return "text/css"
	if strings.has_suffix(path, ".svg") do return "image/svg+xml"
	if strings.has_suffix(path, ".json") do return "application/json"
	if strings.has_suffix(path, ".png") do return "image/png"
	if strings.has_suffix(path, ".ico") do return "image/x-icon"
	if strings.has_suffix(path, ".woff2") do return "font/woff2"
	if strings.has_suffix(path, ".woff") do return "font/woff"
	if strings.has_suffix(path, ".ttf") do return "font/ttf"
	return "application/octet-stream"
}

http_serve_static :: proc(fd: posix.FD, raw_path: string) {
	static_dir := os.get_env("SHARD_STATIC", runtime_alloc)
	if len(static_dir) == 0 do static_dir = "/srv"

	serve_path := raw_path
	qmark := strings.index(serve_path, "?")
	if qmark >= 0 do serve_path = serve_path[:qmark]

	if strings.contains(serve_path, "..") {
		resp := "HTTP/1.1 403 Forbidden\r\nContent-Length: 9\r\nConnection: close\r\n\r\nForbidden"
		posix.send(fd, raw_data(transmute([]u8)resp), len(resp), {})
		return
	}

	if serve_path == "/" do serve_path = "/index.html"

	full_path := strings.concatenate({static_dir, serve_path}, runtime_alloc)
	data, ok := os.read_entire_file(full_path, runtime_alloc)
	if !ok {
		full_path = strings.concatenate({static_dir, "/index.html"}, runtime_alloc)
		data, ok = os.read_entire_file(full_path, runtime_alloc)
	}

	if !ok {
		resp := "HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\nConnection: close\r\n\r\nNot Found"
		posix.send(fd, raw_data(transmute([]u8)resp), len(resp), {})
		return
	}

	ct := http_content_type(full_path)
	header := fmt.aprintf(
		"HTTP/1.1 200 OK\r\nContent-Type: %s\r\nContent-Length: %d\r\nConnection: close\r\n\r\n",
		ct,
		len(data),
		allocator = runtime_alloc,
	)
	posix.send(fd, raw_data(transmute([]u8)header), len(header), {})
	posix.send(fd, raw_data(data), len(data), {})
}

http_handle :: proc(fd: posix.FD) {
	defer posix.close(fd)
	log.infof("HTTP handle start: fd=%d", i32(fd))

	buf := make([]u8, HTTP_READ_BUF, runtime_alloc)
	if buf == nil {
		log.error("HTTP handle: failed to allocate recv buffer")
		return
	}
	n := posix.recv(fd, raw_data(buf), len(buf), {})
	log.infof("HTTP recv: n=%d fd=%d", n, i32(fd))
	if n <= 0 do return

	request := string(buf[:int(n)])
	first_line_end := strings.index(request, "\r\n")
	if first_line_end < 0 do first_line_end = strings.index(request, "\n")
	if first_line_end < 0 {
		log.error("HTTP handle: no line ending in request")
		return
	}

	parts := strings.split(request[:first_line_end], " ", allocator = runtime_alloc)
	if len(parts) < 2 {
		log.errorf("HTTP handle: malformed request line: %s", request[:first_line_end])
		return
	}

	method := parts[0]
	path := parts[1]
	log.infof("HTTP %s %s", method, path)

	body := ""
	body_start := strings.index(request, "\r\n\r\n")
	if body_start >= 0 do body = request[body_start + 4:]

	response_body: string
	status := "200 OK"

	tool_name := ""
	switch {
	case path == "/info" && method == "GET":
		tool_name = "shard_info"
	case path == "/list" && method == "GET":
		tool_name = "shard_list"
	case path == "/query" && method == "POST":
		tool_name = "shard_query"
	case path == "/write" && method == "POST":
		tool_name = "shard_write"
	case path == "/read" && method == "POST":
		tool_name = "shard_read"
	case path == "/ask" && method == "POST":
		tool_name = "shard_ask"
	case path == "/ingest" && method == "POST":
		tool_name = "shard_ingest"
	case path == "/fleet/ask" && method == "POST":
		tool_name = "fleet_ask"
	case path == "/fleet/query" && method == "POST":
		tool_name = "fleet_query"
	case path == "/context" && method == "POST":
		tool_name = "build_context"
	case path == "/shard" && method == "POST":
		tool_name = "create_shard"
	case path == "/cache" && method == "GET":
		tool_name = "cache_list"
	case path == "/cache" && method == "POST":
		tool_name = "cache_set"
	case path == "/cache" && method == "DELETE":
		tool_name = "cache_delete"
	case strings.has_prefix(path, "/cache/") && method == "GET":
		key := path[7:]
		body = fmt.aprintf(`{{"key":"%s"}}`, mcp_json_escape(key), allocator = runtime_alloc)
		tool_name = "cache_get"
	}

	if len(tool_name) > 0 {
		args := body if len(body) > 0 else "{}"
		rpc := fmt.aprintf(
			`{{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{{"name":"%s","arguments":%s}}}}`,
			tool_name,
			args,
			allocator = runtime_alloc,
		)
		resp := mcp_process(rpc)
		parsed, err := json.parse(transmute([]u8)resp, allocator = runtime_alloc)
		if err == nil {
			obj, _ := parsed.(json.Object)
			result_obj, _ := obj["result"].(json.Object)
			content_arr, _ := result_obj["content"].(json.Array)
			if len(content_arr) > 0 {
				first, _ := content_arr[0].(json.Object)
				text, _ := first["text"].(json.String)
				response_body = fmt.aprintf(
					`{{"result":"%s"}}`,
					mcp_json_escape(text),
					allocator = runtime_alloc,
				)
			}
			if _, has_err := obj["error"]; has_err {
				status = "400 Bad Request"
				response_body = resp
			}
		} else {
			status = "500 Internal Server Error"
			response_body = `{"error":"internal error"}`
		}
	} else if method == "GET" {
		log.infof("HTTP serving static: %s", path)
		http_serve_static(fd, path)
		return
	} else {
		log.errorf("HTTP 404: %s %s", method, path)
		status = "404 Not Found"
		response_body = `{"error":"not found"}`
	}

	if method == "OPTIONS" {
		options_resp := "HTTP/1.1 204 No Content\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, DELETE, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type\r\nConnection: close\r\n\r\n"
		posix.send(fd, raw_data(transmute([]u8)options_resp), len(options_resp), {})
		return
	}

	resp := fmt.aprintf(
		"HTTP/1.1 %s\r\nContent-Type: application/json\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s",
		status,
		len(response_body),
		response_body,
		allocator = runtime_alloc,
	)
	sent := posix.send(fd, raw_data(transmute([]u8)resp), len(resp), {})
	log.infof("HTTP response: status=%s sent=%d/%d fd=%d", status, sent, len(resp), i32(fd))
}

MCP_PROTOCOL_VERSION :: "2024-11-05"
MCP_SERVER_NAME :: "shard"

mcp_run :: proc() {
	index_write(state.shard_id, state.exe_path)

	mcp_pid := posix.fork()
	if mcp_pid == 0 {
		mcp_stdio()
		os.exit(0)
	} else if mcp_pid > 0 {
		log.infof("MCP stdio forked (pid: %d)", i32(mcp_pid))
	}

	http_run()
}

mcp_stdio :: proc() {
	log.info("MCP server started on stdio")
	buf := make([]u8, MCP_READ_BUF, runtime_alloc)
	remainder := make([dynamic]u8, 0, 4096, runtime_alloc)
	use_header_framing := false
	for {
		n, err := os.read(os.stdin, buf[:])
		if err != nil || n <= 0 do break

		for b in buf[:n] do append(&remainder, b)

		for {
			if len(remainder) == 0 do break

			start := 0
			for start < len(remainder) && (remainder[start] == '\r' || remainder[start] == '\n') {
				start += 1
			}
			if start > 0 {
				mcp_consume_bytes(&remainder, start)
				if len(remainder) == 0 do break
			}

			if mcp_looks_like_headers(remainder[:]) {
				use_header_framing = true
				head_end, sep_len, has_headers := mcp_find_header_end(remainder[:])
				if !has_headers do break

				content_len, has_len := mcp_parse_content_length(remainder[:head_end])
				if !has_len {
					resp := mcp_error(json.Null{}, -32600, "missing content-length")
					if len(resp) > 0 do mcp_send_response(resp, use_header_framing)
					mcp_consume_bytes(&remainder, head_end + sep_len)
					continue
				}

				payload_start := head_end + sep_len
				payload_end := payload_start + content_len
				if payload_end > len(remainder) do break

				payload := string(remainder[payload_start:payload_end])
				resp := mcp_process(payload)
				if len(resp) > 0 do mcp_send_response(resp, use_header_framing)

				mcp_consume_bytes(&remainder, payload_end)
				continue
			}

			nl := -1
			for i in 0 ..< len(remainder) {
				if remainder[i] == '\n' {nl = i; break}
			}
			if nl == -1 do break

			line := string(remainder[:nl])
			line = strings.trim_right(line, "\r")

			if len(strings.trim_space(line)) > 0 {
				resp := mcp_process(line)
				if len(resp) > 0 do mcp_send_response(resp, use_header_framing)
			}

			mcp_consume_bytes(&remainder, nl + 1)
		}
	}
}

mcp_send_response :: proc(resp: string, use_header_framing: bool) {
	if use_header_framing {
		framed := fmt.aprintf("Content-Length: %d\r\n\r\n%s", len(resp), resp, allocator = runtime_alloc)
		os.write(os.stdout, transmute([]u8)framed)
	} else {
		line := fmt.aprintf("%s\n", resp, allocator = runtime_alloc)
		os.write(os.stdout, transmute([]u8)line)
	}
}

mcp_consume_bytes :: proc(buf: ^[dynamic]u8, n: int) {
	if n <= 0 do return
	if n >= len(buf^) {
		resize(buf, 0)
		return
	}
	copy(buf^[:len(buf^) - n], buf^[n:])
	resize(buf, len(buf^) - n)
}

mcp_find_header_end :: proc(buf: []u8) -> (int, int, bool) {
	if len(buf) >= 4 {
		for i in 0 ..< len(buf) - 3 {
			if buf[i] == '\r' && buf[i + 1] == '\n' && buf[i + 2] == '\r' && buf[i + 3] == '\n' {
				return i, 4, true
			}
		}
	}
	if len(buf) >= 2 {
		for i in 0 ..< len(buf) - 1 {
			if buf[i] == '\n' && buf[i + 1] == '\n' {
				return i, 2, true
			}
		}
	}
	return 0, 0, false
}

mcp_looks_like_headers :: proc(buf: []u8) -> bool {
	if len(buf) == 0 do return false

	i := 0
	for i < len(buf) && (buf[i] == ' ' || buf[i] == '\t' || buf[i] == '\r' || buf[i] == '\n') do i += 1
	if i >= len(buf) do return false

	if buf[i] == '{' || buf[i] == '[' do return false

	line_end := i
	for line_end < len(buf) && buf[line_end] != '\n' && buf[line_end] != '\r' do line_end += 1
	if line_end <= i do return false

	for j in i ..< line_end {
		if buf[j] == ':' do return true
	}

	return false
}

mcp_parse_content_length :: proc(headers: []u8) -> (int, bool) {
	prefix := "content-length:"
	i := 0
	for i < len(headers) {
		line_start := i
		for i < len(headers) && headers[i] != '\n' do i += 1
		line_end := i
		if line_end > line_start && headers[line_end - 1] == '\r' do line_end -= 1

		if line_end - line_start >= len(prefix) {
			match := true
			for j in 0 ..< len(prefix) {
				c := headers[line_start + j]
				if c >= 'A' && c <= 'Z' do c += 32
				if c != prefix[j] {
					match = false
					break
				}
			}
			if match {
				k := line_start + len(prefix)
				for k < line_end && (headers[k] == ' ' || headers[k] == '\t') do k += 1

				val := 0
				has_digit := false
				for k < line_end && headers[k] >= '0' && headers[k] <= '9' {
					has_digit = true
					val = val * 10 + int(headers[k] - '0')
					k += 1
				}
				if has_digit do return val, true
			}
		}

		i += 1
	}

	return 0, false
}

mcp_process :: proc(line: string) -> string {
	parsed, parse_err := json.parse(transmute([]u8)line, allocator = runtime_alloc)
	if parse_err != nil do return mcp_error(json.Null{}, -32700, "parse error")

	if arr, is_arr := parsed.(json.Array); is_arr {
		if len(arr) == 0 do return mcp_error(json.Null{}, -32600, "invalid request")
		responses := strings.builder_make(runtime_alloc)
		wrote := false
		for item in arr {
			obj, ok := item.(json.Object)
			if !ok {
				resp := mcp_error(json.Null{}, -32600, "invalid request")
				if wrote do strings.write_string(&responses, ",")
				strings.write_string(&responses, resp)
				wrote = true
				continue
			}

			resp := mcp_process_object(obj)
			if len(resp) == 0 do continue
			if wrote do strings.write_string(&responses, ",")
			strings.write_string(&responses, resp)
			wrote = true
		}

		if !wrote do return ""
		return fmt.aprintf("[%s]", strings.to_string(responses), allocator = runtime_alloc)
	}

	obj, is_obj := parsed.(json.Object)
	if !is_obj do return mcp_error(json.Null{}, -32600, "invalid request")
	return mcp_process_object(obj)
}

mcp_process_object :: proc(obj: json.Object) -> string {
	method_val, has_method := obj["method"]
	if !has_method do return mcp_error(json.Null{}, -32600, "missing method")
	method, is_str := method_val.(json.String)
	if !is_str do return mcp_error(json.Null{}, -32600, "method must be string")

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
	strings.write_string(&b, `,"error":{"code":`)
	fmt.sbprintf(&b, `%d`, code)
	strings.write_string(&b, `,"message":"`)
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

MCP_TOOLS_JSON :: string(#load("help/tools.json"))

mcp_tools_list :: proc(id_val: json.Value) -> string {
	return mcp_result(
		id_val,
		fmt.aprintf(`{{"tools":%s}}`, MCP_TOOLS_JSON, allocator = runtime_alloc),
	)
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
	case "shard_list":
		return mcp_tool_shard_list(id_val)
	case "cache_set":
		return mcp_tool_cache_set(id_val, args)
	case "cache_get":
		return mcp_tool_cache_get(id_val, args)
	case "cache_delete":
		return mcp_tool_cache_delete(id_val, args)
	case "cache_list":
		return mcp_tool_cache_list(id_val)
	case "build_context":
		return mcp_tool_build_context(id_val, args)
	case "fleet_query":
		return mcp_tool_fleet_query(id_val, args)
	case "create_shard":
		return mcp_tool_create_shard(id_val, args)
	case "vec_search":
		return mcp_tool_vec_search(id_val, args)
	case "shard_ask":
		return mcp_tool_shard_ask(id_val, args)
	case "shard_ingest":
		return mcp_tool_shard_ingest(id_val, args)
	case "fleet_ask":
		return mcp_tool_fleet_ask(id_val, args)
	case "compact":
		if compact() {
			return mcp_tool_result(
				id_val,
				fmt.aprintf(
					"compacted: %d processed",
					len(state.blob.shard.processed),
					allocator = runtime_alloc,
				),
			)
		}
		return mcp_tool_result(id_val, "compact failed", true)
	case "shard_write_batch":
		return mcp_tool_write_batch(id_val, args)
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

	return mcp_tool_result(
		id_val,
		fmt.aprintf("wrote thought %s", thought_id_to_hex(id), allocator = runtime_alloc),
	)
}

mcp_tool_read :: proc(id_val: json.Value, args: json.Object) -> string {
	id_hex, _ := args["id"].(json.String)
	if len(id_hex) == 0 do return mcp_tool_result(id_val, "missing id", true)

	tid, ok := hex_to_thought_id(id_hex)
	if !ok do return mcp_tool_result(id_val, "invalid id (must be 32 hex chars)", true)

	desc, content, read_ok := read_thought(tid)
	if !read_ok do return mcp_tool_result(id_val, "thought not found or decrypt failed", true)

	return mcp_tool_result(
		id_val,
		fmt.aprintf("# %s\n\n%s", desc, content, allocator = runtime_alloc),
	)
}

mcp_tool_query :: proc(id_val: json.Value, args: json.Object) -> string {
	keyword, _ := args["keyword"].(json.String)

	target, _ := args["shard"].(json.String)
	results: []Query_Result
	if len(target) > 0 && target != state.shard_id {
		results = query_peer(target, keyword)
	} else {
		results = query_thoughts(keyword)
	}
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
		fmt.sbprintf(
			&b,
			"thoughts: %d processed, %d unprocessed\n",
			len(s.processed),
			len(s.unprocessed),
		)
	}
	fmt.sbprintf(&b, "has key: %v\n", state.has_key)
	peers := index_list()
	fmt.sbprintf(&b, "known shards: %d\n", len(peers))
	return mcp_tool_result(id_val, strings.to_string(b))
}

mcp_tool_shard_list :: proc(id_val: json.Value) -> string {
	peers := index_list()
	if len(peers) == 0 do return mcp_tool_result(id_val, "no shards registered")

	b := strings.builder_make(runtime_alloc)
	fmt.sbprintf(&b, "%d shards:\n", len(peers))
	for peer in peers {
		raw, ok := os.read_entire_file(peer.exe_path, runtime_alloc)
		if !ok {
			fmt.sbprintf(&b, "- %s (unreachable: %s)\n", peer.shard_id, peer.exe_path)
			continue
		}
		blob := load_blob_from_raw(raw)
		if blob.has_data {
			s := &blob.shard
			name := s.catalog.name if len(s.catalog.name) > 0 else peer.shard_id
			fmt.sbprintf(
				&b,
				"- %s: %s (%d thoughts)\n",
				peer.shard_id,
				name,
				len(s.processed) + len(s.unprocessed),
			)
		} else {
			fmt.sbprintf(&b, "- %s (empty)\n", peer.shard_id)
		}
	}
	return mcp_tool_result(id_val, strings.to_string(b))
}

mcp_tool_cache_set :: proc(id_val: json.Value, args: json.Object) -> string {
	key, _ := args["key"].(json.String)
	value, _ := args["value"].(json.String)
	author, _ := args["author"].(json.String)
	expires, _ := args["expires"].(json.String)
	if len(key) == 0 do return mcp_tool_result(id_val, "missing key", true)
	entry := Cache_Entry {
		value   = strings.clone(value, runtime_alloc),
		author  = strings.clone(author, runtime_alloc),
		expires = strings.clone(expires, runtime_alloc),
	}
	state.topic_cache[strings.clone(key, runtime_alloc)] = entry
	cache_save_key(key, entry)
	return mcp_tool_result(id_val, "cache entry set")
}

mcp_tool_cache_get :: proc(id_val: json.Value, args: json.Object) -> string {
	key, _ := args["key"].(json.String)
	if len(key) == 0 do return mcp_tool_result(id_val, "missing key", true)
	cache_load()
	entry, ok := state.topic_cache[key]
	if !ok do return mcp_tool_result(id_val, "not found", true)
	return mcp_tool_result(id_val, entry.value)
}

mcp_tool_cache_delete :: proc(id_val: json.Value, args: json.Object) -> string {
	key, _ := args["key"].(json.String)
	if len(key) == 0 do return mcp_tool_result(id_val, "missing key", true)
	cache_delete_key(key)
	return mcp_tool_result(id_val, "cache entry deleted")
}

mcp_tool_cache_list :: proc(id_val: json.Value) -> string {
	cache_load()
	if len(state.topic_cache) == 0 do return mcp_tool_result(id_val, "cache empty")
	b := strings.builder_make(runtime_alloc)
	for _, entry in state.topic_cache {
		label := cache_safe_label(entry)
		if len(entry.author) > 0 {
			fmt.sbprintf(&b, "%s: %s [%s]\n", label, entry.value, entry.author)
		} else {
			fmt.sbprintf(&b, "%s: %s\n", label, entry.value)
		}
	}
	return mcp_tool_result(id_val, strings.to_string(b))
}

mcp_tool_build_context :: proc(id_val: json.Value, args: json.Object) -> string {
	task, _ := args["task"].(json.String)
	if len(task) == 0 do return mcp_tool_result(id_val, "missing task", true)
	ctx := build_context(task)
	if len(ctx) == 0 do return mcp_tool_result(id_val, "no context available")
	return mcp_tool_result(id_val, ctx)
}

mcp_tool_fleet_query :: proc(id_val: json.Value, args: json.Object) -> string {
	keyword, _ := args["keyword"].(json.String)
	if len(keyword) == 0 do return mcp_tool_result(id_val, "missing keyword", true)

	results := fleet_query(keyword)
	if len(results) == 0 do return mcp_tool_result(id_val, "no peers available")

	b := strings.builder_make(runtime_alloc)
	for r in results {
		if r.ok {
			fmt.sbprintf(&b, "%s: %s\n", r.shard_id, r.response)
		} else {
			fmt.sbprintf(&b, "%s: (unreachable)\n", r.shard_id)
		}
	}
	return mcp_tool_result(id_val, strings.to_string(b))
}

mcp_tool_create_shard :: proc(id_val: json.Value, args: json.Object) -> string {
	name, _ := args["name"].(json.String)
	purpose, _ := args["purpose"].(json.String)
	if len(name) == 0 do return mcp_tool_result(id_val, "missing name", true)
	if !create_shard(name, purpose) do return mcp_tool_result(id_val, "failed to create shard", true)
	return mcp_tool_result(
		id_val,
		fmt.aprintf("created shard '%s'", name, allocator = runtime_alloc),
	)
}

mcp_tool_vec_search :: proc(id_val: json.Value, args: json.Object) -> string {
	query, _ := args["query"].(json.String)
	if len(query) == 0 do return mcp_tool_result(id_val, "missing query", true)
	if !state.has_embed do return mcp_tool_result(id_val, "no embedding model configured (set EMBED_MODEL)", true)

	top_k := 5
	if k, ok := args["top_k"].(json.Integer); ok && k > 0 {
		top_k = int(k)
	}

	results := vec_search(query, top_k)
	if len(results) == 0 do return mcp_tool_result(id_val, "no matches")

	b := strings.builder_make(runtime_alloc)
	fmt.sbprintf(&b, "%d results:\n", len(results))
	for r in results {
		fmt.sbprintf(&b, "- %s: %s (score: %d)\n", thought_id_to_hex(r.id), r.description, r.score)
	}
	return mcp_tool_result(id_val, strings.to_string(b))
}

mcp_tool_shard_ask :: proc(id_val: json.Value, args: json.Object) -> string {
	question, _ := args["question"].(json.String)
	if len(question) == 0 do return mcp_tool_result(id_val, "missing question", true)
	target, _ := args["shard"].(json.String)
	if len(target) > 0 && target != state.shard_id {
		answer, ok := ask_peer(target, question)
		if !ok do return mcp_tool_result(id_val, answer, true)
		return mcp_tool_result(
			id_val,
			fmt.aprintf("[%s] %s", target, answer, allocator = runtime_alloc),
		)
	}
	answer, ok := shard_ask(question)
	if !ok do return mcp_tool_result(id_val, answer, true)
	return mcp_tool_result(id_val, answer)
}

mcp_tool_shard_ingest :: proc(id_val: json.Value, args: json.Object) -> string {
	data, _ := args["data"].(json.String)
	if len(data) == 0 do return mcp_tool_result(id_val, "missing data", true)
	format, _ := args["format"].(json.String)

	results, ok := shard_ingest(data, format)
	if !ok do return mcp_tool_result(id_val, "ingest failed (check LLM config)", true)

	b := strings.builder_make(runtime_alloc)
	stored := 0
	routed := 0

	self_name := state.blob.shard.catalog.name
	for r in results {
		is_self :=
			len(r.route_to) == 0 ||
			r.route_to == state.shard_id ||
			r.route_to == self_name ||
			strings.to_lower(r.route_to, runtime_alloc) ==
				strings.to_lower(self_name, runtime_alloc)

		if is_self {
			id, write_ok := write_thought(r.description, r.content)
			if write_ok {
				stored += 1
				fmt.sbprintf(&b, "stored %s: %s\n", thought_id_to_hex(id), r.description)
			}
		} else {
			_, peer_ok := load_peer_blob(r.route_to)
			if peer_ok {
				routed += 1
				fmt.sbprintf(&b, "routed to %s: %s\n", r.route_to, r.description)
			} else {
				id, write_ok := write_thought(r.description, r.content)
				if write_ok {
					stored += 1
					fmt.sbprintf(
						&b,
						"stored %s (no peer %s): %s\n",
						thought_id_to_hex(id),
						r.route_to,
						r.description,
					)
				}
			}
		}
	}

	fmt.sbprintf(&b, "\n%d stored, %d routed", stored, routed)
	return mcp_tool_result(id_val, strings.to_string(b))
}

mcp_tool_fleet_ask :: proc(id_val: json.Value, args: json.Object) -> string {
	question, _ := args["question"].(json.String)
	if len(question) == 0 do return mcp_tool_result(id_val, "missing question", true)
	answer := fleet_ask(question)
	return mcp_tool_result(id_val, answer)
}

mcp_tool_write_batch :: proc(id_val: json.Value, args: json.Object) -> string {
	thoughts_json, _ := args["thoughts"].(json.String)
	if len(thoughts_json) == 0 do return mcp_tool_result(id_val, "missing thoughts", true)

	parsed, err := json.parse(transmute([]u8)thoughts_json, allocator = runtime_alloc)
	if err != nil do return mcp_tool_result(id_val, "invalid JSON array", true)
	arr, arr_ok := parsed.(json.Array)
	if !arr_ok do return mcp_tool_result(id_val, "expected JSON array", true)

	s := &state.blob.shard
	count := 0
	for item in arr {
		obj, obj_ok := item.(json.Object)
		if !obj_ok do continue
		desc, _ := obj["description"].(json.String)
		content, _ := obj["content"].(json.String)
		if len(desc) == 0 do continue

		if thought_exists(desc) do continue

		id := new_thought_id()
		body_blob, seal_blob, trust := thought_encrypt(state.key, id, desc, content)
		t := Thought {
			id         = id,
			trust      = trust,
			seal_blob  = seal_blob,
			body_blob  = body_blob,
			created_at = now_rfc3339(),
		}

		buf: [dynamic]u8
		buf.allocator = runtime_alloc
		thought_serialize(&buf, &t)

		new_unprocessed: [dynamic][]u8
		new_unprocessed.allocator = runtime_alloc
		for entry in s.unprocessed do append(&new_unprocessed, entry)
		append(&new_unprocessed, buf[:])
		s.unprocessed = new_unprocessed[:]
		count += 1
	}

	if count == 0 do return mcp_tool_result(id_val, "no new thoughts (all duplicates or empty)")
	if !state.blob.has_data do state.blob.has_data = true

	if len(s.catalog.name) == 0 && count > 0 {
		first_obj, _ := arr[0].(json.Object)
		first_desc, _ := first_obj["description"].(json.String)
		s.catalog.name = first_desc
		s.catalog.purpose = first_desc
		s.catalog.created = now_rfc3339()
		state.shard_id = resolve_shard_id()
	}

	if !blob_write_self() do return mcp_tool_result(id_val, "persist failed", true)
	return mcp_tool_result(
		id_val,
		fmt.aprintf("wrote %d thoughts in one persist", count, allocator = runtime_alloc),
	)
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
		index_write(state.shard_id, state.exe_path)
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
					"gates:        gate=%s descriptors=%d links=%d",
					s.gates.gate,
					len(s.gates.descriptors),
					len(s.gates.shard_links),
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
	case .Compact:
		if !compact() do shutdown(1)
	case .Init:
		if !shard_init() do shutdown(1)
	case .Daemon, .None:
		daemon_run()
		defer daemon_shutdown()
	}
}
