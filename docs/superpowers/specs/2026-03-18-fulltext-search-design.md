# Full-text Search Mode for `shard_query`

**Date:** 2026-03-18  
**Status:** Approved  
**Scope:** Extend `shard_query` with a `fulltext` mode that gates on relevant shards first, then searches decrypted thought content bodies, returning ranked windowed excerpts.

---

## Problem

Current search in Shard indexes only thought **descriptions** — the short plaintext summary of each thought. The full content body is encrypted and never searched. This means an agent querying for a specific term that appears in the body of a thought (but not its description) gets no result.

RAG pipelines solve this by chunking and embedding full document content. Shard can do the same — but better — by using its existing gate routing to pre-filter to relevant shards before doing any full-text scan, avoiding the O(n) cost of searching everything.

---

## Design

### Pipeline

```
shard_query(query, mode: "fulltext", context_lines: 5)
        │
        ▼
1. Gate filter (existing logic in _op_global_query)
   Score all shards by gates + catalog match
   Drop shards below threshold
        │
        ▼
2. Decrypt & search (new — fulltext_search in search.odin)
   For each passing shard:
     Tokenize query into tokens []string
     For each thought in slot.index (plaintext descriptions, already in memory):
       Pre-pass: check slot.index[i].description for any token match (no decrypt)
       If description pre-pass passes:
         Decrypt thought using thought_decrypt with context.temp_allocator
         Search pt.content body for token matches
         If ≥1 hit found:
           Split pt.content on \n → lines []string
           Find all hit line indices
           Collect ±context_lines around each hit
           Merge overlapping windows
           Clone selected excerpt lines with `allocator` (persistent)
           Score by hit density (hit_line_count / total_lines)
         Free_all(context.temp_allocator) after each thought
        │
        ▼
3. Rank & filter (new)
   Collect all Fulltext_Excerpt entries across all shards
   Sort by score descending
   Drop entries below resolved min_score threshold
        │
        ▼
4. Return enriched result list (marshalled as JSON in fulltext_results field)
```

Multiple disjoint hit windows within one thought produce multiple `Fulltext_Excerpt` entries (same `id`, different `excerpt`). Overlapping windows within one thought are merged into a single excerpt block.

**Pre-pass note:** The pre-pass uses `slot.index[i].description` — plaintext strings already held in memory from the search index, no decryption required. The existing `_thought_matches_tokens` proc (which operates on a decrypted `Thought_Plaintext`) is NOT used for the pre-pass; it is a separate utility for post-decrypt matching and may be used inside `fulltext_search` for content body matching after decrypt.

**Temp allocator note:** `free_all(context.temp_allocator)` is called after processing each thought so that decrypt scratch space does not accumulate across a shard with many thoughts. The caller (`_op_global_query`) may also reset between shards. Only strings cloned to `allocator` persist.

---

## Config System

The existing config format uses flat `KEY value` pairs (no section headers). New fulltext config keys follow the same `UPPER_SNAKE_CASE` pattern and are added to `Shard_Config` and parsed in `config.odin`:

```
FULLTEXT_CONTEXT_LINES 3
FULLTEXT_MIN_SCORE 0.10
```

These are added to `Shard_Config` as:
```odin
fulltext_context_lines: int,   // default 3
fulltext_min_score:     f32,   // default 0.10
```

And to `DEFAULT_CONFIG` as:
```odin
fulltext_context_lines = 3,
fulltext_min_score     = 0.10,
```

**Precedence (lowest → highest):**
1. Hardcoded fallback in `DEFAULT_CONFIG` (`context_lines = 3`, `min_score = 0.10`)
2. `FULLTEXT_CONTEXT_LINES` / `FULLTEXT_MIN_SCORE` in `.shards/config`
3. Per-request `context_lines` param (caller override for that call only)

`min_score` is config-only — not overridable per-request. It is a deployment-level noise floor.

This pattern generalises to future modes: each adds its own flat config keys following the `<MODE>_<PARAM>` naming convention.

---

## Data Structures

### New `Fulltext_Excerpt` struct (`types.odin`)

```odin
Fulltext_Excerpt :: struct {
    shard:       string,  // shard name (standalone, not combined with id)
    id:          string,  // thought hex ID only (NOT "shard/id" format)
    description: string,
    score:       f32,
    excerpt:     string,  // windowed lines; hit lines prefixed with ">>> "
}
```

Note: `id` here is the bare thought hex ID, not the `"shard_name/hex_id"` compound format used by `Wire_Result` in cross-shard queries. The shard is carried separately in the `shard` field.

### `Request` changes (`types.odin`)

`mode: string` already exists on `Request` (used by compact ops for `"lossless"` / `"lossy"`). No new field needed — the new value `"fulltext"` is added as a valid mode for the query path. The dispatch in `_op_global_query` and `_op_query` branches on `req.mode == "fulltext"`. The compact dispatch in `_slot_dispatch` is unaffected because it never reaches those procs.

Add one new optional field:
- `context_lines: int` — per-request override for fulltext window size. `0` means "use config default" (`fulltext_context_lines`).

### `Response` changes (`types.odin`)

Add two new fields:
```odin
fulltext_results: []Fulltext_Excerpt,  // populated when mode == "fulltext"
mode:             string,              // echoed from request (e.g. "fulltext")
```

The existing `shards_searched: int` and `total_results: int` fields are already present on `Response` and are reused for fulltext responses.

---

## `fulltext_search` Proc Signature (`search.odin`)

```odin
fulltext_search :: proc(
    index:         []Search_Entry,   // slot.index — plaintext descriptions for pre-pass
    blob:          Blob,             // full blob for decrypting content bodies
    master:        Master_Key,
    shard_name:    string,
    query:         string,
    context_lines: int,
    min_score:     f32,
    allocator      := context.allocator,
) -> []Fulltext_Excerpt
```

**Memory contract:**
- `thought_decrypt` is called with `context.temp_allocator` for each thought.
- `free_all(context.temp_allocator)` is called after each thought is processed (hit or miss) so temp memory does not accumulate.
- Hit line strings selected for the excerpt are cloned with `allocator` before the temp allocator is reset.
- The returned `[]Fulltext_Excerpt` and all strings within (`shard`, `id`, `description`, `excerpt`) are allocated with `allocator`.
- The caller is responsible for freeing the returned slice and its string fields when done.
- The `index` parameter is used for the description pre-pass; `blob.processed` and `blob.unprocessed` supply the full thoughts for decryption.

---

## Wire Format

**Request (global — no shard param):**
```json
{
  "op": "global_query",
  "query": "gates routing",
  "mode": "fulltext",
  "context_lines": 5,
  "key": "<hex>"
}
```

**Request (named shard — single-shard fulltext):**
```json
{
  "op": "query",
  "name": "architecture",
  "key": "<hex>",
  "query": "gates routing",
  "mode": "fulltext",
  "context_lines": 5
}
```

**Response:**
```json
{
  "status": "ok",
  "mode": "fulltext",
  "fulltext_results": [
    {
      "shard": "architecture",
      "id": "abc123def456...",
      "description": "Gates — declarative routing signals",
      "score": 0.87,
      "excerpt": "Each shard declares what it wants.\n>>> Gates are evaluated before any content is read.\nThis avoids scanning irrelevant shards entirely."
    },
    {
      "shard": "decisions",
      "id": "789abc...",
      "description": "Vision — routing before reading",
      "score": 0.61,
      "excerpt": ">>> The routing table knows where knowledge belongs\nbefore any agent opens a shard."
    }
  ],
  "shards_searched": 4,
  "total_results": 6
}
```

Hit lines are prefixed with `>>> ` so the agent can see exactly what matched. Omitting `mode` in the request gives current behavior exactly.

---

## Scope: Global and Single-Shard

`mode: "fulltext"` works in both paths:

- **Global (no shard param):** `_tool_query` builds `op: "global_query"` → `_op_global_query` branches on `mode == "fulltext"` → calls `fulltext_search(slot.index[:], slot.blob, slot.master, ...)` per passing shard → merges and returns `fulltext_results`.
- **Single-shard (shard param given):** `_tool_query` builds `op: "query"` → `_op_query` in `protocol.odin` branches on `mode == "fulltext"` → calls `fulltext_search(node.index[:], node.blob, node.blob.master, ...)` directly (slot is already loaded by the daemon routing layer; `node.blob` and `node.blob.master` are used directly, no additional slot loading step).

Both paths return the same `fulltext_results` response shape.

---

## Code Changes

| File | Change |
|---|---|
| `src/types.odin` | Add `Fulltext_Excerpt` struct; add `context_lines: int` to `Request`; add `fulltext_results: []Fulltext_Excerpt` and `mode: string` to `Response` |
| `src/config.odin` | Add `fulltext_context_lines: int` and `fulltext_min_score: f32` to `Shard_Config` and `DEFAULT_CONFIG`; parse `FULLTEXT_CONTEXT_LINES` and `FULLTEXT_MIN_SCORE` keys in config parser |
| `src/search.odin` | Add `fulltext_search` proc (signature above): index pre-pass → decrypt → find hit lines → window → merge → score → `free_all(temp)` per thought → return `[]Fulltext_Excerpt` |
| `src/ops_query.odin` | In `_op_global_query`: after gate filter, check `req.mode == "fulltext"` → resolve `context_lines` (request > config > default) → call `fulltext_search` per shard → merge, sort, filter → set `resp.fulltext_results`, `resp.mode`, `resp.shards_searched`, `resp.total_results` |
| `src/protocol.odin` | In `_op_query`: check `req.mode == "fulltext"` → call `fulltext_search(node.index[:], node.blob, node.blob.master, ...)` → set `resp.fulltext_results`, `resp.mode` |
| `src/markdown.odin` | **JSON path** (`md_parse_request_json`): parse `"mode"` (already parsed) and `"context_lines"` → `req.context_lines`; marshal `resp.fulltext_results` array and `resp.mode` in `md_marshal_response_json`. **YAML path** (`md_parse_request`): add `case "context_lines": req.context_lines, _ = strconv.parse_int(val)` to the switch block; echo `mode` in `md_marshal_response` YAML output |
| `src/mcp_tools.odin` | In `_tool_query`: read `mode := md_json_get_str(args, "mode")` and `context_lines_val := md_json_get_int(args, "context_lines")`; in the **single-shard builder** (`b2`, around line 175): add `if mode != "" { fmt.sbprintf(&b2, ",\"mode\":\"%s\"", json_escape(mode)) }` and `if context_lines_val > 0 { fmt.sbprintf(&b2, ",\"context_lines\":%d", context_lines_val) }`; same pattern in the **global builder** (`b`, around line 194) |
| `src/mcp.odin` | Update `shard_query` tool schema JSON to add `"mode"` field (string, description: "Search mode: omit for default scored results, 'fulltext' for windowed content search") and `"context_lines"` field (integer, description: "Lines of context above/below each hit in fulltext mode (default from config)") |

No new files. No new protocol op. Fully backward compatible.

---

## Key Invariants

- Omitting `mode` in any request produces identical behavior to today. No regressions.
- Gate filtering always runs before any decryption in global fulltext mode. Full-text never scans shards the gate layer rejects.
- `context_lines: 0` in a request means "use config default" (`fulltext_context_lines`), not "zero lines of context."
- Multiple hits in one thought within `context_lines` of each other are merged into one excerpt block.
- Pre-pass uses `slot.index[i].description` (plaintext, in memory) — no decrypt for non-matching thoughts.
- `free_all(context.temp_allocator)` is called after each thought to prevent unbounded temp memory growth across multi-shard, many-thought scans.
- Only excerpt strings are cloned to the persistent allocator; all other decrypt scratch is temp.
- `mode: "fulltext"` on a compact op is never reached — compact dispatch exits before `_op_global_query` or the `_op_query` fulltext branch.
- `Fulltext_Excerpt.id` is a bare thought hex ID, not the `"shard/id"` compound format used by `Wire_Result`.

---

## What This Is Not

- Not a replacement for the existing description-based keyword/vector search (mode omitted = current behavior).
- Not a new MCP tool — `shard_query` is extended, not duplicated.
- Not per-shard configurable — mode defaults are global in `.shards/config`.
- `min_score` is not a per-request override — it is a deployment-level filter set in config.
