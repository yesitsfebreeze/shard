package shard

import "core:os"

// =============================================================================
// shard init — bootstrap a new shard workspace
// =============================================================================

@(private)
_run_init :: proc() {
	for arg in os.args[2:] {
		if arg == "--help" || arg == "-h" {
			_print_help(HELP_INIT)
			return
		} else if arg == "--ai" {
			_print_help(HELP_AI_INIT)
			return
		}
	}

	key_hex := _workspace_init()
	defer if key_hex != "" {delete(key_hex)}

	info("")
	info("=== Workspace ready ===")
	info("")
	info("Run \"shard install\" to configure your AI tool (MCP + agent setup).")
	info("Or run \"shard daemon &\" and \"shard mcp\" to start manually.")
}

// =============================================================================
// shard install — workspace init + AI agent setup reference
// =============================================================================

@(private)
_run_install :: proc() {
	for arg in os.args[2:] {
		if arg == "--help" || arg == "-h" {
			_print_help(HELP_INSTALL)
			return
		} else if arg == "--ai" {
			_print_help(HELP_AI_INSTALL)
			return
		}
	}

	// Human-facing: same as init (workspace setup)
	key_hex := _workspace_init()
	defer if key_hex != "" {delete(key_hex)}

	info("")
	info("=== Workspace ready ===")
	info("")
	info("For AI agent setup, run:")
	info("  shard install --ai")
}
