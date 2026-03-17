package shard

import "core:fmt"

// =============================================================================
// Help — compile-time embedded text from src/help/*.txt and src/help/ai/*.md
// =============================================================================

// Human-readable help
@(private) HELP_OVERVIEW :: string(#load("help/overview.txt"))
@(private) HELP_INIT     :: string(#load("help/init.txt"))
@(private) HELP_SHARD    :: string(#load("help/shard.txt"))
@(private) HELP_DAEMON   :: string(#load("help/daemon.txt"))
@(private) HELP_NEW      :: string(#load("help/new.txt"))
@(private) HELP_CONNECT  :: string(#load("help/connect.txt"))
@(private) HELP_MCP      :: string(#load("help/mcp.txt"))
@(private) HELP_INSTALL  :: string(#load("help/install.txt"))

// AI reference help
@(private) HELP_AI_OVERVIEW :: string(#load("help/ai/overview.md"))
@(private) HELP_AI_INIT     :: string(#load("help/ai/init.md"))
@(private) HELP_AI_DAEMON   :: string(#load("help/ai/daemon.md"))
@(private) HELP_AI_CONNECT :: string(#load("help/ai/connect.md"))
@(private) HELP_AI_MCP      :: string(#load("help/ai/mcp.md"))
@(private) HELP_AI_SHARD   :: string(#load("help/ai/shard.md"))
@(private) HELP_AI_NEW     :: string(#load("help/ai/new.md"))
@(private) HELP_AI_INSTALL :: string(#load("help/ai/install.md"))

@(private)
_print_help :: proc(text: string) {
	fmt.print(text)
}
