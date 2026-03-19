# Shard - AI Agent Reference

> This is your complete reference. Read overview first, then per-command docs as needed.

## Architecture

- **Shard**: An encrypted file (`.shard`) containing thoughts. Each shard has a name, a purpose, and topic gates.
- **Daemon**: A central process that manages all shards in-process. Connect once, access all shards.
- **Thought**: An atomic encrypted unit - a `description` (title) and optional `content` (body). Each thought also stores plaintext metadata: `agent` (who wrote it), `created_at`, and `updated_at` timestamps.
- **Catalog**: A shard's plaintext identity card (name, purpose, tags, related shards). Readable without the master key.
- **Gates**: Plaintext routing signals - `description`, `positive` (accept topics), `negative` (reject topics). Used to decide which shard should receive a thought.

## Workflow

1. **Get the big picture**: Call `shard_discover` with no params. One call returns every shard's name, purpose, thought count, tags, and thought descriptions (~500 tokens). This is your map.
2. **Load targeted context**: Use `shard_query` with `budget: 2000` to get just enough content for your task. Budget caps total content characters - results that don't fit are truncated with `truncated: true`. Drill deeper with `shard_read` on specific thoughts only if needed.
3. **Route operations**: Include `name: <shard>` in your message to target a specific shard through the daemon.
4. **Authenticate**: All encrypted ops (`write`, `read`, `update`, `delete`, `search`, `compact`, `dump`) require `key: <64-hex master key>`.

**Token-efficient pattern:** `shard_discover` -> `shard_query(budget: 2000)` -> maybe one `shard_read`. This replaces discovering + dumping multiple shards (~12,500 tokens) with ~800-2,800 tokens.

## Message Format

All communication uses **JSON** with the following structure:

```json
{
  "op": "<operation>",
  "key": "value",
  "list": ["a", "b", "c"],
  "content": "Optional body text"
}
```

**Rules:**
- All fields are optional except `op`.
- Lists are represented as JSON arrays.
- The `content` field holds the body text.
- Responses use the same JSON format. Parse the JSON for `status`, `id`, `ids`, `items`, etc.
- Multiple messages can be sent sequentially on the same connection. Each message is a complete JSON object.

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
- Catalogs, gates, and manifests are plaintext - no key needed.
- Thought descriptions and content are encrypted.
- Agent, created_at, and updated_at are stored as plaintext metadata.

## Per-Command Help

Use `--ai` on any command for specific guidance:

- `shard init --ai`      # First-time workspace setup
- `shard install --ai`   # Workspace + AI agent setup
- `shard daemon --ai`    # Daemon operations and registry
- `shard connect --ai`   # IPC session client
- `shard mcp --ai`       # MCP server and tools
- `shard new --ai`       # Creating new shards
- `shard dump --ai`      # Export shards as markdown
- `shard --ai`           # Shard node operations (thoughts, catalogs, gates)