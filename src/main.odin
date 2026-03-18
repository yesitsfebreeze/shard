package shard

import "core:crypto"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

import logger "logger"

// =============================================================================
// Entry point
// =============================================================================
//
// Usage:
//   shard new                                 Create a new shard (interactive wizard)
//   shard daemon [--data <path>]              Start the daemon
//   shard --name <n> --key <hex> [options]    Start a shard node
//
// Daemon mode:
//   Fixed IPC endpoint (shard-daemon). Tracks all shard processes.
//   No key needed — the daemon stores registry metadata, not secrets.
//   Default data: daemon.shard
//
// Shard mode:
//   --name    Node name (IPC endpoint). Default: default
//   --key     Master key (64 hex chars). Also reads SHARD_KEY env var
//   --data    Path to .shard file. Default: <name>.shard
//   --timeout Idle seconds before auto-exit. 0 = never. Default: 300

DEFAULT_TIMEOUT :: 300 // 5 minutes

main :: proc() {
	// Initialize logger and tracking allocator
	track_alloc := logger.init_tracking_allocator()
	context.allocator = track_alloc
	context.logger = logger.init()
	defer {
		logger.shutdown()
		logger.cleanup_tracking_allocator()
	}

	if len(os.args) > 1 {
		switch os.args[1] {
		case "init":
			_run_init()
			return
		case "install":
			_run_install()
			return
		case "daemon":
			_run_daemon()
			return
		case "new":
			_run_new()
			return
		case "connect":
			_run_connect()
			return
		case "mcp":
			run_mcp()
			return
		case "vault":
			_run_vault()
			return
		case "--help", "-h":
			_print_help(HELP_OVERVIEW)
			return
		case "--ai":
			_print_help(HELP_AI_OVERVIEW)
			return
		}
	}

	if len(os.args) <= 1 {
		_print_help(HELP_OVERVIEW)
		return
	}

	_run_shard()
}

// =============================================================================
// Help system
// =============================================================================

@(private)
_print_help_overview :: proc() {
	_print_help(HELP_OVERVIEW)
}

@(private)
_run_daemon :: proc() {
	data_path: string = ".shards/daemon.shard"

	args := os.args[2:]
	for i := 0; i < len(args); i += 1 {
		if args[i] == "--data" && i + 1 < len(args) {
			i += 1; data_path = args[i]
		} else if args[i] == "--help" || args[i] == "-h" {
			_print_help(HELP_DAEMON)
			return
		} else if args[i] == "--ai" {
			_print_help(HELP_AI_DAEMON)
			return
		}
	}

	// Load config early so logger can be configured with the correct level, file,
	// and format before any further work. node_init will see it as already loaded.
	cfg := config_load()
	logger.configure(cfg.log_level, cfg.log_file, cfg.log_format)
	context.logger = logger.get_logger()

	logger.infof("starting daemon with data path: %s", data_path)

	master: Master_Key // zero key — daemon doesn't encrypt its own blob
	node, ok := node_init(DAEMON_NAME, master, data_path, 0, is_daemon = true)
	if !ok {
		logger.err("failed to initialize daemon node")
		os.exit(1)
	}

	logger.info("daemon initialized, starting event loop")
	node_run(&node)
	node_shutdown(&node)
}

@(private)
_run_shard :: proc() {
	name: string
	key_hex: string
	data_path: string
	timeout_sec: int = DEFAULT_TIMEOUT

	args := os.args[1:]
	for i := 0; i < len(args); i += 1 {
		if args[i] == "--name" && i + 1 < len(args) {
			i += 1; name = args[i]
		} else if args[i] == "--key" && i + 1 < len(args) {
			i += 1; key_hex = args[i]
		} else if args[i] == "--data" && i + 1 < len(args) {
			i += 1; data_path = args[i]
		} else if args[i] == "--timeout" && i + 1 < len(args) {
			i += 1
			val, ok := strconv.parse_int(args[i])
			if ok do timeout_sec = val
		} else if args[i] == "--help" || args[i] == "-h" {
			_print_help(HELP_SHARD)
			return
		} else if args[i] == "--ai" {
			_print_help(HELP_AI_SHARD)
			return
		}
	}

	if name == "" do name = "default"
	if data_path == "" do data_path = fmt.tprintf(".shards/%s.shard", name)

	if key_hex == "" {
		if env_key, env_ok := os.lookup_env("SHARD_KEY"); env_ok {
			key_hex = env_key
		}
	}

	master: Master_Key
	if key_hex != "" {
		k, ok := hex_to_key(key_hex)
		if !ok {
			logger.err("error: key must be exactly 64 hex characters (32 bytes)")
			os.exit(1)
		}
		master = k
	}

	idle_timeout: time.Duration
	if timeout_sec > 0 {
		idle_timeout = time.Duration(timeout_sec) * time.Second
	}

	node, ok := node_init(name, master, data_path, idle_timeout)
	if !ok {
		os.exit(1)
	}

	node_run(&node)
	node_shutdown(&node)
}

// =============================================================================
// shard init — bootstrap a new shard workspace (shared helper)
// =============================================================================

@(private)
_workspace_init :: proc() -> (key_hex: string) {
	logger.info("=== Shard workspace setup ===")
	logger.info("")

	already_exists := os.exists(".shards")
	if already_exists {
		logger.info(".shards/ directory already exists — will skip existing files.")
	} else {
		os.make_directory(".shards")
		logger.info("Created .shards/")
	}

	if os.exists(CONFIG_PATH) {
		logger.infof("  %s already exists — skipping.", CONFIG_PATH)
	} else {
		s := DEFAULT_CONFIG_FILE
		if os.write_entire_file(CONFIG_PATH, s) {
			logger.infof("  Created %s", CONFIG_PATH)
		} else {
			logger.errf("  warning: could not write %s", CONFIG_PATH)
		}
	}

	if os.exists(KEYCHAIN_PATH) {
		logger.infof("  %s already exists — skipping key setup.", KEYCHAIN_PATH)
	} else {
		logger.info("")
		logger.info("Encryption protects your thoughts at rest with ChaCha20-Poly1305.")
		logger.info("A single master key is used for all shards in this workspace.")
		logger.info("")
		choice := _prompt("Enable encryption? (Y/n): ")

		if choice == "n" || choice == "N" {
			logger.info("")
			logger.info("Encryption disabled. Thoughts will be stored in plaintext.")
			logger.info("You can enable encryption later by creating .shards/keychain manually.")
		} else {
			master: Master_Key
			crypto.rand_bytes(master[:])
			hex_out := hex.encode(master[:], context.temp_allocator)
			key_hex = strings.clone(string(hex_out))

			kc_content := fmt.tprintf(
				"# Shard master key — applies to all shards in this workspace\n# DO NOT share this file. If you lose this key, encrypted thoughts are unrecoverable.\n* %s\n",
				key_hex,
			)
			if os.write_entire_file(KEYCHAIN_PATH, transmute([]u8)kc_content) {
				logger.info("")
				logger.info("Generated master key and saved to .shards/keychain")
				logger.info("")
				logger.infof("  KEY: %s", key_hex)
				logger.info("")
				logger.info("  This is a one-time secret. Back it up somewhere safe.")
				logger.info("  If you lose this key, your encrypted thoughts cannot be recovered.")
			} else {
				logger.errf("  warning: could not write %s", KEYCHAIN_PATH)
			}
		}
	}
	return key_hex
}
