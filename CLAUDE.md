# CLAUDE.md

Read this file first. It defines how to work on this codebase.

## Project

Shard is an encrypted thought store written in Odin. Single binary, runs as daemon/node/CLI/MCP server. Stores knowledge in encrypted `.shard` files. AI agents interact via MCP (JSON-RPC over stdio) or IPC (named pipes on Windows, Unix sockets on POSIX). Wire protocol is Markdown with YAML frontmatter.

## Architecture (Current, Accurate)

- **Single process, in-process slots**: The daemon loads shard blobs into `Shard_Slot` structs in its own process. No separate process per shard. One daemon manages all shards in-memory.
- **File format**: SHRD0004. Binary thoughts with revises field, plaintext catalog/gates/manifest, SHA256 integrity, atomic write.
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
- Anything that makes the Wolf spec-to-solution loop more complete.
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
- Block comments describing file format, protocol, or architecture must match reality. If they reference the old multi-process model, fix them.
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
- Tests live in `src/tests.odin` alongside the source. No separate test binaries.

## Three-Layer Vision

This system is being built toward three composing layers:

1. **Multi-agent coordination**: Multiple AI agents in git worktrees work on different tasks simultaneously, sharing context through shards via MCP. They can see each other's progress, announce API changes, and avoid conflicts.
2. **Intelligent data storage**: Raw information is pumped in, auto-routed to the right shard via gates and embeddings, and compacted over time into distilled plain-text statements optimized for AI consumption.
3. **Automated spec-to-solution**: The Wolf system indexes a codebase, generates feature specs with implementation todos, distributes tasks to agents, verifies results, and picks the best next actions.

These layers compose: Wolf generates work, Layer 1 distributes it, Layer 2 is the shared memory.

## File Map

| File | Lines | Role |
|------|-------|------|
| `src/main.odin` | ~580 | Entry point, CLI, subcommands |
| `src/types.odin` | ~283 | All struct definitions |
| `src/crypto.odin` | ~335 | HKDF, ChaCha20-Poly1305, thought encrypt/decrypt |
| `src/blob.odin` | ~439 | .shard file format, load/flush/convenience ops |
| `src/daemon.odin` | ~1056 | Registry, slots, routing, traverse, transactions |
| `src/protocol.odin` | ~837 | Op dispatch: write/read/search/compact/dump/gates/catalog |
| `src/markdown.odin` | ~280 | YAML frontmatter parser/serializer |
| `src/mcp.odin` | ~999 | MCP server, all 19 tools, JSON-RPC |
| `src/node.odin` | ~185 | Process lifecycle, event loop, idle timeout |
| `src/ipc.odin` | ~55 | Platform-neutral message framing |
| `src/ipc_windows.odin` | ~175 | Windows named pipes |
| `src/ipc_posix.odin` | ~148 | Unix domain sockets |
| `src/embed.odin` | ~412 | Vector embeddings, cosine similarity, index |
| `src/scanner.odin` | ~100 | Content scanner: API key, password, PII detection |
| `src/config.odin` | ~236 | Config file reader |
| `src/keychain.odin` | ~83 | Keychain reader |
| `src/help.odin` | ~20 | Compile-time help text loading |
| `src/tests.odin` | ~300 | All tests (run with `odin test src/`) |

## Adding a New Op

The pattern for adding a new protocol operation:

1. **types.odin** — Add fields to `Request` and/or `Response` structs
2. **markdown.odin** — Parse new request fields, marshal new response fields
3. **protocol.odin** — Add handler (`_op_xxx`), add case to `dispatch()` switch
4. **daemon.odin** — Add case to `_slot_dispatch()`, add to `_op_requires_key()` if encrypted
5. **mcp.odin** — Add tool def to `_tools` array, add handler, add case to `_handle_tools_call()`
6. **tests.odin** — Add test coverage

## Workflow

1. Read this file.
2. Build with `just build` and fix any errors before considering work done.
3. Run `just test` — all tests must pass.
4. When fixing a bug, also fix any related cleanup issues in the same file.
5. If any change touches architecture, protocol, or behavior, update `docs/CONCEPT.txt` to match.
6. Before removing anything that looks intentional, ask the user.
