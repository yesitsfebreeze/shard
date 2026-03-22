#!/bin/bash
export HOME=/root
export SHARD_KEY="000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
mkdir -p /root/.shards
cp /data/_config.jsonc /root/.shards/_config.jsonc 2>/dev/null

S=/app/shard

w() {
  local desc="$1" content="$2"
  printf '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"shard_write","arguments":{"description":"%s","content":"%s"}}}\n' \
    "$(echo "$desc" | sed 's/"/\\"/g')" "$(echo "$content" | sed 's/"/\\"/g')" \
    | "$S" --mcp 2>/dev/null | grep -o '"text":"[^"]*"'
}

echo "=== Indexing Shard v3 Knowledge ==="

w "Architecture Overview" "Single-binary encrypted knowledge routing system in Odin. Each shard is its own EXE with encrypted thoughts appended after executable code. Each EXE runs its own daemon with idle debounce. Single file shard.odin, no comments, Linux only, built in Docker. The MCP process acts as hub managing all shard nodes."

w "Binary Format" "Layout: exe code, processed thoughts block, unprocessed thoughts block, catalog JSON, manifest, gates JSON, data_size u32, SHA-256 hash, magic bytes SHRD0006 (0x5348524430303036). To locate data: read last 8 bytes for magic, walk backwards through footer. Writes: assemble new binary to .tmp, rename over original, chmod +x."

w "Encryption System" "ChaCha20-Poly1305 with HKDF-SHA256 per-thought key derivation from master key (SHARD_KEY env var or config). Each thought gets unique key via HKDF(master, thought_id). Seal is encrypted SHA256 of description for verification without full decrypt. Trust token is SHA256(key || SHA256(plaintext)) for integrity binding. Nonce is random 12 bytes per encryption."

w "Thought Data Model" "Thought struct: id (16 random bytes), trust (Trust_Token 32 bytes), seal_blob (encrypted desc hash), body_blob (encrypted description + separator + content), agent string, created_at RFC3339, updated_at, revises (parent thought ID), ttl u32, read_count u32, cite_count u32. Body separator is newline-dash-dash-dash-newline."

w "Thought Binary Serialization" "Per thought: id:16, seal_len:u32le, seal_blob, body_len:u32le, body_blob, agent_len:u8, agent, created_len:u8, created_at, updated_len:u8, updated_at, revises:16, ttl:u32le, read_count:u32le, cite_count:u32le, trust:32. All multi-byte integers little-endian."

w "Index and Revision Lifecycle" "Shards register in ~/.shards/index/ one file per shard ID containing exe path on line 1, prev path on line 2. Working copies in ~/.shards/run/. Shard ID from slugified catalog name or first 16 hex chars of SHA256(exe_path). On daemon start: create working copy, write index. On shutdown: index updated to point to working copy, old exe marked prev. Next startup: delete prev revision."

w "IPC System" "Unix domain sockets at /tmp/shard-ID.sock. Wire protocol: u32 LE payload length followed by UTF-8 JSON bytes. Max message 16 MiB. Poll-based accept with configurable idle timeout (default 30s). Per-connection request arena allocator 1 MiB freed on return. ipc_listen, ipc_connect, ipc_accept_timed, ipc_send_msg, ipc_recv_msg."

w "MCP Server" "Runs via --mcp flag over stdio. JSON-RPC 2.0. Reads newline-delimited JSON from stdin, writes responses to stdout. Console logger redirected to stderr in MCP mode. Tools defined in help/tools.json loaded via #load at compile time. The MCP process is the hub that can read any shard binary via load_peer_blob."

w "Hub and Node Architecture" "MCP process is the persistent hub. Each shard binary is a node. Hub reads any shard via load_blob_from_raw without spawning processes. shard_ask and shard_query accept optional shard parameter to target peers. fleet_ask fans out to all shards. shard_list shows all registered nodes with thought counts. Nodes are ephemeral, hub is persistent."

w "Descriptor System" "Shards have descriptors: array of format definitions (json/markdown/text) with match rules, structure descriptions, link definitions. Gates use a gate string embedded as vector for semantic similarity routing. shard_ingest sends data plus descriptors to LLM for decomposition. --init creates shard from descriptor JSONC file setting catalog, gates, descriptors, links."

w "Gate Routing" "gates_check uses cosine similarity on gate embeddings (threshold 0.7 accept, 0.3 reject) with keyword fallback. gates_describe_for_llm formats all descriptors as structured text for LLM context. write_thought checks gates before storing. Rejected writes attempt route_to_peer which tries all peers via IPC, creates auto-shard if none accept."

w "Query System" "query_thoughts searches both descriptions and content case-insensitive substring match. build_context includes all thoughts from shard, LLM filters at answer time. shard_ask builds context then calls llm_chat with system prompt constraining to context only. fleet_ask reads all peer binaries, builds context from each, asks LLM per shard, merges answers."

w "LLM Integration" "Config from env vars (LLM_URL, LLM_KEY, LLM_MODEL) or ~/.shards/_config.jsonc. llm_chat shells out to curl with 120s timeout. Builds OpenAI-compatible chat completion request. Parses choices[0].message.content from response. embed_text calls /embeddings endpoint for vector search."

w "Vector Search" "embed_text calls OpenAI-compatible /embeddings endpoint via curl using EMBED_MODEL. Vec_Entry stores thought_id, description, embedding. vec_index_thought auto-indexes on write. vec_search computes cosine similarity, returns top-k. In-memory only, lost on restart."

w "Configuration" "~/.shards/_config.jsonc with JSONC comment stripping. Fields: llm_url, llm_key, llm_model, embed_model, shard_key, idle_timeout_ms, http_port, max_thoughts, shard_dir. Env vars override config. strip_jsonc_comments handles // and /* */ comments inside and outside strings."

w "HTTP Server" "--http starts TCP server on PORT env (default from config). Raw posix sockets with SO_REUSEADDR. Routes: GET /info (metadata JSON), POST /query (keyword search), POST /write (create thought). JSON request/response. Manual HTTP parsing of first line for method and path."

w "Topic Cache" "In-memory map[string]string on State for short-term memory. MCP tools cache_set, cache_get, cache_delete, cache_list operate directly on state.topic_cache. Ephemeral, lost on process exit. Used by build_context to include active topics in LLM prompts."

w "Compact Operation" "--compact moves all unprocessed thoughts to processed block and persists via blob_write_self. Emits compact event to peers. No LLM involvement currently."

w "Event System" "Event_Kind enum: Write, Compact, Gate_Change. emit_event sends JSON to all peer shards via ipc_connect. Wired into write_thought and compact. Events are fire-and-forget, no acknowledgment."

w "Build and Test" "Docker-based. Dockerfile for unit tests (12 tests). scripts/Dockerfile.integration for integration tests (24 tests). scripts/stress_test.sh for 6-shard 30-thought cross-domain test. scripts/mcp_server.sh wraps Docker for MCP native integration. .mcp.json configures Claude Code MCP server."

w "Project File Structure" "shard.odin is everything. Dockerfile for unit tests. help/ has #load embedded text: help.txt, help.ai.txt, daemon.txt/ai, version.txt/ai, info.txt/ai, tools.json. scripts/ has test.sh, test_integration.sh, stress_test.sh, test_llm.sh, Dockerfile.integration, mcp_server.sh. docs/ has vision.md, todo.md. .temp/ gitignored for persistent test data and config."

w "Odin Language Conventions" "snake_case for procs and variables, Title_Case for types. -vet -strict-style enforced. mem.Arena for allocation: 64 MiB runtime arena, 1 MiB per-request arena. Error handling via multiple return values and or_return. No garbage collector. Explicit allocators via context. core:sys/posix for sockets."

w "Design Principles" "Clean code: no dead code, no comments, delete replaced functions. Routing before reading: gates checked before decrypting. Encryption by default. Single binary no deps. Linux only. Context is constructed not retrieved. If binary is lost, data is lost. No backup by design."

w "Catalog and Gates Types" "Catalog struct: name, purpose, tags []string, created. All JSON-tagged. Gates struct: gate string, gate_embedding []f64, descriptors []Descriptor, intake_prompt string, shard_links []string. Descriptor struct: format, match_rule, structure, links. Gates serialized as JSON, parsed back on read."

w "Memory Model" "Two-tier: Runtime allocator (64 MiB arena, process lifetime, global state) and Request allocator (1 MiB arena per IPC connection, freed on return). state is heap-allocated on runtime arena. topic_cache map uses runtime allocator. vec_index dynamic array uses runtime allocator."

w "MCP Tool List" "15 tools: shard_write, shard_read, shard_query, shard_ask (with shard param for peers), fleet_ask, shard_ingest, shard_info, shard_list, create_shard, build_context, cache_set, cache_get, cache_delete, cache_list, vec_search. All defined in help/tools.json and #loaded at compile time."

echo ""
echo "=== Done: 25 thoughts indexed ==="
