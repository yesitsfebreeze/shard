# Shard Codebase Agent Guidelines

This file provides instructions for agentic coding agents working in the Shard repository.

## Build, Test, and Lint Commands

### Building
```bash
just build              # Build the binary with debug info
just release            # Build optimized binary and compress with UPX
just clean              # Remove bin/ directory
just test-build         # Build test binary (used before considering work done)
```

### Testing
```bash
just test               # Run all tests (cross-platform)
odin test src/          # Alternative to just test
odin test src/<package> # Run tests for specific package
odin test src/<package>:<test_name> # Run specific test
```

### Running
```bash
just run                # Run the daemon (expects working tests)
shard init              # Initialize .shards/, keychain, config (first time)
shard daemon &          # Start daemon in background
shard mcp               # Start MCP server (connects to daemon)
```

### Code Quality
```bash
odin vet src/           # Check for suspicious constructs
odin fmt src/           # Format Odin source code
```

## Code Style Guidelines

### Imports
- Group imports by category: system packages, project packages
- Use blank lines to separate import groups
- Align imports vertically when possible
- Use relative imports within the same package
- Import only what's needed

```odin
// System packages
import "core:fmt"
import "core:strings"
import "core:os"

// Project packages
import "../crypto"
import "../blob"
import "./types"
```

### Formatting
- Run `odin fmt src/` before committing
- Maximum line length: 100 characters
- Indentation: 4 spaces
- Opening braces on same line as declaration
- Closing braces on their own line
- No trailing whitespace
- Empty lines between logical sections

### Types and Naming Conventions
- Use `lower_snake_case` for variables and functions
- Use `PascalCase` for types, constants, and enum variants
- Use `UPPER_SNAKE_CASE` for preprocessor macros
- Prefix interfaces with `I` (e.g., `IEncoder`)
- Suffix implementation structs with `Impl` when needed
- Boolean variables should start with `is`, `has`, `can`, or `should`
- Error variables should be named `err`

### Error Handling
- No silent failures; always handle or propagate errors
- Return error as last return value when applicable
- Use `defer` for cleanup resources
- Distinguish between expected and unexpected errors
- Log unexpected errors with context
- For IPC failures, include specific reason, not just generic messages

```odin
// Good: explicit error handling
file, err := os.open(path)
if err != nil {
    return fmt.Errorf("failed to open %s: %v", path, err)
}
defer os.close(file)

// Good: defer for cleanup
f := os.create(path)
defer {
    os.close(f)
}()
```

### Memory Discipline (Odin Specific)
- Every `strings.clone()` must have corresponding `delete()` or documented ownership transfer
- Every `json.parse()` must have corresponding `json.destroy()`
- Every `fmt.aprintf()` or other allocating format must have its result freed
- When replacing string field, free old value first
- Use `context.temp_allocator` for short-lived allocations within function scope
- Never pass temp-allocated strings to structs that outlive function
- `defer os.close(f)` and explicit `os.close(f)` must never coexist on same handle

### Comments
- Comments must describe what code actually does now, not what it used to do
- Update or remove comments when changing behavior
- Block comments describing file format, protocol, or architecture must match reality
- Section headers (`// ===`) are fine for navigation but keep accurate
- No commented-out code; delete it (git has history)

### Functions
- Each function should do one thing
- Split functions over 100 lines unless strong reason exists
- Document non-obvious behavior in comments
- Place related functions together in file
- Put public functions near top of file

### Security
- Never interpolate user-supplied strings directly into YAML frontmatter
- Escape newlines, colons, and YAML-special characters
- Respect content alert system; do not bypass it
- Validate all inputs from external sources
- Use constant-time comparison for cryptographic operations

## Additional Guidelines

### Adding New Operations
When adding a new protocol operation:
1. Add fields to `Request`/`Response` in `types.odin`
2. Parse/marshal fields in `markdown.odin`
3. Add handler (`_op_xxx`) in `protocol.odin` and case to `dispatch()`
4. Add case to `_slot_dispatch()` in daemon, add to `_op_requires_key()` if encrypted
5. Add tool def to `_tools` array in `mcp.odin`, add handler, add case to `_handle_tools_call()`
6. Add test coverage in appropriate `test_*.odin` file

### Workflow
1. Read `CLAUDE.md` and this file first
2. Build with `just test-build` and fix any errors before considering work done
3. Run `just test` - all tests must pass
4. When fixing a bug, also fix related cleanup issues in same file
5. If change touches architecture, protocol, or behavior, update `docs/CONCEPT.txt`
6. Before removing anything that looks intentional, ask for clarification

### Agent Modes
Five agent modes are defined in `.agent/agents/`:
- `shard.coder`: Development — writes code, reads/writes shards, builds and tests
- `shard.review`: Code review — checks correctness, standards, writes findings to shards
- `shard.ask`: Knowledge query — answers questions by searching shards, read-only
- `shard.sweep`: Cleanup — removes AI slop from the diff, deduplicates shards, fixes stale entries
- `shard.remember`: Knowledge filing — takes freeform info and routes it to the right shard

### Shard System Usage
- Start with `shard_discover()` to get table of contents
- Check `shard_events()` for pending changes
- Use `shard_query(budget: 2000)` for targeted context
- Write findings to appropriate shard with descriptive description
- Set agent field for identification
- Use `revises` when updating existing thoughts
- Follow completion workflow: write summary, update CONCEPT.txt if needed, update todos shard

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