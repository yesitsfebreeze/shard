# Shard — build recipes
# Requires: just (https://github.com/casey/just), odin (dev-2025-01+)

# Default recipe
default: build

# Standard debug build
build:
    odin build src/ -out:shard.exe

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
# Agent setup — .agent/ is the source of truth, tools symlink to it
# Read .agent/setup.md for full per-tool instructions
# =============================================================================

# Install for all supported tools
install:
    @ln -sf .agent/instructions.md CLAUDE.md
    @ln -sf .agent/instructions.md .cursorrules
    @ln -sf .agent/instructions.md .windsurfrules
    @mkdir -p .github
    @ln -sf ../.agent/instructions.md .github/copilot-instructions.md
    @echo "installed: CLAUDE.md .cursorrules .windsurfrules .github/copilot-instructions.md"
    @echo "NOTE: MCP configs are tool-specific. See .agent/setup.md"

# Uninstall generated tool configs
uninstall:
    @rm -f CLAUDE.md .cursorrules .windsurfrules opencode.json
    @rm -f .github/copilot-instructions.md
    @rm -f .mcp.json
    @rm -rf .cursor/mcp.json
    @echo "uninstalled all tool configs"
