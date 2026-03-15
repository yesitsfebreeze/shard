# shard — AI Agent Reference

> You are interacting with `shard`, an encrypted thought store.
> This document is your complete reference. Read it fully before sending any operations.

## Architecture

- **Shard**: An encrypted file (`.shard`) containing thoughts. Each shard has a name, a purpose, and topic gates.
- **Daemon**: A central process that manages all shards in-process. Connect once, access all shards.
- **Thought**: An atomic encrypted unit — a `description` (title) and optional `content` (body). Each thought also stores plaintext metadata: `agent` (who wrote it), `created_at`, and `updated_at` timestamps.
- **Catalog**: A shard's plaintext identity card (name, purpose, tags, related shards). Readable without the master key.
- **Gates**: Plaintext routing signals — `description`, `positive` (accept topics), `negative` (reject topics). Used to decide which shard should receive a thought.

## Message Format

All communication uses **YAML frontmatter** with an optional markdown body:

```
---
op: <operation>
key: value
list: [a, b, c]
---
Optional body text (maps to the "content" field).
```

**Rules:**
- The opening `---` and closing `---` are required.
- Key-value pairs go between them. Lists use `[a, b, c]` syntax.
- Anything after the closing `---` is the body/content.
- Responses use the same format. Parse the frontmatter for `status`, `id`, `ids`, `items`, etc.
- Multiple messages can be sent sequentially on the same connection. Each `---` opening after a body starts a new message.

## How to Connect

### Via `shard connect` (IPC session)

```bash
# Start daemon (if not already running)
shard daemon &

# Open a persistent session (reads messages from stdin, prints responses to stdout)
shard connect           # connects to daemon (default)
shard connect <name>    # connects to a specific standalone shard
```

Pipe YAML frontmatter messages to stdin. One connection for the entire session — no reconnect per op. Send EOF when done.

### Via MCP (JSON-RPC over stdio)

```bash
shard mcp
```

Starts a Model Context Protocol server on stdio. The daemon must be running. Use standard MCP tool calls (`shard_discover`, `shard_read`, `shard_write`, etc.) — the MCP server routes them through the daemon internally.

## Workflow

1. **Connect to daemon**: `shard connect`
2. **List all shards**: Send `op: registry` — returns every shard with its catalog and gates.
3. **Evaluate gates**: Read each shard's `description`, `positive`, and `negative` gates to decide which shard is relevant.
4. **Route operations**: Include `name: <shard>` in your message to target a specific shard through the daemon.
5. **Authenticate**: All encrypted ops (`write`, `read`, `update`, `delete`, `search`, `compact`, `dump`) require `key: <64-hex master key>`.

## Operations Reference

### Daemon Operations (no key required)

#### registry — List all shards

```yaml
---
op: registry
---
```

Response:

```yaml
---
status: ok
registry:
  - name: notes
    data_path: .shards/notes.shard
    thought_count: 5
    catalog:
      name: notes
      purpose: meeting notes
      tags: [work, notes]
    gate_desc: [meeting notes, project docs]
    gate_positive: [planning, architecture]
    gate_negative: [spam, off-topic]
---
```

#### registry with query — Filter shards by keyword (matches name, purpose, tags)

```yaml
---
op: registry
query: notes
---
```

#### discover — Re-scan .shards/ directory

```yaml
---
op: discover
---
```

### Thought Operations (require `key`)

Include `name: <shard>` when routing through the daemon.

#### write — Store an encrypted thought

```yaml
---
op: write
name: <shard>
key: <64-hex master key>
description: meeting notes
agent: my-agent
---
We discussed the roadmap and agreed on priorities.
```

- `agent` is optional (max 64 chars). Records who wrote the thought. Stored as plaintext.
- `created_at` and `updated_at` are set automatically.

Response: `status: ok`, `id: <32-hex>`

#### read — Decrypt a thought by ID

```yaml
---
op: read
name: <shard>
key: <64-hex master key>
id: <thought-id>
---
```

Response:

```yaml
---
status: ok
description: meeting notes
agent: my-agent
created_at: 2026-03-15T20:00:00Z
updated_at: 2026-03-15T20:00:00Z
---
We discussed the roadmap and agreed on priorities.
```

#### update — Modify a thought (omitted fields keep current value)

```yaml
---
op: update
name: <shard>
key: <64-hex master key>
id: <thought-id>
description: updated title
---
New body content replaces the old content.
```

Response: `status: ok`, `id: <thought-id>`

The `updated_at` timestamp is refreshed automatically. The original `agent` and `created_at` are preserved.

#### delete — Remove a thought

```yaml
---
op: delete
name: <shard>
key: <64-hex master key>
id: <thought-id>
---
```

#### list — Get all thought IDs (no key required)

```yaml
---
op: list
name: <shard>
---
```

Response: `status: ok`, `ids: [id1, id2, ...]`

#### search — Keyword search over thought descriptions

```yaml
---
op: search
name: <shard>
key: <64-hex master key>
query: meeting
---
```

Response: `status: ok`, `results:` array with `id` and `score` per match.

Optional `agent` field filters results to thoughts written by that agent:

```yaml
---
op: search
name: <shard>
key: <64-hex master key>
query: meeting
agent: my-agent
---
```

#### compact — Move thoughts from unprocessed to processed

```yaml
---
op: compact
name: <shard>
key: <64-hex master key>
ids: [id1, id2]
---
```

Response: `status: ok`, `moved: <count>`

#### dump — Export all thoughts as Obsidian markdown

```yaml
---
op: dump
name: <shard>
key: <64-hex master key>
---
```

Response: full markdown document with YAML frontmatter, wikilinks, and all decrypted thoughts organized under Knowledge (processed) and Unprocessed sections.

### Catalog Operations (no key required)

#### catalog — Read shard identity

```yaml
---
op: catalog
name: <shard>
---
```

Response: `status: ok`, `catalog:` object with `name`, `purpose`, `tags`, `related`, `created`.

#### set_catalog — Update shard identity (only provided fields change)

```yaml
---
op: set_catalog
name: <shard>
purpose: meeting notes and project documentation
tags: [work, notes, meetings]
related: [journal]
---
```

### Gate Operations (no key required)

Gates are plaintext routing signals. Read ops return current values. Set ops replace the list.

| Read op       | Set op            | Purpose                     |
|---------------|-------------------|-----------------------------|
| `description` | `set_description` | What this shard contains    |
| `positive`    | `set_positive`    | Topics shard WANTS          |
| `negative`    | `set_negative`    | Topics shard REJECTS        |
| `related`     | `set_related`     | Linked shard names          |

Set example:

```yaml
---
op: set_positive
name: <shard>
items: [planning, architecture, design]
---
```

#### link / unlink — Add or remove related shards (max 32)

```yaml
---
op: link
name: <shard>
items: [auth, api-design]
---
```

```yaml
---
op: unlink
name: <shard>
items: [api-design]
---
```

### Utility Operations (no key required)

#### status — Health check

```yaml
---
op: status
name: <shard>
---
```

Response: `status: ok`, `node_name`, `thoughts`, `uptime_secs`.

#### manifest — Read or write freeform plaintext metadata

```yaml
---
op: manifest
name: <shard>
---
```

Write by including body content after the closing `---`.

#### shutdown — Stop a shard process

```yaml
---
op: shutdown
name: <shard>
---
```

## Creating a New Shard (non-interactive)

The `shard new` wizard requires interactive stdin. As an AI agent, do this instead:

1. Create the shard file directly:
   ```bash
   shard --name my-shard --key <64-hex> --timeout 0 &
   ```
2. Tell the daemon to discover it:
   ```yaml
   ---
   op: discover
   ---
   ```
3. Configure it through the daemon:
   ```yaml
   ---
   op: set_catalog
   name: my-shard
   purpose: what this shard is for
   tags: [topic1, topic2]
   ---
   ---
   op: set_positive
   name: my-shard
   items: [things, this, shard, wants]
   ---
   ```

## MCP Tools

When using `shard mcp`, these tools are available via JSON-RPC:

| Tool              | Key? | Description                              |
|-------------------|------|------------------------------------------|
| `shard_discover`  | No   | List/filter shards from the registry     |
| `shard_catalog`   | No   | Read a shard's catalog                   |
| `shard_gates`     | No   | Read a shard's routing gates             |
| `shard_list`      | No   | List all thought IDs                     |
| `shard_status`    | No   | Health check (name, thoughts, uptime)    |
| `shard_search`    | Yes  | Keyword search thought descriptions      |
| `shard_read`      | Yes  | Decrypt and read a thought by ID         |
| `shard_write`     | Yes  | Write a new encrypted thought            |
| `shard_update`    | Yes  | Update a thought's description/content   |
| `shard_delete`    | Yes  | Delete a thought by ID                   |
| `shard_dump`      | Yes  | Export all thoughts as markdown          |

All tools that target a shard take a `shard` argument (the shard name). Tools marked "Key" also require a `key` argument (64-hex master key).

## Error Responses

All errors return `status: error` with an `error` field:

```yaml
---
status: error
error: description of what went wrong
---
```

Common causes: missing `key`, invalid `id`, unknown `op`, shard not found.

## Encryption

- Master key: 32 bytes, supplied as 64-char hex string.
- Per-thought key derived via HKDF-SHA256(master, thought_id).
- Cipher: ChaCha20-Poly1305 (IETF, 96-bit nonce, 128-bit tag).
- Catalogs, gates, and manifests are plaintext — no key needed.
- Thought descriptions and content are encrypted.
- Agent, created_at, and updated_at are stored as plaintext metadata.
