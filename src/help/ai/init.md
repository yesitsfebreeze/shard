# shard init — AI Agent Setup Reference

## When to Use

Run `shard init` when the workspace has not been initialized yet (no `.shards/` directory).

## What It Does

1. Creates `.shards/` directory
2. Generates `.shards/config` with defaults
3. Asks about encryption:
   - If enabled: generates 64-hex master key, writes `.shards/keychain` with `* <key>`
   - If disabled: skips key generation (thoughts stored plaintext)
4. Prints MCP config JSON for AI client setup

## For AI Agents

If you cannot provide interactive input (the init command asks "Enable encryption? (Y/n)"), perform setup manually:

1. `mkdir .shards`
2. Generate a key: `openssl rand -hex 32` (or any 64-char hex string)
3. Write `.shards/keychain`:
   ```
   # Shard master key
   * <64-hex-key>
   ```
4. Write `.shards/config`:
   ```
   [daemon]
   ipc = "shard-daemon"
   
   [llm]
   # Optional: LLM_URL and LLM_MODEL for vector search and AI features
   ```
5. Configure MCP in your AI client:
   ```json
   {
     "mcpServers": {
       "shard": {
         "type": "stdio",
         "command": "<path-to-shard-binary>",
         "args": ["mcp"]
       }
     }
   }
   ```

## Key Resolution

After setup, the keychain automatically resolves keys for all MCP tool calls. The daemon starts automatically when `shard mcp` runs. Agents create shards on-the-fly with `shard_remember` — no pre-creation needed.