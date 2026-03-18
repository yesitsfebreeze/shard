# Unified Search Index Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `vec_index` + per-slot `Search_Entry[]` with a single unified two-level persistent index (`Shard_Index`) — one file (`.shards/.index`), one in-memory struct, zero legacy remnants.

**Architecture:** A new `src/index.odin` owns all index logic: two-level cosine search (shard-level routing → thought-level hits), keyword fallback, persistence as JSON with atomic write, and all scoring/tokenization procs moved from `search.odin`. The old `search.odin` is deleted entirely, `embed.odin` is stripped to embedding-only, and all call sites across `protocol.odin`, `ops_write.odin`, `ops_query.odin`, `ops_read.odin`, `node.odin`, and `daemon.odin` are updated.

**Tech Stack:** Odin, `core:encoding/json`, existing `embed_text`/`embed_texts`/`cosine_similarity`, existing `blob_flush` atomic-write pattern.

**Spec:** `docs/superpowers/specs/2026-03-18-unified-search-index-design.md`

---

## File Map

| File | Action | Responsibility |
|---|---|---|
| `src/index.odin` | **Create** | All index logic: structs, load/build/persist, query, thought mutations, scoring, tokenization, fulltext search |
| `src/search.odin` | **Delete** | Replaced entirely by `index.odin` |
| `src/embed.odin` | **Modify** | Strip index procs; keep `embed_text`, `embed_texts`, `embed_shard_text`, `cosine_similarity`, `embed_ready` |
| `src/types.odin` | **Modify** | Remove 5 old structs, add 5 new structs, update `Node` and `Shard_Slot` |
| `src/protocol.odin` | **Modify** | Update `_op_write`, `_op_update`, `_op_delete`, `_merge_revision_chain`, `_op_query` call sites |
| `src/ops_write.odin` | **Modify** | New `_slot_dispatch` signature, update `_op_remember`/gates, remove `slot.index` write-back |
| `src/ops_read.odin` | **Modify** | Delete `_slot_build_index` |
| `src/ops_query.odin` | **Modify** | Update `_op_global_query`, `_op_traverse`, fulltext call sites |
| `src/ops_events.odin` | **Modify** | Update `_op_rollback` temp_node pattern |
| `src/node.odin` | **Modify** | Replace `build_search_index` call with `index_load`/thought-index build |
| `src/daemon.odin` | **Modify** | Remove slot index sync in `daemon_evict_idle` |
| `tests/unit/test_query.odin` | **Modify** | Replace `Search_Entry`/`search_query` test with `Indexed_Thought`/`index_query_thoughts` test |

---

## Task 1: New types in `types.odin`

**Files:**
- Modify: `src/types.odin`

- [ ] **Step 1.1: Remove old search/vector structs**

In `src/types.odin`, delete these struct definitions and the fields that reference them:

```
// DELETE these structs:
Search_Entry :: struct { ... }
Search_Result :: struct { ... }
Vector_Index :: struct { ... }
Vector_Entry :: struct { ... }
Vector_Result :: struct { ... }

// DELETE from Node:
index:     [dynamic]Search_Entry,
vec_index: Vector_Index,

// DELETE from Shard_Slot:
index: [dynamic]Search_Entry,
```

- [ ] **Step 1.2: Add new index structs**

In `src/types.odin`, add after the existing `// Search` section (replace it entirely):

```odin
// =============================================================================
// Unified search index
// =============================================================================

Indexed_Thought :: struct {
    id:          Thought_ID,
    description: string,   // heap-allocated, cloned on write/load, freed on remove
    embedding:   []f32,    // nil if LLM not configured
    text_hash:   u64,      // FNV-64 of description — change detection
}

Indexed_Shard :: struct {
    name:      string,     // heap-allocated, cloned on write/load
    embedding: []f32,      // shard-level embedding: catalog + gates text
    text_hash: u64,        // FNV-64 of shard gate text — change detection
    thoughts:  [dynamic]Indexed_Thought,
}

Shard_Index :: struct {
    shards: [dynamic]Indexed_Shard,
    dims:   int,           // embedding dimensions (consistent across all entries)
}

// Lightweight scored thought result — used by index_query_thoughts
Index_Result :: struct {
    id:    Thought_ID,
    score: f32,
}

// Lightweight scored shard result — used by index_query_shards
Index_Shard_Result :: struct {
    name:  string, // points into Indexed_Shard.name — not a new allocation
    score: f32,
}
```

- [ ] **Step 1.3: Add `shard_index` to `Node`, remove `index` and `vec_index`**

In `src/types.odin` in the `Node` struct:
```odin
// Remove:
index:     [dynamic]Search_Entry,
vec_index: Vector_Index,

// Add (after existing fields, before registry):
shard_index: Shard_Index,
```

- [ ] **Step 1.4: Build — confirm types compile**

```bash
just test-build
```
Expected: compile errors about missing `Search_Entry`, `search_query`, `build_search_index`, `index_build`, etc. — that is correct, we will fix them in subsequent tasks. The goal here is just to confirm `types.odin` itself parses.

---

## Task 2: Create `src/index.odin` — core structs, persistence, scoring

**Files:**
- Create: `src/index.odin`

This task builds the new file in layers. Each step adds a section and must compile.

- [ ] **Step 2.1: File skeleton and moved procs**

Create `src/index.odin` with the package declaration and move these procs verbatim from `search.odin` (do not delete `search.odin` yet — it will be deleted in Task 5):

```odin
package shard

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:time"
import "core:unicode"

import logger "logger"

// =============================================================================
// Moved from search.odin — tokenization, scoring, staleness, time parsing
// =============================================================================
```

Then copy these procs from `search.odin` into `index.odin`:
- `fnv_hash`
- `_tokenize`
- `_stem`
- `_keyword_score`
- `_composite_score`
- `_compute_staleness`
- `_parse_rfc3339`
- `_atoi2`
- `_atoi4`
- `_sort_results` (rename to `_sort_index_results`, change to operate on `[]Index_Result`)

Mark all as `@(private)` except `fnv_hash` (it is called from `protocol.odin`).

- [ ] **Step 2.2: Add persistence path helper and index_persist**

**Locking contract:** `index_persist` does NOT acquire any lock. In the daemon, it is called from `_slot_dispatch` end which already holds `node.mu` exclusively. The correct pattern is:
1. Serialize `node.shard_index` to a local byte buffer **while holding the write lock**
2. Release the write lock
3. Do the atomic file write outside the lock

In practice: `index_persist` is called at the end of `_slot_dispatch` after all mutations. At that point the connection handler holds the write lock. `index_persist` should serialize, then the write lock should be released by the connection handler before returning, with file I/O happening outside. For simplicity in this implementation: `index_persist` serializes to a temp buffer then does the file write inline — the lock is not re-acquired inside `index_persist`. The file I/O is fast enough (atomic rename) that holding the lock across it is acceptable for now. Document this with a comment.

```odin
// =============================================================================
// Persistence — .shards/.index
// =============================================================================

_index_path :: proc() -> string {
    return ".shards/.index"
}

// index_persist writes node.shard_index to .shards/.index as JSON.
// Does NOT acquire node.mu — caller is responsible for holding the write lock
// during serialization. File I/O is performed inline after serialization.
index_persist :: proc(node: ^Node) {
    if len(node.shard_index.shards) == 0 do return

    b := strings.builder_make(context.temp_allocator)
    strings.write_string(&b, "{\n")
    fmt.sbprintf(&b, "  \"dims\": %d,\n", node.shard_index.dims)
    strings.write_string(&b, "  \"shards\": [\n")

    for shard_entry, si in node.shard_index.shards {
        strings.write_string(&b, "    {\n")
        // escape name for JSON safety
        esc_name := _json_escape(shard_entry.name, context.temp_allocator)
        fmt.sbprintf(&b, "      \"name\": \"%s\",\n", esc_name)
        fmt.sbprintf(&b, "      \"text_hash\": %d,\n", shard_entry.text_hash)
        strings.write_string(&b, "      \"embedding\": [")
        for f, fi in shard_entry.embedding {
            if fi > 0 do strings.write_string(&b, ",")
            fmt.sbprintf(&b, "%g", f)
        }
        strings.write_string(&b, "],\n")
        strings.write_string(&b, "      \"thoughts\": [\n")
        for te, ti in shard_entry.thoughts {
            strings.write_string(&b, "        {\n")
            fmt.sbprintf(&b, "          \"id\": \"%s\",\n", id_to_hex(te.id, context.temp_allocator))
            fmt.sbprintf(&b, "          \"text_hash\": %d,\n", te.text_hash)
            esc_desc := _json_escape(te.description, context.temp_allocator)
            fmt.sbprintf(&b, "          \"description\": \"%s\",\n", esc_desc)
            strings.write_string(&b, "          \"embedding\": [")
            for f, fi in te.embedding {
                if fi > 0 do strings.write_string(&b, ",")
                fmt.sbprintf(&b, "%g", f)
            }
            strings.write_string(&b, "]\n")
            if ti < len(shard_entry.thoughts) - 1 {
                strings.write_string(&b, "        },\n")
            } else {
                strings.write_string(&b, "        }\n")
            }
        }
        strings.write_string(&b, "      ]\n")
        if si < len(node.shard_index.shards) - 1 {
            strings.write_string(&b, "    },\n")
        } else {
            strings.write_string(&b, "    }\n")
        }
    }
    strings.write_string(&b, "  ]\n}\n")

    data := transmute([]u8)strings.to_string(b)
    tmp := fmt.tprintf("%s.tmp", _index_path())

    f, ferr := os.open(tmp, os.O_WRONLY | os.O_CREATE | os.O_TRUNC, 0o644)
    if ferr != nil {
        logger.warnf("index: persist open failed: %v", ferr)
        return
    }
    _, werr := os.write(f, data)
    os.close(f)
    if werr != nil {
        logger.warnf("index: persist write failed: %v", werr)
        return
    }
    when ODIN_OS == .Windows {
        if !os.rename(tmp, _index_path()) {
            logger.warnf("index: persist rename failed")
        }
    } else {
        if rename_err := os.rename(tmp, _index_path()); rename_err != nil {
            logger.warnf("index: persist rename failed: %v", rename_err)
        }
    }
}

@(private)
_json_escape :: proc(s: string, allocator := context.allocator) -> string {
    b := strings.builder_make(allocator)
    for c in s {
        switch c {
        case '"':  strings.write_string(&b, "\\\"")
        case '\': strings.write_string(&b, "\\\\")
        case '\n': strings.write_string(&b, "\n")
        case '\r': strings.write_string(&b, "\r")
        case '\t': strings.write_string(&b, "\t")
        case:      strings.write_rune(&b, c)
        }
    }
    return strings.to_string(b)
}
```

- [ ] **Step 2.3: Build — confirm no new errors introduced**

```bash
just test-build
```
Expected: same errors as after Task 1 (missing call sites), no new errors.

---

## Task 3: Add `index_load` and `index_build` to `index.odin`

**Files:**
- Modify: `src/index.odin`

- [ ] **Step 3.1: Add `index_load`**

```odin
// =============================================================================
// Load and build
// =============================================================================

// index_load reads .shards/.index and populates node.shard_index.
// Returns (restored count, list of shard names that need rebuilding).
// Caller must handle the rebuild list before serving queries.
index_load :: proc(node: ^Node, allocator := context.allocator) -> (restored: int, needs_rebuild: [dynamic]string) {
    needs_rebuild = make([dynamic]string, allocator)

    data, ok := os.read_entire_file(_index_path(), context.temp_allocator)
    if !ok do return 0, needs_rebuild

    // Parse dims
    // Parse shards array
    // Use md_json_get_* helpers from markdown.odin for JSON parsing
    // (same pattern as index_load in embed.odin)

    parsed, parse_ok := _parse_index_json(string(data), node, allocator)
    if !parse_ok {
        logger.warnf("index: load failed to parse — cold start")
        return 0, needs_rebuild
    }

    // Dims mismatch: if embed_ready() and dims differ, treat as cold
    if parsed > 0 && embed_ready() && node.shard_index.dims > 0 {
        // dims are set during parse — checked after
    }

    // Build set of loaded shard names
    loaded := make(map[string]bool, allocator = context.temp_allocator)
    for &se in node.shard_index.shards {
        loaded[se.name] = true
    }

    // Any registry shard not in index needs rebuild
    for entry in node.registry {
        if entry.name == DAEMON_NAME do continue
        if !(entry.name in loaded) {
            append(&needs_rebuild, strings.clone(entry.name, allocator))
        }
    }

    // Drop entries for shards not in registry or whose file is missing
    i := 0
    for i < len(node.shard_index.shards) {
        se := &node.shard_index.shards[i]
        in_registry := false
        for entry in node.registry {
            if entry.name == se.name { in_registry = true; break }
        }
        file_exists := os.exists(se.name + ".shard") || _shard_file_exists(node, se.name)
        if !in_registry || !file_exists {
            _free_indexed_shard(se)
            ordered_remove(&node.shard_index.shards, i)
            continue
        }
        i += 1
    }

    restored = len(node.shard_index.shards)
    logger.infof("index: loaded %d shards, %d need rebuild", restored, len(needs_rebuild))
    return restored, needs_rebuild
}
```

Note: `_parse_index_json` and `_shard_file_exists` and `_free_indexed_shard` are helpers added in the same step:

```odin
@(private)
_free_indexed_shard :: proc(se: ^Indexed_Shard) {
    delete(se.name)
    delete(se.embedding)
    for &te in se.thoughts {
        delete(te.description)
        delete(te.embedding)
    }
    delete(se.thoughts)
}

@(private)
_shard_file_exists :: proc(node: ^Node, name: string) -> bool {
    for entry in node.registry {
        if entry.name == name {
            return os.exists(entry.data_path)
        }
    }
    return false
}
```

For `_parse_index_json`, use `core:encoding/json` exactly as the current `embed.odin:index_load` does (lines 302–362). Here is the full implementation:

```odin
@(private)
_parse_index_json :: proc(data: string, node: ^Node, allocator := context.allocator) -> (int, bool) {
    val, err := json.parse(transmute([]u8)data, allocator = context.temp_allocator)
    if err != .None do return 0, false
    defer json.destroy_value(val, context.temp_allocator)

    root, is_obj := val.(json.Object)
    if !is_obj do return 0, false

    // Parse dims
    if dims_val, ok := root["dims"]; ok {
        switch d in dims_val {
        case json.Float:   node.shard_index.dims = int(d)
        case json.Integer: node.shard_index.dims = int(d)
        }
    }

    shards_val, has_shards := root["shards"]
    if !has_shards do return 0, false
    shards_arr, is_arr := shards_val.(json.Array)
    if !is_arr do return 0, false

    count := 0
    for shard_item in shards_arr {
        shard_obj, is_shard := shard_item.(json.Object)
        if !is_shard do continue

        name_val, _ := shard_obj["name"]
        name_str, name_ok := name_val.(json.String)
        if !name_ok do continue

        hash_val, _ := shard_obj["text_hash"]
        text_hash: u64
        switch h in hash_val {
        case json.Float:   text_hash = u64(h)
        case json.Integer: text_hash = u64(h)
        }

        se := Indexed_Shard{
            name      = strings.clone(string(name_str), allocator),
            text_hash = text_hash,
            thoughts  = make([dynamic]Indexed_Thought, allocator),
        }

        // Parse shard embedding
        if emb_val, ok := shard_obj["embedding"]; ok {
            if emb_arr, is_emb := emb_val.(json.Array); is_emb {
                se.embedding = make([]f32, len(emb_arr), allocator)
                for fv, fi in emb_arr {
                    switch f in fv {
                    case json.Float:   se.embedding[fi] = f32(f)
                    case json.Integer: se.embedding[fi] = f32(f)
                    }
                }
            }
        }

        // Parse thoughts
        if thoughts_val, ok := shard_obj["thoughts"]; ok {
            if thoughts_arr, is_ta := thoughts_val.(json.Array); is_ta {
                for thought_item in thoughts_arr {
                    thought_obj, is_to := thought_item.(json.Object)
                    if !is_to do continue

                    id_val, _ := thought_obj["id"]
                    id_str, id_ok := id_val.(json.String)
                    if !id_ok do continue
                    tid, hex_ok := hex_to_id(string(id_str))
                    if !hex_ok do continue

                    desc_val, _ := thought_obj["description"]
                    desc_str, desc_ok := desc_val.(json.String)
                    if !desc_ok do continue

                    th_hash_val, _ := thought_obj["text_hash"]
                    th_hash: u64
                    switch h in th_hash_val {
                    case json.Float:   th_hash = u64(h)
                    case json.Integer: th_hash = u64(h)
                    }

                    te := Indexed_Thought{
                        id          = tid,
                        description = strings.clone(string(desc_str), allocator),
                        text_hash   = th_hash,
                    }

                    if emb_val, ok := thought_obj["embedding"]; ok {
                        if emb_arr, is_emb := emb_val.(json.Array); is_emb && len(emb_arr) > 0 {
                            te.embedding = make([]f32, len(emb_arr), allocator)
                            for fv, fi in emb_arr {
                                switch f in fv {
                                case json.Float:   te.embedding[fi] = f32(f)
                                case json.Integer: te.embedding[fi] = f32(f)
                                }
                            }
                        }
                    }
                    append(&se.thoughts, te)
                }
            }
        }

        append(&node.shard_index.shards, se)
        count += 1
    }
    return count, true
}
```

- [ ] **Step 3.2: Add `index_build`**

```odin
// index_build does a full rebuild of node.shard_index from all registry shards.
// Frees all existing entries first. Called on cold start or after _op_discover.
index_build :: proc(node: ^Node) {
    // Free existing
    for &se in node.shard_index.shards {
        _free_indexed_shard(&se)
    }
    delete(node.shard_index.shards)
    node.shard_index.shards = make([dynamic]Indexed_Shard)
    node.shard_index.dims = 0

    for entry in node.registry {
        if entry.name == DAEMON_NAME do continue
        index_update_shard(node, entry.name)
    }

    // index_update_shard calls index_persist per shard — final persist after all done
    logger.infof("index: built %d shards", len(node.shard_index.shards))
}
```

- [ ] **Step 3.3: Build check**

```bash
just test-build
```
Expected: still the same call-site errors — no new ones.

---

## Task 4: Add mutation and query procs to `index.odin`

**Files:**
- Modify: `src/index.odin`

- [ ] **Step 4.1: Add `index_update_shard`**

```odin
// index_update_shard creates or updates the Indexed_Shard entry for a shard.
// Creates if absent. Re-embeds shard if metadata hash changed.
// Preserves existing Indexed_Thought entries.
// Persists on completion.
index_update_shard :: proc(node: ^Node, name: string) {
    // Find registry entry
    reg_entry: ^Registry_Entry
    for &e in node.registry {
        if e.name == name { reg_entry = &e; break }
    }
    if reg_entry == nil do return

    shard_text := embed_shard_text(reg_entry^)
    new_hash := fnv_hash(shard_text)

    // Find or create Indexed_Shard
    existing: ^Indexed_Shard
    for &se in node.shard_index.shards {
        if se.name == name { existing = &se; break }
    }

    if existing == nil {
        // Create new entry
        se := Indexed_Shard{
            name      = strings.clone(name),
            text_hash = new_hash,
        }
        if embed_ready() {
            emb, ok := embed_text(shard_text, context.temp_allocator)
            if ok {
                se.embedding = make([]f32, len(emb))
                copy(se.embedding, emb)
                node.shard_index.dims = len(emb)
            }
        }
        se.thoughts = make([dynamic]Indexed_Thought)
        append(&node.shard_index.shards, se)
        index_persist(node)
        return
    }

    // Update existing: re-embed if hash changed
    if existing.text_hash != new_hash {
        delete(existing.embedding)
        existing.embedding = nil
        existing.text_hash = new_hash
        if embed_ready() {
            emb, ok := embed_text(shard_text, context.temp_allocator)
            if ok {
                existing.embedding = make([]f32, len(emb))
                copy(existing.embedding, emb)
                node.shard_index.dims = len(emb)
            }
        }
    }
    index_persist(node)
}
```

- [ ] **Step 4.2: Add thought mutation procs**

```odin
// index_add_thought appends an Indexed_Thought to the named shard entry.
// Clones description. Embeds if LLM ready.
// Does NOT persist — caller must call index_persist after.
index_add_thought :: proc(node: ^Node, shard_name: string, id: Thought_ID, description: string) {
    se := _find_indexed_shard(node, shard_name)
    if se == nil do return

    te := Indexed_Thought{
        id          = id,
        description = strings.clone(description),
        text_hash   = fnv_hash(description),
    }
    if embed_ready() {
        emb, ok := embed_text(description, context.temp_allocator)
        if ok {
            te.embedding = make([]f32, len(emb))
            copy(te.embedding, emb)
            if node.shard_index.dims == 0 do node.shard_index.dims = len(emb)
        }
    }
    append(&se.thoughts, te)
}

// index_update_thought updates description and re-embeds if hash changed.
// Does NOT persist — caller must call index_persist after.
index_update_thought :: proc(node: ^Node, shard_name: string, id: Thought_ID, description: string) {
    se := _find_indexed_shard(node, shard_name)
    if se == nil do return

    new_hash := fnv_hash(description)
    for &te in se.thoughts {
        if te.id != id do continue
        if te.text_hash == new_hash do return // no change
        delete(te.description)
        te.description = strings.clone(description)
        te.text_hash = new_hash
        delete(te.embedding)
        te.embedding = nil
        if embed_ready() {
            emb, ok := embed_text(description, context.temp_allocator)
            if ok {
                te.embedding = make([]f32, len(emb))
                copy(te.embedding, emb)
            }
        }
        return
    }
}

// index_remove_thought removes an Indexed_Thought by ID. Frees its memory.
// Does NOT persist — caller must call index_persist after.
index_remove_thought :: proc(node: ^Node, shard_name: string, id: Thought_ID) {
    se := _find_indexed_shard(node, shard_name)
    if se == nil do return

    for i := 0; i < len(se.thoughts); i += 1 {
        if se.thoughts[i].id == id {
            delete(se.thoughts[i].description)
            delete(se.thoughts[i].embedding)
            ordered_remove(&se.thoughts, i)
            return
        }
    }
}

// index_remove_shard removes an Indexed_Shard and all its thoughts. Frees memory.
// Does NOT persist — caller must call index_persist after.
index_remove_shard :: proc(node: ^Node, name: string) {
    for i := 0; i < len(node.shard_index.shards); i += 1 {
        if node.shard_index.shards[i].name == name {
            _free_indexed_shard(&node.shard_index.shards[i])
            ordered_remove(&node.shard_index.shards, i)
            return
        }
    }
}

@(private)
_find_indexed_shard :: proc(node: ^Node, name: string) -> ^Indexed_Shard {
    for &se in node.shard_index.shards {
        if se.name == name do return &se
    }
    return nil
}
```

- [ ] **Step 4.3: Add query procs**

```odin
// =============================================================================
// Query
// =============================================================================

// index_query_shards returns shards ranked by relevance to query.
// Uses cosine similarity if embeddings present, keyword fallback otherwise.
// Falls back to gate scoring if no embeddings at all.
// Uses context.temp_allocator — caller must not hold results past next alloc.
index_query_shards :: proc(node: ^Node, query: string, limit: int) -> []Index_Shard_Result {
    results := make([dynamic]Index_Shard_Result, context.temp_allocator)

    if embed_ready() && node.shard_index.dims > 0 {
        q_embed, ok := embed_text(query, context.temp_allocator)
        if ok {
            for &se in node.shard_index.shards {
                if se.embedding == nil do continue
                score := cosine_similarity(q_embed, se.embedding)
                if score > 0.3 {
                    append(&results, Index_Shard_Result{name = se.name, score = score})
                }
            }
        }
    }

    // Keyword fallback if no vector results
    if len(results) == 0 {
        q_tokens := _tokenize(query, context.temp_allocator)
        if len(q_tokens) > 0 {
            for &se in node.shard_index.shards {
                score := _keyword_score(q_tokens, se.name)
                if score > 0 {
                    append(&results, Index_Shard_Result{name = se.name, score = score})
                }
            }
        }
    }

    // Sort descending
    _sort_shard_results(results[:])

    n := min(limit, len(results))
    return results[:n]
}

// index_query_thoughts returns thoughts in a shard ranked by relevance to query.
// Uses context.temp_allocator.
index_query_thoughts :: proc(se: ^Indexed_Shard, query: string) -> []Index_Result {
    results := make([dynamic]Index_Result, context.temp_allocator)

    has_embeddings := len(se.thoughts) > 0 && se.thoughts[0].embedding != nil
    if embed_ready() && has_embeddings {
        q_embed, ok := embed_text(query, context.temp_allocator)
        if ok {
            for &te in se.thoughts {
                if te.embedding == nil do continue
                score := cosine_similarity(q_embed, te.embedding)
                if score > 0.3 {
                    append(&results, Index_Result{id = te.id, score = score})
                }
            }
            _sort_index_results(results[:])
            return results[:]
        }
    }

    // Keyword fallback
    q_tokens := _tokenize(query, context.temp_allocator)
    if len(q_tokens) == 0 do return nil
    for &te in se.thoughts {
        score := _keyword_score(q_tokens, te.description)
        if score > 0 {
            append(&results, Index_Result{id = te.id, score = score})
        }
    }
    _sort_index_results(results[:])
    return results[:]
}

@(private)
_sort_shard_results :: proc(results: []Index_Shard_Result) {
    for i := 1; i < len(results); i += 1 {
        key := results[i]
        j := i - 1
        for j >= 0 && results[j].score < key.score {
            results[j + 1] = results[j]
            j -= 1
        }
        results[j + 1] = key
    }
}
```

- [ ] **Step 4.5: Build check**

```bash
just test-build
```
Expected: errors only in callers that still reference old types/procs. No errors inside `index.odin` itself.

---

## Task 5: Strip `embed.odin` and delete `search.odin`

**Files:**
- Modify: `src/embed.odin`
- Delete: `src/search.odin`

- [ ] **Step 5.1: Strip `embed.odin`**

Delete these procs from `src/embed.odin` (they are now in `index.odin` or replaced):
- `index_build`
- `index_update_shard`
- `index_persist`
- `index_load`
- `index_query`
- `_vec_index_path`

Keep: `embed_ready`, `embed_text`, `embed_texts`, `embed_shard_text`, `cosine_similarity`, `_build_embed_body`, `_parse_embed_response`, `_parse_f32_array`, `_build_embed_body_batch`, `_parse_embed_response_batch`, `_cleanup_batch`, `_http_post`, `_llm_endpoint`, and all HTTP helpers.

Also delete the `// Vec index persistence` section comment and all JSON serialization code for `Vector_Entry`.

- [ ] **Step 5.2: Delete `search.odin`**

```bash
rm src/search.odin
```

- [ ] **Step 5.3: Build — confirm only call-site errors remain**

```bash
just test-build
```
Expected: errors in `protocol.odin`, `ops_write.odin`, `ops_query.odin`, `ops_read.odin`, `node.odin`, `daemon.odin` about missing calls. Zero errors inside `index.odin` or `embed.odin`.

---

## Task 6: Update `node.odin`

**Files:**
- Modify: `src/node.odin`

- [ ] **Step 6.1: Replace `build_search_index` call with index initialization**

In `node_init`, replace:
```odin
node.index = make([dynamic]Search_Entry)
// ...
if !build_search_index(&node.index, node.blob, master, "node") {
    fmt.eprintfln("node: wrong key — could not decrypt any existing thoughts")
    return node, false
}
```

With:
```odin
// shard_index zero-initializes automatically — no explicit make needed

// Key authentication: try to decrypt at least one thought
if !is_daemon {
    total_thoughts := len(node.blob.processed) + len(node.blob.unprocessed)
    if total_thoughts > 0 {
        decrypted_any := false
        for thought in node.blob.processed {
            pt, err := thought_decrypt(thought, master, context.temp_allocator)
            if err == .None {
                delete(pt.description, context.temp_allocator)
                delete(pt.content, context.temp_allocator)
                decrypted_any = true
                break
            }
        }
        if !decrypted_any {
            fmt.eprintfln("node: wrong key — could not decrypt any existing thoughts")
            return node, false
        }
    }
}
```

- [ ] **Step 6.2: Add `_index_blob_thoughts` helper to `index.odin`**

Odin does not support nested procs. Add this as a package-level private proc in `src/index.odin`:

```odin
// _index_blob_thoughts decrypts all thoughts in a slice, appends Indexed_Thought
// entries to se, and collects description strings into descs for batch embedding.
@(private)
_index_blob_thoughts :: proc(
    thoughts: []Thought,
    master: Master_Key,
    se: ^Indexed_Shard,
    descs: ^[dynamic]string,
) {
    for thought in thoughts {
        pt, err := thought_decrypt(thought, master, context.temp_allocator)
        if err != .None do continue
        desc := strings.clone(pt.description)
        te := Indexed_Thought{
            id          = thought.id,
            description = desc,
            text_hash   = fnv_hash(desc),
        }
        append(&se.thoughts, te)
        append(descs, desc)
        delete(pt.description, context.temp_allocator)
        delete(pt.content, context.temp_allocator)
    }
}
```

- [ ] **Step 6.3: Populate `shard_index` for standalone node in `node_init`**

After the key authentication block, for non-daemon nodes:

```odin
if !is_daemon {
    // Try to load existing index
    _, needs_rebuild := index_load(&node)
    defer delete(needs_rebuild)
    if len(needs_rebuild) > 0 || len(node.shard_index.shards) == 0 {
        // Build entry for own blob
        se := Indexed_Shard{
            name    = strings.clone(node.name),
            thoughts = make([dynamic]Indexed_Thought),
        }
        descs := make([dynamic]string, context.temp_allocator)
        _index_blob_thoughts(node.blob.processed[:], master, &se, &descs)
        _index_blob_thoughts(node.blob.unprocessed[:], master, &se, &descs)

        if embed_ready() && len(descs) > 0 {
            embeddings, ok := embed_texts(descs[:], context.temp_allocator)
            if ok && len(embeddings) == len(se.thoughts) {
                for &te, i in se.thoughts {
                    te.embedding = make([]f32, len(embeddings[i]))
                    copy(te.embedding, embeddings[i])
                }
                if len(embeddings) > 0 do node.shard_index.dims = len(embeddings[0])
            }
        }
        append(&node.shard_index.shards, se)
        index_persist(&node)
    }
}
```

- [ ] **Step 6.4: Update daemon path — ensure `index_build` handles thought rebuild**

The daemon path calls `index_build(&node)` which calls `index_update_shard` per shard. However per the spec, `index_update_shard` only handles shard-level metadata. For a warm restart where only some shards need rebuilding (the `needs_rebuild` list from `index_load`), the per-thought entries must also be populated.

Update `index_build` in `index.odin` to also build per-thought entries for each shard:

```odin
index_build :: proc(node: ^Node) {
    // Free existing
    for &se in node.shard_index.shards {
        _free_indexed_shard(&se)
    }
    delete(node.shard_index.shards)
    node.shard_index.shards = make([dynamic]Indexed_Shard)
    node.shard_index.dims = 0

    for entry in node.registry {
        if entry.name == DAEMON_NAME do continue
        _build_shard_entry(node, entry.name)
    }
    index_persist(node)
    logger.infof("index: built %d shards", len(node.shard_index.shards))
}
```

Add `_build_shard_entry` which loads the slot, decrypts thoughts, builds `Indexed_Thought` entries with batch embedding, then unloads the slot:

```odin
@(private)
_build_shard_entry :: proc(node: ^Node, name: string) {
    reg_entry: ^Registry_Entry
    for &e in node.registry {
        if e.name == name { reg_entry = &e; break }
    }
    if reg_entry == nil do return

    se := Indexed_Shard{
        name     = strings.clone(name),
        thoughts = make([dynamic]Indexed_Thought),
    }

    // Shard-level embedding
    shard_text := embed_shard_text(reg_entry^)
    se.text_hash = fnv_hash(shard_text)
    if embed_ready() {
        emb, ok := embed_text(shard_text, context.temp_allocator)
        if ok {
            se.embedding = make([]f32, len(emb))
            copy(se.embedding, emb)
            node.shard_index.dims = len(emb)
        }
    }

    // Load blob to get thought descriptions
    blob, blob_ok := blob_load(reg_entry.data_path, reg_entry.master)
    if !blob_ok {
        append(&node.shard_index.shards, se)
        return
    }
    defer blob_free(&blob) // unload after indexing

    descs := make([dynamic]string, context.temp_allocator)
    _index_blob_thoughts(blob.processed[:],   reg_entry.master, &se, &descs)
    _index_blob_thoughts(blob.unprocessed[:], reg_entry.master, &se, &descs)

    if embed_ready() && len(descs) > 0 {
        embeddings, ok := embed_texts(descs[:], context.temp_allocator)
        if ok && len(embeddings) == len(se.thoughts) {
            for &te, i in se.thoughts {
                te.embedding = make([]f32, len(embeddings[i]))
                copy(te.embedding, embeddings[i])
            }
        }
    }
    append(&node.shard_index.shards, se)
}
```

Note: `blob_free` frees the blob's allocated memory. Check if this proc exists; if not, use `blob_unload` or manually free `blob.processed`, `blob.unprocessed`, catalog strings. Check `blob.odin` for the correct cleanup proc name.

Also update `index_update_shard` to call `_build_shard_entry` when creating a new entry (replace the inline creation block with `_build_shard_entry`).

- [ ] **Step 6.5: Build check**

```bash
just test-build
```
Expected: `node.odin` errors resolved. Remaining errors in `protocol.odin`, `ops_write.odin`, `ops_query.odin`, `ops_read.odin`, `daemon.odin`.

---

## Task 7: Update `ops_write.odin` — `_slot_dispatch` and write call sites

**Files:**
- Modify: `src/ops_write.odin`

- [ ] **Step 7.1: Update `_slot_dispatch` signature**

Change:
```odin
_slot_dispatch :: proc(slot: ^Shard_Slot, req: Request, allocator := context.allocator) -> string {
```
To:
```odin
_slot_dispatch :: proc(daemon: ^Node, slot: ^Shard_Slot, req: Request, allocator := context.allocator) -> string {
```

- [ ] **Step 7.2: Update `temp_node` init and write-back**

Remove `index = slot.index` from the `temp_node` struct literal.
Remove `slot.index = temp_node.index` from the write-back at the end.

- [ ] **Step 7.3: Route `"query"` case to daemon**

Change the `"query"` case from:
```odin
case "query":
    result = _op_query(&temp_node, req, allocator)
```
To:
```odin
case "query":
    result = _op_query(daemon, req, allocator)
```

- [ ] **Step 7.4: Add `index_persist(daemon)` after mutating ops**

`_op_is_mutating` already exists in `ops_write.odin` (line 290) — use it directly.

After the switch/case block, before the write-back of `slot.blob`, add:

```odin
// Persist index if op was mutating
if _op_is_mutating(req.op) {
    index_persist(daemon)
}
```

- [ ] **Step 7.5: Update `_slot_dispatch` callers**

Find all calls to `_slot_dispatch` in `ops_write.odin` and `_op_route_to_slot` and add `node` as the first argument:
```odin
// Before:
result := _slot_dispatch(slot, req, allocator)
// After:
result := _slot_dispatch(node, slot, req, allocator)
```

- [ ] **Step 7.6: Update `_slot_drain_write_queue` signature**

Change:
```odin
_slot_drain_write_queue :: proc(slot: ^Shard_Slot, temp_node: ^Node) {
```
To:
```odin
_slot_drain_write_queue :: proc(daemon: ^Node, slot: ^Shard_Slot, temp_node: ^Node) {
```

Inside, after draining all queued writes, add `index_persist(daemon)` once.
Update all callers to pass `node` as first argument.

- [ ] **Step 7.7: Update `_op_remember` — index call**

Replace the existing `index_update_shard(node, req.name)` call (which currently calls the old proc in `embed.odin`) — it now calls the new proc in `index.odin`. No signature change needed; the new `index_update_shard` has the same name and signature.

- [ ] **Step 7.8: Update gate sync calls**

All `index_update_shard(node, entry.name)` calls in `ops_write.odin` now point to the new proc in `index.odin`. No signature changes needed — verify they compile.

- [ ] **Step 7.9: Build check**

```bash
just test-build
```
Expected: `ops_write.odin` errors resolved.

---

## Task 8: Update `ops_read.odin` — delete `_slot_build_index`

**Files:**
- Modify: `src/ops_read.odin`

- [ ] **Step 8.1: Delete `_slot_build_index`**

Find and delete the `_slot_build_index` proc entirely:
```odin
_slot_build_index :: proc(slot: ^Shard_Slot) {
    build_search_index(&slot.index, slot.blob, slot.master, fmt.tprintf("daemon/%s", slot.name))
}
```

- [ ] **Step 8.2: Remove all calls to `_slot_build_index`**

Search for all call sites of `_slot_build_index` in `ops_read.odin` and delete them. The index is now built/updated via `index_update_shard` when a slot is first loaded — that call already exists in `_slot_load` via `index_update_shard`. Verify there are no remaining references.

- [ ] **Step 8.3: Build check**

```bash
just test-build
```
Expected: `ops_read.odin` errors resolved.

---

## Task 9: Update `protocol.odin` — write/update/delete/compact/query call sites

**Files:**
- Modify: `src/protocol.odin`

- [ ] **Step 9.1: Update `_op_write`**

Replace:
```odin
entry := Search_Entry {
    id          = id,
    description = strings.clone(req.description),
    text_hash   = fnv_hash(req.description),
}
if embed_ready() {
    emb, emb_ok := embed_text(req.description, context.temp_allocator)
    if emb_ok {
        stored := make([]f32, len(emb))
        copy(stored, emb)
        entry.embedding = stored
    }
}
append(&node.index, entry)
```
With:
```odin
index_add_thought(node, node.name, id, req.description)
```

Note: `index_persist` is called at end of `_slot_dispatch` — not needed here.
For standalone node path (non-daemon), add `index_persist(node)` after `index_add_thought`.

- [ ] **Step 9.2: Update `_op_update`**

Replace the `for &entry in node.index` block that updates the search entry with:
```odin
index_update_thought(node, node.name, id, new_desc)
```

For standalone node path, add `index_persist(node)` after.

- [ ] **Step 9.3: Update `_op_delete`**

Replace:
```odin
for i := 0; i < len(node.index); i += 1 {
    if node.index[i].id == id {
        delete(node.index[i].embedding)
        ordered_remove(&node.index, i)
        break
    }
}
```
With:
```odin
index_remove_thought(node, node.name, id)
```

For standalone node path, add `index_persist(node)` after.

- [ ] **Step 9.4: Update `_op_query`**

Replace:
```odin
// fulltext path:
excerpts := fulltext_search(node.index[:], node.blob, ...)
// regular path:
hits := search_query(node.index[:], req.query, context.temp_allocator)
```
With:
```odin
// fulltext path — find Indexed_Shard for this node's own shard:
se := _find_indexed_shard(node, node.name)
thoughts_for_ft: []Indexed_Thought
if se != nil do thoughts_for_ft = se.thoughts[:]
excerpts := fulltext_search(thoughts_for_ft, node.blob, node.blob.master, shard_name, req.query, ctx_lines, min_score, allocator)

// regular path:
se := _find_indexed_shard(node, node.name)
if se == nil do return _err_response("shard not indexed", allocator)
hits := index_query_thoughts(se, req.query)
```

Then update the hit processing loop: `h.id` and `h.score` remain the same field names (`Index_Result` has same fields as old `Search_Result`).

- [ ] **Step 9.5: Update `_merge_revision_chain`**

Find the section that removes old index entries and appends the merged entry.
Replace the `for i := 0...node.index` removal loop with `index_remove_thought(node, node.name, cid)` for each removed chain member.
Replace the `append(&node.index, entry)` with `index_add_thought(node, node.name, merged_id, merged_description)`.

- [ ] **Step 9.6: Build check**

```bash
just test-build
```
Expected: `protocol.odin` errors resolved.

---

## Task 10: Update `ops_query.odin` — global query and traverse

**Files:**
- Modify: `src/ops_query.odin`

- [ ] **Step 10.1: Update `_op_global_query` — replace speculative loading with index lookup**

Find the block that:
1. Uses `index_query(node, req.query, ...)` for vec_index cosine
2. Falls back to `_score_gates` for gate scoring
3. Loads each candidate slot and calls `search_query(slot.index[:], ...)`

Replace with:

```odin
// Get ranked shards from unified index
candidates := index_query_shards(node, req.query, max_total * 2)

// Fallback: if no index results, use gate scoring
if len(candidates) == 0 {
    q_tokens := _tokenize(req.query, context.temp_allocator)
    for entry in node.registry {
        if entry.name == DAEMON_NAME do continue
        gs := _score_gates(entry, q_tokens)
        if gs.score >= threshold {
            append(&gate_candidates, _Scored_Shard{name = gs.name, score = gs.score})
        }
    }
    // ... use gate_candidates
}

// For each candidate shard, get thought hits from index
for c in candidates {
    if c.score < threshold do continue
    se := _find_indexed_shard(node, c.name)
    if se == nil do continue

    hits := index_query_thoughts(se, req.query)
    if len(hits) == 0 do continue

    // NOW load slot — only for shards with actual thought hits
    entry_ptr := _find_registry_entry(node, c.name)
    if entry_ptr == nil do continue
    slot := _slot_get_or_create(node, entry_ptr)
    if !slot.loaded {
        key_hex := _access_resolve_key(c.name)
        if !_slot_load(slot, key_hex) do continue
    }
    if !slot.key_set do continue
    slot.last_access = time.now()

    count := 0
    for h in hits {
        if count >= limit_per_shard do break
        if len(wire) >= max_total do break
        thought, found := blob_get(&slot.blob, h.id)
        if !found do continue
        pt, err := thought_decrypt(thought, slot.master, allocator)
        if err != .None do continue
        // ... build wire result with composite score
    }
}
```

- [ ] **Step 10.2: Update fulltext path in `_op_global_query`**

Find the `req.mode == "fulltext"` block. It calls `_slot_build_index(slot)` before `fulltext_search(slot.index[:], ...)`. Replace with:

```odin
// Get thought index from shard_index instead of building slot.index
se := _find_indexed_shard(node, c.name)
thoughts_for_ft: []Indexed_Thought
if se != nil do thoughts_for_ft = se.thoughts[:]
excerpts := fulltext_search(thoughts_for_ft, slot.blob, slot.master, c.name, req.query, ctx_lines, min_score, allocator)
```

Remove the `_slot_build_index(slot)` call and `slot.index` reference.

- [ ] **Step 10.3: Update `_op_traverse` shard routing**

`_traverse_layer0` uses `index_query(node, query, ...)` from `embed.odin`. Replace with `index_query_shards(node, query, max_branches)`. Results are `[]Index_Shard_Result` instead of `[]Vector_Result` — update the iteration accordingly (`.name` and `.score` fields are the same names).

- [ ] **Step 10.4: Remove remaining `slot.index` references**

Search `ops_query.odin` for any remaining `slot.index` or `_slot_build_index` references and remove them.

- [ ] **Step 10.5: Build check**

```bash
just test-build
```
Expected: `ops_query.odin` errors resolved.

---

## Task 11: Update `ops_events.odin` and `daemon.odin`

**Files:**
- Modify: `src/ops_events.odin`
- Modify: `src/daemon.odin`

- [ ] **Step 11.1: Update `_op_rollback` in `ops_events.odin`**

Find the `temp_node` construction in `_op_rollback`:
```odin
temp_node := Node {
    name           = slot.name,
    blob           = slot.blob,
    index          = slot.index,
    pending_alerts = slot.pending_alerts,
}
_slot_clear_lock(slot)
_slot_drain_write_queue(slot, &temp_node)
slot.blob = temp_node.blob
slot.index = temp_node.index
slot.pending_alerts = temp_node.pending_alerts
```

Replace with:
```odin
temp_node := Node {
    name           = slot.name,
    blob           = slot.blob,
    pending_alerts = slot.pending_alerts,
}
_slot_clear_lock(slot)
_slot_drain_write_queue(node, slot, &temp_node)
slot.blob = temp_node.blob
slot.pending_alerts = temp_node.pending_alerts
```

Note: `_op_rollback` must receive `node ^Node` — check if it already does and add it if not.

- [ ] **Step 11.2: Update `daemon_evict_idle` in `daemon.odin`**

Find the `temp_node` construction in `daemon_evict_idle`:
```odin
temp_node := Node {
    name           = slot.name,
    blob           = slot.blob,
    index          = slot.index,
    pending_alerts = slot.pending_alerts,
}
Ops.slot_drain_write_queue(slot, &temp_node)
slot.blob = temp_node.blob
slot.index = temp_node.index
slot.pending_alerts = temp_node.pending_alerts
```

Replace with:
```odin
temp_node := Node {
    name           = slot.name,
    blob           = slot.blob,
    pending_alerts = slot.pending_alerts,
}
Ops.slot_drain_write_queue(node, slot, &temp_node)
slot.blob = temp_node.blob
slot.pending_alerts = temp_node.pending_alerts
```

Also in the eviction path, remove:
```odin
for &entry in slot.index do delete(entry.embedding)
clear(&slot.index)
```

Slot eviction no longer manages any index state — the index lives on the daemon node, not the slot.

- [ ] **Step 11.3: Build check**

```bash
just test-build
```
Expected: clean build. Zero errors.

---

## Task 12: Update the unit test

**Files:**
- Modify: `tests/unit/test_query.odin`

- [ ] **Step 12.1: Replace old test with new one**

Replace the existing `test_search_query_empty_index` test:

```odin
package shard_unit_test

import "core:testing"
import shard "shard:."

// Confirms index_query_thoughts returns empty results for an empty shard entry.
@(test)
test_index_query_thoughts_empty :: proc(t: ^testing.T) {
    se := shard.Indexed_Shard{
        name    = "test",
        thoughts = make([dynamic]shard.Indexed_Thought),
    }
    results := shard.index_query_thoughts(&se, "anything")
    testing.expect_value(t, len(results), 0)
    delete(se.thoughts)
}

// Confirms index_query_thoughts returns a match on keyword when no embeddings.
@(test)
test_index_query_thoughts_keyword :: proc(t: ^testing.T) {
    te := shard.Indexed_Thought{
        description = "memory discipline in odin",
        text_hash   = shard.fnv_hash("memory discipline in odin"),
    }
    se := shard.Indexed_Shard{
        name    = "test",
        thoughts = make([dynamic]shard.Indexed_Thought),
    }
    append(&se.thoughts, te)

    results := shard.index_query_thoughts(&se, "memory")
    testing.expect(t, len(results) > 0, "expected at least one result")
    if len(results) > 0 {
        testing.expect(t, results[0].score > 0, "expected positive score")
    }

    delete(se.thoughts[0].description)
    delete(se.thoughts)
}
```

- [ ] **Step 12.2: Run tests**

```bash
just test
```
Expected: all tests pass.

---

## Task 13: Full build and test

- [ ] **Step 13.1: Full build**

```bash
just test-build
```
Expected: clean build, zero errors, zero warnings.

- [ ] **Step 13.2: Run all tests**

```bash
just test
```
Expected: all tests pass.

- [ ] **Step 13.3: Smoke test — start daemon and run a query**

```bash
shard daemon &
sleep 1
shard mcp  # or: echo '{"op":"global_query","query":"test"}' | shard connect digest
```
Expected: daemon starts, query returns results (or empty results if no shards). No panics or crashes.

- [ ] **Step 13.4: Verify `.shards/.index` created, `.shards/.vec_index` absent**

```bash
ls .shards/
```
Expected: `.index` present, `.vec_index` absent.

- [ ] **Step 13.5: Commit**

```bash
git add src/index.odin src/embed.odin src/types.odin src/protocol.odin src/ops_write.odin src/ops_read.odin src/ops_query.odin src/ops_events.odin src/node.odin src/daemon.odin tests/unit/test_query.odin
git rm src/search.odin
git commit -m "refactor: replace vec_index + Search_Entry[] with unified Shard_Index

- New index.odin owns all search logic: two-level cosine, keyword fallback,
  fulltext search, scoring, tokenization, persistence to .shards/.index
- Deleted search.odin entirely
- Stripped embed.odin to embedding + cosine only
- Removed Search_Entry, Search_Result, Vector_Index, Vector_Entry, Vector_Result
- Added Indexed_Thought, Indexed_Shard, Shard_Index, Index_Result, Index_Shard_Result
- Cross-shard query no longer loads slots speculatively
- .shards/.vec_index superseded by .shards/.index"
```

---

