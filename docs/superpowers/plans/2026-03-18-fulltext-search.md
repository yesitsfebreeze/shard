# Full-text Search Mode Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend `shard_query` with `mode: "fulltext"` that gate-filters shards first, then decrypts and searches thought content bodies, returning ranked windowed line excerpts.

**Architecture:** Add `fulltext_search` proc to `search.odin` that takes the in-memory description index for a fast pre-pass and the full blob for content decryption. Branch on `req.mode == "fulltext"` in both the global (`_op_global_query`) and single-shard (`_op_query`) paths. New config keys `FULLTEXT_CONTEXT_LINES` and `FULLTEXT_MIN_SCORE` set deployment defaults; `context_lines` in the request overrides per-call.

**Tech Stack:** Odin, existing `thought_decrypt`, `_tokenize`, `_stem` from `search.odin`, `blob_get` from `blob.odin`.

**Spec:** `docs/superpowers/specs/2026-03-18-fulltext-search-design.md`

**Build commands:**
- `just test-build` — build only (fast check)
- `just test` — run all tests
- `odin test src/query/tests/` — run query-specific tests

---

## File Map

| File | What changes |
|---|---|
| `src/types.odin` | Add `Fulltext_Excerpt` struct; add `context_lines: int` to `Request`; add `fulltext_results: []Fulltext_Excerpt` and `mode: string` to `Response` |
| `src/config.odin` | Add `fulltext_context_lines: int` and `fulltext_min_score: f32` to `Shard_Config` and `DEFAULT_CONFIG`; parse `FULLTEXT_CONTEXT_LINES` / `FULLTEXT_MIN_SCORE` in config switch |
| `src/default.config` | Add commented-out default entries for the two new keys |
| `src/search.odin` | Add `fulltext_search` proc |
| `src/ops_query.odin` | Branch on `mode == "fulltext"` in `_op_global_query` after gate filter |
| `src/protocol.odin` | Branch on `mode == "fulltext"` in `_op_query` |
| `src/markdown.odin` | Parse `context_lines` in both YAML (`md_parse_request`) and JSON (`md_parse_request_json`) paths; marshal `fulltext_results` and `mode` in `md_marshal_response_json` |
| `src/mcp_tools.odin` | Forward `mode` and `context_lines` from args in both JSON builder paths in `_tool_query` |
| `src/mcp.odin` | Update `shard_query` tool schema string with `mode` and `context_lines` params |
| `src/query/tests/query_test.odin` | Add real tests for `fulltext_search` logic |

---

## Task 1: Data structures — types.odin

**Files:**
- Modify: `src/types.odin`

- [ ] **Step 1: Add `Fulltext_Excerpt` struct**

Open `src/types.odin`. After the `Wire_Result` struct (around line 341), add:

```odin
Fulltext_Excerpt :: struct {
    shard:       string,
    id:          string, // bare thought hex ID — NOT "shard/id" compound format
    description: string,
    score:       f32,
    excerpt:     string, // windowed lines; hit lines prefixed with ">>> "
}
```

- [ ] **Step 2: Add `context_lines` to `Request`**

In `src/types.odin`, find the `Request` struct. After the `max_bytes: int` field (last field, around line 258), add:

```odin
// fulltext search fields
context_lines: int, // lines above/below each hit (fulltext mode, 0 = use config default)
```

- [ ] **Step 3: Add `fulltext_results` and `mode` to `Response`**

In `src/types.odin`, find the `Response` struct. First check: `mode: string` may already exist on `Response` (used by compact ops). If it is already present, add only `fulltext_results`. If it is absent, add both. After the `suggestions` field (last field, around line 306), add:

```odin
// fulltext search fields
fulltext_results: []Fulltext_Excerpt, // populated when mode == "fulltext"
// mode: string — add only if not already present on Response
mode: string, // echoed from request (e.g. "fulltext")
```

- [ ] **Step 4: Build to verify no compile errors**

```
just test-build
```

Expected: clean build, no errors.

- [ ] **Step 5: Commit**

```
git add src/types.odin
git commit -m "feat: add Fulltext_Excerpt, context_lines, fulltext_results to types"
```

---

## Task 2: Config — config.odin + default.config

**Files:**
- Modify: `src/config.odin`
- Modify: `src/default.config`

- [ ] **Step 1: Add fields to `Shard_Config`**

In `src/config.odin`, find `Shard_Config` struct. After the `cache_compact_threshold` field, add:

```odin
// Fulltext search
fulltext_context_lines: int, // lines above/below each hit (default 3)
fulltext_min_score:     f32, // drop excerpts below this score (default 0.10)
```

- [ ] **Step 2: Add defaults to `DEFAULT_CONFIG`**

In `src/config.odin`, find `DEFAULT_CONFIG`. After `cache_compact_threshold = 10,` add:

```odin
fulltext_context_lines = 3,
fulltext_min_score     = 0.10,
```

- [ ] **Step 3: Add parse cases to config switch**

In `src/config.odin`, find the `switch key` block. After the `case "CACHE_COMPACT_THRESHOLD":` block, add:

```odin
// Fulltext search
case "FULLTEXT_CONTEXT_LINES":
    _global_config.fulltext_context_lines = _parse_int(val, 3)
case "FULLTEXT_MIN_SCORE":
    _global_config.fulltext_min_score = f32(_parse_float(val, 0.10))
```

- [ ] **Step 4: Update default.config**

In `src/default.config`, after the `# --- Auto-compaction ---` block, add:

```
# --- Fulltext search ---
# FULLTEXT_CONTEXT_LINES 3    (lines above/below each hit)
# FULLTEXT_MIN_SCORE     0.10 (drop excerpts below this score)
```

- [ ] **Step 5: Build to verify**

```
just test-build
```

Expected: clean build.

- [ ] **Step 6: Commit**

```
git add src/config.odin src/default.config
git commit -m "feat: add fulltext_context_lines and fulltext_min_score config keys"
```

---

## Task 3: Core search logic — search.odin

**Files:**
- Modify: `src/search.odin`
- Modify: `src/query/tests/query_test.odin`

**Note on testing:** `_compute_windows` and `_fulltext_hit_density` are `@(private)` procs in `package shard`. They cannot be called from `package query_tests` (a separate sub-package). Tests for these helpers are written directly in `src/search.odin` using `@(test)` blocks in the same package. The `src/query/tests/query_test.odin` file is updated to a clean integration stub only.

**Note on nested procs:** Odin does not support proc literals defined inside proc bodies. The `_search_thoughts` helper must be a package-level `@(private)` proc, defined before `fulltext_search` in the file.

- [ ] **Step 1: Add helper types, procs, and `fulltext_search` to search.odin**

Open `src/search.odin`. At the end of the file, add the following blocks **in order**:

```odin
// =============================================================================
// Full-text search — windowed excerpt extraction
// =============================================================================

// _Line_Window represents a merged range of lines to include in an excerpt.
@(private)
_Line_Window :: struct {
    start: int,
    end:   int,
}

// _compute_windows takes hit line indices, total line count, and context_lines
// and returns merged non-overlapping windows clamped to [0, lines_count-1].
@(private)
_compute_windows :: proc(
    hit_indices:   []int,
    lines_count:   int,
    context_lines: int,
    allocator      := context.allocator,
) -> []_Line_Window {
    if len(hit_indices) == 0 || lines_count == 0 do return nil

    windows := make([dynamic]_Line_Window, allocator)

    for hi in hit_indices {
        s := max(0, hi - context_lines)
        e := min(lines_count - 1, hi + context_lines)
        if len(windows) > 0 && s <= windows[len(windows) - 1].end + 1 {
            // Overlapping or adjacent — extend last window
            if e > windows[len(windows) - 1].end {
                windows[len(windows) - 1].end = e
            }
        } else {
            append(&windows, _Line_Window{start = s, end = e})
        }
    }

    return windows[:]
}

// _fulltext_hit_density scores a thought by hit-to-total-line ratio.
@(private)
_fulltext_hit_density :: proc(hit_count: int, total_lines: int) -> f32 {
    if total_lines == 0 do return 0
    return f32(hit_count) / f32(total_lines)
}

// _fulltext_search_thoughts searches one []Thought slice and appends matching
// Fulltext_Excerpt entries to results. Called by fulltext_search for both
// processed and unprocessed thought lists.
//
// index: in-memory description pre-pass entries (may be shorter than thoughts
//        for unprocessed — pass empty slice to skip pre-pass).
@(private)
_fulltext_search_thoughts :: proc(
    thoughts:      []Thought,
    index:         []Search_Entry,
    master:        Master_Key,
    shard_name:    string,
    q_tokens:      []string,
    context_lines: int,
    min_score:     f32,
    results:       ^[dynamic]Fulltext_Excerpt,
    allocator:     mem.Allocator,
) {
    for thought, ti in thoughts {
        // Pre-pass: check description in index (no decrypt needed)
        has_desc_hit := false
        if ti < len(index) {
            desc_lower := strings.to_lower(index[ti].description, context.temp_allocator)
            for qt in q_tokens {
                if strings.contains(desc_lower, qt) {
                    has_desc_hit = true
                    break
                }
            }
            // desc_lower freed by free_all at end of thought loop
        }

        // Decrypt
        pt, err := thought_decrypt(thought, master, context.temp_allocator)
        if err != .None {
            free_all(context.temp_allocator)
            continue
        }

        lines := strings.split(pt.content, "\n", context.temp_allocator)
        hit_indices := make([dynamic]int, context.temp_allocator)

        for line, li in lines {
            line_lower := strings.to_lower(line, context.temp_allocator)
            for qt in q_tokens {
                if strings.contains(line_lower, qt) {
                    append(&hit_indices, li)
                    break
                }
            }
        }

        // If no content hits and no description hit, skip
        if len(hit_indices) == 0 && !has_desc_hit {
            free_all(context.temp_allocator)
            continue
        }

        if len(hit_indices) > 0 {
            score := _fulltext_hit_density(len(hit_indices), len(lines))
            if score >= min_score {
                windows := _compute_windows(
                    hit_indices[:],
                    len(lines),
                    context_lines,
                    context.temp_allocator,
                )

                thought_hex := id_to_hex(thought.id, context.temp_allocator)

                for w in windows {
                    excerpt_b := strings.builder_make(context.temp_allocator)
                    for li := w.start; li <= w.end; li += 1 {
                        is_hit := false
                        for hi in hit_indices {
                            if hi == li {is_hit = true; break}
                        }
                        if is_hit do strings.write_string(&excerpt_b, ">>> ")
                        strings.write_string(&excerpt_b, lines[li])
                        if li < w.end do strings.write_string(&excerpt_b, "\n")
                    }

                    append(
                        results,
                        Fulltext_Excerpt {
                            shard       = strings.clone(shard_name, allocator),
                            id          = strings.clone(thought_hex, allocator),
                            description = strings.clone(pt.description, allocator),
                            score       = score,
                            excerpt     = strings.clone(strings.to_string(excerpt_b), allocator),
                        },
                    )
                }
            }
        }

        free_all(context.temp_allocator)
    }
}

// fulltext_search decrypts all thoughts in a blob and returns windowed
// excerpts for those whose description or content match any query token.
//
// Memory contract:
//   - thought_decrypt is called with context.temp_allocator per thought.
//   - free_all(context.temp_allocator) is called after each thought.
//   - Only excerpt strings are cloned to `allocator` (persistent).
//   - Caller must free returned []Fulltext_Excerpt and all string fields.
fulltext_search :: proc(
    index:         []Search_Entry, // in-memory description index for pre-pass
    blob:          Blob,
    master:        Master_Key,
    shard_name:    string,
    query:         string,
    context_lines: int,
    min_score:     f32,
    allocator      := context.allocator,
) -> []Fulltext_Excerpt {
    q_tokens := _tokenize(query, context.temp_allocator)
    if len(q_tokens) == 0 do return nil

    results := make([dynamic]Fulltext_Excerpt, allocator)

    _fulltext_search_thoughts(
        blob.processed[:],
        index,
        master,
        shard_name,
        q_tokens,
        context_lines,
        min_score,
        &results,
        allocator,
    )
    // For unprocessed, pass empty index slice so pre-pass is skipped
    // (unprocessed thoughts do not have aligned index entries)
    empty_index: []Search_Entry
    _fulltext_search_thoughts(
        blob.unprocessed[:],
        empty_index,
        master,
        shard_name,
        q_tokens,
        context_lines,
        min_score,
        &results,
        allocator,
    )

    // Sort by score descending
    for i := 1; i < len(results); i += 1 {
        key := results[i]
        j := i - 1
        for j >= 0 && results[j].score < key.score {
            results[j + 1] = results[j]
            j -= 1
        }
        results[j + 1] = key
    }

    return results[:]
}

// =============================================================================
// Full-text search tests (in-package, @(private) helpers not accessible
// from sub-packages)
// =============================================================================

@(test)
_test_fulltext_window_merge_overlapping :: proc(t: ^testing.T) {
    // Lines 0-9, hits at 3 and 5 with context_lines=2
    // Window A: [1,5], Window B: [3,7] → merged: [1,7]
    // Note: _compute_windows returns []_Line_Window backed by temp_allocator —
    // no defer delete needed (temp_allocator freed at end of test by runner).
    hit_indices := [?]int{3, 5}
    windows := _compute_windows(hit_indices[:], 10, 2, context.temp_allocator)
    testing.expect_value(t, len(windows), 1)
    testing.expect_value(t, windows[0].start, 1)
    testing.expect_value(t, windows[0].end, 7)
}

@(test)
_test_fulltext_window_separate :: proc(t: ^testing.T) {
    // Hits at 2 and 17 in 20-line content, context_lines=2 → two windows
    hit_indices := [?]int{2, 17}
    windows := _compute_windows(hit_indices[:], 20, 2, context.temp_allocator)
    testing.expect_value(t, len(windows), 2)
    testing.expect_value(t, windows[0].start, 0)
    testing.expect_value(t, windows[0].end, 4)
    testing.expect_value(t, windows[1].start, 15)
    testing.expect_value(t, windows[1].end, 19)
}

@(test)
_test_fulltext_window_clamps_to_bounds :: proc(t: ^testing.T) {
    // Hit at line 0 with context_lines=3 — start must clamp to 0
    hit_indices := [?]int{0}
    windows := _compute_windows(hit_indices[:], 5, 3, context.temp_allocator)
    testing.expect_value(t, len(windows), 1)
    testing.expect_value(t, windows[0].start, 0)
    testing.expect_value(t, windows[0].end, 3)
}

@(test)
_test_fulltext_hit_density :: proc(t: ^testing.T) {
    score := _fulltext_hit_density(3, 10)
    testing.expect(t, score > 0.29 && score < 0.31, "expected ~0.3")
}
```

Also add `import "core:mem"` to the imports block at the top of `search.odin` (needed for `mem.Allocator` in `_fulltext_search_thoughts`). Also add `import "core:testing"` if not already present (needed for the `@(test)` procs).

- [ ] **Step 2: Update query_test.odin to a clean stub**

Open `src/query/tests/query_test.odin`. Replace its contents with:

```odin
package query_tests

import "core:testing"

// Full-text search helpers (_compute_windows, _fulltext_hit_density) are
// @(private) in package shard and tested directly in src/search.odin.
// End-to-end dispatch tests require a running daemon; add those separately.

@(test)
test_package_compiles :: proc(t: ^testing.T) {
    testing.expect(t, true, "query_tests package compiles")
}
```

- [ ] **Step 3: Run all tests**

```
just test
```

Expected: all tests pass including the new `_test_fulltext_window_*` and `_test_fulltext_hit_density` tests from `src/search.odin`.

- [ ] **Step 4: Build to verify**

```
just test-build
```

Expected: clean build.

- [ ] **Step 5: Commit**

```
git add src/search.odin src/query/tests/query_test.odin
git commit -m "feat: add fulltext_search with windowed excerpt extraction and in-package tests"
```

---

## Task 4: Wire format — markdown.odin

**Files:**
- Modify: `src/markdown.odin`

- [ ] **Step 1: Parse `context_lines` in YAML path**

In `src/markdown.odin`, find `md_parse_request`. In the `switch key` block, after `case "max_bytes":`, add:

```odin
case "context_lines":
    req.context_lines, _ = strconv.parse_int(val)
```

- [ ] **Step 2: Parse `context_lines` in JSON path**

In `src/markdown.odin`, find `md_parse_request_json`. Note: `req.mode = md_json_get_str(obj, "mode")` is already present — do not add it again. After `req.max_bytes = md_json_get_int(obj, "max_bytes")`, add only:

```odin
req.context_lines = md_json_get_int(obj, "context_lines")
```

- [ ] **Step 3: Verify `write_json_field` escapes strings**

Before writing the marshalling code, check `write_json_field` in `src/markdown.odin`. Confirm it escapes special characters (newlines, backslashes, quotes). The `excerpt` field contains `\n` and `>>> ` — if `write_json_field` does not escape `\n` → `\\n`, the JSON output will be malformed. If it doesn't escape, use a json-safe string builder manually for `excerpt` (replace `\n` with `\\n` before writing).

- [ ] **Step 4: Marshal `mode` and `fulltext_results` in JSON response**

In `src/markdown.odin`, find `md_marshal_response_json`. After the `if resp.total_results != 0` block (around line 621), add:

```odin
if resp.mode != "" {
    strings.write_string(&b, ",")
    write_json_field(&b, "mode", resp.mode)
}

if len(resp.fulltext_results) > 0 {
    strings.write_string(&b, `,"fulltext_results":[`)
    for r, i in resp.fulltext_results {
        if i > 0 do strings.write_string(&b, ",")
        strings.write_string(&b, "{")
        write_json_field(&b, "shard", r.shard)
        strings.write_string(&b, ",")
        write_json_field(&b, "id", r.id)
        strings.write_string(&b, `,"score":`)
        fmt.sbprintf(&b, "%v", r.score)
        if r.description != "" {
            strings.write_string(&b, ",")
            write_json_field(&b, "description", r.description)
        }
        if r.excerpt != "" {
            strings.write_string(&b, ",")
            write_json_field(&b, "excerpt", r.excerpt)
        }
        strings.write_string(&b, "}")
    }
    strings.write_string(&b, "]")
}
```

- [ ] **Step 5: Build to verify**

```
just test-build
```

Expected: clean build.

- [ ] **Step 6: Commit**

```
git add src/markdown.odin
git commit -m "feat: marshal fulltext_results and mode in JSON response; parse context_lines"
```

---

## Task 5: Global query path — ops_query.odin

**Files:**
- Modify: `src/ops_query.odin`

- [ ] **Step 1: Add fulltext branch after gate filter in `_op_global_query`**

In `src/ops_query.odin`, find `_op_global_query`. Locate the section after `candidates` is sorted and the per-shard loop begins (around line 320, the `wire := make(...)` line).

Add a fulltext branch **before** `wire := make(...)`:

```odin
// Fulltext mode: decrypt content bodies and return windowed excerpts
if req.mode == "fulltext" {
    cfg := config_get()
    ctx_lines := req.context_lines > 0 ? req.context_lines : cfg.fulltext_context_lines
    if ctx_lines <= 0 do ctx_lines = 3
    min_score := cfg.fulltext_min_score
    if min_score <= 0 do min_score = 0.10

    ft_results := make([dynamic]Fulltext_Excerpt, allocator)
    shards_searched := 0

    for c in candidates {
        entry_ptr := _find_registry_entry(node, c.name)
        if entry_ptr == nil do continue

        slot := _slot_get_or_create(node, entry_ptr)
        if !slot.loaded {
            key_hex := _access_resolve_key(c.name)
            if !_slot_load(slot, key_hex) do continue
        }
        if !slot.key_set {
            key_hex := _access_resolve_key(c.name)
            if key_hex != "" do _slot_set_key(slot, key_hex)
        }
        if !slot.key_set do continue

        slot.last_access = time.now()

        // Build index if not yet populated (mirrors existing _op_global_query pattern)
        if len(slot.index) == 0 &&
           (len(slot.blob.processed) > 0 || len(slot.blob.unprocessed) > 0) {
            _slot_build_index(slot)
        }

        excerpts := fulltext_search(
            slot.index[:],
            slot.blob,
            slot.master,
            c.name,
            req.query,
            ctx_lines,
            min_score,
            allocator,
        )
        for e in excerpts {
            append(&ft_results, e)
        }
        shards_searched += 1
    }

    // Sort all excerpts across shards by score descending
    for i := 1; i < len(ft_results); i += 1 {
        key := ft_results[i]
        j := i - 1
        for j >= 0 && ft_results[j].score < key.score {
            ft_results[j + 1] = ft_results[j]
            j -= 1
        }
        ft_results[j + 1] = key
    }

    return _marshal(
        Response {
            status           = "ok",
            mode             = "fulltext",
            fulltext_results = ft_results[:],
            shards_searched  = shards_searched,
            total_results    = len(ft_results),
        },
        allocator,
    )
}
```

- [ ] **Step 2: Build to verify**

```
just test-build
```

Expected: clean build.

- [ ] **Step 3: Commit**

```
git add src/ops_query.odin
git commit -m "feat: fulltext mode branch in _op_global_query"
```

---

## Task 6: Single-shard query path — protocol.odin

**Files:**
- Modify: `src/protocol.odin`

- [ ] **Step 1: Add fulltext branch to `_op_query`**

In `src/protocol.odin`, find `_op_query` (around line 459). After the initial guard `if req.query == "" do return _err_response(...)`, add:

```odin
// Fulltext mode: decrypt content bodies and return windowed excerpts
if req.mode == "fulltext" {
    cfg := config_get()
    ctx_lines := req.context_lines > 0 ? req.context_lines : cfg.fulltext_context_lines
    if ctx_lines <= 0 do ctx_lines = 3
    min_score := cfg.fulltext_min_score
    if min_score <= 0 do min_score = 0.10

    shard_name := node.blob.catalog.name != "" ? node.blob.catalog.name : node.name
    excerpts := fulltext_search(
        node.index[:],
        node.blob,
        node.blob.master,
        shard_name,
        req.query,
        ctx_lines,
        min_score,
        allocator,
    )
    return _marshal(
        Response {
            status           = "ok",
            mode             = "fulltext",
            fulltext_results = excerpts,
            total_results    = len(excerpts),
        },
        allocator,
    )
}
```

- [ ] **Step 2: Build to verify**

```
just test-build
```

Expected: clean build.

- [ ] **Step 3: Commit**

```
git add src/protocol.odin
git commit -m "feat: fulltext mode branch in _op_query (single-shard)"
```

---

## Task 7: MCP layer — mcp_tools.odin + mcp.odin

**Files:**
- Modify: `src/mcp_tools.odin`
- Modify: `src/mcp.odin`

- [ ] **Step 1: Forward `mode` and `context_lines` in `_tool_query`**

In `src/mcp_tools.odin`, find `_tool_query` (line 128). After the existing reads for `format`, `threshold_val`, `layer_val`, add:

```odin
mode_val        := md_json_get_str(args, "mode")
context_lines_val := md_json_get_int(args, "context_lines")
```

In the **single-shard builder** (`b2`, around line 184 where `format` is conditionally appended), add **before** `strings.write_string(&b2, "}")`:

```odin
if mode_val != "" do fmt.sbprintf(&b2, `,\"mode\":\"%s\"`, json_escape(mode_val))
if context_lines_val > 0 do fmt.sbprintf(&b2, `,"context_lines":%d`, context_lines_val)
```

In the **global builder** (`b`, around line 203 where `threshold` is conditionally appended), add **before** `strings.write_string(&b, "}")`:

```odin
if mode_val != "" do fmt.sbprintf(&b, `,\"mode\":\"%s\"`, json_escape(mode_val))
if context_lines_val > 0 do fmt.sbprintf(&b, `,"context_lines":%d`, context_lines_val)
```

- [ ] **Step 2: Update `shard_query` tool schema in mcp.odin**

In `src/mcp.odin`, find the tool definition with `name = "shard_query"` (around line 119). Update the `schema` string to add `mode` and `context_lines` to the properties object. The current schema ends with `...,"depth":{"type":"integer",...}},"required":["query"]}`. Change it to:

```
...,"depth":{"type":"integer","description":"Advanced: link-following depth for wikilink traversal (0 = flat)"},"mode":{"type":"string","description":"Search mode: omit for default scored results, 'fulltext' for windowed content body search","enum":["fulltext"]},"context_lines":{"type":"integer","description":"Lines of context above/below each hit in fulltext mode (0 = use config default)"}},"required":["query"]}
```

- [ ] **Step 3: Build to verify**

```
just test-build
```

Expected: clean build.

- [ ] **Step 4: Run all tests**

```
just test
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```
git add src/mcp_tools.odin src/mcp.odin
git commit -m "feat: forward mode and context_lines in shard_query MCP tool"
```

---

## Task 8: Final verification

- [ ] **Step 1: Run full test suite**

```
just test
```

Expected: all tests pass, no failures.

- [ ] **Step 2: Run test build**

```
just test-build
```

Expected: clean build.

- [ ] **Step 3: Smoke test the pipeline mentally**

Verify the full chain:
1. MCP agent sends `shard_query(query="routing", mode="fulltext", context_lines=5)`
2. `_tool_query` builds `{"op":"global_query","query":"routing","mode":"fulltext","context_lines":5,"key":"..."}`
3. Daemon routes to `_op_global_query`
4. Gate filter selects relevant shards
5. Fulltext branch calls `fulltext_search` per shard
6. Results collected, sorted, returned as `fulltext_results` JSON array
7. Each result has `shard`, `id`, `description`, `score`, `excerpt` with `>>> ` marked hit lines

- [ ] **Step 4: Final commit if any loose ends**

```
git add -A
git commit -m "feat: fulltext search mode complete"
```
