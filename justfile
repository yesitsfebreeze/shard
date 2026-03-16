# Shard — build recipes
# Requires: just (https://github.com/casey/just), odin (dev-2025-01+)

# Default recipe
default: build

# Standard debug build
build:
    odin build src/ -out:shard

# Optimized release build (small binary)
release:
    odin build src/ -out:shard -o:size -no-bounds-check
    @echo "built: shard (release)"
    @ls -lh shard | awk '{print "size:", $5}'

# Optimized for speed
fast:
    odin build src/ -out:shard -o:speed
    @echo "built: shard (fast)"

# Run all tests
test:
    odin test src/

# Clean build artifacts
clean:
    rm -f shard shard.exe

# Start the daemon
daemon:
    ./shard daemon

# Start the MCP server (requires daemon running)
mcp:
    ./shard mcp

# =============================================================================
# Tool linking — CLAUDE.md is the master, other tools symlink to it
# =============================================================================

# Link OpenCode — generates opencode.json with MCP config
link-opencode:
    @echo '{"$$schema":"https://opencode.ai/config.json","mcp":{"shard":{"type":"local","command":["./shard","mcp"],"enabled":true}}}' | python3 -m json.tool > opencode.json
    @echo "linked: opencode.json"

# Link GitHub Copilot — symlinks instructions to CLAUDE.md
link-copilot:
    @mkdir -p .github
    @ln -sf ../CLAUDE.md .github/copilot-instructions.md
    @echo "linked: .github/copilot-instructions.md -> CLAUDE.md"

# Link Cursor — symlinks rules to CLAUDE.md
link-cursor:
    @ln -sf CLAUDE.md .cursorrules
    @echo "linked: .cursorrules -> CLAUDE.md"

# Link all supported tools
link-all: link-opencode link-copilot link-cursor
    @echo "all tools linked to CLAUDE.md"

# Unlink all tool configs
unlink-all:
    @rm -f opencode.json .cursorrules
    @rm -rf .github/copilot-instructions.md
    @echo "all tool links removed"
