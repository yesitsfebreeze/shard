# CLAUDE.md

Run `docker build -t shard . && docker run --rm shard --help --ai` for full documentation.

## Quick Start

```bash
docker build -t shard .
docker run --rm shard --help --ai    # full AI documentation
docker run -p 8080:8080 shard        # run daemon + HTTP
```

## Architecture

**Everything is one binary: `shard.odin`.**

The binary is self-contained: daemon, HTTP server, MCP server, IPC, and fleet coordination are all compiled into a single Linux ELF.

### Binary Layout

```
[ ELF code ] [ shard data ] [ SHA-256 hash ] [ magic footer ]
```

The binary appends its own data after the ELF code on first run (`blob_write_self`). On subsequent runs it reads the footer magic (`SHARD_MAGIC`), verifies the SHA-256 hash, and parses the appended data back into memory (`blob_read`). This is how each shard carries its own knowledge — the binary *is* the shard.

### What runs inside the binary

- **Daemon** (`daemon_run`): IPC listener, routes thoughts, spawns fleet peers
- **HTTP** (`http_run`): port 8080, REST API
- **MCP** (`mcp_run`): stdio-based MCP server for AI tool calls

### Fleet

A fleet is a set of shards. Each shard binary spawns from a copy of itself (`create_shard` writes `state.blob.exe_code` to a new path, then initializes it with `shard_init`). The fleet shares no external infrastructure — peer discovery is via a shared index directory.

## Rules

Single file `shard.odin`. No unneeded comments. No dead code.
