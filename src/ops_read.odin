// ops_read.odin — read operations: digest, slot loading, key management
package shard

import "core:fmt"
import "core:strings"
import "core:time"

_op_requires_key :: proc(op: string) -> bool {
	switch op {
	case "write",
	     "read",
	     "update",
	     "delete",
	     "query",
	     "compact",
	     "compact_suggest",
	     "revisions",
	     "stale",
	     "feedback":
		return true
	}
	return false
}

_op_digest :: proc(node: ^Node, req: Request, allocator := context.allocator) -> string {
	use_filter := req.query != ""
	q_tokens: []string
	if use_filter {
		q_tokens = _tokenize(req.query, context.temp_allocator)
	}

	// Build markdown body
	b := strings.builder_make(context.temp_allocator)

	for &entry in node.registry {
		if use_filter && len(q_tokens) > 0 {
			gs := _score_gates(entry, q_tokens)
			if gs.score < ACCESS_MIN_SCORE do continue
		}

		fmt.sbprintf(&b, "\n## %s\n", entry.name)
		if entry.catalog.purpose != "" {
			fmt.sbprintf(&b, "**Purpose:** %s\n", entry.catalog.purpose)
		}
		fmt.sbprintf(&b, "**Thoughts:** %d\n", entry.thought_count)
		if entry.catalog.tags != nil && len(entry.catalog.tags) > 0 {
			strings.write_string(&b, "**Tags:** ")
			for tag, i in entry.catalog.tags {
				if i > 0 do strings.write_string(&b, ", ")
				strings.write_string(&b, tag)
			}
			strings.write_string(&b, "\n")
		}

		key_hex := req.key
		if key_hex == "" {
			key_hex = _access_resolve_key(entry.name)
		}

		slot := _slot_get_or_create(node, &entry)
		if !slot.loaded {
			_slot_load(slot, key_hex)
		}
		if key_hex != "" && !slot.key_set {
			_slot_set_key(slot, key_hex)
		}

		if slot.loaded && slot.key_set {
			slot.last_access = time.now()

			if len(slot.blob.processed) > 0 {
				strings.write_string(&b, "### Processed\n")
				for thought in slot.blob.processed {
					pt, err := thought_decrypt(thought, slot.master, context.temp_allocator)
					if err != .None do continue
					fmt.sbprintf(&b, "- %s\n", pt.description)
				}
			}

			if len(slot.blob.unprocessed) > 0 {
				strings.write_string(&b, "### Unprocessed\n")
				for thought in slot.blob.unprocessed {
					pt, err := thought_decrypt(thought, slot.master, context.temp_allocator)
					if err != .None do continue
					fmt.sbprintf(&b, "- %s\n", pt.description)
				}
			}
		} else if slot.loaded {
			strings.write_string(&b, "*No key available — descriptions not shown*\n")
		}
	}

	content := strings.clone(strings.to_string(b), allocator)
	return _marshal(
		Response{status = "ok", node_name = "digest", thoughts = len(node.registry), content = content},
		allocator,
	)
}

_access_resolve_key :: proc(shard_name: string) -> string {
	kc, ok := keychain_load(context.temp_allocator)
	if !ok do return ""
	key, found := keychain_lookup(kc, shard_name)
	if found do return key
	return ""
}

_find_registry_entry :: proc(node: ^Node, name: string) -> ^Registry_Entry {
	for &entry in node.registry {
		if entry.name == name {
			return &entry
		}
	}
	return nil
}

_slot_get_or_create :: proc(node: ^Node, entry: ^Registry_Entry) -> ^Shard_Slot {
	if slot, ok := node.slots[entry.name]; ok {
		return slot
	}
	slot := new(Shard_Slot)
	slot.name = entry.name
	slot.data_path = entry.data_path
	slot.loaded = false
	slot.key_set = false
	slot.last_access = time.now()
	node.slots[entry.name] = slot
	return slot
}

_slot_load :: proc(slot: ^Shard_Slot, key_hex: string = "") -> bool {
	master: Master_Key
	has_key := false

	if key_hex != "" {
		if k, ok := hex_to_key(key_hex); ok {
			master = k
			has_key = true
		}
	}

	blob, ok := blob_load(slot.data_path, master)
	if !ok do return false

	slot.blob = blob
	slot.loaded = true
	slot.master = master

	// Unencrypted mode: zero master key — treat as keyed so ops and index work.
	is_zero: u8 = 0
	for b in master do is_zero |= b
	slot.key_set = has_key || is_zero == 0

	if slot.key_set {
		_slot_build_index(slot)
	}

	return true
}

_slot_set_key :: proc(slot: ^Shard_Slot, key_hex: string) {
	k, ok := hex_to_key(key_hex)
	if !ok do return

	slot.master = k
	slot.blob.master = slot.master
	slot.key_set = true
	_slot_build_index(slot)
}

_slot_build_index :: proc(slot: ^Shard_Slot) {
	build_search_index(&slot.index, slot.blob, slot.master, fmt.tprintf("daemon/%s", slot.name))
}

_slot_verify_key :: proc(slot: ^Shard_Slot, key_hex: string) -> bool {
	// Unencrypted mode: zero master key accepts any request (key optional).
	is_zero: u8 = 0
	for b in slot.master do is_zero |= b
	if is_zero == 0 do return true

	if !slot.key_set do return false
	k, ok := hex_to_key(key_hex)
	if !ok do return false
	diff: u8 = 0
	for i in 0 ..< 32 do diff |= k[i] ~ slot.master[i]
	return diff == 0
}


