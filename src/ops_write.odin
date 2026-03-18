// ops_write.odin — write operations: shard creation, routing, slot dispatch, mutation classification
package shard

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

_op_registry :: proc(node: ^Node, req: Request, allocator := context.allocator) -> string {
	cfg := config_get()
	for &entry in node.registry {
		unprocessed := 0
		if slot, ok := node.slots[entry.name]; ok && slot.loaded {
			unprocessed = len(slot.blob.unprocessed)
		}
		entry.needs_attention = _shard_needs_attention(node, entry.name, unprocessed)
		entry.needs_compaction = cfg.compact_threshold > 0 && unprocessed >= cfg.compact_threshold
	}

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

_op_discover :: proc(node: ^Node, allocator := context.allocator) -> string {
	daemon_scan_shards(node)
	index_build(node)
	return _marshal(Response{status = "ok", registry = node.registry[:]}, allocator)
}

_op_remember :: proc(node: ^Node, req: Request, allocator := context.allocator) -> string {
	if req.name == "" do return _err_response("name required", allocator)
	if req.name == DAEMON_NAME do return _err_response("cannot use reserved name 'daemon'", allocator)
	if !_valid_shard_name(req.name) do return _err_response("invalid shard name (must be alphanumeric, hyphens, underscores only)", allocator)

	for entry in node.registry {
		if entry.name == req.name {
			return _err_response(fmt.tprintf("shard '%s' already exists", req.name), allocator)
		}
	}

	max_shards := config_get().max_shards
	if len(node.registry) >= max_shards {
		return _err_response(fmt.tprintf("shard limit reached (%d)", max_shards), allocator)
	}

	data_path := fmt.tprintf(".shards/%s.shard", req.name)
	os.make_directory(".shards")

	zero_key: Master_Key
	blob, ok := blob_load(data_path, zero_key)
	if !ok {
		return _err_response(fmt.tprintf("could not create shard file: %s", data_path), allocator)
	}

	blob.catalog = Catalog {
		name    = strings.clone(req.name),
		purpose = strings.clone(req.purpose),
		tags    = _clone_strings(req.tags),
		related = _clone_strings(req.related),
		created = _format_time(time.now()),
	}

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

	infof("daemon: created shard '%s' via remember", req.name)
	return _marshal(Response{status = "ok", catalog = blob.catalog}, allocator)
}

_op_route_to_slot :: proc(node: ^Node, req: Request, allocator := context.allocator) -> string {
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

	slot := _slot_get_or_create(node, entry)

	if !slot.loaded {
		if !_slot_load(slot, req.key) {
			return _err_response(fmt.tprintf("could not load shard '%s'", req.name), allocator)
		}
	}

	if req.key != "" && !slot.key_set {
		_slot_set_key(slot, req.key)
	}

	if _op_requires_key(req.op) {
		if !_slot_verify_key(slot, req.key) {
			return _err_response("key required (provide key: <64-hex> in request)", allocator)
		}
	}

	slot.last_access = time.now()

	was_locked := _slot_is_locked(slot)

	result := _slot_dispatch(slot, req, allocator)

	_record_consumption(node, req.agent, req.name, req.op)

	if _op_modifies_gates(req.op) {
		_sync_slot_gates(entry, slot)
		_daemon_persist(node)
		index_update_shard(node, entry.name)
		_emit_event(node, entry.name, "gates_updated", req.agent)
	}

	if _op_emits_event(req.op) {
		event_type := req.op == "compact" ? "compacted" : "knowledge_changed"
		_emit_event(node, entry.name, event_type, req.agent)
	}

	if was_locked && !_slot_is_locked(slot) {
		_emit_event(node, entry.name, "lock_released", req.agent)
	}

	return result
}

_slot_dispatch :: proc(slot: ^Shard_Slot, req: Request, allocator := context.allocator) -> string {
	if _op_is_mutating(req.op) && _slot_is_locked(slot) {
		if req.lock_id == "" || req.lock_id != slot.lock_id {
			if req.op == "write" {
				if slot.write_queue == nil {
					slot.write_queue = make([dynamic]Request)
				}
				append(&slot.write_queue, _clone_request(req))
				return _marshal(
					Response {
						status = "queued",
						description = fmt.tprintf(
							"write queued — shard locked by %s",
							slot.lock_agent,
						),
					},
					allocator,
				)
			}
			remaining := time.duration_seconds(time.diff(time.now(), slot.lock_expiry))
			return _err_response(
				fmt.tprintf("shard locked by %s (expires in %.0fs)", slot.lock_agent, remaining),
				allocator,
			)
		}
	}

	temp_node := Node {
		name           = slot.name,
		blob           = slot.blob,
		index          = slot.index,
		pending_alerts = slot.pending_alerts,
	}

	result: string
	switch req.op {
	case "description":
		result = _op_gate_read(slot.blob.description[:], allocator)
	case "positive":
		result = _op_gate_read(slot.blob.positive[:], allocator)
	case "negative":
		result = _op_gate_read(slot.blob.negative[:], allocator)
	case "related":
		result = _op_gate_read(slot.blob.related[:], allocator)
	case "set_description":
		result = _op_gate_write(&temp_node, &temp_node.blob.description, req.items, allocator)
	case "set_positive":
		result = _op_gate_write(&temp_node, &temp_node.blob.positive, req.items, allocator)
	case "set_negative":
		result = _op_gate_write(&temp_node, &temp_node.blob.negative, req.items, allocator)
	case "set_related":
		result = _op_gate_write(&temp_node, &temp_node.blob.related, req.items, allocator)
	case "link":
		result = _op_link(&temp_node, req, allocator)
	case "unlink":
		result = _op_unlink(&temp_node, req, allocator)
	case "catalog":
		result = _op_catalog(&temp_node, allocator)
	case "set_catalog":
		result = _op_set_catalog(&temp_node, req, allocator)
	case "write":
		result = _op_write(&temp_node, req, allocator)
	case "read":
		result = _op_read(&temp_node, req, allocator)
	case "update":
		result = _op_update(&temp_node, req, allocator)
	case "list":
		result = _op_list(&temp_node, allocator)
	case "delete":
		result = _op_delete(&temp_node, req, allocator)
	case "query":
		result = _op_query(&temp_node, req, allocator)
	case "revisions":
		result = _op_revisions(&temp_node, req, allocator)
	case "compact":
		result = _op_compact(&temp_node, req, allocator)
	case "compact_suggest":
		result = _op_compact_suggest(&temp_node, req, allocator)
	case "stale":
		result = _op_stale(&temp_node, req, allocator)
	case "feedback":
		result = _op_feedback(&temp_node, req, allocator)
	case "gates":
		result = _op_gates(&temp_node, allocator)
	case "manifest":
		result = _op_manifest(&temp_node, req, allocator)
	case "status":
		result = _op_status(&temp_node, allocator)
	case "transaction":
		result = _op_transaction(slot, req, allocator)
	case "commit":
		result = _op_commit(slot, &temp_node, req, allocator)
	case "rollback":
		result = _op_rollback(slot, req, allocator)
	case:
		result = _err_response(fmt.tprintf("unknown op: %s", req.op), allocator)
	}

	slot.blob = temp_node.blob
	slot.index = temp_node.index
	slot.pending_alerts = temp_node.pending_alerts

	return result
}

_slot_drain_write_queue :: proc(slot: ^Shard_Slot, temp_node: ^Node) {
	if slot.write_queue == nil || len(slot.write_queue) == 0 do return

	drained := 0
	for &queued_req in slot.write_queue {
		_ = _op_write(temp_node, queued_req, context.temp_allocator)
		drained += 1
	}

	clear(&slot.write_queue)

	if drained > 0 {
		infof("drained %d queued writes after lock release", drained)
	}
}

_slot_is_locked :: proc(slot: ^Shard_Slot) -> bool {
	zero_time: time.Time
	if slot.lock_expiry == zero_time do return false
	if time.diff(time.now(), slot.lock_expiry) <= 0 {
		_slot_clear_lock(slot)
		return false
	}
	return true
}

_slot_clear_lock :: proc(slot: ^Shard_Slot) {
	delete(slot.lock_id)
	delete(slot.lock_agent)
	slot.lock_id = ""
	slot.lock_agent = ""
	slot.lock_expiry = {}
}

_op_is_mutating :: proc(op: string) -> bool {
	switch op {
	case "write",
	     "update",
	     "delete",
	     "compact",
	     "feedback",
	     "set_description",
	     "set_positive",
	     "set_negative",
	     "set_related",
	     "set_catalog",
	     "link",
	     "unlink":
		return true
	}
	return false
}

_op_emits_event :: proc(op: string) -> bool {
	switch op {
	case "write", "update", "delete", "compact", "feedback":
		return true
	}
	return false
}

_op_modifies_gates :: proc(op: string) -> bool {
	switch op {
	case "set_description",
	     "set_positive",
	     "set_negative",
	     "set_related",
	     "set_catalog",
	     "link",
	     "unlink":
		return true
	}
	return false
}

_sync_slot_gates :: proc(entry: ^Registry_Entry, slot: ^Shard_Slot) {
	fresh := _registry_entry_from_blob(entry.name, entry.data_path, slot.blob)

	_free_registry_strings(entry)

	entry.thought_count = fresh.thought_count
	entry.catalog = fresh.catalog
	entry.gate_desc = fresh.gate_desc
	entry.gate_positive = fresh.gate_positive
	entry.gate_negative = fresh.gate_negative
	entry.gate_related = fresh.gate_related
}

_valid_shard_name :: proc(name: string) -> bool {
	if len(name) == 0 || len(name) > 128 do return false
	for ch in name {
		switch ch {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '-', '_':
		case:
			return false
		}
	}
	return true
}
