package shard

import "core:log"
import "core:mem"
import "core:os"
import "core:sys/posix"

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
CONTEXT_SESSION_MAX_ENTRIES :: 64
CONTEXT_FALLBACK_MAX_THOUGHTS :: 4
SCD1_MAGIC :: [4]u8{'S', 'C', 'D', '1'}
SCD1_FRAME_SIZE :: 25
SCD1_OP_READ :: u8(0x01)
SCD1_OP_CITE :: u8(0x02)

Thought_Counter_Op :: enum {
	Read,
	Cite,
}

HELP_TEXT :: [Command][2]string {
	.Help     = {string(#load("help/help.txt")), string(#load("help/help.ai.txt"))},
	.Daemon   = {string(#load("help/daemon.txt")), string(#load("help/daemon.ai.txt"))},
	.Version  = {string(#load("help/version.txt")), string(#load("help/version.ai.txt"))},
	.Info     = {string(#load("help/info.txt")), string(#load("help/info.ai.txt"))},
	.Mcp      = {string(#load("help/daemon.txt")), string(#load("help/daemon.ai.txt"))},
	.Compact  = {string(#load("help/info.txt")), string(#load("help/info.ai.txt"))},
	.Init     = {string(#load("help/info.txt")), string(#load("help/info.ai.txt"))},
	.Selftest = {string(#load("help/info.txt")), string(#load("help/info.ai.txt"))},
	.Keychain = {string(#load("help/info.txt")), string(#load("help/info.ai.txt"))},
	.None     = {string(#load("help/help.txt")), string(#load("help/help.ai.txt"))},
}

Command :: enum {
	None,
	Daemon,
	Mcp,
	Compact,
	Init,
	Selftest,
	Help,
	Version,
	Info,
	Keychain,
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
	ttl_days:        int `json:"ttl_days"`,
	archive_dir:     string `json:"archive_dir"`,
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
	parent_id: string,
	tree_path: string,
	depth:     int,
}

Cache_Entry :: struct {
	value:   string `json:"value"`,
	author:  string `json:"author"`,
	expires: string `json:"expires"`,
}

Ingest_Result :: struct {
	description: string,
	content:     string,
	route_to:    string,
}

Meta_Stats :: struct {
	access_count:  u64    `json:"access_count"`,
	write_count:   u64    `json:"write_count"`,
	last_access_at: string `json:"last_access_at"`,
}

Meta_Item :: struct {
	id:               string     `json:"id"`,
	name:             string     `json:"name"`,
	thought_count:    int        `json:"thought_count"`,
	linked_shard_ids: [dynamic]string `json:"linked_shard_ids"`,
	stats:            Meta_Stats `json:"stats"`,
}

Meta_Single_Response :: struct {
	id:               string     `json:"id"`,
	name:             string     `json:"name"`,
	bucket:           int        `json:"bucket"`,
	window:           string     `json:"window"`,
	thought_count:    int        `json:"thought_count"`,
	linked_shard_ids: [dynamic]string `json:"linked_shard_ids"`,
	stats:            Meta_Stats `json:"stats"`,
}

Meta_Batch_Response :: struct {
	bucket:      int         `json:"bucket"`,
	window:      string      `json:"window"`,
	items:       [dynamic]Meta_Item `json:"items"`,
	missing_ids: [dynamic]string    `json:"missing_ids"`,
}

Meta_Http_Response :: struct {
	body:   string,
	status: string,
	ok:    bool,
}

Context_Term :: struct {
	term:   string,
	weight: f64,
}

Context_Session :: struct {
	id:                 string,
	agent:              string,
	started_at:         string,
	last_used_at:       string,
	recent_queries:     [dynamic]string,
	dominant_terms:     [dynamic]Context_Term,
	topic_mix:          [dynamic]Context_Term,
	unresolved_threads: [dynamic]string,
}

Context_Packet :: struct {
	session_id:           string,
	generated_at:         string,
	based_on_query:       string,
	included_shards:      [dynamic]string,
	included_thought_ids: [dynamic]string,
	summary:              string,
	confidence_notes:     string,
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
	exe_path:                    string,
	exe_dir:                     string,
	shards_dir:                  string,
	shard_id:                    string,
	index_dir:                   string,
	run_dir:                     string,
	working_copy:                string,
	command:                     Command,
	ai_mode:                     bool,
	config:                      Config,
	blob:                        Blob,
	key:                         Key,
	has_key:                     bool,
	idle_timeout:                int,
	http_port:                   int,
	max_thoughts:                int,
	llm_url:                     string,
	llm_key:                     string,
	llm_model:                   string,
	has_llm:                     bool,
	embed_model:                 string,
	has_embed:                   bool,
	vec_index:                   [dynamic]Vec_Entry,
	topic_cache:                 map[string]Cache_Entry,
	context_sessions:            map[string]Context_Session,
	congestion_replay_cursor:    int,
	active_request_children:      int,
	congestion_replay_dirty:      bool,
	cache_dir:                   string,
	cache_key_fallback:          Key,
	has_cache_key_fallback:      bool,
	cache_migration_note_logged:  bool,
	split_routing_hash_only:     bool,
	selftest_target:             string,
	is_fork:                     bool,
	needs_maintenance:           bool,
}

state: ^State
runtime_arena: ^mem.Arena
runtime_alloc: mem.Allocator
console_logger: log.Logger
file_logger: log.Logger
multi_logger: log.Logger
log_file_handle: os.Handle
