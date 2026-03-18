# Test Suite Design — Separated `tests/` Folder

**Date:** 2026-03-18  
**Status:** Approved

---

## Goal

Move test code out of `src/` into a dedicated `tests/` folder at the project root. Tests import the source package via an Odin collection, giving them access to all public symbols. The source tree is clean of test files except for a narrow exception (see below). The test binary is ephemeral — built, run, discarded.

---

## Directory Structure

```
tests/
  unit/
    package shard_unit_test
    test_crypto.odin
    test_blob.odin
    test_markdown.odin
    test_search.odin
    (one file per logical area)
  integration/
    package shard_integration_test
    helpers.odin
    test_write_read.odin
    test_query.odin
    test_dispatch.odin
    test_events.odin
    (one file per feature area)
```

---

## Package and Import Convention

Both test packages import `src/` via a named collection called `shard`:

```odin
import shard "shard:"
```

The collection is resolved at test-run time by passing `-collection:shard=./src` to `odin test`. This makes all public symbols in `package shard` available under the `shard.` prefix.

Example:
```odin
package shard_unit_test

import "core:strings"
import "core:testing"
import shard "shard:"

@(test)
test_md_parse_roundtrip :: proc(t: ^testing.T) {
    input := "---\nop: write\nname: foo\n---\n"
    req, ok := shard.md_parse_request(input)
    testing.expect(t, ok, "parse should succeed")
    testing.expect_value(t, req.op, "write")
}
```

---

## Two Test Layers

### Unit (`tests/unit/`)

- Tests individual public procedures in isolation
- No `Node`, no disk I/O, no daemon
- Covers: `md_parse_request`, `md_marshal_response`, `crypto_*`, `blob_load`/`blob_put`/`blob_get`, `search_query`, `fulltext_search`, etc.
- Fast, deterministic, no cleanup needed

### Integration (`tests/integration/`)

- Tests full request/response flow through `daemon_dispatch` in-process
- Builds a `Node` in-process using a new `node_init_test` helper (see below)
- Calls `daemon_dispatch` directly — no IPC, no separate process
- Asserts on the returned JSON/YAML response string
- Each test creates its own isolated temp dir and cleans up on exit

---

## New `node_init_test` in `src/node.odin`

`node_init` unconditionally starts an IPC listener, which is incompatible with in-process
tests (no pipe name to bind, parallel tests would conflict). A new public procedure
`node_init_test` is added to `src/node.odin` that performs everything `node_init` does
except starting the IPC listener:

```odin
// node_init_test creates an in-process Node for testing. No IPC listener is started.
// Use daemon_dispatch directly; do not call node_run.
// idle_timeout defaults to 0 (no eviction). is_daemon is always false.
node_init_test :: proc(
    name: string,
    master: Master_Key,
    data_path: string,
    idle_timeout: time.Duration = 0,
) -> (node: Node, ok: bool) {
    // same as node_init but skips ipc_listen entirely
}
```

This proc is public so `tests/integration/` can call `shard.node_init_test(...)`.

---

## Integration Test Helpers (`tests/integration/helpers.odin`)

```odin
package shard_integration_test

import "core:os"
import "core:strings"
import "core:testing"
import shard "shard:"

// make_test_node creates an isolated Node with a zero master key in a temp dir.
// Returns the node and the temp path. Caller must defer cleanup_test_node.
make_test_node :: proc(t: ^testing.T, name := "test") -> (node: shard.Node, tmp: string, ok: bool) {
    tmp = os.get_env("TEMP") or_else "/tmp"
    tmp = strings.concatenate({tmp, "/shard-test-", name})
    os.make_directory(tmp)
    master: shard.Master_Key  // zero key
    node, ok = shard.node_init_test(name, master, strings.concatenate({tmp, "/node.shard"}), 0)
    return
}

// cleanup_test_node flushes and removes the temp directory.
cleanup_test_node :: proc(node: ^shard.Node, tmp: string) {
    shard.daemon_flush_all(node)
    // remove tmp dir recursively
}

// dispatch parses yaml and calls daemon_dispatch. Fails the test if parse fails.
dispatch :: proc(t: ^testing.T, node: ^shard.Node, yaml: string) -> string {
    req, ok := shard.md_parse_request(yaml)
    testing.expect(t, ok, "dispatch: md_parse_request failed")
    resp, _ := shard.daemon_dispatch(node, req)
    return resp
}
```

A typical integration test:
```odin
@(test)
test_write_then_read :: proc(t: ^testing.T) {
    node, tmp, ok := make_test_node(t)
    testing.expect(t, ok, "node init must succeed")
    defer cleanup_test_node(&node, tmp)

    resp := dispatch(t, &node, "---\nop: remember\nname: test-shard\npurpose: test\n---\n")
    testing.expect(t, strings.contains(resp, `"status":"ok"`), resp)

    resp2 := dispatch(t, &node, "---\nop: write\nname: test-shard\ndescription: hello\ncontent: world\n---\n")
    testing.expect(t, strings.contains(resp2, `"status":"ok"`), resp2)
}
```

---

## Exception: Private-helper tests stay in `src/`

`src/search.odin` contains 4 `@(test)` procs that test `@(private)` helpers
(`_compute_windows`, `_fulltext_hit_density`). These cannot be moved to `tests/unit/`
because external packages cannot access `@(private)` symbols. They stay in `src/search.odin`.

**Invariant (revised):** `src/` contains no test files except inline `@(test)` procs that
test `@(private)` symbols that have no public equivalent. All other tests live in `tests/`.

---

## Justfile Changes

The `test` target currently scans `src/` for subdirectories named `tests`. It is extended
to also run `tests/unit` and `tests/integration` with the `-collection:shard=./src` flag.

### Unix (`[unix]` recipe)
```bash
[unix]
test: _mkdir_bin
    #!/usr/bin/env bash
    set -euo pipefail
    # existing: src sub-package tests
    find src -type d -name 'tests' | while read dir; do
        echo ""
        echo "▶ testing $dir..."
        extra=""
        [[ "$dir" == *fs/tests* ]] && extra="-define:ODIN_TEST_THREADS=1"
        odin test "./$dir" -define:ODIN_TEST_LOG_LEVEL=warning $extra || exit 1
    done
    # new: top-level test packages
    for dir in tests/unit tests/integration; do
        [ -d "$dir" ] || continue
        echo ""
        echo "▶ testing $dir..."
        odin test "./$dir" \
            -collection:shard=./src \
            -define:ODIN_TEST_LOG_LEVEL=warning || exit 1
    done
```

### Windows (`[windows]` recipe)
```powershell
[windows]
test: _mkdir_bin
    #!powershell
    # existing: src sub-package tests (unchanged)
    $dirs = Get-ChildItem -Path "src" -Recurse -Directory -Filter "tests"
    foreach ($d in $dirs) {
        $rel = $d.FullName.Substring((Get-Location).Path.Length + 1) -replace "\\", "/"
        Write-Host ""; Write-Host "▶ testing $rel..."
        $extra = ""
        if ($rel -like "*fs/tests*") { $extra = "-define:ODIN_TEST_THREADS=1" }
        $cmd = "odin test `"./$rel`" -define:ODIN_TEST_LOG_LEVEL=warning -define:ODIN_TEST_SHORT_LOGS=true $extra"
        Invoke-Expression $cmd
        if ($LASTEXITCODE -ne 0) { exit 1 }
    }
    # new: top-level test packages
    foreach ($dir in @("tests/unit", "tests/integration")) {
        if (Test-Path $dir) {
            Write-Host ""; Write-Host "▶ testing $dir..."
            odin test "./$dir" `
                -collection:shard=./src `
                -define:ODIN_TEST_LOG_LEVEL=warning `
                -define:ODIN_TEST_SHORT_LOGS=true
            if ($LASTEXITCODE -ne 0) { exit 1 }
        }
    }
```

---

## Migration Plan

1. Add `node_init_test` to `src/node.odin`
2. Create `tests/unit/` and `tests/integration/` directories
3. Write `tests/integration/helpers.odin` with `make_test_node`, `cleanup_test_node`, `dispatch`
4. Write seed test files in both packages (at minimum one `@(test)` proc each so `odin test` succeeds)
5. Update `justfile` `test` target for both Unix and Windows
6. Verify `just test` passes end-to-end
7. Move `src/query/tests/query_test.odin` → `tests/unit/test_query.odin`, update package name to `shard_unit_test`
8. Delete `src/query/tests/` and `src/query/` (now empty)
9. Verify `just test` still passes
10. Verify `just build` passes (`src/` unaffected)

---

## Invariants

- `src/` contains no test files, except inline `@(test)` procs testing `@(private)` symbols (currently only in `src/search.odin`)
- `odin build ./src` is unaffected — test packages are never compiled into the main binary
- Both `tests/unit` and `tests/integration` are skipped gracefully if the directory does not exist
- The `-collection:shard=./src` flag is only passed to runs under `tests/`, not to runs under `src/`
- All test runs use `-define:ODIN_TEST_LOG_LEVEL=warning` for clean output
- Each integration test is fully isolated: its own temp dir, created and cleaned up per test

---

## Out of Scope

- No IPC/named-pipe end-to-end tests (in-process `daemon_dispatch` is sufficient)
- No test runner beyond `odin test` (no custom harness)
- No code coverage tooling
- No mocking framework (use real types with zero/temp values)
