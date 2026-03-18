package shard

import "core:os"

import logger "logger"

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

	logger.info("")
	logger.info("=== Workspace ready ===")
	logger.info("")
	logger.info("Run \"shard install\" to configure your AI tool (MCP + agent setup).")
	logger.info("Or run \"shard daemon &\" and \"shard mcp\" to start manually.")
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

	logger.info("")
	logger.info("=== Workspace ready ===")
	logger.info("")
	logger.info("For AI agent setup, run:")
	logger.info("  shard install --ai")
}
