# Shard Integration Test Playbook

This file is executed by an AI agent step by step. Each step has a command, expected output, and a result field to fill in. At the end, triage all failures by priority and fix P0 first.

**How to run:** Work through each phase in order. If Phase 1 fails, stop — the system is not in a runnable state. Fill in each `Result:` line with `PASS`, `FAIL: <actual output>`, or `SKIP: <reason>`.

All commands use `test-shard connect` via stdin pipe. Replace `<KEY>` with the 64-hex master key from your keychain.

---

## Phase 1 — Baseline

*If any step here fails, stop. The system cannot be tested further.*

### 1.1 Build

```bash
just test-build
```

**Expect:** Exits with code 0. No compiler errors or warnings. Binary exists at `bin/test-shard`.

Result:

---

### 1.2 Init

```bash
test-shard init
```

**Expect:** `.shards/` directory created. `config.yaml` (or equivalent) created. Keychain entry created. No errors printed.

*(If already initialized, this may print "already initialized" — that is acceptable.)*

Result:

---

### 1.3 Daemon starts and responds

```bash
test-shard daemon &
sleep 1
echo '---
op: registry
---' | test-shard connect
```

**Expect:** Response contains `status: ok`. A `registry` array is present (may be empty). No `err` field.

Result:

---

## Phase 2 — Core CRUD

*P0 — the system is useless without these.*

### 2.1 Create shard

```bash
echo '---
op: remember
name: test-playbook
purpose: Integration test scratch shard, safe to delete
tags: [test, integration]
---' | test-shard connect
```

**Expect:** `status: ok`. A `catalog` object returned with `name: test-playbook`. File `.shards/test-playbook.shard` exists on disk after response.

Result:

---

### 2.2 Write a thought

```bash
echo '---
op: write
name: test-playbook
description: canary thought for integration testing
agent: test-playbook
key: <KEY>
---
This is the canary content. It contains the word phosphorescent for uniqueness.' | test-shard connect
```

**Expect:** `status: ok`. An `id` field is present — a 32-character hex string. Save this ID; it is used in steps 2.3, 2.4, 2.5, 2.8, and 3.5.

Result:
Saved ID:

---

### 2.3 Read the thought back

```bash
echo '---
op: read
name: test-playbook
id: <ID from 2.2>
key: <KEY>
---' | test-shard connect
```

**Expect:** `status: ok`. `description` equals `canary thought for integration testing` exactly. `content` contains `phosphorescent`. `agent` equals `test-playbook`.

Result:

---

### 2.4 Keyword search

```bash
echo '---
op: search
name: test-playbook
query: canary
key: <KEY>
---' | test-shard connect
```

**Expect:** `status: ok`. Results array contains at least one entry where `description` includes `canary`. The ID from step 2.2 appears in results.

Result:

---

### 2.5 Semantic query

```bash
echo '---
op: query
name: test-playbook
query: unique glowing word used for testing
key: <KEY>
---' | test-shard connect
```

**Expect:** `status: ok`. Results array is non-empty. The canary thought (ID from 2.2) appears in the top 3 results.

Result:

---

### 2.6 Discover — shard appears in registry

```bash
echo '---
op: discover
---' | test-shard connect
```

**Expect:** `status: ok`. The `registry` array contains an entry with `name: test-playbook`.

Result:

---

### 2.7 Delete the thought

```bash
echo '---
op: delete
name: test-playbook
id: <ID from 2.2>
key: <KEY>
---' | test-shard connect
```

**Expect:** `status: ok`. No `err` field.

Result:

---

### 2.8 Confirm deletion

```bash
echo '---
op: read
name: test-playbook
id: <ID from 2.2>
key: <KEY>
---' | test-shard connect
```

**Expect:** `status: ok` with `err` containing `not found` (or equivalent). Content must NOT be returned.

Result:

---

## Phase 3 — Advanced Ops

*P1 — data quality features. Fix these after P0.*

### 3.1 Stale thought detection

Write a thought with a near-zero TTL, then immediately query stale:

```bash
echo '---
op: write
name: test-playbook
description: stale canary thought
agent: test-playbook
thought_ttl: 0.00001
key: <KEY>
---
This thought should appear as stale immediately.' | test-shard connect
```

Then:

```bash
echo '---
op: stale
name: test-playbook
threshold: 0.0
key: <KEY>
---' | test-shard connect
```

**Expect:** First response: `status: ok` with an `id`. Second response: `status: ok`, `results` array is non-empty, and the stale thought appears in it.

Result:

---

### 3.2 Compact suggest

```bash
echo '---
op: compact_suggest
name: test-playbook
mode: lossless
key: <KEY>
---' | test-shard connect
```

**Expect:** `status: ok`. A `suggestions` array is present (may be empty — that is fine). No `err` field.

Result:

---

### 3.3 Compact apply

```bash
echo '---
op: compact_apply
name: test-playbook
mode: lossless
key: <KEY>
---' | test-shard connect
```

**Expect:** `status: ok`. A `moved` field with an integer value ≥ 0. No `err` field.

Result:

---

### 3.4 Dump

```bash
echo '---
op: dump
name: test-playbook
key: <KEY>
---' | test-shard connect
```

**Expect:** `status: ok`. The `content` field contains valid Markdown starting with a YAML frontmatter block (`---`). A `title:` or `name:` field is present in that frontmatter.

Result:

---

### 3.5 Feedback — endorsement affects ranking

Write two thoughts, endorse one, and verify the endorsed one ranks higher.

```bash
echo '---
op: write
name: test-playbook
description: endorsed ranking test thought
agent: test-playbook
key: <KEY>
---
Ranking test content about memory management and allocation.' | test-shard connect
```

Save ID as `<ID-A>`. Then write a second thought:

```bash
echo '---
op: write
name: test-playbook
description: baseline ranking test thought
agent: test-playbook
key: <KEY>
---
Ranking test content about memory management and allocation.' | test-shard connect
```

Save ID as `<ID-B>`. Endorse `<ID-A>`:

```bash
echo '---
op: feedback
name: test-playbook
id: <ID-A>
feedback: endorse
key: <KEY>
---' | test-shard connect
```

Then query:

```bash
echo '---
op: query
name: test-playbook
query: memory management allocation
key: <KEY>
---' | test-shard connect
```

**Expect:** `status: ok` on all calls. In the final query results, `<ID-A>` appears before `<ID-B>` (higher rank due to endorsement boost).

Result:

---

## Phase 4 — Multi-Agent Coordination

*P2 — coordination features. Log failures to the `todos` shard if not fixing now.*

### 4.1 Fleet — parallel ops on two shards

First create a second scratch shard:

```bash
echo '---
op: remember
name: test-playbook-b
purpose: Second scratch shard for fleet test
---' | test-shard connect
```

Then run fleet:

```bash
echo '---
op: fleet
tasks:
  - shard: test-playbook
    op: write
    description: fleet write A
    agent: test-playbook
    key: <KEY>
    content: Written by fleet task A
  - shard: test-playbook-b
    op: catalog
---' | test-shard connect
```

**Expect:** `status: ok`. `fleet_results` array has 2 entries. First entry has `status: ok` with an `id`. Second entry has `status: ok` with catalog data for `test-playbook-b`.

Result:

---

### 4.2 Transaction — write queuing under lock

```bash
echo '---
op: transaction
name: test-playbook
ttl: 30
---' | test-shard connect
```

Save `lock_id` from response. Then immediately (while lock is held) send a write:

```bash
echo '---
op: write
name: test-playbook
description: queued write under lock
agent: test-playbook
key: <KEY>
---
This write should be queued.' | test-shard connect
```

**Expect:** First response: `status: ok` with `lock_id`. Second response: `status: ok` with message indicating write is queued (e.g. `write queued`).

Now commit:

```bash
echo '---
op: commit
name: test-playbook
lock_id: <lock_id>
---' | test-shard connect
```

Then search for the queued write:

```bash
echo '---
op: search
name: test-playbook
query: queued write under lock
key: <KEY>
---' | test-shard connect
```

**Expect:** Commit response: `status: ok`. Final search: results contain the queued write thought — confirming it executed after lock release.

Result:

---

### 4.3 Events — emit and read

```bash
echo '---
op: events
source: test-playbook
event_type: test_ping
agent: test-playbook
---' | test-shard connect
```

Then read events:

```bash
echo '---
op: events
shard: test-playbook
---' | test-shard connect
```

**Expect:** First response: `status: ok`. Second response: `status: ok`, `events` array contains an entry with `event_type: test_ping` and `agent: test-playbook`.

Result:

---

## Cleanup

### C.1 Remove test shards from disk

```bash
rm .shards/test-playbook.shard
rm .shards/test-playbook-b.shard
```

Then call discover:

```bash
echo '---
op: discover
---' | test-shard connect
```

**Expect:** `registry` no longer contains `test-playbook` or `test-playbook-b`.

Result:

---

## Summary

Fill this in after completing all steps.

### Failures

List each failed step, the actual output received, and expected output:

| Step | Expected | Actual |
|------|----------|--------|
|      |          |        |

### Triage

- **P0 failures** (Phase 1 or Phase 2): Fix immediately before any other work.
- **P1 failures** (Phase 3): Fix in the current session.
- **P2 failures** (Phase 4): Write a thought to the `todos` shard with priority `P2` and continue.

### Sign-off

Date run:
Agent:
Overall result: PASS / FAIL
