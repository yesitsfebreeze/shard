# CONCEPT.txt + AGENTS.md Documentation Fix (Workstream A) Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix `docs/CONCEPT.txt` and `AGENTS.md` to accurately describe the current codebase — correct the file map (daemon.odin vs operators.odin), update Milestone 3 status, and document the topic cache as it exists today.

**Architecture:** Pure documentation edits. No source files touched. Three tasks: (1) fix the file map in both docs, (2) update M3 milestone status, (3) add a TOPIC CACHE section describing current behavior. Commit each task separately.

**Tech Stack:** Text editing only. Build verification: `just test-build` (confirms no source was accidentally changed).

**Spec:** `docs/superpowers/specs/2026-03-17-concept-doc-update-design.md` — Workstream A sections.

---

## File Map

| File | Change |
|------|--------|
| `docs/CONCEPT.txt` | Fix daemon.odin description (~line 422); add ops_read.odin; update M3 milestone; add TOPIC CACHE section after TWO-BLOCK DESIGN |
| `AGENTS.md` | Fix daemon.odin row (~line 169); add ops_read.odin row |

---

## Task 1: Fix the file map

**Files:**
- Modify: `docs/CONCEPT.txt` line ~422 (IMPLEMENTATION section, source files table)
- Modify: `AGENTS.md` line ~169 (File Map table)

- [ ] **Step 1.1: Read the current IMPLEMENTATION section of CONCEPT.txt**

  Open `docs/CONCEPT.txt` and read the source files list (lines ~410–437). Confirm the current `daemon.odin` line reads:
  ```
  src/daemon.odin        Registry, in-process slots, routing, layered traverse (L0/L1/L2), global_query, transactions, digest, staleness, feedback, auto-compaction monitoring
  ```
  This is incorrect. `daemon.odin` is 489 lines and does NOT own any of those things.

- [ ] **Step 1.2: Read the current AGENTS.md file map**

  Open `AGENTS.md` and read the File Map table (lines ~165–185). Confirm the current `daemon.odin` row reads:
  ```
  | `src/daemon.odin` | ~2420 | Registry, slots, routing, layered traverse (L0/L1/L2), global_query, transactions, digest, consumption tracking |
  ```
  Both the line count (~2420) and description are wrong.

- [ ] **Step 1.3: Update CONCEPT.txt — replace the daemon.odin line**

  In `docs/CONCEPT.txt`, find the source files list. Replace the single `src/daemon.odin` line with these three lines:
  ```
    src/daemon.odin        ~489   daemon_dispatch router; slot eviction scheduling;
                                  registry scan/refresh on startup; LLM helpers
                                  (_truncate_to_budget, _ai_compact_content, _llm_post)
    src/operators.odin     ~1881  Operator hub: Operators struct, Ops global, shared
                                  constants; all ops not yet split out: write routing,
                                  query/traverse/global_query, fleet, events/transactions,
                                  consumption tracking, topic cache (_op_cache)
    src/ops_read.odin      ~355   Read ops: _op_access, _op_digest, _op_requires_key;
                                  slot loading (_slot_get_or_create, _slot_load,
                                  _slot_set_key, _slot_build_index, _slot_verify_key);
                                  _find_registry_entry
                                  (operators split in progress — see
                                  docs/superpowers/specs/2026-03-17-operators-split-design.md)
  ```

  Also update the line count on `src/mcp.odin` from `~1014` to `~1320` and `src/protocol.odin` from `~1290` to `~1858` while you're in this section — those are also stale.

- [ ] **Step 1.4: Update AGENTS.md — replace the daemon.odin row**

  In `AGENTS.md`, find the File Map table. Replace the `src/daemon.odin` row:
  ```
  | `src/daemon.odin` | ~489 | daemon_dispatch router, slot eviction scheduling, registry scan/refresh on startup, LLM helpers (_truncate_to_budget, _ai_compact_content, _llm_post) |
  ```

  After that row, add two new rows:
  ```
  | `src/operators.odin` | ~1881 | Operator hub + all ops not yet split out: write routing, query/traverse/global_query, fleet, events/transactions, consumption, topic cache (_op_cache) |
  | `src/ops_read.odin` | ~355 | Read ops: _op_access, _op_digest, slot loading (_slot_get_or_create, _slot_load, _slot_set_key, _slot_build_index, _slot_verify_key), _find_registry_entry (operators split in progress) |
  ```

  Also update the `src/mcp.odin` line count from `~1014` to `~1320` and `src/protocol.odin` from `~1290` to `~1858`.

- [ ] **Step 1.5: Verify build is unchanged**

  ```bash
  just test-build
  ```
  Expected: exits 0. This confirms no source file was accidentally touched.

- [ ] **Step 1.6: Commit**

  ```bash
  git add docs/CONCEPT.txt AGENTS.md
  git commit -m "docs: fix file map — daemon.odin actual role, add ops_read.odin, correct line counts"
  ```

---

## Task 2: Update Milestone 3 status

**Files:**
- Modify: `docs/CONCEPT.txt` — MILESTONE 3 paragraph in "WHERE THIS IS HEADED" section

- [ ] **Step 2.1: Read the current WHERE THIS IS HEADED section**

  Open `docs/CONCEPT.txt` and read lines ~376–399. Confirm the MILESTONE 3 entry currently says:
  ```
  New: global_query daemon op — searches all shards above a gate threshold,
  returns unified results with shard attribution, composite scoring, budget
  truncation. MCP shard_query uses global_query for cross-shard cases.
  Remaining: filtered cross-shard export, vault-level index, wikilink resolution.
  ```
  Both the "New" and "Remaining" sentences are stale.

- [ ] **Step 2.2: Replace the MILESTONE 3 body text**

  Replace the paragraph starting with "New: global_query..." through "wikilink resolution." with:
  ```
  Done: global_query is the default for shard_query (omit shard → searches all
  shards above threshold). vec_index persisted to .shards/.vec_index — no cold-
  start re-embedding on daemon restart.
  Remaining: filtered cross-shard export, vault-level Obsidian index, wikilink
  resolution.
  ```

- [ ] **Step 2.3: Verify build is unchanged**

  ```bash
  just test-build
  ```
  Expected: exits 0.

- [ ] **Step 2.4: Commit**

  ```bash
  git add docs/CONCEPT.txt
  git commit -m "docs: update milestone 3 status — global_query default done, vec_index persistence done"
  ```

---

## Task 3: Document the topic cache (current behavior)

**Files:**
- Modify: `docs/CONCEPT.txt` — add TOPIC CACHE section after TWO-BLOCK DESIGN and before WIRE PROTOCOL

- [ ] **Step 3.1: Read the TWO-BLOCK DESIGN section to find insertion point**

  Open `docs/CONCEPT.txt` and confirm the section order. The TWO-BLOCK DESIGN section ends with the MCP tools list for compaction (compact_suggest, compact, compact_apply). The next section is WIRE PROTOCOL. The new TOPIC CACHE section goes between those two.

- [ ] **Step 3.2: Insert the TOPIC CACHE section**

  After the closing of the TWO-BLOCK DESIGN section (after the last MCP compaction tool description), insert this full section before the WIRE PROTOCOL separator line:

  ```
  --------------------------------------------------------------------------------
  TOPIC CACHE — SHORT-TERM MEMORY
  --------------------------------------------------------------------------------

  Every agent session accumulates context: what was asked, what was useful, what
  decisions were made. The topic cache holds this as named, in-memory context
  that is shared across all agents connected to the same daemon.

  A topic cache is:
    - Named by topic (e.g. "auth-refactor", "bug-hunt-2026-03-17")
    - Shared: any agent reading the same topic sees all entries from all agents
    - FIFO-evicted when max_bytes is set on first write to the topic
    - In-memory only during daemon lifetime (not persisted across restarts yet —
      see MILESTONE 4 below)
    - On each write: a snapshot is synced to
      ~/.claude/context-mode/sessions/shard-cache-<topic>-events.md
      if that directory exists (best-effort, Claude-specific)

  MCP tools:
    shard_cache_write  Append an entry to a named topic (topic, content, agent, max_bytes)
    shard_cache_read   Read all entries for a topic as a markdown context document
    shard_cache_list   List all active topics with entry counts and sizes

  CACHE ENTRY
    Each entry has: id (random hex), agent (who wrote it), timestamp (RFC3339),
    content (free text). Entries render as ## [timestamp] agent / content when read.

  TYPICAL WORKFLOW (current)
    1. Start of session: shard_cache_list to see active topics
    2. shard_cache_read on relevant topics to load prior context
    3. Work — write entries as decisions or discoveries accumulate
    4. Context is available to any other agent on the same daemon for the session

  PLANNED IMPROVEMENTS (Milestone 4)
    - Persist cache to ~/.shards/sessions/<topic>.md across daemon restarts
    - Load sessions on daemon startup so new agents see prior context
    - Auto-compact via LLM at configurable entry threshold (CACHE_COMPACT_THRESHOLD)
    - Replace raw entries with a single compacted summary on threshold
  ```

- [ ] **Step 3.3: Update the DAEMON entity section**

  Find the DAEMON section under KEY ENTITIES (around line 105–120). After the `- consumption log` entry, add:
  ```
      - topic cache    — named in-memory Cache_Slots, one per topic.
                         Shared across all agents. FIFO-evicted when max_bytes set.
                         Cleared per-topic via cache clear action.
  ```

- [ ] **Step 3.4: Update the one-sentence definition**

  Find the ONE-SENTENCE DEFINITION section at the top of CONCEPT.txt. Replace:
  ```
  A shard is an encrypted thought store loaded in-process by a daemon that
  acts as the nervous system for a self-improving second brain.
  ```
  With:
  ```
  Shard is an encrypted knowledge system with two memory layers: long-term
  thought stores (encrypted, persistent, per-topic shards) and short-term topic
  caches (named, in-memory, shared across agents, auto-compacting in a future
  milestone).
  ```

- [ ] **Step 3.5: Verify build is unchanged**

  ```bash
  just test-build
  ```
  Expected: exits 0.

- [ ] **Step 3.6: Commit**

  ```bash
  git add docs/CONCEPT.txt
  git commit -m "docs: add TOPIC CACHE section — document short-term memory layer as currently implemented"
  ```

---

## After All Tasks

- [ ] **Final check: read CONCEPT.txt in full** to confirm it reads coherently end-to-end. Look for any remaining references to `daemon.odin` owning routing/slots/traverse that slipped through.

- [ ] **Final check: read the AGENTS.md file map** and confirm all rows are accurate (no ~2420 line count anywhere, no "Registry, slots, routing..." in daemon.odin description).
