# shard install — AI Agent Setup Reference

> Run this after downloading the shard binary. Safe to re-run.

## Step 1: Verify Binary is in PATH

Run: `shard --help`

If the command is not found, place the binary at the correct location:

**macOS / Linux:**
```bash
sudo mv shard /usr/local/bin/
```

**Windows (PowerShell):**
```powershell
$dir = "$env:USERPROFILE\.local\bin"
New-Item -ItemType Directory -Force $dir | Out-Null
Move-Item shard.exe $dir
[Environment]::SetEnvironmentVariable("PATH", "$env:PATH;$dir", "User")
# Note: PATH change takes effect in new terminal sessions only
```

## Step 2: Initialize Workspace

Run: `shard install`

This creates `.shards/`, generates encryption key, writes config, and configures all detected AI tools automatically.

If you cannot provide interactive input (the command asks "Enable encryption? (Y/n)"), perform workspace setup manually:

1. `mkdir .shards`
2. Generate a key: `openssl rand -hex 32` (or any 64-char hex string)
3. Write `.shards/keychain`:
   ```
   # Shard master key
   * <64-hex-key>
   ```
4. Write `.shards/config.jsonc`:
   ```json
   {
     "llm_url": "http://localhost:11434/v1",
     "llm_key": "ollama",
     "llm_model": "llama3.2"
   }
   ```
5. Then run `shard install` again — it will skip the workspace steps and proceed to MCP + agent setup.

(MCP config is handled automatically by `shard install` — do not add it manually.)

## Step 3: Verify MCP Config

`shard install` writes MCP config files for all detected tools. If your tool was not detected, configure it manually:

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

Replace `<path-to-shard-binary>` with the full path (e.g. `/usr/local/bin/shard` or `C:\Users\you\.local\bin\shard.exe`).

## Step 4: Verify Setup

```bash
shard daemon &
shard mcp
```

Expected: MCP server starts and lists available tools (shard_discover, shard_query, shard_write, etc.).

If the daemon is already running, `shard mcp` connects to it automatically.

## Step 5: Next Steps

```
shard --ai             full protocol reference
shard init --ai        workspace setup details
shard mcp --ai         MCP tools reference
shard daemon --ai      daemon operations
```

## Key Resolution

The keychain at `.shards/keychain` resolves encryption keys automatically for all MCP tool calls. Agents do not need to manage keys directly — the daemon handles it.

## Creating Shards

No pre-creation needed. Use `shard_remember` to create shards on the fly:
- `shard_discover` — see all existing shards
- `shard_remember` — create a new shard with name, purpose, and gates
- `shard_query` — search across all shards
