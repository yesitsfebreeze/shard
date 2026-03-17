# Persistent Topic Cache + Auto-Compaction (Workstream B) Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the topic cache persistent across daemon restarts (writes to `~/.shards/sessions/<topic>.md`, loads on startup) and add LLM-driven auto-compaction at a configurable entry threshold. Then update `docs/CONCEPT.txt` to describe the new behavior.

**Architecture:** Three source changes — (1) replace `_cache_sync_context_mode` in `ops_cache.odin` with `_cache_persist_slot` that writes to `~/.shards/sessions/`; add `_cache_load_all` called from `node_init` in `node.odin`; (2) add `CACHE_COMPACT_THRESHOLD` to `config.odin`; (3) add compaction trigger in the write path of `ops_cache.odin`. After all source changes pass tests, update docs. Each source task commits independently.

**Tech Stack:** Odin, `core:os`, `core:strings`, `core:fmt`, `core:time`, `core:strconv`. Reuses existing `_ai_compact_content` (daemon.odin) and `_format_time` (ops_cache.odin). Build: `just test-build`. Tests: `just test`.

**Spec:** `docs/superpowers/specs/2026-03-17-concept-doc-update-design.md` — Workstream B sections.

**Prerequisite:** Workstream A plan (`2026-03-17-concept-doc-update-A.md`) should be complete before this plan is executed, but the source changes here are independent of the doc changes there.

---

## File Map

| File | Change |
|------|--------|
| `src/ops_cache.odin` | Replace `_cache_sync_context_mode` with `_cache_persist_slot`; add `_cache_sessions_dir`, `_cache_load_all`, `_cache_parse_session_file`, `_cache_maybe_compact`; add compaction trigger and file-delete in clear action; add `strconv` import |
| `src/node.odin` | Add `_cache_load_all(&node)` call in daemon startup block |
| `src/config.odin` | Add `cache_compact_threshold int` field, default 10, parse `CACHE_COMPACT_THRESHOLD` key |
| `src/types.odin` | Add `compacted_at string` field to `Cache_Slot` |
| `docs/CONCEPT.txt` | Update TOPIC CACHE section and DAEMON entity to describe new persistent behavior |

---

## Task 1: Add `cache_compact_threshold` to config

**Files:**
- Modify: `src/config.odin`

- [ ] **Step 1.1: Read the relevant config sections**

  Open `src/config.odin`. Read:
  - The `Shard_Config` struct (lines ~19–52): confirm `compact_threshold` exists near the bottom
  - The `DEFAULT_CONFIG` literal (lines ~55–88): confirm `compact_threshold = 20` entry
  - The config switch cases (lines ~120–199): find the `COMPACT_THRESHOLD` case

- [ ] **Step 1.2: Add `cache_compact_threshold` to `Shard_Config` struct**

  Find the line:
  ```odin
  compact_threshold:          int, // auto-trigger compaction when unprocessed >= this (0 = disabled)
  ```
  After it, add:
  ```odin
  cache_compact_threshold:    int, // auto-compact topic cache when entries >= this (0 = disabled)
  ```

- [ ] **Step 1.3: Add default value to `DEFAULT_CONFIG`**

  Find:
  ```odin
  compact_threshold          = 20, // auto-trigger at 20 unprocessed thoughts (0 = disabled)
  ```
  After it, add:
  ```odin
  cache_compact_threshold    = 10, // auto-compact cache topics at 10 entries (0 = disabled)
  ```

- [ ] **Step 1.4: Add parse case in `config_load`**

  Find the `case "COMPACT_THRESHOLD":` block. After it, add:
  ```odin
  case "CACHE_COMPACT_THRESHOLD":
      _global_config.cache_compact_threshold = _parse_int(val, 10)
  ```

- [ ] **Step 1.5: Add comment to default config template**

  Find the `// # --- Auto-compaction ---` comment block (near bottom of file). After `COMPACT_MODE`, add:
  ```
  // # CACHE_COMPACT_THRESHOLD 10  (0 = disabled, LLM-summarize topic cache at N entries)
  ```

- [ ] **Step 1.6: Build**

  ```bash
  just test-build
  ```
  Expected: exits 0.

- [ ] **Step 1.7: Commit**

  ```bash
  git add src/config.odin
  git commit -m "feat: add CACHE_COMPACT_THRESHOLD config (default 10, 0=disabled)"
  ```

---

## Task 2: Add `compacted_at` to `Cache_Slot`

**Files:**
- Modify: `src/types.odin`

- [ ] **Step 2.1: Read `Cache_Slot` struct**

  Open `src/types.odin`. Find `Cache_Slot` (lines ~419–423):
  ```odin
  Cache_Slot :: struct {
      topic:       string,
      max_bytes:   int, // 0 = unlimited
      total_bytes: int,
      entries:     [dynamic]Cache_Entry,
  }
  ```

- [ ] **Step 2.2: Add `compacted_at` field**

  Replace with:
  ```odin
  Cache_Slot :: struct {
      topic:        string,
      max_bytes:    int, // 0 = unlimited
      total_bytes:  int,
      entries:      [dynamic]Cache_Entry,
      compacted_at: string, // RFC3339 timestamp of last LLM compaction, "" if never
  }
  ```

- [ ] **Step 2.3: Build**

  ```bash
  just test-build
  ```
  Expected: exits 0.

- [ ] **Step 2.4: Commit**

  ```bash
  git add src/types.odin
  git commit -m "feat: add compacted_at field to Cache_Slot"
  ```

---

## Task 3: Replace `_cache_sync_context_mode` with persist + load in `ops_cache.odin`

This is the core persistence task.

**Files:**
- Modify: `src/ops_cache.odin` (228 lines — read it in full before making changes)

- [ ] **Step 3.1: Read `ops_cache.odin` in full**

  Open `src/ops_cache.odin` and read all 228 lines. Confirm:
  - `_op_cache` is at lines 9–150
  - `_cache_sync_context_mode` is at lines 155–188 (call at line 55 in write path)
  - `_registry_matches` is at lines 190–221
  - `_format_time` is at lines 223–227
  - Current imports: `core:fmt`, `core:os`, `core:strings`, `core:time` (no `strconv`)

- [ ] **Step 3.2: Add `core:strconv` import**

  Add to the import block at the top of `ops_cache.odin`:
  ```odin
  import "core:strconv"
  ```
  The import block should now read:
  ```odin
  import "core:fmt"
  import "core:os"
  import "core:strconv"
  import "core:strings"
  import "core:time"
  ```

- [ ] **Step 3.3: Add `_cache_sessions_dir` helper**

  Add this proc at the **top of the file, after the import block and before `_op_cache`**:

  ```odin
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
  ```

  Note: uses `USERPROFILE` only on Windows (not the HOMEDRIVE fallback in the old code — HOMEDRIVE is a drive letter, not a path).

- [ ] **Step 3.4: Add `_cache_persist_slot` proc**

  Add after `_cache_sessions_dir`:

  ```odin
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
      if rename_err := os.rename(tmp_path, file_path); rename_err != nil {
          logger.warnf("cache: persist rename failed for topic '%s': %v", slot.topic, rename_err)
          os.remove(tmp_path)
      }
  }
  ```

  Note: `ops_cache.odin` does not currently import `logger`. Check whether `logger` is imported via `import logger "logger"` in this file. If not, add it: `import logger "logger"`. Look at `src/daemon.odin` to confirm the import alias used project-wide is `logger "logger"`.

- [ ] **Step 3.5: Add `_cache_load_all` proc**

  Add after `_cache_persist_slot`:

  ```odin
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
  ```

- [ ] **Step 3.6: Add `_cache_parse_session_file` proc**

  Add after `_cache_load_all`. This is a dedicated lightweight parser — it does NOT use `markdown.odin` (which is coupled to `Thought`/catalog types). All strings must use the heap allocator (not temp) because the returned slot outlives this function.

  ```odin
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
  ```

- [ ] **Step 3.7: Replace `_cache_sync_context_mode` call in write path**

  In `_op_cache`, write case (line ~55), replace:
  ```odin
  _cache_sync_context_mode(slot)
  ```
  With:
  ```odin
  _cache_persist_slot(slot)
  ```

- [ ] **Step 3.8: Add file deletion in the `clear` action**

  In `_op_cache`, `"clear"` case, find the line `delete_key(&node.cache_slots, req.topic)` (line ~144). Insert these lines **immediately before** it:
  ```odin
  sessions_dir := _cache_sessions_dir()
  if sessions_dir != "" {
      file_path := fmt.tprintf("%s/%s.md", sessions_dir, req.topic)
      os.remove(file_path)
  }
  ```

- [ ] **Step 3.9: Delete `_cache_sync_context_mode`**

  Remove the entire `_cache_sync_context_mode` proc (lines 152–188 in the original file). It is fully replaced by `_cache_persist_slot`.

- [ ] **Step 3.10: Check logger import**

  Check whether `ops_cache.odin` already imports `logger`. The existing file does not — add it:
  ```odin
  import logger "logger"
  ```
  Add it to the import block (alphabetical order with the others).

- [ ] **Step 3.11: Build**

  ```bash
  just test-build
  ```
  Expected: exits 0.

- [ ] **Step 3.12: Run tests**

  ```bash
  just test
  ```
  Expected: all tests pass.

- [ ] **Step 3.13: Commit**

  ```bash
  git add src/ops_cache.odin
  git commit -m "feat: persist topic cache to ~/.shards/sessions/ — replace Claude-specific sync"
  ```

---

## Task 4: Call `_cache_load_all` on daemon startup

**Files:**
- Modify: `src/node.odin`

- [ ] **Step 4.1: Read the daemon startup block**

  Open `src/node.odin` and read lines ~75–83:
  ```odin
  if is_daemon {
      config_load()
      daemon_load_registry(&node)
      daemon_scan_shards(&node)
      index_build(&node)
      daemon_load_events(&node)
      daemon_load_consumption(&node)
  }
  ```

- [ ] **Step 4.2: Add `_cache_load_all` call**

  Add `_cache_load_all(&node)` as the last line in that block:
  ```odin
  if is_daemon {
      config_load()
      daemon_load_registry(&node)
      daemon_scan_shards(&node)
      index_build(&node)
      daemon_load_events(&node)
      daemon_load_consumption(&node)
      _cache_load_all(&node)
  }
  ```

- [ ] **Step 4.3: Build**

  ```bash
  just test-build
  ```
  Expected: exits 0.

- [ ] **Step 4.4: Run tests**

  ```bash
  just test
  ```
  Expected: all tests pass.

- [ ] **Step 4.5: Smoke test — verify persistence round-trip**

  With the daemon running:
  1. `shard_cache_write` — topic `test-persist`, content `hello from session 1`
  2. Check `~/.shards/sessions/test-persist.md` exists and contains the entry
  3. Stop the daemon (Windows: `taskkill /F /IM shard.exe`, POSIX: `pkill shard`)
  4. Start the daemon: `bin/shard.exe daemon &`
  5. `shard_cache_list` — `test-persist` should appear
  6. `shard_cache_read` topic `test-persist` — entry should be present
  7. `shard_cache_write` action `clear` on `test-persist` — `~/.shards/sessions/test-persist.md` should be deleted

- [ ] **Step 4.6: Commit**

  ```bash
  git add src/node.odin
  git commit -m "feat: load topic cache from ~/.shards/sessions/ on daemon startup"
  ```

---

## Task 5: Auto-compaction via LLM on write

**Files:**
- Modify: `src/ops_cache.odin`

- [ ] **Step 5.1: Remove `@(private)` from `_ai_compact_content` in `daemon.odin`**

  Open `src/daemon.odin` lines 46–48. The proc is currently declared:
  ```odin
  @(private)
  _ai_compact_content :: proc(content: string, max_len: int) -> string {
  ```
  The `@(private)` annotation makes it file-scoped in Odin — not callable from `ops_cache.odin` even though they share `package shard`. Remove the `@(private)` line:
  ```odin
  _ai_compact_content :: proc(content: string, max_len: int) -> string {
  ```
  Build to confirm:
  ```bash
  just test-build
  ```
  Expected: exits 0.

- [ ] **Step 5.2: Add `_cache_maybe_compact` proc**

  Add this proc in `ops_cache.odin`, just before `_op_cache`:

  ```odin
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
  ```

- [ ] **Step 5.3: Call `_cache_maybe_compact` in the write path — with use-after-free fix**

  In `_op_cache` write case, the current sequence ends with:
  ```odin
  _cache_persist_slot(slot)

  return _marshal(Response{status = "ok", id = entry.id}, allocator)
  ```

  The problem: `_cache_maybe_compact` frees `entry.id` if compaction fires, but `entry.id` is used in the return statement after. Fix by capturing the ID before compaction:

  Replace those two lines with:
  ```odin
  _cache_persist_slot(slot)

  // Capture id before potential compaction (compaction frees slot entries)
  entry_id := strings.clone(entry.id, allocator)
  _cache_maybe_compact(node, slot)

  return _marshal(Response{status = "ok", id = entry_id}, allocator)
  ```

- [ ] **Step 5.4: Build**

  ```bash
  just test-build
  ```
  Expected: exits 0.

- [ ] **Step 5.5: Run tests**

  ```bash
  just test
  ```
  Expected: all tests pass.

- [ ] **Step 5.6: Smoke test — verify compaction (two paths)**

  **With LLM configured:**
  1. Write 10 entries to topic `test-compact` using `shard_cache_write`
  2. On the 10th write, daemon auto-compacts
  3. `shard_cache_read test-compact` — 1 entry, agent is `compacted`
  4. `~/.shards/sessions/test-compact.md` — `compacted_at` is non-empty

  **Without LLM configured (LLM_URL not set):**
  1. Write 15 entries to topic `test-no-llm`
  2. All 15 entries present — no crash, no data loss
  3. `shard_cache_read test-no-llm` — all 15 entries visible

- [ ] **Step 5.7: Commit**

  ```bash
  git add src/ops_cache.odin
  git commit -m "feat: auto-compact topic cache via LLM at CACHE_COMPACT_THRESHOLD entries"
  ```

---

## Task 6: Update `CONCEPT.txt` to describe the new behavior

**Prerequisite:** Tasks 1–5 complete and `just test` passes.

**Files:**
- Modify: `docs/CONCEPT.txt`

- [ ] **Step 6.1: Read the TOPIC CACHE section added in Workstream A**

  Confirm it exists and currently says "In-memory only during daemon lifetime (not persisted across restarts yet — see MILESTONE 4 below)".

- [ ] **Step 6.2: Replace the TOPIC CACHE section body**

  Update the "A topic cache is:" bullet list and everything after it through "PLANNED IMPROVEMENTS" to:

  ```
  A topic cache is:
    - Named by topic (e.g. "auth-refactor", "bug-hunt-2026-03-17")
    - Shared: any agent reading the same topic sees all entries from all agents
    - Persisted to ~/.shards/sessions/<topic>.md on every write (atomic)
    - Loaded back into the daemon on startup — new sessions see prior context
    - FIFO-evicted when max_bytes is set on first write to the topic
    - Auto-compacted by LLM when entry count reaches CACHE_COMPACT_THRESHOLD
      (default 10, 0 = disabled). Raw entries replaced with a single summary.
      Falls back gracefully if no LLM is configured.

  AUTO-COMPACTION
    When entry count reaches CACHE_COMPACT_THRESHOLD, the daemon calls the LLM
    (same config as shard traversal: LLM_URL, LLM_MODEL) to summarize all entries.
    The summary replaces all entries as a single "compacted" entry attributed to
    "compacted" agent. Subsequent writes append on top of the summary. If no LLM
    is configured, raw entries accumulate (FIFO eviction still applies when
    max_bytes is set). compacted_at in the persisted file records when last run.

  NEW AGENT WORKFLOW
    1. shard_cache_list — discover available topics from prior sessions
    2. shard_cache_read <topic> — load the compacted context for relevant topics
    3. Work — write entries as decisions or discoveries accumulate
    4. Context auto-compacts and persists for the next session automatically

  STORAGE
    Path:    ~/.shards/sessions/<topic>.md
    Format:  Markdown with YAML frontmatter (topic, entry_count, total_bytes,
             max_bytes, compacted_at) followed by ## [timestamp] agent / content entries
    Created: sessions/ directory created by daemon on first write if absent
    Atomic:  temp file → rename, same pattern as .shard file writes
  ```

- [ ] **Step 6.3: Update the DAEMON entity `topic cache` entry**

  Find `- topic cache` in the DAEMON key entity section. Replace with:
  ```
      - topic cache    — named Cache_Slots, one per topic. Persisted to
                         ~/.shards/sessions/<topic>.md on every write. Loaded on
                         daemon startup. Auto-compacted by LLM at
                         CACHE_COMPACT_THRESHOLD entries (default 10). Shared
                         across all agents. FIFO-evicted when max_bytes is set.
  ```

- [ ] **Step 6.4: Update the one-sentence definition**

  Find the definition updated in Workstream A that says "auto-compacting in a future milestone". Remove the "future milestone" qualifier:
  ```
  Shard is an encrypted knowledge system with two memory layers: long-term
  thought stores (encrypted, persistent, per-topic shards) and short-term topic
  caches (named, persistent, shared across agents, auto-compacted by LLM at a
  configurable threshold).
  ```

- [ ] **Step 6.5: Build one final time**

  ```bash
  just test-build
  ```
  Expected: exits 0.

- [ ] **Step 6.6: Commit**

  ```bash
  git add docs/CONCEPT.txt
  git commit -m "docs: update TOPIC CACHE section — persistence and auto-compaction implemented"
  ```

---

## After All Tasks

- [ ] Run full test suite: `just test`
- [ ] Verify `~/.shards/sessions/` is created on first cache write if absent
- [ ] Verify `shard_cache_list` shows persisted topics after daemon restart
- [ ] Update `milestones` shard: note topic cache persistence and auto-compaction complete
