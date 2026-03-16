# Shard — AI Agent Guide

You interact with Shard through an **MCP server** (Model Context Protocol). The MCP server connects to the Shard daemon and exposes all operations as tool calls over JSON-RPC 2.0 on stdio.

## Setup

The daemon must be running before the MCP server starts:

```bash
# Start the daemon (manages all shards in-process)
shard daemon &

# Start the MCP server (connects to daemon internally)
shard mcp
```

The MCP server is typically configured in your AI client's MCP settings (e.g. `claude_desktop_config.json`, Cursor, etc.) so it starts automatically. You don't call `shard mcp` manually — your client does.

## Available MCP Tools

All tools return YAML frontmatter responses. Tools that target a shard take a `shard` argument (the shard name). Tools marked with a key require a `key` argument (64-char hex master key).

### Discovery (no key)

| Tool | Arguments | Description |
|------|-----------|-------------|
| `shard_discover` | `query?` | List all shards from the daemon registry. Returns names, catalogs, and gates. Optional `query` filters by keyword. |
| `shard_catalog` | `shard` | Read a shard's catalog (name, purpose, tags, related shards). |
| `shard_gates` | `shard` | Read a shard's routing gates: description, positive (accepts), negative (rejects). |
| `shard_list` | `shard` | List all thought IDs in a shard. |
| `shard_status` | `shard` | Health check: node name, thought count, uptime. |

### Smart Search (require key)

| Tool | Arguments | Description |
|------|-----------|-------------|
| `shard_explore` | `key`, `query`, `limit?`, `depth?` | **Recommended for complex questions.** Deep graph traversal — starts from gate-matched shards, queries for matching thoughts, follows cross-links (related shards + `[[wikilinks]]` in content), and repeats until exhausted. Returns results grouped by shard with a full exploration trace. Default: 10 results, depth 3. |
| `shard_query` | `key`, `query`, `shard?`, `limit?` | Flat search across one or all shards. Returns top matching thoughts with full content. Good for simple lookups. |

### Thought Operations (require key)

| Tool | Arguments | Description |
|------|-----------|-------------|
| `shard_search` | `shard`, `key`, `query` | Keyword search over thought descriptions. Returns IDs and scores. |
| `shard_read` | `shard`, `key`, `id` | Decrypt and read a thought by ID. Returns description, content, agent, timestamps. |
| `shard_write` | `shard`, `key`, `description`, `content` | Write a new encrypted thought. Returns the new thought ID. |
| `shard_update` | `shard`, `key`, `id`, `description?`, `content?` | Update description and/or content. Omitted fields keep current value. |
| `shard_delete` | `shard`, `key`, `id` | Delete a thought by ID. |
| `shard_dump` | `shard`, `key` | Export all thoughts as Obsidian-compatible markdown. |

## Workflow

### Answering Questions (read path)

Use `shard_explore` — it does the full discovery loop automatically:

1. Checks the registry for shards whose gates match your query
2. Queries each shard for matching thoughts (returns decrypted content)
3. Scans content for `[[wikilinks]]` and checks each shard's related gate
4. Follows those cross-links to discover deeper connections
5. Repeats until no new leads, depth limit, or result limit reached
6. Returns all results + an exploration trace showing what was checked

For simple lookups where you already know the shard, use `shard_query` instead.

### Storing Knowledge (write path)

1. **Discover shards** — call `shard_discover` to see all available shards with their catalogs and gates.
2. **Evaluate gates** — read `shard_gates` to understand what each shard accepts/rejects. Use this to route thoughts to the right shard.
3. **Write** — call `shard_write` to store new knowledge. Include a searchable `description` and the full `content`.
4. **Cross-link** — use `[[shard-name]]` wikilinks in thought content to create navigable connections. These links are followed by `shard_explore` during searches.

## Concepts

- **Shard**: An encrypted file (`.shard`) containing thoughts. Each shard has a name, purpose, and topic gates.
- **Thought**: An atomic encrypted unit with a `description` (searchable title) and `content` (body). Metadata (`agent`, `created_at`, `updated_at`) is stored as plaintext.
- **Catalog**: A shard's plaintext identity card — name, purpose, tags, related shards. Readable without the master key.
- **Gates**: Plaintext routing signals. `positive` = topics the shard wants. `negative` = topics it rejects. `description` = what the shard contains. Use gates to decide which shard should receive a thought.
- **Daemon**: Central process managing all shards in-process. The MCP server connects to it automatically.

## Data Storage

All `.shard` files live under `.shards/`. The daemon discovers them automatically. You don't need to manage file paths.

## Encryption

- Master key: 32 bytes, supplied as 64-char hex string.
- Per-thought keys derived via HKDF-SHA256(master, thought_id).
- Cipher: ChaCha20-Poly1305.
- Catalogs, gates, and manifests are plaintext — no key needed to read.
- Thought descriptions and content are encrypted.

## Error Handling

All errors return `status: error` with an `error` field describing what went wrong. Common causes: missing `key`, invalid `id`, unknown shard name.
