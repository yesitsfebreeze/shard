# Design: operators.odin Semantic Split

**Date:** 2026-03-17  
**Status:** Approved  
**Scope:** Refactor `src/operators.odin` (2,229 lines) into a thin hub + 6 focused files

---

## Problem

`operators.odin` has grown to 2,229 lines with no natural stopping point. It owns at least
four unrelated concerns:

- Slot lifecycle (daemon internal state management)
- Cross-shard query, traversal, and scoring
- Transaction locking and event messaging
- In-memory topic cache

Every new addition lands here by default. Finding fleet/traverse logic requires scrolling
past transaction TTL code. Both `AGENTS.md` and `CONCEPT.txt` describe `daemon.odin` as the
file containing these concerns — but `daemon.odin` is actually only 489 lines. The
descriptions belong to `operators.odin`.

---

## Goal

- `operators.odin` becomes a thin hub: `Operators` struct, `Ops` global, shared types, constants
- Six focused files own the actual procs, grouped by semantic responsibility
- Zero behavior change — pure file reorganization
- No changes to call sites (`protocol.odin`, `mcp.odin`, `daemon.odin` still use `Ops.xxx`)
- Update `AGENTS.md` file map and `CONCEPT.txt` to match reality

---

## File Map (After)

| File | ~Lines | Responsibility |
|---|---|---|
| `src/operators.odin` | ~170 | Hub: `Operators` struct, `Ops` global wiring, shared constants and types |
| `src/ops_read.odin` | ~280 | Reading: `_op_access`, `_op_digest`, `_op_requires_key`, `_access_resolve_key`, slot internals (`_slot_get_or_create`, `_slot_load`, `_slot_set_key`, `_slot_build_index`, `_slot_verify_key`), `_find_registry_entry` |
| `src/ops_write.odin` | ~260 | Writing + routing: `_op_registry`, `_op_discover`, `_op_remember`, `_op_route_to_slot`, `_slot_dispatch`, `_slot_drain_write_queue`, `_slot_is_locked`, `_slot_clear_lock`, `_op_is_mutating`, `_op_emits_event`, `_op_modifies_gates`, `_sync_slot_gates`, `_valid_shard_name` |
| `src/ops_query.odin` | ~560 | Cross-shard search: `_op_global_query`, `_op_traverse`, `_traverse_layer0`, `_traverse_search_shards`, `_score_gates`, `_sort_wire_results`, `_negative_gate_rejects` |
| `src/ops_fleet.odin` | ~200 | Parallel dispatch: `_op_fleet`, `_fleet_task_proc`, `_fleet_task_execute`, `_build_fleet_msg`, `_build_fleet_task_json` |
| `src/ops_events.odin` | ~350 | Messaging + observability: `_op_transaction`, `_op_commit`, `_op_rollback`, `_op_notify`, `_op_events`, `_op_alert_response`, `_op_alerts`, `_record_consumption`, `_op_consumption_log`, `_shard_needs_attention`, `_emit_event` |
| `src/ops_cache.odin` | ~260 | Topic cache: `_op_cache`, `_cache_sync_context_mode`, `_registry_matches`, `_format_time` |

**Total: ~2,080 lines across 7 files** (was 2,229 in one)

---

## Key Decisions

### operators.odin as hub only
The `Operators` struct and `Ops` global remain in `operators.odin`. This is the seam that
`protocol.odin`, `mcp.odin`, and `daemon.odin` depend on. Those files do not change.

**Exception — `_op_cache`:** `_op_cache` is intentionally absent from the `Operators` struct
and `Ops` global. `daemon.odin:177` calls it directly by name (`_op_cache(node, req, allocator)`).
This is fine — Odin's flat package namespace means the split is transparent to callers.
The spec notes this to avoid confusion: `_op_cache` moving to `ops_cache.odin` compiles
correctly without any change to `daemon.odin`.

### All files are `package shard`
Odin's single-package model means no imports between files are needed. The split is purely
organizational — zero runtime or compilation impact.

### Slot lifecycle goes to ops_write.odin
Slot internals (`_slot_dispatch`, `_slot_drain_write_queue`, lock helpers) are fundamentally
about routing writes into a shard. They belong with write semantics.

Slot *loading* (`_slot_get_or_create`, `_slot_load`, key management) goes to `ops_read.odin`
because reading a shard requires loading it first — these procs are the prerequisite for
any read operation.

### ops_events.odin absorbs transactions
Transactions are locking + write-queue coordination + event emission. They are
observability/messaging infrastructure, not data mutations. Grouping them with notify,
events, and alerts keeps all the "things that happen around mutations" together.

### ops_cache.odin owns format_time and registry_matches
These two helpers are only called from cache-related code, so they travel with `ops_cache.odin`.

---

## What Does Not Change

- `protocol.odin` — no changes
- `mcp.odin` — no changes  
- `daemon.odin` — no changes
- `node.odin` — no changes
- All test files — no changes
- Wire protocol, behavior, op semantics — unchanged

---

## Documentation Updates Required

After the split, update:

1. **`AGENTS.md` file map** — replace the `src/operators.odin` row with 7 rows (one per new file),
   fix `daemon.odin` description (489 lines; actual contents: `daemon_dispatch` router,
   event/consumption persistence, slot eviction, registry scan + refresh, and LLM helpers
   `_truncate_to_budget` / `_ai_compact_content` for budget-aware content compaction)
2. **`docs/CONCEPT.txt`** — fix line ~422 which incorrectly attributes registry/slots/routing/
   traverse/global_query/transactions/digest/consumption to `daemon.odin`

---

## Success Criteria

- `just test-build` passes
- `just test` passes (all tests green)
- `operators.odin` is ≤200 lines and contains only the hub
- Each new file has a single clear responsibility statement in its header comment
- `AGENTS.md` and `CONCEPT.txt` accurately describe the new file layout
