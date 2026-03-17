// ops_cache.odin — cache operations: in-memory topic cache with session persistence
package shard

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

import logger "logger"

// _cache_sessions_dir returns ~/.shards/sessions for the current user.
// Uses USERPROFILE on Windows, HOME on POSIX. Returns "" if unresolvable.
_cache_sessions_dir :: proc(allocator := context.temp_allocator) -> string {
	home: string
	when ODIN_OS == .Windows {
		home, _ = os.lookup_env("USERPROFILE", allocator)
	} else {
		home, _ = os.lookup_env("HOME", allocator)
	}
	if home == "" do return ""
	return fmt.tprintf("%s/.shards/sessions", home)
}

// _cache_persist_slot writes the full slot to ~/.shards/sessions/<topic>.md
// using an atomic write (temp file → rename). Creates sessions dir if needed.
// Best-effort: any I/O error is logged and silently ignored.
_cache_persist_slot :: proc(slot: ^Cache_Slot) {
	sessions_dir := _cache_sessions_dir()
	if sessions_dir == "" do return

	os.make_directory(sessions_dir)

	file_path := fmt.tprintf("%s/%s.md", sessions_dir, slot.topic)
	tmp_path  := fmt.tprintf("%s/%s.md.tmp", sessions_dir, slot.topic)

	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "---\n")
	fmt.sbprintf(&b, "topic: %s\n",        slot.topic)
	fmt.sbprintf(&b, "entry_count: %d\n",  len(slot.entries))
	fmt.sbprintf(&b, "total_bytes: %d\n",  slot.total_bytes)
	fmt.sbprintf(&b, "max_bytes: %d\n",    slot.max_bytes)
	fmt.sbprintf(&b, "compacted_at: %s\n", slot.compacted_at)
	fmt.sbprintf(&b, "---\n\n")

	for entry in slot.entries {
		fmt.sbprintf(&b, "## [%s] %s\n\n%s\n\n", entry.timestamp, entry.agent, entry.content)
	}

	data := transmute([]u8)strings.to_string(b)
	if !os.write_entire_file(tmp_path, data) {
		logger.warnf("cache: persist write failed for topic '%s'", slot.topic)
		return
	}
	os.remove(file_path)
	when ODIN_OS == .Darwin {
		if !os.rename(tmp_path, file_path) {
			logger.warnf("cache: persist rename failed for topic '%s'", slot.topic)
			os.remove(tmp_path)
		}
	} else {
		if rename_err := os.rename(tmp_path, file_path); rename_err != nil {
			logger.warnf("cache: persist rename failed for topic '%s': %v", slot.topic, rename_err)
			os.remove(tmp_path)
		}
	}
}

// _cache_load_all scans ~/.shards/sessions/*.md and populates node.cache_slots.
// Called once during daemon startup. Files that fail to parse are skipped.
_cache_load_all :: proc(node: ^Node) {
	sessions_dir := _cache_sessions_dir()
	if sessions_dir == "" do return

	dir_handle, open_err := os.open(sessions_dir)
	if open_err != nil do return
	defer os.close(dir_handle)

	entries, read_err := os.read_dir(dir_handle, 0, context.temp_allocator)
	if read_err != nil do return

	loaded := 0
	for entry in entries {
		if !strings.has_suffix(entry.name, ".md") do continue

		file_path := fmt.tprintf("%s/%s", sessions_dir, entry.name)
		data, ok  := os.read_entire_file(file_path, context.temp_allocator)
		if !ok do continue

		slot := _cache_parse_session_file(string(data))
		if slot == nil do continue

		node.cache_slots[strings.clone(slot.topic)] = slot
		loaded += 1
	}

	if loaded > 0 {
		logger.infof("cache: loaded %d topic(s) from ~/.shards/sessions/", loaded)
	}
}

// _cache_parse_session_file parses a session .md file into a heap-allocated Cache_Slot.
// Returns nil on any parse error. All strings use the heap allocator.
_cache_parse_session_file :: proc(data: string) -> ^Cache_Slot {
	if !strings.has_prefix(data, "---\n") do return nil

	rest      := data[4:]
	close_idx := strings.index(rest, "\n---\n")
	if close_idx == -1 do return nil

	frontmatter := rest[:close_idx]
	body        := rest[close_idx + 5:]

	slot := new(Cache_Slot)
	slot.entries = make([dynamic]Cache_Entry)

	fm := frontmatter
	for line in strings.split_lines_iterator(&fm) {
		colon := strings.index(line, ": ")
		if colon == -1 do continue
		key := line[:colon]
		val := line[colon + 2:]
		switch key {
		case "topic":
			slot.topic = strings.clone(val)
		case "max_bytes":
			slot.max_bytes, _ = strconv.parse_int(val)
		case "total_bytes":
			slot.total_bytes, _ = strconv.parse_int(val)
		case "compacted_at":
			if val != "" do slot.compacted_at = strings.clone(val)
		}
	}

	if slot.topic == "" {
		delete(slot.entries)
		free(slot)
		return nil
	}

	// Parse entries: ## [timestamp] agent\n\ncontent\n\n
	remaining := strings.trim_space(body)
	for len(remaining) > 0 {
		if !strings.has_prefix(remaining, "## [") do break

		header_end := strings.index(remaining, "\n")
		if header_end == -1 do break
		header := remaining[3:header_end] // strip "## "

		ts_end := strings.index(header, "] ")
		if ts_end == -1 do break
		timestamp := header[1:ts_end]
		agent     := header[ts_end + 2:]

		content_start := header_end + 1
		if content_start < len(remaining) && remaining[content_start] == '\n' {
			content_start += 1
		}

		content_end  := len(remaining)
		next_entry   := strings.index(remaining[content_start:], "\n## [")
		if next_entry != -1 {
			content_end = content_start + next_entry + 1
		}

		content := strings.trim_space(remaining[content_start:content_end])

		append(&slot.entries, Cache_Entry{
			id        = new_random_hex(),
			agent     = strings.clone(agent),
			timestamp = strings.clone(timestamp),
			content   = strings.clone(content),
		})

		if content_end >= len(remaining) do break
		remaining = strings.trim_left(remaining[content_end:], "\n")
	}

	return slot
}

// _cache_maybe_compact summarizes all slot entries into one via LLM when the
// entry count reaches cfg.cache_compact_threshold. Replaces raw entries with
// the summary entry. Persists the slot after compaction. No-op if threshold is
// 0, not reached, or LLM returns empty (no LLM configured, call failed, etc.).
_cache_maybe_compact :: proc(node: ^Node, slot: ^Cache_Slot) {
	cfg := config_get()
	if cfg.cache_compact_threshold <= 0 do return
	if len(slot.entries) < cfg.cache_compact_threshold do return

	// Build combined content string for the LLM
	b := strings.builder_make(context.temp_allocator)
	for entry in slot.entries {
		fmt.sbprintf(&b, "[%s] %s:\n%s\n\n", entry.timestamp, entry.agent, entry.content)
	}
	all_content := strings.to_string(b)

	max_len := slot.max_bytes > 0 ? slot.max_bytes : 4096
	summary := _ai_compact_content(all_content, max_len)
	if summary == "" do return // LLM unavailable or failed — keep raw entries

	// Free all current entries
	for &entry in slot.entries {
		delete(entry.id)
		delete(entry.agent)
		delete(entry.timestamp)
		delete(entry.content)
	}
	clear(&slot.entries)
	slot.total_bytes = 0

	// Replace with single compacted entry
	now_str := strings.clone(_format_time(time.now()))
	compacted_entry := Cache_Entry{
		id        = new_random_hex(),
		agent     = strings.clone("compacted"),
		timestamp = now_str,
		content   = strings.clone(summary),
	}
	append(&slot.entries, compacted_entry)
	slot.total_bytes = len(summary)

	delete(slot.compacted_at)
	slot.compacted_at = strings.clone(now_str)

	_cache_persist_slot(slot)
	logger.infof("cache: compacted topic '%s' to 1 entry via LLM", slot.topic)
}

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

		_cache_persist_slot(slot)

		// Capture id before potential compaction (compaction frees slot entries including entry.id)
		entry_id := strings.clone(entry.id, allocator)
		_cache_maybe_compact(node, slot)

		return _marshal(Response{status = "ok", id = entry_id}, allocator)

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
		sessions_dir := _cache_sessions_dir()
		if sessions_dir != "" {
			file_path := fmt.tprintf("%s/%s.md", sessions_dir, req.topic)
			os.remove(file_path)
		}
		delete_key(&node.cache_slots, req.topic)

		return _marshal(Response{status = "ok"}, allocator)
	}

	return _err_response("action must be write, read, list, or clear", allocator)
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

