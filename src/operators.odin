package shard

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

DEFAULT_TRANSACTION_TTL :: 30
ACCESS_MIN_SCORE :: f32(0.1)

Gate_Score :: struct {
	name:    string,
	score:   f32,
	purpose: string,
	matched: [dynamic]string,
}

_Scored_Shard :: struct {
	name:  string,
	score: f32,
}

_Fleet_Thread_Data :: struct {
	node:    ^Node,
	task:    Fleet_Task,
	result:  string,
	slot_mu: ^sync.Mutex,
}

Operators :: struct {
	registry:               proc(
		node: ^Node,
		req: Request,
		allocator := context.allocator,
	) -> string,
	discover:               proc(node: ^Node, allocator := context.allocator) -> string,
	remember:               proc(
		node: ^Node,
		req: Request,
		allocator := context.allocator,
	) -> string,
	route_to_slot:          proc(
		node: ^Node,
		req: Request,
		allocator := context.allocator,
	) -> string,
	access:                 proc(
		node: ^Node,
		req: Request,
		allocator := context.allocator,
	) -> string,
	digest:                 proc(
		node: ^Node,
		req: Request,
		allocator := context.allocator,
	) -> string,
	traverse:               proc(
		node: ^Node,
		req: Request,
		allocator := context.allocator,
	) -> string,
	global_query:           proc(
		node: ^Node,
		req: Request,
		allocator := context.allocator,
	) -> string,
	consumption_log:        proc(
		node: ^Node,
		req: Request,
		allocator := context.allocator,
	) -> string,
	fleet:                  proc(
		node: ^Node,
		req: Request,
		allocator := context.allocator,
	) -> string,
	alert_response:         proc(
		node: ^Node,
		req: Request,
		allocator := context.allocator,
	) -> string,
	alerts:                 proc(node: ^Node, allocator := context.allocator) -> string,
	notify:                 proc(
		node: ^Node,
		req: Request,
		allocator := context.allocator,
	) -> string,
	events:                 proc(
		node: ^Node,
		req: Request,
		allocator := context.allocator,
	) -> string,
	transaction:            proc(
		slot: ^Shard_Slot,
		req: Request,
		allocator := context.allocator,
	) -> string,
	commit:                 proc(
		slot: ^Shard_Slot,
		temp_node: ^Node,
		req: Request,
		allocator := context.allocator,
	) -> string,
	rollback:               proc(
		slot: ^Shard_Slot,
		req: Request,
		allocator := context.allocator,
	) -> string,
	slot_dispatch:          proc(
		slot: ^Shard_Slot,
		req: Request,
		allocator := context.allocator,
	) -> string,
	is_mutating:            proc(op: string) -> bool,
	requires_key:           proc(op: string) -> bool,
	emits_event:            proc(op: string) -> bool,
	modifies_gates:         proc(op: string) -> bool,
	slot_is_locked:         proc(slot: ^Shard_Slot) -> bool,
	emit_event:             proc(node: ^Node, source: string, event_type: string, agent: string),
	slot_drain_write_queue: proc(slot: ^Shard_Slot, temp_node: ^Node),
	record_consumption:     proc(node: ^Node, agent: string, shard_name: string, op: string),
	access_resolve_key:     proc(shard_name: string) -> string,
	find_registry_entry:    proc(node: ^Node, name: string) -> ^Registry_Entry,
	score_gates:            proc(entry: Registry_Entry, q_tokens: []string) -> Gate_Score,
	negative_gate_rejects:  proc(gate_negative: []string, q_tokens: []string) -> bool,
}

Ops := Operators {
	registry               = _op_registry,
	discover               = _op_discover,
	remember               = _op_remember,
	route_to_slot          = _op_route_to_slot,
	access                 = _op_access,
	digest                 = _op_digest,
	traverse               = _op_traverse,
	global_query           = _op_global_query,
	consumption_log        = _op_consumption_log,
	fleet                  = _op_fleet,
	alert_response         = _op_alert_response,
	alerts                 = _op_alerts,
	notify                 = _op_notify,
	events                 = _op_events,
	transaction            = _op_transaction,
	commit                 = _op_commit,
	rollback               = _op_rollback,
	slot_dispatch          = _slot_dispatch,
	is_mutating            = _op_is_mutating,
	requires_key           = _op_requires_key,
	emits_event            = _op_emits_event,
	modifies_gates         = _op_modifies_gates,
	slot_is_locked         = _slot_is_locked,
	emit_event             = _emit_event,
	slot_drain_write_queue = _slot_drain_write_queue,
	record_consumption     = _record_consumption,
	access_resolve_key     = _access_resolve_key,
	find_registry_entry    = _find_registry_entry,
	score_gates            = _score_gates,
	negative_gate_rejects  = _negative_gate_rejects,
}



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

_op_fleet :: proc(node: ^Node, req: Request, allocator := context.allocator) -> string {
	// Use pre-parsed tasks from JSON request if available (req.tasks populated by md_parse_request_json)
	tasks: []Fleet_Task
	if req.tasks != nil && len(req.tasks) > 0 {
		tasks = req.tasks
	} else {
		// Fall back to parsing tasks from content body (JSON/CLI path)
		content := strings.trim_space(req.content)
		if content == "" {
			return _err_response("fleet tasks required", allocator)
		}

		tasks_json, json_err := json.parse(
			transmute([]u8)content,
			allocator = context.temp_allocator,
		)
		if json_err != nil {
			return _err_response("invalid fleet tasks JSON", allocator)
		}

		tasks_arr, is_arr := tasks_json.(json.Array)
		if !is_arr {
			return _err_response("fleet tasks must be a JSON array", allocator)
		}
		if len(tasks_arr) == 0 {
			return _err_response("fleet tasks array is empty", allocator)
		}

		parsed_tasks := make([]Fleet_Task, len(tasks_arr), context.temp_allocator)
		for item, i in tasks_arr {
			obj, is_obj := item.(json.Object)
			if !is_obj do continue
			parsed_tasks[i] = Fleet_Task {
				name        = md_json_get_str(obj, "name"),
				op          = md_json_get_str(obj, "op"),
				key         = md_json_get_str(obj, "key"),
				description = md_json_get_str(obj, "description"),
				content     = md_json_get_str(obj, "content"),
				query       = md_json_get_str(obj, "query"),
				id          = md_json_get_str(obj, "id"),
				agent       = md_json_get_str(obj, "agent"),
			}
		}
		tasks = parsed_tasks
	}

	if len(tasks) == 0 {
		return _err_response("fleet tasks array is empty", allocator)
	}

	cfg := config_get()
	max_parallel := cfg.fleet_max_parallel
	if max_parallel <= 0 do max_parallel = 8

	task_count := len(tasks)
	thread_data := make([]_Fleet_Thread_Data, task_count, context.temp_allocator)

	for i in 0 ..< task_count {
		thread_data[i].node = node
		thread_data[i].task = tasks[i]

		task := tasks[i]
		if task.name == "" || task.name == DAEMON_NAME do continue

		entry_ptr := _find_registry_entry(node, task.name)
		if entry_ptr == nil do continue

		slot := _slot_get_or_create(node, entry_ptr)
		if !slot.loaded {
			_slot_load(slot, task.key)
		}
		if task.key != "" && !slot.key_set {
			_slot_set_key(slot, task.key)
		}
		slot.last_access = time.now()
		thread_data[i].slot_mu = &slot.mu
	}

	batch_size := min(max_parallel, task_count)
	threads := make([]^thread.Thread, batch_size, context.temp_allocator)

	i := 0
	for i < task_count {
		batch_end := min(i + batch_size, task_count)
		active := 0

		for j in i ..< batch_end {
			t := thread.create(_fleet_task_proc)
			if t != nil {
				t.data = &thread_data[j]
				threads[active] = t
				active += 1
				thread.start(t)
			} else {
				_fleet_task_execute(&thread_data[j])
			}
		}

		for j in 0 ..< active {
			thread.join(threads[j])
			thread.destroy(threads[j])
		}

		i = batch_end
	}

	for td in thread_data {
		task := td.task
		if task.name == "" || task.name == DAEMON_NAME do continue

		_record_consumption(node, task.agent, task.name, task.op)

		if _op_modifies_gates(task.op) {
			for &entry in node.registry {
				if entry.name == task.name {
					if slot, ok := node.slots[task.name]; ok {
						_sync_slot_gates(&entry, slot)
						index_update_shard(node, entry.name)
					}
					break
				}
			}
			_daemon_persist(node)
			_emit_event(node, task.name, "gates_updated", task.agent)
		}

		if _op_emits_event(task.op) {
			event_type := task.op == "compact" ? "compacted" : "knowledge_changed"
			_emit_event(node, task.name, event_type, task.agent)
		}
	}

	results := make([]Fleet_Result, task_count, allocator)
	for td, idx in thread_data {
		status := "ok"
		if strings.contains(td.result, "status: error") {
			status = "error"
		}
		results[idx] = Fleet_Result {
			name    = strings.clone(td.task.name, allocator),
			status  = strings.clone(status, allocator),
			content = strings.clone(td.result, allocator),
		}
	}

	return _marshal(Response{status = "ok", fleet_results = results}, allocator)
}

_fleet_task_proc :: proc(t: ^thread.Thread) {
	data := cast(^_Fleet_Thread_Data)t.data
	if data == nil do return
	_fleet_task_execute(data)
}

_fleet_task_execute :: proc(data: ^_Fleet_Thread_Data) {
	task := data.task
	node := data.node

	if task.name == "" || task.name == DAEMON_NAME {
		data.result = _err_response("fleet tasks must target a specific shard", context.allocator)
		return
	}

	slot: ^Shard_Slot = nil
	if s, ok := node.slots[task.name]; ok {
		slot = s
	}
	if slot == nil || !slot.loaded {
		data.result = _err_response(
			fmt.tprintf("shard '%s' not in registry or not loaded", task.name),
			context.allocator,
		)
		return
	}

	if _op_requires_key(task.op) && !slot.key_set {
		data.result = _err_response("key required (provide key in task)", context.allocator)
		return
	}

	fleet_req := Request {
		op          = task.op,
		name        = task.name,
		key         = task.key,
		description = task.description,
		content     = task.content,
		query       = task.query,
		id          = task.id,
		agent       = task.agent,
	}

	if data.slot_mu != nil {
		sync.lock(data.slot_mu)
	}

	data.result = _slot_dispatch(slot, fleet_req, context.allocator)

	if data.slot_mu != nil {
		sync.unlock(data.slot_mu)
	}
}


// =============================================================================
// Topic cache — shared, agent-agnostic context store
// =============================================================================
//
// op: cache
//   action: "write" — append content to a named topic cache
//   action: "read"  — read all entries for a topic as markdown context
//   action: "list"  — list all known topics
//   action: "clear" — delete a topic and all its entries
//
// Topics are in-memory only (daemon lifetime). Multiple agents sharing the
// same topic see a merged context window, FIFO-evicted when max_bytes is set.
//
// Context-mode integration: on each write, a markdown file is written to
// ~/.claude/context-mode/sessions/ (if that directory exists). context-mode
// auto-indexes these files the next time any ctx_* tool is called, making
// the cache content searchable via ctx_search.

_op_cache :: proc(node: ^Node, req: Request, allocator := context.allocator) -> string {
	if node.cache_slots == nil {
		node.cache_slots = make(map[string]^Cache_Slot)
	}

	switch req.action {
	case "write":
		if req.topic == "" do return _err_response("topic required", allocator)
		if req.content == "" do return _err_response("content required", allocator)

		slot, exists := node.cache_slots[req.topic]
		if !exists {
			s := new(Cache_Slot)
			s.topic = strings.clone(req.topic)
			s.max_bytes = req.max_bytes
			s.entries = make([dynamic]Cache_Entry)
			node.cache_slots[strings.clone(req.topic)] = s
			slot = s
		} else if req.max_bytes > 0 && slot.max_bytes == 0 {
			slot.max_bytes = req.max_bytes
		}

		content_bytes := len(req.content)

		// FIFO eviction: drop oldest entries until the new one fits
		if slot.max_bytes > 0 {
			for slot.total_bytes + content_bytes > slot.max_bytes && len(slot.entries) > 0 {
				old := slot.entries[0]
				slot.total_bytes -= len(old.content)
				delete(old.id)
				delete(old.agent)
				delete(old.timestamp)
				delete(old.content)
				ordered_remove(&slot.entries, 0)
			}
		}

		entry := Cache_Entry {
			id        = new_random_hex(),
			agent     = strings.clone(req.agent != "" ? req.agent : "unknown"),
			timestamp = strings.clone(_format_time(time.now())),
			content   = strings.clone(req.content),
		}
		append(&slot.entries, entry)
		slot.total_bytes += content_bytes

		_cache_sync_context_mode(slot)

		return _marshal(Response{status = "ok", id = entry.id}, allocator)

	case "read":
		if req.topic == "" do return _err_response("topic required", allocator)

		slot, exists := node.cache_slots[req.topic]
		if !exists || len(slot.entries) == 0 {
			return _marshal(
				Response {
					status = "ok",
					content = fmt.tprintf("# Cache: %s\n\n(empty)", req.topic),
				},
				allocator,
			)
		}

		b := strings.builder_make(allocator)
		fmt.sbprintf(&b, "# Cache: %s\n\n", slot.topic)
		if slot.max_bytes > 0 {
			fmt.sbprintf(
				&b,
				"Size: %d / %d bytes | Entries: %d\n\n",
				slot.total_bytes,
				slot.max_bytes,
				len(slot.entries),
			)
		} else {
			fmt.sbprintf(
				&b,
				"Size: %d bytes | Entries: %d\n\n",
				slot.total_bytes,
				len(slot.entries),
			)
		}
		for entry in slot.entries {
			fmt.sbprintf(&b, "## [%s] %s\n\n%s\n\n", entry.timestamp, entry.agent, entry.content)
		}

		return _marshal(Response{status = "ok", content = strings.to_string(b)}, allocator)

	case "list":
		b := strings.builder_make(allocator)
		strings.write_string(&b, "---\nstatus: ok\n")
		fmt.sbprintf(&b, "count: %d\n", len(node.cache_slots))
		if len(node.cache_slots) > 0 {
			strings.write_string(&b, "topics:\n")
			for _, slot in node.cache_slots {
				if slot.max_bytes > 0 {
					fmt.sbprintf(
						&b,
						"  - topic: %s\n    entries: %d\n    bytes: %d\n    max_bytes: %d\n",
						slot.topic,
						len(slot.entries),
						slot.total_bytes,
						slot.max_bytes,
					)
				} else {
					fmt.sbprintf(
						&b,
						"  - topic: %s\n    entries: %d\n    bytes: %d\n",
						slot.topic,
						len(slot.entries),
						slot.total_bytes,
					)
				}
			}
		}
		strings.write_string(&b, "---\n")
		return strings.to_string(b)

	case "clear":
		if req.topic == "" do return _err_response("topic required", allocator)

		slot, exists := node.cache_slots[req.topic]
		if !exists {
			return _marshal(Response{status = "ok"}, allocator)
		}

		for &entry in slot.entries {
			delete(entry.id)
			delete(entry.agent)
			delete(entry.timestamp)
			delete(entry.content)
		}
		delete(slot.entries)
		delete(slot.topic)
		free(slot)
		delete_key(&node.cache_slots, req.topic)

		return _marshal(Response{status = "ok"}, allocator)
	}

	return _err_response("action must be write, read, list, or clear", allocator)
}

// _cache_sync_context_mode writes a markdown events file to the context-mode
// sessions directory so context-mode auto-indexes the latest cache entry.
// Best-effort: any I/O error is silently ignored.
_cache_sync_context_mode :: proc(slot: ^Cache_Slot) {
	if len(slot.entries) == 0 do return

	// Resolve home directory
	home: string
	when ODIN_OS == .Windows {
		home, _ = os.lookup_env("USERPROFILE", context.temp_allocator)
		if home == "" do home, _ = os.lookup_env("HOMEDRIVE", context.temp_allocator)
	} else {
		home, _ = os.lookup_env("HOME", context.temp_allocator)
	}
	if home == "" do return

	sessions_dir := fmt.tprintf("%s/.claude/context-mode/sessions", home)

	dh, open_err := os.open(sessions_dir)
	if open_err != nil do return
	os.close(dh)

	file_path := fmt.tprintf("%s/shard-cache-%s-events.md", sessions_dir, slot.topic)

	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "# Shard Cache: %s\n\n", slot.topic)
	last := slot.entries[len(slot.entries) - 1]
	fmt.sbprintf(
		&b,
		"Latest entry by **%s** at %s:\n\n%s\n",
		last.agent,
		last.timestamp,
		last.content,
	)

	os.write_entire_file(file_path, transmute([]u8)strings.to_string(b))
}

_registry_matches :: proc(entry: Registry_Entry, q_tokens: []string) -> bool {
	if len(q_tokens) == 0 do return true
	name_tokens := _tokenize(
		entry.catalog.name != "" ? entry.catalog.name : entry.name,
		context.temp_allocator,
	)
	defer delete(name_tokens, context.temp_allocator)
	for qt in q_tokens {
		for nt in name_tokens {
			if qt == nt do return true
		}
	}
	if entry.catalog.purpose != "" {
		purpose_tokens := _tokenize(entry.catalog.purpose, context.temp_allocator)
		defer delete(purpose_tokens, context.temp_allocator)
		for qt in q_tokens {
			for pt in purpose_tokens {
				if qt == pt do return true
			}
		}
	}
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

_format_time :: proc(t: time.Time) -> string {
	y, mon, d := time.date(t)
	h, m, s := time.clock(t)
	return fmt.tprintf("%04d-%02d-%02dT%02d:%02d:%02dZ", y, int(mon), d, h, m, s)
}

// _build_fleet_msg constructs a fleet JSON message with the given JSON task body.
_build_fleet_msg :: proc(json_body: string) -> string {
	return fmt.tprintf(`{"op":"fleet",%s}`, json_body)
}

// _build_fleet_task_json constructs a single JSON task object.
@(private)
_build_fleet_task_json :: proc(
	name, op, key: string,
	description: string = "",
	content: string = "",
	agent: string = "",
) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `"name":"%s","op":"%s","key":"%s"`, name, op, key)
	if description != "" do fmt.sbprintf(&b, `,"description":"%s"`, description)
	if content != "" do fmt.sbprintf(&b, `,"content":"%s"`, content)
	if agent != "" do fmt.sbprintf(&b, `,"agent":"%s"`, agent)
	return strings.to_string(b)
}
