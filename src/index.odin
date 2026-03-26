package shard

import "core:os"
import "core:path/filepath"
import "core:fmt"
import "core:strings"

index_path_depth :: proc(path: string) -> int {
	if len(path) == 0 do return 0
	depth := 0
	for c in path {
		if c == '/' do depth += 1
	}
	return depth
}

index_path_parent :: proc(path: string) -> string {
	if len(path) == 0 do return ""
	idx := strings.last_index(path, "/")
	if idx <= 0 do return ""
	return strings.clone(path[:idx], runtime_alloc)
}

index_tree_leaf :: proc(path: string) -> string {
	if len(path) == 0 do return ""
	idx := strings.last_index(path, "/")
	if idx < 0 || idx + 1 >= len(path) do return strings.clone(path, runtime_alloc)
	return strings.clone(path[idx + 1:], runtime_alloc)
}

index_read_entry :: proc(shard_id: string) -> (entry: Index_Entry, ok: bool) {
	path := filepath.join({state.index_dir, shard_id}, runtime_alloc)
	content, read_ok := os.read_entire_file(path, runtime_alloc)
	if !read_ok do return entry, false

	lines := strings.split(string(content), "\n", allocator = runtime_alloc)
	entry.shard_id = strings.clone(shard_id, runtime_alloc)
	if len(lines) >= 1 && len(strings.trim_space(lines[0])) > 0 {
		entry.exe_path = strings.trim_space(lines[0])
	}
	for i in 1 ..< len(lines) {
		line := strings.trim_space(lines[i])
		if len(line) == 0 do continue
		if strings.has_prefix(line, "parent:") {
			entry.parent_id = strings.trim_space(line[len("parent:"):])
			continue
		}
		if strings.has_prefix(line, "path:") {
			entry.tree_path = strings.trim_space(line[len("path:"):])
			continue
		}
		if strings.has_prefix(line, "depth:") {
			d := strings.trim_space(line[len("depth:"):])
			if depth_value, parsed_ok := parse_decimal_int(d); parsed_ok {
				entry.depth = depth_value
			}
			continue
		}
		if len(entry.prev_path) == 0 do entry.prev_path = line
	}

	if len(entry.tree_path) == 0 do entry.tree_path = strings.clone(shard_id, runtime_alloc)
	if len(entry.parent_id) == 0 {
		parent_path := index_path_parent(entry.tree_path)
		if len(parent_path) > 0 do entry.parent_id = index_tree_leaf(parent_path)
	}
	if entry.depth == 0 && entry.tree_path != shard_id {
		entry.depth = index_path_depth(entry.tree_path)
	}

	return entry, len(entry.exe_path) > 0
}

index_read :: proc(shard_id: string) -> (current: string, prev: string, ok: bool) {
	entry, entry_ok := index_read_entry(shard_id)
	if !entry_ok do return "", "", false
	return entry.exe_path, entry.prev_path, true
}

index_write :: proc(
	shard_id: string,
	current: string,
	prev: string = "",
	parent_id: string = "",
	tree_path: string = "",
) -> bool {
	ensure_dir(state.index_dir)
	parent := parent_id
	path_value := tree_path
	if len(parent) == 0 || len(path_value) == 0 {
		if existing, existing_ok := index_read_entry(shard_id); existing_ok {
			if len(parent) == 0 do parent = existing.parent_id
			if len(path_value) == 0 do path_value = existing.tree_path
		}
	}
	if len(path_value) == 0 {
		if len(parent) > 0 {
			parent_path := parent
			if parent_entry, parent_ok := index_read_entry(parent);
			   parent_ok && len(parent_entry.tree_path) > 0 {
				parent_path = parent_entry.tree_path
			}
			path_value = strings.concatenate({parent_path, "/", shard_id}, runtime_alloc)
		} else {
			path_value = strings.clone(shard_id, runtime_alloc)
		}
	}
	if len(parent) == 0 {
		parent_path := index_path_parent(path_value)
		if len(parent_path) > 0 do parent = index_tree_leaf(parent_path)
	}
	depth := index_path_depth(path_value)

	path := filepath.join({state.index_dir, shard_id}, runtime_alloc)
	b := strings.builder_make(runtime_alloc)
	strings.write_string(&b, current)
	strings.write_string(&b, "\n")
	if len(prev) > 0 {
		strings.write_string(&b, prev)
		strings.write_string(&b, "\n")
	}
	fmt.sbprintf(&b, "parent:%s\n", process_json_escape(parent))
	fmt.sbprintf(&b, "path:%s\n", process_json_escape(path_value))
	fmt.sbprintf(&b, "depth:%d\n", depth)
	content := strings.to_string(b)

	return os.write_entire_file(path, transmute([]u8)content)
}

index_list :: proc() -> []Index_Entry {
	ensure_dir(state.index_dir)

	dh, err := os.open(state.index_dir)
	if err != nil do return {}
	defer os.close(dh)

	entries, _ := os.read_dir(dh, -1, runtime_alloc)
	result: [dynamic]Index_Entry
	result.allocator = runtime_alloc

	for entry in entries {
		if entry.is_dir do continue
		item, ok := index_read_entry(entry.name)
		if ok do append(&result, item)
	}
	return result[:]
}

index_sort_tree :: proc(entries: []Index_Entry) {
	for i in 0 ..< len(entries) {
		for j in i + 1 ..< len(entries) {
			a := entries[i]
			b := entries[j]
			swap := false
			if a.depth > b.depth {
				swap = true
			} else if a.depth == b.depth {
				if a.tree_path > b.tree_path do swap = true
			}
			if swap do entries[i], entries[j] = entries[j], entries[i]
		}
	}
}

index_depth_prefix :: proc(depth: int) -> string {
	if depth <= 0 do return ""
	b := strings.builder_make(runtime_alloc)
	for _ in 0 ..< depth {
		strings.write_string(&b, ">")
	}
	return strings.to_string(b)
}

index_cleanup_prev :: proc() {
	current, prev, ok := index_read(state.shard_id)
	if !ok do return
	if len(prev) == 0 do return
	index_write(state.shard_id, current)
}

index_bootstrap_known_shards :: proc() {
	_ = index_list()
}
