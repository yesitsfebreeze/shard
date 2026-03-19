package shard

import "core:fmt"
import "core:os"
import "core:strings"

// =============================================================================
// shard dump — export shards as markdown files
// =============================================================================

// Dump_Result holds the outcome of a dump operation for reporting.
Dump_Result :: struct {
	exported: int,
	skipped:  int,
	errors:   int,
	broken:   [dynamic]Broken_Link,
	// summary text ready for MCP/CLI
	summary:  string,
}

Broken_Link :: struct {
	file:   string,
	target: string,
}

// _dump_shards is the shared core: exports all .shard files to a folder as markdown.
// shard_filter: if non-empty, only export that shard. out_path: destination folder.
// key_hex: master key override (empty = use env/keychain). Returns a result struct.
@(private)
_dump_shards :: proc(
	out_path: string,
	key_hex: string,
	shard_filter: string,
	allocator := context.allocator,
) -> Dump_Result {
	result: Dump_Result
	result.broken = make([dynamic]Broken_Link, allocator)

	keychain, kc_ok := keychain_load(context.temp_allocator)

	dir_handle, dir_err := os.open(".shards")
	if dir_err != nil {
		result.summary = strings.clone("error: could not open .shards/ directory", allocator)
		result.errors = 1
		return result
	}
	defer os.close(dir_handle)

	entries, read_err := os.read_dir(dir_handle, 0)
	if read_err != nil {
		result.summary = strings.clone("error: could not read .shards/ directory", allocator)
		result.errors = 1
		return result
	}

	os.make_directory(out_path)

	Shard_Info :: struct {
		name:    string,
		purpose: string,
		tags:    []string,
	}

	shard_infos    := make([dynamic]Shard_Info, allocator)
	tag_map        := make(map[string][dynamic]string, allocator)
	exported_names := make(map[string]bool, allocator)

	for entry in entries {
		if !strings.has_suffix(entry.name, ".shard") do continue
		if entry.name == "daemon.shard" do continue

		shard_name := strings.clone(entry.name[:len(entry.name) - 6], allocator)

		// Apply shard filter
		if shard_filter != "" && shard_name != shard_filter {
			delete(shard_name, allocator)
			continue
		}

		shard_path := fmt.tprintf(".shards/%s", entry.name)

		effective_key := key_hex
		if effective_key == "" && kc_ok {
			if kc_key, found := keychain_lookup(keychain, shard_name); found {
				effective_key = kc_key
			}
		}

		master: Master_Key
		have_key := false
		if k, ok := hex_to_key(effective_key); ok {
			master = k
			have_key = true
		}

		blob, blob_ok := blob_load(shard_path, master)
		if !blob_ok {
			result.errors += 1
			continue
		}

		cat := blob.catalog
		append(&shard_infos, Shard_Info{name = shard_name, purpose = cat.purpose, tags = cat.tags})
		for tag in cat.tags {
			if tag not_in tag_map {
				tag_map[tag] = make([dynamic]string, allocator)
			}
			append(&tag_map[tag], shard_name)
		}

		total_thoughts := len(blob.processed) + len(blob.unprocessed)
		if total_thoughts > 0 && !have_key {
			blob_destroy(&blob)
			result.skipped += 1
			continue
		}

		dump_node := Node {
			name = shard_name,
			blob = blob,
		}
		raw_content := _op_dump(&dump_node, Request{}, allocator)
		md_content, was_alloc := strings.replace(raw_content, "status: ok\n", "", 1)
		if was_alloc {
			delete(raw_content)
		}

		file_path := fmt.tprintf("%s/%s.md", out_path, shard_name)
		write_ok := os.write_entire_file(file_path, transmute([]u8)md_content)
		delete(md_content)
		if !write_ok {
			blob_destroy(&blob)
			result.errors += 1
			continue
		}

		exported_names[shard_name] = true
		blob_destroy(&blob)
		result.exported += 1
	}

	os.file_info_slice_delete(entries)

	// Wikilink audit
	seen := make(map[string]map[string]bool, allocator)
	for name, _ in exported_names {
		file_path := fmt.tprintf("%s/%s.md", out_path, name)
		content_bytes, read_ok := os.read_entire_file(file_path, allocator)
		if !read_ok do continue
		content  := string(content_bytes)
		file_key := fmt.aprintf("%s.md", name)

		pos := 0
		for pos < len(content) {
			open := strings.index(content[pos:], "[[")
			if open == -1 do break
			open += pos
			close_rel := strings.index(content[open + 2:], "]]")
			if close_rel == -1 do break
			raw_target := content[open + 2:open + 2 + close_rel]
			pipe := strings.index(raw_target, "|")
			target := pipe >= 0 ? raw_target[:pipe] : raw_target
			pos = open + 2 + close_rel + 2

			if target not_in exported_names {
				if file_key not_in seen {
					seen[strings.clone(file_key)] = make(map[string]bool)
				}
				inner := &seen[file_key]
				if target not_in inner^ {
					cloned_target := strings.clone(target)
					inner^[cloned_target] = true
					append(&result.broken, Broken_Link{
						file   = file_key,
						target = cloned_target,
					})
				}
			}
		}
		delete(content_bytes)
	}

	// Generate index.md (skip if single-shard filter)
	if shard_filter == "" {
		index_b := strings.builder_make(allocator)
		strings.write_string(
			&index_b,
			"---\ntype: dump-index\ntags: [shard-dump]\n---\n\n# Dump Index\n\nAll shards in the knowledge base:\n\n",
		)
		for info in shard_infos {
			if info.purpose != "" {
				fmt.sbprintf(&index_b, "- [[%s]] — %s\n", info.name, info.purpose)
			} else {
				fmt.sbprintf(&index_b, "- [[%s]]\n", info.name)
			}
		}

		if len(tag_map) > 0 {
			strings.write_string(&index_b, "\n# Tags\n\n")
			sorted_tags := make([dynamic]string, allocator)
			for tag, _ in tag_map {
				append(&sorted_tags, tag)
			}
			for i := 1; i < len(sorted_tags); i += 1 {
				key := sorted_tags[i]
				j := i - 1
				for j >= 0 && sorted_tags[j] > key {
					sorted_tags[j + 1] = sorted_tags[j]
					j -= 1
				}
				sorted_tags[j + 1] = key
			}
			for tag in sorted_tags {
				shards_for_tag := tag_map[tag]
				fmt.sbprintf(&index_b, "## #%s\n\n", tag)
				for s in shards_for_tag {
					fmt.sbprintf(&index_b, "- [[%s]]\n", s)
				}
				strings.write_string(&index_b, "\n")
			}
		}

		index_path := fmt.tprintf("%s/index.md", out_path)
		index_content_str := strings.to_string(index_b)
		os.write_entire_file(index_path, transmute([]u8)index_content_str)
	}

	// Build summary
	sb := strings.builder_make(allocator)
	fmt.sbprintf(&sb, "%d exported, %d skipped, %d errors", result.exported, result.skipped, result.errors)
	if len(result.broken) > 0 {
		fmt.sbprintf(&sb, ", %d broken links", len(result.broken))
	}
	result.summary = strings.to_string(sb)
	return result
}

// _run_dump is the CLI entry point for `shard dump`.
@(private)
_run_dump :: proc() {
	out_path := "dump"
	key_hex: string
	shard_filter: string

	args := os.args[2:]
	for i := 0; i < len(args); i += 1 {
		if args[i] == "--key" && i + 1 < len(args) {
			i += 1; key_hex = args[i]
		} else if args[i] == "--out" && i + 1 < len(args) {
			i += 1; out_path = args[i]
		} else if args[i] == "--shard" && i + 1 < len(args) {
			i += 1; shard_filter = args[i]
		} else if args[i] == "--help" || args[i] == "-h" {
			_print_help(HELP_DUMP)
			return
		} else if args[i] == "--ai" {
			_print_help(HELP_AI_DUMP)
			return
		} else if len(args[i]) > 0 && args[i][0] != '-' {
			out_path = args[i]
		}
	}

	if key_hex == "" {
		if env_key, env_ok := os.lookup_env("SHARD_KEY"); env_ok {
			key_hex = env_key
		}
	}

	result := _dump_shards(out_path, key_hex, shard_filter)

	// Print per-file results
	if result.exported > 0 || result.skipped > 0 || result.errors > 0 {
		// Re-list to show what happened (summary is enough)
	}

	// Print broken links
	if len(result.broken) > 0 {
		fmt.println()
		fmt.println("broken links:")
		seen_files := make(map[string]bool, context.allocator)
		file_order := make([dynamic]string, context.allocator)
		for link in result.broken {
			if link.file not_in seen_files {
				seen_files[link.file] = true
				append(&file_order, link.file)
			}
		}
		for file in file_order {
			targets := make([dynamic]string, context.temp_allocator)
			for link in result.broken {
				if link.file == file {
					append(&targets, link.target)
				}
			}
			b := strings.builder_make(context.temp_allocator)
			for t, i in targets {
				if i > 0 do strings.write_string(&b, ", ")
				fmt.sbprintf(&b, "[[%s]]", t)
			}
			fmt.printfln("  %s → %s", file, strings.to_string(b))
		}
	}

	fmt.println()
	fmt.printfln("Done: %s", result.summary)
	fmt.printfln("Output: %s/", out_path)
}
