# Project

Shard is an encrypted thought store written in Odin. Single binary that runs as daemon, CLI, and MCP server. Stores knowledge in encrypted `.shard` files. AI agents interact via MCP (JSON-RPC over stdio) or IPC (named pipes on Windows, Unix sockets on POSIX).

## Source

- **Language:** Odin
- **Source:** `src/*.odin`
- **Tests:** `src/*_test.odin` (alongside source, no separate binary)

## Commands

| Action | Command |
|--------|---------|
| Build (AI) | `just test-build` |

## Testing
Read docs/TESTS.md and run the playbook.

## Architecture

- `docs/CONCEPT.txt` — canonical architecture document, must always match the running implementation
- `CLAUDE.md` — code standards, memory discipline rules, file map with line counts

## Code Standards

- No dead code — remove unused functions, variables, imports immediately
- No stale comments — comments describe current behavior, not historical
- Memory discipline — every `strings.clone()` has a `delete()`, every `json.parse()` has a `json.destroy()`
- Clean function boundaries — one concern per function, under 100 lines preferred
- Security — never interpolate user strings into YAML frontmatter
- Section headers (`// === ... ===`) are intentional navigation aids
- Format specification comments in `crypto.odin` and `blob.odin` document binary layouts

## Principles

- Single binary, no external dependencies
- Shards are the shared memory for all agents
- Every change must move the project forward — no regressions without explicit approval
- Wire protocol is Markdown with YAML frontmatter
- The system is built toward three layers: multi-agent coordination, intelligent data storage, automated spec-to-solution
