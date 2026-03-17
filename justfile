# Shard — build recipes
# Requires: just (https://github.com/casey/just), odin (dev-2025-01+)

# Default recipe
default: build

# Standard debug build
build:
    @if [ "$OS" = "Windows_NT" ]; then \
        taskkill //IM shard.exe //F 2>nul || true; \
        odin build src/ -out:shard.exe; \
        echo "built: shard.exe"; \
    else \
        rm -f shard; \
        odin build src/ -out:shard; \
        echo "built: shard"; \
    fi

# Optimized release build (small binary)
release:
    @if [ "$OS" = "Windows_NT" ]; then \
        odin build src/ -out:shard_tmp.exe -o:size -no-bounds-check; \
        echo "built: shard_tmp.exe (release)"; \
        ls -lh shard_tmp.exe | awk '{print "size:", $5}'; \
        echo "compressing with upx..."; \
        upx --best --lzma -f -o shard.exe shard_tmp.exe; \
        rm shard_tmp.exe; \
        echo "compressed size:"; \
        ls -lh shard.exe | awk '{print "size:", $5}'; \
    else \
        odin build src/ -out:shard -o:size -no-bounds-check; \
        echo "built: shard (release)"; \
        ls -lh shard | awk '{print "size:", $5}'; \
        echo "compressing with upx..."; \
        upx --best --lzma -f -o shard_tmp shard; \
        rm shard; \
        mv shard_tmp shard; \
        echo "compressed size:"; \
        ls -lh shard | awk '{print "size:", $5}'; \
    fi

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
