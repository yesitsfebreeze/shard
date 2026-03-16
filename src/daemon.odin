package shard

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

// =============================================================================
// Daemon — a shard that manages other shards in-process
// =============================================================================
//
// The daemon is a normal shard process at a fixed IPC endpoint (name = "daemon").
// It loads other shard blobs in-process on demand, routes operations by the
// `name:` field in requests, and exposes the registry (with gates) so AIs can
// decide which shard to query.
//
// IPC endpoint:
//   Windows:    \\.\pipe\shard-daemon
//   POSIX:      /tmp/shard-daemon.sock
//

// =============================================================================
// Daemon dispatch — routes ops that are daemon-level
// =============================================================================

daemon_dispatch :: proc(node: ^Node, req: Request, allocator := context.allocator) -> (string, bool) {
	// Daemon-level ops (no shard name needed)
	switch req.op {
	case "registry":  return _op_registry(node, req, allocator), true
	case "discover":  return _op_discover(node, allocator), true
	case "remember":  return _op_remember(node, req, allocator), true
	case "traverse":  return _op_traverse(node, req, allocator), true
	}

	// If a name is specified and it's not the daemon itself, route to a slot
	if req.name != "" && req.name != DAEMON_NAME {
		return _op_route_to_slot(node, req, allocator), true
	}

	// Fall through to normal shard dispatch (ops on the daemon's own blob)
	return "", false
}

// =============================================================================
// Registry — list known shards with gates for AI routing
// =============================================================================

@(private)
_op_registry :: proc(node: ^Node, req: Request, allocator := context.allocator) -> string {
	if req.query != "" {
		q_tokens := _tokenize(req.query, context.temp_allocator)
		defer delete(q_tokens, context.temp_allocator)
		filtered := make([dynamic]Registry_Entry, context.temp_allocator)
		defer delete(filtered)
		for entry in node.registry {
			if _registry_matches(entry, q_tokens) {
				append(&filtered, entry)
			}
		}
		return _marshal(Response{status = "ok", registry = filtered[:]}, allocator)
	}
	return _marshal(Response{status = "ok", registry = node.registry[:]}, allocator)
}

// discover re-scans the .shards/ directory and refreshes the registry.
@(private)
_op_discover :: proc(node: ^Node, allocator := context.allocator) -> string {
	daemon_scan_shards(node)
	index_build(node)
	return _marshal(Response{status = "ok", registry = node.registry[:]}, allocator)
}

// =============================================================================
// remember — create a new shard with catalog and gates in one shot
// =============================================================================
//
// Used by AI agents to self-organize: when a thought doesn't fit any
// existing shard's gates, the AI creates a new category on the fly.
//
//   ---
//   op: remember
//   name: quantum-physics
//   purpose: notes on quantum mechanics
//   tags: [physics, quantum]
//   items: [quantum, entanglement, superposition]
//   related: [chemistry, math]
//   ---
//
// The 'items' field sets the positive gate. Negative gate and description
// gate can be set afterward via set_negative / set_description on the shard.
//

// MAX_SHARDS is now configurable via .shards/config (max_shards)

@(private)
_op_remember :: proc(node: ^Node, req: Request, allocator := context.allocator) -> string {
	if req.name == "" do return _err_response("name required", allocator)
	if req.name == DAEMON_NAME do return _err_response("cannot use reserved name 'daemon'", allocator)
	if !_valid_shard_name(req.name) do return _err_response("invalid shard name (must be alphanumeric, hyphens, underscores only)", allocator)

	// Check if shard already exists
	for entry in node.registry {
		if entry.name == req.name {
			return _err_response(fmt.tprintf("shard '%s' already exists", req.name), allocator)
		}
	}

	// Guard against unbounded growth
	max_shards := config_get().max_shards
	if len(node.registry) >= max_shards {
		return _err_response(fmt.tprintf("shard limit reached (%d)", max_shards), allocator)
	}

	// Create the .shard file
	data_path := fmt.aprintf(".shards/%s.shard", req.name)
	os.make_directory(".shards")

	zero_key: Master_Key
	blob, ok := blob_load(data_path, zero_key)
	if !ok {
		return _err_response(fmt.tprintf("could not create shard file: %s", data_path), allocator)
	}

	// Set catalog
	blob.catalog = Catalog{
		name    = strings.clone(req.name),
		purpose = strings.clone(req.purpose),
		tags    = _clone_strings(req.tags),
		related = _clone_strings(req.related),
		created = _format_time(time.now()),
	}

	// Set positive gate from items
	if req.items != nil && len(req.items) > 0 {
		for item in req.items {
			append(&blob.positive, strings.clone(item))
		}
	}

	if !blob_flush(&blob) {
		return _err_response("could not write shard file", allocator)
	}

	append(&node.registry, _registry_entry_from_blob(req.name, data_path, blob))
	_daemon_persist(node)
	index_update_shard(node, req.name)

	fmt.eprintfln("daemon: created shard '%s' via remember", req.name)
	return _marshal(Response{status = "ok", catalog = blob.catalog}, allocator)
}

// =============================================================================
// Slot routing — load a shard in-process and dispatch the op against it
// =============================================================================

@(private)
_op_route_to_slot :: proc(node: ^Node, req: Request, allocator := context.allocator) -> string {
	// Find the registry entry
	entry_idx := -1
	for e, i in node.registry {
		if e.name == req.name {
			entry_idx = i
			break
		}
	}
	if entry_idx < 0 {
		return _err_response(fmt.tprintf("shard '%s' not in registry", req.name), allocator)
	}

	entry := &node.registry[entry_idx]

	// Get or create the slot
	slot := _slot_get_or_create(node, entry)

	// Ensure the blob is loaded
	if !slot.loaded {
		if !_slot_load(slot, req.key) {
			return _err_response(fmt.tprintf("could not load shard '%s'", req.name), allocator)
		}
	}

	// If a key is provided and we haven't keyed this slot yet, try to key it
	if req.key != "" && !slot.key_set {
		_slot_set_key(slot, req.key)
	}

	// Verify key for encrypted ops
	if _op_requires_key(req.op) {
		if !_slot_verify_key(slot, req.key) {
			return _err_response("key required (provide key: <64-hex> in request)", allocator)
		}
	}

	slot.last_access = time.now()

	// Dispatch against the slot's blob
	result := _slot_dispatch(slot, req, allocator)

	// If gates changed, sync to registry and re-index
	if _op_modifies_gates(req.op) {
		_sync_slot_gates(entry, slot)
		_daemon_persist(node)
		index_update_shard(node, entry.name)
	}

	return result
}

// _slot_dispatch runs a shard op against a loaded slot.
@(private)
_slot_dispatch :: proc(slot: ^Shard_Slot, req: Request, allocator := context.allocator) -> string {
	// Build a temporary node so we can reuse existing op handlers
	temp_node := Node{
		name  = slot.name,
		blob  = slot.blob,
		index = slot.index,
	}

	result: string
	switch req.op {
	// Gate ops
	case "description":     result = _op_gate_read(slot.blob.description[:], allocator)
	case "positive":        result = _op_gate_read(slot.blob.positive[:], allocator)
	case "negative":        result = _op_gate_read(slot.blob.negative[:], allocator)
	case "related":         result = _op_gate_read(slot.blob.related[:], allocator)
	case "set_description": result = _op_gate_write(&temp_node, &temp_node.blob.description, req.items, allocator)
	case "set_positive":    result = _op_gate_write(&temp_node, &temp_node.blob.positive,    req.items, allocator)
	case "set_negative":    result = _op_gate_write(&temp_node, &temp_node.blob.negative,    req.items, allocator)
	case "set_related":     result = _op_gate_write(&temp_node, &temp_node.blob.related,     req.items, allocator)
	case "link":            result = _op_link(&temp_node, req, allocator)
	case "unlink":          result = _op_unlink(&temp_node, req, allocator)
	// Catalog ops
	case "catalog":         result = _op_catalog(&temp_node, allocator)
	case "set_catalog":     result = _op_set_catalog(&temp_node, req, allocator)
	// Content ops
	case "write":           result = _op_write(&temp_node, req, allocator)
	case "read":            result = _op_read(&temp_node, req, allocator)
	case "update":          result = _op_update(&temp_node, req, allocator)
	case "list":            result = _op_list(&temp_node, allocator)
	case "delete":          result = _op_delete(&temp_node, req, allocator)
	case "search":          result = _op_search(&temp_node, req, allocator)
	case "query":           result = _op_query(&temp_node, req, allocator)
	case "compact":         result = _op_compact(&temp_node, req, allocator)
	case "dump":            result = _op_dump(&temp_node, allocator)
	case "gates":           result = _op_gates(&temp_node, allocator)
	case "manifest":        result = _op_manifest(&temp_node, req, allocator)
	case "status":          result = _op_status(&temp_node, allocator)
	case:
		result = _err_response(fmt.tprintf("unknown op: %s", req.op), allocator)
	}

	// Sync changes back to the slot
	slot.blob  = temp_node.blob
	slot.index = temp_node.index

	return result
}

// =============================================================================
// Slot management — lazy loading, key handling, eviction
// =============================================================================

@(private)
_slot_get_or_create :: proc(node: ^Node, entry: ^Registry_Entry) -> ^Shard_Slot {
	if slot, ok := node.slots[entry.name]; ok {
		return slot
	}
	slot := new(Shard_Slot)
	slot.name      = entry.name
	slot.data_path = entry.data_path
	slot.loaded    = false
	slot.key_set   = false
	slot.last_access = time.now()
	node.slots[entry.name] = slot
	return slot
}

// _slot_load loads the blob from disk. If key_hex is provided, uses it;
// otherwise loads with zero key (only plaintext fields accessible).
@(private)
_slot_load :: proc(slot: ^Shard_Slot, key_hex: string = "") -> bool {
	master: Master_Key
	has_key := false

	if key_hex != "" {
		if k, ok := hex_to_key(key_hex); ok {
			master = k
			has_key = true
		}
	}

	blob, ok := blob_load(slot.data_path, master)
	if !ok do return false

	slot.blob   = blob
	slot.loaded = true
	slot.master = master
	slot.key_set = has_key

	// Build search index if we have a key
	if has_key {
		_slot_build_index(slot)
	}

	return true
}

// _slot_set_key re-keys a loaded slot (builds the search index).
@(private)
_slot_set_key :: proc(slot: ^Shard_Slot, key_hex: string) {
	k, ok := hex_to_key(key_hex)
	if !ok do return

	slot.master = k
	slot.blob.master = slot.master
	slot.key_set = true
	_slot_build_index(slot)
}

@(private)
_slot_build_index :: proc(slot: ^Shard_Slot) {
	build_search_index(&slot.index, slot.blob, slot.master, fmt.tprintf("daemon/%s", slot.name))
}

@(private)
_slot_verify_key :: proc(slot: ^Shard_Slot, key_hex: string) -> bool {
	if !slot.key_set do return false
	k, ok := hex_to_key(key_hex)
	if !ok do return false
	diff: u8 = 0
	for i in 0..<32 do diff |= k[i] ~ slot.master[i]
	return diff == 0
}

@(private)
_op_requires_key :: proc(op: string) -> bool {
	switch op {
	case "write", "read", "update", "delete", "search", "query", "compact", "dump":
		return true
	}
	return false
}

// daemon_evict_idle flushes and unloads shard blobs that haven't been
// accessed within max_idle. Called periodically from the event loop.
daemon_evict_idle :: proc(node: ^Node, max_idle: time.Duration) {
	now := time.now()
	to_evict := make([dynamic]string, context.temp_allocator)

	for name, slot in node.slots {
		if !slot.loaded do continue
		idle := time.diff(slot.last_access, now)
		if idle >= max_idle {
			blob_flush(&slot.blob)
			slot.loaded = false
			slot.key_set = false
			for &entry in slot.index do delete(entry.embedding)
			clear(&slot.index)
			fmt.eprintfln("daemon: evicted idle shard '%s'", name)
		}
	}
}

// daemon_flush_all flushes all loaded shard blobs. Called on shutdown.
daemon_flush_all :: proc(node: ^Node) {
	for name, slot in node.slots {
		if slot.loaded {
			blob_flush(&slot.blob)
			fmt.eprintfln("daemon: flushed shard '%s'", name)
		}
	}
}

// =============================================================================
// Auto-discovery — scan .shards/ directory for shard files
// =============================================================================

daemon_scan_shards :: proc(node: ^Node) {
	dir_handle, err := os.open(".shards")
	if err != nil do return
	defer os.close(dir_handle)

	entries, read_err := os.read_dir(dir_handle, 0)
	if read_err != nil do return

	for entry in entries {
		name := entry.name
		// Skip non-.shard files and the daemon's own file
		if !strings.has_suffix(name, ".shard") do continue
		if name == "daemon.shard" do continue

		shard_name := name[:len(name) - 6] // strip ".shard"
		data_path := fmt.tprintf(".shards/%s", name)

		// Skip if already in registry
		already := false
		for &reg in node.registry {
			if reg.name == shard_name {
				already = true
				// Refresh gates from disk
				_refresh_registry_entry(&reg, data_path)
				break
			}
		}
		if already do continue

		// Load blob with zero key to read plaintext metadata
		zero_key: Master_Key
		blob, ok := blob_load(strings.clone(data_path), zero_key)
		if !ok do continue

		total := len(blob.processed) + len(blob.unprocessed)
		append(&node.registry, _registry_entry_from_blob(shard_name, data_path, blob))
		fmt.eprintfln("daemon: discovered shard '%s' (%d thoughts)", shard_name, len(blob.processed) + len(blob.unprocessed))
	}

	_daemon_persist(node)
}

// _refresh_registry_entry reloads gates and catalog from disk for a known entry.
@(private)
_refresh_registry_entry :: proc(entry: ^Registry_Entry, data_path: string) {
	zero_key: Master_Key
	blob, ok := blob_load(data_path, zero_key)
	if !ok do return

	fresh := _registry_entry_from_blob(entry.name, data_path, blob)
	entry.thought_count = fresh.thought_count
	entry.catalog       = fresh.catalog
	entry.gate_desc     = fresh.gate_desc
	entry.gate_positive = fresh.gate_positive
	entry.gate_negative = fresh.gate_negative
	entry.gate_related  = fresh.gate_related
}

// =============================================================================
// Persistence — registry stored as JSON in the daemon's blob manifest
// =============================================================================

_daemon_persist :: proc(node: ^Node) {
	data, err := json.marshal(node.registry[:])
	if err != nil do return
	defer delete(data)
	node.blob.manifest = strings.clone(string(data))
	blob_flush(&node.blob)
}

daemon_load_registry :: proc(node: ^Node) {
	if node.blob.manifest == "" do return

	entries: [dynamic]Registry_Entry
	if err := json.unmarshal(transmute([]u8)node.blob.manifest, &entries); err == nil {
		node.registry = entries
		fmt.eprintfln("daemon: loaded %d shards from registry", len(entries))
	}
}

// =============================================================================
// traverse — Layer-0 gate filtering with ranked results
// =============================================================================
//
// Evaluates all registered shards' gates against a query and returns
// candidates ranked by gate relevance score. This is the foundation
// for layered shard traversal — Layer 0 (gate surface) filtering.
//
// Request:
//   op: traverse
//   query: <keywords>
//   max_branches: <int, default 5>
//
// Response:
//   status: ok
//   results:
//     - id: <shard-name>
//       score: <0.0-1.0>
//       description: <catalog purpose>
//       content: <matched gate keywords>
//

Gate_Score :: struct {
	name:     string,
	score:    f32,
	purpose:  string,
	matched:  [dynamic]string,
}

@(private)
_op_traverse :: proc(node: ^Node, req: Request, allocator := context.allocator) -> string {
	if req.query == "" do return _err_response("query required", allocator)

	max_branches := req.max_branches > 0 ? req.max_branches : 5

	// Vector search (if index is available)
	if len(node.vec_index.entries) > 0 {
		results := index_query(node, req.query, max_branches * 2, context.temp_allocator)
		if results != nil && len(results) > 0 {
			q_tokens := _tokenize(req.query, context.temp_allocator)
			defer delete(q_tokens, context.temp_allocator)
			wire := make([dynamic]Wire_Result, allocator)
			for r in results {
				if len(wire) >= max_branches do break
				purpose := ""
				rejected := false
				for entry in node.registry {
					if entry.name == r.name {
						purpose = entry.catalog.purpose
						if entry.gate_negative != nil {
							rejected = _negative_gate_rejects(entry.gate_negative, q_tokens)
						}
						break
					}
				}
				if rejected do continue
				append(&wire, Wire_Result{
					id          = strings.clone(r.name, allocator),
					score       = r.score,
					description = strings.clone(purpose, allocator),
				})
			}
			if len(wire) > 0 {
				return _marshal(Response{status = "ok", results = wire[:]}, allocator)
			}
		}
	}

	// Keyword fallback
	q_tokens := _tokenize(req.query, context.temp_allocator)
	defer delete(q_tokens, context.temp_allocator)
	if len(q_tokens) == 0 do return _err_response("query produced no tokens", allocator)

	scored := make([dynamic]Gate_Score, context.temp_allocator)
	defer delete(scored)

	for entry in node.registry {
		gs := _score_gates(entry, q_tokens)
		if gs.score > 0 {
			append(&scored, gs)
		}
	}

	// Sort by score descending (insertion sort — fine for typical registry sizes)
	for i := 1; i < len(scored); i += 1 {
		key := scored[i]
		j := i - 1
		for j >= 0 && scored[j].score < key.score {
			scored[j + 1] = scored[j]
			j -= 1
		}
		scored[j + 1] = key
	}

	// Cap to max_branches
	count := min(len(scored), max_branches)

	wire := make([dynamic]Wire_Result, allocator)
	for i in 0 ..< count {
		gs := scored[i]
		// Build matched keywords string
		matched_str := ""
		if len(gs.matched) > 0 {
			matched_str = strings.join(gs.matched[:], ", ", allocator)
		}
		append(&wire, Wire_Result{
			id          = strings.clone(gs.name, allocator),
			score       = gs.score,
			description = strings.clone(gs.purpose, allocator),
			content     = matched_str,
		})
	}

	return _marshal(Response{status = "ok", results = wire[:]}, allocator)
}

@(private)
_negative_gate_rejects :: proc(gate_negative: []string, q_tokens: []string) -> bool {
	for neg in gate_negative {
		neg_tokens := _tokenize(neg, context.temp_allocator)
		defer delete(neg_tokens, context.temp_allocator)
		for qt in q_tokens {
			qt_stem := _stem(qt)
			for nt in neg_tokens {
				if qt == nt || qt_stem == _stem(nt) do return true
			}
		}
	}
	return false
}

// _score_gates evaluates a registry entry's gates against query tokens.
// Scoring:
//   - Negative gate match → score clamped to 0 (reject)
//   - Positive gate match → +2 per token (strong accept signal)
//   - Description gate match → +1 per token
//   - Catalog name/purpose/tags match → +1 per token
//   - Score normalized to 0.0-1.0 range
@(private)
_score_gates :: proc(entry: Registry_Entry, q_tokens: []string) -> Gate_Score {
	result: Gate_Score
	result.name    = entry.name
	result.purpose = entry.catalog.purpose
	result.matched = make([dynamic]string, context.temp_allocator)

	raw_score: f32 = 0
	max_possible: f32 = f32(len(q_tokens)) * 2 // max if all tokens match positive gate
	if max_possible == 0 { return result }

	// Check negative gate — any match rejects this shard
	if entry.gate_negative != nil {
		for neg in entry.gate_negative {
			neg_tokens := _tokenize(neg, context.temp_allocator)
			defer delete(neg_tokens, context.temp_allocator)
			for qt in q_tokens {
				for nt in neg_tokens {
					if qt == nt {
						result.score = 0
						return result
					}
				}
			}
		}
	}

	// Track which query tokens have matched (for dedup)
	matched_set: map[string]bool
	defer delete(matched_set)

	// Positive gate — strongest signal (+2 per match)
	if entry.gate_positive != nil {
		for pos in entry.gate_positive {
			pos_tokens := _tokenize(pos, context.temp_allocator)
			defer delete(pos_tokens, context.temp_allocator)
			for qt in q_tokens {
				if qt in matched_set do continue
				for pt in pos_tokens {
					if qt == pt {
						raw_score += 2
						matched_set[qt] = true
						append(&result.matched, qt)
						break
					}
				}
			}
		}
	}

	// Description gate (+1 per match)
	if entry.gate_desc != nil {
		for desc in entry.gate_desc {
			desc_tokens := _tokenize(desc, context.temp_allocator)
			defer delete(desc_tokens, context.temp_allocator)
			for qt in q_tokens {
				if qt in matched_set do continue
				for dt in desc_tokens {
					if qt == dt {
						raw_score += 1
						matched_set[qt] = true
						append(&result.matched, qt)
						break
					}
				}
			}
		}
	}

	// Catalog name (+1 per match)
	cat_name := entry.catalog.name != "" ? entry.catalog.name : entry.name
	name_tokens := _tokenize(cat_name, context.temp_allocator)
	defer delete(name_tokens, context.temp_allocator)
	for qt in q_tokens {
		if qt in matched_set do continue
		for nt in name_tokens {
			if qt == nt {
				raw_score += 1
				matched_set[qt] = true
				append(&result.matched, qt)
				break
			}
		}
	}

	// Catalog purpose (+1 per match)
	if entry.catalog.purpose != "" {
		purpose_tokens := _tokenize(entry.catalog.purpose, context.temp_allocator)
		defer delete(purpose_tokens, context.temp_allocator)
		for qt in q_tokens {
			if qt in matched_set do continue
			for pt in purpose_tokens {
				if qt == pt {
					raw_score += 1
					matched_set[qt] = true
					append(&result.matched, qt)
					break
				}
			}
		}
	}

	// Catalog tags (+1 per match)
	if entry.catalog.tags != nil {
		for tag in entry.catalog.tags {
			tag_tokens := _tokenize(tag, context.temp_allocator)
			defer delete(tag_tokens, context.temp_allocator)
			for qt in q_tokens {
				if qt in matched_set do continue
				for tt in tag_tokens {
					if qt == tt {
						raw_score += 1
						matched_set[qt] = true
						append(&result.matched, qt)
						break
					}
				}
			}
		}
	}

	// Normalize to 0.0-1.0
	result.score = min(raw_score / max_possible, 1.0)
	return result
}

// =============================================================================
// Helpers
// =============================================================================

_format_time :: proc(t: time.Time) -> string {
	y, mon, d := time.date(t)
	h, m, s := time.clock(t)
	return fmt.tprintf("%04d-%02d-%02dT%02d:%02d:%02dZ", y, int(mon), d, h, m, s)
}

_clone_catalog :: proc(cat: Catalog, fallback_name: string = "") -> Catalog {
	name := cat.name != "" ? strings.clone(cat.name) : strings.clone(fallback_name)
	return Catalog{
		name    = name,
		purpose = strings.clone(cat.purpose),
		tags    = _clone_strings(cat.tags),
		related = _clone_strings(cat.related),
		created = strings.clone(cat.created),
	}
}

_registry_entry_from_blob :: proc(name: string, data_path: string, blob: Blob) -> Registry_Entry {
	return Registry_Entry{
		name          = strings.clone(name),
		data_path     = strings.clone(data_path),
		thought_count = len(blob.processed) + len(blob.unprocessed),
		catalog       = _clone_catalog(blob.catalog, name),
		gate_desc     = _clone_strings(blob.description[:]),
		gate_positive = _clone_strings(blob.positive[:]),
		gate_negative = _clone_strings(blob.negative[:]),
		gate_related  = _clone_strings(blob.related[:]),
	}
}

_clone_strings :: proc(src: []string, allocator := context.allocator) -> []string {
	if len(src) == 0 do return nil
	out := make([]string, len(src), allocator)
	for s, i in src do out[i] = strings.clone(s, allocator)
	return out
}

// _valid_shard_name rejects path traversal and other dangerous characters.
// Only allows alphanumeric, hyphens, and underscores.
@(private)
_valid_shard_name :: proc(name: string) -> bool {
	if len(name) == 0 || len(name) > 128 do return false
	for ch in name {
		switch ch {
		case 'a'..='z', 'A'..='Z', '0'..='9', '-', '_':
			// ok
		case:
			return false
		}
	}
	return true
}

@(private)
_registry_matches :: proc(entry: Registry_Entry, q_tokens: []string) -> bool {
	if len(q_tokens) == 0 do return true
	// Match against catalog name
	name_tokens := _tokenize(entry.catalog.name != "" ? entry.catalog.name : entry.name, context.temp_allocator)
	defer delete(name_tokens, context.temp_allocator)
	for qt in q_tokens {
		for nt in name_tokens {
			if qt == nt do return true
		}
	}
	// Match against catalog purpose
	if entry.catalog.purpose != "" {
		purpose_tokens := _tokenize(entry.catalog.purpose, context.temp_allocator)
		defer delete(purpose_tokens, context.temp_allocator)
		for qt in q_tokens {
			for pt in purpose_tokens {
				if qt == pt do return true
			}
		}
	}
	// Match against catalog tags
	for tag in entry.catalog.tags {
		tag_tokens := _tokenize(tag, context.temp_allocator)
		defer delete(tag_tokens, context.temp_allocator)
		for qt in q_tokens {
			for tt in tag_tokens {
				if qt == tt do return true
			}
		}
	}
	return false
}

// =============================================================================
// Gate sync helpers
// =============================================================================

@(private)
_op_modifies_gates :: proc(op: string) -> bool {
	switch op {
	case "set_description", "set_positive", "set_negative", "set_related",
	     "set_catalog", "link", "unlink":
		return true
	}
	return false
}

@(private)
_sync_slot_gates :: proc(entry: ^Registry_Entry, slot: ^Shard_Slot) {
	fresh := _registry_entry_from_blob(entry.name, entry.data_path, slot.blob)
	entry.thought_count = fresh.thought_count
	entry.catalog       = fresh.catalog
	entry.gate_desc     = fresh.gate_desc
	entry.gate_positive = fresh.gate_positive
	entry.gate_negative = fresh.gate_negative
	entry.gate_related  = fresh.gate_related
}
