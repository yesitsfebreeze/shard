# Unified Search Index Design

**Date:** 2026-03-18
**Status:** Approved — final
**Replaces:** `vec_index` (shard-level vector routing) + per-slot `Search_Entry[]` (thought-level keyword scan)

---

## Problem

Search is split across two disconnected systems that don't share state:

1. **`vec_index`** (`Vector_Index` on `Node`) — shard-level embeddings for routing queries to the right shards. Persisted to `.shards/.vec_index`. Built and maintained by `embed.odin`.

2. **`Search_Entry[]`** (`[dynamic]Search_Entry` on both `Node` and `Shard_Slot`) — per-shard in-memory arrays of thought descriptions + optional embeddings. Built fresh on every slot load. Never persisted. Maintained by `search.odin` and scattered call sites in `protocol.odin`.

The gap between them causes the core inefficiency: `_op_global_query` uses `vec_index` to pick candidate shards, then must speculatively load each candidate slot, decrypt all thoughts, and build a fresh `Search_Entry[]` just to find out which thoughts match. With 20 shards, that's potentially 20 slot loads and hundreds of decryptions before a single result is returned.

---

## Goal

Replace both systems with a single unified two-level persistent index. One file, one in-memory struct, one set of procs. No legacy remnants.

---

## What Gets Deleted

| Item | Location |
|---|---|
| `Vector_Index` struct | `types.odin` |
| `Vector_Entry` struct | `types.odin` |
| `Vector_Result` struct | `types.odin` |
| `Search_Entry` struct | `types.odin` |
| `Search_Result` struct | `types.odin` |
| `Node.index [dynamic]Search_Entry` | `types.odin` |
| `Node.vec_index Vector_Index` | `types.odin` |
| `Shard_Slot.index [dynamic]Search_Entry` | `types.odin` |
| `search.odin` entire file | `src/search.odin` |
| `embed.odin` index procs: `index_build`, `index_update_shard`, `index_persist`, `index_load`, `index_query`, `_vec_index_path` | `src/embed.odin` |
| `.shards/.vec_index` file | disk (runtime) |

No backward compatibility. No migration. Old `.vec_index` is simply ignored on first start and overwritten by the new `.shards/.index`.

---

## New Data Structures

```odin
// One thought's entry in the index
Indexed_Thought :: struct {
    id:          Thought_ID,
    description: string,    // heap-allocated — cloned on load/write, freed on remove
    embedding:   []f32,     // nil if LLM not configured
    text_hash:   u64,       // FNV-64 of description — change detection
}

// One shard's entry in the index
Indexed_Shard :: struct {
    name:      string,       // heap-allocated — cloned on load/write
    embedding: []f32,        // shard-level: catalog + gates text embedded
    text_hash: u64,          // FNV-64 of shard text — change detection
    thoughts:  [dynamic]Indexed_Thought,
}

// The unified index — one instance on Node (daemon only)
Shard_Index :: struct {
    shards: [dynamic]Indexed_Shard,
    dims:   int,             // embedding dimensions (consistent across all entries)
}

// Lightweight scored result — private to index.odin, used as return type
Index_Result :: struct {
    id:    Thought_ID,
    score: f32,
}

// Lightweight scored shard — private to index.odin, used as shard routing result
Index_Shard_Result :: struct {
    name:  string,   // points into existing Indexed_Shard.name — not a new allocation
    score: f32,
}
```

### Memory contract

All `string` fields in `Indexed_Thought` and `Indexed_Shard` are heap-allocated via `strings.clone()` on creation (both from writes and from `index_load`). They are freed with `delete()` when the entry is removed or the index is rebuilt. `index_build` frees all existing entries before repopulating. `index_load` allocates fresh strings for every entry it parses.

### Changes to `Node`

```odin
// Remove:
index:     [dynamic]Search_Entry,
vec_index: Vector_Index,

// Add (daemon only):
shard_index: Shard_Index,
```

### Changes to `Shard_Slot`

```odin
// Remove:
index: [dynamic]Search_Entry,
```

### Changes to `_slot_dispatch` in `ops_write.odin`

The `temp_node` pattern currently copies `slot.index` into a temp node and writes it back after dispatch. With `Shard_Slot.index` removed:

```odin
// Remove from temp_node init:
index = slot.index,

// Remove from write-back:
slot.index = temp_node.index
```

`temp_node` is still used for `blob` and `pending_alerts` write-back — that is unchanged. Index mutations (write, update, delete, compact) now call `index_*` procs directly on the daemon's `node` (passed into `_slot_dispatch` as a new parameter), not on `temp_node`. See Write Path section for details.

---

## Query Flow

### Single-shard query (`_op_query` in `protocol.odin`)

`_op_query` is called in two contexts:
1. **Standalone node** (non-daemon): the node's own blob is being queried directly
2. **Via `_slot_dispatch`**: the daemon dispatches to a slot via a `temp_node`

In both cases, the node passed to `_op_query` now has a `shard_index`. For the standalone node, `shard_index` contains a single `Indexed_Shard` entry for itself (populated at start in `node_init`). For the `_slot_dispatch` path, `_op_query` receives the daemon's real node — it looks up the slot's shard by name.

```
query arrives with shard name (or node.name for standalone)
  → find Indexed_Shard by name in node.shard_index.shards
  → if mode == "fulltext":
      → fulltext_search() — unchanged, decrypts content, returns windowed excerpts
  → else if shard has thought embeddings:
      → embed query once
      → cosine against each Indexed_Thought.embedding → ranked Index_Result hits
  → else:
      → keyword scan over Indexed_Thought.description → ranked Index_Result hits
  → for each hit: blob_get() + thought_decrypt() → return results
```

### Cross-shard query (`_op_global_query`, `_op_traverse` in `ops_query.odin`)

```
query arrives without shard name
  → if mode == "fulltext":
      → for each shard: load slot, fulltext_search() — unchanged behavior
  → else:
      → embed query once
      → index_query_shards(node, query, limit) → []Index_Shard_Result ranked by score
      → apply negative gate filter (_negative_gate_rejects — unchanged)
      → for each top-K shard result:
          → find Indexed_Shard in node.shard_index
          → index_query_thoughts(shard_entry, query) → []Index_Result ranked by score
      → merge all hits, sort by composite score
      → load only matched shards, decrypt only matched thoughts
      → return results
```

No speculative slot loading for non-fulltext queries. Shards with no matching thoughts are never touched.

### fulltext_search

`fulltext_search` is **retained and moved to `index.odin`**. It decrypts thought *content* (not just descriptions) and returns windowed line excerpts. It operates on a `Blob` directly and requires a loaded slot.

Its current signature includes `index: []Search_Entry` used as a pre-pass to skip decrypting thoughts whose descriptions don't match any query token. After this refactor, that parameter changes to `[]Indexed_Thought`:

```odin
// Old:
fulltext_search(index: []Search_Entry, blob: Blob, master: Master_Key, ...) -> []Fulltext_Excerpt

// New:
fulltext_search(thoughts: []Indexed_Thought, blob: Blob, master: Master_Key, ...) -> []Fulltext_Excerpt
```

The pre-pass logic is preserved — `Indexed_Thought.description` is used exactly as `Search_Entry.description` was. Callers pass the `thoughts` slice from the shard's `Indexed_Shard` entry (looked up by name from `node.shard_index`). For unprocessed thoughts (which have no aligned index entries), the empty slice behaviour is unchanged.

`fulltext_search`, `_fulltext_search_thoughts`, `_fulltext_hit_density`, `_compute_windows` all move from `search.odin` to `index.odin`.

### Fallback priority

1. Vector search (cosine) — when embeddings present
2. Keyword search (`_tokenize` + `_keyword_score`) — when no LLM configured
3. Gate scoring (`_score_gates`) — last resort for shard routing when `shard_index` has no shard embeddings

`_score_gates` is not removed. It remains the final fallback for shard routing.

---

## Persistence

### File: `.shards/.index`

Single JSON file. Atomic write (temp file + rename) matching `blob_flush` pattern.

```json
{
  "dims": 768,
  "shards": [
    {
      "name": "decisions",
      "text_hash": 12345678,
      "embedding": [0.1, 0.2, 0.3],
      "thoughts": [
        {
          "id": "abc123def456abc123def456abc123de",
          "text_hash": 87654321,
          "description": "Memory discipline — Odin requires explicit ownership",
          "embedding": [0.3, 0.1, 0.4]
        }
      ]
    }
  ]
}
```

### Change detection

- Shard embedding skipped if `text_hash` of `embed_shard_text()` output unchanged
- Thought embedding skipped if `text_hash` of description unchanged
- On warm restart with no changes: zero LLM calls

### Dims mismatch

If current embed model produces different dimensions than stored in `.shards/.index`:
- Entire index treated as cold, full rebuild triggered, old file overwritten
- No crash, no corruption

### Persistence strategy

`index_persist` is **not** called on every individual thought mutation. It is called:
- After `index_build` completes
- After `index_update_shard` completes (shard metadata changed)
- After any write operation that changes thought entries — **deferred to end of `_slot_dispatch`**, not inline in `index_add_thought` / `index_update_thought` / `index_remove_thought`

This means individual thought index mutations are batched within a single dispatch call and persisted once at the end. For the standalone node path (non-daemon), `index_persist` is called directly after each mutation since there is no `_slot_dispatch` batching.

---

## New Procs — `index.odin`

All index logic moves to a new `src/index.odin`. `embed.odin` retains only `embed_text`, `embed_texts`, `embed_shard_text`, `cosine_similarity`, `embed_ready`.

`_tokenize`, `_keyword_score`, `_stem`, `_composite_score`, `_compute_staleness`, `fulltext_search` and its helpers, `fnv_hash`, `_parse_rfc3339` all move from `search.odin` to `index.odin`.

`_format_time` stays in `ops_cache.odin` where it already lives — it is used across `ops_events.odin`, `ops_write.odin`, `protocol.odin`, and `cmd_new.odin`. It has no relationship to indexing and does not move.

| Proc | Signature | Purpose | Called from |
|---|---|---|---|
| `index_load` | `(node: ^Node) -> (restored: int, needs_rebuild: []string)` | Read `.shards/.index`, populate `node.shard_index`. Returns count of restored shards and list of shard names needing rebuild. | daemon start, `node_init` |
| `index_build` | `(node: ^Node)` | Full rebuild — all shards + thoughts, batch embed, persist. Frees all existing entries first. | daemon start (cold/stale), `_op_discover` |
| `index_persist` | `(node: ^Node)` | Serializes `node.shard_index` to a buffer (caller holds write lock), then writes buffer to `.shards/.index` atomically outside the lock. Caller is responsible for lock management — see Locking section. | end of `_slot_dispatch`, `index_build`, `index_update_shard`, standalone node mutations |
| `index_update_shard` | `(node: ^Node, name: string)` | Create entry if absent, or re-embed if metadata hash changed. Thought entries preserved if unchanged. Looks up `Registry_Entry` by name for `embed_shard_text`. Persists on completion. | `_op_remember`, gates updated, catalog updated, `_op_discover` (via `index_build`) |
| `index_add_thought` | `(node: ^Node, shard_name: string, id: Thought_ID, description: string)` | Append `Indexed_Thought`. Clones description. Embeds if LLM ready. Does not persist — caller persists. | `_op_write`, `_merge_revision_chain` |
| `index_update_thought` | `(node: ^Node, shard_name: string, id: Thought_ID, description: string)` | Update description + re-embed if hash changed. Does not persist — caller persists. | `_op_update` |
| `index_remove_thought` | `(node: ^Node, shard_name: string, id: Thought_ID)` | Remove `Indexed_Thought` by ID. Frees description and embedding. Does not persist — caller persists. | `_op_delete`, `_merge_revision_chain` |
| `index_remove_shard` | `(node: ^Node, name: string)` | Remove `Indexed_Shard` and all its thoughts. Frees all memory. Does not persist — caller persists. | shard deletion (future) |
| `index_query_shards` | `(node: ^Node, query: string, limit: int) -> []Index_Shard_Result` | Cosine or keyword ranked shard list. Returns scored names, not full structs. Uses `context.temp_allocator`. | `_op_global_query`, `_op_traverse` |
| `index_query_thoughts` | `(entry: ^Indexed_Shard, query: string) -> []Index_Result` | Cosine or keyword ranked thought hits within one shard. Uses `context.temp_allocator`. | `_op_query`, `_op_global_query` |

`Index_Result` and `Index_Shard_Result` are package-visible (no `@(private)`) so callers in `protocol.odin` and `ops_query.odin` can use them. They live in `index.odin`.

---

## `_slot_dispatch` — Updated Signature

To allow index mutations inside `_slot_dispatch` to update the daemon's real `shard_index`, `_slot_dispatch` receives the daemon node:

```odin
_slot_dispatch :: proc(
    daemon: ^Node,       // NEW — daemon node for index mutations
    slot:   ^Shard_Slot,
    req:    Request,
    allocator := context.allocator,
) -> string
```

Inside `_slot_dispatch`:
- `temp_node` no longer carries an `index` field
- The `"query"` case dispatches `_op_query(daemon, req, allocator)` — **not** `&temp_node`. `_op_query` uses `daemon.shard_index` to look up the slot's shard by `slot.name`.
- After the switch, if the op was mutating: `index_persist(daemon)` is called once
- `index_add_thought`, `index_update_thought`, `index_remove_thought` receive `daemon` not `temp_node`
- All callers of `_slot_dispatch` pass the daemon node as first argument — this includes `ops_write.odin`, and the `daemon_evict_idle` path in `daemon.odin` (see below)

### `_slot_drain_write_queue`

`_slot_drain_write_queue(slot, temp_node)` also calls `_op_write` for each queued request. Its signature changes to receive `daemon`:

```odin
_slot_drain_write_queue :: proc(daemon: ^Node, slot: ^Shard_Slot, temp_node: ^Node)
```

Each drained `_op_write` call routes through `daemon` for index mutations. `index_persist(daemon)` is called once after all queued writes are drained, not per write.

### `daemon_evict_idle` in `daemon.odin`

`daemon_evict_idle` has its own `temp_node` construction and `slot.index` write-back for draining write queues on lock expiry. After this refactor:
- Remove `index = slot.index` from temp_node init
- Remove `slot.index = temp_node.index` write-back
- Pass `node` (the daemon node) to `_slot_drain_write_queue`
- Remove `for &entry in slot.index do delete(entry.embedding)` and `clear(&slot.index)` from the eviction path — slot eviction no longer manages any index state

---

## Write Path — Call Sites

### `_op_write` (`protocol.odin`)

```
thought written
  → index_add_thought(daemon, shard_name, id, description)  // no persist yet
  → [end of _slot_dispatch] → index_persist(daemon)
```

### `_op_update` (`protocol.odin`)

```
thought updated
  → index_update_thought(daemon, shard_name, id, new_description)  // no persist yet
  → [end of _slot_dispatch] → index_persist(daemon)
```

### `_op_delete` (`protocol.odin`)

```
thought deleted
  → index_remove_thought(daemon, shard_name, id)  // no persist yet
  → [end of _slot_dispatch] → index_persist(daemon)
```

### `_merge_revision_chain` (`protocol.odin`)

```
revision chain merged
  → index_remove_thought(daemon, shard_name, id) for each removed chain member
  → index_add_thought(daemon, shard_name, merged_id, merged_description)
  → [end of _slot_dispatch] → index_persist(daemon)
```

### `_op_remember` (`ops_write.odin`)

```
new shard registered
  → index_update_shard(daemon, name)  // creates entry if absent, embeds, persists
```

`index_add_shard` is not called from `_op_remember`. `index_update_shard` handles both create (entry absent) and update (entry present, re-embed if hash changed). This is consistent with the existing pattern where `ops_write.odin:88` already calls `index_update_shard` today. `index_add_shard` is removed from the proc table — `index_update_shard` is the single entry point for both creation and updates of shard-level index entries.

### Gates / catalog updated (`ops_write.odin`)

```
set_positive / set_negative / set_description / set_catalog / _op_remember
  → index_update_shard(daemon, name)  // creates entry if absent, re-embeds if hash changed, persists
```

### `_op_discover` (`ops_write.odin`)

`_op_discover` currently calls `index_build(node)` to rebuild the shard-level vec_index after a registry scan. Under the new design it still calls `index_build(node)` — this now rebuilds the full two-level index (shards + thoughts). This is intentional: `_op_discover` is a registry refresh operation and a full index rebuild is the correct response.

---

## Start Sequences

### Daemon start

```
daemon starts
  → node_init():
      → shard_index = {}  (zero value, no allocation)

  → registry scan (unchanged — reads .shard metadata, populates node.registry)

  → restored, needs_rebuild := index_load(node)
      → read .shards/.index
      → if missing, unreadable, or dims mismatch → cold (needs_rebuild = all registry shards)
      → restore Indexed_Shard + Indexed_Thought entries (clone all strings)
      → drop entries for shards no longer in registry
      → drop entries for shards whose .shard file no longer exists on disk
      → mark shards in registry but not in index as needing rebuild

  → if len(needs_rebuild) == 0 → ready to serve

  → for each name in needs_rebuild:
      → load slot (blob_load + key resolution)
      → for each thought in blob:
          → description stored in Indexed_Thought regardless of LLM availability
          → if embed_ready(): batch embed all descriptions → store embeddings
          → if !embed_ready(): embeddings remain nil, keyword fallback active
      → unload slot if it was loaded only for indexing (not otherwise in use)
  → index_persist(node)

  → ready to serve
```

### Standalone node start (`node_init` in `node.odin`)

A standalone node (non-daemon) manages its own blob directly. It has no registry and no slots. Its `shard_index` contains a single entry for itself.

```
node_init(node, blob, master)
  → shard_index = {}

  → try index_load(node)  (reads .shards/.index relative to node's data path)
      → if loaded and entry for node.name present → done

  → else: build entry for own blob
      → create Indexed_Shard{name = node.name}
      → for each thought in blob: index_add_thought(node, node.name, id, description)
      → if embed_ready(): batch embed descriptions
      → index_persist(node)
```

This replaces the current `build_search_index(&node.index, node.blob, master, "node")` call in `node.odin`.

### Start scenarios

| Scenario | Cost |
|---|---|
| Warm restart, nothing changed | `index_load` only — zero LLM calls, milliseconds |
| New shard added since last start | Rebuild that shard only — one batch embed call |
| Embed model changed (dims mismatch) | Full rebuild — one-time cost |
| Cold start (no `.shards/.index`) | Full rebuild — one-time cost |
| No LLM configured, warm | `index_load` restores descriptions — keyword fallback active, zero LLM calls |
| No LLM configured, cold | `index_build` stores descriptions only — keyword fallback active |

---

## Locking

`node.shard_index` is guarded by the existing `node.mu` RW mutex:
- Query procs (`index_query_shards`, `index_query_thoughts`) hold **read lock** — concurrent reads allowed
- Mutating procs (`index_add_thought`, `index_update_thought`, `index_remove_thought`, `index_update_shard`, `index_build`) hold **write lock**

`index_persist` does **not** acquire any lock. It expects the caller to:
1. Hold the write lock while serializing `node.shard_index` to a local byte buffer
2. Release the write lock
3. Call `index_persist` to do the atomic file write (temp + rename) outside the lock

`_slot_dispatch` is called from connection handler code that already holds `node.mu` exclusively. The end-of-dispatch persist sequence is therefore:
```
// still inside write lock from connection handler
buffer := _index_serialize(node)   // snapshot under write lock
sync.mutex_unlock(&node.mu)        // release before I/O
_index_write_file(buffer)          // atomic write, no lock held
sync.mutex_lock(&node.mu)          // re-acquire if caller needs it
```

For `index_update_shard` (called from gate/catalog ops which also run inside the write lock), the same pattern applies. For `index_build` at daemon start, no other connections are running yet — lock management is a no-op.

---

## Files Changed

| File | Change |
|---|---|
| `src/index.odin` | New — owns all index logic, fulltext search, scoring, tokenization |
| `src/embed.odin` | Strip index procs, keep `embed_text`, `embed_texts`, `embed_shard_text`, `cosine_similarity`, `embed_ready` |
| `src/search.odin` | Deleted entirely — all procs move to `index.odin` except `build_search_index` and `search_query` which are replaced |
| `src/types.odin` | Remove `Vector_Index`, `Vector_Entry`, `Vector_Result`, `Search_Entry`, `Search_Result`; add `Indexed_Thought`, `Indexed_Shard`, `Shard_Index`; update `Node` and `Shard_Slot` |
| `src/protocol.odin` | Update write/update/delete/compact call sites; remove `node.index` references |
| `src/ops_write.odin` | Update `_slot_dispatch` signature (add `daemon ^Node`); update `_op_remember`, gate sync call sites; remove `slot.index` write-back |
| `src/ops_read.odin` | Delete `_slot_build_index` entirely |
| `src/ops_query.odin` | Update `_op_global_query`, `_op_traverse` to use `index_query_shards` + `index_query_thoughts` |
| `src/node.odin` | Remove `node.index` init; `node.shard_index` zero-initializes automatically |
| `src/daemon.odin` | Remove slot index sync code; update `_slot_dispatch` call sites to pass `node` |

---

## What Does Not Change

- `.shard` binary file format (SHRD0006) — untouched
- Encryption model — untouched
- `blob.odin` — untouched
- `crypto.odin` — untouched
- `fulltext_search` behavior — moved to `index.odin`, unchanged
- Gate scoring (`_score_gates`) — retained as fallback
- Composite scoring (`_composite_score`) — retained, moves to `index.odin`
- Staleness scoring (`_compute_staleness`) — retained, moves to `index.odin`
- All MCP tool signatures — untouched
- All protocol op names — untouched
- `fulltext` mode in `_op_query` and `_op_global_query` — untouched
