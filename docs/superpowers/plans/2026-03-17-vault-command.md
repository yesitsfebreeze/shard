# Vault Command Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `shard dump` with `shard vault` — a clean Obsidian vault exporter that includes a wikilink audit pass reporting broken `[[links]]`.

**Architecture:** Add `_run_vault()` to `src/main.odin` following the same direct-proc pattern as `_run_dump()`. After exporting all shards, scan each exported `.md` file for `[[wikilinks]]` and report any that reference non-exported shards. Remove `_run_dump()` and the standalone `--dump` flag entirely.

**Tech Stack:** Odin, `src/main.odin`, `src/protocol.odin` (unchanged), `src/help/shard.txt`, `src/help/ai/mcp.md`, `docs/CONCEPT.txt`

---

## File Map

| File | Change |
|------|--------|
| `src/main.odin` | Add `_run_vault()`, remove `_run_dump()`, remove `dump_path`/`--dump` from `_run_shard()`, add `case "vault"` to CLI switch |
| `src/help/shard.txt` | Remove `--dump` flag line; add `shard vault` to COMMANDS; keep `op: dump` protocol example |
| `src/help/ai/mcp.md` | Add `## CLI` section before `## Available Tools`; keep `shard_dump` entry |
| `docs/CONCEPT.txt` | Update M3 remaining — mark wikilink resolution done |

---

### Task 1: Add `_run_vault()` skeleton and wire into CLI

**Files:**
- Modify: `src/main.odin`

- [ ] **Step 1: Add `case "vault"` to the CLI switch in `main()`**

In `src/main.odin`, find the switch block (around line 46) and add the vault case:

```odin
case "vault":
    _run_vault()
    return
```
Add it after `case "dump":`.

- [ ] **Step 2: Add `_run_vault()` skeleton**

Add this proc at the bottom of `main.odin` (after `_run_dump`):

```odin
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

	fmt.printfln("vault: stub — out_path=%s", out_path)
}
```

- [ ] **Step 3: Build to verify it compiles**

```
just test-build
```
Expected: build succeeds with no errors.

- [ ] **Step 4: Commit skeleton**

```bash
git add src/main.odin
git commit -m "feat: add shard vault CLI skeleton"
```

---

### Task 2: Implement per-shard export loop (without wikilink audit)

**Files:**
- Modify: `src/main.odin`

This task implements steps 1–7 and 9–11 from the spec's Export Logic, minus the audit.

- [ ] **Step 1: Replace the stub body with the full export loop**

**Important implementation notes before writing code:**
- Declare `exported_names := make(map[string]bool, context.allocator)` alongside `shard_infos` and `tag_map` in the local variable block — this map is required by the wikilink audit in Task 3
- Declare `Shard_Info` as a proc-local struct inside `_run_vault()` (same as it is inside `_run_dump()`) — do not rely on `_run_dump`'s declaration
- Collect `Shard_Info` and tags **before** the `if total_thoughts > 0 && !have_key` skip check — this is a deliberate behavioral change; do not copy the order from `_run_dump` where it comes after

Replace the `fmt.printfln("vault: stub...")` line and everything after it in `_run_vault()` with:

```odin
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

	shard_infos := make([dynamic]Shard_Info, context.allocator)
	tag_map     := make(map[string][dynamic]string, context.allocator)
	exported_names := make(map[string]bool, context.allocator)

	exported := 0
	skipped  := 0
	errors   := 0

	for entry in entries {
		if !strings.has_suffix(entry.name, ".shard") do continue
		if entry.name == "daemon.shard" do continue

		shard_name := entry.name[:len(entry.name) - 6]
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
			skipped += 1
			continue
		}

		dump_node := Node {
			name = shard_name,
			blob = blob,
		}
		md_content := _op_dump(&dump_node, Request{}, context.allocator)
		md_content, _ = strings.replace(md_content, "status: ok\n", "", 1)
		// Note: no graph_meta injection (that was the broken code in _run_dump)

		file_path := fmt.tprintf("%s/%s.md", out_path, shard_name)
		write_ok := os.write_entire_file(file_path, transmute([]u8)md_content)
		if !write_ok {
			fmt.printfln("  FAIL  %s (could not write %s)", shard_name, file_path)
			errors += 1
			continue
		}

		exported_names[shard_name] = true
		fmt.printfln("  exported: %s", file_path)
		exported += 1
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
```

- [ ] **Step 2: Build to verify it compiles**

```
just test-build
```
Expected: no errors.

- [ ] **Step 3: Smoke test — run vault on the live .shards/ directory**

```
./bin/shard.exe vault test-vault/
```
Expected: exported lines, `index:   test-vault/index.md`, `Done: N exported...`
Check that `test-vault/index.md` exists and contains `[[shard-name]]` entries.
Check that no `.md` file has a double `---` frontmatter block.

- [ ] **Step 4: Commit**

```bash
git add src/main.odin
git commit -m "feat: implement shard vault export loop"
```

---

### Task 3: Add wikilink audit pass

**Files:**
- Modify: `src/main.odin`

- [ ] **Step 1: Insert the audit pass between the shard loop and the index generation**

**Important implementation notes:**
- `os.read_entire_file(file_path, context.allocator)` allocates with `context.allocator` — explicitly `delete(content_bytes)` at the end of each loop body (do not use `defer` — in Odin `defer` runs at proc exit, not loop iteration exit)
- `fmt.tprintf(...)` for `file_path` and `file_key` also uses `context.allocator` by default; these strings are intentionally kept alive (used in `seen` map and `broken` slice) and should NOT be freed in the loop body
- The `seen` inner maps must be initialized before first use: `if file_key not_in seen { seen[strings.clone(file_key)] = make(map[string]bool) }` — the full code below includes this
- `Broken_Link` is also a proc-local struct; declare it at the start of this block

Find the comment `// Generate vault index.md` in `_run_vault()`. Insert the following **before** it:

```odin
	// Wikilink audit — scan exported .md files for broken [[links]]
	Broken_Link :: struct {
		file:   string,
		target: string,
	}
	broken := make([dynamic]Broken_Link, context.allocator)
	seen   := make(map[string]map[string]bool, context.allocator)

	for name, _ in exported_names {
		file_path := fmt.tprintf("%s/%s.md", out_path, name)
		content_bytes, read_ok := os.read_entire_file(file_path, context.allocator)
		if !read_ok do continue
		content  := string(content_bytes)
		file_key := fmt.tprintf("%s.md", name)

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
					seen[strings.clone(file_key)] = make(map[string]bool)
				}
				if target not_in seen[file_key] {
					seen[file_key][strings.clone(target)] = true
					append(&broken, Broken_Link{
						file:   strings.clone(file_key),
						target: strings.clone(target),
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

```

- [ ] **Step 2: Build**

```
just test-build
```
Expected: no errors.

- [ ] **Step 3: Verify audit fires correctly**

Run vault and check that if any shard's `related` gate contains a name not in the
exported set, it appears in the broken links output. If all shards are exported and
linked correctly, no broken links section prints.

```
./bin/shard.exe vault test-vault/
```

- [ ] **Step 4: Commit**

```bash
git add src/main.odin
git commit -m "feat: add wikilink audit pass to shard vault"
```

---

### Task 4: Remove `shard dump` subcommand and `--dump` standalone flag

**Files:**
- Modify: `src/main.odin`

- [ ] **Step 1: Remove `case "dump"` from the CLI switch in `main()`**

In the switch block, delete:
```odin
case "dump":
    _run_dump()
    return
```

- [ ] **Step 2: Remove `_run_dump()` proc**

Delete the entire `_run_dump()` proc (from the `// shard dump — export all shards as Obsidian markdown` comment through the closing `}`). This is approximately lines 598–796 in the original file.

**Note:** `Shard_Info` was declared proc-locally inside `_run_dump()`. Since `_run_vault()` declares its own proc-local `Shard_Info`, there is no conflict — removing `_run_dump` does not affect `_run_vault`'s struct declaration.

- [ ] **Step 3: Remove `--dump` flag from `_run_shard()`**

In `_run_shard()`, find and delete:
- The `dump_path: string` variable declaration (around line 133)
- The `} else if args[i] == "--dump" {` block (approximately lines 144–148)
- The entire `// --dump: export shard as markdown file and exit` block that uses `dump_path` (approximately lines 182–215)

- [ ] **Step 4: Build**

```
just test-build
```
Expected: no errors.

- [ ] **Step 5: Run all tests**

```
just test
```
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add src/main.odin
git commit -m "feat: remove shard dump — replaced by shard vault"
```

---

### Task 5: Update help text

**Files:**
- Modify: `src/help/shard.txt`
- Modify: `src/help/ai/mcp.md`

- [ ] **Step 1: Update `src/help/shard.txt`**

a. In the `FLAGS (standalone mode)` section, remove this exact line:
```
  --dump [path]     Export shard as Obsidian markdown and exit. (default: markdown/)
```

b. In the `COMMANDS` section (the block with `shard daemon`, `shard new`, etc.), add:
```
  shard vault [path]                                  Export all shards as Obsidian markdown vault
```

c. Verify the `op: dump` IPC protocol example is still present (do not remove it).
d. Verify the `shard_dump` MCP tool summary line is still present (do not remove it).

- [ ] **Step 2: Update `src/help/ai/mcp.md`**

Add a new `## CLI` section immediately before the `## Available Tools` heading:

```markdown
## CLI

```bash
shard vault [path] [--key <hex>]
```

Export all shards as Obsidian markdown. Default output directory: `vault/`. Keys resolved per-shard from `--key` flag, `SHARD_KEY` env, or `.shards/keychain`. Reports broken `[[wikilinks]]` after export.

```

- [ ] **Step 3: Build to verify help text still embeds correctly**

```
just test-build
```
Expected: no errors.

- [ ] **Step 4: Spot-check help output**

```
./bin/shard.exe --help
./bin/shard.exe vault --help
```
Expected: `dump` gone from main help; `vault` present; `vault --help` shows usage.

- [ ] **Step 5: Commit**

```bash
git add src/help/shard.txt src/help/ai/mcp.md
git commit -m "docs: update help text — add vault, remove dump CLI entry"
```

---

### Task 6: Update CONCEPT.txt and run final checks

**Files:**
- Modify: `docs/CONCEPT.txt`

- [ ] **Step 1: Update M3 remaining items in CONCEPT.txt**

Find the M3 section (around line 773). The current text reads:
```
  Remaining: filtered cross-shard export, vault-level Obsidian index, wikilink
  resolution.
```

Replace with:
```
  Done: global_query default routing, vec_index persistence, vault export
  (shard vault command with wikilink audit).
  Remaining: filtered cross-shard export (global_dump op).
```

- [ ] **Step 2: Run full test suite**

```
just test
```
Expected: all tests pass.

- [ ] **Step 3: Final smoke test**

```
./bin/shard.exe vault test-vault2/
ls test-vault2/
```
Expected: one `.md` per shard + `index.md`. No double-frontmatter. Broken links section
appears only if there are actually broken wikilinks.

- [ ] **Step 4: Commit**

```bash
git add docs/CONCEPT.txt
git commit -m "docs: update CONCEPT.txt — vault command completes M3 wikilink resolution"
```

---

### Task 7: Final verification

- [ ] **Step 1: Run full tests one last time**

```
just test
```
Expected: all pass, 0 failures.

- [ ] **Step 2: Verify `shard dump` is fully gone**

```bash
grep -r "shard dump\|_run_dump\|dump_path\|--dump" src/ --include="*.odin"
```
Expected: no results (the only remaining `dump` references should be `_op_dump` in
`protocol.odin` and the `shard_dump` MCP tool in `mcp.odin`).

- [ ] **Step 3: Verify `shard vault` is wired end-to-end**

```
./bin/shard.exe --help | grep vault
./bin/shard.exe vault --help
```
Expected: vault appears in main help; vault --help shows correct usage.
