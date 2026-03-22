# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Vision

**Always read `vision.md` before making any design or implementation decisions.** Use the `/shard-vision` skill — it reads the vision document and grounds your response in the project's architecture and principles.

## What This Is

Shard v3 — a ground-up rewrite of the Shard encrypted knowledge routing system. The mature v2 codebase lives in `../src/` (40+ Odin files); this directory (`v3/`) is the fresh start. Refer to `../src/` for proven patterns, but v3 is its own package.

Shard is a single-binary encrypted knowledge store. Thoughts are encrypted with ChaCha20-Poly1305 and stored in `.shard` files. A daemon manages shards, AI agents route thoughts via gates (accept/reject rules), and new shards are created automatically when nothing fits.

## Build & Test

Requires [Odin](https://odin-lang.org/) (dev-2026-02+) and [just](https://github.com/casey/just).

All commands run from the **repo root** (`../`), not from `v3/`:

```bash
just test          # run all unit + integration tests
just build         # debug build (runs tests first) → ./bin/shard[.exe]
just run           # compile and run directly
just release       # optimized build + UPX compression
just clean         # remove ./bin/
just ci-check      # trigger GitHub Actions build and wait for results
```

To run a single test directory manually:
```bash
# In-package tests (tests/ dirs inside src/)
odin test ./src/fs/tests -define:ODIN_TEST_LOG_LEVEL=warning

# Standalone tests (reference src as a collection)
odin test ./tests/unit -collection:shard=./src -define:ODIN_TEST_LOG_LEVEL=warning
```

Build flags: `-o:speed -vet -strict-style` (debug adds `-debug`).

## Architecture (v3)

**Single file** — Everything lives in `shard.odin`. Organize with section comments.

**Two-tier memory model:**
- **Runtime allocator** — Default context. Global state (registry, config, daemon). Lives for process lifetime.
- **Request allocator** — Fresh `mem.Arena` per request, passed via context. Freed in bulk when request completes. No individual `free()` calls in request code paths.

**v2 reference** — The mature codebase in `../src/` (40+ files) has proven implementations of all core operations. Refer to it for patterns, but v3 consolidates into one file.

**Platform:** Linux only. IPC via Unix domain sockets. The shard binary format (EXE + appended data) is platform-specific. On other platforms, run inside Docker.

**Key environment variables:**
- `SHARD_KEY` — master encryption key
- `LLM_URL`, `LLM_KEY`, `LLM_MODEL` — LLM provider (any OpenAI-compatible API)
- `EMBED_MODEL` — embedding model for vector search
- `PORT` — HTTP server port (default 8080)

**Config:** `.shards/config.jsonc` for LLM integration settings.

## Odin Conventions

- Package name is `shard` (all files in a directory share one package)
- Use `mem.Arena` for allocation — see `startup()` in `shard.odin`
- Odin uses `snake_case` for procs and variables, `Title_Case` for types and enum values
- Error handling via tagged unions and `enum` error types, not exceptions
- `#config()` for compile-time configuration knobs
- `-vet -strict-style` is enforced — unused variables/imports are compile errors

## Design Principles

- **Routing before reading** — gates declare what shards accept; agents don't search everything
- **Encryption by default** — all thought content is encrypted at rest
- **Single binary, no runtime deps** — everything ships in one executable
- **All features prepare for Obsidian export** — YAML frontmatter, wikilinks, tags
