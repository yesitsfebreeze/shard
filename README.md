# Shard

**Your second brain, encrypted on disk.**

Shard is a single executable that stores your thoughts in encrypted `.shard` files. You write to it, your AI writes to it, and everything stays local and private.

Each shard is a category — *notes*, *journal*, *recipes*, whatever you want. A daemon manages them all. AI agents use gates (accept/reject rules) to figure out where new thoughts belong, and when nothing fits, they create a new shard automatically.

---

## Install

### macOS / Linux
```bash
curl -fsSL https://raw.githubusercontent.com/yesitsfebreeze/shard/main/install.sh | sh
```

### Windows (PowerShell)
```powershell
irm https://raw.githubusercontent.com/yesitsfebreeze/shard/main/install.ps1 | iex
```

Auto-detects your OS and architecture. Installs the latest stable release, falls back to nightly if no stable release exists.

<details>
<summary>Options</summary>

Pin a specific version:
```bash
SHARD_VERSION=v0.1.0 curl -fsSL https://raw.githubusercontent.com/yesitsfebreeze/shard/main/install.sh | sh
```

Custom install directory:
```bash
SHARD_INSTALL_DIR=~/.local/bin curl -fsSL https://raw.githubusercontent.com/yesitsfebreeze/shard/main/install.sh | sh
```

Supported platforms: `linux-amd64`, `linux-arm64`, `macos-amd64`, `macos-arm64`, `windows-amd64`

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
shard install   # initialize workspace + configure your AI tool
shard daemon &  # start the daemon
shard mcp       # start the MCP server (your AI tool connects here)
```

---

## Learn More

Everything is built into the binary:

```bash
shard --help        # command reference
shard install --ai  # full AI agent setup guide
shard --ai          # AI protocol reference
shard init --ai     # workspace setup details
shard mcp --ai      # MCP tools reference
```

---

## Configuration

Shard uses `.shards/config.jsonc` for optional LLM integration (vector search, AI compaction):

```json
{
  "llm_url": "http://localhost:11434/v1",
  "llm_key": "ollama",
  "llm_model": "llama3.2"
}
```

Works with any OpenAI-compatible provider: ollama, OpenAI, Cohere, etc.

---

## Build from Source

Requires [Odin](https://odin-lang.org/) (dev-2026-02 or later) and [just](https://github.com/casey/just).

```bash
just test       # run all tests
just release    # size-optimized release
```
