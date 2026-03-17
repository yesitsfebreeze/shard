package shard

import "core:os"
import "core:strings"


// Format (one entry per line):
//   # comment
//   <shard-name> <64-hex-key>
//   * <64-hex-key>              <- default key for any shard not listed
//
// The keychain is a convenience file so you don't have to pass --key every
// time. It maps shard names to their master keys. A wildcard (*) entry
// provides a default key for shards without an explicit mapping.
//
// Key resolution order (used by dump, MCP, etc.):
//   1. Explicit --key flag or tool parameter
//   2. SHARD_KEY environment variable
//   3. Keychain entry for the specific shard name
//   4. Keychain wildcard (*) entry

KEYCHAIN_PATH :: ".shards/keychain"

Keychain_Entry :: struct {
	name: string, // shard name or "*" for default
	key:  string, // 64-hex key
}

Keychain :: struct {
	entries:     [dynamic]Keychain_Entry,
	default_key: string,
}

keychain_load :: proc(allocator := context.allocator) -> (Keychain, bool) {
	kc: Keychain
	kc.entries = make([dynamic]Keychain_Entry, allocator)

	data, ok := os.read_entire_file(KEYCHAIN_PATH, context.temp_allocator)
	if !ok do return kc, false

	content := string(data)
	for line in strings.split_lines_iterator(&content) {
		trimmed := strings.trim_space(line)
		if trimmed == "" || strings.has_prefix(trimmed, "#") do continue

		sp := strings.index_any(trimmed, " \t")
		if sp == -1 do continue

		name := strings.clone(trimmed[:sp], allocator)
		key := strings.clone(strings.trim_space(trimmed[sp + 1:]), allocator)
		if len(key) != 64 do continue

		append(&kc.entries, Keychain_Entry{name = name, key = key})
		if name == "*" {
			kc.default_key = key
		}
	}

	return kc, len(kc.entries) > 0
}


keychain_lookup :: proc(kc: Keychain, shard_name: string) -> (string, bool) {
	for entry in kc.entries {
		if entry.name == shard_name {
			return entry.key, true
		}
	}
	if kc.default_key != "" {
		return kc.default_key, true
	}
	return "", false
}


