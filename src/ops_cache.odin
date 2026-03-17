// ops_cache.odin — cache operations: in-memory topic cache, context-mode sync
package shard

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

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

