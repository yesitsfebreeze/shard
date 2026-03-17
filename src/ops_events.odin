// ops_events.odin — event operations: transactions, alerts, notifications, consumption tracking
package shard

import "core:fmt"
import "core:strings"
import "core:time"

_op_transaction :: proc(
	slot: ^Shard_Slot,
	req: Request,
	allocator := context.allocator,
) -> string {
	if _slot_is_locked(slot) {
		remaining := time.duration_seconds(time.diff(time.now(), slot.lock_expiry))
		return _err_response(
			fmt.tprintf(
				"shard already locked by %s (expires in %.0fs)",
				slot.lock_agent,
				remaining,
			),
			allocator,
		)
	}

	ttl := req.ttl > 0 ? req.ttl : DEFAULT_TRANSACTION_TTL
	lock_id := new_random_hex()

	slot.lock_id = strings.clone(lock_id)
	slot.lock_agent = strings.clone(req.agent != "" ? req.agent : "unknown")
	slot.lock_expiry = time.time_add(time.now(), time.Duration(ttl) * time.Second)

	total := len(slot.blob.processed) + len(slot.blob.unprocessed)
	return _marshal(Response{status = "ok", lock_id = lock_id, thoughts = total}, allocator)
}

_op_commit :: proc(
	slot: ^Shard_Slot,
	temp_node: ^Node,
	req: Request,
	allocator := context.allocator,
) -> string {
	if !_slot_is_locked(slot) {
		return _err_response("shard is not locked", allocator)
	}
	if req.lock_id != slot.lock_id {
		return _err_response("lock_id mismatch", allocator)
	}

	result: string
	if req.description != "" {
		result = _op_write(temp_node, req, allocator)
	} else {
		result = _marshal(Response{status = "ok"}, allocator)
	}

	_slot_clear_lock(slot)
	_slot_drain_write_queue(slot, temp_node)
	return result
}

_op_rollback :: proc(slot: ^Shard_Slot, req: Request, allocator := context.allocator) -> string {
	if !_slot_is_locked(slot) {
		return _err_response("shard is not locked", allocator)
	}
	if req.lock_id != slot.lock_id {
		return _err_response("lock_id mismatch", allocator)
	}
	temp_node := Node {
		name           = slot.name,
		blob           = slot.blob,
		index          = slot.index,
		pending_alerts = slot.pending_alerts,
	}
	_slot_clear_lock(slot)
	_slot_drain_write_queue(slot, &temp_node)
	slot.blob = temp_node.blob
	slot.index = temp_node.index
	slot.pending_alerts = temp_node.pending_alerts
	return _marshal(Response{status = "ok"}, allocator)
}


_op_alert_response :: proc(node: ^Node, req: Request, allocator := context.allocator) -> string {
	if req.alert_id == "" do return _err_response("alert_id required", allocator)
	if req.action != "acknowledge" && req.action != "dismiss" {
		return _err_response("action must be 'acknowledge' or 'dismiss'", allocator)
	}

	for name, slot in node.slots {
		if slot.pending_alerts == nil do continue
		alert, found := slot.pending_alerts[req.alert_id]
		if !found do continue

		categories := make([dynamic]string, context.temp_allocator)
		for f in alert.findings {
			append(&categories, f.category)
		}
		cat_str := strings.join(categories[:], ",", context.temp_allocator)

		append(
			&node.audit_trail,
			Audit_Entry {
				timestamp = _format_time(time.now()),
				alert_id = strings.clone(req.alert_id),
				shard = strings.clone(name),
				agent = strings.clone(alert.agent),
				action = strings.clone(req.action),
				category = strings.clone(cat_str),
			},
		)

		delete_key(&slot.pending_alerts, req.alert_id)
		_daemon_persist(node)
		return _marshal(Response{status = "ok"}, allocator)
	}

	return _err_response(fmt.tprintf("alert '%s' not found", req.alert_id), allocator)
}

_op_alerts :: proc(node: ^Node, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	count := 0
	for _, slot in node.slots {
		if slot.pending_alerts == nil do continue
		for _ in slot.pending_alerts do count += 1
	}
	strings.write_string(&b, `{"status":"ok","count":`)
	fmt.sbprintf(&b, "%d", count)
	if count > 0 {
		strings.write_string(&b, `,"alerts":[`)
		first := true
		for _, slot in node.slots {
			if slot.pending_alerts == nil do continue
			for _, alert in slot.pending_alerts {
				if !first do strings.write_string(&b, ",")
				first = false
				strings.write_string(&b, `{`)
				_write_json_field(&b, "alert_id", alert.alert_id)
				strings.write_string(&b, ",")
				_write_json_field(&b, "shard", alert.shard_name)
				strings.write_string(&b, ",")
				_write_json_field(&b, "agent", alert.agent)
				strings.write_string(&b, ",")
				_write_json_field(&b, "created_at", alert.created_at)
				if len(alert.findings) > 0 {
					strings.write_string(&b, `,"findings":[`)
					for f, i in alert.findings {
						if i > 0 do strings.write_string(&b, ",")
						strings.write_string(&b, `{`)
						_write_json_field(&b, "category", f.category)
						strings.write_string(&b, ",")
						_write_json_field(&b, "snippet", f.snippet)
						strings.write_string(&b, "}")
					}
					strings.write_string(&b, "]")
				}
				strings.write_string(&b, "}")
			}
		}
		strings.write_string(&b, "]")
	}
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

_op_notify :: proc(node: ^Node, req: Request, allocator := context.allocator) -> string {
	if req.source == "" do return _err_response("source required", allocator)
	if req.event_type == "" do return _err_response("event_type required", allocator)

	switch req.event_type {
	case "knowledge_changed",
	     "knowledge_stale",
	     "gates_updated",
	     "compacted",
	     "lock_released",
	     "needs_compaction":
	case:
		return _err_response(fmt.tprintf("unknown event_type: %s", req.event_type), allocator)
	}

	chain := make([dynamic]string, context.temp_allocator)
	if req.origin_chain != nil {
		for s in req.origin_chain do append(&chain, s)
	}
	append(&chain, req.source)

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

	routed := 0
	now := strings.clone(_format_time(time.now()))
	for target in targets {
		in_chain := false
		for origin in chain {
			if origin == target {in_chain = true; break}
		}
		if in_chain do continue

		event := Shard_Event {
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

_op_events :: proc(node: ^Node, req: Request, allocator := context.allocator) -> string {
	target := req.name != "" ? req.name : req.source
	if target == "" do return _err_response("name required (which shard to get events for)", allocator)

	events, found := node.event_queue[target]
	if !found || len(events) == 0 {
		return _marshal(Response{status = "ok", events = nil}, allocator)
	}

	result := make([]Shard_Event, len(events), allocator)
	for ev, i in events {
		result[i] = Shard_Event {
			source       = strings.clone(ev.source, allocator),
			event_type   = strings.clone(ev.event_type, allocator),
			agent        = strings.clone(ev.agent, allocator),
			timestamp    = strings.clone(ev.timestamp, allocator),
			origin_chain = _clone_strings(ev.origin_chain, allocator),
		}
	}

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

_emit_event :: proc(node: ^Node, source: string, event_type: string, agent: string) {
	if !node.is_daemon do return

	targets: []string
	for entry in node.registry {
		if entry.name == source {
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

		event := Shard_Event {
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



_record_consumption :: proc(node: ^Node, agent: string, shard_name: string, op: string) {
	if !node.is_daemon do return

	record := Consumption_Record {
		agent     = strings.clone(agent != "" ? agent : "unknown"),
		shard     = strings.clone(shard_name),
		op        = strings.clone(op),
		timestamp = strings.clone(_format_time(time.now())),
	}
	append(&node.consumption_log, record)

	for len(node.consumption_log) > MAX_CONSUMPTION_RECORDS {
		oldest := node.consumption_log[0]
		delete(oldest.agent)
		delete(oldest.shard)
		delete(oldest.op)
		delete(oldest.timestamp)
		ordered_remove(&node.consumption_log, 0)
	}

	if len(node.consumption_log) % 50 == 0 {
		_daemon_persist_consumption(node)
	}
}

_op_consumption_log :: proc(node: ^Node, req: Request, allocator := context.allocator) -> string {
	limit := req.limit > 0 ? req.limit : 50
	shard_filter := req.name
	agent_filter := req.agent

	filtered := make([dynamic]Consumption_Record, context.temp_allocator)
	for i := len(node.consumption_log) - 1; i >= 0; i -= 1 {
		if len(filtered) >= limit do break
		rec := node.consumption_log[i]
		if shard_filter != "" && rec.shard != shard_filter do continue
		if agent_filter != "" && rec.agent != agent_filter do continue
		append(
			&filtered,
			Consumption_Record {
				agent = strings.clone(rec.agent, allocator),
				shard = strings.clone(rec.shard, allocator),
				op = strings.clone(rec.op, allocator),
				timestamp = strings.clone(rec.timestamp, allocator),
			},
		)
	}

	return _marshal(Response{status = "ok", consumption_log = filtered[:]}, allocator)
}

_shard_needs_attention :: proc(node: ^Node, shard_name: string, unprocessed_count: int) -> bool {
	if unprocessed_count == 0 do return false

	check_depth := min(len(node.consumption_log), 100)
	for i := len(node.consumption_log) - 1; i >= len(node.consumption_log) - check_depth; i -= 1 {
		if i < 0 do break
		if node.consumption_log[i].shard == shard_name {
			return false
		}
	}

	return unprocessed_count >= 3
}
