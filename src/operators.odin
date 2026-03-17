package shard

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

import logger "logger"
import "core:testing"

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

Ops :: Operators {
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

	logger.infof("daemon: created shard '%s' via remember", req.name)
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
	case "compact_suggest":
		result = _op_compact_suggest(&temp_node, req, allocator)
	case "dump":
		result = _op_dump(&temp_node, req, allocator)
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
		logger.infof("drained %d queued writes after lock release", drained)
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

_op_requires_key :: proc(op: string) -> bool {
	switch op {
	case "write",
	     "read",
	     "update",
	     "delete",
	     "search",
	     "query",
	     "compact",
	     "compact_suggest",
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

_find_registry_entry :: proc(node: ^Node, name: string) -> ^Registry_Entry {
	for &entry in node.registry {
		if entry.name == name {
			return &entry
		}
	}
	return nil
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

		entry_ptr := _find_registry_entry(node, name)
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

		entry_ptr := _find_registry_entry(node, c.name)
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
	// Use pre-parsed tasks from JSON request if available (req.tasks populated by md_parse_request_json)
	tasks: []Fleet_Task
	if req.tasks != nil && len(req.tasks) > 0 {
		tasks = req.tasks
	} else {
		// Fall back to parsing tasks from content body (YAML/CLI path)
		content := strings.trim_space(req.content)
		if content == "" {
			return _err_response("fleet tasks required", allocator)
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

// =============================================================================
// Concurrent stress tests
// =============================================================================

// =============================================================================
// Concurrent stress test — validates multi-agent write safety
// =============================================================================
//
// Creates an in-process daemon node with a test shard slot, then spawns
// N threads that each write thoughts through dispatch() with the node mutex.
// Verifies all writes land, no data loss, and transaction isolation holds.
//

STRESS_AGENT_COUNT :: 10
STRESS_WRITES_EACH :: 5

// _make_test_key_hex converts a Master_Key to a 64-char hex string.
@(private)
_make_test_key_hex :: proc(master: Master_Key) -> string {
	key_full: [64]u8
	for i in 0 ..< 32 {
		hi := master[i] >> 4
		lo := master[i] & 0x0F
		key_full[i*2]   = hi < 10 ? '0' + hi : 'a' + hi - 10
		key_full[i*2+1] = lo < 10 ? '0' + lo : 'a' + lo - 10
	}
	return strings.clone(string(key_full[:]))
}

// _make_test_slot creates a shard slot with a real temp file for flush.
@(private)
_make_test_slot :: proc(name: string, path: string, master: Master_Key) -> ^Shard_Slot {
	slot := new(Shard_Slot)
	slot.name      = strings.clone(name)
	slot.data_path = strings.clone(path)
	slot.loaded    = true
	slot.key_set   = true
	slot.master    = master
	slot.blob = Blob{
		path        = strings.clone(path),
		master      = master,
		processed   = make([dynamic]Thought),
		unprocessed = make([dynamic]Thought),
		description = make([dynamic]string),
		positive    = make([dynamic]string),
		negative    = make([dynamic]string),
		related     = make([dynamic]string),
	}
	slot.index = make([dynamic]Search_Entry)
	return slot
}

// _free_test_slot frees all allocations in a test slot.
@(private)
_free_test_slot :: proc(slot: ^Shard_Slot) {
	// Delete dynamically allocated arrays
	delete(slot.blob.processed)
	delete(slot.blob.unprocessed)
	delete(slot.blob.description)
	delete(slot.blob.positive)
	delete(slot.blob.negative)
	delete(slot.blob.related)
	delete(slot.index)
	delete(slot.write_queue)

	// Delete pending_alerts map contents
	for k, v in slot.pending_alerts {
		delete(k)
		delete(v.agent)
		delete(v.shard_name)
		delete(v.request.name)
		delete(v.request.description)
		delete(v.request.content)
		delete(v.request.query)
		delete(v.request.id)
		delete(v.request.revises)
		delete(v.request.agent)
		delete(v.request.key)
		delete(v.request.lock_id)
		delete(v.request.alert_id)
		delete(v.request.action)
		delete(v.request.event_type)
		delete(v.request.source)
		delete(v.request.feedback)
		for t in v.request.tags do delete(t)
		delete(v.request.tags)
		for t in v.request.related do delete(t)
		delete(v.request.related)
		delete(v.findings)
		delete(v.request.origin_chain)
	}
	delete(slot.pending_alerts)

	// Delete strings that were cloned
	delete(slot.name)
	delete(slot.data_path)
	delete(slot.blob.path)
	delete(slot.lock_agent)
	delete(slot.lock_id)

	free(slot)
}

// _make_test_daemon_node creates a daemon node for testing.
@(private)
_make_test_daemon_node :: proc() -> Node {
	return Node{
		name        = DAEMON_NAME,
		is_daemon   = true,
		running     = true,
		registry    = make([dynamic]Registry_Entry),
		slots       = make(map[string]^Shard_Slot),
		event_queue = make(Event_Queue),
		blob = Blob{
			processed   = make([dynamic]Thought),
			unprocessed = make([dynamic]Thought),
			description = make([dynamic]string),
			positive    = make([dynamic]string),
			negative    = make([dynamic]string),
			related     = make([dynamic]string),
		},
		index = make([dynamic]Search_Entry),
	}
}

// =============================================================================
// Stress test: N agents write concurrently, all writes must land
// =============================================================================

Stress_Thread_Data :: struct {
	node:       ^Node,
	agent_id:   int,
	key_hex:    string,
	success:    int,
	failed:     int,
}

@(test)
test_stress_concurrent_writes :: proc(t: ^testing.T) {
	master: Master_Key
	master[0] = 0xCC; master[1] = 0xDD
	key_str := _make_test_key_hex(master)
	defer delete(key_str)

	test_path := ".shards/_stress_test.shard"
	slot := _make_test_slot("stress-test", test_path, master)
	node := _make_test_daemon_node()
	node.slots["stress-test"] = slot
	append(&node.registry, Registry_Entry{
		name      = "stress-test",
		data_path = test_path,
		catalog   = Catalog{name = "stress-test"},
	})

	// Spawn threads
	thread_data := make([]Stress_Thread_Data, STRESS_AGENT_COUNT)
	threads := make([]^thread.Thread, STRESS_AGENT_COUNT)

	for i in 0 ..< STRESS_AGENT_COUNT {
		thread_data[i] = Stress_Thread_Data{
			node     = &node,
			agent_id = i,
			key_hex  = key_str,
		}
		threads[i] = thread.create(_stress_writer_proc)
		if threads[i] != nil {
			threads[i].data = &thread_data[i]
			thread.start(threads[i])
		}
	}

	// Wait for all threads
	for i in 0 ..< STRESS_AGENT_COUNT {
		if threads[i] != nil {
			thread.join(threads[i])
			thread.destroy(threads[i])
		}
	}

	// Count results
	total_success := 0
	total_failed := 0
	for i in 0 ..< STRESS_AGENT_COUNT {
		total_success += thread_data[i].success
		total_failed  += thread_data[i].failed
	}

	// Verify: total thoughts in the shard should equal total successful writes
	thought_count := len(slot.blob.processed) + len(slot.blob.unprocessed)
	expected := STRESS_AGENT_COUNT * STRESS_WRITES_EACH

	testing.expectf(t, total_success == expected,
		"all writes must succeed: got %d/%d (failed: %d)", total_success, expected, total_failed)
	testing.expectf(t, thought_count == expected,
		"shard must contain all thoughts: got %d, expected %d", thought_count, expected)

	// Cleanup
	// Note: slot is already in node.slots, so let the loop handle it
	for k, v in node.slots {
		delete(k)
		_free_test_slot(v)
	}
	delete(node.slots)
	delete(node.registry)
	delete(node.event_queue)
	delete(node.blob.processed)
	delete(node.blob.unprocessed)
	delete(node.blob.description)
	delete(node.blob.positive)
	delete(node.blob.negative)
	delete(node.blob.related)
	delete(node.index)
	delete(thread_data)
	delete(threads)
	os.remove(test_path)
}

@(private)
_stress_writer_proc :: proc(thr: ^thread.Thread) {
	data := cast(^Stress_Thread_Data)thr.data
	if data == nil do return

	for w in 0 ..< STRESS_WRITES_EACH {
		desc := fmt.tprintf("agent-%d-write-%d", data.agent_id, w)
		msg := fmt.tprintf(
			"---\nop: write\nname: stress-test\nkey: %s\ndescription: %s\nagent: agent-%d\n---\nContent from agent %d write %d\n",
			data.key_hex, desc, data.agent_id, data.agent_id, w,
		)

		sync.lock(&data.node.mu)
		result := dispatch(data.node, msg)
		sync.unlock(&data.node.mu)

		if strings.contains(result, "status: ok") {
			data.success += 1
		} else {
			data.failed += 1
		}
	}
}

// =============================================================================
// Transaction isolation test — locks prevent concurrent mutation,
// writes queue during lock and drain on commit
// =============================================================================

@(test)
test_transaction_isolation :: proc(t: ^testing.T) {
	master: Master_Key
	master[0] = 0xEE; master[1] = 0xFF
	key_str := _make_test_key_hex(master)
	defer delete(key_str)

	test_path := ".shards/_txn_test.shard"
	slot := _make_test_slot("txn-test", test_path, master)
	node := _make_test_daemon_node()
	node.slots["txn-test"] = slot
	append(&node.registry, Registry_Entry{
		name      = "txn-test",
		data_path = test_path,
		catalog   = Catalog{name = "txn-test"},
	})

	// Agent A locks the shard
	lock_msg := fmt.tprintf(
		"---\nop: transaction\nname: txn-test\nkey: %s\nagent: agent-A\nttl: 10\n---\n", key_str)

	sync.lock(&node.mu)
	lock_result := dispatch(&node, lock_msg)
	sync.unlock(&node.mu)

	testing.expect(t, strings.contains(lock_result, "lock_id:"), "transaction must return lock_id")

	// Extract lock_id
	lock_id := ""
	lock_result_copy := strings.clone(lock_result)
	defer delete(lock_result_copy)
	for line in strings.split_lines_iterator(&lock_result_copy) {
		trimmed := strings.trim_space(line)
		if strings.has_prefix(trimmed, "lock_id:") {
			lock_id = strings.clone(strings.trim_space(trimmed[len("lock_id:"):]))
			break
		}
	}
	defer delete(lock_id)
	testing.expect(t, lock_id != "", "must extract lock_id")

	// Agent B tries to write — should be queued
	write_msg := fmt.tprintf(
		"---\nop: write\nname: txn-test\nkey: %s\ndescription: agent B write\nagent: agent-B\n---\nQueued content\n", key_str)

	sync.lock(&node.mu)
	write_result := dispatch(&node, write_msg)
	sync.unlock(&node.mu)

	testing.expect(t, strings.contains(write_result, "queued"),
		"write during lock must be queued")

	// Verify: shard has 0 thoughts (nothing committed yet)
	pre_count := len(slot.blob.processed) + len(slot.blob.unprocessed)
	testing.expectf(t, pre_count == 0,
		"shard must have 0 thoughts before commit, got %d", pre_count)

	// Agent A commits
	commit_msg := fmt.tprintf(
		"---\nop: commit\nname: txn-test\nkey: %s\nlock_id: %s\ndescription: agent A commit\nagent: agent-A\n---\nCommit content\n", key_str, lock_id)

	sync.lock(&node.mu)
	commit_result := dispatch(&node, commit_msg)
	sync.unlock(&node.mu)

	testing.expect(t, strings.contains(commit_result, "status: ok"), "commit must succeed")

	// Verify: shard has 2 thoughts (Agent A commit + Agent B drained)
	post_count := len(slot.blob.processed) + len(slot.blob.unprocessed)
	testing.expectf(t, post_count == 2,
		"shard must have 2 thoughts after commit+drain, got %d", post_count)

	// Cleanup
	os.remove(test_path)
}

// =============================================================================
// Consumption tracking tests
// =============================================================================

// =============================================================================
// Consumption tracking tests
// =============================================================================

// _free_node cleans up a test node.
@(private)
_free_node :: proc(node: ^Node) {
	for &record in node.consumption_log {
		delete(record.agent)
		delete(record.shard)
		delete(record.op)
		delete(record.timestamp)
	}
	delete(node.consumption_log)
	delete(node.registry)
	delete(node.slots)
	delete(node.event_queue)
	delete(node.blob.processed)
	delete(node.blob.unprocessed)
	delete(node.blob.description)
	delete(node.blob.positive)
	delete(node.blob.negative)
	delete(node.blob.related)
	delete(node.index)
}

@(test)
test_consumption_record_tracking :: proc(t: ^testing.T) {
	// Create a daemon node
	node := Node {
		name = "daemon",
		is_daemon = true,
		blob = Blob {
			processed = make([dynamic]Thought),
			unprocessed = make([dynamic]Thought),
			description = make([dynamic]string),
			positive = make([dynamic]string),
			negative = make([dynamic]string),
			related = make([dynamic]string),
		},
		registry = make([dynamic]Registry_Entry),
		slots = make(map[string]^Shard_Slot),
		event_queue = make(Event_Queue),
	}

	// Record some consumption
	_record_consumption(&node, "agent-1", "notes", "read")
	_record_consumption(&node, "agent-2", "todos", "write")
	_record_consumption(&node, "agent-1", "notes", "query")

	testing.expect(t, len(node.consumption_log) == 3, "should have 3 records")
	testing.expect(t, node.consumption_log[0].agent == "agent-1", "first record agent")
	testing.expect(t, node.consumption_log[0].shard == "notes", "first record shard")
	testing.expect(t, node.consumption_log[0].op == "read", "first record op")
	testing.expect(t, node.consumption_log[1].agent == "agent-2", "second record agent")
	testing.expect(t, node.consumption_log[2].op == "query", "third record op")

	_free_node(&node)
}

@(test)
test_consumption_ring_buffer :: proc(t: ^testing.T) {
	node := Node {
		name = "daemon",
		is_daemon = true,
		blob = Blob {
			processed = make([dynamic]Thought),
			unprocessed = make([dynamic]Thought),
			description = make([dynamic]string),
			positive = make([dynamic]string),
			negative = make([dynamic]string),
			related = make([dynamic]string),
		},
		registry = make([dynamic]Registry_Entry),
		slots = make(map[string]^Shard_Slot),
		event_queue = make(Event_Queue),
	}

	// Fill beyond MAX_CONSUMPTION_RECORDS
	for _ in 0 ..< MAX_CONSUMPTION_RECORDS + 50 {
		_record_consumption(&node, "agent", "shard", "read")
	}

	testing.expect(
		t,
		len(node.consumption_log) <= MAX_CONSUMPTION_RECORDS,
		"ring buffer should cap at MAX_CONSUMPTION_RECORDS",
	)
}

@(test)
test_consumption_unknown_agent :: proc(t: ^testing.T) {
	node := Node {
		name = "daemon",
		is_daemon = true,
		blob = Blob {
			processed = make([dynamic]Thought),
			unprocessed = make([dynamic]Thought),
			description = make([dynamic]string),
			positive = make([dynamic]string),
			negative = make([dynamic]string),
			related = make([dynamic]string),
		},
		registry = make([dynamic]Registry_Entry),
		slots = make(map[string]^Shard_Slot),
		event_queue = make(Event_Queue),
	}

	// Empty agent should become "unknown"
	_record_consumption(&node, "", "notes", "read")
	testing.expect(
		t,
		node.consumption_log[0].agent == "unknown",
		"empty agent should become 'unknown'",
	)
}

@(test)
test_consumption_log_op :: proc(t: ^testing.T) {
	node := Node {
		name = "daemon",
		is_daemon = true,
		blob = Blob {
			processed = make([dynamic]Thought),
			unprocessed = make([dynamic]Thought),
			description = make([dynamic]string),
			positive = make([dynamic]string),
			negative = make([dynamic]string),
			related = make([dynamic]string),
		},
		registry = make([dynamic]Registry_Entry),
		slots = make(map[string]^Shard_Slot),
		event_queue = make(Event_Queue),
	}

	_record_consumption(&node, "agent-1", "notes", "read")
	_record_consumption(&node, "agent-2", "todos", "write")
	_record_consumption(&node, "agent-1", "notes", "query")

	// Test unfiltered
	result := _op_consumption_log(&node, Request{limit = 10})
	testing.expect(t, strings.contains(result, "status: ok"), "consumption_log should succeed")
	testing.expect(t, strings.contains(result, "record_count: 3"), "should have 3 records")

	// Test filtered by shard
	result2 := _op_consumption_log(&node, Request{name = "notes", limit = 10})
	testing.expect(
		t,
		strings.contains(result2, "record_count: 2"),
		"should have 2 records for notes",
	)

	// Test filtered by agent
	result3 := _op_consumption_log(&node, Request{agent = "agent-2", limit = 10})
	testing.expect(
		t,
		strings.contains(result3, "record_count: 1"),
		"should have 1 record for agent-2",
	)
}

@(test)
test_needs_attention_empty :: proc(t: ^testing.T) {
	node := Node {
		name = "daemon",
		is_daemon = true,
		blob = Blob {
			processed = make([dynamic]Thought),
			unprocessed = make([dynamic]Thought),
			description = make([dynamic]string),
			positive = make([dynamic]string),
			negative = make([dynamic]string),
			related = make([dynamic]string),
		},
		registry = make([dynamic]Registry_Entry),
		slots = make(map[string]^Shard_Slot),
		event_queue = make(Event_Queue),
	}

	// No unprocessed = no attention needed
	testing.expect(
		t,
		!_shard_needs_attention(&node, "notes", 0),
		"0 unprocessed should not need attention",
	)

	// Below threshold = no attention needed
	testing.expect(
		t,
		!_shard_needs_attention(&node, "notes", 2),
		"2 unprocessed (below threshold) should not need attention",
	)
}

@(test)
test_needs_attention_unvisited :: proc(t: ^testing.T) {
	node := Node {
		name = "daemon",
		is_daemon = true,
		blob = Blob {
			processed = make([dynamic]Thought),
			unprocessed = make([dynamic]Thought),
			description = make([dynamic]string),
			positive = make([dynamic]string),
			negative = make([dynamic]string),
			related = make([dynamic]string),
		},
		registry = make([dynamic]Registry_Entry),
		slots = make(map[string]^Shard_Slot),
		event_queue = make(Event_Queue),
	}

	// 5 unprocessed, no visits = needs attention
	testing.expect(
		t,
		_shard_needs_attention(&node, "notes", 5),
		"unvisited shard with 5 unprocessed should need attention",
	)

	// Record a visit
	_record_consumption(&node, "agent-1", "notes", "read")

	// Now it should NOT need attention (recently visited)
	testing.expect(
		t,
		!_shard_needs_attention(&node, "notes", 5),
		"recently visited shard should not need attention",
	)
}

@(test)
test_consumption_dispatch :: proc(t: ^testing.T) {
	node := Node {
		name = "daemon",
		is_daemon = true,
		blob = Blob {
			processed = make([dynamic]Thought),
			unprocessed = make([dynamic]Thought),
			description = make([dynamic]string),
			positive = make([dynamic]string),
			negative = make([dynamic]string),
			related = make([dynamic]string),
		},
		registry = make([dynamic]Registry_Entry),
		slots = make(map[string]^Shard_Slot),
		event_queue = make(Event_Queue),
	}

	// Test that consumption_log op routes through daemon_dispatch
	result := dispatch(&node, "---\nop: consumption_log\n---\n")
	testing.expect(
		t,
		strings.contains(result, "status: ok"),
		"consumption_log op should succeed via dispatch",
	)
}

// =============================================================================
// Fleet dispatch tests
// =============================================================================

// =============================================================================
// Fleet dispatch tests — validates parallel multi-shard operations
// =============================================================================

// _build_fleet_msg constructs a fleet YAML message with the given JSON task body.
@(private)
_build_fleet_msg :: proc(json_body: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "---\nop: fleet\n---\n")
	strings.write_string(&b, json_body)
	return strings.to_string(b)
}

// _build_fleet_task_json constructs a single JSON task object.
@(private)
_build_fleet_task_json :: proc(name, op, key: string, description: string = "", content: string = "", agent: string = "") -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `"name":"%s","op":"%s","key":"%s"`, name, op, key)
	if description != "" do fmt.sbprintf(&b, `,"description":"%s"`, description)
	if content != "" do fmt.sbprintf(&b, `,"content":"%s"`, content)
	if agent != "" do fmt.sbprintf(&b, `,"agent":"%s"`, agent)
	return strings.to_string(b)
}

// test_fleet_parallel_different_shards creates two shard slots and dispatches
// write ops to both via fleet. Both writes must succeed.
@(test)
test_fleet_parallel_different_shards :: proc(t: ^testing.T) {
	master: Master_Key
	master[0] = 0xA1; master[1] = 0xB2
	key_str := _make_test_key_hex(master)
	defer delete(key_str)

	path_a := ".shards/_fleet_a.shard"
	path_b := ".shards/_fleet_b.shard"
	slot_a := _make_test_slot("fleet-a", path_a, master)
	slot_b := _make_test_slot("fleet-b", path_b, master)

	node := _make_test_daemon_node()
	node.slots["fleet-a"] = slot_a
	node.slots["fleet-b"] = slot_b
	append(&node.registry, Registry_Entry{
		name      = "fleet-a",
		data_path = path_a,
		catalog   = Catalog{name = "fleet-a"},
	})
	append(&node.registry, Registry_Entry{
		name      = "fleet-b",
		data_path = path_b,
		catalog   = Catalog{name = "fleet-b"},
	})

	// Build fleet JSON body using builder (not fmt.tprintf which misinterprets braces)
	task_a := _build_fleet_task_json("fleet-a", "write", key_str, "thought for shard A", "content A", "test")
	task_b := _build_fleet_task_json("fleet-b", "write", key_str, "thought for shard B", "content B", "test")
	json_body := strings.concatenate({"[{", task_a, "},{", task_b, "}]"}, context.temp_allocator)
	fleet_msg := _build_fleet_msg(json_body)

	sync.lock(&node.mu)
	result := dispatch(&node, fleet_msg)
	sync.unlock(&node.mu)

	testing.expectf(t, strings.contains(result, "status: ok"),
		"fleet dispatch must return status: ok")
	testing.expect(t, strings.contains(result, "task_count: 2"),
		"fleet must report 2 tasks")

	// Verify: each shard has 1 thought
	count_a := len(slot_a.blob.processed) + len(slot_a.blob.unprocessed)
	count_b := len(slot_b.blob.processed) + len(slot_b.blob.unprocessed)
	testing.expectf(t, count_a == 1,
		"fleet-a must have 1 thought, got %d", count_a)
	testing.expectf(t, count_b == 1,
		"fleet-b must have 1 thought, got %d", count_b)

	// Cleanup
	os.remove(path_a)
	os.remove(path_b)
}

// test_fleet_same_shard_serialized dispatches 3 write ops to the same shard
// via fleet. All 3 writes must succeed (serialized by slot.mu).
@(test)
test_fleet_same_shard_serialized :: proc(t: ^testing.T) {
	master: Master_Key
	master[0] = 0xC3; master[1] = 0xD4
	key_str := _make_test_key_hex(master)
	defer delete(key_str)

	test_path := ".shards/_fleet_serial.shard"
	slot := _make_test_slot("fleet-serial", test_path, master)

	node := _make_test_daemon_node()
	node.slots["fleet-serial"] = slot
	append(&node.registry, Registry_Entry{
		name      = "fleet-serial",
		data_path = test_path,
		catalog   = Catalog{name = "fleet-serial"},
	})

	// Build fleet message with 3 tasks targeting the same shard
	t1 := _build_fleet_task_json("fleet-serial", "write", key_str, "write 1", "body 1", "test")
	t2 := _build_fleet_task_json("fleet-serial", "write", key_str, "write 2", "body 2", "test")
	t3 := _build_fleet_task_json("fleet-serial", "write", key_str, "write 3", "body 3", "test")
	json_body := strings.concatenate({"[{", t1, "},{", t2, "},{", t3, "}]"}, context.temp_allocator)
	fleet_msg := _build_fleet_msg(json_body)

	sync.lock(&node.mu)
	result := dispatch(&node, fleet_msg)
	sync.unlock(&node.mu)

	testing.expectf(t, strings.contains(result, "status: ok"),
		"fleet dispatch must return status: ok")
	testing.expect(t, strings.contains(result, "task_count: 3"),
		"fleet must report 3 tasks")

	// Verify: shard has 3 thoughts
	count := len(slot.blob.processed) + len(slot.blob.unprocessed)
	testing.expectf(t, count == 3,
		"fleet-serial must have 3 thoughts, got %d", count)

	// Cleanup
	os.remove(test_path)
}

// test_fleet_error_aggregation dispatches one valid and one invalid task.
// The valid task should succeed; the invalid one should show an error status.
@(test)
test_fleet_error_aggregation :: proc(t: ^testing.T) {
	master: Master_Key
	master[0] = 0xE5; master[1] = 0xF6
	key_str := _make_test_key_hex(master)
	defer delete(key_str)

	test_path := ".shards/_fleet_err.shard"
	slot := _make_test_slot("fleet-err", test_path, master)

	node := _make_test_daemon_node()
	node.slots["fleet-err"] = slot
	append(&node.registry, Registry_Entry{
		name      = "fleet-err",
		data_path = test_path,
		catalog   = Catalog{name = "fleet-err"},
	})

	// Task 1: valid write. Task 2: write to a non-existent shard (should error).
	good_task := _build_fleet_task_json("fleet-err", "write", key_str, "valid write", "ok", "test")
	bad_task := _build_fleet_task_json("nonexistent", "write", key_str, "bad write", "fail", "test")
	json_body := strings.concatenate({"[{", good_task, "},{", bad_task, "}]"}, context.temp_allocator)
	fleet_msg := _build_fleet_msg(json_body)

	sync.lock(&node.mu)
	result := dispatch(&node, fleet_msg)
	sync.unlock(&node.mu)

	testing.expectf(t, strings.contains(result, "status: ok"),
		"fleet dispatch must return status: ok (overall)")
	testing.expect(t, strings.contains(result, "task_count: 2"),
		"fleet must report 2 tasks")

	// The valid write should have succeeded
	count := len(slot.blob.processed) + len(slot.blob.unprocessed)
	testing.expectf(t, count == 1,
		"fleet-err must have 1 thought from valid write, got %d", count)

	// Cleanup
	os.remove(test_path)
}

// test_fleet_empty_tasks verifies that fleet op rejects empty task arrays.
@(test)
test_fleet_empty_tasks :: proc(t: ^testing.T) {
	node := _make_test_daemon_node()

	fleet_msg := _build_fleet_msg("[]")

	sync.lock(&node.mu)
	result := dispatch(&node, fleet_msg)
	sync.unlock(&node.mu)

	testing.expect(t, strings.contains(result, "status: error"),
		"fleet with empty tasks must return error")
	testing.expect(t, strings.contains(result, "empty"),
		"error must mention empty tasks")
}

// test_fleet_invalid_json verifies that fleet op rejects invalid JSON.
@(test)
test_fleet_invalid_json :: proc(t: ^testing.T) {
	node := _make_test_daemon_node()

	fleet_msg := _build_fleet_msg("not json")

	sync.lock(&node.mu)
	result := dispatch(&node, fleet_msg)
	sync.unlock(&node.mu)

	testing.expect(t, strings.contains(result, "status: error"),
		"fleet with invalid JSON must return error")
}

// =============================================================================
// Layered traversal tests
// =============================================================================

// =============================================================================
// Layered traversal tests
// =============================================================================

// _make_test_daemon builds a daemon node with the given shard configurations.
// Each shard config creates a registry entry, a loaded slot with encrypted thoughts,
// and a search index. Returns a node ready for dispatch.
@(private)
Test_Shard_Config :: struct {
	name:     string,
	purpose:  string,
	positive: []string,
	related:  []string,
	thoughts: []Thought_Plaintext,
}

@(private)
_make_test_daemon :: proc(key: Master_Key, configs: []Test_Shard_Config) -> Node {
	node := Node {
		name = "daemon",
		is_daemon = true,
		blob = Blob {
			processed = make([dynamic]Thought),
			unprocessed = make([dynamic]Thought),
			description = make([dynamic]string),
			positive = make([dynamic]string),
			negative = make([dynamic]string),
			related = make([dynamic]string),
		},
		registry = make([dynamic]Registry_Entry),
		slots = make(map[string]^Shard_Slot),
		event_queue = make(Event_Queue),
	}

	for cfg in configs {
		slot := new(Shard_Slot)
		slot.name = cfg.name
		slot.loaded = true
		slot.key_set = true
		slot.master = key
		slot.last_access = time.now()
		slot.blob = Blob {
			processed = make([dynamic]Thought),
			unprocessed = make([dynamic]Thought),
			description = make([dynamic]string),
			positive = make([dynamic]string),
			negative = make([dynamic]string),
			related = make([dynamic]string),
			master = key,
			catalog = Catalog{name = cfg.name, purpose = cfg.purpose},
		}

		// Set positive gates
		for p in cfg.positive {
			append(&slot.blob.positive, p)
		}

		// Set related
		for r in cfg.related {
			append(&slot.blob.related, r)
		}

		// Add thoughts
		slot.index = make([dynamic]Search_Entry)
		for pt_cfg in cfg.thoughts {
			tid := new_thought_id()
			thought, _ := thought_create(key, tid, pt_cfg)
			thought.created_at = _format_time(time.now())
			thought.updated_at = _format_time(time.now())
			append(&slot.blob.unprocessed, thought)

			// Build index entry
			append(
				&slot.index,
				Search_Entry {
					id = tid,
					description = pt_cfg.description,
					text_hash = fnv_hash(pt_cfg.description),
				},
			)
		}

		// Clone positive/related for registry entry
		pos_clone := make([]string, len(cfg.positive))
		for p, i in cfg.positive {pos_clone[i] = p}
		rel_clone := make([]string, len(cfg.related))
		for r, i in cfg.related {rel_clone[i] = r}

		append(
			&node.registry,
			Registry_Entry {
				name = cfg.name,
				thought_count = len(cfg.thoughts),
				catalog = Catalog{name = cfg.name, purpose = cfg.purpose},
				gate_positive = pos_clone,
				gate_related = rel_clone,
			},
		)
		node.slots[cfg.name] = slot
	}

	return node
}

@(test)
test_traverse_layer0_returns_shard_names :: proc(t: ^testing.T) {
	key := Master_Key {
		1,
		2,
		3,
		4,
		5,
		6,
		7,
		8,
		9,
		10,
		11,
		12,
		13,
		14,
		15,
		16,
		17,
		18,
		19,
		20,
		21,
		22,
		23,
		24,
		25,
		26,
		27,
		28,
		29,
		30,
		31,
		32,
	}

	configs := []Test_Shard_Config {
		{
			name = "alpha",
			purpose = "Database design and SQL queries",
			positive = {"database", "sql", "schema"},
			thoughts = {
				{
					description = "Database schema overview",
					content = "Tables and relations for the main database",
				},
			},
		},
		{
			name = "beta",
			purpose = "Networking and HTTP protocols",
			positive = {"networking", "http", "tcp"},
			thoughts = {
				{description = "HTTP request handling", content = "How we handle HTTP requests"},
			},
		},
	}

	node := _make_test_daemon(key, configs)

	// Layer 0: should return shard names, not thought content
	req := Request {
		op           = "traverse",
		query        = "database schema",
		max_branches = 5,
		layer        = 0,
	}
	result, handled := daemon_dispatch(&node, req)
	testing.expect(t, handled, "traverse must be handled by daemon")
	testing.expect(t, strings.contains(result, "status: ok"), "traverse L0 must return ok")
	testing.expect(t, strings.contains(result, "alpha"), "traverse L0 must find alpha shard")
	// Layer 0 should NOT contain thought content
	testing.expect(
		t,
		!strings.contains(result, "Tables and relations"),
		"L0 must not include thought content",
	)
}

@(test)
test_traverse_layer1_returns_thought_content :: proc(t: ^testing.T) {
	key := Master_Key {
		1,
		2,
		3,
		4,
		5,
		6,
		7,
		8,
		9,
		10,
		11,
		12,
		13,
		14,
		15,
		16,
		17,
		18,
		19,
		20,
		21,
		22,
		23,
		24,
		25,
		26,
		27,
		28,
		29,
		30,
		31,
		32,
	}

	configs := []Test_Shard_Config {
		{
			name = "alpha",
			purpose = "Database design and SQL queries",
			positive = {"database", "sql", "schema"},
			thoughts = {
				{
					description = "Database schema overview",
					content = "Tables and relations for the main database",
				},
				{
					description = "SQL query optimization",
					content = "Index strategies for fast queries",
				},
			},
		},
		{
			name = "beta",
			purpose = "Networking and HTTP protocols",
			positive = {"networking", "http", "tcp"},
			thoughts = {
				{description = "HTTP request handling", content = "How we handle HTTP requests"},
			},
		},
	}

	node := _make_test_daemon(key, configs)

	// Layer 1: should search within matched shards and return thought content
	req := Request {
		op           = "traverse",
		query        = "database schema",
		max_branches = 5,
		layer        = 1,
	}
	result, handled := daemon_dispatch(&node, req)
	testing.expect(t, handled, "traverse must be handled by daemon")
	testing.expect(t, strings.contains(result, "status: ok"), "traverse L1 must return ok")
	// Layer 1 should contain thought descriptions and content from alpha
	testing.expect(
		t,
		strings.contains(result, "Database schema overview"),
		"L1 must include thought description from matched shard",
	)
	testing.expect(
		t,
		strings.contains(result, "Tables and relations"),
		"L1 must include thought content from matched shard",
	)
	// Result IDs should be in shard_name/thought_hex format
	testing.expect(
		t,
		strings.contains(result, "alpha/"),
		"L1 result IDs must be prefixed with shard name",
	)
	// Should NOT contain thoughts from non-matching shard
	testing.expect(
		t,
		!strings.contains(result, "HTTP request handling"),
		"L1 must not include thoughts from non-matching shard",
	)
}

@(test)
test_traverse_layer2_follows_related :: proc(t: ^testing.T) {
	key := Master_Key {
		1,
		2,
		3,
		4,
		5,
		6,
		7,
		8,
		9,
		10,
		11,
		12,
		13,
		14,
		15,
		16,
		17,
		18,
		19,
		20,
		21,
		22,
		23,
		24,
		25,
		26,
		27,
		28,
		29,
		30,
		31,
		32,
	}

	configs := []Test_Shard_Config {
		{
			name = "alpha",
			purpose = "Database design and SQL queries",
			positive = {"database", "sql", "schema"},
			related = {"gamma"},
			thoughts = {
				{
					description = "Database schema overview",
					content = "Tables and relations for the main database",
				},
			},
		},
		{
			name = "beta",
			purpose = "Networking and HTTP protocols",
			positive = {"networking", "http", "tcp"},
			thoughts = {
				{description = "HTTP request handling", content = "How we handle HTTP requests"},
			},
		},
		{
			name = "gamma",
			purpose = "Database migration tools",
			positive = {"migration", "schema", "versioning"},
			thoughts = {
				{
					description = "Migration strategy for schema changes",
					content = "How to safely evolve database schemas",
				},
			},
		},
	}

	node := _make_test_daemon(key, configs)

	// Layer 2: should search matched shards AND related shards
	req := Request {
		op           = "traverse",
		query        = "database schema",
		max_branches = 5,
		layer        = 2,
	}
	result, handled := daemon_dispatch(&node, req)
	testing.expect(t, handled, "traverse must be handled by daemon")
	testing.expect(t, strings.contains(result, "status: ok"), "traverse L2 must return ok")
	// Should contain alpha's thoughts (direct match)
	testing.expect(
		t,
		strings.contains(result, "Database schema overview"),
		"L2 must include thoughts from matched shard",
	)
	// Should contain gamma's thoughts (related to alpha)
	testing.expect(
		t,
		strings.contains(result, "Migration strategy"),
		"L2 must include thoughts from related shard",
	)
	// Should NOT contain beta's thoughts (not matched, not related)
	testing.expect(
		t,
		!strings.contains(result, "HTTP request handling"),
		"L2 must not include thoughts from unrelated shard",
	)
}

@(test)
test_traverse_layer1_budget_truncation :: proc(t: ^testing.T) {
	key := Master_Key {
		1,
		2,
		3,
		4,
		5,
		6,
		7,
		8,
		9,
		10,
		11,
		12,
		13,
		14,
		15,
		16,
		17,
		18,
		19,
		20,
		21,
		22,
		23,
		24,
		25,
		26,
		27,
		28,
		29,
		30,
		31,
		32,
	}

	long_content := "This is a very long content string that should be truncated when a budget is applied during layer 1 traversal of multiple shards"

	configs := []Test_Shard_Config {
		{
			name = "alpha",
			purpose = "Database design and SQL queries",
			positive = {"database", "sql", "schema"},
			thoughts = {{description = "Database schema overview", content = long_content}},
		},
	}

	node := _make_test_daemon(key, configs)

	// Layer 1 with small budget
	req := Request {
		op           = "traverse",
		query        = "database schema",
		max_branches = 5,
		layer        = 1,
		budget       = 20,
	}
	result, handled := daemon_dispatch(&node, req)
	testing.expect(t, handled, "traverse must be handled by daemon")
	testing.expect(
		t,
		strings.contains(result, "status: ok"),
		"traverse L1 with budget must return ok",
	)
	testing.expect(
		t,
		strings.contains(result, "truncated: true"),
		"L1 with budget must set truncated flag",
	)
	// Full content should NOT be present
	testing.expect(
		t,
		!strings.contains(result, long_content),
		"full content must not be present when budget is small",
	)
}

@(test)
test_traverse_layer_parse :: proc(t: ^testing.T) {
	req, ok := md_parse_request("---\nop: traverse\nquery: test\nlayer: 2\n---\n")
	testing.expect(t, ok, "parse must succeed")
	testing.expect(t, req.layer == 2, "layer must be parsed as 2")
	testing.expect(t, req.op == "traverse", "op must be traverse")
}

@(test)
test_traverse_layer0_unchanged :: proc(t: ^testing.T) {
	// Verify that layer 0 (default) behavior is exactly the same as before
	key := Master_Key {
		1,
		2,
		3,
		4,
		5,
		6,
		7,
		8,
		9,
		10,
		11,
		12,
		13,
		14,
		15,
		16,
		17,
		18,
		19,
		20,
		21,
		22,
		23,
		24,
		25,
		26,
		27,
		28,
		29,
		30,
		31,
		32,
	}

	configs := []Test_Shard_Config {
		{
			name = "alpha",
			purpose = "Database design and SQL queries",
			positive = {"database", "sql"},
			thoughts = {{description = "Schema doc", content = "Content"}},
		},
	}

	node := _make_test_daemon(key, configs)

	// Default (no layer specified) should behave as Layer 0
	req := Request {
		op           = "traverse",
		query        = "database",
		max_branches = 5,
	}
	result, handled := daemon_dispatch(&node, req)
	testing.expect(t, handled, "traverse must be handled by daemon")
	testing.expect(t, strings.contains(result, "status: ok"), "default traverse must return ok")
	testing.expect(t, strings.contains(result, "alpha"), "default traverse must find alpha shard")
	// Default should return shard names, not thought content
	testing.expect(
		t,
		!strings.contains(result, "Schema doc"),
		"default traverse must not include thought descriptions",
	)
}

// =============================================================================
// Cross-shard global query tests
// =============================================================================

// =============================================================================
// Cross-shard global query tests
// =============================================================================

@(test)
test_global_query_basic :: proc(t: ^testing.T) {
	key := Master_Key{1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32}

	configs := []Test_Shard_Config{
		{
			name     = "alpha",
			purpose  = "Database design and SQL queries",
			positive = {"database", "sql", "schema"},
			thoughts = {
				{description = "Database schema overview", content = "Tables and relations for the main database"},
			},
		},
		{
			name     = "beta",
			purpose  = "Networking and HTTP protocols",
			positive = {"networking", "http", "tcp"},
			thoughts = {
				{description = "HTTP request handling", content = "How we handle HTTP requests"},
			},
		},
	}

	node := _make_test_daemon(key, configs)

	req := Request{op = "global_query", query = "database schema"}
	result, handled := daemon_dispatch(&node, req)
	testing.expect(t, handled, "global_query must be handled by daemon")
	testing.expect(t, strings.contains(result, "status: ok"), "global_query must return ok")
	testing.expect(t, strings.contains(result, "Database schema overview"), "must find matching thought")
	testing.expect(t, strings.contains(result, "alpha/"), "result ID must include shard name")
	testing.expect(t, strings.contains(result, "shard_name: alpha"), "result must include shard_name field")
	// Should NOT contain unrelated shard's thoughts
	testing.expect(t, !strings.contains(result, "HTTP request handling"), "must not include unrelated thoughts")
}

@(test)
test_global_query_multiple_shards :: proc(t: ^testing.T) {
	key := Master_Key{1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32}

	configs := []Test_Shard_Config{
		{
			name     = "alpha",
			purpose  = "Database design patterns",
			positive = {"database", "design", "patterns"},
			thoughts = {
				{description = "Database design patterns", content = "Common patterns for database design"},
			},
		},
		{
			name     = "beta",
			purpose  = "Software design patterns",
			positive = {"software", "design", "patterns"},
			thoughts = {
				{description = "Software design patterns", content = "Common software design patterns"},
			},
		},
		{
			name     = "gamma",
			purpose  = "Networking protocols",
			positive = {"networking", "tcp", "udp"},
			thoughts = {
				{description = "TCP protocol details", content = "How TCP works"},
			},
		},
	}

	node := _make_test_daemon(key, configs)

	// "design patterns" should match alpha and beta but not gamma
	req := Request{op = "global_query", query = "design patterns"}
	result, handled := daemon_dispatch(&node, req)
	testing.expect(t, handled, "global_query must be handled by daemon")
	testing.expect(t, strings.contains(result, "status: ok"), "must return ok")
	testing.expect(t, strings.contains(result, "Database design patterns"), "must find alpha's thought")
	testing.expect(t, strings.contains(result, "Software design patterns"), "must find beta's thought")
	testing.expect(t, !strings.contains(result, "TCP protocol"), "must not find gamma's thought")
	testing.expect(t, strings.contains(result, "shards_searched:"), "must report shards_searched")
}

@(test)
test_global_query_threshold_filtering :: proc(t: ^testing.T) {
	key := Master_Key{1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32}

	configs := []Test_Shard_Config{
		{
			name     = "alpha",
			purpose  = "Database design and SQL queries",
			positive = {"database", "sql", "schema"},
			thoughts = {
				{description = "Database schema overview", content = "Tables and relations"},
			},
		},
		{
			name     = "beta",
			purpose  = "General notes",
			positive = {"notes"},
			thoughts = {
				{description = "Random notes", content = "Some random notes"},
			},
		},
	}

	node := _make_test_daemon(key, configs)

	// High threshold should filter out weakly matching shards
	req := Request{op = "global_query", query = "database schema", threshold = 0.8}
	result, handled := daemon_dispatch(&node, req)
	testing.expect(t, handled, "global_query must be handled by daemon")
	testing.expect(t, strings.contains(result, "status: ok"), "must return ok")
	// beta should be filtered out by high threshold
	testing.expect(t, !strings.contains(result, "Random notes"), "high threshold must filter weak matches")
}

@(test)
test_global_query_budget_truncation :: proc(t: ^testing.T) {
	key := Master_Key{1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32}

	long_content := "This is a very long content string that should be truncated when a budget is applied during global cross-shard query execution"

	configs := []Test_Shard_Config{
		{
			name     = "alpha",
			purpose  = "Database design and SQL queries",
			positive = {"database", "sql", "schema"},
			thoughts = {
				{description = "Database schema overview", content = long_content},
			},
		},
	}

	node := _make_test_daemon(key, configs)

	req := Request{op = "global_query", query = "database schema", budget = 20}
	result, handled := daemon_dispatch(&node, req)
	testing.expect(t, handled, "global_query must be handled by daemon")
	testing.expect(t, strings.contains(result, "status: ok"), "must return ok")
	testing.expect(t, strings.contains(result, "truncated: true"), "must set truncated flag")
	testing.expect(t, !strings.contains(result, long_content), "full content must not be present")
}

@(test)
test_global_query_limit :: proc(t: ^testing.T) {
	key := Master_Key{1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32}

	configs := []Test_Shard_Config{
		{
			name     = "alpha",
			purpose  = "Database design and SQL queries",
			positive = {"database", "sql", "schema"},
			thoughts = {
				{description = "Database schema overview", content = "Schema content 1"},
				{description = "Database query patterns", content = "Query content 2"},
				{description = "Database index strategies", content = "Index content 3"},
			},
		},
	}

	node := _make_test_daemon(key, configs)

	// Limit to 1 result
	req := Request{op = "global_query", query = "database", limit = 1}
	result, handled := daemon_dispatch(&node, req)
	testing.expect(t, handled, "global_query must be handled by daemon")
	testing.expect(t, strings.contains(result, "status: ok"), "must return ok")
	// Count result entries — should have exactly 1
	count := strings.count(result, "  - id:")
	testing.expect(t, count == 1, fmt.tprintf("expected 1 result, got %d", count))
}

@(test)
test_global_query_empty_query :: proc(t: ^testing.T) {
	key := Master_Key{1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32}

	configs := []Test_Shard_Config{
		{
			name     = "alpha",
			purpose  = "Database design",
			positive = {"database"},
			thoughts = {{description = "Test", content = "Content"}},
		},
	}

	node := _make_test_daemon(key, configs)

	req := Request{op = "global_query", query = ""}
	result, handled := daemon_dispatch(&node, req)
	testing.expect(t, handled, "global_query must be handled by daemon")
	testing.expect(t, strings.contains(result, "error"), "empty query must return error")
}

@(test)
test_global_query_shard_attribution :: proc(t: ^testing.T) {
	key := Master_Key{1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32}

	configs := []Test_Shard_Config{
		{
			name     = "alpha",
			purpose  = "Database design and SQL queries",
			positive = {"database", "sql"},
			thoughts = {
				{description = "Database schema overview", content = "Alpha's database content"},
			},
		},
		{
			name     = "beta",
			purpose  = "Database optimization and performance",
			positive = {"database", "optimization", "performance"},
			thoughts = {
				{description = "Database performance tuning", content = "Beta's database content"},
			},
		},
	}

	node := _make_test_daemon(key, configs)

	req := Request{op = "global_query", query = "database"}
	result, handled := daemon_dispatch(&node, req)
	testing.expect(t, handled, "global_query must be handled by daemon")
	testing.expect(t, strings.contains(result, "status: ok"), "must return ok")
	// Both shards should appear with attribution
	testing.expect(t, strings.contains(result, "shard_name: alpha"), "must attribute alpha results")
	testing.expect(t, strings.contains(result, "shard_name: beta"), "must attribute beta results")
}

// =============================================================================
// Integration tests — event hub
// =============================================================================

@(test)
test_event_hub_auto_emit :: proc(t: ^testing.T) {

	node := Node{
		registry     = make([dynamic]Registry_Entry),
		slots        = make(map[string]^Shard_Slot),
		event_queue  = Event_Queue{},
	}

	// Set up two related shards
	append(&node.registry, Registry_Entry{
		name      = "shard-a",
		data_path = ".shards/shard-a.shard",
		catalog   = Catalog{related = {"shard-b"}},
		gate_related = {"shard-b"},
	})
	append(&node.registry, Registry_Entry{
		name      = "shard-b",
		data_path = ".shards/shard-b.shard",
		catalog   = Catalog{related = {"shard-a"}},
		gate_related = {"shard-a"},
	})

	// Emit event from shard-a
	req := Request{
		source     = "shard-a",
		event_type = "knowledge_changed",
		agent      = "test-agent",
	}
	result := _op_notify(&node, req)
	testing.expect(t, strings.contains(result, "status: ok"), "notify must succeed")

	// shard-b should have a pending event
	events, has_events := node.event_queue["shard-b"]
	testing.expect(t, has_events, "shard-b must have pending events")
	if has_events {
		testing.expect(t, len(events) == 1, "shard-b must have exactly 1 event")
		if len(events) > 0 {
			testing.expect(t, events[0].source == "shard-a", "event source must be shard-a")
			testing.expect(t, events[0].event_type == "knowledge_changed", "event type must match")
		}
	}

	// shard-a should NOT have an event (origin chain prevents loop)
	_, has_a_events := node.event_queue["shard-a"]
	testing.expect(t, !has_a_events, "shard-a must NOT get its own event")
}

@(test)
test_event_origin_chain_prevents_loop :: proc(t: ^testing.T) {
	node := Node{
		registry     = make([dynamic]Registry_Entry),
		slots        = make(map[string]^Shard_Slot),
		event_queue  = Event_Queue{},
	}

	// A -> B -> C -> A (circular)
	append(&node.registry, Registry_Entry{
		name      = "a",
		data_path = ".shards/a.shard",
		gate_related = {"b"},
	})
	append(&node.registry, Registry_Entry{
		name      = "b",
		data_path = ".shards/b.shard",
		gate_related = {"c"},
	})
	append(&node.registry, Registry_Entry{
		name      = "c",
		data_path = ".shards/c.shard",
		gate_related = {"a"},
	})

	// Emit from a -> b
	_op_notify(&node, Request{source = "a", event_type = "knowledge_changed", agent = "test"})

	// Now simulate b forwarding to c, with origin_chain = [a, b]
	_op_notify(&node, Request{source = "b", event_type = "knowledge_changed", agent = "test", origin_chain = {"a", "b"}})

	// c should have an event, but NOT loop back to a (a is in origin chain)
	c_events, has_c := node.event_queue["c"]
	testing.expect(t, has_c, "c must have events")

	// a should NOT get a second event from c's forwarding since a is in the origin chain
	a_events, has_a := node.event_queue["a"]
	if has_a {
		// a might have events from b's forwarding to c if c->a was tried,
		// but the origin chain should prevent it
		for ev in a_events {
			testing.expect(t, ev.source != "c" || false, "a must not get circular event from c")
		}
	}

	// Verify origin chain length grows
	if has_c && len(c_events) > 0 {
		testing.expect(t, len(c_events[0].origin_chain) >= 2, "origin chain must include a and b")
	}
}
