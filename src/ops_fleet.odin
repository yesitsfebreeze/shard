// ops_fleet.odin — fleet operations: parallel multi-shard task dispatch
package shard

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

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
