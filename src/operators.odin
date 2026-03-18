package shard

import "core:sync"

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
		daemon: ^Node,
		slot: ^Shard_Slot,
		temp_node: ^Node,
		req: Request,
		allocator := context.allocator,
	) -> string,
	rollback:               proc(
		daemon: ^Node,
		slot: ^Shard_Slot,
		req: Request,
		allocator := context.allocator,
	) -> string,
	slot_dispatch:          proc(
		daemon: ^Node,
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
	slot_drain_write_queue: proc(daemon: ^Node, slot: ^Shard_Slot, temp_node: ^Node),
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

