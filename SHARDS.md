# Shard Workflow

This repository is configured to use shard MCP with context pinning across compaction.

## Runtime layout

- MCP binary: `.shards/bin/shard` (relative to repo root)
- Local shard state: existing shard runtime for this repo
- Thought cap (test): `max_thoughts = 128`

## MCP servers

- `shard` (local binary)
- `context7` (npx)
- `context-mode` (npx)

## Thought naming

Use stable, searchable prefixes:

- `v3_...` for repo-local notes
- `task_...` for active work notes
- `design_...` for architecture decisions
- `ops_...` for operational entries

Suffix with `_v1`, `_v2`, etc. for significant revisions.

## Retrieval pattern

1. Refresh cached context with `build_context` at session start.
2. Use `shard_query` and `shard_read` while working.
3. Write durable findings via `shard_write`.
4. Compact and refresh cache on session idle.

## Hook automation

Plugin hook:

- `.opencode/plugins/shard-hooks.js`

Scripts:

- `.opencode/hooks/session-created.sh`
- `.opencode/hooks/session-idle.sh`
- `.opencode/hooks/context-cache-refresh.py`
- `.opencode/hooks/context-cache-read.py`
- `.opencode/hooks/shard-call.py`

Behavior:

- On `session.created`: refresh cache key `v3_context_cache` and write `v3_session_started`.
- On `session.idle`: compact thoughts and refresh cache.
- On `experimental.session.compacting`: append cached context block back into continuation context.

Built-in split policy (`shard.odin`):

- Trigger when total thoughts reaches the built-in red threshold (`~88%` of `max_thoughts`).
- Create generic sub-shards named from current shard id:
  - `<shard-id>-topic-a`
  - `<shard-id>-topic-b`
- Child shard binaries are written under a parent folder:
  - `<shard_dir>/<parent-shard-id>/<child-shard-id>`
- Persist split state in cache key `<shard-id>_split_state`.

Built-in decision shard policy (`shard.odin`):

- Decision/important-note thoughts are routed to a dedicated shard:
  - `<shard-id>-decisions`
- Decision shard binary is also created under the parent folder.
- Routing triggers on descriptions like `decision_*`, `important_*`, `note_*` and decision markers in content.

## Compaction policy (Claude-style parity)

1. Keep durable shard context in cache key `v3_context_cache`.
2. Compact normal prompt/session memory as usual.
3. Re-append cached shard context after compaction so continuity is preserved.
