# Shard v3 — Vision

## What This Is

Shard is a single-binary encrypted knowledge routing system written in Odin. It stores thoughts in encrypted `.shard` files, routes knowledge via gates, and serves AI agents through MCP (JSON-RPC 2.0) and HTTP+SSE.

v3 is a ground-up rewrite. One file. Clean allocator model. Same vision, better foundation.

## Core Principles

1. **Clean code from the get-go** — Every change is also a cleanup pass. When a function is replaced, renamed, or superseded, delete the old version immediately. Only the latest implementation exists in the codebase. No dead code, no "old_" prefixes, no commented-out blocks kept "just in case." The repo is always shippable, never mid-migration.
2. **Routing before reading** — Gates declare what shards accept/reject. Agents never scan everything.
3. **Encryption by default** — ChaCha20-Poly1305 with HKDF per-thought key derivation. One key per shard.
4. **Single binary, no deps** — Daemon, MCP server, HTTP server, CLI — all one executable.
5. **Linux only** — The shard binary targets Linux exclusively. The EXE-is-the-shard format is inherently platform-specific — you cannot copy a Linux binary with its appended data and run it on Windows or macOS. On other platforms, run shards inside a Docker container or equivalent Linux environment. This is a deliberate choice, not a limitation to fix later.
6. **Context is constructed, not retrieved** — Not top-k search. Active assembly of relevant working context.
7. **Obsidian-native output** — YAML frontmatter, wikilinks, tags. Human-readable surface area.

## Architecture (v3)

### Single File

Everything lives in `shard.odin`. One package, one file. This will grow large — organize by grouping related logic together. The benefit is zero import complexity and full visibility.

### No Comments

Do not write comments. No section headers, no `//> Name` markers, no "this does X" restating what the code says. The only exception: a comment is allowed when the logic is genuinely hard to understand even for an experienced reader — and even then, prefer renaming or restructuring over commenting. TODOs on stubs are fine.

### The Binary IS the Shard

Each shard is its own EXE. The encrypted thoughts and content are stored inside the binary itself — appended after the executable code. There are no separate `.shard` files. The EXE is the storage format.

### Each EXE Is Its Own Daemon

There is no central daemon process. Each shard EXE runs its own daemon. When you launch a shard, it starts listening for requests (IPC, HTTP, whatever applies). If no requests arrive within a configurable idle timeout, the EXE shuts itself down. This is a debounce mechanism — the shard stays alive while it's being used and quietly exits when it's not.

Lifecycle:
1. **Start** — Launch the EXE. It copies itself to a working copy (see Self-Write below). The original file is now free for overwriting.
2. **Listen** — The running process (from the copy) accepts requests. Each request resets the idle timer.
3. **Idle shutdown** — If no requests arrive within the debounce window (configurable, default TBD), the process exits cleanly.
4. **On-demand wakeup** — Any client that needs this shard launches the EXE again. Startup is fast — it's a single binary with no deps.

### Shard Index

Discovery and revision tracking via `~/.shards/`:

```
~/.shards/
  index/
    <shard-id>     # Plain text: line 1 = current exe path, line 2 = prev exe path
  run/
    <shard-id>     # Working copy while daemon is running
```

**Shard ID** — derived from `slugify(catalog.name)` if the shard has a catalog, otherwise first 16 hex chars of `SHA256(exe_path)`. Used as the filename in both `index/` and `run/`.

**Index entry** — one file per shard. Line 1 is the current canonical exe path. Line 2 (optional) is the previous revision, deleted on next startup.

**Revision lifecycle:**
1. Daemon starts → creates working copy at `~/.shards/run/<shard-id>`, writes index entry
2. During runtime → `blob_write_self` writes to the working copy
3. Daemon shuts down → updates index: working copy becomes canonical, old exe is marked as prev
4. Next startup → reads index, deletes prev revision, clears prev from index

This means:
- No long-running central daemon to manage or crash
- Each shard is fully self-contained — drop it anywhere, run it, it works
- Resource usage scales to zero when idle
- The system grows organically — just run more EXEs
- Every shard discovers peers by listing `~/.shards/index/`
- Old revisions are automatically cleaned up on next startup

### Self-Write via Copy

A running process cannot overwrite its own EXE (the OS holds a lock on it). The solution: copy-on-start.

1. **On startup** — Copy the EXE to a temporary working path (e.g., `<name>.shard.tmp`).
2. **Launch from copy** — Re-exec from the copy, or run the copy as the actual daemon process. The original EXE file is now unlocked.
3. **Write back** — When the shard needs to persist new data (new thoughts, updated catalog, compaction), it writes the new shard data into the *original* EXE path. Read own in-memory state + new data → assemble new binary → write to original path.
4. **Self-update** — Same mechanism. If the shard receives an updated binary (new code + existing data), it writes it to the original path. On next launch, the new code runs.

This means:
- The shard can always write to itself because it's running from a copy
- Updates are atomic: write new file → rename over original (or write + verify hash)
- The copy is ephemeral — cleaned up on shutdown
- No separate "storage layer" — the EXE is the database and the runtime

### Memory Model

Two allocator tiers:

- **Runtime allocator** — The default context allocator. Lives for the entire process lifetime. Used for global state: registry, config, daemon structures, the event hub. Cleaned up at exit.
- **Request allocator** — A fresh arena created per-request. Passed through the context to all request-handling code. Freed when the request completes. Allocate freely within a request — no need to track individual frees.

Implementation:
```odin
// Runtime: use default context allocator (set up in main)
// Per-request: create a new context with a request-scoped arena
request_arena: mem.Arena
mem.arena_init(&request_arena, make([]byte, REQUEST_ARENA_SIZE))
request_context := context
request_context.allocator = mem.arena_allocator(&request_arena)
defer mem.arena_destroy(&request_arena)
// Pass request_context through to all request handlers
```

This means:
- No individual `free()` calls in request code paths
- Request memory is bulk-freed in one operation
- Runtime state persists across requests
- Memory leaks in request handling are impossible — the arena is destroyed

### Data Model

**Thought** — Atomic encrypted unit. Has: id (16 bytes), description, content, agent, timestamps, revision chain, TTL, read/cite counts. Encrypted body = description + separator + content.

**Shard** — One EXE. The binary IS the shard. Encrypted data is appended after the executable code. Contains: catalog (plaintext identity), gates (routing signals), processed thoughts (AI-ordered), unprocessed thoughts (append-only inbox), manifest (freeform metadata).

**Catalog** — Plaintext identity card: name, purpose, tags, related shards, created timestamp. Readable without encryption key.

**Gates** — Plaintext routing signals: description, positive terms, negative terms, related shards. Used for routing decisions before any decryption.

**Daemon** — Each shard runs its own daemon (no central process). A running shard manages: its own data (thoughts, catalog, gates), IPC listener, idle debounce timer. Coordination between shards happens via IPC between running shard processes.

### Wire Protocol

Length-prefixed JSON over Unix domain sockets:
```
[u32 LE: payload_length][payload: UTF-8 JSON bytes]
```

### File Format (appended to EXE)

The shard data is appended after the executable's native code. The EXE runs normally — the OS ignores trailing data. Shard reads its own binary to find the data section.

```
[... native executable code ...]
[SHARD DATA START]
[PROCESSED BLOCK]     count-prefixed binary thoughts
[UNPROCESSED BLOCK]   count-prefixed binary thoughts
[CATALOG BLOCK]       length-prefixed plaintext JSON
[MANIFEST BLOCK]      length-prefixed plaintext
[GATES BLOCK]         plaintext routing signals
[gates_size: u32 LE]  4 bytes
[blob_hash: u8x32]    SHA-256 of all preceding bytes
[MAGIC: u64 LE]       0x5348524430303036 ("SHRD0006")
```

To locate the data: read the last 8 bytes of the file for MAGIC, then walk backwards through the footer to find block offsets.

Writes: the running process (from the working copy) assembles new EXE code + shard data → writes to the original path → verifies hash. See "Self-Write via Copy" above.

### Encryption

- Master key: 32 bytes (64-char hex or `SHARD_KEY` env var)
- Per-thought key: HKDF-SHA256(master, thought_id)
- Cipher: ChaCha20-Poly1305 (IETF, 96-bit nonce, 128-bit tag)
- Seal: encrypted SHA256(description) for verification without full decrypt
- Trust: SHA256(key || SHA256(plaintext)) for integrity binding

### Operations

Core ops the system must support:
- **write** — Create/update thoughts with gate routing
- **read** — Read thought by ID with optional revision chain
- **query** — Cross-shard search (keyword + semantic + fulltext modes)
- **compact** — Merge revision chains, prune stale thoughts (lossless/lossy)
- **dump** — Export shard as Obsidian markdown
- **gates** — Read/write routing signals
- **events** — Emit and consume shard events through the daemon hub
- **transaction** — Acquire lock, commit, rollback
- **fleet** — Parallel multi-shard dispatch
- **cache** — Topic cache read/write/list (short-term memory)

### Three-Layer Memory

1. **Long-term** — Shards. Durable encrypted thought storage, refined over time via compaction.
2. **Short-term** — Topic cache / context sessions. Ephemeral state describing what matters now.
3. **Working** — Context packets. On-demand assembled context optimized for the current task.

Do not collapse short-term state into long-term storage. Do not treat transient relevance as durable truth.

## Environment Variables

- `SHARD_KEY` — Master encryption key
- `LLM_URL` — LLM API endpoint (any OpenAI-compatible provider)
- `LLM_KEY` — LLM authentication
- `LLM_MODEL` — Model for compaction/context assembly
- `EMBED_MODEL` — Embedding model for vector search
- `PORT` — HTTP server port (default 8080)

## What v3 Must Achieve

The v2 codebase (in `../src/`) is the reference. v3 carries the same vision forward with:
- Cleaner single-file architecture
- Explicit two-tier allocator model (runtime + per-request arenas)
- Same encryption, wire protocol, and file format
- Same operational model (daemon, MCP, HTTP, CLI)
