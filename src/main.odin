package shard

import "core:crypto"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

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
//

DEFAULT_TIMEOUT :: 300 // 5 minutes

main :: proc() {
	if len(os.args) > 1 {
		switch os.args[1] {
		case "init":
			_run_init()
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
		case "dump":
			_run_dump()
			return
		case "--help", "-h":
			_print_help(HELP_OVERVIEW)
			return
		case "--ai-help":
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
		} else if args[i] == "--ai-help" {
			_print_help(HELP_AI_DAEMON)
			return
		}
	}

	master: Master_Key // zero key — daemon doesn't encrypt its own blob
	node, ok := node_init(DAEMON_NAME, master, data_path, 0, is_daemon = true)
	if !ok {
		os.exit(1)
	}

	node_run(&node)
	node_shutdown(&node)
}

@(private)
_run_shard :: proc() {
	name:        string
	key_hex:     string
	data_path:   string
	dump_path:   string
	timeout_sec: int = DEFAULT_TIMEOUT

	args := os.args[1:]
	for i := 0; i < len(args); i += 1 {
		if args[i] == "--name" && i + 1 < len(args) {
			i += 1; name = args[i]
		} else if args[i] == "--key" && i + 1 < len(args) {
			i += 1; key_hex = args[i]
		} else if args[i] == "--data" && i + 1 < len(args) {
			i += 1; data_path = args[i]
		} else if args[i] == "--dump" {
			if i + 1 < len(args) && len(args[i+1]) > 0 && args[i+1][0] != '-' {
				i += 1; dump_path = args[i]
			} else {
				dump_path = "markdown"
			}
		} else if args[i] == "--timeout" && i + 1 < len(args) {
			i += 1
			val, ok := strconv.parse_int(args[i])
			if ok do timeout_sec = val
		} else if args[i] == "--help" || args[i] == "-h" {
			_print_help(HELP_SHARD)
			return
		} else if args[i] == "--ai-help" {
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
			fmt.eprintln("error: key must be exactly 64 hex characters (32 bytes)")
			os.exit(1)
		}
		master = k
	}

	// --dump: export shard as markdown file and exit (no server)
	if dump_path != "" {
		if key_hex == "" {
			fmt.eprintln("error: --key is required for dump (thoughts are encrypted)")
			os.exit(1)
		}
		blob, blob_ok := blob_load(data_path, master)
		if !blob_ok {
			fmt.eprintfln("error: could not load shard file: %s", data_path)
			os.exit(1)
		}

		// Build a temporary node just for the dump op
		dump_node := Node{
			name = name,
			blob = blob,
		}
		md_content := _op_dump(&dump_node, context.allocator)

		// Strip the YAML frontmatter status field — rewrite it as a proper file
		// Actually, _op_dump returns a full markdown doc with frontmatter, keep as-is
		// Just remove the "status: ok\n" line since it's an IPC artifact
		md_content, _ = strings.replace(md_content, "status: ok\n", "", 1)

		os.make_directory(dump_path)
		out_path := fmt.tprintf("%s/%s.md", dump_path, name)
		write_ok := os.write_entire_file(out_path, transmute([]u8)md_content)
		if !write_ok {
			fmt.eprintfln("error: could not write %s", out_path)
			os.exit(1)
		}
		fmt.printfln("exported: %s", out_path)
		return
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
// shard init — bootstrap a new shard workspace
// =============================================================================

@(private)
_run_init :: proc() {
	for arg in os.args[2:] {
		if arg == "--help" || arg == "-h" {
			_print_help(HELP_INIT)
			return
		} else if arg == "--ai-help" {
			_print_help(HELP_AI_INIT)
			return
		}
	}

	fmt.println("=== Shard workspace setup ===")
	fmt.println()

	// 1. Create .shards/ directory
	already_exists := os.exists(".shards")
	if already_exists {
		fmt.println(".shards/ directory already exists — will skip existing files.")
	} else {
		os.make_directory(".shards")
		fmt.println("Created .shards/")
	}

	// 2. Config — generate if missing
	if os.exists(CONFIG_PATH) {
		fmt.printfln("  %s already exists — skipping.", CONFIG_PATH)
	} else {
		s := DEFAULT_CONFIG_FILE
		if os.write_entire_file(CONFIG_PATH, transmute([]u8)s) {
			fmt.printfln("  Created %s", CONFIG_PATH)
		} else {
			fmt.eprintfln("  warning: could not write %s", CONFIG_PATH)
		}
	}

	// 3. Encryption — ask user
	key_hex: string
	if os.exists(KEYCHAIN_PATH) {
		fmt.printfln("  %s already exists — skipping key setup.", KEYCHAIN_PATH)
	} else {
		fmt.println()
		fmt.println("Encryption protects your thoughts at rest with ChaCha20-Poly1305.")
		fmt.println("A single master key is used for all shards in this workspace.")
		fmt.println()
		choice := _prompt("Enable encryption? (Y/n): ")

		if choice == "n" || choice == "N" {
			fmt.println()
			fmt.println("Encryption disabled. Thoughts will be stored in plaintext.")
			fmt.println("You can enable encryption later by creating .shards/keychain manually.")
		} else {
			// Generate key
			master: Master_Key
			crypto.rand_bytes(master[:])
			hex_out := hex.encode(master[:], context.temp_allocator)
			key_hex = string(hex_out)

			// Write keychain with wildcard entry
			kc_content := fmt.tprintf("# Shard master key — applies to all shards in this workspace\n# DO NOT share this file. If you lose this key, encrypted thoughts are unrecoverable.\n* %s\n", key_hex)
			if os.write_entire_file(KEYCHAIN_PATH, transmute([]u8)kc_content) {
				fmt.println()
				fmt.println("Generated master key and saved to .shards/keychain")
				fmt.println()
				fmt.printfln("  KEY: %s", key_hex)
				fmt.println()
				fmt.println("  This is a one-time secret. Back it up somewhere safe.")
				fmt.println("  If you lose this key, your encrypted thoughts cannot be recovered.")
			} else {
				fmt.eprintfln("  warning: could not write %s", KEYCHAIN_PATH)
			}
		}
	}

	// 4. Print MCP config
	exe_path := os.args[0]
	// Normalize backslashes to forward slashes for JSON, then escape for display
	exe_json, _ := strings.replace_all(exe_path, `\`, `\\`)

	fmt.println()
	fmt.println("=== Setup complete ===")
	fmt.println()
	fmt.println("Add this to your MCP client config (Claude, Cursor, OpenCode, etc.):")
	fmt.println()
	fmt.printfln(`  {`)
	fmt.printfln(`    "mcpServers": {`)
	fmt.printfln(`      "shard": {`)
	fmt.printfln(`        "type": "stdio",`)
	fmt.printfln(`        "command": "%s",`, exe_json)
	fmt.printfln(`        "args": ["mcp"]`)
	fmt.printfln(`      }`)
	fmt.printfln(`    }`)
	fmt.printfln(`  }`)
	fmt.println()
	fmt.println("The daemon starts automatically when the MCP server connects.")
	fmt.println("Agents can create shards on the fly with shard_remember — no manual setup needed.")
	if key_hex != "" {
		fmt.println("Encryption is handled automatically via .shards/keychain.")
	}
	fmt.println()
	fmt.println("For AI agents: run \"shard --ai-help\" for the complete operation reference.")
}

// =============================================================================
// shard new — interactive wizard to create a new shard with catalog
// =============================================================================

@(private)
_run_new :: proc() {
	// Check for --help
	for arg in os.args[2:] {
		if arg == "--help" || arg == "-h" {
			_print_help(HELP_NEW)
			return
		} else if arg == "--ai-help" {
			_print_help(HELP_AI_NEW)
			return
		}
	}

	fmt.println("=== Create new shard ===")
	fmt.println()

	// 1. Name (required)
	name := _prompt("Shard name (required): ")
	if name == "" {
		fmt.eprintln("error: name is required")
		os.exit(1)
	}

	// 2. Purpose
	purpose := _prompt("Purpose (what this shard is for): ")

	// 3. Tags (comma-separated)
	tags_raw := _prompt("Tags (comma-separated, e.g. \"code,notes,research\"): ")
	tags: [dynamic]string
	if tags_raw != "" {
		for part in strings.split(tags_raw, ",", context.temp_allocator) {
			trimmed := strings.trim_space(part)
			if trimmed != "" do append(&tags, strings.clone(trimmed))
		}
	}

	// 4. Related shards (comma-separated)
	related_raw := _prompt("Related shards (comma-separated names): ")
	related: [dynamic]string
	if related_raw != "" {
		for part in strings.split(related_raw, ",", context.temp_allocator) {
			trimmed := strings.trim_space(part)
			if trimmed != "" do append(&related, strings.clone(trimmed))
		}
	}

	// 5. Master key — generate or provide
	key_hex := _prompt("Master key (64 hex chars, or press Enter to generate one): ")
	master: Master_Key

	if key_hex == "" {
		// Generate a random 32-byte key
		crypto.rand_bytes(master[:])
		hex_out := hex.encode(master[:], context.temp_allocator)
		fmt.printfln("\nGenerated key: %s", string(hex_out))
		fmt.println("Save this key — you need it to read/write thoughts in this shard.")
	} else {
		k, ok := hex_to_key(key_hex)
		if !ok {
			fmt.eprintln("error: key must be exactly 64 hex characters (32 bytes)")
			os.exit(1)
		}
		master = k
	}

	// 6. Data path — store under .shards/
	data_path := fmt.tprintf(".shards/%s.shard", name)
	os.make_directory(".shards")

	// Check if file already exists
	if os.exists(data_path) {
		overwrite := _prompt(fmt.tprintf("File '%s' already exists. Overwrite? (y/N): ", data_path))
		if overwrite != "y" && overwrite != "Y" {
			fmt.println("Aborted.")
			return
		}
	}

	// Build the blob with catalog
	blob, ok := blob_load(data_path, master)
	if !ok {
		fmt.eprintln("error: could not initialize shard file")
		os.exit(1)
	}

	blob.catalog = Catalog{
		name    = strings.clone(name),
		purpose = strings.clone(purpose),
		tags    = tags[:],
		related = related[:],
		created = _format_time(time.now()),
	}

	if !blob_flush(&blob) {
		fmt.eprintln("error: could not write shard file")
		os.exit(1)
	}

	fmt.println()
	fmt.printfln("Created '%s'", data_path)
	fmt.printfln("  Name:    %s", name)
	if purpose != "" do fmt.printfln("  Purpose: %s", purpose)
	if len(tags) > 0 do fmt.printfln("  Tags:    %s", strings.join(tags[:], ", "))
	if len(related) > 0 do fmt.printfln("  Related: %s", strings.join(related[:], ", "))

	// Notify daemon to re-scan (fails silently if daemon isn't running)
	_notify_daemon_discover()
}

// =============================================================================
// shard connect — session client, streams ops from stdin over IPC
// =============================================================================

@(private)
_run_connect :: proc() {
	name := "daemon"

	args := os.args[2:]
	for i := 0; i < len(args); i += 1 {
		if args[i] == "--help" || args[i] == "-h" {
			_print_help(HELP_CONNECT)
			return
		} else if args[i] == "--ai-help" {
			_print_help(HELP_AI_CONNECT)
			return
		} else {
			name = args[i]
		}
	}

	conn, ok := ipc_connect(name)
	if !ok {
		fmt.eprintfln("could not connect to '%s' (is the daemon running? try: shard daemon)", name)
		os.exit(1)
	}
	defer ipc_close_conn(conn)

	// State machine for parsing YAML frontmatter messages from stdin
	Connect_State :: enum { Waiting, In_Front, In_Body }

	buf: [65536]u8
	state := Connect_State.Waiting
	msg_builder := strings.builder_make()
	defer strings.builder_destroy(&msg_builder)

	flush_msg :: proc(conn: IPC_Conn, b: ^strings.Builder) -> bool {
		msg := strings.to_string(b^)
		if strings.trim_space(msg) == "" {
			strings.builder_reset(b)
			return true
		}
		data := transmute([]u8)msg
		if !ipc_send_msg(conn, data) {
			fmt.eprintln("send failed — connection lost")
			return false
		}
		resp, recv_ok := ipc_recv_msg(conn)
		if !recv_ok {
			fmt.eprintln("recv failed — connection lost")
			return false
		}
		fmt.print(string(resp))
		resp_str := string(resp)
		if len(resp_str) > 0 && resp_str[len(resp_str)-1] != '\n' {
			fmt.println()
		}
		delete(resp)
		strings.builder_reset(b)
		return true
	}

	for {
		n, err := os.read(os.stdin, buf[:])
		if err != nil || n <= 0 do break

		chunk := string(buf[:n])
		lines := strings.split(chunk, "\n", context.temp_allocator)

		for line in lines {
			trimmed := strings.trim_right(line, "\r")

			switch state {
			case .Waiting:
				if strings.trim_space(trimmed) == "---" {
					strings.write_string(&msg_builder, "---\n")
					state = .In_Front
				}
			case .In_Front:
				if strings.trim_space(trimmed) == "---" {
					strings.write_string(&msg_builder, "---\n")
					state = .In_Body
				} else {
					strings.write_string(&msg_builder, trimmed)
					strings.write_string(&msg_builder, "\n")
				}
			case .In_Body:
				if strings.trim_space(trimmed) == "---" {
					if !flush_msg(conn, &msg_builder) do return
					strings.write_string(&msg_builder, "---\n")
					state = .In_Front
				} else {
					strings.write_string(&msg_builder, trimmed)
					strings.write_string(&msg_builder, "\n")
				}
			}
		}
	}

	// EOF — flush any pending message
	if state == .In_Body {
		flush_msg(conn, &msg_builder)
	}
}

// _notify_daemon_discover tells a running daemon to re-scan .shards/.
// Fails silently if the daemon isn't running.
@(private)
_notify_daemon_discover :: proc() {
	conn, ok := ipc_connect(DAEMON_NAME)
	if !ok do return
	defer ipc_close_conn(conn)

	msg := "---\nop: discover\n---\n"
	if !ipc_send_msg(conn, transmute([]u8)msg) do return

	// Read and discard response
	resp, _ := ipc_recv_msg(conn, context.temp_allocator)
	delete(resp, context.temp_allocator)

	fmt.eprintln("Daemon notified — shard is now discoverable.")
}

// _prompt prints a prompt and reads a line from stdin.
@(private)
_prompt :: proc(prompt: string) -> string {
	fmt.print(prompt)
	buf: [4096]u8
	n, err := os.read(os.stdin, buf[:])
	if err != nil || n <= 0 do return ""
	// Strip trailing newline / carriage return
	line := string(buf[:n])
	line = strings.trim_right(line, "\r\n")
	return strings.clone(line)
}

// =============================================================================
// shard dump — export all shards as Obsidian markdown
// =============================================================================

@(private)
_run_dump :: proc() {
	out_path := "markdown"
	key_hex:   string

	args := os.args[2:]
	for i := 0; i < len(args); i += 1 {
		if args[i] == "--key" && i + 1 < len(args) {
			i += 1; key_hex = args[i]
		} else if args[i] == "--help" || args[i] == "-h" {
			fmt.println("Usage: shard dump [path] [--key <hex>]")
			fmt.println()
			fmt.println("Export all shards as Obsidian markdown files.")
			fmt.println("Keys are resolved per-shard from: --key flag, SHARD_KEY env, or .shards/keychain.")
			fmt.println("Default output path: markdown/")
			return
		} else if len(args[i]) > 0 && args[i][0] != '-' {
			out_path = args[i]
		}
	}

	if key_hex == "" {
		if env_key, env_ok := os.lookup_env("SHARD_KEY"); env_ok {
			key_hex = env_key
		}
	}

	keychain, kc_ok := keychain_load(context.temp_allocator)

	dir_handle, dir_err := os.open(".shards")
	if dir_err != nil {
		fmt.eprintln("error: could not open .shards/ directory")
		os.exit(1)
	}
	defer os.close(dir_handle)

	entries, read_err := os.read_dir(dir_handle, 0)
	if read_err != nil {
		fmt.eprintln("error: could not read .shards/ directory")
		os.exit(1)
	}

	os.make_directory(out_path)

	exported := 0
	skipped  := 0
	errors   := 0

	for entry in entries {
		if !strings.has_suffix(entry.name, ".shard") do continue
		if entry.name == "daemon.shard" do continue

		shard_name := entry.name[:len(entry.name) - 6] // strip ".shard"
		shard_path := fmt.tprintf(".shards/%s", entry.name)

		resolved_key := key_hex
		if resolved_key == "" && kc_ok {
			if kc_key, found := keychain_lookup(keychain, shard_name); found {
				resolved_key = kc_key
			}
		}

		master: Master_Key
		have_key := false
		if k, ok := hex_to_key(resolved_key); ok {
			master = k
			have_key = true
		}

		blob, blob_ok := blob_load(shard_path, master)
		if !blob_ok {
			fmt.printfln("  FAIL  %s (could not load)", entry.name)
			errors += 1
			continue
		}

		total_thoughts := len(blob.processed) + len(blob.unprocessed)
		if total_thoughts > 0 && !have_key {
			fmt.printfln("  SKIP  %s (%d thoughts, no key)", shard_name, total_thoughts)
			skipped += 1
			continue
		}

		dump_node := Node{
			name = shard_name,
			blob = blob,
		}
		md_content := _op_dump(&dump_node, context.allocator)
		md_content, _ = strings.replace(md_content, "status: ok\n", "", 1)

		file_path := fmt.tprintf("%s/%s.md", out_path, shard_name)
		write_ok := os.write_entire_file(file_path, transmute([]u8)md_content)
		if !write_ok {
			fmt.printfln("  FAIL  %s (could not write %s)", shard_name, file_path)
			errors += 1
			continue
		}

		fmt.printfln("  exported: %s", file_path)
		exported += 1
	}

	fmt.println()
	fmt.printfln("Done: %d exported, %d skipped, %d errors", exported, skipped, errors)
}

