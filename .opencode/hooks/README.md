# Shard Hook Scripts

- `shard-call.py`: low-level helper to call shard MCP tools over stdio.
- `context-cache-refresh.py`: refreshes `v3_context_cache` from `build_context`.
- `context-cache-read.py`: reads `v3_context_cache` for compaction injection.
- `session-created.sh`: refreshes context cache and writes a session-start thought.
- `session-idle.sh`: compacts shard thoughts and refreshes context cache.

Note: auto split and decision routing are now built into `shard.odin`.

These scripts are invoked automatically by `.opencode/plugins/shard-hooks.js`.
