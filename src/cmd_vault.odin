package shard

import "core:fmt"
import "core:os"
import "core:strings"

// =============================================================================
// shard vault — export all shards as Obsidian vault with wikilink audit
// =============================================================================

@(private)
_run_vault :: proc() {
	out_path := "vault"
	key_hex: string

	args := os.args[2:]
	for i := 0; i < len(args); i += 1 {
		if args[i] == "--key" && i + 1 < len(args) {
			i += 1; key_hex = args[i]
		} else if args[i] == "--help" || args[i] == "-h" {
			fmt.println("Usage: shard vault [path] [--key <hex>]")
			fmt.println()
			fmt.println("Export all shards as Obsidian markdown vault.")
			fmt.println("Keys resolved per-shard from: --key flag, SHARD_KEY env, or .shards/keychain.")
			fmt.println("Default output path: vault/")
			fmt.println()
			fmt.println("Reports broken [[wikilinks]] after export.")
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

	keychain, kc_ok := keychain_load(context.temp_allocator)

	dir_handle, dir_err := os.open(".shards")
	if dir_err != nil {
		fmt.eprintln("error: could not open .shards/ directory")
		os.exit(1)
	}
	defer os.close(dir_handle)

	entries, read_err := os.read_dir(dir_handle, 0)
	if read_err != nil {
		fmt.eprintln("error: could not read .shards/ directory")
		os.exit(1)
	}

	os.make_directory(out_path)

	// Proc-local types
	Shard_Info :: struct {
		name:    string,
		purpose: string,
		tags:    []string, // points into blob memory; valid until proc exit
	}

	shard_infos    := make([dynamic]Shard_Info, context.allocator)
	tag_map        := make(map[string][dynamic]string, context.allocator)
	exported_names := make(map[string]bool, context.allocator)

	exported := 0
	skipped  := 0
	errors   := 0

	for entry in entries {
		if !strings.has_suffix(entry.name, ".shard") do continue
		if entry.name == "daemon.shard" do continue

		// Clone shard_name so it remains valid after os.file_info_slice_delete(entries)
		shard_name := strings.clone(entry.name[:len(entry.name) - 6])
		// shard_path via fmt.tprintf uses context.temp_allocator — no explicit free needed
		shard_path := fmt.tprintf(".shards/%s", entry.name)

		resolved_key := key_hex
		if resolved_key == "" && kc_ok {
			if kc_key, found := keychain_lookup(keychain, shard_name); found {
				resolved_key = kc_key
			}
		}

		master: Master_Key
		have_key := false
		if k, ok := hex_to_key(resolved_key); ok {
			master = k
			have_key = true
		}

		blob, blob_ok := blob_load(shard_path, master)
		if !blob_ok {
			fmt.printfln("  FAIL  %s (could not load)", entry.name)
			delete(shard_name)
			errors += 1
			continue
		}

		// Collect catalog info BEFORE skip check (behavioral change vs _run_dump:
		// skipped shards now appear in index.md)
		cat := blob.catalog
		append(&shard_infos, Shard_Info{name = shard_name, purpose = cat.purpose, tags = cat.tags})
		for tag in cat.tags {
			if tag not_in tag_map {
				tag_map[tag] = make([dynamic]string, context.allocator)
			}
			append(&tag_map[tag], shard_name)
		}

		total_thoughts := len(blob.processed) + len(blob.unprocessed)
		if total_thoughts > 0 && !have_key {
			fmt.printfln("  SKIP  %s (%d thoughts, no key)", shard_name, total_thoughts)
			blob_destroy(&blob)
			skipped += 1
			continue
		}

		dump_node := Node {
			name = shard_name,
			blob = blob,
		}
		raw_content := _op_dump(&dump_node, Request{}, context.allocator)
		md_content, was_alloc := strings.replace(raw_content, "status: ok\n", "", 1)
		if was_alloc {
			delete(raw_content) // strings.replace allocated a new string; free the original
		}
		// Note: no graph_meta injection (that was the broken code in _run_dump)

		file_path := fmt.tprintf("%s/%s.md", out_path, shard_name)
		write_ok := os.write_entire_file(file_path, transmute([]u8)md_content)
		delete(md_content)
		if !write_ok {
			fmt.printfln("  FAIL  %s (could not write %s)", shard_name, file_path)
			blob_destroy(&blob)
			errors += 1
			continue
		}

		exported_names[shard_name] = true
		fmt.printfln("  exported: %s", file_path)
		// file_path is fmt.tprintf (temp_allocator) — no explicit free
		blob_destroy(&blob)
		exported += 1
	}

	os.file_info_slice_delete(entries)

	// Wikilink audit — scan exported .md files for broken [[links]]
	Broken_Link :: struct {
		file:   string,
		target: string,
	}
	broken := make([dynamic]Broken_Link, context.allocator)
	seen   := make(map[string]map[string]bool, context.allocator)

	for name, _ in exported_names {
		// file_path is temp_allocator — used only for the read call, not stored
		file_path := fmt.tprintf("%s/%s.md", out_path, name)
		content_bytes, read_ok := os.read_entire_file(file_path, context.allocator)
		if !read_ok do continue
		content  := string(content_bytes)
		// file_key uses fmt.aprintf (context.allocator) so it survives past this loop
		// iteration; stored directly in Broken_Link.file and read after the loop ends
		file_key := fmt.aprintf("%s.md", name)

		pos := 0
		for pos < len(content) {
			open := strings.index(content[pos:], "[[")
			if open == -1 do break
			open += pos
			close_rel := strings.index(content[open + 2:], "]]")
			if close_rel == -1 do break
			raw_target := content[open + 2:open + 2 + close_rel]
			// Strip Obsidian alias: [[target|display]] → target
			pipe := strings.index(raw_target, "|")
			target := pipe >= 0 ? raw_target[:pipe] : raw_target
			pos = open + 2 + close_rel + 2

			if target not_in exported_names {
				if file_key not_in seen {
					// Clone once for the seen map key
					seen[strings.clone(file_key)] = make(map[string]bool)
				}
				inner := &seen[file_key]
				if target not_in inner^ {
					cloned_target := strings.clone(target)
					inner^[cloned_target] = true
					append(&broken, Broken_Link{
						file   = file_key, // reuse fmt.tprintf result — no extra clone
						target = cloned_target,
					})
				}
			}
		}
		delete(content_bytes)
	}

	// Print broken links grouped by file
	if len(broken) > 0 {
		fmt.println()
		fmt.println("broken links:")
		// Collect unique files in order of first occurrence
		seen_files := make(map[string]bool, context.allocator)
		file_order := make([dynamic]string, context.allocator)
		for link in broken {
			if link.file not_in seen_files {
				seen_files[link.file] = true
				append(&file_order, link.file)
			}
		}
		for file in file_order {
			targets := make([dynamic]string, context.temp_allocator)
			for link in broken {
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

	// Generate vault index.md
	index_b := strings.builder_make(context.allocator)
	strings.write_string(
		&index_b,
		"---\ntype: vault-index\ntags: [shard-vault]\n---\n\n# Vault Index\n\nAll shards in the knowledge base:\n\n",
	)
	for info in shard_infos {
		if info.purpose != "" {
			fmt.sbprintf(&index_b, "- [[%s]] — %s\n", info.name, info.purpose)
		} else {
			fmt.sbprintf(&index_b, "- [[%s]]\n", info.name)
		}
	}

	// Tag index
	if len(tag_map) > 0 {
		strings.write_string(&index_b, "\n# Tags\n\n")
		sorted_tags := make([dynamic]string, context.allocator)
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
	index_write_ok := os.write_entire_file(index_path, transmute([]u8)index_content_str)
	if index_write_ok {
		fmt.printfln("  index:   %s", index_path)
	}

	fmt.println()
	fmt.printfln("Done: %d exported, %d skipped, %d errors", exported, skipped, errors)
}
