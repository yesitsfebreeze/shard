# Shard MCP Quick Reference

Use this file when testing MCP directly from this repository.

## Run MCP

```bash
HOME=/home/feb SHARD_KEY=<hex> ./mcp.sh
```

Send MCP JSON-RPC messages over stdio (`Content-Length` framing) to the process.

## Tool Argument Notes

The MCP tool schemas currently use these argument names:

- `shard_query`
  - `{"keyword": "<search term>", "shard": "<optional peer id>"}`
- `shard_read`
  - `{"id": "<32-char thought id>"}`
- `shard_write`
  - `{"description": "...", "content": "...", "agent": "optional", "shard": "optional"}`
- `shard_ask`
  - `{"question": "...", "shard": "optional peer id", "agent": "optional"}`
- `build_context`
  - `{"task": "...", "agent": "optional", "format": "optional: packet"}`
- `fleet_query`
  - `{"keyword": "..."}`
- `vec_search`
  - `{"query": "...", "top_k": 5}`
- `cache_set`
  - `{"key": "<cache key>", "value": "...", "author": "optional", "expires": "optional RFC3339"}`
- `cache_get`
  - `{"key": "<cache key>"}`
- `cache_delete`
  - `{"key": "<cache key>"}`
- `cache_list`
  - `{} (no args)`

## Example MCP Calls

1) Write

```json
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{
  "name":"shard_write",
  "arguments":{
    "description":"mcp context test",
    "content":"Context packet probe content",
    "agent":"probe-agent"
  }
}}
```

2) Query

```json
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{
  "name":"shard_query",
  "arguments":{"keyword":"Context packet"}
}}
```

3) Read

```json
{ "jsonrpc":"2.0", "id":3, "method":"tools/call", "params":{
  "name":"shard_read",
  "arguments":{"id":"<32-char thought id>"}
}}
```

4) Build context

```json
{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{
  "name":"build_context",
  "arguments":{"task":"evaluate MCP context usefulness"}
}}
```

## Why these names matter

- `cache_*` tools are for shared cache entries and are intentionally `key`/`value`, not `topic`/`content`.
- `shard_read` uses `id`, while write/query use `description`/`content` and `keyword`.
- `build_context` expects `task` and returns assembled context (`format: packet` for JSON output).

If you have been seeing `missing key` responses, confirm `SHARD_KEY` is set for the MCP subprocess.
