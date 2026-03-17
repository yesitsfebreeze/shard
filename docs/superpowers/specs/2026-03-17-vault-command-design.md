# Design: `shard vault` — Replace `shard dump` with Obsidian Vault Export

**Date:** 2026-03-17  
**Status:** Approved  
**Milestone:** M3 — Unified Knowledge Base (P2 remaining item)

---

## Summary

Replace the `shard dump` CLI subcommand with `shard vault <dir>`. The new command
is a clean, correct vault exporter: it writes every shard as an Obsidian-compatible
`.md` file, generates an `index.md` with wikilinks and a tag index, then does a
second-pass audit that reports any broken `[[wikilinks]]` found in the output.

`shard dump` is removed entirely. The MCP tool `shard_dump` (protocol-level, used
by agents) is **not** renamed — that is a separate breaking-change concern.

---

## Motivation

The existing `shard dump` command has several issues:

1. **Broken frontmatter injection** — `_run_dump` inserts a second `---` YAML block
   after the first, producing invalid frontmatter that Obsidian silently ignores.
2. **No wikilink validation** — `[[name]]` references in thought content and the
   `## Related` section are emitted as-is. If a shard wasn't exported (no key,
   or filtered), the link is silently broken in the vault.
3. **Skipped shards absent from index** — shards with thoughts but no key are
   currently excluded from `index.md` entirely. The vault index should list every
   known shard so the user can see what exists, even if the content wasn't exported.
   This is a deliberate behavioral change from `_run_dump`.
4. **Name** — `dump` is an implementation word. `vault` describes the output.
5. **Standalone `--dump` flag** — `_run_shard()` has a `--dump <path>` flag for
   single-shard standalone mode. This is redundant now that the daemon handles
   all shards; it should be removed.

---

## CLI

```
shard vault [path] [--key <hex>]
```

- **Default path:** `vault/` (was `markdown/`)
- **Key resolution:** `--key` flag → `SHARD_KEY` env → `.shards/keychain` per-shard
- **Help flag:** `--help` / `-h` prints usage and exits

Remove from CLI:
- `case "dump": _run_dump()` in `main()`
- `_run_dump()` proc in `main.odin`
- `--dump [path]` flag parsing and the `dump_path` variable in `_run_shard()`

Changes to `src/help/shard.txt`:
- **Remove** the line reading `  --dump [path]     Export shard as Obsidian markdown and exit. (default: markdown/)`
  from the `FLAGS (standalone mode)` section
- **Add** `  shard vault [path]                                Export all shards as Obsidian markdown`
  to the `COMMANDS` section (the block starting with `shard daemon`, `shard new`, etc.)
- **Keep** the `op: dump` IPC protocol example — documents the protocol-level op, unchanged
- **Keep** the `shard_dump` MCP tool summary line — MCP tool not renamed

Changes to `src/help/ai/mcp.md`:
- **Keep** the `| shard_dump | ...` MCP tool table entry — not renamed
- `mcp.md` currently has no CLI subcommand section. Add a new `## CLI` section
  immediately before the `## Available Tools` heading containing:
  ```
  ## CLI

  shard vault [path] [--key <hex>]
      Export all shards as Obsidian markdown vault. Default path: vault/
  ```
  No `shard dump` entry to remove — it was never in `mcp.md`.

Add to CLI:
- `case "vault": _run_vault()` in `main()`
- `vault` entry in help overview (`src/help/overview.txt` or inline in `_print_help`)

---

## Export Logic

Implemented in `_run_vault()` in `main.odin`. This is a direct proc, not an IPC
call — it loads blobs and calls `_op_dump` directly, the same way `_run_dump` does
today.

**`exported_names`** is a `map[string]bool` (Odin has no set type). Key = shard name,
value always `true`. Used for O(1) membership checks in the wikilink audit.

**Key resolution** — matches existing `_run_dump` code exactly. `--key` takes priority
over the env var. Resolution order:
1. `--key <hex>` flag (parsed into `key_hex` during arg parsing)
2. If `key_hex == ""`: check `SHARD_KEY` env var (step 3 in the steps below)
3. Per-shard: keychain lookup by shard name
If none resolve, `master` is the zero value and `have_key = false`.

**`blob_load` with no key** — `blob_load(path, zero_master)` succeeds: it loads
catalog and gates (plaintext), and records thought ciphertext blobs. Thoughts will
fail to decrypt later, but blob load itself does not fail. This is the existing
behavior that allows `total_thoughts` to be read before the skip check.

**`status: ok\n` stripping** — `_op_dump` always prepends `status: ok\n` to its
output as an IPC artifact. Strip it with:
```odin
md_content, _ = strings.replace(md_content, "status: ok\n", "", 1)
```
This matches the existing code in `_run_dump` exactly (line 717).

**Steps:**

1. Parse args: optional `[path]` positional, `--key <hex>`, `--help`
2. Declare local data structures:
   ```odin
   exported_names := make(map[string]bool, context.allocator)
   shard_infos    := make([dynamic]Shard_Info, context.allocator)
   tag_map        := make(map[string][dynamic]string, context.allocator)
   exported, skipped, errors := 0, 0, 0
   ```
3. Load keychain from `.shards/keychain` (best-effort; `kc_ok` flag tracks success)
4. If `key_hex == ""` after arg parsing: check `SHARD_KEY` env var
5. `os.make_directory(out_path)` — create output directory
6. Open and iterate `.shards/` directory; skip non-`.shard` files and `daemon.shard`
   (skipping `daemon.shard` by exact name matches current behavior — intentional)
7. For each shard file:
   a. `shard_name := entry.name[:len(entry.name)-6]` (strip `.shard`)
   b. Resolve per-shard key into `resolved_key`: start with `key_hex`, then check
      keychain. Set `master` and `have_key` from `hex_to_key(resolved_key)`.
   c. `blob, blob_ok := blob_load(shard_path, master)` — succeeds even with zero key
   d. If `!blob_ok`: print `  FAIL  <name> (could not load)`, increment errors, continue
   e. **[BEHAVIORAL CHANGE vs `_run_dump`]** Collect `Shard_Info` and tags **before** the
      skip check. In the existing `_run_dump` code these two appends come after the skip
      `continue` — move them before it so every shard appears in `index.md`:
      ```odin
      cat := blob.catalog
      append(&shard_infos, Shard_Info{name = shard_name, purpose = cat.purpose, tags = cat.tags})
      for tag in cat.tags {
          if tag not_in tag_map { tag_map[tag] = make([dynamic]string, context.allocator) }
          append(&tag_map[tag], shard_name)
      }
      ```
      `tags` slice points into blob memory — valid until proc exit.
   f. `total_thoughts := len(blob.processed) + len(blob.unprocessed)`
   g. If `total_thoughts > 0 && !have_key`: print `  SKIP  <name> (%d thoughts, no key)`,
      increment skipped, `continue`
   h. `dump_node := Node{name = shard_name, blob = blob}`
   i. `md_content := _op_dump(&dump_node, Request{}, context.allocator)` (direct proc call)
   j. `md_content, _ = strings.replace(md_content, "status: ok\n", "", 1)`
   k. Do **not** inject any secondary frontmatter block (delete the `graph_meta` block lines)
   l. `file_path := fmt.tprintf("%s/%s.md", out_path, shard_name)`
   m. `write_ok := os.write_entire_file(file_path, transmute([]u8)md_content)`
   n. If `!write_ok`: print `  FAIL  <name> (could not write <path>)`, increment errors, continue
   o. `exported_names[shard_name] = true`; increment `exported`; print `  exported: <path>`
8. Run wikilink audit (see next section)
9. Generate `<dir>/index.md`:
   - Header: `---\ntype: vault-index\ntags: [shard-vault]\n---\n\n# Vault Index\n\nAll shards in the knowledge base:\n\n`
   - For each entry in `shard_infos`: `- [[name]] — purpose\n` (or `- [[name]]\n` if no purpose)
   - Tag index: `\n# Tags\n\n` followed by `## #tag\n\n- [[shard]]\n` per tag (tags sorted alphabetically)
   - This mirrors the existing `_run_dump` index generation exactly, carried over unchanged
10. Write `index.md`, print `  index:   <path>`
11. Print `\nDone: %d exported, %d skipped, %d errors`

**Memory note:** `shard_infos` entries hold `tags` slices that point into blob memory.
Blobs are not freed during `_run_vault` (they use `context.allocator`), so these
pointers are valid until proc exit.

---

## Wikilink Audit Pass

Runs as step 8, after all shard `.md` files are written and before `index.md` is written.
Scans every **exported** shard `.md` file only. `index.md` is **excluded** — it
legitimately links to skipped/failed shards by design.

**Algorithm:**

```odin
broken: [dynamic]Broken_Link        // lives in context.allocator
seen:   map[string]map[string]bool  // seen[file_key][target] — deduplication

for name, _ in exported_names {     // Odin map iteration: key, value
    file_path := fmt.tprintf("%s/%s.md", out_path, name)
    content_bytes, read_ok := os.read_entire_file(file_path, context.allocator)
    if !read_ok do continue
    content := string(content_bytes)
    file_key := fmt.tprintf("%s.md", name)   // tprintf uses context.allocator by default

    pos := 0
    for pos < len(content) {
        open := strings.index(content[pos:], "[[")
        if open == -1 do break
        open += pos
        close_rel := strings.index(content[open+2:], "]]")
        if close_rel == -1 do break
        raw_target := content[open+2 : open+2+close_rel]
        // Strip Obsidian display-text alias: [[target|display]] → target
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
                    file:   strings.clone(file_key),   // context.allocator
                    target: strings.clone(target),     // context.allocator
                })
            }
        }
    }
    delete(content_bytes)   // free the []u8 allocated with context.allocator
}
```

Key implementation notes:
- `os.read_entire_file(path, context.allocator)` allocates with `context.allocator`.
  Free with `delete(content_bytes)` at end of each loop body — **not** `defer`,
  because `defer` in Odin runs at proc exit, not loop-iteration exit. The two-argument
  form is already used in this codebase (e.g. `blob.odin`).
- `Broken_Link` strings are `strings.clone`d to `context.allocator` so they survive
  the loop. Keys in the `seen` map are also cloned to `context.allocator`.
- Deduplication: each `(file_key, target)` pair is appended to `broken` at most once.
- Pipe-aliases (`[[target|display text]]`) handled by truncating `raw_target` at `|`.
- `seen` and `broken` live in `context.allocator` and are freed at proc exit by the
  tracking allocator (no explicit cleanup needed — consistent with rest of `main.odin`).

**Output (only printed if `len(broken) > 0`):**

Print one line per unique file, listing all broken targets for that file:
```
broken links:
  decisions.md → [[missing-shard]], [[other-gone]]
  architecture.md → [[missing-shard]]
```

If no broken links: nothing extra printed (clean vault = clean output).

---

## Terminal Output

```
  exported: vault/architecture.md
  exported: vault/decisions.md
  SKIP  code-ipc (0 thoughts, no key)
  exported: vault/decisions.md
  ...
  index:   vault/index.md

broken links:
  decisions.md → [[missing-shard]]

Done: 14 exported, 1 skipped, 0 errors
```

---

## Data Structures

Both structs are declared **proc-local** inside `_run_vault()`, consistent with how
`Shard_Info` is currently declared inside `_run_dump()`. They are not added to
`types.odin`.

```odin
// Inside _run_vault():
Shard_Info :: struct {
    name:    string,
    purpose: string,
    tags:    []string,
}

Broken_Link :: struct {
    file:   string,   // "<name>.md", cloned to context.allocator
    target: string,   // wikilink target, cloned to context.allocator
}
```

---

## What Does Not Change

- `_op_dump` in `protocol.odin` — per-shard render function, used by both CLI
  and the MCP `shard_dump` tool. Unchanged.
- MCP tool `shard_dump` — agent-facing protocol name. Not renamed here.
- `index.md` format and tag index structure — carried over from `_run_dump` exactly.
  The only behavioral change is that skipped/failed shards now appear in `index.md`
  (previously they did not — see Motivation §3).
- Key resolution logic — carried over from `_run_dump` unchanged.

---

## Files Touched

| File | Change |
|------|--------|
| `src/main.odin` | Add `_run_vault()`, remove `_run_dump()`, remove `dump_path` / `--dump` from `_run_shard()`, add `case "vault"` to CLI switch |
| `src/help/shard.txt` | Remove `--dump` flag line (line 18); add `shard vault` to COMMANDS section; keep `op: dump` protocol example and `shard_dump` MCP entry |
| `src/help/ai/mcp.md` | Add `vault` CLI entry; keep `shard_dump` MCP tool entry unchanged |
| `docs/CONCEPT.txt` | Update M3 remaining items — mark wikilink resolution done |

---

## Testing

- `just test` must pass (no new test file required — this is CLI-only)
- Manual smoke test: `shard vault vault/` on the live `.shards/` directory
- Verify `vault/index.md` has correct wikilinks
- Verify broken link report fires for a shard with a `related` entry pointing to a non-exported shard
- Verify no double-frontmatter in any exported file

---

## Out of Scope

- Renaming the MCP `shard_dump` tool
- Filtered exports (`--query` flag) — that belongs to the `global_dump` op (P1, separate work)
- Rewriting broken wikilinks (Option B, rejected)
