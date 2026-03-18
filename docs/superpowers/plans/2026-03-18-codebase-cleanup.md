# Codebase Cleanup Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove all duplicated, misplaced, and bloated code — extract a new `json.odin`, a new `search.odin`, a new `http.odin`, split `mcp.odin` into infrastructure + tools, split `embed.odin` into embeddings + streaming, and split `main.odin` CLI commands into focused files.

**Architecture:** Six parallel clean-up tracks (each independent): (1) create `json.odin` as the single home for all JSON helpers, (2) create `search.odin` for the keyword/vector search engine, (3) create `http.odin` for the shared curl HTTP helpers, (4) split `mcp.odin` → `mcp.odin` (infra) + `mcp_tools.odin` (tool handlers), (5) split `embed.odin` → `embed.odin` (vectors) + `llm.odin` (streaming chat), (6) split `main.odin` → `main.odin` (entry + daemon/shard runners) + `cmd_*.odin` per command. Each track is independently buildable and testable.

**Tech Stack:** Odin, `core:encoding/json`, `core:strings`, `just test-build` to verify, `just test` to run tests.

---

## File Map (after cleanup)

| File | Was | Now |
|------|-----|-----|
| `src/json.odin` | *(new)* | All JSON accessor helpers + escape + write_json_value |
| `src/search.odin` | *(new)* | `build_search_index`, `search_query`, keyword/vector engines, composite scoring, staleness, RFC3339 parser |
| `src/http.odin` | *(new)* | Shared `_http_post` proc used by both embed and daemon |
| `src/mcp.odin` | 1304 lines | IPC connection, keychain, JSON-RPC framing, tool dispatch, daemon auto-start (~450 lines) |
| `src/mcp_tools.odin` | *(new)* | All `_tool_*` handlers split out (~870 lines) |
| `src/embed.odin` | 730 lines | Vector embeddings only: `embed_*`, `index_*`, `cosine_similarity`, `fnv_hash`, `_embed_post`, `_parse_*` (~580 lines) |
| `src/llm.odin` | *(new)* | `stream_chat`, `_stream_post`, `_extract_sse_content`, `_llm_endpoint` (~150 lines) |
| `src/main.odin` | 835 lines | Entry point + `main()`, `_run_daemon`, `_run_shard`, `_workspace_init` (~200 lines) |
| `src/cmd_init.odin` | *(new)* | `_run_init` + `_run_install` |
| `src/cmd_new.odin` | *(new)* | `_run_new` |
| `src/cmd_connect.odin` | *(new)* | `_run_connect`, `flush_msg`, `_notify_daemon_discover`, `_prompt` |
| `src/cmd_vault.odin` | *(new)* | `_run_vault` |
| `src/protocol.odin` | 1830 lines | Ops only — everything below line 1270 moves to `search.odin` (~1270 lines) |
| `src/markdown.odin` | 956 lines | Wire format only — JSON accessor section (lines 479–639) moves to `json.odin` (~640 lines) |
| `src/daemon.odin` | 486 lines | `_llm_post` moves to `http.odin`; `_llm_endpoint` moves to `llm.odin` (~450 lines) |

---

## Task 1: Create `json.odin` — centralize all JSON helpers

**What:** Extract the `md_json_get_*` family from `markdown.odin` (lines 479–563), `_write_json_field`, `_write_json_array`, `_json_escape_to`, `json_escape` from `markdown.odin` (lines 913–952), and `_write_json_value` + `md_json_get_float` from `mcp.odin` — consolidate into a single `src/json.odin`.

**Why:** These helpers are used by `protocol.odin`, `mcp.odin`, `ops_cache.odin`, and `markdown.odin` itself. `md_json_get_float` in `mcp.odin` is a near-duplicate of `md_json_get_f64` in `markdown.odin` — delete the mcp one and update callers.

**Files:**
- Create: `src/json.odin`
- Modify: `src/markdown.odin` — remove extracted procs, keep `md_parse_request`, `md_marshal_response*`, `md_parse_request_json`, `md_marshal_response_json`, `_write_catalog`, `_write_inline_list`, `_parse_inline_list`
- Modify: `src/mcp.odin` — remove `md_json_get_float` (line 1149) and `_write_json_value` (line 240), update 2 call sites of `md_json_get_float` (lines 480 and 856)

- [ ] **Step 1: Read `markdown.odin` lines 479–563 and 913–952**

  Verify these are the exact procs to move:
  - `md_json_get_str`, `md_json_get_int`, `md_json_get_f64`, `md_json_get_bool`, `md_json_get_obj`, `md_json_get_str_array`, `md_json_str_array_to_json`
  - `_write_json_field`, `_write_json_array`, `_json_escape_to`, `json_escape`

- [ ] **Step 2: Read `mcp.odin` lines 240–258 and 1149–1168**

  Verify `_write_json_value` and `md_json_get_float` are entirely self-contained and have no other dependencies in mcp.odin.

- [ ] **Step 3: Create `src/json.odin`**

  New file with package declaration and all collected procs:

  ```odin
  package shard

  import "core:encoding/json"
  import "core:fmt"
  import "core:strings"

  // =============================================================================
  // JSON accessors — typed helpers for json.Object key lookups
  // =============================================================================

  md_json_get_str :: proc(obj: json.Object, key: string) -> string { ... }
  md_json_get_int :: proc(obj: json.Object, key: string) -> int { ... }
  md_json_get_f64 :: proc(obj: json.Object, key: string) -> f64 { ... }
  md_json_get_bool :: proc(obj: json.Object, key: string) -> (bool, bool) { ... }
  md_json_get_obj :: proc(obj: json.Object, key: string) -> (json.Object, bool) { ... }
  md_json_get_str_array :: proc(obj: json.Object, key: string, allocator := ...) -> []string { ... }
  md_json_str_array_to_json :: proc(arr: []string, allocator := ...) -> json.Array { ... }

  // =============================================================================
  // JSON output helpers — writing JSON fields and escaped strings
  // =============================================================================

  write_json_value :: proc(b: ^strings.Builder, val: json.Value) { ... }
  _write_json_field :: proc(b: ^strings.Builder, key: string, value: string) { ... }
  _write_json_array :: proc(b: ^strings.Builder, items: []string) { ... }
  _json_escape_to :: proc(b: ^strings.Builder, s: string) { ... }
  json_escape :: proc(s: string, allocator := context.temp_allocator) -> string { ... }
  ```

  Note: rename `_write_json_value` → `write_json_value` (no longer private to mcp).

- [ ] **Step 4: Delete extracted procs from `markdown.odin`**

  Remove lines 479–563 (accessor block) and lines 913–952 (output helpers block).
  `markdown.odin` should no longer import `"core:fmt"` if that was its only use — verify.

- [ ] **Step 5: Delete `_write_json_value` and `md_json_get_float` from `mcp.odin`**

  Remove lines 240–258 (`_write_json_value`) and lines 1149–1168 (`md_json_get_float`).

  There are **two** call sites for `md_json_get_float` — update both:
  - Line 480 in `_tool_query` (after Task 4 moves it to `mcp_tools.odin`)
  - Line 856 in `_tool_stale` (after Task 4 moves it to `mcp_tools.odin`)

  `md_json_get_float` returned `(f64, bool)` where the bool meant "key was present".
  `md_json_get_f64` returns `f64` with `0` as the absent-key sentinel.
  `0.0` is a semantically invalid threshold (would match everything), so `!= 0` is a safe
  presence check for this field. **However**, to avoid any semantic ambiguity, add
  `md_json_get_float` directly to `json.odin` with the `(f64, bool)` signature — this
  is the cleanest migration that changes zero behaviour:

  ```odin
  // In json.odin — new proc, replaces the mcp.odin-local version:
  md_json_get_float :: proc(obj: json.Object, key: string) -> (f64, bool) {
      val, ok := obj[key]
      if !ok do return 0, false
      #partial switch v in val {
      case f64:  return v, true
      case i64:  return f64(v), true
      }
      return 0, false
  }
  ```

  Call sites in `mcp_tools.odin` remain unchanged — they already call `md_json_get_float`
  and the proc now lives in `json.odin` (same package, resolves automatically).

  Also update `_write_json_value` → `write_json_value` at the 3 call sites in `mcp.odin`.

- [ ] **Step 6: Build**

  ```bash
  just test-build
  ```
  Expected: clean compile, no "undefined" errors.

- [ ] **Step 7: Test**

  ```bash
  just test
  ```
  Expected: all tests pass.

- [ ] **Step 8: Commit**

  ```bash
  git add src/json.odin src/markdown.odin src/mcp.odin
  git commit -m "refactor: extract json.odin — centralize all JSON helpers"
  ```

---

## Task 2: Create `search.odin` — extract search engine from `protocol.odin`

**What:** Move the pure search and scoring procs from the bottom of `protocol.odin` (lines ~1270–1830) into a new `src/search.odin`. The procs that move are: `build_search_index`, `search_query`, `_entries_have_embeddings`, `_vector_search`, `_keyword_search`, `_keyword_score`, `_stem`, `_tokenize`, `_thought_matches_tokens`, `_sort_results`, `_composite_score`, `_compute_staleness`, `_parse_rfc3339`, `_atoi2`, `_atoi4`. The procs `_op_stale`, `_op_feedback`, `_increment_read_count`, `_scan_citations`, `_clone_request`, `_clone_strings`, `_err_response`, `_marshal`, `id_to_hex`, `hex_to_id` **stay in `protocol.odin`** — they are used by the ops above line 1270.

**Why:** `protocol.odin` is 1830 lines. The bottom 560 lines are a self-contained search library with zero dependencies on the top half's operations logic. This is the single biggest cleanness win.

**Files:**
- Create: `src/search.odin`
- Modify: `src/protocol.odin` — remove lines 1270–1830

- [ ] **Step 1: Read `protocol.odin` lines 1270–1830**

  Identify the exact cut point and every proc that goes to `search.odin`:
  - `build_search_index`, `_index_thoughts` (nested)
  - `search_query`, `_entries_have_embeddings`, `_vector_search`, `_keyword_search`
  - `_keyword_score`, `_stem`, `_tokenize`, `_thought_matches_tokens`
  - `_sort_results`, `_composite_score`
  - `_increment_read_count`, `_scan_citations`
  - `_compute_staleness`, `_parse_rfc3339`, `_atoi2`, `_atoi4`
  - `_op_stale`, `_op_feedback`
  - `_clone_request`, `_clone_strings`
  - `_err_response`, `_marshal`
  - `id_to_hex`, `hex_to_id`

  Note: `_err_response`, `_marshal`, `id_to_hex`, `hex_to_id` are used *throughout* protocol.odin's top half — they stay in `protocol.odin`. Only the pure search + scoring procs move.

- [ ] **Step 2: Re-scope the move**

  After Step 1 audit, the actual boundary is:
  - Move to `search.odin`: `build_search_index`, `search_query`, `_entries_have_embeddings`, `_vector_search`, `_keyword_search`, `_keyword_score`, `_stem`, `_tokenize`, `_thought_matches_tokens`, `_sort_results`, `_composite_score`, `_compute_staleness`, `_parse_rfc3339`, `_atoi2`, `_atoi4`
  - Stay in `protocol.odin`: `_op_stale`, `_op_feedback`, `_increment_read_count`, `_scan_citations`, `_clone_request`, `_clone_strings`, `_err_response`, `_marshal`, `id_to_hex`, `hex_to_id` (all used by ops above line 1270)

- [ ] **Step 3: Create `src/search.odin`**

  ```odin
  package shard

  import "core:encoding/json"
  import "core:math"
  import "core:slice"
  import "core:strings"
  import "core:time"

  // =============================================================================
  // Search index — build and query
  // =============================================================================

  build_search_index :: proc(...) { ... }
  search_query :: proc(...) { ... }
  _entries_have_embeddings :: proc(...) { ... }
  _vector_search :: proc(...) { ... }
  _keyword_search :: proc(...) { ... }

  // =============================================================================
  // Scoring — keyword, vector, composite, staleness
  // =============================================================================

  _keyword_score :: proc(...) { ... }
  _stem :: proc(...) { ... }
  _tokenize :: proc(...) { ... }
  _thought_matches_tokens :: proc(...) { ... }
  _sort_results :: proc(...) { ... }
  _composite_score :: proc(...) { ... }
  _compute_staleness :: proc(...) { ... }

  // =============================================================================
  // Time — RFC3339 parsing
  // =============================================================================

  _parse_rfc3339 :: proc(...) { ... }
  _atoi2 :: proc(...) { ... }
  _atoi4 :: proc(...) { ... }
  ```

- [ ] **Step 4: Delete moved procs from `protocol.odin`**

  Remove the 14 procs identified in Step 2 from protocol.odin. Verify `protocol.odin` still has all imports it needs (it will keep `"core:time"` for `_compute_staleness` callers that remain). Remove imports no longer needed after the move (`"core:math"` if only used by search, etc.).

- [ ] **Step 5: Check imports in `search.odin`**

  `search.odin` uses: `json` (for `Thought_Plaintext`), `math` (cosine similarity via `cosine_similarity` from embed.odin — verify it calls `cosine_similarity` from `embed.odin`, not reimplements it), `strings`, `time`. Add only what's needed.

- [ ] **Step 6: Build**

  ```bash
  just test-build
  ```
  Expected: clean compile.

- [ ] **Step 7: Test**

  ```bash
  just test
  ```
  Expected: all tests pass.

- [ ] **Step 8: Commit**

  ```bash
  git add src/search.odin src/protocol.odin
  git commit -m "refactor: extract search.odin — move search engine out of protocol.odin"
  ```

---

## Task 3: Create `http.odin` — unify curl HTTP helpers

**What:** Both `daemon.odin` (`_llm_post`, lines 83–110) and `embed.odin` (`_embed_post`, lines 428–465) implement nearly identical curl POST wrappers. Unify them into a single `_http_post` in a new `src/http.odin`. Update both callers.

**Why:** The two implementations differ only in minor flag ordering (`-s -S` vs `-s`, `--max-time` present in embed but missing from daemon). The canonical version should include `-s -S` and `--max-time`.

**Files:**
- Create: `src/http.odin`
- Modify: `src/daemon.odin` — delete `_llm_post`, call `_http_post` instead
- Modify: `src/embed.odin` — delete `_embed_post`, call `_http_post` instead

- [ ] **Step 1: Read `daemon.odin` lines 83–130 and `embed.odin` lines 401–465**

  Confirm the exact signatures:
  - `_llm_post(url, api_key, body, timeout) -> (string, bool)` — note: no `allocator` param, uses `context.temp_allocator` for cmd
  - `_embed_post(url, api_key, body, timeout, allocator) -> (string, bool)` — has explicit allocator

- [ ] **Step 2: Create `src/http.odin`**

  ```odin
  package shard

  import "core:fmt"
  import "core:os/os2"
  import "core:strings"

  // =============================================================================
  // HTTP — shared curl POST helper used by embed and daemon LLM calls
  // =============================================================================

  // _http_post sends a JSON POST request via curl and returns the response body.
  // api_key is optional — pass "" to omit the Authorization header.
  // timeout is in seconds (0 = no limit).
  _http_post :: proc(
      url: string,
      api_key: string,
      body: string,
      timeout: int,
      allocator := context.allocator,
  ) -> (string, bool) {
      cmd := make([dynamic]string, context.temp_allocator)
      append(&cmd, "curl", "-s", "-S")
      if timeout > 0 {
          append(&cmd, "--max-time", fmt.tprintf("%d", timeout))
      }
      append(&cmd, "-X", "POST")
      append(&cmd, "-H", "Content-Type: application/json")
      if api_key != "" {
          append(&cmd, "-H", fmt.tprintf("Authorization: Bearer %s", api_key))
      }
      append(&cmd, "-d", body)
      append(&cmd, url)

      state, stdout, stderr, err := os2.process_exec(os2.Process_Desc{command = cmd[:]}, allocator)
      if err != nil {
          fmt.eprintfln("http: curl error: %v", err)
          return "", false
      }
      if state.exit_code != 0 {
          stderr_str := string(stderr)
          trunc := min(200, len(stderr_str))
          fmt.eprintfln("http: curl exit %d: %s", state.exit_code, stderr_str[:trunc])
          return "", false
      }
      return string(stdout), true
  }
  ```

- [ ] **Step 3: Update `daemon.odin`**

  Delete `_llm_post` proc (lines 83–110). Replace its single call site:
  ```odin
  // Before:
  response, ok := _llm_post(chat_url, cfg.llm_key, strings.to_string(b), cfg.llm_timeout)
  // After:
  response, ok := _http_post(chat_url, cfg.llm_key, strings.to_string(b), cfg.llm_timeout)
  ```
  Remove `import "core:os/os2"` from daemon.odin if it was only used by `_llm_post`. Check other usages first.

- [ ] **Step 4: Update `embed.odin`**

  Delete `_embed_post` proc (lines 428–465). Replace call sites:
  ```odin
  // Before:
  response, ok := _embed_post(embed_url, cfg.llm_key, body, cfg.llm_timeout, allocator)
  // After:
  response, ok := _http_post(embed_url, cfg.llm_key, body, cfg.llm_timeout, allocator)
  ```
  There are two call sites in `embed.odin` — update both.

- [ ] **Step 5: Build**

  ```bash
  just test-build
  ```
  Expected: clean compile.

- [ ] **Step 6: Test**

  ```bash
  just test
  ```
  Expected: all tests pass.

- [ ] **Step 7: Commit**

  ```bash
  git add src/http.odin src/daemon.odin src/embed.odin
  git commit -m "refactor: extract http.odin — unify duplicate curl POST helpers"
  ```

---

## Task 4: Split `mcp.odin` → `mcp.odin` + `mcp_tools.odin`

**What:** Move all `_tool_*` handlers (lines 353–1147) into a new `src/mcp_tools.odin`. Keep `mcp.odin` as the JSON-RPC server infrastructure: IPC connection, keychain, response formatters, `_handle_initialize`, `_handle_tools_list`, `_handle_tools_call`, `run_mcp`, `_process_jsonrpc`, `_daemon_auto_start`, `_extract_suggestion_ids`.

**Why:** `mcp.odin` is 1304 lines. The tool handler section is 795 lines of independent, one-per-tool functions. The infra and tools have no cross-dependency — tools call `_daemon_call`, `_mcp_tool_result`, `json_escape`, and `md_json_get_*`, all of which live in the infrastructure or `json.odin`.

**Files:**
- Create: `src/mcp_tools.odin`
- Modify: `src/mcp.odin` — remove `_tool_*` procs (lines 353–1147 after Task 1 removes md_json_get_float)

- [ ] **Step 1: Read `mcp.odin` lines 340–1147**

  Identify exact start/end of the tool handler block. Every proc starting with `_tool_` moves. `_extract_suggestion_ids` (line 1113) is a helper used only by `_tool_compact_apply` — it moves too.

- [ ] **Step 2: Create `src/mcp_tools.odin`**

  ```odin
  package shard

  import "core:encoding/json"
  import "core:fmt"
  import "core:strings"

  // =============================================================================
  // MCP tool handlers — one proc per shard_* tool
  // =============================================================================

  _tool_discover :: proc(...) { ... }
  _tool_query :: proc(...) { ... }
  _tool_read :: proc(...) { ... }
  _tool_write :: proc(...) { ... }
  _tool_delete :: proc(...) { ... }
  _tool_remember :: proc(...) { ... }
  _tool_consumption_log :: proc(...) { ... }
  _tool_cache_write :: proc(...) { ... }
  _tool_cache_read :: proc(...) { ... }
  _tool_cache_list :: proc(...) { ... }
  _tool_events :: proc(...) { ... }
  _tool_stale :: proc(...) { ... }
  _tool_feedback :: proc(...) { ... }
  _tool_fleet :: proc(...) { ... }
  _tool_compact_suggest :: proc(...) { ... }
  _tool_compact :: proc(...) { ... }
  _tool_compact_apply :: proc(...) { ... }
  _extract_suggestion_ids :: proc(...) { ... }
  ```

  All tool procs call `_daemon_call` and `_mcp_tool_result` — these stay in `mcp.odin` and are accessible since both files are in the same package.

- [ ] **Step 3: Delete `_tool_*` and `_extract_suggestion_ids` from `mcp.odin`**

  After the move, `mcp.odin` should end with `_daemon_auto_start` and `run_mcp`/`_process_jsonrpc`. Verify `_handle_tools_call` still compiles (it calls `_tool_*` by name — same package, so it resolves from `mcp_tools.odin`).

- [ ] **Step 4: Verify imports**

  `mcp_tools.odin` needs: `"core:encoding/json"`, `"core:fmt"`, `"core:strings"`. Check for any `strconv` usage in tools. `mcp.odin` can drop imports only used by removed procs.

- [ ] **Step 5: Build**

  ```bash
  just test-build
  ```
  Expected: clean compile.

- [ ] **Step 6: Test**

  ```bash
  just test
  ```
  Expected: all tests pass.

- [ ] **Step 7: Commit**

  ```bash
  git add src/mcp_tools.odin src/mcp.odin
  git commit -m "refactor: split mcp_tools.odin — separate tool handlers from MCP server"
  ```

---

## Task 5: Split `embed.odin` → `embed.odin` + `llm.odin`

**What:** Move `stream_chat`, `_stream_post`, `_extract_sse_content`, `Streaming_Callback`, `Streaming_Message` (lines 590–730) and `_llm_endpoint` (line 401) into a new `src/llm.odin`. Also move `fnv_hash` (line 407) to `search.odin` since it's used only by the search index (as `text_hash`).

**Why:** `embed.odin` mixes vector math with LLM streaming chat. `_llm_endpoint` is the shared URL builder — it belongs with the LLM caller, not with embeddings. `fnv_hash` is a search index detail.

**Files:**
- Create: `src/llm.odin`
- Modify: `src/embed.odin` — remove `stream_chat`, `_stream_post`, `_extract_sse_content`, `Streaming_Callback`, `Streaming_Message`, `_llm_endpoint`, `fnv_hash`
- Modify: `src/search.odin` — add `fnv_hash` (from Task 2 it already has the search engine; fnv_hash fits here as a search utility)

- [ ] **Step 1: Read `embed.odin` lines 401–730**

  Confirm `_llm_endpoint` is called only by `_embed_post` (now deleted after Task 3) and `stream_chat`. After Task 3, `_embed_post` is gone but `embed.odin` still calls `_llm_endpoint` directly for the embed URL (lines 35 and 56: `embed_url := _llm_endpoint("/embeddings")`). Moving `_llm_endpoint` to `llm.odin` is safe because both files are in the same package.

  Also verify: `daemon.odin`'s `_ai_compact_content` calls `_llm_post` (now `_http_post`) which takes a plain URL string — `_llm_endpoint` is not called in `daemon.odin`, only in `embed.odin`. Confirm this before proceeding.

  Confirm `fnv_hash` call sites: only `src/protocol.odin` (search index building) and `src/embed.odin` (index persist/load). After Task 2 extracts search.odin, the `build_search_index` call is in `search.odin`. Check embed.odin's index persist/load for `fnv_hash` usage — if embed.odin uses it directly (in `index_persist`/`index_load`), it resolves from `search.odin` (same package) after the move.

- [ ] **Step 2: Create `src/llm.odin`**

  ```odin
  package shard

  import "core:fmt"
  import "core:os/os2"
  import "core:strings"

  // =============================================================================
  // LLM — endpoint URL builder and streaming chat via SSE
  // =============================================================================

  Streaming_Callback :: #type proc(chunk: string, done: bool, user_data: rawptr)

  Streaming_Message :: struct {
      role:    string,
      content: string,
  }

  // _llm_endpoint constructs a full URL for an LLM API endpoint suffix.
  _llm_endpoint :: proc(suffix: string) -> string { ... }

  // stream_chat sends a chat completion request and streams the response via SSE.
  stream_chat :: proc(
      messages: []Streaming_Message,
      callback: Streaming_Callback,
      user_data: rawptr,
      allocator := context.allocator,
  ) -> bool { ... }

  _stream_post :: proc(...) { ... }
  _extract_sse_content :: proc(sse_json: string) -> string { ... }
  ```

- [ ] **Step 3: Move `fnv_hash` to `search.odin`**

  Add `fnv_hash` to `search.odin` (it's used by `build_search_index`'s `text_hash` field). Remove from `embed.odin`.

- [ ] **Step 4: Delete moved procs from `embed.odin`**

  Remove `stream_chat`, `_stream_post`, `_extract_sse_content`, `Streaming_Callback`, `Streaming_Message`, `_llm_endpoint`, `fnv_hash` from `embed.odin`. Update file comment to reflect it now handles embeddings only.

- [ ] **Step 5: Check `embed.odin` imports**

  After the move, verify which imports are still needed. `"core:os/os2"` is used by `_stream_post` (moved) but also by the batch embed proc — check. `"core:fmt"` is likely still needed.

- [ ] **Step 6: Build**

  ```bash
  just test-build
  ```
  Expected: clean compile.

- [ ] **Step 7: Test**

  ```bash
  just test
  ```
  Expected: all tests pass.

- [ ] **Step 8: Commit**

  ```bash
  git add src/llm.odin src/embed.odin src/search.odin
  git commit -m "refactor: extract llm.odin — separate streaming chat from vector embeddings"
  ```

---

## Task 6: Split `main.odin` into per-command files

**What:** Extract each `_run_*` command into its own `cmd_*.odin` file. `main.odin` keeps only `main()`, `_run_daemon`, `_run_shard`, `_workspace_init`, and `_print_help_overview`.

**Why:** `main.odin` is 835 lines with 5 largely independent command implementations. Each command has its own imports, logic, and test surface. Splitting by command is the natural structure.

**Split:**
- `src/cmd_init.odin` — `_run_init` (line 260) + `_run_install` (line 286)
- `src/cmd_new.odin` — `_run_new` (line 313)
- `src/cmd_connect.odin` — `_run_connect` (line 428), `flush_msg` (line 463, local proc), `_notify_daemon_discover` (line 535), `_prompt` (line 552)
- `src/cmd_vault.odin` — `_run_vault` (line 567)

**Files:**
- Create: `src/cmd_init.odin`, `src/cmd_new.odin`, `src/cmd_connect.odin`, `src/cmd_vault.odin`
- Modify: `src/main.odin` — remove extracted procs, keep entry point + daemon/shard runners + workspace init

- [ ] **Step 1: Read `main.odin` lines 192–835**

  Map each proc's imports. Determine which `import` lines each new file needs:
  - `cmd_init.odin`: `"core:crypto"`, `"core:encoding/hex"`, `"core:fmt"`, `"core:os"`, `"core:strings"`, `logger`
  - `cmd_new.odin`: `"core:crypto"`, `"core:encoding/hex"`, `"core:fmt"`, `"core:os"`, `"core:strings"`, `logger`
  - `cmd_connect.odin`: `"core:fmt"`, `"core:os"`, `"core:strings"`, `"core:time"`, `logger`
  - `cmd_vault.odin`: `"core:fmt"`, `"core:os"`, `"core:strings"`, `logger`

  Note: `flush_msg` in `_run_connect` is declared as a local proc-variable inside `_run_connect`. It must be extracted as a package-level proc in `cmd_connect.odin` (rename to `_flush_msg` to keep it private).

- [ ] **Step 2: Create `src/cmd_init.odin`**

  ```odin
  package shard

  import "core:crypto"
  import "core:encoding/hex"
  import "core:fmt"
  import "core:os"
  import "core:strings"
  import logger "logger"

  // _run_init initializes a new shard workspace in the current directory.
  _run_init :: proc() { ... }

  // _run_install runs init then prints MCP setup instructions.
  _run_install :: proc() { ... }
  ```

- [ ] **Step 3: Create `src/cmd_new.odin`**

  ```odin
  package shard

  import "core:crypto"
  import "core:encoding/hex"
  import "core:fmt"
  import "core:os"
  import "core:strings"
  import logger "logger"

  // _run_new creates a new named shard and registers it with the daemon.
  _run_new :: proc() { ... }
  ```

- [ ] **Step 4: Create `src/cmd_connect.odin`**

  ```odin
  package shard

  import "core:fmt"
  import "core:os"
  import "core:strings"
  import "core:time"
  import logger "logger"

  // _run_connect opens an interactive REPL session against a shard.
  _run_connect :: proc() { ... }

  @(private)
  _flush_msg :: proc(conn: IPC_Conn, b: ^strings.Builder) -> bool { ... }

  _notify_daemon_discover :: proc() { ... }

  _prompt :: proc(prompt: string) -> string { ... }
  ```

- [ ] **Step 5: Create `src/cmd_vault.odin`**

  ```odin
  package shard

  import "core:fmt"
  import "core:os"
  import "core:strings"
  import logger "logger"

  // _run_vault exports all shard content as a wikilink-resolved markdown vault.
  _run_vault :: proc() { ... }
  ```

- [ ] **Step 6: Trim `main.odin`**

  After removing the extracted procs, `main.odin` should contain:
  - Package declaration + imports (only what `main`, `_run_daemon`, `_run_shard`, `_workspace_init` need)
  - `main()` with the subcommand switch
  - `_print_help_overview`
  - `_run_daemon`
  - `_run_shard`
  - `_workspace_init`

  Target: ~200 lines.

- [ ] **Step 7: Build**

  ```bash
  just test-build
  ```
  Expected: clean compile.

- [ ] **Step 8: Test**

  ```bash
  just test
  ```
  Expected: all tests pass.

- [ ] **Step 9: Commit**

  ```bash
  git add src/cmd_init.odin src/cmd_new.odin src/cmd_connect.odin src/cmd_vault.odin src/main.odin
  git commit -m "refactor: split main.odin — extract CLI commands to cmd_*.odin files"
  ```

---

## Final verification

- [ ] **Run full test suite**

  ```bash
  just test
  ```
  Expected: all tests pass.

- [ ] **Run vet**

  ```bash
  odin vet src/
  ```
  Expected: no warnings.

- [ ] **Run fmt**

  ```bash
  odin fmt src/
  git diff --stat
  ```
  If fmt makes changes, commit them:
  ```bash
  git add src/
  git commit -m "chore: odin fmt after cleanup"
  ```

- [ ] **Verify final file sizes**

  ```bash
  wc -l src/*.odin | sort -rn | head -20
  ```

  Expected approximate results:
  | File | Expected lines |
  |------|---------------|
  | `protocol.odin` | ~1270 |
  | `mcp.odin` | ~450 |
  | `mcp_tools.odin` | ~800 |
  | `markdown.odin` | ~640 |
  | `embed.odin` | ~530 |
  | `search.odin` | ~380 |
  | `main.odin` | ~200 |
  | `json.odin` | ~120 |
  | `http.odin` | ~50 |
  | `llm.odin` | ~150 |
  | `cmd_connect.odin` | ~160 |
  | `cmd_new.odin` | ~120 |
  | `cmd_init.odin` | ~80 |
  | `cmd_vault.odin` | ~80 |

- [ ] **Final commit summary**

  ```bash
  git log --oneline -8
  ```
