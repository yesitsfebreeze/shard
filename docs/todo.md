# Shard v3 — TODO

Ordered by execution dependency and impact. Each item unlocks the ones below it.

## Phase 1: Core Storage (make a shard that can hold thoughts)

- [x] **Thought struct** — Full type: id (16 bytes), description, content, agent, timestamps, revision chain, TTL, read/cite counts. Binary serialization in/out of thought blocks.
- [x] **Encryption** — ChaCha20-Poly1305 with HKDF-SHA256 per-thought key derivation from master key (`SHARD_KEY`). Seal and trust hashes. Encrypt/decrypt thought bodies.
- [x] **Write operation** — Accept a thought, encrypt it, append to unprocessed block, persist via `blob_write_self`.
- [x] **Read operation** — Decrypt and return a thought by ID. Walk processed + unprocessed blocks.
- [x] **Self-write via copy** — Working copy at `~/.shards/run/<shard-id>`, index at `~/.shards/index/<shard-id>` with revision tracking. `blob_write_self` writes to working copy. Index updated on shutdown, prev revision deleted on next startup.
- [x] **SHA-256 footer hash** — Replace the placeholder zeros with actual SHA-256 of all data bytes. Verify on read.

## Phase 2: Communication (make shards talk)

- [x] **IPC listener** — Unix domain socket at `/tmp/shard-<id>.sock`. Platform-split: `ipc_linux.odin` (real) + `ipc_stub.odin` (Windows dev builds).
- [x] **Wire protocol** — Length-prefixed JSON (u32 LE + payload, max 16 MiB). `ipc_send_msg` / `ipc_recv_msg`.
- [x] **Idle debounce timer** — `ipc_accept_timed` with `poll()`. Daemon loop exits on timeout, handles connections on accept.
- [x] **Request allocator** — 1 MiB arena per connection. Created in `handle_connection`, set on context, freed on return. `handle_request` runs with the request allocator.

## Phase 3: Routing (make shards smart about what they accept)

- [x] **Gates routing logic** — `gates_check` matches description+content against accept/reject terms (case-insensitive). Reject terms block, accept terms allow. Integrated into `write_thought`.
- [x] **Cross-shard write routing** — `route_to_peer` tries all peer shards via IPC when local gates reject. Creates a new auto-shard if no peer accepts.
- [x] **Query operation** — `query_thoughts` decrypts all thoughts and keyword-matches against descriptions (case-insensitive). Returns matching IDs + descriptions.

## Phase 4: Agent Interface (make shards usable by AI)

- [x] **MCP server** — JSON-RPC 2.0 over stdio (`--mcp`). Tools: `shard_write`, `shard_read`, `shard_query`, `shard_info`. Initialize handshake, length-prefixed responses.
- [x] **HTTP+SSE server** — `--http` starts TCP server on `PORT` (default 8080). Routes: GET `/info`, POST `/query`, POST `/write`. JSON responses.

## Phase 5: Intelligence (make shards refine themselves)

- [x] **LLM integration** — `load_llm_config` reads `LLM_URL`, `LLM_KEY`, `LLM_MODEL` from env. `llm_chat(system, user)` calls OpenAI-compatible API via curl subprocess. `llm_extract_content` parses response.
- [x] **Compaction** — `compact` moves all unprocessed thoughts to processed and persists. `--compact` CLI command. LLM-assisted ordering deferred until needed.
- [x] **Dump / Obsidian export** — `--dump` exports to `vault/<shard>.md` with YAML frontmatter (title, purpose, tags, created, thoughts count), Knowledge + Unprocessed sections, each thought as `### description` + content.

## Phase 6: Memory Layers (make the system think)

- [x] **Topic cache** — In-memory `map[string]string` on State. `cache_set/get/delete/list/clear` procs. MCP tools: `cache_set`, `cache_get`, `cache_delete`, `cache_list`. Ephemeral — lost on shutdown.
- [x] **Context engine** — `build_context(task)` assembles active topics from cache + keyword-matched thoughts + shard purpose. MCP tool: `build_context`.
- [x] **Vector search** — `embed_text` calls OpenAI-compatible embeddings API via curl. `vec_index_thought` auto-indexes on write. `vec_search` with cosine similarity. MCP tool: `vec_search`.

## Phase 7: Coordination (make shards work together)

- [x] **Events** — `emit_event` sends JSON event to all peer shards via IPC connect. `Event_Kind`: Write, Compact, Gate_Change. Wired into `write_thought` and `compact`. `ipc_connect` added for client-side socket connection.
- [x] **Transaction** — `tx_begin` snapshots shard data, `tx_commit` persists via blob_write_self, `tx_rollback` restores snapshot. Single-shard, in-process.
- [x] **Fleet** — `fleet_query` fans out keyword queries to all peer shards via IPC, collects responses. `Fleet_Result` per shard.
- [x] **Auto-shard creation** — `create_shard(name, purpose)` copies clean exe code, appends empty shard data with catalog, writes SHA-256 hash, registers in index.

## Phase 8: Enhanced Routing (smart data routing)

- [ ] **Shard descriptors** — Replace simple gates with a rich JSON descriptor: positive/negative terms, data transformers (field-level routing for JSON, keyword routing for text), links to other shards, and compression.
- [ ] **`--init` command** — Create a shard from a descriptor JSON. Sets catalog, gates, transformers in one shot.
- [ ] **Gate auto-learning** — After N writes, ask the LLM to infer accept/reject terms and update gates automatically.

## Phase 9: Network Intelligence (multi-shard coordination)

- [x] **Fleet ask** — `fleet_ask` reads all peer shard binaries, builds context from each, asks LLM per shard, merges answers. MCP tool: `fleet_ask`.
- [ ] **Cross-shard context** — When answering, note related shards. Populate catalog `related` field from co-occurring queries.
- [ ] **MCP native integration** — Wire shard as a Claude Code MCP server in settings.json for direct conversation access.

## Phase 10: Data Quality (production readiness)

- [x] **Thought timestamps** — `now_rfc3339` generates timestamps. `created_at` set on every write.
- [ ] **Persistent vector index** — Store embeddings in the binary format alongside thoughts. Semantic search survives restarts.
- [ ] **Streaming LLM** — SSE streaming for partial answers. Handle slow models without timeout.
- [ ] **Catalog auto-populate** — First write infers name/purpose/tags from content if catalog is empty.
