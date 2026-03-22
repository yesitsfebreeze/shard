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
- [ ] **Cross-shard write routing** — On write, read index, check gates of known shards, route to the best match. Create a new shard if nothing fits.
- [x] **Query operation** — `query_thoughts` decrypts all thoughts and keyword-matches against descriptions (case-insensitive). Returns matching IDs + descriptions.

## Phase 4: Agent Interface (make shards usable by AI)

- [x] **MCP server** — JSON-RPC 2.0 over stdio (`--mcp`). Tools: `shard_write`, `shard_read`, `shard_query`, `shard_info`. Initialize handshake, length-prefixed responses.
- [ ] **HTTP+SSE server** — REST API + server-sent events for real-time updates. Secondary interface for web clients and monitoring.

## Phase 5: Intelligence (make shards refine themselves)

- [ ] **LLM integration** — Config from env vars (`LLM_URL`, `LLM_KEY`, `LLM_MODEL`). OpenAI-compatible API client.
- [ ] **Compaction** — Move thoughts from unprocessed to processed. LLM-assisted ordering and pruning. Lossless (merge revision chains) and lossy (summarize/prune stale) modes.
- [x] **Dump / Obsidian export** — `--dump` exports to `vault/<shard>.md` with YAML frontmatter (title, purpose, tags, created, thoughts count), Knowledge + Unprocessed sections, each thought as `### description` + content.

## Phase 6: Memory Layers (make the system think)

- [ ] **Topic cache** — Short-term memory. Ephemeral key-value store describing what matters now. Read/write/list/expire operations.
- [ ] **Context engine** — Assemble working context packets on demand. Not top-k retrieval — active construction from multiple shards + topic cache.
- [ ] **Vector search** — Embedding model integration (`EMBED_MODEL`). Index thought descriptions for semantic search alongside keyword search.

## Phase 7: Coordination (make shards work together)

- [ ] **Events** — Shard-to-shard event system. Emit events on write/compact/gate-change. Other shards subscribe via IPC.
- [ ] **Transaction** — Lock acquisition, commit, rollback for multi-step operations on a single shard.
- [ ] **Fleet** — Parallel dispatch across multiple shards. Fan-out queries, collect results.
- [ ] **Auto-shard creation** — When no existing shard accepts a thought, create a new shard EXE (copy clean binary + initialize catalog/gates).
