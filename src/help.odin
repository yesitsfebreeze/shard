package shard

import "core:fmt"

// =============================================================================
// Help — compile-time embedded text from src/help/*.txt
// =============================================================================

@(private) HELP_OVERVIEW :: string(#load("help/overview.txt"))
@(private) HELP_SHARD    :: string(#load("help/shard.txt"))
@(private) HELP_DAEMON   :: string(#load("help/daemon.txt"))
@(private) HELP_NEW      :: string(#load("help/new.txt"))
@(private) HELP_CONNECT  :: string(#load("help/connect.txt"))
@(private) HELP_MCP      :: string(#load("help/mcp.txt"))
@(private) HELP_COMPRESS :: string(#load("help/compress.txt"))
@(private) HELP_AI       :: string(#load("help/ai_help.md"))

@(private)
_print_help :: proc(text: string) {
	fmt.print(text)
}
