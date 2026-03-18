package shard

import "core:crypto"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

import logger "logger"

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

	logger.info("=== Create new shard ===")
	logger.info("")

	// 1. Name (required)
	name := _prompt("Shard name (required): ")
	if name == "" {
		logger.err("error: name is required")
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
			logger.err("error: key must be exactly 64 hex characters (32 bytes)")
			os.exit(1)
		}
		master = k
	}

	// 6. Data path — store under .shards/
	data_path := fmt.tprintf(".shards/%s.shard", name)
	os.make_directory(".shards")

	// Check if file already exists
	if os.exists(data_path) {
		overwrite := _prompt(
			fmt.tprintf("File '%s' already exists. Overwrite? (y/N): ", data_path),
		)
		if overwrite != "y" && overwrite != "Y" {
			fmt.println("Aborted.")
			return
		}
	}

	// Build the blob with catalog
	blob, ok := blob_load(data_path, master)
	if !ok {
		logger.err("error: could not initialize shard file")
		os.exit(1)
	}

	blob.catalog = Catalog {
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
