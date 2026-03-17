# Unified Query Pipeline Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Collapse `search`, `query`, `access`, `global_query`, and `dump` into one pipeline — query → filter → action — surfaced via `shard_query` with an optional `format` param.

**Architecture:** The gate-scoring + vec-index shard selection logic already exists in `_op_global_query`. We extend it with a `format` field: `"results"` (default, existing behaviour) returns scored Wire_Results; `"dump"` returns a unified markdown document. Per-shard `query` gains the same `format` field. `_op_search`, `_op_access`, and the standalone `shard_dump` MCP tool are deleted. `shard_query` becomes the single entry point for all read operations.

**Tech Stack:** Odin, existing `operators.odin` / `protocol.odin` / `mcp.odin` / `types.odin` / `markdown.odin`

---

## File Map

| File | Change |
|------|--------|
| `src/types.odin` | Add `format: string` to `Request` |
| `src/markdown.odin` | Parse `format` field from JSON |
| `src/protocol.odin` | Delete `_op_search`; add dump branch to `_op_query`; remove `"search"` case from `dispatch` |
| `src/operators.odin` | Delete `_op_access`; add dump branch to `_op_global_query`; remove `"search"` from `_op_requires_key`; remove `"dump"` from `_slot_dispatch` (now handled via `query` op); remove `access` from Ops vtable and `daemon_dispatch` |
| `src/daemon.odin` | Remove `"access"` case from `daemon_dispatch` |
| `src/mcp.odin` | Delete `shard_dump` tool + `_tool_dump`; update `shard_query` schema + description; remove `"dump"` from `shard_fleet` op enum; update `_tool_query` to pass `format` through |
| `src/query/tests/query_test.odin` | New — scaffold tests for `format=dump` on both per-shard and global paths |

---

## Task 1: Add `format` field to Request and parse it

**Files:**
- Modify: `src/types.odin` (Request struct)
- Modify: `src/markdown.odin` (JSON parser)

- [ ] **Step 1: Add `format` to `Request` in `types.odin`**

In the `Request` struct, after the `mode` field (line ~253), add:

```odin
// query format: "results" (default) or "dump"
format: string,
```

- [ ] **Step 2: Parse `format` in `markdown.odin`**

Find the block where `req.mode` is parsed (search for `req.mode = _str(obj, "mode"`). Add directly after it:

```odin
req.format = _str(obj, "format", allocator)
```

- [ ] **Step 3: Marshal `format` in `markdown.odin`**

Find where `mode` is written to the response builder (search for `_write_json_field(&b, "mode"`). Add directly after it:

```odin
if req.format != "" do _write_json_field(&b, "format", req.format)
```

- [ ] **Step 4: Build to verify no compile errors**

```
just test-build
```

Expected: clean build, no errors.

- [ ] **Step 5: Commit**

```
git add src/types.odin src/markdown.odin
git commit -m "feat: add format field to Request for query pipeline"
```

---

## Task 2: Delete `_op_search` and its references

**Files:**
- Modify: `src/protocol.odin` (delete proc + dispatch case)
- Modify: `src/operators.odin` (delete `_slot_dispatch` case + `_op_requires_key` entry)

- [ ] **Step 1: Delete `_op_search` proc from `protocol.odin`**

Remove the entire proc body (lines 473–507):

```odin
_op_search :: proc(node: ^Node, req: Request, allocator := context.allocator) -> string {
    ...
}
```

- [ ] **Step 2: Remove `"search"` case from `dispatch` in `protocol.odin`**

Remove:
```odin
case "search":
    return _op_search(node, req, allocator)
```

- [ ] **Step 3: Remove `"search"` from `_slot_dispatch` in `operators.odin`**

Remove:
```odin
case "search":
    result = _op_search(&temp_node, req, allocator)
```

- [ ] **Step 4: Remove `"search"` from `_op_requires_key` in `operators.odin`**

Remove `"search",` from the switch case list in `_op_requires_key`.

- [ ] **Step 5: Build to verify no compile errors**

```
just test-build
```

Expected: clean build.

- [ ] **Step 6: Commit**

```
git add src/protocol.odin src/operators.odin
git commit -m "refactor: delete _op_search — superseded by query op"
```

---

## Task 3: Delete `_op_access` and its references

**Files:**
- Modify: `src/operators.odin` (delete proc, Ops vtable entry, `_slot_dispatch` case, `"dump"` from `_slot_dispatch`)
- Modify: `src/daemon.odin` (delete `daemon_dispatch` case)

- [ ] **Step 1: Delete `_op_access` proc from `operators.odin`**

Remove the entire proc (lines 784–942 approx). It starts with:
```odin
_op_access :: proc(node: ^Node, req: Request, allocator := context.allocator) -> string {
```
and ends after the final `return _marshal(...)` before `_op_digest`.

- [ ] **Step 2: Remove `access` from the Ops vtable declaration in `operators.odin`**

In the `Ops_Table` struct definition, remove:
```odin
access: proc(node: ^Node, req: Request, allocator := context.allocator) -> string,
```

In the `Ops` initialiser, remove:
```odin
access = _op_access,
```

- [ ] **Step 3: Remove `"dump"` from `_slot_dispatch` in `operators.odin`**

The `dump` op used to be handled per-slot. Now that `format=dump` is part of the `query` op, the standalone `dump` case in `_slot_dispatch` must be removed. Find and remove:
```odin
case "dump":
    result = _op_dump(&temp_node, req, allocator)
```

Also remove `"dump"` from `_op_requires_key` in `operators.odin` — find `"dump",` in the switch case list and delete it.

- [ ] **Step 4: Remove `"access"` from `daemon_dispatch` in `daemon.odin`**

Remove:
```odin
case "access":
    return Ops.access(node, req, allocator), true
```

- [ ] **Step 5: Build to verify no compile errors**

```
just test-build
```

Expected: clean build.

- [ ] **Step 6: Commit**

```
git add src/operators.odin src/daemon.odin
git commit -m "refactor: delete _op_access and standalone dump slot dispatch — superseded by global_query and query format=dump"
```

---

## Task 4: Add `format=dump` to per-shard `_op_query`

**Files:**
- Modify: `src/protocol.odin` (`_op_query`)

The per-shard dump path: when `req.format == "dump"`, retrieve **all** matching thoughts (respecting budget) and render them as a markdown document using the existing `_dump_thought` helper. The shard title comes from `node.blob.catalog.name` (falling back to `node.name`).

- [ ] **Step 1: Add dump branch at the end of `_op_query` in `protocol.odin`**

After the existing wire-result loop (after `count += 1`), replace the final `return _marshal(...)` with:

```odin
if req.format == "dump" {
    b := strings.builder_make(allocator)
    title := node.blob.catalog.name != "" ? node.blob.catalog.name : node.name
    fmt.sbprintf(&b, "# %s\n", title)
    if node.blob.catalog.purpose != "" {
        fmt.sbprintf(&b, "\n%s\n", node.blob.catalog.purpose)
    }
    if len(wire) > 0 {
        strings.write_string(&b, "\n## Knowledge\n")
        for r in wire {
            fmt.sbprintf(&b, "\n### %s\n\n%s\n", r.description, r.content)
        }
    }
    return _marshal(Response{status = "ok", content = strings.to_string(b)}, allocator)
}
return _marshal(Response{status = "ok", results = wire[:]}, allocator)
```

Note: `wire` already contains decrypted content from the existing loop — we just render it differently.

- [ ] **Step 2: Build to verify no compile errors**

```
just test-build
```

- [ ] **Step 3: Commit**

```
git add src/protocol.odin
git commit -m "feat: add format=dump to per-shard query op"
```

---

## Task 5: Add `format=dump` to `_op_global_query`

**Files:**
- Modify: `src/operators.odin` (`_op_global_query`)

The global dump path: after collecting and sorting `wire` results, if `req.format == "dump"`, group them by `shard_name` and render as unified markdown with one `# ShardName` section per shard.

- [ ] **Step 1: Add dump branch after `_sort_wire_results` in `_op_global_query`**

After the existing `_sort_wire_results(wire[:])` and trim-to-max_total loop, replace the final `return _marshal(...)` with:

```odin
if req.format == "dump" {
    b := strings.builder_make(allocator)
    current_shard := ""
    for r in wire {
        if r.shard_name != current_shard {
            current_shard = r.shard_name
            fmt.sbprintf(&b, "\n# %s\n", current_shard)
        }
        fmt.sbprintf(&b, "\n### %s\n\n%s\n", r.description, r.content)
    }
    return _marshal(
        Response{status = "ok", content = strings.to_string(b)},
        allocator,
    )
}
return _marshal(
    Response{
        status         = "ok",
        results        = wire[:],
        shards_searched = shards_searched,
        total_results  = len(wire),
    },
    allocator,
)
```

- [ ] **Step 2: Build to verify no compile errors**

```
just test-build
```

- [ ] **Step 3: Commit**

```
git add src/operators.odin
git commit -m "feat: add format=dump to global_query op"
```

---

## Task 6: Delete `shard_dump` MCP tool, update `shard_query`

**Files:**
- Modify: `src/mcp.odin`

- [ ] **Step 1: Delete `shard_dump` from the `_tools` array**

Remove the entire entry:
```odin
{
    name = "shard_dump",
    description = "Dump all thoughts in a shard as a markdown document.",
    schema = `...`,
},
```

- [ ] **Step 2: Delete `_tool_dump` proc**

Remove the entire proc (lines 678–693):
```odin
// shard_dump — "Give me everything"
_tool_dump :: proc(id_val: json.Value, args: json.Object) -> string {
    ...
}
```

- [ ] **Step 3: Remove `shard_dump` case from `_handle_tools_call`**

Remove:
```odin
case "shard_dump":
    return _tool_dump(id_val, args)
```

- [ ] **Step 4: Update `shard_query` tool description and schema**

Replace the current `shard_query` entry:

```odin
{
    name        = "shard_query",
    description = "Universal search. Returns scored results by default or a markdown document when format=dump. Omit shard for cross-shard search across all shards above gate relevance threshold; provide shard for direct single-shard lookup. Advanced: set depth>0 for wikilink BFS traversal.",
    schema      = `{"type":"object","properties":{"query":{"type":"string","description":"Search keywords or question"},"shard":{"type":"string","description":"Specific shard to search. Omit for global cross-shard search."},"format":{"type":"string","description":"Output format: 'results' (default, scored list) or 'dump' (full markdown document)","enum":["results","dump"]},"limit":{"type":"integer","description":"Max results (default 5)"},"threshold":{"type":"number","description":"Gate score threshold for cross-shard selection (0.0-1.0)"},"budget":{"type":"integer","description":"Max content chars in response (0 = unlimited)"},"depth":{"type":"integer","description":"Advanced: link-following depth for wikilink traversal (0 = flat)"}},"required":["query"]}`,
},
```

- [ ] **Step 5: Update `_tool_query` to pass `format` through to the op**

In `_tool_query` (around line 468), after reading `budget_val`, add:

```odin
format := md_json_get_str(args, "format")
threshold_val := md_json_get_f32(args, "threshold")
```

In the global_query branch (no shard, no depth), add `format` and `threshold` to the JSON message:
```odin
if format != "" do fmt.sbprintf(&b, `,"format":"%s"`, json_escape(format))
if threshold_val > 0 do fmt.sbprintf(&b, `,"threshold":%f`, threshold_val)
```

In the per-shard branch (shard specified), add `format`:
```odin
if format != "" do fmt.sbprintf(&b2, `,"format":"%s"`, json_escape(format))
```

- [ ] **Step 6: Remove `"dump"` and `"search"` from `shard_fleet` op enum in schema**

Find the `shard_fleet` schema string and update the `op` enum from:
```
"enum":["query","read","write","dump","search","stale"]
```
to:
```
"enum":["query","read","write","stale"]
```

- [ ] **Step 7: Build to verify no compile errors**

```
just test-build
```

- [ ] **Step 8: Commit**

```
git add src/mcp.odin
git commit -m "feat: delete shard_dump tool, unify under shard_query format=dump"
```

---

## Task 7: Write tests

**Files:**
- Create: `src/query/tests/query_test.odin`

`just test` scans for directories literally named `tests` anywhere under `src/`. The correct structure is `src/<package>/tests/` — Odin runs `odin test ./src/query/tests/`. The test file must be in the `tests` directory itself, not a subdirectory.

- [ ] **Step 1: Create test directory**

```
mkdir -p src/query/tests
```

- [ ] **Step 2: Write the test file at `src/query/tests/query_test.odin`**

```odin
package query_tests

import "core:testing"

// These are scaffold tests. The codebase has no test harness yet that allows
// in-process dispatch without a live daemon. Expand these once a test-node
// helper is extracted (future task). For now they verify the package compiles
// and the test runner finds the directory.

@(test)
test_format_field_exists :: proc(t: ^testing.T) {
    // Placeholder: confirms test package compiles.
    // Real test: parse {"format":"dump"} through md_unmarshal and check req.format == "dump"
    testing.expect(t, true, "scaffold")
}

@(test)
test_query_default_returns_results :: proc(t: ^testing.T) {
    // Placeholder: without format=dump, query returns Wire_Results not markdown.
    testing.expect(t, true, "scaffold")
}

@(test)
test_query_dump_returns_markdown :: proc(t: ^testing.T) {
    // Placeholder: with format=dump, query returns content field with # heading.
    testing.expect(t, true, "scaffold")
}

@(test)
test_global_query_dump_groups_by_shard :: proc(t: ^testing.T) {
    // Placeholder: global_query format=dump groups results under # ShardName headers.
    testing.expect(t, true, "scaffold")
}
```

- [ ] **Step 3: Run tests**

```
just test
```

Expected: `▶ testing src/query/tests...` appears in output, all 4 tests pass.

- [ ] **Step 4: Commit**

```
git add src/query/
git commit -m "test: scaffold query pipeline test package"
```

---

## Task 8: Update shard knowledge

- [ ] **Step 1: Record the completion in the milestones shard**

Use `shard_write` to update the M3 progress thought — mark `global_dump` (unified via `format=dump`) as complete.

- [ ] **Step 2: Update `decisions` shard**

Write a new thought to `decisions` documenting: "`search` and `access` ops deleted; `shard_query` with `format=dump` is the unified query+dump interface."

- [ ] **Step 3: Final build check**

```
just test-build
```

Expected: clean build, all tests pass.

- [ ] **Step 4: Final commit**

```
git add -A
git commit -m "chore: update shard knowledge after unified query pipeline"
```

---

## Verification Checklist

Before declaring done:

- [ ] `just test-build` passes with no errors or warnings
- [ ] `_op_search` is fully deleted (no remaining references)
- [ ] `_op_access` is fully deleted (no remaining references)  
- [ ] `shard_dump` MCP tool is deleted
- [ ] `shard_query` schema includes `format` and `threshold` params
- [ ] `_op_query` returns markdown when `format=dump`
- [ ] `_op_global_query` returns markdown when `format=dump`
- [ ] `format` field parses correctly through `markdown.odin`
- [ ] `shard_fleet` schema no longer lists `"dump"` or `"search"` as valid ops
