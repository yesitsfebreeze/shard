# Agent Instructions

Read this file first. It defines how to work on this codebase and how to use the shard system.

## Project

Shard is an encrypted thought store written in Odin. Single binary, runs as daemon/node/CLI/MCP server. Stores knowledge in encrypted `.shard` files. AI agents interact via MCP (JSON-RPC over stdio) or IPC (named pipes on Windows, Unix sockets on POSIX). Wire protocol is Markdown with YAML frontmatter.

## Setup

```bash
just build              # build the binary
shard init              # create .shards/, keychain, config (first time only)
shard daemon &          # start the daemon
shard mcp               # start MCP server (connects to daemon automatically)
```

To connect your AI tool, read `.agent/setup.md` — it has per-tool installation instructions.

Or pipe messages directly via CLI:

```bash
echo '---
op: registry
---' | shard connect
```

## Shard System

Shards are the shared knowledge layer. Specs, todos, decisions, and architecture all live in shards — not markdown files on disk. Any agent can read and write to them.

### Connecting

MCP tools are prefixed `shard_` (e.g., `shard_discover`, `shard_write`, `shard_dump`). If MCP is not available, pipe YAML frontmatter messages through `shard connect`.

### Current Shards

| Shard | Purpose |
|-------|---------|
| `architecture` | System design, daemon, IPC, crypto, protocol, file format |
| `milestones` | Milestone status tracking (M1 complete, M2 in progress, etc.) |
| `decisions` | Technical decisions and rationale |
| `todos` | Prioritized implementation tasks sorted by impact (P0-P9) |
| `spec-*` | Feature specifications (one per feature) |

Use `shard_discover` to see all shards. Use `shard_query` with a topic to find the best matching shard automatically.

### Startup Workflow

At the beginning of every task, before writing any code:

1. **Get the big picture** — call `shard_discover` with no params. This returns a compressed table-of-contents of every shard: names, purposes, thought counts, and thought descriptions (not full content). One call, ~500 tokens. This is your map.
2. **Check for pending events** — use the events op for shards relevant to your task. Events tell you what other agents changed since your last session.
3. **Load targeted context** — use `shard_query` with a `budget` parameter to get just enough context for your task. Budget caps the total content characters returned and truncates results that don't fit. Start with `budget: 2000` — if a result shows `truncated: true`, you can drill deeper with `shard_read` on that specific thought.
4. **Read project rules** — this file and `docs/CONCEPT.txt` are the ground truth.
5. **Plan your work** — with context from shards + project docs, plan before touching code.

**Token-efficient pattern:** `shard_discover` → `shard_query(budget: 2000)` → maybe one `shard_read`. This replaces the old pattern of dumping multiple full shards (~12,500 tokens) with ~800-2,800 tokens.

### During Work

- **Write findings** to the appropriate shard. Good candidates: architecture decisions, bug root causes, API changes, performance observations, cross-cutting concerns.
- **Use descriptive names**. The description field is what search indexes on. Be specific.
- **Set the agent field** to identify yourself consistently.
- **Use revises** when updating an existing thought to link to the original.

### What to Write vs Not Write

**Write:** Architecture decisions, bug findings, API surfaces, cross-cutting concerns, status updates, known issues.

**Don't write:** Raw code (git handles that), temporary debug notes, things already in this file or CONCEPT.txt, duplicates.

### Completion Workflow

1. **Write a summary** to the relevant shard: what changed, impact, what's left.
2. **Update CONCEPT.txt** if you changed architecture, protocol, or behavior.
3. **Update the `todos` shard** if you completed a spec item — write a revision marking it done.
4. The daemon **auto-emits events** to related shards. Other agents see changes automatically.

### Spec Workflow

Specs live in `spec-*` shards. Each contains a problem statement, goals, and proposed design.

**Reading:** Use dump on any `spec-*` shard, or access with a topic.

**Creating:** Create a shard named `spec-<slug>` with the remember op. Write two thoughts (problem + design). Link to `milestones` and `todos`. Add a todo.

**Working:** Read `todos` for priority, read the `spec-*` shard, implement, write results back, update the todo.

### Transaction Safety

For read-modify-write: lock with the transaction op, read and modify, commit to release. Locks auto-expire after 30 seconds.

### Multi-Agent Awareness

- After writing, the daemon auto-notifies related shards.
- Before reading, check events for what changed and who changed it.
- If a shard is locked, your write is queued and applied on lock release.

## Architecture (Current, Accurate)

- **Single process, in-process slots**: The daemon loads shard blobs into `Shard_Slot` structs in its own process. No separate process per shard. One daemon manages all shards in-memory.
- **File format**: SHRD0006. Binary thoughts with revises + TTL + counter fields, plaintext catalog/gates/manifest, SHA256 integrity, atomic write. Migrates SHRD0005/SHRD0004 on load.
- **Encryption**: ChaCha20-Poly1305, HKDF-SHA256 key derivation, one symmetric key per shard.
- **IPC**: Length-prefixed messages (u32 LE + UTF-8 payload). Windows named pipes with overlapped I/O, POSIX Unix sockets with poll.

## Source of Truth: CONCEPT.txt

`docs/CONCEPT.txt` is the canonical architecture document. It must always reflect the actual running implementation.

### Keeping it current
- After any change that affects architecture, protocol, file format, process model, or public-facing behavior, update the relevant section of CONCEPT.txt in the same session.
- If a section of CONCEPT.txt no longer matches reality, fix the document. Do not leave stale descriptions.
- The file map and source file descriptions at the bottom of CONCEPT.txt must match the actual source tree.

### No silent degradation
- Before removing any feature, function, protocol op, or capability, warn the user and explain the impact.
- If a removal is necessary for cleanup, explain what replaces it or why it is no longer needed.
- The project must always move forward. Every change should either fix a bug, improve correctness, improve performance, or add capability. No change should reduce what the system can do without explicit approval.
- If refactoring would temporarily break a feature, state this upfront with a plan to restore it.

### What counts as beneficial
- Anything that makes multi-agent coordination safer or more reliable.
- Anything that makes data storage more correct or the routing smarter.
- Anything that makes the spec-to-solution loop more complete.
- Performance improvements, memory leak fixes, and security hardening.
- These must never be removed without a replacement that is equal or better.

## Code Standards

### No dead code
- Remove unused functions, variables, imports, and struct fields immediately.
- Do not comment out code "for later". Delete it. Git has history.
- If a function is no longer called, delete it. If a field is no longer read, delete it.

### No stale comments
- Comments must describe what the code actually does now, not what it used to do.
- If you change behavior, update or remove the comment above it.
- Block comments describing file format, protocol, or architecture must match reality.
- Section headers (the `// ===` blocks) are fine -- they help navigation. Keep them accurate.

### No legacy compatibility without justification
- No backward compatibility shims. The current format is the only format.
- Any other backward-compat shims must have a comment explaining what they support and when they can be removed.

### Clean function boundaries
- Each function does one thing. If a function handles both "normal case" and "legacy fallback", split it or document why.
- No functions over 100 lines without a strong reason. Break them up.

### Memory discipline (Odin specific)
- Every `strings.clone()` must have a corresponding `delete()` or documented ownership transfer.
- Every `json.parse()` must have a corresponding `json.destroy()`.
- Every `fmt.aprintf()` or other allocating format must have its result freed.
- When replacing a string field (e.g., `entry.catalog.name = new_name`), free the old value first.
- Use `context.temp_allocator` for short-lived allocations within a single function scope. Do not pass temp-allocated strings to structs that outlive the function.
- `defer os.close(f)` and explicit `os.close(f)` must never coexist on the same handle.

### Error handling
- No silent failures. If an operation fails, either return an error or log it.
- `blob_load` returning success on file-not-found is acceptable (new shard). But permission errors or partial corruption should be distinguishable.
- IPC connection failures should include the reason, not just "could not connect".

### Security
- Never interpolate user-supplied strings directly into YAML frontmatter. Escape newlines, colons, and YAML-special characters.
- The content alert system exists for a reason. Do not bypass it.

### Testing
- Build must succeed with no warnings before any commit.
- Run `just test` (or `odin test src/`) — all tests must pass.
- Tests live in `src/` alongside the source as `test_*.odin` files. No separate test binaries.

## Three-Layer Vision

This system is being built toward three composing layers:

1. **Multi-agent coordination**: Multiple AI agents work on different tasks simultaneously, sharing context through shards. They can see each other's progress, announce changes, and avoid conflicts.
2. **Intelligent data storage**: Raw information is pumped in, auto-routed to the right shard via gates and embeddings, and compacted over time into distilled plain-text statements optimized for AI consumption.
3. **Automated spec-to-solution**: Specs and todos live in shards. Agents read the `todos` shard for prioritized work, read `spec-*` shards for feature definitions, implement the work, and write results back. The shards are the shared project brain.

These layers compose: Specs define work, Layer 1 distributes it, Layer 2 is the shared memory.

## Agents

Four agent modes are defined in `.agent/agents/`:

| Agent | Role |
|-------|------|
| `shard.coder` | Development — writes code, reads/writes shards, builds and tests |
| `shard.review` | Code review — checks correctness, standards, writes findings to shards |
| `shard.ask` | Knowledge query — answers questions by searching shards, read-only |
| `shard.sweep` | Cleanup — removes AI slop from the diff, deduplicates shards, fixes stale entries |

## File Map

| File | Lines | Role |
|------|-------|------|
| `src/main.odin` | ~680 | Entry point, CLI, subcommands (init, new, connect, dump) |
| `src/types.odin` | ~349 | All struct definitions (Thought with counters) |
| `src/crypto.odin` | ~365 | HKDF, ChaCha20-Poly1305, thought encrypt/decrypt, binary serialization (SHRD0006) |
| `src/blob.odin` | ~399 | .shard file format (SHRD0006), load/flush/atomic write, V4/V5 migration |
| `src/daemon.odin` | ~2420 | Registry, slots, routing, layered traverse (L0/L1/L2), global_query, transactions, digest, consumption tracking |
| `src/protocol.odin` | ~1290 | Op dispatch: write/read/search/compact/dump/gates/stale/feedback, composite scoring |
| `src/markdown.odin` | ~800 | YAML frontmatter parser/serializer, JSON wire format |
| `src/mcp.odin` | ~1014 | MCP server, 11 tools, JSON-RPC, daemon auto-start |
| `src/node.odin` | ~241 | Process lifecycle, event loop, idle timeout |
| `src/ipc.odin` | ~55 | Platform-neutral message framing |
| `src/ipc_windows.odin` | ~175 | Windows named pipes |
| `src/ipc_posix.odin` | ~148 | Unix domain sockets |
| `src/embed.odin` | ~412 | Vector embeddings, cosine similarity, index |
| `src/scanner.odin` | ~170 | Content scanner: AI-based (LLM), informational alerts only |
| `src/config.odin` | ~248 | Config file reader |
| `src/keychain.odin` | ~83 | Keychain reader |
| `src/help.odin` | ~20 | Compile-time help text loading |
| `src/test_*.odin` | ~2500 | Tests: crypto, blob, markdown, scanner, search, dispatch, concurrent, consumption, digest, staleness, relevance, traverse, fleet, global_query |

## Adding a New Op

The pattern for adding a new protocol operation:

1. **types.odin** — Add fields to `Request` and/or `Response` structs
2. **markdown.odin** — Parse new request fields, marshal new response fields
3. **protocol.odin** — Add handler (`_op_xxx`), add case to `dispatch()` switch
4. **daemon.odin** — Add case to `_slot_dispatch()`, add to `_op_requires_key()` if encrypted
5. **mcp.odin** — Add tool def to `_tools` array, add handler, add case to `_handle_tools_call()`
6. **test_<feature>.odin** — Add test coverage in the appropriate test file

## Workflow

1. Read this file.
2. Build with `just build` and fix any errors before considering work done.
3. Run `just test` (or `odin test src/`) — all tests must pass.
4. Tests live in `src/` alongside the source as `test_*.odin` files. No separate test binaries.
5. When fixing a bug, also fix any related cleanup issues in the same file.
6. If any change touches architecture, protocol, or behavior, update `docs/CONCEPT.txt` to match.
7. Before removing anything that looks intentional, ask the user.
