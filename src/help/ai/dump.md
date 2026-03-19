# shard dump — AI Agent Reference

## What It Does

Exports `.shard` files as Obsidian-compatible markdown. Each shard becomes a `.md` file with YAML frontmatter, wikilinks to related shards, and thought content organized by Knowledge/Unprocessed sections.

## CLI Usage

```bash
shard dump [path] [--out <path>] [--shard <name>] [--key <hex>]
```

- `path` / `--out` — output directory (default: `dump/`)
- `--shard` — export a single shard by name (default: all)
- `--key` — master key (64 hex chars). Also reads `SHARD_KEY` env or `.shards/keychain`.

## MCP Usage

Use the `shard_dump` tool:

```json
{"name": "shard_dump", "arguments": {"path": "dump/", "shard": "decisions"}}
```

- `path` — output directory (required)
- `shard` — export only this shard (optional, default: all)

## Behavior

- Skips `daemon.shard`
- Skips shards with thoughts but no available key (counted as skipped)
- Generates `index.md` with all shard names, purposes, and tags (unless single-shard mode)
- Scans exported files for `[[wikilinks]]` and reports broken links
- Output is compatible with Obsidian, Logseq, and other markdown-based tools
