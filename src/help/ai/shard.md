# shard (node) — AI Agent Reference

## Usage

```bash
shard                              # start default shard node
shard --name <name>                # custom node name (IPC endpoint)
shard --key <hex>                  # master key (64 hex chars)
shard --data <path>                # path to .shard file
shard --timeout <secs>             # idle timeout (0=never, default 300)
shard --dump [path]                # export as markdown and exit
```

## Environment

- `SHARD_KEY` env var can supply the master key instead of `--key`

## Thought Operations (require `key`)

Include `name: <shard>` when routing through the daemon.

### write — Store an encrypted thought

```json
{
  "op": "write",
  "name": "<shard>",
  "key": "<64-hex master key>",
  "description": "meeting notes",
  "agent": "my-agent"
}
```
We discussed the roadmap and agreed on priorities.

- `agent` is optional (max 64 chars). Records who wrote the thought. Stored as plaintext.
- `created_at` and `updated_at` are set automatically.

Response: `status: ok`, `id: <32-hex>`

### read — Decrypt a thought by ID

```json
{
  "op": "read",
  "name": "<shard>",
  "key": "<64-hex master key>",
  "id": "<thought-id>"
}
```

Response:
```json
{
  "status": "ok",
  "description": "meeting notes",
  "agent": "my-agent",
  "created_at": "2026-03-15T20:00:00Z",
  "updated_at": "2026-03-15T20:00:00Z",
  "content": "We discussed the roadmap and agreed on priorities."
}
```

### update — Modify a thought (omitted fields keep current value)

```json
{
  "op": "update",
  "name": "<shard>",
  "key": "<64-hex master key>",
  "id": "<thought-id>",
  "description": "updated title"
}
```
New body content replaces the old content.

Response: `status: ok`, `id: <thought-id>`

The `updated_at` timestamp is refreshed automatically. The original `agent` and `created_at` are preserved.

### delete — Remove a thought

```json
{
  "op": "delete",
  "name": "<shard>",
  "key": "<64-hex master key>",
  "id": "<thought-id>"
}
```

### list — Get all thought IDs (no key required)

```json
{
  "op": "list",
  "name": "<shard>"
}
```

Response: `status: ok`, `ids: [id1, id2, ...]`

### search — Keyword search over thought descriptions

```json
{
  "op": "search",
  "name": "<shard>",
  "key": "<64-hex master key>",
  "query": "meeting"
}
```

Response: `status: ok`, `results:` array with `id`, `score`, and `description` per match.

Optional `agent` field filters results to thoughts written by that agent.

### query — Search and read in one shot (recommended)

Searches thought descriptions and returns the top N results with **decrypted content**. Combines search + read into a single operation.

```json
{
  "op": "query",
  "name": "<shard>",
  "key": "<64-hex master key>",
  "query": "encryption pipeline",
  "thought_count": 5
}
```

Response: `status: ok`, `results:` array with `id`, `score`, `description`, and `content` per match.

**Budget parameter** — cap total content characters:
```json
{
  "op": "query",
  "name": "<shard>",
  "key": "<64-hex master key>",
  "query": "encryption pipeline",
  "thought_count": 5,
  "budget": 2000
}
```

When `budget` > 0, content is truncated to fit. Results that were cut include `truncated: true`. Use `shard_read` to get full content.

### compact — Move thoughts from unprocessed to processed

```json
{
  "op": "compact",
  "name": "<shard>",
  "key": "<64-hex master key>",
  "ids": [id1, id2]
}
```

Response: `status: ok`, `moved: <count>`

### dump — Export all thoughts as Obsidian markdown

```json
{
  "op": "dump",
  "name": "<shard>",
  "key": "<64-hex master key>"
}
```

Response: full markdown document with all decrypted thoughts (no YAML frontmatter).

## Catalog Operations (no key required)

### catalog — Read shard identity

```json
{
  "op": "catalog",
  "name": "<shard>"
}
```

Response: `status: ok`, `catalog:` object with `name`, `purpose`, `tags`, `related`, `created`.

### set_catalog — Update shard identity

```json
{
  "op": "set_catalog",
  "name": "<shard>",
  "purpose": "meeting notes and project documentation",
  "tags": ["work", "notes", "meetings"],
  "related": ["journal"]
}
```

## Gate Operations (no key required)

Gates are plaintext routing signals.

### gates — Read all gates at once

```json
{
  "op": "gates",
  "name": "<shard>"
}
```

| Read op | Set op | Purpose |
|---------|--------|---------|
| `description` | `set_description` | What this shard contains |
| `positive` | `set_positive` | Topics shard WANTS |
| `negative` | `set_negative` | Topics shard REJECTS |
| `related` | `set_related` | Linked shard names |

### link / unlink — Add or remove related shards (max 32)

```json
{
  "op": "link",
  "name": "<shard>",
  "items": ["auth", "api-design"]
}
```

```json
{
  "op": "unlink",
  "name": "<shard>",
  "items": ["api-design"]
}
```

## Utility Operations (no key required)

### status — Health check

```json
{
  "op": "status",
  "name": "<shard>"
}
```

Response: `status: ok`, `node_name`, `thoughts`, `uptime_secs`.

### manifest — Read or write freeform plaintext metadata

```json
{
  "op": "manifest",
  "name": "<shard>"
}
```

Write by including body content after the JSON object.

### shutdown — Stop a shard process

```json
{
  "op": "shutdown",
  "name": "<shard>"
}
```

## Beast Mode — Self-Organizing Memory

### remember — Create a new shard with catalog and gates

When a thought doesn't fit any existing shard's gates, create a new shard on the fly:

```json
{
  "op": "remember",
  "name": "quantum-physics",
  "purpose": "notes on quantum mechanics and related topics",
  "tags": ["physics", "quantum", "science"],
  "items": ["quantum", "entanglement", "superposition", "wave function"],
  "related": ["chemistry", "math"]
}
```

- `name` (required): The shard name. Must be unique, cannot be "daemon".
- `purpose`: What this shard is for.
- `tags`: Topic tags for discovery.
- `items`: Becomes the **positive gate** (topics this shard wants).
- `related`: Names of related shards.

**Limit:** Maximum 64 shards.

**When to use:**
1. Send `op: registry` to see all shards and their gates.
2. Evaluate whether the thought fits any existing shard's positive/negative gates.
3. If no shard is a good fit, use `remember` to create a new category.
4. Then `write` the thought to the new shard.