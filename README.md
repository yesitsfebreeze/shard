# ShardV2

Encrypted thought store. One process per shard, started on demand, dies when idle. A daemon tracks everything.

## Build

Requires [Odin](https://odin-lang.org/) (dev-2025-01 or later).

```
odin build src/ -out:shard.exe
```

Optimized for size (~240 KB with UPX):

```
odin build src/ -out:shard.exe -o:size
upx --best --lzma shard.exe
```

Optimized for speed (~1.4 MB):

```
odin build src/ -out:shard.exe -o:speed
```

Test client:

```
odin build tests/ -out:tests/client.exe
```

## Architecture

```
                         ┌──────────────┐
                         │    daemon    │  fixed endpoint: shard-daemon
                         │              │  tracks all known shards
                         │  registry:   │  persists to daemon.shard
                         │   notes ✓    │
                         │   journal ✗  │
                         │   archive ✗  │
                         └──────┬───────┘
                                │
                 ┌──────────────┼──────────────┐
                 │              │              │
          ┌──────┴──────┐ ┌────┴──────┐ ┌─────┴─────┐
          │ shard-notes │ │  (idle)   │ │  (idle)   │
          │  notes.shard│ │  journal  │ │  archive  │
          │  alive, 1   │ │  stopped  │ │  stopped  │
          └─────────────┘ └───────────┘ └───────────┘
                ▲
                │ IPC
                │
            AI / client
```

- **One EXE, many processes.** Each `.shard` file gets its own process.
- **Start on demand.** AI connects to the daemon, sees what exists, starts what it needs.
- **Die when idle.** Each shard process exits after `--timeout` seconds of inactivity (default 5 min). Data is flushed to disk. Memory freed.
- **Daemon remembers everything.** Every shard that was ever started is in the registry — alive or not. The AI can see the full knowledge base and spin up any shard by name.

## Usage


### Generate a new key
python -c "import secrets; print(secrets.token_hex(32))"

### Start the daemon

```
./shard.exe daemon
```

The daemon listens at a fixed IPC endpoint (`shard-daemon`). No key needed — it stores registry metadata, not secrets.

### Start a shard

```
./shard.exe --name notes --key <64-hex> --data notes.shard
```

The shard automatically registers with the daemon on startup and unregisters on shutdown.

| Flag | Description |
|------|-------------|
| `--name` | Shard name. Determines the IPC endpoint. Default: `default` |
| `--key` | Master key (64 hex chars / 32 bytes). Also reads `SHARD_KEY` env var |
| `--data` | Path to `.shard` file. Created if missing. Default: `<name>.shard` |
| `--timeout` | Idle timeout in seconds. `0` = run forever. Default: `300` (5 min) |

### AI workflow

```
1. Connect to daemon
2. Send registry query → get list of all known shards
3. Pick shards relevant to the task
4. For each: try connect → if refused, spawn: shard.exe --name X --key K --data X.shard
5. Send ops (write/read/search)
6. Disconnect
7. Shard sits idle → times out → exits → memory freed
```

## Wire Format

All IPC messages use **Markdown with YAML frontmatter**. Metadata goes in the frontmatter, content goes in the body. Responses can be saved directly as `.md` files for Obsidian.

```
[u32 LE: payload_length][payload: UTF-8 markdown bytes]
```

| Platform | Endpoint |
|----------|----------|
| Windows | `\\.\pipe\shard-<name>` |
| Linux/macOS | `/tmp/shard-<name>.sock` |

### Request format

```markdown
---
op: write
description: meeting notes
---
discussed roadmap priorities for Q2
```

### Response format

```markdown
---
status: ok
id: a1b2c3d4e5f6a7b8...
---
```

Content-bearing responses put the content in the body:

```markdown
---
status: ok
description: meeting notes
---
discussed roadmap priorities for Q2
```

Lists use inline YAML syntax:

```markdown
---
status: ok
ids: [a1b2c3d4..., e5f6a7b8...]
---
```

## Daemon Operations

**registry** — List all known shards.

```markdown
>> ---
   op: registry
   ---

<< ---
   status: ok
   registry:
     - name: notes
       data_path: notes.shard
       alive: true
       last_seen: 2026-03-15T19:32:28Z
       thought_count: 5
     - name: journal
       data_path: journal.shard
       alive: false
       last_seen: 2026-03-15T18:00:00Z
       thought_count: 12
   ---
```

**registry with query** — Filter shards by keyword.

```markdown
>> ---
   op: registry
   query: notes
   ---
```

**register** — Called automatically by shard processes on startup.

```markdown
>> ---
   op: register
   name: notes
   data_path: notes.shard
   thought_count: 5
   purpose: meeting notes and project docs
   tags: [meetings, projects]
   ---
```

**unregister** — Called automatically by shard processes on shutdown.

```markdown
>> ---
   op: unregister
   name: notes
   ---
```

**heartbeat** — Update a shard's status. Implicit register if unknown.

```markdown
>> ---
   op: heartbeat
   name: notes
   thought_count: 6
   ---
```

**discover** — Probe all registered shards to check which are actually alive.

```markdown
>> ---
   op: discover
   ---
```

The daemon also supports all standard shard ops (write, read, list, etc.) on its own data.

## Shard Operations

**write** — Create an encrypted thought. Description in frontmatter, content in body.

```markdown
>> ---
   op: write
   description: meeting notes
   ---
   discussed roadmap

<< ---
   status: ok
   id: a1b2c3d4...
   ---
```

**read** — Decrypt a thought by ID.

```markdown
>> ---
   op: read
   id: a1b2c3d4...
   ---

<< ---
   status: ok
   description: meeting notes
   ---
   discussed roadmap
```

**list** — All thought IDs.

```markdown
>> ---
   op: list
   ---

<< ---
   status: ok
   ids: [a1b2c3d4..., e5f6a7b8...]
   ---
```

**delete** — Remove a thought.

```markdown
>> ---
   op: delete
   id: a1b2c3d4...
   ---
```

**search** — Keyword search over descriptions.

```markdown
>> ---
   op: search
   query: meeting
   ---

<< ---
   status: ok
   results:
     - id: a1b2c3d4...
       score: 1.00
   ---
```

**compact** — Move thoughts from unprocessed to processed block in given order.

```markdown
>> ---
   op: compact
   ids: [a1b2c3d4..., e5f6a7b8...]
   ---

<< ---
   status: ok
   moved: 2
   ---
```

**dump** — Decrypt all thoughts and return a complete Obsidian-ready Markdown document. Save the response directly as a `.md` file.

```markdown
>> ---
   op: dump
   ---

<< ---
   status: ok
   title: Architecture
   purpose: System design and patterns
   tags: [design, patterns, infrastructure]
   related: [rate-limiting, authentication]
   created: 2026-03-15T10:00:00Z
   exported: 2026-03-15T19:32:28Z
   thoughts: 3
   ---

   # Architecture

   System design and patterns

   ## Related

   [[rate-limiting]] | [[authentication]]

   ## Knowledge

   ### Database Schema Design

   Thoughts on table structure, indexes, normalization...

   ### Event-Driven Architecture

   Patterns for reactive systems and message queues...

   ## Unprocessed

   ### API Rate Limiting Notes

   Token bucket vs sliding window comparison...
```

**manifest** | **status** | **shutdown** | **gates** — Same as before, using frontmatter format.

## Project Structure

```
src/
  main.odin          Entry point: daemon subcommand or shard mode
  types.odin         Shared types, registry entry
  crypto.odin        HKDF, ChaCha20-Poly1305, thought encrypt/decrypt
  blob.odin          .shard file format: load, flush, two-block storage
  daemon.odin        Daemon registry: register, unregister, discover, persist
  ipc.odin           Platform-neutral message framing
  ipc_windows.odin   Named pipe (overlapped I/O for timed accept)
  ipc_posix.odin     Unix domain socket (poll for timed accept)
  node.odin          Node lifecycle, master election, idle timeout
  protocol.odin      Dispatch, op handlers, search
  markdown.odin      YAML frontmatter parser/serializer for wire format
tests/
  client.odin        Test client: client <name> [markdown_ops...]
```

## Data Format

The `.shard` file is a standalone binary blob:

```
[PROCESSED BLOCK]      count-prefixed encrypted thoughts (AI-ordered)
[UNPROCESSED BLOCK]    count-prefixed encrypted thoughts (append-only)
[MANIFEST BLOCK]       length-prefixed plaintext YAML/JSON
[GATES BLOCK]          plaintext routing signals
[gates_size: u32 LE]   4 bytes
[blob_hash: u8x32]     SHA-256 of all preceding bytes
[MAGIC: u64 LE]        0x5348524430303031 ("SHRD0001")
```

## Encryption

- Master key: 32 bytes, supplied as 64-char hex
- Per-thought key: `HKDF-SHA256(master, thought_id)`
- Cipher: ChaCha20-Poly1305 (IETF, 96-bit nonce, 128-bit tag)
- Body: `description + "\n---\n" + content`
- Seal: encrypted `SHA256(description)` for verification without full decryption
