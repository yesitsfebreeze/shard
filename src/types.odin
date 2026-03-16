package shard

import "core:time"

// =============================================================================
// Core crypto types
// =============================================================================

Thought_ID  :: distinct [16]u8
Trust_Token :: distinct [32]u8
Master_Key  :: distinct [32]u8

// =============================================================================
// Thought — the atomic encrypted unit
// =============================================================================

Thought :: struct {
	id:         Thought_ID,
	trust:      Trust_Token,
	seal_blob:  []u8,
	body_blob:  []u8,
	// Plaintext metadata — queryable without decryption
	agent:      string,        // who wrote this (max 64 chars, "" = unknown)
	created_at: string,        // RFC3339 timestamp
	updated_at: string,        // RFC3339 timestamp
}

Thought_Plaintext :: struct {
	description: string,
	content:     string,
}

Thought_Error :: enum {
	None,
	Bad_Format,
	Bad_Encoding,
	Decrypt_Failed,
	Seal_Mismatch,
	No_Separator,
}

// =============================================================================
// Catalog — the shard's identity card (plaintext, no key needed)
// =============================================================================

Catalog :: struct {
	name:    string   `json:"name"`,           // human-readable shard name
	purpose: string   `json:"purpose"`,        // what this shard is for
	tags:    []string `json:"tags"`,           // topic tags for discovery
	related: []string `json:"related"`,        // names of related shards
	created: string   `json:"created"`,        // RFC3339 creation timestamp
}

// =============================================================================
// Blob — in-memory representation of a .shard file
// =============================================================================

Blob :: struct {
	path:        string,
	master:      Master_Key,
	catalog:     Catalog,                // plaintext identity card
	processed:   [dynamic]Thought,       // AI-ordered thoughts
	unprocessed: [dynamic]Thought,       // append-only thoughts
	manifest:    string,                 // plaintext YAML metadata
	description: [dynamic]string,        // plaintext: what this shard is for
	positive:    [dynamic]string,        // plaintext: routing accept signals
	negative:    [dynamic]string,        // plaintext: routing reject signals
	related:     [dynamic]string,        // plaintext: names of related shards
}

// =============================================================================
// Node — a shard process
// =============================================================================
//
// Every shard is the same exe. The daemon is just a shard whose blob
// stores a registry of other shards. It loads other shard blobs in-process
// via Shard_Slot.
//

Node :: struct {
	name:          string,
	blob:          Blob,
	index:         [dynamic]Search_Entry,
	start_time:    time.Time,
	last_activity: time.Time,        // last client interaction
	idle_timeout:  time.Duration,    // 0 = no timeout
	listener:      IPC_Listener,
	running:       bool,
	is_daemon:     bool,             // true if this node is the daemon
	// Daemon only: managed shard slots (loaded in-process)
	registry:      [dynamic]Registry_Entry,
	slots:         map[string]^Shard_Slot,
	vec_index:     Vector_Index,
}

// =============================================================================
// Shard slots — in-process loaded shard blobs (daemon only)
// =============================================================================

Shard_Slot :: struct {
	name:        string,
	data_path:   string,
	blob:        Blob,
	index:       [dynamic]Search_Entry,
	loaded:      bool,               // false = not loaded yet (just metadata)
	key_set:     bool,               // true if blob was loaded with a real key
	master:      Master_Key,         // the key used to load (zero if unkeyed)
	last_access: time.Time,          // for idle eviction
}

// =============================================================================
// Daemon registry
// =============================================================================

DAEMON_NAME :: "daemon"

Registry_Entry :: struct {
	name:          string        `json:"name"`,
	data_path:     string        `json:"data_path"`,
	remote:        string        `json:"remote,omitempty"`,   // future: remote address for federation
	thought_count: int           `json:"thought_count"`,
	catalog:       Catalog       `json:"catalog"`,
	// Gates — cached from the shard blob for AI-driven routing
	gate_desc:     []string      `json:"gate_desc,omitempty"`,
	gate_positive: []string      `json:"gate_positive,omitempty"`,
	gate_negative: []string      `json:"gate_negative,omitempty"`,
	gate_related:  []string      `json:"gate_related,omitempty"`,
}

// =============================================================================
// Search
// =============================================================================

Search_Entry :: struct {
	id:          Thought_ID,
	description: string,
}

Search_Result :: struct {
	id:    Thought_ID,
	score: f32,
}

// =============================================================================
// Vector index
// =============================================================================

Vector_Entry :: struct {
	name:      string,
	embedding: []f32,
	text_hash: u64,
}

Vector_Index :: struct {
	entries: [dynamic]Vector_Entry,
	dims:    int,
}

Vector_Result :: struct {
	name:  string,
	score: f32,
}

// =============================================================================
// Wire protocol types
// =============================================================================

Request :: struct {
	op:            string,
	id:            string,
	description:   string,
	content:       string,        // maps to markdown body
	query:         string,
	items:         []string,
	ids:           []string,      // for compact op
	name:          string,        // shard name (register/unregister)
	data_path:     string,
	thought_count: int,
	agent:         string,        // who is writing (max 64 chars)
	key:           string,        // per-request master key (64 hex chars) for encrypted ops
	// catalog fields (for set_catalog)
	purpose:       string,
	tags:          []string,
	related:       []string,
	// traverse fields
	max_depth:     int,
	max_branches:  int,
}

Response :: struct {
	status:      string,
	id:          string,
	description: string,
	content:     string,          // maps to markdown body
	ids:         []string,
	items:       []string,
	results:     []Wire_Result,
	err:         string,
	moved:       int,
	// agent identity
	agent:       string,
	created_at:  string,
	updated_at:  string,
	// status op fields
	node_name:   string,
	thoughts:    int,
	uptime_secs: f64,
	// catalog
	catalog:     Catalog,
	// daemon registry
	registry:    []Registry_Entry,
}

Wire_Result :: struct {
	id:          string,
	score:       f32,
	description: string,
	content:     string,   // populated by query op (search+read compound)
}
