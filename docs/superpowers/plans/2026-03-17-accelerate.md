# Shard Acceleration Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Three independent improvements that make Shard meaningfully better today: (1) fix `shard_query` so "omit shard" truly searches all knowledge, (2) persist the vec_index to disk so there is no cold-start embedding cost on restart, (3) track file/location improvement notes in the `decisions` shard as we go.

**Architecture:**
- Task 1 is a routing fix in `mcp.odin` — swap the no-shard default from `access` (single best shard) to `global_query` (all shards above threshold). One conditional block removed, tool description updated.
- Task 2 adds vec_index persistence to `embed.odin` — serialize `[]Vector_Entry` to `.shards/.vec_index` as JSON on every `index_update_shard` call, load on `index_build` and skip re-embedding entries whose `text_hash` hasn't changed.
- Task 3 is a living process: whenever a file/location problem is spotted during implementation, write a thought to the `decisions` shard before moving on.

**Tech Stack:** Odin, `core:encoding/json`, existing `fnv_hash` cache check already in `index_update_shard`.

> **Import note for Task 2:** `embed.odin` imports `core:os/os2`. File write/rename in the new procs must use `os2` calls (or add `import "core:os"` alongside it — check what `blob.odin` uses for the atomic write pattern and mirror it). Do not mix `os` and `os2` on the same handle.

**Build command:** `just test-build`
**Test method:** Smoke tests are inline per task below. The integration playbook is at `docs/TESTS.md` (AI-executed manual playbook — run Phase 1 build check and Phase 2 CRUD after all tasks complete).

---

## File Map

| File | Change |
|------|--------|
| `src/mcp.odin` | Task 1: remove `access` fallback branch, wire no-shard path to `global_query` directly; update tool description string |
| `src/embed.odin` | Task 2: add `index_persist`, `index_load` procs; call them from `index_build` and `index_update_shard` |
| `src/help/ai/shard.md` | Task 1: update `shard_query` doc to reflect new routing behaviour |
| `.shards/` (runtime) | Task 2: `.shards/.vec_index` file created at runtime — not a source change |

**Refactor notes to track in `decisions` shard (Task 3):**
- `operators.odin` (2229 lines) conflates slot lifecycle, transactions, event hub, fleet, traverse, global_query, digest, access. Slot lifecycle (`_slot_*`) belongs in `daemon.odin`. Fleet/traverse/global_query belong in a new `src/query.odin`. Mark in shard, do split opportunistically.
- `daemon.odin` (489 lines) is described in CONCEPT.txt as owning registry, slots, routing, layered traverse, global_query — but all of that is actually in `operators.odin`. CONCEPT.txt is currently misleading. Update it when the split happens.

---

## Task 1: Fix `shard_query` default routing — omit shard → global_query

**Files:**
- Modify: `src/mcp.odin` (~line 466–560, `_tool_query` proc)
- Modify: `src/help/ai/shard.md` (shard_query tool description section)

The current logic for no-shard + no-depth is:
```
if shard_name == "" && max_depth <= 0 {
    // calls "access" op — routes to ONE best-match shard
}
```
This must become a call to `global_query`, which already searches all shards above a gate threshold and returns results with `shard_name` attribution. The `global_query` path that currently sits at the bottom of the function (reached only when `max_depth > 0` without a shard) is the right behaviour for the default case.

- [ ] **Step 1.1: Read the current `_tool_query` proc in full**

  Open `src/mcp.odin` and read lines 464–565 to confirm the four branch structure before touching anything.

- [ ] **Step 1.2: Remove the `access` fallback branch**

  Delete this block entirely (approx lines 527–543):
  ```odin
  // No shard specified and no depth: use access op to auto-route
  if shard_name == "" && max_depth <= 0 {
      b := strings.builder_make(context.temp_allocator)
      fmt.sbprintf(&b, `{"op":"access","query":"%s"`, json_escape(query))
      if key != "" {
          strings.write_string(&b, `,"key":"`)
          strings.write_string(&b, json_escape(key))
          strings.write_string(&b, `"`)
      }
      if limit > 0 do fmt.sbprintf(&b, `,"thought_count":%d`, limit)
      if budget > 0 do fmt.sbprintf(&b, `,"budget":%d`, budget)
      strings.write_string(&b, "}")

      resp, ok := _daemon_call(strings.to_string(b))
      if !ok do return _mcp_tool_result(id_val, "error: could not connect to daemon", true)
      return _mcp_tool_result(id_val, resp)
  }
  ```

  The `global_query` block that follows (currently labelled `// Cross-shard search via daemon global_query op`) now becomes the natural fallthrough for the no-shard case. Remove the wrapping `{}` block braces so the logic is flat — it is no longer a special case.

- [ ] **Step 1.3: Update the comment above the global_query block**

  Change:
  ```odin
  // Cross-shard search via daemon global_query op
  ```
  To:
  ```odin
  // No shard specified: search all shards via global_query
  ```

- [ ] **Step 1.4: Update the MCP tool description AND schema strings**

  In `src/mcp.odin`, find the `shard_query` tool entry (around line 119–121). Two strings need updating:

  **`description` field** — change:
  > "Find relevant thoughts by natural language search. Omit shard to auto-route to the best matching shard via gate relevance."

  To:
  > "Find relevant thoughts by natural language search. Omit shard to search all shards above gate relevance threshold (global search). Specify shard for direct lookup. Set depth > 0 to follow cross-shard links and [[wikilinks]] (BFS traversal). Returns decrypted thought content grouped by shard."

  **`schema` field** — inside the JSON schema string, find the `shard` property description:
  > `"If omitted, auto-routes to best match."`

  Change to:
  > `"If omitted, searches all shards globally above gate threshold."`

- [ ] **Step 1.5: Update `src/help/ai/shard.md`**

  Find the `shard_query` documentation section. Update the description of the `shard` parameter (currently "If omitted, auto-routes to best match") to say "If omitted, searches all shards globally above gate threshold."

- [ ] **Step 1.6: Build**

  ```bash
  just test-build
  ```
  Expected: exits 0, no errors.

- [ ] **Step 1.7: Smoke test — verify global routing**

  With the daemon running and at least two shards populated:
  ```
  shard_query(query: "architecture decisions")
  ```
  Expected: results come from multiple shards, each result has a `shard_name` field. Previously this would have returned results from a single shard only.

- [ ] **Step 1.8: Commit**

  ```bash
  git add src/mcp.odin src/help/ai/shard.md
  git commit -m "fix: shard_query default now searches all shards via global_query"
  ```

---

## Task 2: Persist vec_index to disk

**Files:**
- Modify: `src/embed.odin` (add `index_persist`, `index_load`; call from `index_build` and `index_update_shard`)

**Context:**
- `Vector_Entry` has: `name: string`, `embedding: []f32`, `text_hash: u64`
- `index_update_shard` already checks `text_hash` to skip re-embedding if the shard's gate text hasn't changed — we extend this to the persisted file
- The `.shards/` directory always exists (created by `shard init`)
- Use the same atomic write pattern as `blob_flush`: write to temp file, rename over target
- Persist path: `.shards/.vec_index` (single JSON file, hidden by convention)

**Persist format** (JSON array, human-readable for debuggability):
```json
[
  {
    "name": "architecture",
    "text_hash": 12345678901234567890,
    "embedding": [0.123, -0.456, ...]
  },
  ...
]
```

- [ ] **Step 2.1: Read `src/embed.odin` lines 1–130 and 132–210**

  Understand the full `embed_text`, `embed_texts`, `index_build`, `index_update_shard` flow before touching anything.

- [ ] **Step 2.2: Add `_vec_index_path` helper**

  Add near the top of `embed.odin` (after imports):
  ```odin
  _vec_index_path :: proc() -> string {
      return ".shards/.vec_index"
  }
  ```

- [ ] **Step 2.3: Add `index_persist` proc**

  Add after `index_update_shard`:
  ```odin
  index_persist :: proc(node: ^Node) {
      if len(node.vec_index.entries) == 0 do return

      b := strings.builder_make(context.temp_allocator)
      strings.write_string(&b, "[\n")
      for entry, i in node.vec_index.entries {
          fmt.sbprintf(&b, `  {"name":"%s","text_hash":%d,"embedding":[`, entry.name, entry.text_hash)
          for v, j in entry.embedding {
              if j > 0 do strings.write_string(&b, ",")
              fmt.sbprintf(&b, "%f", v)
          }
          strings.write_string(&b, "]}")
          if i < len(node.vec_index.entries) - 1 do strings.write_string(&b, ",")
          strings.write_string(&b, "\n")
      }
      strings.write_string(&b, "]\n")

      data := transmute([]u8)strings.to_string(b)
      tmp := fmt.tprintf("%s.tmp", _vec_index_path())
      if err := os.write_entire_file(tmp, data); err != nil {
          logger.warnf("vec_index: persist write failed: %v", err)
          return
      }
      if err := os.rename(tmp, _vec_index_path()); err != nil {
          logger.warnf("vec_index: persist rename failed: %v", err)
          os.remove(tmp)
      }
  }
  ```

- [ ] **Step 2.4: Add `index_load` proc**

  Add after `index_persist`:
  ```odin
  // index_load reads .shards/.vec_index and populates node.vec_index
  // with entries whose text_hash still matches the current registry.
  // Returns the number of entries restored (skipped = hash mismatch or unknown shard).
  index_load :: proc(node: ^Node) -> int {
      data, ok := os.read_entire_file(_vec_index_path(), context.temp_allocator)
      if !ok do return 0

      val, err := json.parse(data, allocator = context.temp_allocator)
      if err != nil do return 0
      defer json.destroy_value(val, context.temp_allocator)

      arr, is_arr := val.(json.Array)
      if !is_arr do return 0

      restored := 0
      for item in arr {
          obj, is_obj := item.(json.Object)
          if !is_obj do continue

          name_val, has_name := obj["name"]
          hash_val, has_hash := obj["text_hash"]
          emb_val,  has_emb  := obj["embedding"]
          if !has_name || !has_hash || !has_emb do continue

          name := name_val.(json.String) or_continue
          hash := u64(hash_val.(json.Float) or_continue)
          emb_arr := emb_val.(json.Array) or_continue

          // Verify this shard still exists in registry with same text_hash
          current_hash: u64 = 0
          found := false
          for entry in node.registry {
              if entry.name == string(name) {
                  text := embed_shard_text(entry)
                  current_hash = fnv_hash(text)
                  found = true
                  break
              }
          }
          if !found || current_hash != hash do continue

          embedding := make([]f32, len(emb_arr))
          for v, i in emb_arr {
              embedding[i] = f32(v.(json.Float) or_else 0.0)
          }

          append(&node.vec_index.entries, Vector_Entry{
              name      = strings.clone(string(name)),
              embedding = embedding,
              text_hash = hash,
          })
          if len(embedding) > 0 do node.vec_index.dims = len(embedding)
          restored += 1
      }

      if restored > 0 do logger.infof("vec_index: loaded %d/%d entries from cache", restored, len(arr))
      return restored
  }
  ```

- [ ] **Step 2.5: Wire `index_load` into `index_build`**

  In `index_build`, after clearing the vec_index and before the embedding loop, attempt to load from cache. Skip embedding any entry whose hash still matches:

  ```odin
  index_build :: proc(node: ^Node) {
      if !embed_ready() do return
      for &entry in node.vec_index.entries {
          delete(entry.name)
          delete(entry.embedding)
      }
      clear(&node.vec_index.entries)

      // Restore from cache first — avoids re-embedding unchanged shards
      _ = index_load(node)

      // Build a set of already-cached names for fast lookup
      cached := make(map[string]bool, allocator = context.temp_allocator)
      for entry in node.vec_index.entries do cached[entry.name] = true

      for entry in node.registry {
          if entry.name in cached do continue   // already loaded from cache
          text := embed_shard_text(entry)
          if text == "" do continue
          // ... rest of existing embedding loop unchanged ...
      }
      // persist after build
      index_persist(node)
  }
  ```

- [ ] **Step 2.6: Wire `index_persist` into `index_update_shard`**

  At the end of `index_update_shard`, after any return path that actually changed an entry, call `index_persist(node)`. The existing `text_hash` check already skips unchanged entries, so this only writes when something actually changed:

  Find the two return sites in `index_update_shard` that modify `ve.embedding` (update existing) and `append` (new entry). Add `index_persist(node)` before each return, or add a single call at the end with a `changed` flag.

  Simplest approach — add a `changed` bool:
  ```odin
  index_update_shard :: proc(node: ^Node, name: string) {
      if !embed_ready() do return
      // ... existing lookup code unchanged ...
      changed := false

      for &ve in node.vec_index.entries {
          if ve.name == name {
              if ve.text_hash == hash do return  // unchanged, nothing to persist
              // ... update embedding ...
              changed = true
              break
          }
      }

      if !changed {
          // new entry path
          // ... existing append code ...
          changed = true
      }

      if changed do index_persist(node)
  }
  ```

- [ ] **Step 2.7: Build**

  ```bash
  just test-build
  ```
  Expected: exits 0.

- [ ] **Step 2.8: Smoke test — verify cache is written and loaded**

  1. Start the daemon fresh: `bin/shard.exe daemon`
  2. Connect via MCP — daemon calls `index_build` → `.shards/.vec_index` should appear
  3. Check it exists: `ls .shards/.vec_index`
  4. Stop and restart the daemon
  5. Observe log output: should say `vec_index: loaded N/N entries from cache` — NOT `embed: indexed N shards`
  6. If no LLM configured, `.vec_index` file won't be created (embed_ready() returns false) — that is correct behaviour, not a bug

- [ ] **Step 2.9: Commit**

  ```bash
  git add src/embed.odin
  git commit -m "feat: persist vec_index to .shards/.vec_index — eliminates cold-start re-embedding"
  ```

---

## Task 3: Track file/location improvement notes in `decisions` shard

**This is a process task, not a code task.** Whenever during implementation above (or any future session) a structural problem is spotted, write it to the `decisions` shard immediately — before moving on. This makes refactor candidates visible and prioritisable.

- [ ] **Step 3.1: Write the `operators.odin` split note**

  Use `shard_write` to the `decisions` shard:
  ```
  description: "Refactor candidate — operators.odin split into slot.odin + query.odin"
  content: |
    operators.odin is 2229 lines and owns too many concerns:
    - Slot lifecycle (_slot_get_or_create, _slot_load, _slot_set_key, _slot_build_index,
      _slot_dispatch, _slot_drain_write_queue, _slot_is_locked, _slot_clear_lock)
      → belongs in daemon.odin (it's daemon internal state management)
    - Fleet dispatch, traverse, global_query, digest, access
      → belongs in a new src/query.odin
    - Transaction logic (_op_transaction, _op_commit, _op_rollback)
      → could stay in operators.odin or move to src/transaction.odin

    Impact: currently it is hard to find fleet/traverse logic while scrolling past
    transaction TTL code. Every addition lands in this file by default.

    Do this split when next making a significant change to any of these areas.
    Do NOT do it as a standalone refactor — do it as part of work that touches the file.
  agent: opencode
  ```

- [ ] **Step 3.2: Write the `daemon.odin` / CONCEPT.txt discrepancy note**

  ```
  description: "CONCEPT.txt describes daemon.odin incorrectly — update when operators split happens"
  content: |
    CONCEPT.txt (line 422) says:
      daemon.odin: Registry, in-process slots, routing, layered traverse (L0/L1/L2),
                   global_query, transactions, digest, consumption tracking

    Reality: daemon.odin is 489 lines and handles only daemon startup, slot eviction
    timing, and the main registry scan. Everything else listed is in operators.odin.

    Fix: update CONCEPT.txt and the file map in AGENTS.md when the operators.odin
    split is executed. The line counts will also change.
  agent: opencode
  ```

- [ ] **Step 3.3: Write the `shard_query` routing complexity note** (now that Task 1 simplified it, record what still exists)

  ```
  description: "shard_query still has 4 routing branches — consider consolidating further"
  content: |
    After Task 1 fix, shard_query has four code paths:
    1. layer > 0 + no shard → traverse op
    2. shard specified + no depth → direct per-shard query op
    3. no shard (default) → global_query op (fixed in Task 1)
    4. shard + depth > 0 → global_query (depth is passed but unused — silently ignores shard name)

    The layer/depth params are confusing to agents. Consider simplifying:
    - layer is a traverse-specific concept; expose it on a separate shard_traverse tool
    - depth > 0 with a shard name currently falls into the global_query path which
      ignores the shard name — that is silently wrong

    Not urgent. Document the current routing in shard_query tool description comments.
  agent: opencode
  ```

- [ ] **Step 3.4: Confirm all three thoughts written to `decisions` shard**

  Run `shard_discover` and verify `decisions` shard has increased thought count.

---

## After All Tasks

- [ ] Run full TESTS.md Phase 1–3 playbook to confirm no regressions
- [ ] Update `decisions` shard with any new issues found during testing
- [ ] Update `milestones` shard: mark M3 as closer (global_query now the default path)
