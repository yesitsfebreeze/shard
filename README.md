# 💎 Shard

**An encrypted thought store for humans and AI agents.**

Shard is a single binary that stores, encrypts, and serves knowledge. Each `.shard` file is a self-contained database of thoughts — encrypted at rest, queryable at runtime, and exportable as Obsidian-compatible markdown.

One daemon manages all your shards in-process. Connect once, access everything.

---

## Quick Start

```bash
# Build (requires Odin dev-2025-01+)
odin build src/ -out:shard

# Generate a master key
python -c "import secrets; print(secrets.token_hex(32))"

# Create your first shard
./shard new

# Start the daemon
./shard daemon &

# Open a session
./shard connect
```

Then send operations on stdin:

```yaml
---
op: registry
---
```

## How It Works

```
                        ┌─────────────────┐
                        │  💎  daemon     │  endpoint: shard-daemon
                        │                 │  manages all shards in-process
                        │  registry:      │  loads blobs on demand
                        │    notes     5  │  evicts after 5 min idle
                        │    journal  12  │
                        │    archive  30  │
                        └────────┬────────┘
                                 │
              ┌──────────────────┼──────────────────┐
              │                  │                  │
        .shards/           .shards/           .shards/
       notes.shard        journal.shard      archive.shard
```

- **One binary, one daemon.** The daemon loads shard files in-process on demand. No separate process per shard.
- **Encrypted at rest.** Thoughts are encrypted with ChaCha20-Poly1305. Per-thought keys derived via HKDF. Catalogs and gates stay plaintext for routing.
- **AI-native.** Gates tell agents what a shard wants and rejects. The registry exposes everything an AI needs to pick the right shard. An MCP server provides tool-based access.
- **Obsidian-ready.** The `dump` op exports a complete `.md` file with YAML frontmatter, wikilinks, and all decrypted thoughts.

## Commands

| Command | Description |
|---------|-------------|
| `shard daemon [--data <path>]` | Start the daemon |
| `shard new` | Create a new shard (interactive wizard) |
| `shard connect [name]` | Open a session to the daemon or a standalone shard |
| `shard mcp` | Start the MCP server (JSON-RPC over stdio) |
| `shard help [command]` | Show help for a command |
| `shard --ai-help` | Print structured markdown reference for AI agents |

### Standalone mode (advanced)

Run a shard as its own process, outside the daemon:

```bash
shard --name notes --key <64-hex> [--data <path>] [--timeout <secs>] [--dump [path]]
```

## Message Format

All communication uses YAML frontmatter with an optional markdown body:

```yaml
---
op: write
name: notes
key: <64-hex master key>
description: meeting notes
agent: claude
---
We discussed the roadmap and agreed on priorities.
```

Responses follow the same format:

```yaml
---
status: ok
id: a1b2c3d4e5f6a7b8
---
```

The body after `---` maps to the `content` field. Lists use `[a, b, c]` syntax.

## Operations

### Daemon

| Op | Description |
|----|-------------|
| `registry` | List all known shards with catalogs and gates |
| `registry` + `query` | Filter shards by keyword (matches name, purpose, tags) |
| `discover` | Re-scan `.shards/` directory and refresh the registry |
| `remember` | Create a new shard with catalog and gates (see Beast Mode below) |

Route any shard op through the daemon by adding `name: <shard>` to your request.

### Thoughts (require `key`)

| Op | Description |
|----|-------------|
| `write` | Store an encrypted thought. Fields: `description`, body = content, optional `agent` |
| `read` | Decrypt a thought by ID. Returns `description`, `agent`, `created_at`, `updated_at`, body = content |
| `update` | Update description and/or content. Omitted fields keep current value |
| `delete` | Remove a thought by ID |
| `search` | Keyword search over descriptions. Optional `agent` filter |
| `compact` | Move thoughts from unprocessed to processed in given order |
| `dump` | Export all thoughts as Obsidian-compatible markdown |
| `list` | Get all thought IDs *(no key required)* |

### Catalog & Gates (no key required)

| Op | Description |
|----|-------------|
| `catalog` / `set_catalog` | Read/write the shard's identity (name, purpose, tags, related) |
| `description` / `set_description` | What this shard contains |
| `positive` / `set_positive` | Topics this shard wants to receive |
| `negative` / `set_negative` | Topics this shard rejects |
| `related` / `set_related` | Linked shard names |
| `link` / `unlink` | Add/remove entries in the related list (max 32) |

### Utility (no key required)

| Op | Description |
|----|-------------|
| `status` | Health check: node name, thought count, uptime |
| `manifest` | Read/write freeform plaintext metadata |
| `shutdown` | Gracefully stop the shard process |

## MCP Server

```bash
shard daemon &
shard mcp
```

The MCP server exposes shard operations as tools over JSON-RPC 2.0 on stdio. Available tools: `shard_discover`, `shard_catalog`, `shard_gates`, `shard_list`, `shard_status`, `shard_search`, `shard_read`, `shard_write`, `shard_update`, `shard_delete`, `shard_dump`.

## AI Workflow

```
1. shard connect              # connect to daemon
2. op: registry               # see all shards, evaluate gates
3. op: search, name: notes    # find relevant thoughts
4. op: read, name: notes      # read what you need
5. op: write, name: notes     # store new knowledge
6. EOF                        # done
```

Run `shard --ai-help` for the complete structured reference.

## Beast Mode — Self-Organizing Memory

When a shared master key is available (via `.shards/key` file or `SHARD_KEY` env var), AI agents can autonomously create new shards to organize knowledge into categories that don't exist yet.

**How it works:** If a thought doesn't fit any existing shard's gates, the AI creates a new category on the fly using the `remember` op:

```yaml
---
op: remember
name: quantum-physics
purpose: notes on quantum mechanics and related topics
tags: [physics, quantum, science]
items: [quantum, entanglement, superposition, wave function]
related: [chemistry, math]
---
```

This creates `.shards/quantum-physics.shard` with the catalog and positive gate set, registers it in the daemon immediately, and returns the catalog. The `items` field becomes the positive gate. The AI can then write thoughts to it using the shared key.

**The shard limit is 64** to prevent runaway creation. Negative gates and description gates can be refined afterward via `set_negative` / `set_description`.

**Setup:** Store the shared master key in `.shards/key` (a plain text file with 64 hex chars). The MCP server reads it automatically. All shards created via `remember` use this key for encryption.

**The result:** The knowledge base grows and self-organizes. The AI evaluates gates to route thoughts, and when nothing fits, it creates a new category. Over time, the shard collection reflects the actual shape of the knowledge — not a predefined taxonomy.

## Data Format

The `.shard` file is a standalone binary blob:

```
[PROCESSED BLOCK]        count-prefixed encrypted thoughts (AI-ordered)
[UNPROCESSED BLOCK]      count-prefixed encrypted thoughts (append-only)
[CATALOG BLOCK]          length-prefixed plaintext JSON (shard identity)
[MANIFEST BLOCK]         length-prefixed plaintext YAML/JSON
[GATES BLOCK]            plaintext routing signals
[gates_size: u32 LE]     4 bytes
[blob_hash: u8×32]       SHA-256 of all preceding bytes
[MAGIC: u64 LE]          0x5348524430303032 ("SHRD0002")
```

## Encryption

- **Master key**: 32 bytes, supplied as 64-char hex string
- **Per-thought key**: `HKDF-SHA256(master, thought_id)`
- **Cipher**: ChaCha20-Poly1305 (IETF, 96-bit nonce, 128-bit tag)
- **Plaintext**: Catalogs, gates, manifests (no key needed to read)
- **Encrypted**: Thought descriptions and content
- **Metadata**: `agent`, `created_at`, `updated_at` stored as plaintext per thought

## Build

Requires [Odin](https://odin-lang.org/) (dev-2025-01 or later).

```bash
# Standard build
odin build src/ -out:shard

# Optimized for size (~240 KB with UPX)
odin build src/ -out:shard -o:size
upx --best --lzma shard

# Optimized for speed
odin build src/ -out:shard -o:speed
```

## Project Structure

```
src/
  main.odin          Entry point, CLI, subcommands
  types.odin         Core types: Thought, Blob, Node, Registry
  crypto.odin        HKDF, ChaCha20-Poly1305, thought encrypt/decrypt
  blob.odin          .shard file format: load, flush, two-block storage
  daemon.odin        Daemon: registry, slot routing, discovery, eviction
  node.odin          Node lifecycle, event loop, idle timeout
  protocol.odin      Op dispatch, handlers, search
  markdown.odin      YAML frontmatter parser/serializer (wire format)
  mcp.odin           MCP server: JSON-RPC over stdio, tool definitions
  ipc.odin           Platform-neutral IPC interface
  ipc_windows.odin   Named pipes (overlapped I/O)
  ipc_posix.odin     Unix domain sockets (poll)
  help.odin          Compile-time embedded help text
  help/              Help text files (overview, shard, daemon, new, connect, mcp, ai)
tests/
  client.odin        Test client
```
