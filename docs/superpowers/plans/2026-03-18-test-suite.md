# Test Suite Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move all tests out of `src/` into a clean `tests/` folder with two layers — `unit/` for public-API tests and `integration/` for in-process daemon dispatch tests.

**Architecture:** A `-collection:shard=./src` flag makes `import shard "shard:"` resolve to the source package from any directory. Unit tests call public procs directly. Integration tests build a headless `Node` via a new `node_init_test` proc and drive it through `daemon_dispatch`. The justfile is extended to run both new packages.

**Tech Stack:** Odin, `odin test`, `just`

**Spec:** `docs/superpowers/specs/2026-03-18-test-suite-design.md`

---

## File Map

| Action   | File                                    | What changes |
|----------|-----------------------------------------|--------------|
| Modify   | `src/node.odin`                         | Add `node_init_test` proc |
| Modify   | `src/search.odin`                       | Delete 4 `@(test)` procs (lines 562–end) |
| Modify   | `justfile`                              | Extend both `[unix]` and `[windows]` test recipes |
| Create   | `tests/unit/test_seed.odin`             | Seed file, `package shard_unit_test` |
| Create   | `tests/integration/helpers.odin`        | `make_test_node`, `cleanup_test_node`, `dispatch` |
| Create   | `tests/integration/test_seed.odin`      | Seed integration test |
| Move     | `src/query/tests/query_test.odin` →     | `tests/unit/test_query.odin`, rename package |
| Delete   | `src/query/tests/` and `src/query/`     | No longer needed |

---

## Task 1: Add `node_init_test` to `src/node.odin`

**Files:**
- Modify: `src/node.odin` — add new public proc after `node_init`

This is the foundation for integration tests. It mirrors `node_init` exactly but skips
the `ipc_listen` call at the end, so tests can build a `Node` in-process without binding
a named pipe or Unix socket.

- [ ] **Step 1.1: Read `src/node.odin` lines 29–101** to understand the full `node_init` body before copying it.

- [ ] **Step 1.2: Add `node_init_test` after the closing `}` of `node_init`**

  Insert immediately after line ~101 (after `node_init`'s closing brace):

  ```odin
  // node_init_test creates an in-process Node for testing.
  // No IPC listener is started — use daemon_dispatch directly; do not call node_run.
  // idle_timeout defaults to 0 (no eviction). is_daemon is always false.
  node_init_test :: proc(
  	name: string,
  	master: Master_Key,
  	data_path: string,
  	idle_timeout: time.Duration = 0,
  ) -> (
  	node: Node,
  	ok: bool,
  ) {
  	now := time.now()
  	node.name = strings.clone(name)
  	node.start_time = now
  	node.last_activity = now
  	node.idle_timeout = idle_timeout
  	node.is_daemon = false
  	node.index = make([dynamic]Search_Entry)
  	node.registry = make([dynamic]Registry_Entry)
  	node.slots = make(map[string]^Shard_Slot)
  	node.cache_slots = make(map[string]^Cache_Slot)
  	node.event_queue = make(Event_Queue)

  	_ensure_parent_dir(data_path)

  	blob, blob_ok := blob_load(data_path, master)
  	if !blob_ok {
  		logger.errf("node: could not load shard data: %s", data_path)
  		return node, false
  	}
  	node.blob = blob

  	total_thoughts := len(node.blob.processed) + len(node.blob.unprocessed)
  	if total_thoughts > 0 {
  		if !build_search_index(&node.index, node.blob, master, "node") {
  			fmt.eprintfln("node: wrong key — could not decrypt any existing thoughts")
  			return node, false
  		}
  	}

  	node.running = true
  	return node, true
  }
  ```

- [ ] **Step 1.3: Build to confirm it compiles**

  ```
  just test-build
  ```

  Expected: build succeeds with no errors.

- [ ] **Step 1.4: Commit**

  ```
  git add src/node.odin
  git commit -m "feat: add node_init_test for in-process testing without IPC listener"
  ```

---

## Task 2: Delete private `@(test)` procs from `src/search.odin`

**Files:**
- Modify: `src/search.odin` — remove lines 562 to end of file (4 test procs)

The procs to delete are:
- `_test_fulltext_window_merge_overlapping` (line 562)
- `_test_fulltext_window_separate` (line 575)
- `_test_fulltext_window_clamps_to_bounds` (line 587)
- `_test_fulltext_hit_density` (line 597)

Also remove the `import "core:testing"` at the top of `src/search.odin` if it is only
used by these test procs and nothing else — check before removing.

- [ ] **Step 2.1: Read `src/search.odin` from line 1 to line 20** to check if `"core:testing"` import is present.

- [ ] **Step 2.2: Read `src/search.odin` from line 555 to end** to see the full test proc bodies and confirm exact line range.

- [ ] **Step 2.3: Delete the 4 test procs** — remove from the first `@(test)` attribute through the end of the file.

- [ ] **Step 2.4: Remove `import "core:testing"`** from `src/search.odin` if it appears and is now unused.

- [ ] **Step 2.5: Build to confirm it compiles**

  ```
  just test-build
  ```

  Expected: build succeeds. The 4 test procs are gone.

- [ ] **Step 2.6: Commit**

  ```
  git add src/search.odin
  git commit -m "refactor: remove private @(test) procs from search.odin — tests live in tests/ only"
  ```

---

## Task 3: Create `tests/unit/` seed package

**Files:**
- Create: `tests/unit/test_seed.odin`

This establishes the `shard_unit_test` package and proves the collection import works
before any real tests are written. `odin test` requires at least one `@(test)` proc to
run successfully.

- [ ] **Step 3.1: Create `tests/unit/test_seed.odin`**

  ```odin
  package shard_unit_test

  import "core:testing"
  import shard "shard:"

  // Smoke test — confirms the collection import resolves and the package compiles.
  @(test)
  test_package_compiles :: proc(t: ^testing.T) {
  	// Verify a core public type is accessible from the collection.
  	_ :: shard.Request
  	testing.expect(t, true, "shard_unit_test package compiles")
  }
  ```

- [ ] **Step 3.2: Run this package in isolation to confirm the collection flag works**

  ```
  odin test ./tests/unit -collection:shard=./src -define:ODIN_TEST_LOG_LEVEL=warning
  ```

  Expected: `1 test passed`.

- [ ] **Step 3.3: Commit**

  ```
  git add tests/unit/test_seed.odin
  git commit -m "feat: add tests/unit package with collection import"
  ```

---

## Task 4: Create `tests/integration/` package with helpers

**Files:**
- Create: `tests/integration/helpers.odin`
- Create: `tests/integration/test_seed.odin`

`helpers.odin` provides `make_test_node`, `cleanup_test_node`, and `dispatch` — the
three building blocks every integration test will use. `test_seed.odin` provides the
minimum `@(test)` proc to make the package runnable.

- [ ] **Step 4.1: Create `tests/integration/helpers.odin`**

  ```odin
  package shard_integration_test

  import "core:fmt"
  import "core:os"
  import os2 "core:os/os2"
  import "core:testing"
  import shard "shard:"

  // make_test_node creates an isolated in-process Node backed by a temp directory.
  // The node uses a zero Master_Key (no encryption). Call cleanup_test_node when done.
  // Use a unique name per test to avoid temp-dir collisions under parallel runs.
  make_test_node :: proc(
  	t: ^testing.T,
  	name := "test",
  ) -> (
  	node: shard.Node,
  	tmp: string,
  	ok: bool,
  ) {
  	base := os.get_env("TEMP")
  	if base == "" do base = "/tmp"
  	tmp = fmt.aprintf("%s/shard-test-%s", base, name)
  	os.make_directory(tmp)
  	data_path := fmt.aprintf("%s/node.shard", tmp)
  	defer delete(data_path) // node_init_test clones what it needs

  	master: shard.Master_Key // zero key — no encrypted content
  	node, ok = shard.node_init_test(name, master, data_path, 0)
  	if !ok {
  		testing.errorf(t, "make_test_node: node_init_test failed for path %s", data_path)
  	}
  	return
  }

  // cleanup_test_node flushes the node and removes the temp directory.
  cleanup_test_node :: proc(node: ^shard.Node, tmp: string) {
  	shard.daemon_flush_all(node)
  	os2.remove_all(tmp) // recursively removes the temp dir and all contents
  	delete(tmp)
  }

  // dispatch parses a YAML request string and calls daemon_dispatch in-process.
  // Fails the test if parsing fails. Returns the raw response string.
  dispatch :: proc(t: ^testing.T, node: ^shard.Node, yaml: string) -> string {
  	req, ok := shard.md_parse_request(yaml)
  	if !ok {
  		testing.errorf(t, "dispatch: md_parse_request failed for input:\n%s", yaml)
  		return ""
  	}
  	resp, _ := shard.daemon_dispatch(node, req)
  	return resp
  }
  ```

- [ ] **Step 4.2: Create `tests/integration/test_seed.odin`**

  ```odin
  package shard_integration_test

  import "core:strings"
  import "core:testing"

  // Smoke test — creates a test node and confirms it initialises without error.
  @(test)
  test_node_init :: proc(t: ^testing.T) {
  	node, tmp, ok := make_test_node(t)
  	testing.expect(t, ok, "node_init_test must succeed on a fresh temp dir")
  	defer cleanup_test_node(&node, tmp)
  }

  // Smoke test — confirms a minimal dispatch round-trip works.
  @(test)
  test_discover_empty :: proc(t: ^testing.T) {
  	node, tmp, ok := make_test_node(t)
  	testing.expect(t, ok, "node init")
  	defer cleanup_test_node(&node, tmp)

  	resp := dispatch(t, &node, "---\nop: discover\n---\n")
  	testing.expect(t, strings.contains(resp, `"status"`), resp)
  }
  ```

- [ ] **Step 4.3: Run the integration package in isolation**

  ```
  odin test ./tests/integration -collection:shard=./src -define:ODIN_TEST_LOG_LEVEL=warning
  ```

  Expected: `2 tests passed`.

- [ ] **Step 4.4: Commit**

  ```
  git add tests/integration/helpers.odin tests/integration/test_seed.odin
  git commit -m "feat: add tests/integration package with node helpers and smoke tests"
  ```

---

## Task 5: Update `justfile` to run `tests/unit` and `tests/integration`

**Files:**
- Modify: `justfile` — extend both `[unix]` and `[windows]` `test` recipes

- [ ] **Step 5.1: Read the current `justfile`** to see the exact indentation and formatting of the existing `test` recipes before editing.

- [ ] **Step 5.2: Replace the `[unix]` test recipe**

  The new recipe appends the top-level test loop after the existing `find src` loop.
  Use tabs for indentation (justfile requirement):

  ```just
  [unix]
  test: _mkdir_bin
  	#!/usr/bin/env bash
  	set -euo pipefail
  	find src -type d -name 'tests' | while read dir; do
  		echo ""
  		echo "▶ testing $dir..."
  		extra=""
  		[[ "$dir" == *fs/tests* ]] && extra="-define:ODIN_TEST_THREADS=1"
  		odin test "./$dir" -define:ODIN_TEST_LOG_LEVEL=warning $extra || exit 1
  	done
  	for dir in tests/unit tests/integration; do
  		[ -d "$dir" ] || continue
  		echo ""
  		echo "▶ testing $dir..."
  		odin test "./$dir" \
  			-collection:shard=./src \
  			-define:ODIN_TEST_LOG_LEVEL=warning || exit 1
  	done
  ```

- [ ] **Step 5.3: Replace the `[windows]` test recipe**

  ```just
  [windows]
  test: _mkdir_bin
  	#!powershell
  	$dirs = Get-ChildItem -Path "src" -Recurse -Directory -Filter "tests"
  	foreach ($d in $dirs) {
  		$rel = $d.FullName.Substring((Get-Location).Path.Length + 1) -replace "\\", "/"
  		Write-Host ""
  		Write-Host "▶ testing $rel..."
  		$extra = ""
  		if ($rel -like "*fs/tests*") { $extra = "-define:ODIN_TEST_THREADS=1" }
  		$cmd = "odin test `"./$rel`" -define:ODIN_TEST_LOG_LEVEL=warning -define:ODIN_TEST_SHORT_LOGS=true $extra"
  		Invoke-Expression $cmd
  		if ($LASTEXITCODE -ne 0) { exit 1 }
  	}
  	foreach ($dir in @("tests/unit", "tests/integration")) {
  		if (Test-Path $dir) {
  			Write-Host ""
  			Write-Host "▶ testing $dir..."
  			odin test "./$dir" `
  				-collection:shard=./src `
  				-define:ODIN_TEST_LOG_LEVEL=warning `
  				-define:ODIN_TEST_SHORT_LOGS=true
  			if ($LASTEXITCODE -ne 0) { exit 1 }
  		}
  	}
  ```

- [ ] **Step 5.4: Run `just test` end-to-end**

  ```
  just test
  ```

  Expected: all test runs pass including `tests/unit` and `tests/integration`.

- [ ] **Step 5.5: Commit**

  ```
  git add justfile
  git commit -m "build: extend justfile test target to run tests/unit and tests/integration"
  ```

---

## Task 6: Migrate `src/query/tests/query_test.odin` and remove `src/query/`

**Files:**
- Move: `src/query/tests/query_test.odin` → `tests/unit/test_query.odin`
- Delete: `src/query/tests/` directory
- Delete: `src/query/` directory

The existing file has `package query_tests` and a single placeholder test. It needs its
package name updated to `shard_unit_test` to join the unit test package.

- [ ] **Step 6.1: Read `src/query/tests/query_test.odin`** to see its full content.

- [ ] **Step 6.2: Create `tests/unit/test_query.odin`** with the content updated:
  - Change `package query_tests` → `package shard_unit_test`
  - Keep or improve the test content (the existing test is just a compile check — it can stay as-is or be replaced with a real test against `shard.fulltext_search` or `shard.search_query`)

  Minimum viable content:
  ```odin
  package shard_unit_test

  import "core:testing"
  import shard "shard:"

  // Confirms search_query returns empty results for an empty index.
  // Actual signature: search_query(entries: []Search_Entry, query: string, allocator?) -> []Search_Result
  @(test)
  test_search_query_empty_index :: proc(t: ^testing.T) {
  	index: [dynamic]shard.Search_Entry
  	results := shard.search_query(index[:], "anything")
  	testing.expect_value(t, len(results), 0)
  	delete(results)
  }
  ```

- [ ] **Step 6.3: Delete `src/query/tests/query_test.odin`**

  ```
  git rm src/query/tests/query_test.odin
  ```

- [ ] **Step 6.4: Remove the now-empty directories**

  ```bash
  # unix
  rmdir src/query/tests
  rmdir src/query
  ```
  ```powershell
  # windows
  Remove-Item -Recurse src/query
  ```

- [ ] **Step 6.5: Run `just test` to confirm everything still passes**

  ```
  just test
  ```

  Expected: all tests pass. The `src/query/tests` run no longer appears (directory gone).

- [ ] **Step 6.6: Run `just build` to confirm the main binary is unaffected**

  ```
  just build
  ```

  Expected: build succeeds.

- [ ] **Step 6.7: Commit**

  ```
  git add tests/unit/test_query.odin
  git rm src/query/tests/query_test.odin
  git commit -m "refactor: migrate src/query/tests to tests/unit, remove src/query/"
  ```

---

## Verification Checklist

After all tasks are complete, confirm:

- [ ] `just test` passes with output showing `▶ testing tests/unit...` and `▶ testing tests/integration...`
- [ ] `just build` produces `bin/shard` with no errors
- [ ] `src/` contains zero `@(test)` attributes — verify with: `grep -r "@(test)" src/`
- [ ] `src/query/` directory does not exist
- [ ] `tests/unit/` and `tests/integration/` exist and each contain at least one passing test
