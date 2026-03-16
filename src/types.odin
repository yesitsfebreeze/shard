package shard

import "core:crypto"
import "core:sync"
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
	revises:    Thought_ID,    // parent thought this revises (zero = original)
	ttl:        u32,           // staleness TTL in seconds (0 = immortal)
	read_count: u32,           // times this thought was read (plaintext)
	cite_count: u32,           // times this thought was cited (plaintext)
}

ZERO_THOUGHT_ID :: Thought_ID{}

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
	mu:            sync.Mutex,       // guards all shared state during dispatch
	// Daemon only: managed shard slots (loaded in-process)
	registry:      [dynamic]Registry_Entry,
	slots:         map[string]^Shard_Slot,
	vec_index:     Vector_Index,
	// Daemon only: content alert audit trail
	audit_trail:   [dynamic]Audit_Entry,
	// Daemon only: event hub — queued events per target shard
	event_queue:   Event_Queue,
	// Daemon only: consumption tracking — per-agent, per-shard access log
	consumption_log: [dynamic]Consumption_Record,
	// Protocol-level: pending content alerts (synced to/from slot)
	pending_alerts: map[string]Pending_Alert,
}

// Generate a random hex string (16 bytes = 32 hex chars)
new_random_hex :: proc() -> string {
	buf: [16]u8
	crypto.rand_bytes(buf[:])
	return id_to_hex(Thought_ID(buf))
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
	// Transaction locking
	lock_agent:  string,             // agent holding the lock ("" = unlocked)
	lock_id:     string,             // random token for commit/rollback auth
	lock_expiry: time.Time,          // when the lock auto-releases (zero = no lock)
	// Write queue: requests queued while shard is transaction-locked
	write_queue: [dynamic]Request,
	// Pending content alerts
	pending_alerts: map[string]Pending_Alert,
}

// =============================================================================
// Daemon registry
// =============================================================================

DAEMON_NAME :: "daemon"

Registry_Entry :: struct {
	name:          string        `json:"name"`,
	data_path:     string        `json:"data_path"`,
	thought_count: int           `json:"thought_count"`,
	catalog:       Catalog       `json:"catalog"`,
	// Gates — cached from the shard blob for AI-driven routing
	gate_desc:     []string      `json:"gate_desc,omitempty"`,
	gate_positive: []string      `json:"gate_positive,omitempty"`,
	gate_negative: []string      `json:"gate_negative,omitempty"`,
	gate_related:  []string      `json:"gate_related,omitempty"`,
	needs_attention: bool       `json:"needs_attention,omitempty"`,
}

// =============================================================================
// Search
// =============================================================================

Search_Entry :: struct {
	id:          Thought_ID,
	description: string,
	embedding:   []f32,        // vector from embed_text (nil if not embedded)
	text_hash:   u64,          // FNV hash of description for cache check
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
	layer:         int,           // traverse layer: 0=gates, 1=gates+thoughts, 2=gates+thoughts+related
	// revision fields
	revises:       string,        // hex ID of parent thought being revised
	// transaction fields
	lock_id:       string,        // transaction lock token
	ttl:           int,           // transaction TTL in seconds (default 30)
	// content alert fields
	alert_id:      string,        // alert ID for alert_response op
	action:        string,        // "approve" or "reject" for alert_response
	// event hub fields
	event_type:    string,        // notify: knowledge_changed, compacted, gates_updated
	source:        string,        // notify: shard that emitted the event
	origin_chain:  []string,      // notify: prevents circular propagation
	// consumption_log fields
	limit:         int,           // max records to return (default 50)
	// budget fields
	budget:        int,           // max approximate content chars in response (0 = unlimited)
	// staleness TTL fields
	thought_ttl:      int,        // thought TTL in seconds (0 = immortal)
	freshness_weight: f32,        // 0.0-1.0, blend freshness into search scoring
	// relevance scoring fields
	feedback:         string,     // "endorse" or "flag" for feedback op
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
	// revision chain
	revisions:   []string,        // list of revision IDs in chronological order
	// transaction
	lock_id:     string,          // transaction lock token
	// content alert
	alert_id:    string,          // alert ID for content_alert responses
	findings:    []Alert_Finding, // flagged content findings
	// event hub
	events:      []Shard_Event,   // pending events for a shard
	// consumption log
	consumption_log: []Consumption_Record,
	// staleness
	staleness_score: f32,        // overall staleness score (stale op)
	// relevance scoring
	relevance_score: f32,        // composite relevance score
}

Wire_Result :: struct {
	id:              string,
	score:           f32,
	description:     string,
	content:         string,   // populated by query op (search+read compound)
	truncated:       bool,     // true if content was cut to fit within budget
	staleness_score: f32,      // 0.0-1.0, freshness decay (stale op)
	relevance_score: f32,      // composite relevance score
}

// =============================================================================
// Content alert types
// =============================================================================

Alert_Finding :: struct {
	category: string,   // "api_key", "password", "pii"
	snippet:  string,   // matched text (truncated)
}

Pending_Alert :: struct {
	alert_id:   string,
	shard_name: string,
	agent:      string,
	findings:   []Alert_Finding,
	request:    Request,          // the original write request (replayed on approve)
	created_at: string,
}

Audit_Entry :: struct {
	timestamp: string   `json:"timestamp"`,
	alert_id:  string   `json:"alert_id"`,
	shard:     string   `json:"shard"`,
	agent:     string   `json:"agent"`,
	action:    string   `json:"action"`,     // "approve" or "reject"
	category:  string   `json:"category"`,
}

// =============================================================================
// Daemon event hub types
// =============================================================================

Shard_Event :: struct {
	source:       string   `json:"source"`,        // shard that emitted the event
	event_type:   string   `json:"event_type"`,    // knowledge_changed, compacted, gates_updated
	agent:        string   `json:"agent"`,         // agent that caused the event
	timestamp:    string   `json:"timestamp"`,
	origin_chain: []string `json:"origin_chain"`,  // prevents circular propagation
}

// Event_Queue maps shard name -> pending events for that shard
Event_Queue :: distinct map[string][dynamic]Shard_Event

// =============================================================================
// Consumption tracking types
// =============================================================================

Consumption_Record :: struct {
	agent:     string   `json:"agent"`,
	shard:     string   `json:"shard"`,
	op:        string   `json:"op"`,
	timestamp: string   `json:"timestamp"`,
}

// Max records kept in memory (ring buffer behavior — oldest dropped)
MAX_CONSUMPTION_RECORDS :: 1000
