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
	registry:         proc(node: ^Node, req: Request, allocator := context.allocator) -> string,
	discover:         proc(node: ^Node, allocator := context.allocator) -> string,
	remember:         proc(node: ^Node, req: Request, allocator := context.allocator) -> string,
	route_to_slot:   proc(node: ^Node, req: Request, allocator := context.allocator) -> string,
	access:           proc(node: ^Node, req: Request, allocator := context.allocator) -> string,
	digest:           proc(node: ^Node, req: Request, allocator := context.allocator) -> string,
	traverse:         proc(node: ^Node, req: Request, allocator := context.allocator) -> string,
	global_query:     proc(node: ^Node, req: Request, allocator := context.allocator) -> string,
	consumption_log:  proc(node: ^Node, req: Request, allocator := context.allocator) -> string,
	fleet:            proc(node: ^Node, req: Request, allocator := context.allocator) -> string,
	alert_response:   proc(node: ^Node, req: Request, allocator := context.allocator) -> string,
	alerts:           proc(node: ^Node, allocator := context.allocator) -> string,
	notify:           proc(node: ^Node, req: Request, allocator := context.allocator) -> string,
	events:           proc(node: ^Node, req: Request, allocator := context.allocator) -> string,
	transaction:      proc(slot: ^Shard_Slot, req: Request, allocator := context.allocator) -> string,
	commit:           proc(slot: ^Shard_Slot, temp_node: ^Node, req: Request, allocator := context.allocator) -> string,
	rollback:         proc(slot: ^Shard_Slot, req: Request, allocator := context.allocator) -> string,
	slot_dispatch:    proc(slot: ^Shard_Slot, req: Request, allocator := context.allocator) -> string,
	is_mutating:      proc(op: string) -> bool,
	requires_key:     proc(op: string) -> bool,
	emits_event:      proc(op: string) -> bool,
	modifies_gates:   proc(op: string) -> bool,
	slot_is_locked:  proc(slot: ^Shard_Slot) -> bool,
	emit_event:       proc(node: ^Node, source: string, event_type: string, agent: string),
	slot_drain_write_queue: proc(slot: ^Shard_Slot, temp_node: ^Node),
	record_consumption: proc(node: ^Node, agent: string, shard_name: string, op: string),
	access_resolve_key: proc(shard_name: string) -> string,
	score_gates: proc(entry: Registry_Entry, q_tokens: []string) -> Gate_Score,
	negative_gate_rejects: proc(gate_negative: []string, q_tokens: []string) -> bool,
}

Ops :: Operators {
	registry         = _op_registry,
	discover         = _op_discover,
	remember         = _op_remember,
	route_to_slot   = _op_route_to_slot,
	access           = _op_access,
	digest           = _op_digest,
	traverse         = _op_traverse,
	global_query     = _op_global_query,
	consumption_log  = _op_consumption_log,
	fleet            = _op_fleet,
	alert_response   = _op_alert_response,
	alerts           = _op_alerts,
	notify           = _op_notify,
	events           = _op_events,
	transaction      = _op_transaction,
	commit           = _op_commit,
	rollback         = _op_rollback,
	slot_dispatch    = _slot_dispatch,
	is_mutating      = _op_is_mutating,
	requires_key     = _op_requires_key,
	emits_event      = _op_emits_event,
	modifies_gates   = _op_modifies_gates,
	slot_is_locked  = _slot_is_locked,
	emit_event       = _emit_event,
	slot_drain_write_queue = _slot_drain_write_queue,
	record_consumption = _record_consumption,
	access_resolve_key = _access_resolve_key,
	score_gates = _score_gates,
	negative_gate_rejects = _negative_gate_rejects,
}


_op_registry :: proc(node: ^Node, req: Request, allocator := context.allocator) -> string {
	for &entry in node.registry {
		unprocessed := 0
		if slot, ok := node.slots[entry.name]; ok && slot.loaded {
			unprocessed = len(slot.blob.unprocessed)
		}
		entry.needs_attention = _shard_needs_attention(node, entry.name, unprocessed)
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

	fmt.eprintfln("daemon: created shard '%s' via remember", req.name)
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
	case "search":
		result = _op_search(&temp_node, req, allocator)
	case "query":
		result = _op_query(&temp_node, req, allocator)
	case "revisions":
		result = _op_revisions(&temp_node, req, allocator)
	case "compact":
		result = _op_compact(&temp_node, req, allocator)
	case "dump":
		result = _op_dump(&temp_node, allocator)
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

_slot_drain_write_queue :: proc(slot: ^Shard_Slot, temp_node: ^Node) {
	if slot.write_queue == nil || len(slot.write_queue) == 0 do return

	drained := 0
	for &queued_req in slot.write_queue {
		_ = _op_write(temp_node, queued_req, context.temp_allocator)
		drained += 1
	}

	clear(&slot.write_queue)

	if drained > 0 {
		fmt.eprintfln("daemon/%s: drained %d queued writes after lock release", slot.name, drained)
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
	strings.write_string(&b, "---\nstatus: ok\n")
	count := 0
	for _, slot in node.slots {
		if slot.pending_alerts == nil do continue
		for _ in slot.pending_alerts {
			count += 1
		}
	}
	fmt.sbprintf(&b, "count: %d\n", count)
	if count > 0 {
		strings.write_string(&b, "alerts:\n")
		for _, slot in node.slots {
			if slot.pending_alerts == nil do continue
			for _, alert in slot.pending_alerts {
				fmt.sbprintf(
					&b,
					"  - alert_id: %s\n    shard: %s\n    agent: %s\n    created_at: %s\n",
					alert.alert_id,
					alert.shard_name,
					alert.agent,
					alert.created_at,
				)
				if len(alert.findings) > 0 {
					strings.write_string(&b, "    findings:\n")
					for f in alert.findings {
						fmt.sbprintf(
							&b,
							"      - category: %s\n        snippet: %s\n",
							f.category,
							f.snippet,
						)
					}
				}
			}
		}
	}
	strings.write_string(&b, "---\n")
	return strings.to_string(b)
}

_op_notify :: proc(node: ^Node, req: Request, allocator := context.allocator) -> string {
	if req.source == "" do return _err_response("source required", allocator)
	if req.event_type == "" do return _err_response("event_type required", allocator)

	switch req.event_type {
	case "knowledge_changed", "knowledge_stale", "gates_updated", "compacted", "lock_released":
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

_op_requires_key :: proc(op: string) -> bool {
	switch op {
	case "write",
	     "read",
	     "update",
	     "delete",
	     "search",
	     "query",
	     "compact",
	     "dump",
	     "revisions",
	     "stale",
	     "feedback":
		return true
	}
	return false
}

_op_access :: proc(node: ^Node, req: Request, allocator := context.allocator) -> string {
	if req.query == "" do return _err_response("query required", allocator)

	max_results := 5

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

	if len(candidates) == 0 {
		q_tokens := _tokenize(req.query, context.temp_allocator)
		if len(q_tokens) == 0 do return _err_response("query produced no tokens", allocator)

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
		return _marshal(
			Response {
				status = "no_match",
				description = "no shard matched the query — consider creating one with shard_remember",
			},
			allocator,
		)
	}

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

	key_hex := req.key
	if key_hex == "" {
		key_hex = _access_resolve_key(best.name)
	}

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

	_record_consumption(node, req.agent, best.name, "access")

	limit := req.thought_count > 0 ? req.thought_count : config_get().default_query_limit
	budget := req.budget > 0 ? req.budget : config_get().default_query_budget
	wire := make([dynamic]Wire_Result, allocator)

	if slot.key_set && len(slot.index) > 0 {
		hits := search_query(slot.index[:], req.query, context.temp_allocator)
		count := 0
		chars_used_acc := 0
		for h in hits {
			if count >= limit do break
			thought, found := blob_get(&slot.blob, h.id)
			if !found do continue
			pt, err := thought_decrypt(thought, slot.master, allocator)
			if err != .None do continue

			new_content, new_truncated, _ := _truncate_to_budget(
				pt.content,
				budget,
				chars_used_acc,
			)

			append(
				&wire,
				Wire_Result {
					id = id_to_hex(h.id, allocator),
					score = h.score,
					description = pt.description,
					content = new_content,
					truncated = new_truncated,
				},
			)
			count += 1
		}
	}

	hint := ""
	if len(candidates) > 1 {
		alt_names := make([dynamic]string, context.temp_allocator)
		cap := min(len(candidates), 4)
		for i in 1 ..< cap {
			append(&alt_names, candidates[i].name)
		}
		hint = fmt.aprintf(
			"also matched: %s",
			strings.join(alt_names[:], ", ", context.temp_allocator),
		)
	}

	return _marshal(
		Response {
			status = "ok",
			node_name = best.name,
			catalog = entry.catalog,
			results = wire[:],
			description = hint,
		},
		allocator,
	)
}

_op_digest :: proc(node: ^Node, req: Request, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "---\nstatus: ok\nop: digest\n")
	fmt.sbprintf(&b, "shard_count: %d\n", len(node.registry))

	use_filter := req.query != ""
	q_tokens: []string
	if use_filter {
		q_tokens = _tokenize(req.query, context.temp_allocator)
	}

	total_thoughts := 0
	shards_included := 0

	strings.write_string(&b, "---\n")

	for &entry in node.registry {
		if use_filter && len(q_tokens) > 0 {
			gs := _score_gates(entry, q_tokens)
			if gs.score < ACCESS_MIN_SCORE do continue
		}

		shards_included += 1
		thought_count := entry.thought_count
		total_thoughts += thought_count

		fmt.sbprintf(&b, "\n## %s\n", entry.name)
		if entry.catalog.purpose != "" {
			fmt.sbprintf(&b, "**Purpose:** %s\n", entry.catalog.purpose)
		}
		fmt.sbprintf(&b, "**Thoughts:** %d\n", thought_count)
		if entry.catalog.tags != nil && len(entry.catalog.tags) > 0 {
			strings.write_string(&b, "**Tags:** ")
			for tag, i in entry.catalog.tags {
				if i > 0 do strings.write_string(&b, ", ")
				strings.write_string(&b, tag)
			}
			strings.write_string(&b, "\n")
		}

		key_hex := req.key
		if key_hex == "" {
			key_hex = _access_resolve_key(entry.name)
		}

		slot := _slot_get_or_create(node, &entry)
		if !slot.loaded {
			_slot_load(slot, key_hex)
		}
		if key_hex != "" && !slot.key_set {
			_slot_set_key(slot, key_hex)
		}

		if slot.loaded && slot.key_set {
			slot.last_access = time.now()

			if len(slot.blob.processed) > 0 {
				strings.write_string(&b, "### Processed\n")
				for thought in slot.blob.processed {
					pt, err := thought_decrypt(thought, slot.master, context.temp_allocator)
					if err != .None do continue
					fmt.sbprintf(&b, "- %s\n", pt.description)
				}
			}

			if len(slot.blob.unprocessed) > 0 {
				strings.write_string(&b, "### Unprocessed\n")
				for thought in slot.blob.unprocessed {
					pt, err := thought_decrypt(thought, slot.master, context.temp_allocator)
					if err != .None do continue
					fmt.sbprintf(&b, "- %s\n", pt.description)
				}
			}
		} else if slot.loaded {
			strings.write_string(&b, "*No key available — descriptions not shown*\n")
		}
	}

	return strings.to_string(b)
}

_access_resolve_key :: proc(shard_name: string) -> string {
	kc, ok := keychain_load(context.temp_allocator)
	if !ok do return ""
	key, found := keychain_lookup(kc, shard_name)
	if found do return key
	return ""
}

_slot_get_or_create :: proc(node: ^Node, entry: ^Registry_Entry) -> ^Shard_Slot {
	if slot, ok := node.slots[entry.name]; ok {
		return slot
	}
	slot := new(Shard_Slot)
	slot.name = entry.name
	slot.data_path = entry.data_path
	slot.loaded = false
	slot.key_set = false
	slot.last_access = time.now()
	node.slots[entry.name] = slot
	return slot
}

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

	slot.blob = blob
	slot.loaded = true
	slot.master = master
	slot.key_set = has_key

	if has_key {
		_slot_build_index(slot)
	}

	return true
}

_slot_set_key :: proc(slot: ^Shard_Slot, key_hex: string) {
	k, ok := hex_to_key(key_hex)
	if !ok do return

	slot.master = k
	slot.blob.master = slot.master
	slot.key_set = true
	_slot_build_index(slot)
}

_slot_build_index :: proc(slot: ^Shard_Slot) {
	build_search_index(&slot.index, slot.blob, slot.master, fmt.tprintf("daemon/%s", slot.name))
}

_slot_verify_key :: proc(slot: ^Shard_Slot, key_hex: string) -> bool {
	if !slot.key_set do return false
	k, ok := hex_to_key(key_hex)
	if !ok do return false
	diff: u8 = 0
	for i in 0 ..< 32 do diff |= k[i] ~ slot.master[i]
	return diff == 0
}

_op_traverse :: proc(node: ^Node, req: Request, allocator := context.allocator) -> string {
	if req.query == "" do return _err_response("query required", allocator)

	max_branches := req.max_branches > 0 ? req.max_branches : 5
	layer := req.layer

	candidates := _traverse_layer0(node, req.query, max_branches, allocator)

	if layer == 0 {
		return _marshal(Response{status = "ok", results = candidates[:]}, allocator)
	}

	cfg := config_get()
	limit := req.thought_count > 0 ? req.thought_count : cfg.default_query_limit
	budget := req.budget > 0 ? req.budget : cfg.default_query_budget
	max_total := cfg.traverse_results > 0 ? cfg.traverse_results : 10
	now := time.now()

	wire := make([dynamic]Wire_Result, allocator)
	chars_used := 0

	candidate_names := make([dynamic]string, context.temp_allocator)
	for c in candidates {
		append(&candidate_names, c.id)
	}

	_traverse_search_shards(
		node,
		candidate_names[:],
		req.query,
		limit,
		budget,
		max_total,
		now,
		&wire,
		&chars_used,
		allocator,
	)

	if layer >= 2 {
		visited := make(map[string]bool, allocator = context.temp_allocator)
		for name in candidate_names {
			visited[name] = true
		}

		related_names := make([dynamic]string, context.temp_allocator)
		for name in candidate_names {
			for entry in node.registry {
				if entry.name == name {
					rel := len(entry.gate_related) > 0 ? entry.gate_related : entry.catalog.related
					if rel != nil {
						for r in rel {
							if r not_in visited {
								visited[r] = true
								append(&related_names, r)
							}
						}
					}
					break
				}
			}
		}

		if len(related_names) > 0 {
			_traverse_search_shards(
				node,
				related_names[:],
				req.query,
				limit,
				budget,
				max_total,
				now,
				&wire,
				&chars_used,
				allocator,
			)
		}
	}

	_sort_wire_results(wire[:])

	for len(wire) > max_total {
		pop(&wire)
	}

	return _marshal(Response{status = "ok", results = wire[:]}, allocator)
}

_traverse_layer0 :: proc(
	node: ^Node,
	query: string,
	max_branches: int,
	allocator := context.allocator,
) -> [dynamic]Wire_Result {
	wire := make([dynamic]Wire_Result, allocator)

	if len(node.vec_index.entries) > 0 {
		results := index_query(node, query, max_branches * 2, context.temp_allocator)
		if results != nil && len(results) > 0 {
			q_tokens := _tokenize(query, context.temp_allocator)
			defer delete(q_tokens, context.temp_allocator)
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
				append(
					&wire,
					Wire_Result {
						id = strings.clone(r.name, allocator),
						score = r.score,
						description = strings.clone(purpose, allocator),
					},
				)
			}
			if len(wire) > 0 do return wire
		}
	}

	q_tokens := _tokenize(query, context.temp_allocator)
	defer delete(q_tokens, context.temp_allocator)
	if len(q_tokens) == 0 do return wire

	scored := make([dynamic]Gate_Score, context.temp_allocator)
	defer delete(scored)

	for entry in node.registry {
		gs := _score_gates(entry, q_tokens)
		if gs.score > 0 {
			append(&scored, gs)
		}
	}

	for i := 1; i < len(scored); i += 1 {
		key := scored[i]
		j := i - 1
		for j >= 0 && scored[j].score < key.score {
			scored[j + 1] = scored[j]
			j -= 1
		}
		scored[j + 1] = key
	}

	count := min(len(scored), max_branches)
	for i in 0 ..< count {
		gs := scored[i]
		matched_str := ""
		if len(gs.matched) > 0 {
			matched_str = strings.join(gs.matched[:], ", ", allocator)
		}
		append(
			&wire,
			Wire_Result {
				id = strings.clone(gs.name, allocator),
				score = gs.score,
				description = strings.clone(gs.purpose, allocator),
				content = matched_str,
			},
		)
	}

	return wire
}

_traverse_search_shards :: proc(
	node: ^Node,
	shard_names: []string,
	query: string,
	limit_per_shard: int,
	budget: int,
	max_total: int,
	now: time.Time,
	wire: ^[dynamic]Wire_Result,
	chars_used: ^int,
	allocator := context.allocator,
) {
	for name in shard_names {
		if len(wire) >= max_total do break

		entry_ptr: ^Registry_Entry = nil
		for &entry in node.registry {
			if entry.name == name {
				entry_ptr = &entry
				break
			}
		}
		if entry_ptr == nil do continue

		slot := _slot_get_or_create(node, entry_ptr)
		if !slot.loaded {
			key_hex := _access_resolve_key(name)
			if !_slot_load(slot, key_hex) do continue
		}
		if !slot.key_set {
			key_hex := _access_resolve_key(name)
			if key_hex != "" {
				_slot_set_key(slot, key_hex)
			}
		}
		if !slot.key_set do continue

		slot.last_access = time.now()

		if len(slot.index) == 0 &&
		   (len(slot.blob.processed) > 0 || len(slot.blob.unprocessed) > 0) {
			_slot_build_index(slot)
		}

		if len(slot.index) == 0 do continue
		hits := search_query(slot.index[:], query, context.temp_allocator)
		if hits == nil do continue

		count := 0
		for h in hits {
			if count >= limit_per_shard do break
			if len(wire) >= max_total do break

			thought, found := blob_get(&slot.blob, h.id)
			if !found do continue

			pt, err := thought_decrypt(thought, slot.master, allocator)
			if err != .None do continue

			new_content, new_truncated, new_chars := _truncate_to_budget(
				pt.content,
				budget,
				chars_used^,
			)
			chars_used^ = new_chars

			composite := _composite_score(h.score, thought, now)

			thought_hex := id_to_hex(h.id, context.temp_allocator)
			combined_id := fmt.aprintf("%s/%s", name, thought_hex, allocator = allocator)

			append(
				wire,
				Wire_Result {
					id = combined_id,
					shard_name = strings.clone(name, allocator),
					score = composite,
					description = pt.description,
					content = new_content,
					truncated = new_truncated,
					relevance_score = composite,
				},
			)
			count += 1
		}
	}
}

_op_global_query :: proc(node: ^Node, req: Request, allocator := context.allocator) -> string {
	if req.query == "" do return _err_response("query required", allocator)

	cfg := config_get()
	threshold := req.threshold > 0 ? req.threshold : cfg.global_query_threshold
	limit_per_shard := req.thought_count > 0 ? req.thought_count : cfg.default_query_limit
	budget := req.budget > 0 ? req.budget : cfg.default_query_budget
	max_total := req.limit > 0 ? req.limit : (cfg.traverse_results > 0 ? cfg.traverse_results : 10)
	now := time.now()

	q_tokens := _tokenize(req.query, context.temp_allocator)
	if len(q_tokens) == 0 do return _err_response("query produced no tokens", allocator)

	candidates := make([dynamic]_Scored_Shard, context.temp_allocator)

	if len(node.vec_index.entries) > 0 {
		vec_results := index_query(node, req.query, len(node.registry), context.temp_allocator)
		if vec_results != nil && len(vec_results) > 0 {
			for r in vec_results {
				if r.score >= threshold {
					rejected := false
					for entry in node.registry {
						if entry.name == r.name {
							if entry.gate_negative != nil {
								rejected = _negative_gate_rejects(entry.gate_negative, q_tokens)
							}
							break
						}
					}
					if !rejected {
						append(&candidates, _Scored_Shard{name = r.name, score = r.score})
					}
				}
			}
		}
	}

	if len(candidates) == 0 {
		for entry in node.registry {
			if entry.name == DAEMON_NAME do continue
			gs := _score_gates(entry, q_tokens)
			if gs.score >= threshold {
				append(&candidates, _Scored_Shard{name = gs.name, score = gs.score})
			}
		}
	}

	for i := 1; i < len(candidates); i += 1 {
		key := candidates[i]
		j := i - 1
		for j >= 0 && candidates[j].score < key.score {
			candidates[j + 1] = candidates[j]
			j -= 1
		}
		candidates[j + 1] = key
	}

	wire := make([dynamic]Wire_Result, allocator)
	shards_searched := 0

	for c in candidates {
		if len(wire) >= max_total do break

		entry_ptr: ^Registry_Entry = nil
		for &entry in node.registry {
			if entry.name == c.name {
				entry_ptr = &entry
				break
			}
		}
		if entry_ptr == nil do continue

		slot := _slot_get_or_create(node, entry_ptr)
		if !slot.loaded {
			key_hex := _access_resolve_key(c.name)
			if !_slot_load(slot, key_hex) do continue
		}
		if !slot.key_set {
			key_hex := _access_resolve_key(c.name)
			if key_hex != "" {
				_slot_set_key(slot, key_hex)
			}
		}
		if !slot.key_set do continue

		slot.last_access = time.now()

		if len(slot.index) == 0 &&
		   (len(slot.blob.processed) > 0 || len(slot.blob.unprocessed) > 0) {
			_slot_build_index(slot)
		}

		if len(slot.index) == 0 do continue
		hits := search_query(slot.index[:], req.query, context.temp_allocator)
		if hits == nil do continue

		shards_searched += 1
		count := 0
		chars_used_acc := 0
		for h in hits {
			if count >= limit_per_shard do break
			if len(wire) >= max_total do break

			thought, found := blob_get(&slot.blob, h.id)
			if !found do continue

			pt, err := thought_decrypt(thought, slot.master, allocator)
			if err != .None do continue

			new_content, new_truncated, _ := _truncate_to_budget(
				pt.content,
				budget,
				chars_used_acc,
			)

			composite := _composite_score(h.score, thought, now)

			thought_hex := id_to_hex(h.id, context.temp_allocator)
			combined_id := fmt.aprintf("%s/%s", c.name, thought_hex, allocator = allocator)

			append(
				&wire,
				Wire_Result {
					id = combined_id,
					shard_name = strings.clone(c.name, allocator),
					score = composite,
					description = pt.description,
					content = new_content,
					truncated = new_truncated,
					relevance_score = composite,
				},
			)
			count += 1
		}
	}

	_sort_wire_results(wire[:])

	for len(wire) > max_total {
		pop(&wire)
	}

	return _marshal(
		Response {
			status = "ok",
			results = wire[:],
			shards_searched = shards_searched,
			total_results = len(wire),
		},
		allocator,
	)
}

_sort_wire_results :: proc(results: []Wire_Result) {
	for i := 1; i < len(results); i += 1 {
		key := results[i]
		j := i - 1
		for j >= 0 && results[j].score < key.score {
			results[j + 1] = results[j]
			j -= 1
		}
		results[j + 1] = key
	}
}

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

_score_gates :: proc(entry: Registry_Entry, q_tokens: []string) -> Gate_Score {
	result: Gate_Score
	result.name = entry.name
	result.purpose = entry.catalog.purpose
	result.matched = make([dynamic]string, context.temp_allocator)

	raw_score: f32 = 0
	max_possible: f32 = f32(len(q_tokens)) * 2
	if max_possible == 0 {return result}

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

	matched_set: map[string]bool
	defer delete(matched_set)

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

	result.score = min(raw_score / max_possible, 1.0)
	return result
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
	content := strings.trim_space(req.content)
	if content == "" {
		return _err_response("fleet tasks required (JSON array in body)", allocator)
	}

	tasks_json, json_err := json.parse(transmute([]u8)content, allocator = context.temp_allocator)
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

	tasks := make([]Fleet_Task, len(tasks_arr), context.temp_allocator)
	for item, i in tasks_arr {
		obj, is_obj := item.(json.Object)
		if !is_obj do continue
		tasks[i] = Fleet_Task {
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

		entry_ptr: ^Registry_Entry = nil
		for &entry in node.registry {
			if entry.name == task.name {
				entry_ptr = &entry
				break
			}
		}
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
