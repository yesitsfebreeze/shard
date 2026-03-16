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
	case "registry":       return _op_registry(node, req, allocator), true
	case "discover":       return _op_discover(node, allocator), true
	case "remember":       return _op_remember(node, req, allocator), true
	case "traverse":       return _op_traverse(node, req, allocator), true
	case "alert_response": return _op_alert_response(node, req, allocator), true
	case "alerts":         return _op_alerts(node, allocator), true
	case "notify":         return _op_notify(node, req, allocator), true
	case "events":         return _op_events(node, req, allocator), true
	case "access":         return _op_access(node, req, allocator), true
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

	// Create the .shard file (tprintf is fine — _registry_entry_from_blob clones it)
	data_path := fmt.tprintf(".shards/%s.shard", req.name)
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

	// Track lock state before dispatch to detect releases
	was_locked := _slot_is_locked(slot)

	// Dispatch against the slot's blob
	result := _slot_dispatch(slot, req, allocator)

	// If gates changed, sync to registry and re-index
	if _op_modifies_gates(req.op) {
		_sync_slot_gates(entry, slot)
		_daemon_persist(node)
		index_update_shard(node, entry.name)
		_emit_event(node, entry.name, "gates_updated", req.agent)
	}

	// Auto-notify on content changes
	if _op_emits_event(req.op) {
		event_type := req.op == "compact" ? "compacted" : "knowledge_changed"
		_emit_event(node, entry.name, event_type, req.agent)
	}

	// Emit lock_released event when a transaction completes
	if was_locked && !_slot_is_locked(slot) {
		_emit_event(node, entry.name, "lock_released", req.agent)
	}

	return result
}

// _slot_dispatch runs a shard op against a loaded slot.
@(private)
_slot_dispatch :: proc(slot: ^Shard_Slot, req: Request, allocator := context.allocator) -> string {
	// Transaction lock enforcement for mutating ops
	if _op_is_mutating(req.op) && _slot_is_locked(slot) {
		if req.lock_id == "" || req.lock_id != slot.lock_id {
			// Queue write ops instead of rejecting — they'll drain after lock release
			if req.op == "write" {
				if slot.write_queue == nil {
					slot.write_queue = make([dynamic]Request)
				}
				append(&slot.write_queue, _clone_request(req))
				return _marshal(Response{
					status      = "queued",
					description = fmt.tprintf("write queued — shard locked by %s", slot.lock_agent),
				}, allocator)
			}
			// Non-write mutating ops still get rejected (update, delete, etc.)
			remaining := time.duration_seconds(time.diff(time.now(), slot.lock_expiry))
			return _err_response(
				fmt.tprintf("shard locked by %s (expires in %.0fs)", slot.lock_agent, remaining),
				allocator,
			)
		}
	}

	// Build a temporary node so we can reuse existing op handlers
	temp_node := Node{
		name           = slot.name,
		blob           = slot.blob,
		index          = slot.index,
		pending_alerts = slot.pending_alerts,
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
	case "revisions":       result = _op_revisions(&temp_node, req, allocator)
	case "compact":         result = _op_compact(&temp_node, req, allocator)
	case "dump":            result = _op_dump(&temp_node, allocator)
	case "gates":           result = _op_gates(&temp_node, allocator)
	case "manifest":        result = _op_manifest(&temp_node, req, allocator)
	case "status":          result = _op_status(&temp_node, allocator)
	// Transaction ops
	case "transaction":     result = _op_transaction(slot, req, allocator)
	case "commit":          result = _op_commit(slot, &temp_node, req, allocator)
	case "rollback":        result = _op_rollback(slot, req, allocator)
	case:
		result = _err_response(fmt.tprintf("unknown op: %s", req.op), allocator)
	}

	// Sync changes back to the slot
	slot.blob           = temp_node.blob
	slot.index          = temp_node.index
	slot.pending_alerts = temp_node.pending_alerts

	return result
}

// =============================================================================
// Transaction ops — pessimistic locking with TTL auto-release
// =============================================================================

DEFAULT_TRANSACTION_TTL :: 30 // seconds

@(private)
_op_transaction :: proc(slot: ^Shard_Slot, req: Request, allocator := context.allocator) -> string {
	// Check if already locked
	if _slot_is_locked(slot) {
		remaining := time.duration_seconds(time.diff(time.now(), slot.lock_expiry))
		return _err_response(
			fmt.tprintf("shard already locked by %s (expires in %.0fs)", slot.lock_agent, remaining),
			allocator,
		)
	}

	ttl := req.ttl > 0 ? req.ttl : DEFAULT_TRANSACTION_TTL
	lock_id := new_random_hex()

	slot.lock_id     = strings.clone(lock_id)
	slot.lock_agent  = strings.clone(req.agent != "" ? req.agent : "unknown")
	slot.lock_expiry = time.time_add(time.now(), time.Duration(ttl) * time.Second)

	// Return current thought count and lock_id
	total := len(slot.blob.processed) + len(slot.blob.unprocessed)
	return _marshal(Response{
		status   = "ok",
		lock_id  = lock_id,
		thoughts = total,
	}, allocator)
}

@(private)
_op_commit :: proc(slot: ^Shard_Slot, temp_node: ^Node, req: Request, allocator := context.allocator) -> string {
	if !_slot_is_locked(slot) {
		return _err_response("shard is not locked", allocator)
	}
	if req.lock_id != slot.lock_id {
		return _err_response("lock_id mismatch", allocator)
	}

	// Execute the write
	result: string
	if req.description != "" {
		result = _op_write(temp_node, req, allocator)
	} else {
		result = _marshal(Response{status = "ok"}, allocator)
	}

	// Clear lock and drain queued writes
	_slot_clear_lock(slot)
	_slot_drain_write_queue(slot, temp_node)
	return result
}

@(private)
_op_rollback :: proc(slot: ^Shard_Slot, req: Request, allocator := context.allocator) -> string {
	if !_slot_is_locked(slot) {
		return _err_response("shard is not locked", allocator)
	}
	if req.lock_id != slot.lock_id {
		return _err_response("lock_id mismatch", allocator)
	}
	// Build temp node for draining
	temp_node := Node{
		name           = slot.name,
		blob           = slot.blob,
		index          = slot.index,
		pending_alerts = slot.pending_alerts,
	}
	_slot_clear_lock(slot)
	_slot_drain_write_queue(slot, &temp_node)
	// Sync back
	slot.blob           = temp_node.blob
	slot.index          = temp_node.index
	slot.pending_alerts = temp_node.pending_alerts
	return _marshal(Response{status = "ok"}, allocator)
}

// _slot_drain_write_queue replays queued writes after a lock release.
// Writes are applied in arrival order. Failures are logged but don't block other writes.
@(private)
_slot_drain_write_queue :: proc(slot: ^Shard_Slot, temp_node: ^Node) {
	if slot.write_queue == nil || len(slot.write_queue) == 0 do return

	drained := 0
	for &queued_req in slot.write_queue {
		_ = _op_write(temp_node, queued_req, context.temp_allocator)
		drained += 1
	}

	// Clear the queue
	clear(&slot.write_queue)

	if drained > 0 {
		fmt.eprintfln("daemon/%s: drained %d queued writes after lock release", slot.name, drained)
	}
}

@(private)
_slot_is_locked :: proc(slot: ^Shard_Slot) -> bool {
	zero_time: time.Time
	if slot.lock_expiry == zero_time do return false
	if time.diff(time.now(), slot.lock_expiry) <= 0 {
		// Lock has expired — auto-release
		_slot_clear_lock(slot)
		return false
	}
	return true
}

@(private)
_slot_clear_lock :: proc(slot: ^Shard_Slot) {
	delete(slot.lock_id)
	delete(slot.lock_agent)
	slot.lock_id     = ""
	slot.lock_agent  = ""
	slot.lock_expiry = {}
}

@(private)
_op_is_mutating :: proc(op: string) -> bool {
	switch op {
	case "write", "update", "delete", "compact", "set_description", "set_positive",
	     "set_negative", "set_related", "set_catalog", "link", "unlink":
		return true
	}
	return false
}

// =============================================================================
// Content alert ops — daemon-level alert management
// =============================================================================

// _op_alert_response dismisses a content alert after user review.
// Writes are never blocked — alerts are informational. Both "acknowledge"
// and "dismiss" simply clear the alert and record an audit entry.
@(private)
_op_alert_response :: proc(node: ^Node, req: Request, allocator := context.allocator) -> string {
	if req.alert_id == "" do return _err_response("alert_id required", allocator)
	if req.action != "acknowledge" && req.action != "dismiss" {
		return _err_response("action must be 'acknowledge' or 'dismiss'", allocator)
	}

	// Search all slots for this alert
	for name, slot in node.slots {
		if slot.pending_alerts == nil do continue
		alert, found := slot.pending_alerts[req.alert_id]
		if !found do continue

		// Record audit entry
		categories := make([dynamic]string, context.temp_allocator)
		for f in alert.findings {
			append(&categories, f.category)
		}
		cat_str := strings.join(categories[:], ",", context.temp_allocator)

		append(&node.audit_trail, Audit_Entry{
			timestamp = _format_time(time.now()),
			alert_id  = strings.clone(req.alert_id),
			shard     = strings.clone(name),
			agent     = strings.clone(alert.agent),
			action    = strings.clone(req.action),
			category  = strings.clone(cat_str),
		})

		delete_key(&slot.pending_alerts, req.alert_id)
		_daemon_persist(node)
		return _marshal(Response{status = "ok"}, allocator)
	}

	return _err_response(fmt.tprintf("alert '%s' not found", req.alert_id), allocator)
}

@(private)
_op_alerts :: proc(node: ^Node, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "---\nstatus: ok\n")
	count := 0
	for _, slot in node.slots {
		if slot.pending_alerts == nil do continue
		for _, alert in slot.pending_alerts {
			count += 1
		}
	}
	fmt.sbprintf(&b, "count: %d\n", count)
	if count > 0 {
		strings.write_string(&b, "alerts:\n")
		for _, slot in node.slots {
			if slot.pending_alerts == nil do continue
			for _, alert in slot.pending_alerts {
				fmt.sbprintf(&b, "  - alert_id: %s\n    shard: %s\n    agent: %s\n    created_at: %s\n",
					alert.alert_id, alert.shard_name, alert.agent, alert.created_at)
				if len(alert.findings) > 0 {
					strings.write_string(&b, "    findings:\n")
					for f in alert.findings {
						fmt.sbprintf(&b, "      - category: %s\n        snippet: %s\n", f.category, f.snippet)
					}
				}
			}
		}
	}
	strings.write_string(&b, "---\n")
	return strings.to_string(b)
}

// =============================================================================
// Event hub — shards notify each other of changes through the daemon
// =============================================================================

// _op_notify receives an event from a shard and routes it to all related shards.
// Uses origin_chain to prevent circular propagation.
@(private)
_op_notify :: proc(node: ^Node, req: Request, allocator := context.allocator) -> string {
	if req.source == ""     do return _err_response("source required", allocator)
	if req.event_type == "" do return _err_response("event_type required", allocator)

	// Validate event type
	switch req.event_type {
	case "knowledge_changed", "knowledge_stale", "gates_updated", "compacted", "lock_released":
		// ok
	case:
		return _err_response(fmt.tprintf("unknown event_type: %s", req.event_type), allocator)
	}

	// Build origin chain — append source to prevent loops
	chain := make([dynamic]string, context.temp_allocator)
	if req.origin_chain != nil {
		for s in req.origin_chain do append(&chain, s)
	}
	append(&chain, req.source)

	// Find the source shard's related list to determine targets
	targets: []string
	for entry in node.registry {
		if entry.name == req.source {
			targets = len(entry.gate_related) > 0 ? entry.gate_related : entry.catalog.related
			break
		}
	}
	if targets == nil || len(targets) == 0 {
		return _marshal(Response{status = "ok"}, allocator)
	}

	// Route event to each target (skip if already in origin chain)
	routed := 0
	now := strings.clone(_format_time(time.now()))
	for target in targets {
		// Check origin chain to prevent loops
		in_chain := false
		for origin in chain {
			if origin == target { in_chain = true; break }
		}
		if in_chain do continue

		event := Shard_Event{
			source       = strings.clone(req.source),
			event_type   = strings.clone(req.event_type),
			agent        = strings.clone(req.agent),
			timestamp    = strings.clone(now),
			origin_chain = _clone_strings(chain[:]),
		}

		if target not_in node.event_queue {
			node.event_queue[strings.clone(target)] = make([dynamic]Shard_Event)
		}
		append(&node.event_queue[target], event)
		routed += 1
	}

	if routed > 0 {
		_daemon_persist_events(node)
	}

	return _marshal(Response{status = "ok", moved = routed}, allocator)
}

// _op_events returns and clears pending events for a shard.
@(private)
_op_events :: proc(node: ^Node, req: Request, allocator := context.allocator) -> string {
	target := req.name != "" ? req.name : req.source
	if target == "" do return _err_response("name required (which shard to get events for)", allocator)

	events, found := node.event_queue[target]
	if !found || len(events) == 0 {
		return _marshal(Response{status = "ok", events = nil}, allocator)
	}

	// Clone events for response
	result := make([]Shard_Event, len(events), allocator)
	for ev, i in events {
		result[i] = Shard_Event{
			source       = strings.clone(ev.source, allocator),
			event_type   = strings.clone(ev.event_type, allocator),
			agent        = strings.clone(ev.agent, allocator),
			timestamp    = strings.clone(ev.timestamp, allocator),
			origin_chain = _clone_strings(ev.origin_chain, allocator),
		}
	}

	// Clear the queue for this target
	for &ev in events {
		delete(ev.source)
		delete(ev.event_type)
		delete(ev.agent)
		delete(ev.timestamp)
		for s in ev.origin_chain do delete(s)
		delete(ev.origin_chain)
	}
	clear(&events)
	node.event_queue[target] = events

	_daemon_persist_events(node)
	return _marshal(Response{status = "ok", events = result}, allocator)
}

// _emit_event is called internally after write/compact/gate changes to auto-notify.
// Best-effort: does not fail the parent operation.
_emit_event :: proc(node: ^Node, source: string, event_type: string, agent: string) {
	if !node.is_daemon do return

	// Find the source shard's related list (from gates, not catalog)
	targets: []string
	for entry in node.registry {
		if entry.name == source {
			// Prefer gate_related (set via set_related op), fall back to catalog.related
			targets = len(entry.gate_related) > 0 ? entry.gate_related : entry.catalog.related
			break
		}
	}
	if targets == nil || len(targets) == 0 do return

	chain := make([]string, 1, context.temp_allocator)
	chain[0] = source
	now := strings.clone(_format_time(time.now()))

	for target in targets {
		if target == source do continue

		event := Shard_Event{
			source       = strings.clone(source),
			event_type   = strings.clone(event_type),
			agent        = strings.clone(agent),
			timestamp    = strings.clone(now),
			origin_chain = _clone_strings(chain),
		}

		if target not_in node.event_queue {
			node.event_queue[strings.clone(target)] = make([dynamic]Shard_Event)
		}
		append(&node.event_queue[target], event)
	}

	_daemon_persist_events(node)
}

// =============================================================================
// Event persistence — .shards/.events file
// =============================================================================
//
// Events are written to .shards/.events as JSON on every queue mutation.
// This ensures events survive daemon crashes. The file is loaded on startup
// and written atomically (write tmp + rename) on every change.

EVENTS_PATH :: ".shards/.events"

// Flat JSON structure for serialization (map[string][dynamic] doesn't marshal cleanly)
Events_File_Entry :: struct {
	target: string         `json:"target"`,
	events: []Shard_Event  `json:"events"`,
}

@(private)
_daemon_persist_events :: proc(node: ^Node) {
	entries := make([dynamic]Events_File_Entry, context.temp_allocator)

	for target, evts in node.event_queue {
		if len(evts) == 0 do continue
		append(&entries, Events_File_Entry{
			target = target,
			events = evts[:],
		})
	}

	data, err := json.marshal(entries[:], allocator = context.temp_allocator)
	if err != nil do return

	// Atomic write: tmp file then rename
	tmp_path := EVENTS_PATH + ".tmp"
	if !os.write_entire_file(tmp_path, data) {
		return
	}
	os.remove(EVENTS_PATH)
	os.rename(tmp_path, EVENTS_PATH)
}

// daemon_load_events loads the event queue from .shards/.events on startup.
daemon_load_events :: proc(node: ^Node) {
	data, ok := os.read_entire_file(EVENTS_PATH, context.temp_allocator)
	if !ok do return

	entries: [dynamic]Events_File_Entry
	if uerr := json.unmarshal(data, &entries); uerr != nil {
		fmt.eprintfln("daemon: could not parse %s: %v", EVENTS_PATH, uerr)
		return
	}

	total := 0
	for entry in entries {
		if len(entry.events) == 0 do continue
		queue := make([dynamic]Shard_Event)
		for ev in entry.events {
			append(&queue, Shard_Event{
				source       = strings.clone(ev.source),
				event_type   = strings.clone(ev.event_type),
				agent        = strings.clone(ev.agent),
				timestamp    = strings.clone(ev.timestamp),
				origin_chain = _clone_strings(ev.origin_chain),
			})
			total += 1
		}
		node.event_queue[strings.clone(entry.target)] = queue
	}

	if total > 0 {
		fmt.eprintfln("daemon: loaded %d pending events from %s", total, EVENTS_PATH)
	}
}

// =============================================================================
// access — single-request shard discovery + content retrieval
// =============================================================================
//
// An agent describes what it needs (query + optional positive/negative gates).
// The daemon finds the best matching shard, loads it, searches for relevant
// thoughts, and returns everything in one response.
//
// Request:
//   op: access
//   query: <description of what the agent needs>
//   items: [positive gate terms]       (optional — boosts matching)
//   key: <hex>                          (optional — auto-resolved from keychain)
//   thought_count: <int>                (optional — max thoughts, default 5)
//
// Response:
//   status: ok
//   name: <matched shard name>
//   catalog: <shard catalog>
//   results: <matched thoughts with content>
//   description: <hint if alternatives exist>
//

ACCESS_MIN_SCORE :: f32(0.1) // minimum gate score to consider a match

@(private)
_op_access :: proc(node: ^Node, req: Request, allocator := context.allocator) -> string {
	if req.query == "" do return _err_response("query required", allocator)

	// Score all shards — reuse traverse's scoring logic
	max_results := 5

	// Try vector search first
	Candidate :: struct {
		name:  string,
		score: f32,
	}
	candidates := make([dynamic]Candidate, context.temp_allocator)

	if len(node.vec_index.entries) > 0 {
		results := index_query(node, req.query, max_results * 2, context.temp_allocator)
		if results != nil {
			q_tokens := _tokenize(req.query, context.temp_allocator)
			for r in results {
				// Check negative gate rejection
				rejected := false
				for entry in node.registry {
					if entry.name == r.name {
						if entry.gate_negative != nil {
							rejected = _negative_gate_rejects(entry.gate_negative, q_tokens)
						}
						break
					}
				}
				if rejected do continue
				if r.score >= ACCESS_MIN_SCORE {
					append(&candidates, Candidate{name = r.name, score = r.score})
				}
			}
		}
	}

	// Keyword fallback if vector search found nothing
	if len(candidates) == 0 {
		q_tokens := _tokenize(req.query, context.temp_allocator)
		if len(q_tokens) == 0 do return _err_response("query produced no tokens", allocator)

		// Boost scoring with positive items if provided
		all_tokens := make([dynamic]string, context.temp_allocator)
		for t in q_tokens do append(&all_tokens, t)
		if req.items != nil {
			for item in req.items {
				item_tokens := _tokenize(item, context.temp_allocator)
				for t in item_tokens do append(&all_tokens, t)
			}
		}

		for entry in node.registry {
			gs := _score_gates(entry, all_tokens[:])
			if gs.score >= ACCESS_MIN_SCORE {
				append(&candidates, Candidate{name = gs.name, score = gs.score})
			}
		}
	}

	if len(candidates) == 0 {
		return _marshal(Response{
			status      = "no_match",
			description = "no shard matched the query — consider creating one with shard_remember",
		}, allocator)
	}

	// Sort by score descending
	for i := 1; i < len(candidates); i += 1 {
		key := candidates[i]
		j := i - 1
		for j >= 0 && candidates[j].score < key.score {
			candidates[j + 1] = candidates[j]
			j -= 1
		}
		candidates[j + 1] = key
	}

	best := candidates[0]

	// Find the registry entry for the best match
	entry_idx := -1
	for e, i in node.registry {
		if e.name == best.name {
			entry_idx = i
			break
		}
	}
	if entry_idx < 0 {
		return _err_response("matched shard not in registry", allocator)
	}
	entry := &node.registry[entry_idx]

	// Resolve key
	key_hex := req.key
	if key_hex == "" {
		key_hex = _access_resolve_key(best.name)
	}

	// Load the shard slot
	slot := _slot_get_or_create(node, entry)
	if !slot.loaded {
		if !_slot_load(slot, key_hex) {
			return _err_response(fmt.tprintf("could not load shard '%s'", best.name), allocator)
		}
	}
	if key_hex != "" && !slot.key_set {
		_slot_set_key(slot, key_hex)
	}
	slot.last_access = time.now()

	// Search within the shard for matching thoughts
	limit := req.thought_count > 0 ? req.thought_count : config_get().default_query_limit
	wire := make([dynamic]Wire_Result, allocator)

	if slot.key_set && len(slot.index) > 0 {
		hits := search_query(slot.index[:], req.query, context.temp_allocator)
		count := 0
		for h in hits {
			if count >= limit do break
			thought, found := blob_get(&slot.blob, h.id)
			if !found do continue
			pt, err := thought_decrypt(thought, slot.master, allocator)
			if err != .None do continue
			append(&wire, Wire_Result{
				id          = id_to_hex(h.id, allocator),
				score       = h.score,
				description = pt.description,
				content     = pt.content,
			})
			count += 1
		}
	}

	// Build hint about alternatives
	hint := ""
	if len(candidates) > 1 {
		alt_names := make([dynamic]string, context.temp_allocator)
		cap := min(len(candidates), 4)
		for i in 1 ..< cap {
			append(&alt_names, candidates[i].name)
		}
		hint = fmt.aprintf("also matched: %s", strings.join(alt_names[:], ", ", context.temp_allocator))
	}

	return _marshal(Response{
		status      = "ok",
		node_name   = best.name,
		catalog     = entry.catalog,
		results     = wire[:],
		description = hint,
	}, allocator)
}

// _access_resolve_key tries to resolve a key for the given shard from the keychain.
@(private)
_access_resolve_key :: proc(shard_name: string) -> string {
	kc, ok := keychain_load(context.temp_allocator)
	if !ok do return ""
	key, found := keychain_lookup(kc, shard_name)
	if found do return key
	return ""
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
	case "write", "read", "update", "delete", "search", "query", "compact", "dump", "revisions":
		return true
	}
	return false
}

// daemon_evict_idle flushes and unloads shard blobs that haven't been
// accessed within max_idle. Called periodically from the event loop.
daemon_evict_idle :: proc(node: ^Node, max_idle: time.Duration) {
	now := time.now()

	for name, slot in node.slots {
		// Check for expired transaction locks (single call — _slot_is_locked auto-releases)
		was_locked := slot.lock_expiry != (time.Time{})
		if was_locked && !_slot_is_locked(slot) {
			fmt.eprintfln("daemon: auto-released expired lock on shard '%s'", name)
			_emit_event(node, name, "lock_released", "daemon")
			// Drain any queued writes after TTL expiry
			if slot.loaded && len(slot.write_queue) > 0 {
				temp_node := Node{
					name           = slot.name,
					blob           = slot.blob,
					index          = slot.index,
					pending_alerts = slot.pending_alerts,
				}
				_slot_drain_write_queue(slot, &temp_node)
				slot.blob           = temp_node.blob
				slot.index          = temp_node.index
				slot.pending_alerts = temp_node.pending_alerts
			}
		}

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
		blob, ok := blob_load(data_path, zero_key)
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

	// Free old strings before replacing
	_free_registry_strings(entry)

	entry.thought_count = fresh.thought_count
	entry.catalog       = fresh.catalog
	entry.gate_desc     = fresh.gate_desc
	entry.gate_positive = fresh.gate_positive
	entry.gate_negative = fresh.gate_negative
	entry.gate_related  = fresh.gate_related
}

@(private)
_free_registry_strings :: proc(entry: ^Registry_Entry) {
	delete(entry.catalog.name)
	delete(entry.catalog.purpose)
	for t in entry.catalog.tags do delete(t)
	delete(entry.catalog.tags)
	for r in entry.catalog.related do delete(r)
	delete(entry.catalog.related)
	delete(entry.catalog.created)
	for s in entry.gate_desc do delete(s)
	delete(entry.gate_desc)
	for s in entry.gate_positive do delete(s)
	delete(entry.gate_positive)
	for s in entry.gate_negative do delete(s)
	delete(entry.gate_negative)
	for s in entry.gate_related do delete(s)
	delete(entry.gate_related)
}

// =============================================================================
// Persistence — registry stored as JSON in the daemon's blob manifest
// =============================================================================

_daemon_persist :: proc(node: ^Node) {
	data, err := json.marshal(node.registry[:])
	if err != nil do return
	defer delete(data)
	delete(node.blob.manifest)
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
_op_emits_event :: proc(op: string) -> bool {
	switch op {
	case "write", "update", "delete", "compact":
		return true
	}
	return false
}

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

	// Free old strings before replacing
	_free_registry_strings(entry)

	entry.thought_count = fresh.thought_count
	entry.catalog       = fresh.catalog
	entry.gate_desc     = fresh.gate_desc
	entry.gate_positive = fresh.gate_positive
	entry.gate_negative = fresh.gate_negative
	entry.gate_related  = fresh.gate_related
}
