package shard

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

EVENTS_PATH :: ".shards/.events"


// The daemon is a normal shard process at a fixed IPC endpoint (name = "daemon").
// It loads other shard blobs in-process on demand, routes operations by the
// `name:` field in requests, and exposes the registry (with gates) so AIs can
// decide which shard to query.
//
// IPC endpoint:
//   Windows:    \\.\pipe\shard-daemon
//   POSIX:      /tmp/shard-daemon.sock


// _truncate_to_budget truncates content to fit within budget.
// Returns (truncated_content, was_truncated, new_chars_used, was_ai_compacted)
// If LLM is configured and content exceeds budget, uses AI to compact the content.
_truncate_to_budget :: proc(content: string, budget: int, chars_used: int) -> (string, bool, int, bool) {
	if budget <= 0 {
		return content, false, chars_used + len(content), false
	}
	remaining := budget - chars_used
	if remaining <= 0 {
		return "", true, budget, false
	}
	if len(content) > remaining {
		// Only attempt LLM compaction when smart_query is enabled
		cfg := config_get()
		if cfg.smart_query && cfg.llm_url != "" && cfg.llm_model != "" {
			compacted := _ai_compact_content(content, remaining)
			if compacted != "" {
				return compacted, true, budget, true
			}
		}
		return content[:remaining], true, budget, false
	}
	return content, false, chars_used + len(content), false
}

_ai_compact_content :: proc(content: string, max_len: int) -> string {
	cfg := config_get()
	if cfg.llm_url == "" || cfg.llm_model == "" {
		return "" // No LLM configured
	}

	// Build the compaction prompt
	prompt := fmt.tprintf(
		`Compress this text to under %d characters while preserving the key information:

%s`,
		max_len,
		content,
	)

	// Make the LLM call
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"model":"`)
	strings.write_string(&b, cfg.llm_model)
	strings.write_string(&b, `","messages":[{"role":"user","content":"`)
	json_escape_to(&b, prompt)
	strings.write_string(&b, `"}],"max_tokens":`)

	// Estimate tokens from char count (rough: 1 token ≈ 4 chars)
	max_tokens := min(max_len / 4, 1024)
	fmt.sbprintf(&b, "%d}", max_tokens)

	chat_url := fmt.tprintf("%s/chat/completions", strings.trim_right(cfg.llm_url, "/"))
	response, ok := _http_post(chat_url, cfg.llm_key, strings.to_string(b), cfg.llm_timeout)
	if !ok || response == "" {
		return ""
	}

	return _extract_llm_content(response)
}

@(private)
_extract_llm_content :: proc(response: string) -> string {
	parsed, err := json.parse(transmute([]u8)response, allocator = context.temp_allocator)
	if err != nil do return ""
	defer json.destroy_value(parsed, context.temp_allocator)

	obj, is_obj := parsed.(json.Object)
	if !is_obj do return ""

	choices, has_choices := obj["choices"]
	if !has_choices do return ""
	arr, is_arr := choices.(json.Array)
	if !is_arr || len(arr) == 0 do return ""

	first, is_first := arr[0].(json.Object)
	if !is_first do return ""

	message, has_msg := first["message"]
	if !has_msg do return ""
	msg_obj, is_msg_obj := message.(json.Object)
	if !is_msg_obj do return ""

	content_val, has_content := msg_obj["content"]
	if !has_content do return ""
	if s, is_str := content_val.(string); is_str {
		return s
	}
	return ""
}

daemon_dispatch :: proc(
	node: ^Node,
	req: Request,
	allocator := context.allocator,
) -> (
	string,
	bool,
) {
	switch req.op {
	case "registry":
		return Ops.registry(node, req, allocator), true
	case "discover":
		return Ops.discover(node, allocator), true
	case "remember":
		return Ops.remember(node, req, allocator), true
	case "traverse":
		return Ops.traverse(node, req, allocator), true
	case "alert_response":
		return Ops.alert_response(node, req, allocator), true
	case "alerts":
		return Ops.alerts(node, allocator), true
	case "notify":
		return Ops.notify(node, req, allocator), true
	case "events":
		return Ops.events(node, req, allocator), true
	case "consumption_log":
		return Ops.consumption_log(node, req, allocator), true
	case "digest":
		return Ops.digest(node, req, allocator), true
	case "fleet":
		return Ops.fleet(node, req, allocator), true
	case "global_query":
		return Ops.global_query(node, req, allocator), true
	case "cache":
		return _op_cache(node, req, allocator), true
	}

	if req.name != "" && req.name != DAEMON_NAME {
		return Ops.route_to_slot(node, req, allocator), true
	}

	return "", false
}


// =============================================================================
// Event persistence — .shards/.events file
// =============================================================================

Events_File_Entry :: struct {
	target: string `json:"target"`,
	events: []Shard_Event `json:"events"`,
}

_daemon_persist_events :: proc(node: ^Node) {
	entries := make([dynamic]Events_File_Entry, context.temp_allocator)

	for target, evts in node.event_queue {
		if len(evts) == 0 do continue
		append(&entries, Events_File_Entry{target = target, events = evts[:]})
	}

	data, err := json.marshal(entries[:], allocator = context.temp_allocator)
	if err != nil do return

	tmp_path := EVENTS_PATH + ".tmp"
	if !os.write_entire_file(tmp_path, data) {
		return
	}
	os.remove(EVENTS_PATH)
	os.rename(tmp_path, EVENTS_PATH)
}

daemon_load_events :: proc(node: ^Node) {
	data, ok := os.read_entire_file(EVENTS_PATH, context.temp_allocator)
	if !ok do return

	entries: [dynamic]Events_File_Entry
	if uerr := json.unmarshal(data, &entries); uerr != nil {
		errf("daemon: could not parse %s: %v", EVENTS_PATH, uerr)
		return
	}

	total := 0
	for entry in entries {
		if len(entry.events) == 0 do continue
		queue := make([dynamic]Shard_Event)
		for ev in entry.events {
			append(
				&queue,
				Shard_Event {
					source = strings.clone(ev.source),
					event_type = strings.clone(ev.event_type),
					agent = strings.clone(ev.agent),
					timestamp = strings.clone(ev.timestamp),
					origin_chain = _clone_strings(ev.origin_chain),
				},
			)
			total += 1
		}
		node.event_queue[strings.clone(entry.target)] = queue
	}

	if total > 0 {
		infof("daemon: loaded %d pending events from %s", total, EVENTS_PATH)
	}
}


// =============================================================================
// Consumption persistence — .shards/.consumption file
// =============================================================================

CONSUMPTION_PATH :: ".shards/.consumption"

_daemon_persist_consumption :: proc(node: ^Node) {
	if len(node.consumption_log) == 0 do return

	data, err := json.marshal(node.consumption_log[:], allocator = context.temp_allocator)
	if err != nil do return

	tmp_path := CONSUMPTION_PATH + ".tmp"
	if !os.write_entire_file(tmp_path, data) do return
	os.remove(CONSUMPTION_PATH)
	os.rename(tmp_path, CONSUMPTION_PATH)
}

daemon_load_consumption :: proc(node: ^Node) {
	data, ok := os.read_entire_file(CONSUMPTION_PATH, context.temp_allocator)
	if !ok do return

	entries: [dynamic]Consumption_Record
	if uerr := json.unmarshal(data, &entries); uerr != nil {
		errf("daemon: could not parse %s: %v", CONSUMPTION_PATH, uerr)
		return
	}

	for rec in entries {
		append(
			&node.consumption_log,
			Consumption_Record {
				agent = strings.clone(rec.agent),
				shard = strings.clone(rec.shard),
				op = strings.clone(rec.op),
				timestamp = strings.clone(rec.timestamp),
			},
		)
	}

	if len(entries) > 0 {
		infof("daemon: loaded %d consumption records from %s", len(entries), CONSUMPTION_PATH)
	}
}


// =============================================================================
// Slot management — eviction and flush
// =============================================================================

daemon_evict_idle :: proc(node: ^Node, max_idle: time.Duration) {
	now := time.now()

	for name, slot in node.slots {
		was_locked := slot.lock_expiry != (time.Time{})
		if was_locked && !Ops.slot_is_locked(slot) {
			infof("daemon: auto-released expired lock on shard '%s'", name)
			Ops.emit_event(node, name, "lock_released", "daemon")
			if slot.loaded && len(slot.write_queue) > 0 {
				temp_node := Node {
					name           = slot.name,
					blob           = slot.blob,
					pending_alerts = slot.pending_alerts,
				}
				Ops.slot_drain_write_queue(node, slot, &temp_node)
				slot.blob = temp_node.blob
				slot.pending_alerts = temp_node.pending_alerts
			}
		}

		if !slot.loaded do continue
		idle := time.diff(slot.last_access, now)
		if idle >= max_idle {
			blob_flush(&slot.blob)
			blob_destroy(&slot.blob)
			slot.loaded = false
			slot.key_set = false
			// slot.index removed — index lives on daemon node, not slot
			infof("daemon: evicted idle shard '%s'", name)
		}
	}
}

daemon_flush_all :: proc(node: ^Node) {
	for name, slot in node.slots {
		if slot.loaded {
			blob_flush(&slot.blob)
			infof("daemon: flushed shard '%s'", name)
		}
	}
}

// _free_registry_entry frees all heap-allocated fields in a Registry_Entry.
_free_registry_entry :: proc(entry: ^Registry_Entry) {
	delete(entry.name)
	delete(entry.data_path)
	_free_registry_strings(entry)
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
	defer {
		for &e in entries do delete(e.fullpath)
		delete(entries)
	}

	for entry in entries {
		name := entry.name
		if !strings.has_suffix(name, ".shard") do continue
		if name == "daemon.shard" do continue

		shard_name := name[:len(name) - 6]
		data_path := fmt.tprintf(".shards/%s", name)

		already := false
		for &reg in node.registry {
			if reg.name == shard_name {
				already = true
				_refresh_registry_entry(&reg, data_path)
				break
			}
		}
		if already do continue

		zero_key: Master_Key
		blob, ok := blob_load(data_path, zero_key)
		if !ok do continue

		append(&node.registry, _registry_entry_from_blob(shard_name, data_path, blob))
		infof(
			"daemon: discovered shard '%s' (%d thoughts)",
			shard_name,
			len(blob.processed) + len(blob.unprocessed),
		)
		blob_destroy(&blob)
	}

	_daemon_persist(node)
}

_refresh_registry_entry :: proc(entry: ^Registry_Entry, data_path: string) {
	zero_key: Master_Key
	blob, ok := blob_load(data_path, zero_key)
	if !ok do return
	defer blob_destroy(&blob)

	fresh := _registry_entry_from_blob(entry.name, data_path, blob)

	_free_registry_strings(entry)

	entry.thought_count = fresh.thought_count
	entry.catalog = fresh.catalog
	entry.gate_desc = fresh.gate_desc
	entry.gate_positive = fresh.gate_positive
	entry.gate_negative = fresh.gate_negative
	entry.gate_related = fresh.gate_related
	// Free the fresh entry's name and data_path which were cloned but won't be used
	delete(fresh.name)
	delete(fresh.data_path)
}

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
		infof("daemon: loaded %d shards from registry", len(entries))
	}
}


// =============================================================================
// Helpers
// =============================================================================

_clone_catalog :: proc(cat: Catalog, fallback_name: string = "") -> Catalog {
	name := cat.name != "" ? strings.clone(cat.name) : strings.clone(fallback_name)
	return Catalog {
		name = name,
		purpose = strings.clone(cat.purpose),
		tags = _clone_strings(cat.tags),
		related = _clone_strings(cat.related),
		created = strings.clone(cat.created),
	}
}

_registry_entry_from_blob :: proc(name: string, data_path: string, blob: Blob) -> Registry_Entry {
	return Registry_Entry {
		name = strings.clone(name),
		data_path = strings.clone(data_path),
		thought_count = len(blob.processed) + len(blob.unprocessed),
		catalog = _clone_catalog(blob.catalog, name),
		gate_desc = _clone_strings(blob.description[:]),
		gate_positive = _clone_strings(blob.positive[:]),
		gate_negative = _clone_strings(blob.negative[:]),
		gate_related = _clone_strings(blob.related[:]),
	}
}

_clone_strings :: proc(src: []string, allocator := context.allocator) -> []string {
	if len(src) == 0 do return nil
	out := make([]string, len(src), allocator)
	for s, i in src do out[i] = strings.clone(s, allocator)
	return out
}
