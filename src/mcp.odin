package shard

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:os/os2"
import "core:strings"
import "core:sync"
import "core:time"

// =============================================================================
// MCP server — JSON-RPC 2.0 over stdio
// =============================================================================
//
// Usage:  shard mcp
//
// Reads JSON-RPC messages from stdin (one per line), writes responses to stdout.
// All diagnostic output goes to stderr. Connects to the daemon via IPC; the
// daemon loads shard blobs in-process and routes ops by the `name:` field.
//
// Protocol:
//   initialize        -> server info + capabilities
//   notifications/initialized  -> (no response)
//   tools/list        -> list of available tools
//   tools/call        -> execute a tool
//

MCP_SERVER_NAME :: "shard-mcp"
MCP_SERVER_VERSION :: "0.2.0"
MCP_PROTOCOL_VERSION :: "2024-11-05"

// =============================================================================
// Daemon connection — single persistent IPC connection to the daemon
// =============================================================================

_daemon_conn: IPC_Conn
_daemon_connected: bool
_daemon_mu: sync.Mutex // guards _daemon_conn and _daemon_connected for HTTP mode threads

_daemon_get :: proc() -> (IPC_Conn, bool) {
	if _daemon_connected do return _daemon_conn, true
	conn, ok := ipc_connect(DAEMON_NAME)
	if !ok do return {}, false
	_daemon_conn = conn
	_daemon_connected = true
	return conn, true
}

_daemon_invalidate :: proc() {
	if _daemon_connected {
		ipc_close_conn(_daemon_conn)
		_daemon_connected = false
	}
}

// _daemon_call sends a JSON message to the daemon and returns the response.
// Protected by _daemon_mu so it is safe to call from multiple HTTP threads.
_daemon_call :: proc(message: string, allocator := context.allocator) -> (string, bool) {
	sync.mutex_lock(&_daemon_mu)
	defer sync.mutex_unlock(&_daemon_mu)

	conn, ok := _daemon_get()
	if !ok {
		fmt.eprintln("DEBUG _daemon_call: no connection")
		return "", false
	}

	data := transmute([]u8)message
	fmt.eprintf("DEBUG _daemon_call SEND (%d bytes): %.200s\n", len(data), message)
	if !ipc_send_msg(conn, data) {
		_daemon_invalidate()
		return "", false
	}

	resp, recv_ok := ipc_recv_msg(conn, allocator)
	if !recv_ok {
		_daemon_invalidate()
		fmt.eprintln("DEBUG _daemon_call: recv failed")
		return "", false
	}
	fmt.eprintf("DEBUG _daemon_call RECV (%d bytes): %.200s\n", len(resp), string(resp))
	return string(resp), true
}

// =============================================================================
// Keychain — lazy-loaded, auto-resolves keys for MCP tools
// =============================================================================

_mcp_keychain: Keychain
_mcp_keychain_loaded: bool

// Priority: explicit key param > SHARD_KEY env > keychain entry > keychain wildcard.
_mcp_resolve_key :: proc(args: json.Object, shard_name: string) -> string {
	key := md_json_get_str(args, "key")
	if key != "" do return key

	if env_key, env_ok := os.lookup_env("SHARD_KEY"); env_ok && env_key != "" {
		return env_key
	}

	if !_mcp_keychain_loaded {
		_mcp_keychain, _ = keychain_load()
		_mcp_keychain_loaded = true
	}
	if kc_key, found := keychain_lookup(_mcp_keychain, shard_name); found {
		return kc_key
	}

	return ""
}

// =============================================================================
// Tool definitions
// =============================================================================

Tool_Def :: struct {
	name:        string,
	description: string,
	schema:      string, // JSON string for inputSchema
}

_tools := [?]Tool_Def {
	{
		name        = "shard_discover",
		description = "Your entry point — call this first at the start of every session before doing anything else. Returns a table of contents of all shards: names, purposes, thought counts, tags, and thought descriptions. One call costs ~500 tokens and gives you a complete map of all stored knowledge.\n\nUSAGE PATTERNS:\n- No params → full table of contents (your map). Always start here.\n- shard='name' → deep info card for one shard: catalog, gates, status, and all thought descriptions. Use this when you need to understand what a specific shard contains before querying it.\n- query='topic' → filtered TOC showing only shards relevant to a topic. Use when you know the domain but not the shard name.\n- refresh=true → re-scan disk before returning (use if you suspect a shard was added outside this session).\n\nNAMING CONVENTIONS you will encounter:\n- 'architecture', 'decisions', 'todos', 'milestones' — project-level knowledge\n- 'spec-*' — feature specifications (e.g. spec-search, spec-encryption)\n- 'code-*' — semantic code index, one per source file (e.g. code-blob, code-protocol)\n- Any other name — domain-specific knowledge the user has organized",
		schema      = `{"type":"object","properties":{"shard":{"type":"string","description":"Specific shard to inspect (returns catalog + gates + status + thoughts)"},"query":{"type":"string","description":"Filter shards by topic keyword"},"refresh":{"type":"boolean","description":"Re-scan .shards/ directory before returning results"}},"required":[]}`,
	},
	{
		name        = "shard_query",
		description = "Universal search across all shards or within one shard. This is your primary tool for finding stored knowledge after you have the map from shard_discover.\n\nUSAGE PATTERNS:\n- No shard → cross-shard search: scores all shards via gate relevance, searches the top matches, returns ranked results. Best for 'find anything about X' questions.\n- shard='name' → single-shard search: searches only that shard. Use when you already know where to look.\n- format='dump' → returns full shard content as a markdown document instead of scored results. Use when you want to read everything in a shard (e.g. dump a spec or decisions shard).\n- mode='fulltext' → searches inside thought bodies with surrounding context lines, not just descriptions. Use for finding specific phrases or code snippets.\n- depth>0 → follows wikilinks between shards (BFS traversal). Use to trace related concepts across shards.\n\nTOKEN EFFICIENCY: Always pass budget=2000 (or similar) to cap response size. If a result shows truncated:true, drill into that specific thought with shard_read. Start broad, then narrow — do not dump entire shards unless you need everything.\n\nEXAMPLES:\n- shard_query(query='encryption key derivation', budget=2000) → find relevant thoughts across all shards\n- shard_query(query='blob_flush', shard='code-blob') → search within the code-blob shard\n- shard_query(query='*', shard='decisions', format='dump') → read all decisions",
		schema      = `{"type":"object","properties":{"query":{"type":"string","description":"Search keywords or question"},"shard":{"type":"string","description":"Specific shard to search. Omit for global cross-shard search."},"format":{"type":"string","description":"Output format: results (default, scored list) or dump (full markdown document)","enum":["results","dump"]},"limit":{"type":"integer","description":"Max results (default 5)"},"threshold":{"type":"number","description":"Gate score threshold for cross-shard selection (0.0-1.0)"},"budget":{"type":"integer","description":"Max content chars in response (0 = unlimited)"},"depth":{"type":"integer","description":"Advanced: link-following depth for wikilink traversal (0 = flat)"},"mode":{"type":"string","description":"Search mode: omit for default scored results, 'fulltext' for windowed content body search","enum":["fulltext"]},"context_lines":{"type":"integer","description":"Lines of context above/below each hit in fulltext mode (0 = use config default)"}},"required":["query"]}`,
	},
	{
		name        = "shard_read",
		description = "Read the full decrypted content of a specific thought by its ID. Use this when shard_query returns a result but the content was truncated, or when you have an ID from a previous result and need the full body.\n\nREQUIRES: shard name + thought ID (32 hex chars). IDs come from shard_query results, shard_discover thought lists, or shard_write responses.\n\nUSAGE PATTERNS:\n- Normal (chain=false, default) → returns the thought's description + full content body.\n- chain=true → returns the full revision history from root to latest. Use when you want to see how a thought evolved over time, or before revising an important decision to understand its context.\n\nNOTE: Thoughts are encrypted at rest. The daemon decrypts transparently using the key from your keychain (~/.shards/keychain) or SHARD_KEY env var.",
		schema      = `{"type":"object","properties":{"shard":{"type":"string","description":"Shard name"},"id":{"type":"string","description":"Thought ID (32 hex chars)"},"chain":{"type":"boolean","description":"If true, return full revision chain (root to latest)"}},"required":["shard","id"]}`,
	},
	{
		name        = "shard_write",
		description = "Store or update a thought in a shard. Thoughts are the atomic unit of knowledge — one idea, one decision, one finding per thought.\n\nTHREE MODES:\n1. CREATE (no id, no revises): Stores a new thought. description is required and is the primary search surface — make it specific and searchable (e.g. 'blob_flush — atomic write to prevent partial corruption', not 'blob_flush notes'). content is the full body.\n2. UPDATE (id provided): Modifies an existing thought in-place. Only supply the fields you want to change. Use for minor corrections.\n3. REVISE (revises=<old-id>): Creates a new thought that supersedes the old one via a revision link. The old thought is preserved but marked as superseded. Use for significant updates to decisions, specs, or findings — preserves history.\n\nRULES:\n- Always set agent to identify yourself (e.g. 'claude', 'gpt-4o', your task name).\n- Always use revises when updating existing knowledge, not id (keeps history).\n- Never create a duplicate — query first if you're unsure whether something exists.\n- description field is indexed for search: be specific. Bad: 'notes about auth'. Good: 'auth — JWT expiry chosen over sessions for stateless scaling'.\n- Write architecture decisions, bug root causes, specs, findings, code intent. Do NOT write raw code dumps or temporary debug notes.\n\nEXAMPLES:\n- New finding: shard_write(shard='decisions', description='IPC framing — length-prefix chosen over newline-delimited for binary safety', content='...', agent='claude')\n- Revise a decision: shard_write(shard='decisions', description='IPC framing update — switched to u32 LE prefix', content='...', revises='<old-id>', agent='claude')",
		schema      = `{"type":"object","properties":{"shard":{"type":"string","description":"Shard name"},"description":{"type":"string","description":"Thought description (required for create, optional for update) — this is the primary search surface, make it specific"},"content":{"type":"string","description":"Thought body content"},"id":{"type":"string","description":"Thought ID to update in-place (omit for create or revise)"},"revises":{"type":"string","description":"Thought ID being superseded — creates a revision link, preserving history. Prefer this over id for significant updates."},"agent":{"type":"string","description":"Agent identity — always set this"}},"required":["shard"]}`,
	},
	{
		name        = "shard_delete",
		description = "Permanently delete a thought by ID. This is irreversible — the thought is removed from the shard file.\n\nUSE SPARINGLY. Prefer shard_write with revises to supersede outdated knowledge rather than deleting it. Only delete when the thought is genuinely wrong, a duplicate, or a test artifact.\n\nREQUIRES: shard name + thought ID (32 hex chars). Get IDs from shard_query or shard_discover.",
		schema      = `{"type":"object","properties":{"shard":{"type":"string","description":"Shard name"},"id":{"type":"string","description":"Thought ID (32 hex chars)"}},"required":["shard","id"]}`,
	},
	{
		name        = "shard_remember",
		description = "Create a new shard (a named knowledge container). Call this when no existing shard fits what you need to store. The shard is ready for writes immediately after creation.\n\nBEFORE CALLING: Always run shard_discover first to check what shards already exist. Creating duplicates wastes space and splits context.\n\nNAMING CONVENTIONS:\n- Source file index: 'code-<filename>' without extension (e.g. code-blob, code-protocol, code-main). One per source file.\n- Feature spec: 'spec-<slug>' (e.g. spec-search, spec-encryption, spec-multiagent).\n- Project-level: use existing 'architecture', 'decisions', 'todos', 'milestones' shards — do NOT create new ones for these.\n- Domain-specific: any meaningful lowercase-hyphenated name.\n\nGATES (positive field): List of topic keywords this shard accepts. The daemon uses gates for cross-shard routing — when a global query fires, gates determine which shards are scored. Be specific: ['blob_load', 'blob_flush', 'shard file format', 'SHRD0006'] is better than ['storage', 'files'].\n\nEXAMPLE:\nshard_remember(name='code-blob', purpose='Semantic code index for src/blob.odin — function intent, connections, design rationale', tags=['code-index', 'blob'], positive=['blob_load', 'blob_flush', 'shard file format', 'SHRD0006', 'atomic write', 'migration'])",
		schema      = `{"type":"object","properties":{"name":{"type":"string","description":"Shard name (used as filename and IPC identifier) — use naming conventions: code-<file>, spec-<slug>, or descriptive lowercase-hyphenated name"},"purpose":{"type":"string","description":"What this shard is for (free text) — be specific, this appears in shard_discover output"},"tags":{"type":"array","items":{"type":"string"},"description":"Catalog tags for discovery and routing"},"related":{"type":"array","items":{"type":"string"},"description":"Names of related shards"},"positive":{"type":"array","items":{"type":"string"},"description":"Gate keywords — topics this shard accepts. Used for cross-shard routing. Be specific."}},"required":["name","purpose"]}`,
	},
	{
		name        = "shard_events",
		description = "Read pending events for a shard, or emit an event to notify related shards of a change. Events are how agents stay in sync across sessions — the daemon records what changed and who changed it.\n\nREAD MODE (pass shard): Returns pending events since your last visit to that shard. Call this at the start of a session for shards you care about to see what other agents changed. Events include the source shard, event type, agent name, and timestamp.\n\nEMIT MODE (pass source + event_type): Broadcasts an event to all shards related to the source shard. Use after significant writes so other agents know to re-read. The daemon auto-emits events for most write ops — you only need this for manual coordination or cross-shard announcements.\n\nEVENT TYPES:\n- knowledge_changed → new or updated thoughts (most common, emitted automatically on write)\n- compacted → shard was compacted, thought IDs may have changed\n- gates_updated → shard's routing gates changed, re-routing needed\n- needs_compaction → shard has grown large and should be compacted\n\nEXAMPLE WORKFLOW: At session start, call shard_events(shard='decisions') to see if any decisions changed since you last worked. If events exist, re-read those shards before proceeding.",
		schema      = `{"type":"object","properties":{"shard":{"type":"string","description":"Shard name to get pending events for (read mode)"},"source":{"type":"string","description":"Shard emitting the event (emit mode) — the shard where the change occurred"},"event_type":{"type":"string","description":"Event type to emit","enum":["knowledge_changed","compacted","gates_updated","needs_compaction"]},"agent":{"type":"string","description":"Agent identity that caused the event"}},"required":[]}`,
	},
	{
		name        = "shard_stale",
		description = "Find thoughts in a shard that have not been accessed or updated recently and may need review. Returns thoughts sorted by staleness score (most stale first).\n\nUSE CASES:\n- Maintenance sessions: find outdated knowledge to update or prune.\n- Before a major refactor: identify which code-index thoughts describe code that has likely changed.\n- Quality audits: surface thoughts that have never been read or endorsed.\n\nTHRESHOLD: 0.0 = return everything, 1.0 = return only extremely stale thoughts. Default 0.5 is a good starting point. Lower it to cast a wider net.\n\nWORKFLOW: Run shard_stale → read each returned thought with shard_read → either revise it (shard_write with revises), delete it (shard_delete), or endorse it (shard_feedback with 'endorse') to reset its staleness.",
		schema      = `{"type":"object","properties":{"shard":{"type":"string","description":"Shard name"},"threshold":{"type":"number","description":"Minimum staleness score 0.0-1.0 (default 0.5). Higher = only the most stale thoughts."}},"required":["shard"]}`,
	},
	{
		name        = "shard_feedback",
		description = "Adjust a thought's relevance score by endorsing or flagging it. Scores affect ranking in shard_query results — endorsed thoughts surface higher, flagged thoughts sink lower.\n\nENDORSE: Use when a query returned a thought that was exactly right, when you read a thought and found it accurate and useful, or after you revise a thought to confirm it's current.\n\nFLAG: Use when a thought repeatedly appears in results but is not relevant, when content is misleading, or when it should be deleted but you want to confirm first.\n\nNOTE: Feedback is persistent — it compounds over multiple sessions. A thought endorsed three times will rank significantly higher than a new thought. Use deliberately, not reflexively.",
		schema      = `{"type":"object","properties":{"shard":{"type":"string","description":"Shard name"},"id":{"type":"string","description":"Thought ID (32 hex chars)"},"feedback":{"type":"string","description":"endorse to boost relevance, flag to reduce it","enum":["endorse","flag"]}},"required":["shard","id","feedback"]}`,
	},
	{
		name        = "shard_fleet",
		description = "Execute multiple shard operations in parallel in a single round-trip. Tasks on different shards run concurrently; tasks on the same shard are serialized automatically.\n\nUSE THIS WHEN:\n- You need to query several shards at once (e.g. load context from architecture + decisions + todos at session start).\n- You need to write findings to multiple shards after completing work.\n- You want to read multiple specific thoughts by ID simultaneously.\n\nSUPPORTED OPS per task: query, read, write, stale.\n\nEXAMPLE — load session context in one call:\nshard_fleet(tasks=[\n  {shard:'architecture', op:'query', query:'daemon IPC protocol'},\n  {shard:'decisions', op:'query', query:'encryption key handling'},\n  {shard:'todos', op:'query', query:'P0 P1 highest priority'}\n])\n\nEXAMPLE — write findings to multiple shards:\nshard_fleet(tasks=[\n  {shard:'decisions', op:'write', description:'chosen LRU for slot eviction', content:'...', agent:'claude'},\n  {shard:'architecture', op:'write', description:'slot eviction added to daemon loop', content:'...', agent:'claude'}\n])\n\nNOTE: Each task needs its own shard+op. The fleet op does not support cross-shard queries (use shard_query without a shard for that).",
		schema      = `{"type":"object","properties":{"tasks":{"type":"array","items":{"type":"object","properties":{"shard":{"type":"string","description":"Target shard name"},"op":{"type":"string","description":"Operation to run on this shard","enum":["query","read","write","stale"]},"description":{"type":"string","description":"For write: thought description (required, is the search surface)"},"content":{"type":"string","description":"For write: thought body"},"query":{"type":"string","description":"For query: search terms"},"id":{"type":"string","description":"For read: thought ID (32 hex chars)"},"agent":{"type":"string","description":"For write: agent identity — always set this"}},"required":["shard","op"]},"description":"Array of tasks to execute. Tasks on different shards run in parallel."}},"required":["tasks"]}`,
	},
	{
		name        = "shard_compact_suggest",
		description = "Analyze a shard and return a list of compaction suggestions without modifying anything. Safe to run at any time — read-only.\n\nWHAT IT FINDS:\n- Revision chains: sequences of thoughts where each revises the previous. These can be merged into one thought keeping the full history.\n- Duplicate thoughts: thoughts with near-identical descriptions or content.\n- Stale thoughts (lossy mode only): thoughts with very low staleness scores that have never been accessed.\n\nMODES:\n- lossless (default): only suggests merges and deduplication. No data loss possible.\n- lossy: also suggests pruning stale/low-value thoughts. Review suggestions carefully before applying.\n\nWORKFLOW: Run shard_compact_suggest → review the suggestions → pass the IDs to shard_compact to execute. Or use shard_compact_apply to do both in one call.",
		schema      = `{"type":"object","properties":{"shard":{"type":"string","description":"Shard name to analyze"},"mode":{"type":"string","description":"lossless (default, merges only) or lossy (also suggests pruning stale thoughts)","enum":["lossless","lossy"]}},"required":["shard"]}`,
	},
	{
		name        = "shard_compact",
		description = "Execute compaction on specific thought IDs returned by shard_compact_suggest. This modifies the shard — merged thoughts are combined, standalone thoughts are moved from unprocessed to processed storage.\n\nALWAYS run shard_compact_suggest first to get IDs and review what will happen. Never pass IDs you haven't verified.\n\nMODES:\n- lossless (default): merges revision chains, preserving all content in the merged thought. Standalone thoughts are processed (marked as reviewed).\n- lossy: additionally prunes stale thoughts. The thought content is gone after this — use only when you are sure the thought is no longer needed.\n\nAFTER COMPACTION: Thought IDs for merged chains change. If you have cached IDs from before compaction, re-query to get fresh IDs.",
		schema      = `{"type":"object","properties":{"shard":{"type":"string","description":"Shard name"},"ids":{"type":"array","items":{"type":"string"},"description":"Thought IDs to compact — get these from shard_compact_suggest"},"mode":{"type":"string","description":"lossless (default, preserves all content) or lossy (also prunes stale thoughts)","enum":["lossless","lossy"]}},"required":["shard","ids"]}`,
	},
	{
		name        = "shard_compact_apply",
		description = "One-shot auto-compaction: runs shard_compact_suggest internally, then immediately applies all suggestions. Equivalent to calling shard_compact_suggest + shard_compact in sequence.\n\nUSE WHEN: You want to clean up a shard without reviewing the suggestions first. Best for routine maintenance on shards you trust.\n\nUSE shard_compact_suggest + shard_compact INSTEAD WHEN: You want to review what will be changed before committing, or you're using lossy mode on an important shard.\n\nRETURNS: A combined report showing what was suggested and what was compacted.\n\nMODES:\n- lossless (default): merges revision chains, deduplicates. Safe.\n- lossy: also prunes stale thoughts. Destructive — use with care.",
		schema      = `{"type":"object","properties":{"shard":{"type":"string","description":"Shard name to auto-compact"},"mode":{"type":"string","description":"lossless (default) or lossy (also prunes stale thoughts)","enum":["lossless","lossy"]}},"required":["shard"]}`,
	},
	{
		name        = "shard_consumption_log",
		description = "View the activity log showing which agents accessed which shards and when. Daemon-level — no encryption key needed.\n\nUSE CASES:\n- Understand what other agents have been working on since your last session.\n- Find shards that have unprocessed thoughts but no recent agent visits (knowledge gaps).\n- Debug coordination issues between agents (e.g. two agents wrote conflicting thoughts).\n- See your own recent activity to avoid re-doing work.\n\nFILTERING:\n- No params → last 50 access records across all shards and agents.\n- shard='name' → activity for one specific shard.\n- agent='name' → activity by one specific agent.\n- limit=N → cap the number of records returned.",
		schema      = `{"type":"object","properties":{"shard":{"type":"string","description":"Filter by shard name (optional)"},"agent":{"type":"string","description":"Filter by agent name (optional)"},"limit":{"type":"integer","description":"Max records to return (default 50)"}},"required":[]}`,
	},
	{
		name        = "shard_cache_write",
		description = "Write a short-lived context entry to a named topic cache. The cache is shared across all agents — any agent that reads the same topic sees your entry. Use this for passing working context between agents or sessions without creating permanent shard thoughts.\n\nDIFFERENCE FROM shard_write:\n- shard_write → permanent, encrypted, versioned, indexed, searchable. Use for knowledge worth keeping.\n- shard_cache_write → ephemeral, shared scratchpad. Use for session hand-offs, intermediate results, coordination notes.\n\nUSE CASES:\n- Passing a summary of your findings to the next agent that will continue this task.\n- Sharing a computed result (e.g. a list of file paths, a parsed config) that another agent needs.\n- Leaving a note about what you changed so the next session knows where to continue.\n\nEVICTION: When the topic exceeds max_bytes, the oldest entries are dropped (FIFO). Set max_bytes=0 for unlimited.\n\nEXAMPLE: shard_cache_write(topic='refactor-progress', content='Completed ops_read.odin. Next: ops_write.odin. Key finding: slot lock is not released on error path.', agent='claude')",
		schema      = `{"type":"object","properties":{"topic":{"type":"string","description":"Cache topic name — use descriptive names like 'auth-refactor', 'session-handoff', 'build-results'"},"content":{"type":"string","description":"Context to cache"},"agent":{"type":"string","description":"Agent identity (optional but recommended)"},"max_bytes":{"type":"integer","description":"Max total bytes for this topic before oldest entries are evicted (set on first write; 0 = unlimited)"}},"required":["topic","content"]}`,
	},
	{
		name        = "shard_cache_read",
		description = "Read all cached entries for a topic, returned as a markdown document with agent and timestamp headers. Entries are in chronological order (oldest first).\n\nUSE CASES:\n- Pick up where another agent left off: read the topic they wrote before starting your work.\n- Check intermediate results a parallel agent produced.\n- Read session hand-off notes.\n\nNOTE: Call shard_cache_list first if you don't know what topics exist. Reading a non-existent topic returns an empty result.",
		schema      = `{"type":"object","properties":{"topic":{"type":"string","description":"Cache topic name to read"}},"required":["topic"]}`,
	},
	{
		name        = "shard_cache_list",
		description = "List all active cache topics with entry counts and total sizes. No params required.\n\nUSE THIS BEFORE shard_cache_write: check if a topic already exists before creating a new one — you may want to append to an existing topic rather than start a new one.\n\nUSE THIS TO DISCOVER: what shared context is currently available — other agents may have left notes, results, or hand-off summaries you should read before starting work.",
		schema      = `{"type":"object","properties":{},"required":[]}`,
	},
	{
		name        = "shard_dump",
		description = "Export shards as markdown files to a folder on disk. Each shard becomes a .md file with YAML frontmatter, wikilinks, and organized thought content. Generates an index.md with table of contents and tag index.\n\nUSAGE PATTERNS:\n- path='dump/' → export all shards to the dump/ folder\n- path='export/', shard='decisions' → export only the decisions shard\n\nThe output is compatible with Obsidian, Logseq, and other markdown tools. Reports broken [[wikilinks]] in the response.\n\nREQUIRES: path is required. Keys resolved from keychain or SHARD_KEY env.",
		schema      = `{"type":"object","properties":{"path":{"type":"string","description":"Output directory for exported markdown files (required)"},"shard":{"type":"string","description":"Export only this shard (optional, default: all shards)"}},"required":["path"]}`,
	},
}

// =============================================================================
// Response builders
// =============================================================================

_mcp_result :: proc(id_val: json.Value, result_json: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"jsonrpc":"2.0","id":`)
	write_json_value(&b, id_val)
	strings.write_string(&b, `,"result":`)
	strings.write_string(&b, result_json)
	strings.write_string(&b, `}`)
	return strings.to_string(b)
}

_mcp_error :: proc(id_val: json.Value, code: int, message: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"jsonrpc":"2.0","id":`)
	write_json_value(&b, id_val)
	strings.write_string(&b, `,"error":{"code":`)
	fmt.sbprintf(&b, "%d", code)
	strings.write_string(&b, `,"message":"`)
	strings.write_string(&b, json_escape(message))
	strings.write_string(&b, `"}}`)
	return strings.to_string(b)
}

_mcp_tool_result :: proc(id_val: json.Value, text: string, is_error: bool = false) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"jsonrpc":"2.0","id":`)
	write_json_value(&b, id_val)
	strings.write_string(&b, `,"result":{"content":[{"type":"text","text":"`)
	strings.write_string(&b, json_escape(text))
	strings.write_string(&b, `"}]`)
	if is_error {
		strings.write_string(&b, `,"isError":true`)
	}
	strings.write_string(&b, `}}`)
	return strings.to_string(b)
}

// =============================================================================
// MCP message handlers
// =============================================================================

// MCP_INSTRUCTIONS is injected into the initialize response as the `instructions` field.
// MCP hosts (Claude Code, Cursor, etc.) surface this to the model as server-level guidance.
// This is the primary channel for teaching the model how to use shard correctly — no external
// config files, agent definitions, or documentation files are needed. The binary is self-contained.
MCP_INSTRUCTIONS :: `You are connected to Shard, an encrypted knowledge store for AI agents. Follow these rules exactly.

## Session Start (required every session)

1. Call shard_discover with no params. This returns a table of contents of all shards — names, purposes, thought counts, thought descriptions. It is your map. Always do this first, before any other call.
2. Call shard_events(shard='<name>') for any shard relevant to your current task, to see what other agents changed since your last session.
3. Call shard_query with budget=2000 to load targeted context. Do not dump entire shards unless you need everything.

## Writing Knowledge

- Use shard_write for permanent knowledge: architecture decisions, bug root causes, code intent, specs, findings.
- Always set the agent field on every write (use your model name or task name).
- Always use revises=<old-id> when updating existing knowledge — never create a duplicate thought. Query first if unsure whether something exists.
- The description field is the primary search surface. Make it specific: 'blob_flush — atomic write prevents partial file corruption on crash' not 'blob_flush notes'.
- Do NOT write: raw code dumps, temporary debug notes, things already in CONCEPT.txt or this server's instructions.

## Shard Naming Conventions

- Source file index: code-<filename> without extension (code-blob, code-protocol, code-main). One per source file.
- Feature specs: spec-<slug> (spec-search, spec-auth, spec-multiagent).
- Project-level: use existing architecture, decisions, todos, milestones shards. Do not create new ones for these.
- Before creating any shard with shard_remember, run shard_discover to confirm no suitable shard already exists.

## Token Efficiency

- shard_discover → shard_query(budget:2000) → shard_read (only if truncated). This pattern costs ~800-2800 tokens total.
- Never dump an entire shard unless you genuinely need all of it (use format=dump only then).
- Use shard_fleet to batch multiple queries or writes into one round-trip.

## Maintenance

- Use shard_compact_apply(mode='lossless') periodically on shards that grow large.
- Use shard_stale to find outdated thoughts; revise or delete them.
- Use shard_feedback(feedback='endorse') when a query returned exactly what you needed — it improves future rankings.`

_handle_initialize :: proc(id_val: json.Value) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"protocolVersion":"`)
	strings.write_string(&b, MCP_PROTOCOL_VERSION)
	strings.write_string(&b, `","capabilities":{"tools":{}},"serverInfo":{"name":"`)
	strings.write_string(&b, MCP_SERVER_NAME)
	strings.write_string(&b, `","version":"`)
	strings.write_string(&b, MCP_SERVER_VERSION)
	strings.write_string(&b, `"},"instructions":"`)
	strings.write_string(&b, json_escape(MCP_INSTRUCTIONS))
	strings.write_string(&b, `"}`)
	return _mcp_result(id_val, strings.to_string(b))
}

_handle_tools_list :: proc(id_val: json.Value) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"tools":[`)
	for tool, i in _tools {
		if i > 0 do strings.write_string(&b, `,`)
		strings.write_string(&b, `{"name":"`)
		strings.write_string(&b, tool.name)
		strings.write_string(&b, `","description":"`)
		strings.write_string(&b, json_escape(tool.description))
		strings.write_string(&b, `","inputSchema":`)
		strings.write_string(&b, tool.schema)
		strings.write_string(&b, `}`)
	}
	strings.write_string(&b, `]}`)
	return _mcp_result(id_val, strings.to_string(b))
}

_handle_tools_call :: proc(id_val: json.Value, params: json.Object) -> string {
	tool_name := md_json_get_str(params, "name")
	args, args_ok := md_json_get_obj(params, "arguments")
	if !args_ok {
		return _mcp_error(id_val, -32602, "missing arguments")
	}

	switch tool_name {
	case "shard_discover":
		return _tool_discover(id_val, args)
	case "shard_query":
		return _tool_query(id_val, args)
	case "shard_read":
		return _tool_read(id_val, args)
	case "shard_write":
		return _tool_write(id_val, args)
	case "shard_delete":
		return _tool_delete(id_val, args)
	case "shard_remember":
		return _tool_remember(id_val, args)
	case "shard_events":
		return _tool_events(id_val, args)
	case "shard_stale":
		return _tool_stale(id_val, args)
	case "shard_feedback":
		return _tool_feedback(id_val, args)
	case "shard_fleet":
		return _tool_fleet(id_val, args)
	case "shard_compact_suggest":
		return _tool_compact_suggest(id_val, args)
	case "shard_compact":
		return _tool_compact(id_val, args)
	case "shard_compact_apply":
		return _tool_compact_apply(id_val, args)
	case "shard_consumption_log":
		return _tool_consumption_log(id_val, args)
	case "shard_cache_write":
		return _tool_cache_write(id_val, args)
	case "shard_cache_read":
		return _tool_cache_read(id_val, args)
	case "shard_cache_list":
		return _tool_cache_list(id_val, args)
	case "shard_dump":
		return _tool_dump(id_val, args)
	case:
		return _mcp_error(id_val, -32602, fmt.tprintf("unknown tool: %s", tool_name))
	}
}

// =============================================================================
// Daemon auto-start — spawns the daemon if it isn't running
// =============================================================================

// _daemon_auto_start checks if the daemon is reachable. If not, spawns it as
// a background process using the current executable with the "daemon" argument.
// Returns true if the daemon is reachable (was already running or started successfully).
@(private)
_daemon_auto_start :: proc() -> bool {
	// Quick probe: try to connect
	probe, ok := ipc_connect(DAEMON_NAME)
	if ok {
		ipc_close_conn(probe)
		debug("daemon already running")
		return true
	}

	// Daemon not running — spawn it
	info("daemon not running, starting it...")

	exe_path := os.args[0]
	process, err := os2.process_start(os2.Process_Desc{command = {exe_path, "daemon"}})
	if err != nil {
		errf("failed to start daemon: %v", err)
		return false
	}

	// Detach — we don't wait for the daemon to exit
	close_err := os2.process_close(process)
	if close_err != nil {
		warnf("could not detach daemon handle: %v", close_err)
	}

	// Wait for the daemon to come up (ipc_connect already retries internally,
	// but we do a brief sleep first to let the daemon create the IPC endpoint)
	time.sleep(500 * time.Millisecond)

	probe2, ok2 := ipc_connect(DAEMON_NAME)
	if ok2 {
		ipc_close_conn(probe2)
		info("daemon started successfully")
		return true
	}

	warn("daemon started but not yet reachable — will retry on first tool call")
	return true // process was spawned; _daemon_get will retry on first use
}

// =============================================================================
// Main MCP loop — reads JSON-RPC from stdin, dispatches, writes to stdout
// =============================================================================

run_mcp :: proc() {
	info("starting MCP server on stdio")

	// Load config
	config_load()

	// Auto-start daemon if not running
	_daemon_auto_start()

	// Read lines from stdin
	buf := make([]u8, 65536) // 64KB read buffer
	defer delete(buf)
	line_builder := strings.builder_make()
	defer strings.builder_destroy(&line_builder)

	for {
		n, err := os.read(os.stdin, buf[:])
		if err != nil || n <= 0 do break

		// Append to line builder and process complete lines
		strings.write_bytes(&line_builder, buf[:n])
		accumulated := strings.to_string(line_builder)

		for {
			nl := strings.index(accumulated, "\n")
			if nl == -1 do break

			line := strings.trim_right(accumulated[:nl], "\r")
			accumulated = accumulated[nl + 1:]

			if strings.trim_space(line) == "" do continue

			resp := _process_jsonrpc(line)
			if resp != "" {
				fmt.println(resp)
			}
		}

		// Keep any remaining partial line
		if accumulated != "" {
			remainder := strings.clone(accumulated)
			strings.builder_reset(&line_builder)
			strings.write_string(&line_builder, remainder)
			delete(remainder)
		} else {
			strings.builder_reset(&line_builder)
		}
	}

	// Cleanup daemon connection
	_daemon_invalidate()
	info("MCP server stopped")
}

_process_jsonrpc :: proc(line: string) -> string {
	// Parse JSON — allocate into temp so the tree is freed at end of message cycle
	parsed, parse_err := json.parse(transmute([]u8)line, allocator = context.temp_allocator)
	if parse_err != nil {
		return _mcp_error(json.Value(nil), -32700, "parse error")
	}
	defer json.destroy_value(parsed, context.temp_allocator)

	obj, is_obj := parsed.(json.Object)
	if !is_obj {
		return _mcp_error(json.Value(nil), -32600, "invalid request")
	}

	method := md_json_get_str(obj, "method")
	id_val, has_id := obj["id"]

	// Notifications have no id — no response expected
	if !has_id || method == "notifications/initialized" {
		debugf("notification: %s", method)
		return ""
	}

	switch method {
	case "initialize":
		return _handle_initialize(id_val)
	case "tools/list":
		return _handle_tools_list(id_val)
	case "tools/call":
		params, params_ok := md_json_get_obj(obj, "params")
		if !params_ok {
			return _mcp_error(id_val, -32602, "missing params")
		}
		return _handle_tools_call(id_val, params)
	case:
		return _mcp_error(id_val, -32601, fmt.tprintf("method not found: %s", method))
	}
}
