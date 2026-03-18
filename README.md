# Shard

**Your second brain, encrypted on disk.**

Shard is a single executable that stores your thoughts in encrypted `.shard` files. You write to it, your AI writes to it, and everything stays local and private.

Each shard is a category — *notes*, *journal*, *recipes*, whatever you want. A daemon manages them all. AI agents use gates (accept/reject rules) to figure out where new thoughts belong, and when nothing fits, they create a new shard automatically.

---

## Install

### macOS
```bash
curl -fsSL https://github.com/yesitsfebreeze/shard/releases/latest/download/shard-macos-arm64.tar.gz | tar xz && sudo mv shard /usr/local/bin/
```

### Linux
```bash
curl -fsSL https://github.com/yesitsfebreeze/shard/releases/latest/download/shard-linux-amd64.tar.gz | tar xz && sudo mv shard /usr/local/bin/
```

### Windows (PowerShell)
```powershell
$dir = "$env:USERPROFILE\.local\bin"
New-Item -ItemType Directory -Force $dir | Out-Null
Invoke-WebRequest https://github.com/yesitsfebreeze/shard/releases/latest/download/shard-windows-amd64.zip -OutFile shard.zip
Expand-Archive shard.zip -DestinationPath $dir -Force
Remove-Item shard.zip
[Environment]::SetEnvironmentVariable("PATH", "$env:PATH;$dir", "User")
```

> **Note (Windows):** The PATH update takes effect in new terminal sessions. Restart your terminal after install.

<details>
<summary>Nightly builds (bleeding edge)</summary>

### macOS (nightly)
```bash
curl -fsSL https://github.com/yesitsfebreeze/shard/releases/download/main/shard-macos-arm64.tar.gz | tar xz && sudo mv shard /usr/local/bin/
```

### Linux (nightly)
```bash
curl -fsSL https://github.com/yesitsfebreeze/shard/releases/download/main/shard-linux-amd64.tar.gz | tar xz && sudo mv shard /usr/local/bin/
```

### Windows (nightly, PowerShell)
```powershell
$dir = "$env:USERPROFILE\.local\bin"
New-Item -ItemType Directory -Force $dir | Out-Null
Invoke-WebRequest https://github.com/yesitsfebreeze/shard/releases/download/main/shard-windows-amd64.zip -OutFile shard.zip
Expand-Archive shard.zip -DestinationPath $dir -Force
Remove-Item shard.zip
[Environment]::SetEnvironmentVariable("PATH", "$env:PATH;$dir", "User")
```

</details>

---

## AI Agent Setup

Once the binary is installed, tell your AI agent:

```
run `shard install --ai` and set me up
```

The binary contains everything your agent needs — setup instructions, MCP config, workspace init, and tool integration. No separate docs required.

---

## Get Started (human)

```bash
shard install     # initialize workspace + configure your AI tool
shard daemon &    # start the daemon
shard mcp         # start the MCP server (your AI tool connects here)
```

---

## Learn More

Everything is built into the binary:

```bash
shard --help                # command reference
shard install --ai     # full AI agent setup guide
shard --ai             # AI protocol reference
shard init --ai        # workspace setup details
shard mcp --ai         # MCP tools reference
```

---

## Configuration

Shard uses `.shards/config` for optional LLM integration (vector search, AI compaction):

```ini
[llm]
LLM_URL    = http://localhost:11434/v1   # OpenAI-compatible API base URL
LLM_KEY    = ollama                      # API key (any string for ollama)
LLM_MODEL  = llama3.2                    # model name (used for all LLM features)
```

Works with any OpenAI-compatible provider: ollama, OpenAI, Cohere, etc.

---

## Build from Source

Requires [Odin](https://odin-lang.org/) (dev-2026-02 or later) and [just](https://github.com/casey/just).

```bash
just test       # run all tests
just release    # size-optimized release
```
