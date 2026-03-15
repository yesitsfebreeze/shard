package shard

import "core:encoding/hex"
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
	return _marshal(Response{status = "ok", registry = node.registry[:]}, allocator)
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
	return _slot_dispatch(slot, req, allocator)
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
	case "set_description": result = _op_gate_write(&temp_node, &slot.blob.description, req.items, allocator)
	case "set_positive":    result = _op_gate_write(&temp_node, &slot.blob.positive,    req.items, allocator)
	case "set_negative":    result = _op_gate_write(&temp_node, &slot.blob.negative,    req.items, allocator)
	case "set_related":     result = _op_gate_write(&temp_node, &slot.blob.related,     req.items, allocator)
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
	case "compact":         result = _op_compact(&temp_node, req, allocator)
	case "dump":            result = _op_dump(&temp_node, allocator)
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

	if key_hex != "" && len(key_hex) == 64 {
		key_bytes, ok := hex.decode(transmute([]u8)key_hex, context.temp_allocator)
		if ok && len(key_bytes) == 32 {
			copy(master[:], key_bytes)
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
	if key_hex == "" || len(key_hex) != 64 do return
	key_bytes, ok := hex.decode(transmute([]u8)key_hex, context.temp_allocator)
	if !ok || len(key_bytes) != 32 do return

	copy(slot.master[:], key_bytes)
	slot.blob.master = slot.master
	slot.key_set = true
	_slot_build_index(slot)
}

@(private)
_slot_build_index :: proc(slot: ^Shard_Slot) {
	clear(&slot.index)
	for thought in slot.blob.processed {
		pt, err := thought_decrypt(thought, slot.master, context.temp_allocator)
		if err == .None {
			append(&slot.index, Search_Entry{id = thought.id, description = strings.clone(pt.description)})
			delete(pt.description, context.temp_allocator)
			delete(pt.content, context.temp_allocator)
		}
	}
	for thought in slot.blob.unprocessed {
		pt, err := thought_decrypt(thought, slot.master, context.temp_allocator)
		if err == .None {
			append(&slot.index, Search_Entry{id = thought.id, description = strings.clone(pt.description)})
			delete(pt.description, context.temp_allocator)
			delete(pt.content, context.temp_allocator)
		}
	}
}

@(private)
_slot_verify_key :: proc(slot: ^Shard_Slot, key_hex: string) -> bool {
	if !slot.key_set do return false
	if key_hex == "" || len(key_hex) != 64 do return false
	key_bytes, ok := hex.decode(transmute([]u8)key_hex, context.temp_allocator)
	if !ok || len(key_bytes) != 32 do return false
	// Constant-time comparison
	diff: u8 = 0
	for i in 0..<32 do diff |= key_bytes[i] ~ slot.master[i]
	return diff == 0
}

@(private)
_op_requires_key :: proc(op: string) -> bool {
	switch op {
	case "write", "read", "update", "delete", "search", "compact", "dump":
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
		new_entry := Registry_Entry{
			name          = strings.clone(shard_name),
			data_path     = strings.clone(data_path),
			thought_count = total,
			catalog       = Catalog{
				name    = blob.catalog.name != "" ? strings.clone(blob.catalog.name) : strings.clone(shard_name),
				purpose = strings.clone(blob.catalog.purpose),
				tags    = _clone_strings(blob.catalog.tags),
				related = _clone_strings(blob.catalog.related),
				created = strings.clone(blob.catalog.created),
			},
			gate_desc     = _clone_dynamic_strings(blob.description[:]),
			gate_positive = _clone_dynamic_strings(blob.positive[:]),
			gate_negative = _clone_dynamic_strings(blob.negative[:]),
		}
		append(&node.registry, new_entry)
		fmt.eprintfln("daemon: discovered shard '%s' (%d thoughts)", shard_name, total)
	}

	_daemon_persist(node)
}

// _refresh_registry_entry reloads gates and catalog from disk for a known entry.
@(private)
_refresh_registry_entry :: proc(entry: ^Registry_Entry, data_path: string) {
	zero_key: Master_Key
	blob, ok := blob_load(data_path, zero_key)
	if !ok do return

	entry.thought_count = len(blob.processed) + len(blob.unprocessed)
	entry.catalog = Catalog{
		name    = blob.catalog.name != "" ? strings.clone(blob.catalog.name) : entry.name,
		purpose = strings.clone(blob.catalog.purpose),
		tags    = _clone_strings(blob.catalog.tags),
		related = _clone_strings(blob.catalog.related),
		created = strings.clone(blob.catalog.created),
	}
	entry.gate_desc     = _clone_dynamic_strings(blob.description[:])
	entry.gate_positive = _clone_dynamic_strings(blob.positive[:])
	entry.gate_negative = _clone_dynamic_strings(blob.negative[:])
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
// Helpers
// =============================================================================

_format_time :: proc(t: time.Time) -> string {
	y, mon, d := time.date(t)
	h, m, s := time.clock(t)
	return fmt.tprintf("%04d-%02d-%02dT%02d:%02d:%02dZ", y, int(mon), d, h, m, s)
}

_clone_strings :: proc(src: []string, allocator := context.allocator) -> []string {
	out := make([]string, len(src), allocator)
	for s, i in src do out[i] = strings.clone(s, allocator)
	return out
}

_clone_dynamic_strings :: proc(src: []string, allocator := context.allocator) -> []string {
	if len(src) == 0 do return nil
	out := make([]string, len(src), allocator)
	for s, i in src do out[i] = strings.clone(s, allocator)
	return out
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
