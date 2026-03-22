# CLAUDE.md

This file provides guidance to Claude Code when working with code in this repository.

## Vision

**Always read `docs/vision.md` before making any design or implementation decisions.** Use the `/shard-vision` skill. Check `docs/todo.md` for current progress.

## What This Is

Shard v3 — single-binary encrypted knowledge routing system. Each shard is its own EXE with encrypted thoughts appended after the executable code. Each EXE runs its own daemon with idle debounce.

## Build & Test

Linux only. Build and test via Docker:

```bash
docker build -t shard-test .                                    # unit tests
docker build -f scripts/Dockerfile.integration -t shard-int .   # integration tests
docker run --rm shard-test                                      # run unit tests
docker run --rm -v "$(pwd)/.temp:/data" shard-int               # run integration tests
```

## Project Structure

```
shard.odin              # everything — single file, no comments
Dockerfile              # unit test build
help/                   # #load embedded help text files
scripts/                # test scripts, integration Dockerfile
docs/                   # vision.md, todo.md
.temp/                  # gitignored, claudeignored — persistent test data + config with secrets
```

## Architecture

**Single file** — `shard.odin`. No comments. No section headers.

**Two-tier memory model:**
- **Runtime allocator** — Global state. Lives for process lifetime.
- **Request allocator** — Fresh arena per IPC connection. Freed on return.

**Config:** `~/.shards/_config.jsonc` — LLM, encryption key, shard defaults. Env vars override config.

**Platform:** Linux only. IPC via Unix domain sockets. Build in Docker.

## Odin Conventions

- `snake_case` for procs and variables, `Title_Case` for types
- `-vet -strict-style` enforced — unused variables/imports are compile errors
- `mem.Arena` for allocation
- Error handling via multiple return values and `or_return`

## Design Principles

- **Clean code from the get-go** — no dead code, no comments, delete replaced functions
- **Routing before reading** — gates and descriptions checked before decrypting thoughts
- **Encryption by default** — ChaCha20-Poly1305, HKDF per-thought key derivation
- **Single binary, no deps** — daemon, MCP, HTTP, CLI in one executable
- **Linux only** — binary format is platform-specific, use Docker elsewhere
- **Context is constructed, not retrieved** — active assembly, not top-k search
