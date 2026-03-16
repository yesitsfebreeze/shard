# shard dump — AI Agent Reference

## What It Does

Exports all shards as Obsidian-compatible markdown files. Creates a directory with one `.md` file per shard.

## Usage

```bash
shard dump [path] [--key <hex>]
```

- `path` — Output directory (default: `markdown/`)
- `--key` — Master key for encrypted shards (or use `SHARD_KEY` env var, or keychain)

## Key Resolution

Keys are resolved in order:
1. `--key` flag
2. `SHARD_KEY` environment variable
3. `.shards/keychain` lookup per shard

## Output

Creates `<path>/<shard-name>.md` for each shard. Files contain:
- YAML frontmatter with shard catalog
- Sections for Knowledge (processed thoughts) and Unprocessed
- Wikilinks between related thoughts

## Skipped Shards

Shards are skipped if:
- No key available and the shard has thoughts (encrypted)
- File cannot be loaded

## For AI Agents

Prefer `shard_digest` + `shard_query(budget:)` over `shard dump` for loading context. Dump is useful for:
- Full workspace backup
- Offline reading
- Converting to another system

The digest + query pattern uses ~800-2,800 tokens vs. ~12,500+ for full dump.