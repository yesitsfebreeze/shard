# operators.odin Semantic Split Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split `src/operators.odin` (2,229 lines) into a thin hub file plus 6 focused files grouped by semantic responsibility, with zero behavior change.

**Architecture:** All files stay in `package shard` — Odin's flat package model means no imports are needed between them. The split is purely organisational. `operators.odin` keeps only the `Operators` struct, the `Ops` global wiring, shared types and constants. The 6 new files each own one clearly-named responsibility.

**Tech Stack:** Odin, `just` build system. Build: `just test-build`. Test: `just test`.

**Spec:** `docs/superpowers/specs/2026-03-17-operators-split-design.md`

---

## File Map

| Action | File | Contents after this plan |
|---|---|---|
| Trim | `src/operators.odin` | Hub only: `Operators` struct, `Ops` global, `Gate_Score`, `_Scored_Shard`, `_Fleet_Thread_Data`, constants |
| Create | `src/ops_read.odin` | `_op_access`, `_op_digest`, `_op_requires_key`, `_access_resolve_key`, `_find_registry_entry`, `_slot_get_or_create`, `_slot_load`, `_slot_set_key`, `_slot_build_index`, `_slot_verify_key` |
| Create | `src/ops_write.odin` | `_op_registry`, `_op_discover`, `_op_remember`, `_op_route_to_slot`, `_slot_dispatch`, `_slot_drain_write_queue`, `_slot_is_locked`, `_slot_clear_lock`, `_op_is_mutating`, `_op_emits_event`, `_op_modifies_gates`, `_sync_slot_gates`, `_valid_shard_name` |
| Create | `src/ops_query.odin` | `_op_global_query`, `_op_traverse`, `_traverse_layer0`, `_traverse_search_shards`, `_score_gates`, `_sort_wire_results`, `_negative_gate_rejects` |
| Create | `src/ops_fleet.odin` | `_op_fleet`, `_fleet_task_proc`, `_fleet_task_execute`, `_build_fleet_msg`, `_build_fleet_task_json` |
| Create | `src/ops_events.odin` | `_op_transaction`, `_op_commit`, `_op_rollback`, `_op_notify`, `_op_events`, `_op_alert_response`, `_op_alerts`, `_record_consumption`, `_op_consumption_log`, `_shard_needs_attention`, `_emit_event` |
| Create | `src/ops_cache.odin` | `_op_cache`, `_cache_sync_context_mode`, `_registry_matches`, `_format_time` |
| Update | `AGENTS.md` | Fix file map table — 7 new rows replacing the `operators.odin` row; fix `daemon.odin` description |
| Update | `docs/CONCEPT.txt` | Fix ~line 422 — move the ops description from `daemon.odin` to the correct files |

**No other files change.** `protocol.odin`, `mcp.odin`, `daemon.odin`, `node.odin`, all test files — untouched.

---

## Important Context for Implementors

- **This is a pure move.** Copy procs verbatim — do not rename, reformulate, or refactor logic.
- **Each new file needs `package shard` at the top** and exactly the imports that its procs use. Check each proc's imports individually rather than copying the full import block from `operators.odin`.
- **`operators.odin` imports** — after trimming, it only needs what the hub types use: `core:sync`, `core:thread` (for `_Fleet_Thread_Data`). Remove unused imports.
- **`_op_cache` is not in `Operators`/`Ops`** — it is called directly as `_op_cache(node, req, allocator)` from `daemon.odin:177`. Moving it to `ops_cache.odin` works without any change to `daemon.odin`.
- **Build verification after every task** — run `just test-build` before committing. Odin will tell you immediately if an import is missing or a proc reference is broken.
- **Line ranges in `operators.odin`** (for reference while cutting):

| Procs | Lines |
|---|---|
| Hub (struct + Ops + types) | 1–166 |
| `_op_registry`, `_op_discover`, `_op_remember` | 167–252 |
| `_op_route_to_slot`, `_slot_dispatch` | 253–420 |
| `_op_transaction`, `_op_commit`, `_op_rollback`, lock helpers | 421–527 |
| `_op_is_mutating` | 529–546 |
| `_op_alert_response`, `_op_alerts`, `_op_notify`, `_op_events`, `_emit_event` | 548–763 |
| `_op_requires_key`, `_op_access`, `_op_digest` | 765–1024 |
| `_access_resolve_key`, `_find_registry_entry`, slot internals | 1025–1113 |
| `_op_traverse`, `_traverse_layer0`, `_traverse_search_shards` | 1114–1368 |
| `_op_global_query`, scoring helpers | 1369–1658 |
| `_record_consumption`, `_op_consumption_log`, `_shard_needs_attention` | 1659–1722 |
| `_op_fleet`, fleet helpers | 1723–1924 |
| `_op_emits_event`, `_op_modifies_gates`, `_sync_slot_gates`, `_valid_shard_name` | 1925–1971 |
| `_op_cache`, `_cache_sync_context_mode`, `_registry_matches`, `_format_time`, fleet JSON helpers | 1972–2229 |

---

## Task 1: Create `ops_read.odin`

**Files:**
- Create: `src/ops_read.odin`
- Modify: `src/operators.odin` (remove these procs after verifying build)

- [ ] **Step 1: Create `src/ops_read.odin`**

  Copy these procs verbatim from `operators.odin` (lines 765–1113):
  - `_op_requires_key` (line 765)
  - `_op_access` (line 784)
  - `_op_digest` (line 950)
  - `_access_resolve_key` (line 1025)
  - `_find_registry_entry` (line 1033)
  - `_slot_get_or_create` (line 1042)
  - `_slot_load` (line 1056)
  - `_slot_set_key` (line 1086)
  - `_slot_build_index` (line 1096)
  - `_slot_verify_key` (line 1100)

  File header:
  ```odin
  // ops_read.odin — read operations: shard access, digest, slot loading, key management
  package shard
  
  import "core:fmt"
  import "core:os"
  import "core:strings"
  import "core:time"
  
  import logger "logger"
  ```

  Then paste the procs exactly as they appear in `operators.odin`.

- [ ] **Step 2: Build to confirm new file compiles**

  Run: `just test-build`
  Expected: build succeeds (procs now exist in two places — that's fine for now)

- [ ] **Step 3: Remove the procs from `operators.odin`**

  Delete lines 765–1113 from `operators.odin` (the 10 procs listed above). Save the file.

- [ ] **Step 4: Build to confirm nothing broke**

  Run: `just test-build`
  Expected: build succeeds with no errors

- [ ] **Step 5: Run tests**

  Run: `just test`
  Expected: all tests pass

- [ ] **Step 6: Commit**

  ```bash
  git add src/ops_read.odin src/operators.odin
  git commit -m "refactor: extract read ops into ops_read.odin"
  ```

---

## Task 2: Create `ops_write.odin`

**Files:**
- Create: `src/ops_write.odin`
- Modify: `src/operators.odin`

- [ ] **Step 1: Create `src/ops_write.odin`**

  Copy these procs verbatim from `operators.odin`:
  - `_op_registry` (line 167)
  - `_op_discover` (line 193)
  - `_op_remember` (line 199)
  - `_op_route_to_slot` (line 253)
  - `_slot_dispatch` (line 312)
  - `_slot_drain_write_queue` (line 495)
  - `_slot_is_locked` (line 511)
  - `_slot_clear_lock` (line 521)
  - `_op_is_mutating` (line 529)
  - `_op_emits_event` (line 1925)
  - `_op_modifies_gates` (line 1933)
  - `_sync_slot_gates` (line 1947)
  - `_valid_shard_name` (line 1960)

  File header:
  ```odin
  // ops_write.odin — write operations: shard creation, routing, slot dispatch, mutation classification
  package shard
  
  import "core:fmt"
  import "core:strings"
  import "core:time"
  
  import logger "logger"
  ```

- [ ] **Step 2: Build**

  Run: `just test-build`
  Expected: build succeeds

- [ ] **Step 3: Remove the procs from `operators.odin`**

  Delete the 13 procs listed above from `operators.odin`. They are at lines 167–252, 253–420, 495–546, and 1925–1971 (adjust for any shifts from Task 1).

- [ ] **Step 4: Build and test**

  Run: `just test-build && just test`
  Expected: build succeeds, all tests pass

- [ ] **Step 5: Commit**

  ```bash
  git add src/ops_write.odin src/operators.odin
  git commit -m "refactor: extract write ops into ops_write.odin"
  ```

---

## Task 3: Create `ops_query.odin`

**Files:**
- Create: `src/ops_query.odin`
- Modify: `src/operators.odin`

- [ ] **Step 1: Create `src/ops_query.odin`**

  Copy these procs verbatim from `operators.odin`:
  - `_op_traverse` (line 1114)
  - `_traverse_layer0` (line 1202)
  - `_traverse_search_shards` (line 1287)
  - `_op_global_query` (line 1369)
  - `_sort_wire_results` (line 1516)
  - `_negative_gate_rejects` (line 1528)
  - `_score_gates` (line 1542)

  File header:
  ```odin
  // ops_query.odin — query operations: cross-shard search, traversal, gate scoring
  package shard
  
  import "core:fmt"
  import "core:strings"
  import "core:time"
  
  import logger "logger"
  ```

- [ ] **Step 2: Build**

  Run: `just test-build`
  Expected: build succeeds

- [ ] **Step 3: Remove the procs from `operators.odin`**

  Delete the 7 procs listed above from `operators.odin`.

- [ ] **Step 4: Build and test**

  Run: `just test-build && just test`
  Expected: build succeeds, all tests pass

- [ ] **Step 5: Commit**

  ```bash
  git add src/ops_query.odin src/operators.odin
  git commit -m "refactor: extract query ops into ops_query.odin"
  ```

---

## Task 4: Create `ops_fleet.odin`

**Files:**
- Create: `src/ops_fleet.odin`
- Modify: `src/operators.odin`

- [ ] **Step 1: Create `src/ops_fleet.odin`**

  Copy these procs verbatim from `operators.odin`:
  - `_op_fleet` (line 1723)
  - `_fleet_task_proc` (line 1871)
  - `_fleet_task_execute` (line 1877)
  - `_build_fleet_msg` (line 2211)
  - `_build_fleet_task_json` (line 2217)

  File header:
  ```odin
  // ops_fleet.odin — fleet operations: parallel multi-shard task dispatch
  package shard
  
  import "core:fmt"
  import "core:strings"
  import "core:sync"
  import "core:thread"
  import "core:time"
  
  import logger "logger"
  ```

- [ ] **Step 2: Build**

  Run: `just test-build`
  Expected: build succeeds

- [ ] **Step 3: Remove the procs from `operators.odin`**

  Delete the 5 procs listed above from `operators.odin`.

- [ ] **Step 4: Build and test**

  Run: `just test-build && just test`
  Expected: build succeeds, all tests pass

- [ ] **Step 5: Commit**

  ```bash
  git add src/ops_fleet.odin src/operators.odin
  git commit -m "refactor: extract fleet ops into ops_fleet.odin"
  ```

---

## Task 5: Create `ops_events.odin`

**Files:**
- Create: `src/ops_events.odin`
- Modify: `src/operators.odin`

- [ ] **Step 1: Create `src/ops_events.odin`**

  Copy these procs verbatim from `operators.odin`:
  - `_op_transaction` (line 421)
  - `_op_commit` (line 449)
  - `_op_rollback` (line 474)
  - `_op_alert_response` (line 548)
  - `_op_alerts` (line 585)
  - `_op_notify` (line 631)
  - `_op_events` (line 694)
  - `_emit_event` (line 729)
  - `_record_consumption` (line 1659)
  - `_op_consumption_log` (line 1684)
  - `_shard_needs_attention` (line 1709)

  File header:
  ```odin
  // ops_events.odin — event operations: transactions, alerts, notifications, consumption tracking
  package shard
  
  import "core:fmt"
  import "core:strings"
  import "core:time"
  
  import logger "logger"
  ```

- [ ] **Step 2: Build**

  Run: `just test-build`
  Expected: build succeeds

- [ ] **Step 3: Remove the procs from `operators.odin`**

  Delete the 11 procs listed above from `operators.odin`.

- [ ] **Step 4: Build and test**

  Run: `just test-build && just test`
  Expected: build succeeds, all tests pass

- [ ] **Step 5: Commit**

  ```bash
  git add src/ops_events.odin src/operators.odin
  git commit -m "refactor: extract event ops into ops_events.odin"
  ```

---

## Task 6: Create `ops_cache.odin`

**Files:**
- Create: `src/ops_cache.odin`
- Modify: `src/operators.odin`

- [ ] **Step 1: Create `src/ops_cache.odin`**

  Copy these procs verbatim from `operators.odin`:
  - `_op_cache` (line 1990)
  - `_cache_sync_context_mode` (line 2136)
  - `_registry_matches` (line 2171)
  - `_format_time` (line 2204)

  File header:
  ```odin
  // ops_cache.odin — cache operations: in-memory topic cache, context-mode sync
  package shard
  
  import "core:fmt"
  import "core:os"
  import "core:strings"
  import "core:time"
  ```

- [ ] **Step 2: Build**

  Run: `just test-build`
  Expected: build succeeds

- [ ] **Step 3: Remove the procs from `operators.odin`**

  Delete the 4 procs listed above from `operators.odin`. After this, `operators.odin` should contain only the hub content (lines 1–166 of the original): `package shard`, imports, constants, `Gate_Score`, `_Scored_Shard`, `_Fleet_Thread_Data`, `Operators` struct, and `Ops` global.

- [ ] **Step 4: Trim unused imports from `operators.odin`**

  After all procs are removed, `operators.odin` no longer uses `os`, `fmt`, `strings`, `thread`, or `time` directly. Check which imports the remaining hub content actually uses:
  - `sync` — yes, `_Fleet_Thread_Data` has `slot_mu: ^sync.Mutex`
  - `thread` — yes, `_Fleet_Thread_Data` has `node: ^Node` and `task: Fleet_Task` but thread type is used in `ops_fleet.odin`; check if the struct field needs it
  - Remove any import that the hub content doesn't reference

  Run `just test-build` after each import removal to confirm.

- [ ] **Step 5: Build and test**

  Run: `just test-build && just test`
  Expected: build succeeds, all tests pass

- [ ] **Step 6: Verify `operators.odin` is hub-only**

  Check that `operators.odin` contains only:
  - `package shard`
  - Imports (only what the hub types need)
  - `DEFAULT_TRANSACTION_TTL` and `ACCESS_MIN_SCORE` constants
  - `Gate_Score`, `_Scored_Shard`, `_Fleet_Thread_Data` type definitions
  - `Operators` struct
  - `Ops` global

  It should be ≤200 lines. If it's larger, something was missed.

- [ ] **Step 7: Commit**

  ```bash
  git add src/ops_cache.odin src/operators.odin
  git commit -m "refactor: extract cache ops into ops_cache.odin, operators.odin is now hub-only"
  ```

---

## Task 7: Update documentation

**Files:**
- Modify: `AGENTS.md`
- Modify: `docs/CONCEPT.txt`

- [ ] **Step 1: Update `AGENTS.md` file map**

  Find the file map table in `AGENTS.md`. Replace the single `src/operators.odin` row with these 7 rows:

  ```
  | `src/operators.odin` | ~170 | Hub: `Operators` struct, `Ops` global wiring, shared types (`Gate_Score`, `_Scored_Shard`, `_Fleet_Thread_Data`), constants |
  | `src/ops_read.odin` | ~280 | Read ops: shard access, digest, slot loading, key management (`_op_access`, `_op_digest`, slot internals) |
  | `src/ops_write.odin` | ~320 | Write ops: shard creation, routing, slot dispatch, mutation classification (`_op_registry`, `_op_remember`, `_slot_dispatch`) |
  | `src/ops_query.odin` | ~560 | Query ops: cross-shard search, traversal, gate scoring (`_op_global_query`, `_op_traverse`, `_score_gates`) |
  | `src/ops_fleet.odin` | ~200 | Fleet ops: parallel multi-shard task dispatch (`_op_fleet`, thread workers) |
  | `src/ops_events.odin` | ~350 | Event ops: transactions, alerts, notifications, consumption tracking |
  | `src/ops_cache.odin` | ~260 | Cache ops: in-memory topic cache, context-mode sync (`_op_cache`) |
  ```

  Also fix the `daemon.odin` row to read:
  ```
  | `src/daemon.odin` | ~489 | Daemon lifecycle: `daemon_dispatch` router, event/consumption persistence, slot eviction, registry scan, LLM helpers (`_truncate_to_budget`, `_ai_compact_content`) |
  ```

- [ ] **Step 2: Update `docs/CONCEPT.txt`**

  Find the section (~line 422) that attributes the following to `daemon.odin`:
  > Registry, in-process slots, routing, layered traverse (L0/L1/L2), global_query, transactions, digest, consumption tracking

  Replace it with accurate descriptions referencing the new files. The actual `daemon.odin` owns: daemon startup, dispatch routing, slot eviction, event/consumption persistence, registry scanning, and LLM-assisted content compaction.

- [ ] **Step 3: Build and test one final time**

  Run: `just test-build && just test`
  Expected: build succeeds, all tests pass

- [ ] **Step 4: Commit**

  ```bash
  git add AGENTS.md docs/CONCEPT.txt
  git commit -m "docs: update AGENTS.md and CONCEPT.txt to reflect operators.odin split"
  ```

---

## Final Verification

- [ ] `operators.odin` is ≤200 lines and contains only hub content
- [ ] Each new `ops_*.odin` file has a single-line responsibility comment at the top
- [ ] `just test-build` passes cleanly
- [ ] `just test` passes — all tests green
- [ ] `AGENTS.md` file map has 7 new rows and an accurate `daemon.odin` description
- [ ] `docs/CONCEPT.txt` no longer misattributes ops to `daemon.odin`
