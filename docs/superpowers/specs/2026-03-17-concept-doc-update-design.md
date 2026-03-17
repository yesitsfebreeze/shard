# Design: CONCEPT.txt Update — Persistent Topic Cache + Accurate File Map

**Date:** 2026-03-17  
**Status:** Approved  
**Scope:** Two distinct workstreams — (A) doc-only fixes, (B) implement missing cache features then document them

---

## Problem

`docs/CONCEPT.txt` has drifted from reality in three ways:

1. **File map is wrong.** Line 422 attributes registry, slots, routing, layered traverse, global_query, transactions, digest, staleness, feedback, and auto-compaction monitoring to `daemon.odin`. In reality `daemon.odin` is 489 lines and owns only: daemon startup/routing dispatch, slot eviction scheduling, registry scan/refresh on startup, and LLM helpers (`_truncate_to_budget`, `_ai_compact_content`, `_llm_post`). Everything else lives in `operators.odin` (1,881 lines) and the partial split (`ops_read.odin`, 355 lines).

2. **Topic cache is not documented.** The system has a fully implemented short-term memory layer — the topic cache — with three MCP tools (`shard_cache_write`, `shard_cache_read`, `shard_cache_list`) and an `_op_cache` handler. It is not mentioned anywhere in `CONCEPT.txt`. It currently:
   - Stores entries in-memory only (lost on daemon restart)
   - Syncs the latest entry to `~/.claude/context-mode/sessions/` (Claude-specific, best-effort)
   - Has no auto-compaction
   - Has no persistence path in `.shards/`
   These gaps mean the cache cannot serve as the "load context for new sessions" workflow described in the user's vision.

3. **Milestone 3 progress is stale.** `shard_query` now defaults to `global_query` (all shards above threshold), and `vec_index` is persisted to `.shards/.vec_index`. These two major M3 items are done but not reflected.

`AGENTS.md` has the same wrong file map (line 169, `~2420` for daemon.odin).

---

## Goal

- Topic cache becomes a first-class persistent feature: survives restarts, auto-compacts, loads into new sessions
- `CONCEPT.txt` accurately describes the implemented system after these changes
- File map reflects the operators split in its current in-progress state
- Milestone 3 reflects actual completion status
- `AGENTS.md` file map updated to match

---

## Two Workstreams

This spec covers two sequential workstreams. Workstream A touches only docs. Workstream B requires source changes first, then docs.

---

## Workstream A: Documentation-Only Fixes

No source changes. Pure doc updates to match current reality.

### A1. Fix the file map in `CONCEPT.txt` and `AGENTS.md`

Replace the current `daemon.odin` description with the accurate one. Add `ops_read.odin`. Note operators split is in progress.

**`CONCEPT.txt` implementation section — replace line ~422:**

```
  src/daemon.odin        ~489   daemon_dispatch router; slot eviction scheduling;
                                registry scan/refresh on startup; LLM helpers
                                (_truncate_to_budget, _ai_compact_content, _llm_post)
  src/operators.odin     ~1881  Operator hub: Operators struct, Ops global, shared
                                constants; all ops not yet split out: write routing,
                                query/traverse/global_query, fleet, events/transactions,
                                consumption tracking, topic cache (_op_cache)
  src/ops_read.odin      ~355   Read ops: _op_access, _op_digest, _op_requires_key;
                                slot loading (_slot_get_or_create, _slot_load,
                                _slot_set_key, _slot_build_index, _slot_verify_key);
                                _find_registry_entry
                                (operators split in progress — see
                                docs/superpowers/specs/2026-03-17-operators-split-design.md)
```

**`AGENTS.md` file map — replace the `daemon.odin` row:**

```
| `src/daemon.odin` | ~489 | daemon_dispatch router, slot eviction scheduling, registry scan/refresh, LLM helpers (_truncate_to_budget, _ai_compact_content, _llm_post) |
| `src/operators.odin` | ~1881 | Operator hub + all ops not yet split: write routing, query/traverse/global_query, fleet, events/transactions, consumption, topic cache |
| `src/ops_read.odin` | ~355 | Read ops: _op_access, _op_digest, slot loading, _find_registry_entry (operators split in progress) |
```

### A2. Update Milestone 3 status in `CONCEPT.txt`

Find the MILESTONE 3 paragraph. Replace the "New:" sentence and "Remaining:" sentence:

**Replace:**
> New: global_query daemon op — searches all shards above a gate threshold, returns unified results with shard attribution, composite scoring, budget truncation. MCP shard_query uses global_query for cross-shard cases.
> Remaining: filtered cross-shard export, vault-level index, wikilink resolution.

**With:**
> Done: global_query is the default for shard_query (omit shard → searches all shards above threshold). vec_index persisted to .shards/.vec_index — no cold-start re-embedding on daemon restart.
> Remaining: filtered cross-shard export, vault-level Obsidian index, wikilink resolution.

### A3. Document the topic cache AS IT CURRENTLY EXISTS

Add a new section after TWO-BLOCK DESIGN:

```
TOPIC CACHE — SHORT-TERM MEMORY
  The cache is the fast, ephemeral layer for in-session context: recent questions,
  useful discoveries, working notes. Unlike shards (long-term, encrypted, permanent),
  the cache is transient and agent-agnostic within a session.

  Current implementation:
    - In-memory only: cache_slots map[string]^Cache_Slot in the daemon node
    - Named by topic (e.g. "auth-refactor", "bug-hunt")
    - Shared: any agent reading the same topic sees all entries
    - FIFO-evicted when max_bytes is set on first write
    - On each write: syncs the latest entry to
      ~/.claude/context-mode/sessions/shard-cache-<topic>-events.md (if that
      directory exists) — best-effort, Claude-specific, not guaranteed
    - Lost on daemon restart

  MCP tools:
    shard_cache_write  Append an entry (topic, content, agent, max_bytes)
    shard_cache_read   Read all entries as a markdown context document
    shard_cache_list   List all active topics with entry counts and sizes
```

---

## Workstream B: Implement Persistence + Auto-Compaction, Then Document

These are **source changes required before the docs can describe them truthfully.**

### B1. Persist cache to ~/.shards/sessions/

**What to build:**

1. On every `cache: write`, after appending the entry, serialize the full `Cache_Slot` to `~/.shards/sessions/<topic>.md`. Use an atomic write (temp file → rename). Create the `sessions/` directory if it doesn't exist.

2. On daemon startup (in `_daemon_init` or equivalent), scan `~/.shards/sessions/*.md`, parse each file, and populate `node.cache_slots`. This gives new sessions immediate access to prior context.

**Persist format** — Markdown with YAML frontmatter:
```markdown
---
topic: auth-refactor
entry_count: 3
total_bytes: 1240
max_bytes: 8192
compacted_at: ""
---

## [2026-03-17T10:00:00Z] opencode

Entry content here...

## [2026-03-17T10:05:00Z] opencode

Another entry...
```

**File path:** `~/.shards/sessions/<topic>.md`  
**Directory creation:** daemon creates `~/.shards/sessions/` on first write if absent.  
**Home resolution:** same as current `_cache_sync_context_mode` (USERPROFILE on Windows, HOME on POSIX).  
**Replaces:** the existing `_cache_sync_context_mode` proc (which syncs to `~/.claude/context-mode/sessions/`). Remove the old Claude-specific sync entirely.  
**Clear action:** the existing `"clear"` action in `_op_cache` must also delete `~/.shards/sessions/<topic>.md` when clearing a slot.  
**Parser:** write a dedicated lightweight frontmatter parser for cache files — the existing `markdown.odin` parser is coupled to `Thought`/catalog types and is not reusable here.  
**Allocator discipline:** all strings loaded from disk in `_cache_load_all` must use the heap allocator (not temp), since they outlive the function. `compacted_at` field must also be read and populated during load.

**Files to change:**
- `src/operators.odin` — replace `_cache_sync_context_mode` with `_cache_persist_slot`; add `_cache_load_all` called from daemon startup
- `src/daemon.odin` — call `_cache_load_all(node)` during daemon initialization
- `src/config.odin` — add `CACHE_COMPACT_THRESHOLD` config field (default 10, 0 = disabled)

### B2. Auto-compaction via LLM

**What to build:**

After appending an entry, check if `len(slot.entries) >= cfg.cache_compact_threshold` (and threshold > 0 and LLM is configured). If so:

1. Concatenate all current entries into a single string (with agent/timestamp headers)
2. Call `_ai_compact_content(joined_entries, max_len)` where `max_len = slot.max_bytes > 0 ? slot.max_bytes : 4096` (reuse existing LLM helper in `daemon.odin`)
3. If the LLM returns a non-empty result:
   - Free all existing entries
   - Replace with a single entry: `agent = "compacted"`, `content = summary`, `timestamp = now`
   - Set `slot.compacted_at = now` (add field to `Cache_Slot`)
   - Persist the compacted slot to disk
4. If LLM returns empty (no LLM configured, or call failed): skip silently. Raw entries continue to accumulate.

**Config:**
- Key: `CACHE_COMPACT_THRESHOLD`
- Default: `10` (compact after 10 entries)
- `0` = disabled

**Files to change:**
- `src/operators.odin` — add compaction check in `_op_cache` write path
- `src/config.odin` — add `cache_compact_threshold int` field and `CACHE_COMPACT_THRESHOLD` parse case
- `src/types.odin` — add `compacted_at string` to `Cache_Slot`

### B3. Update CONCEPT.txt topic cache section to reflect B1 + B2

After B1 and B2 are implemented and tests pass, update the TOPIC CACHE section written in A3 to reflect:

- Storage: `~/.shards/sessions/<topic>.md`, created on first write, loaded on daemon startup
- Auto-compaction: triggered at `CACHE_COMPACT_THRESHOLD` entries, LLM summarizes all entries into one
- No-LLM fallback: FIFO eviction only, no summarization
- New agent workflow: `shard_cache_list` → select topics → `shard_cache_read` → loaded context ready

### B4. Update daemon entity in CONCEPT.txt

Add to the DAEMON key entities section:

```
    - topic cache    — named Cache_Slots, one per topic. Persisted to
                       ~/.shards/sessions/<topic>.md. Loaded on startup.
                       Auto-compacted by LLM at CACHE_COMPACT_THRESHOLD entries.
                       Shared across agents; FIFO-evicted when max_bytes is set.
```

---

## Implementation Order

```
A1 → A2 → A3   (doc-only, safe to do immediately, commit separately)
B1 → B2 → B3 → B4  (source changes, then doc update, commit together)
```

---

## Files Changed

| File | Workstream | Change |
|------|-----------|--------|
| `docs/CONCEPT.txt` | A1, A2, A3 | File map fix, M3 status, topic cache section (current behavior) |
| `AGENTS.md` | A1 | File map: fix daemon.odin row, add ops_read.odin row |
| `src/operators.odin` | B1, B2 | Replace `_cache_sync_context_mode` with persist; add compaction trigger; add load-all |
| `src/daemon.odin` | B1 | Call `_cache_load_all` on startup |
| `src/config.odin` | B2 | Add `cache_compact_threshold` field |
| `src/types.odin` | B2 | Add `compacted_at` to `Cache_Slot` |
| `docs/CONCEPT.txt` | B3, B4 | Update topic cache section and daemon entity to reflect new behavior |

---

## Success Criteria

**Workstream A:**
- `docs/CONCEPT.txt` file map accurately describes `daemon.odin` (489 lines, actual role) and `operators.odin` (1881 lines, actual role)
- `docs/CONCEPT.txt` topic cache section describes cache as it actually exists today
- `AGENTS.md` file map matches `docs/CONCEPT.txt`
- No source file modified

**Workstream B:**
- Cache entries survive daemon restart (verified: stop daemon, restart, `shard_cache_read` returns prior entries)
- Auto-compaction fires at threshold when LLM is configured (verified: write 10+ entries, check slot has one compacted entry)
- No-LLM path: entries accumulate normally, no crash
- `just test-build` passes
- `just test` passes
- `docs/CONCEPT.txt` topic cache section matches implemented behavior
