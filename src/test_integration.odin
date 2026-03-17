package shard

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

// =============================================================================
// Integration tests — blob roundtrip, config, keychain, revision chains, events
// =============================================================================

// Blob flush/load roundtrip — write to disk, read back, verify integrity
@(test)
test_blob_flush_load_roundtrip :: proc(t: ^testing.T) {
	key := Master_Key{1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32}
	test_path := ".shards/_test_roundtrip.shard"
	defer os.remove(test_path)

	// Create blob with some thoughts
	id1 := new_thought_id()
	id2 := new_thought_id()
	pt1 := Thought_Plaintext{description = "roundtrip processed", content = "processed body"}
	pt2 := Thought_Plaintext{description = "roundtrip unprocessed", content = "unprocessed body"}
	thought1, ok1 := thought_create(key, id1, pt1)
	thought2, ok2 := thought_create(key, id2, pt2)
	testing.expect(t, ok1, "thought1 must create")
	testing.expect(t, ok2, "thought2 must create")

	thought1.agent = "test-agent"
	thought1.created_at = _format_time(time.now())
	thought1.updated_at = _format_time(time.now())
	thought1.ttl = 3600
	thought1.read_count = 5
	thought1.cite_count = 2
	thought2.agent = "test-agent"
	thought2.created_at = _format_time(time.now())
	thought2.updated_at = _format_time(time.now())

	blob := Blob{
		path        = test_path,
		master      = key,
		processed   = make([dynamic]Thought),
		unprocessed = make([dynamic]Thought),
		description = make([dynamic]string),
		positive    = make([dynamic]string),
		negative    = make([dynamic]string),
		related     = make([dynamic]string),
		catalog     = Catalog{
			name    = "test-shard",
			purpose = "roundtrip test",
			tags    = {"test", "integration"},
			created = _format_time(time.now()),
		},
	}
	append(&blob.processed, thought1)
	append(&blob.unprocessed, thought2)
	append(&blob.description, "test description")
	append(&blob.positive, "roundtrip")
	append(&blob.negative, "exclude-me")
	append(&blob.related, "other-shard")

	// Flush to disk
	flush_ok := blob_flush(&blob)
	testing.expect(t, flush_ok, "blob_flush must succeed")

	// Verify file exists
	_, stat_err := os.stat(test_path)
	testing.expect(t, stat_err == nil, "shard file must exist after flush")

	// Load back
	loaded, load_ok := blob_load(test_path, key)
	testing.expect(t, load_ok, "blob_load must succeed")

	// Verify processed thoughts
	testing.expect(t, len(loaded.processed) == 1, "must have 1 processed thought")
	if len(loaded.processed) > 0 {
		rpt, rerr := thought_decrypt(loaded.processed[0], key, context.temp_allocator)
		testing.expect(t, rerr == .None, "processed thought must decrypt")
		if rerr == .None {
			testing.expect(t, rpt.description == "roundtrip processed", "processed description must match")
			testing.expect(t, rpt.content == "processed body", "processed content must match")
		}
		testing.expect(t, loaded.processed[0].agent == "test-agent", "agent must persist")
		testing.expect(t, loaded.processed[0].ttl == 3600, "ttl must persist")
		testing.expect(t, loaded.processed[0].read_count == 5, "read_count must persist")
		testing.expect(t, loaded.processed[0].cite_count == 2, "cite_count must persist")
	}

	// Verify unprocessed thoughts
	testing.expect(t, len(loaded.unprocessed) == 1, "must have 1 unprocessed thought")
	if len(loaded.unprocessed) > 0 {
		rpt, rerr := thought_decrypt(loaded.unprocessed[0], key, context.temp_allocator)
		testing.expect(t, rerr == .None, "unprocessed thought must decrypt")
		if rerr == .None {
			testing.expect(t, rpt.description == "roundtrip unprocessed", "unprocessed description must match")
		}
	}

	// Verify catalog
	testing.expect(t, loaded.catalog.name == "test-shard", "catalog name must match")
	testing.expect(t, loaded.catalog.purpose == "roundtrip test", "catalog purpose must match")

	// Verify gates
	testing.expect(t, len(loaded.description) == 1, "must have 1 description gate")
	testing.expect(t, len(loaded.positive) == 1, "must have 1 positive gate")
	testing.expect(t, len(loaded.negative) == 1, "must have 1 negative gate")
	testing.expect(t, len(loaded.related) == 1, "must have 1 related gate")
}

// Config defaults — verify default values without a config file
@(test)
test_config_defaults :: proc(t: ^testing.T) {
	cfg := DEFAULT_CONFIG
	testing.expect(t, cfg.slot_idle_max == 300, "slot_idle_max default must be 300")
	testing.expect(t, cfg.evict_interval == 30, "evict_interval default must be 30")
	testing.expect(t, cfg.max_shards == 64, "max_shards default must be 64")
	testing.expect(t, cfg.default_query_limit == 5, "default_query_limit must be 5")
	testing.expect(t, cfg.default_query_budget == 0, "default_query_budget must be 0 (unlimited)")
	testing.expect(t, cfg.relevance_keyword_weight == 0.3, "relevance_keyword_weight must be 0.3")
	testing.expect(t, cfg.fleet_max_parallel == 8, "fleet_max_parallel must be 8")
	testing.expect(t, cfg.compact_threshold == 20, "compact_threshold must be 20")
	testing.expect(t, cfg.compact_mode == "lossless", "compact_mode must be lossless")
	testing.expect(t, !cfg.streaming_enabled, "streaming must be disabled by default")
}

// Keychain parsing — per-shard, wildcard, missing
@(test)
test_keychain_lookup :: proc(t: ^testing.T) {
	kc := Keychain{
		entries = make([dynamic]Keychain_Entry),
		default_key = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
	}
	append(&kc.entries, Keychain_Entry{name = "notes", key = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"})
	append(&kc.entries, Keychain_Entry{name = "*", key = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"})

	// Direct match
	key, found := keychain_lookup(kc, "notes")
	testing.expect(t, found, "must find 'notes' key")
	testing.expect(t, key == "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "notes key must match")

	// Wildcard fallback
	key2, found2 := keychain_lookup(kc, "other")
	testing.expect(t, found2, "must find wildcard key for 'other'")
	testing.expect(t, key2 == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "wildcard key must match")

	// No wildcard
	kc2 := Keychain{entries = make([dynamic]Keychain_Entry)}
	_, found3 := keychain_lookup(kc2, "missing")
	testing.expect(t, !found3, "must not find key without entries")
}

// Revision chain walking — linear chain of 3 revisions
@(test)
test_revision_chain_walking :: proc(t: ^testing.T) {
	key := Master_Key{1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32}
	key_hex := _make_test_key_hex(key)

	// Create chain: root -> child1 -> child2
	root_id := new_thought_id()
	child1_id := new_thought_id()
	child2_id := new_thought_id()

	pt_root := Thought_Plaintext{description = "version 1", content = "original"}
	thought_root, _ := thought_create(key, root_id, pt_root)
	thought_root.created_at = _format_time(time.time_add(time.now(), -60 * time.Second))
	thought_root.updated_at = thought_root.created_at
	thought_root.agent = "agent-1"

	pt_child1 := Thought_Plaintext{description = "version 2", content = "updated"}
	thought_child1, _ := thought_create(key, child1_id, pt_child1)
	thought_child1.revises = root_id
	thought_child1.created_at = _format_time(time.time_add(time.now(), -30 * time.Second))
	thought_child1.updated_at = thought_child1.created_at
	thought_child1.agent = "agent-2"

	pt_child2 := Thought_Plaintext{description = "version 3", content = "final"}
	thought_child2, _ := thought_create(key, child2_id, pt_child2)
	thought_child2.revises = child1_id
	thought_child2.created_at = _format_time(time.now())
	thought_child2.updated_at = thought_child2.created_at
	thought_child2.agent = "agent-3"

	blob := Blob{
		processed   = make([dynamic]Thought),
		unprocessed = make([dynamic]Thought),
		description = make([dynamic]string),
		positive    = make([dynamic]string),
		negative    = make([dynamic]string),
		related     = make([dynamic]string),
		master      = key,
	}
	append(&blob.unprocessed, thought_root)
	append(&blob.unprocessed, thought_child1)
	append(&blob.unprocessed, thought_child2)

	node := Node{
		blob  = blob,
		index = make([dynamic]Search_Entry),
	}

	// Use the revisions op to walk the chain
	root_hex := id_to_hex(root_id)
	result := dispatch(&node, fmt.tprintf("---\nop: revisions\nid: %s\nkey: %s\n---\n", root_hex, key_hex))
	testing.expect(t, strings.contains(result, "status: ok"), "revisions op must return ok")
	// Should find the chain (returns ids field)
	testing.expect(t, strings.contains(result, "ids:"), "must have ids field with chain")
}

// Compact merge — verify revision chain merging into processed
@(test)
test_compact_merge_into_processed :: proc(t: ^testing.T) {
	key := Master_Key{1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32}
	key_hex := _make_test_key_hex(key)

	root_id := new_thought_id()
	child_id := new_thought_id()
	standalone_id := new_thought_id()

	pt_root := Thought_Plaintext{description = "base thought", content = "v1"}
	thought_root, _ := thought_create(key, root_id, pt_root)
	thought_root.created_at = _format_time(time.time_add(time.now(), -30 * time.Second))
	thought_root.updated_at = thought_root.created_at
	thought_root.agent = "author"

	pt_child := Thought_Plaintext{description = "base thought (updated)", content = "v2"}
	thought_child, _ := thought_create(key, child_id, pt_child)
	thought_child.revises = root_id
	thought_child.created_at = _format_time(time.now())
	thought_child.updated_at = thought_child.created_at
	thought_child.agent = "reviewer"

	pt_standalone := Thought_Plaintext{description = "standalone thought", content = "independent"}
	thought_standalone, _ := thought_create(key, standalone_id, pt_standalone)
	thought_standalone.created_at = _format_time(time.now())
	thought_standalone.updated_at = thought_standalone.created_at

	blob := Blob{
		processed   = make([dynamic]Thought),
		unprocessed = make([dynamic]Thought),
		description = make([dynamic]string),
		positive    = make([dynamic]string),
		negative    = make([dynamic]string),
		related     = make([dynamic]string),
		master      = key,
	}
	append(&blob.unprocessed, thought_root)
	append(&blob.unprocessed, thought_child)
	append(&blob.unprocessed, thought_standalone)

	node := Node{
		blob  = blob,
		index = make([dynamic]Search_Entry),
	}

	root_hex := id_to_hex(root_id)
	child_hex := id_to_hex(child_id)
	standalone_hex := id_to_hex(standalone_id)

	result := dispatch(&node, fmt.tprintf(
		"---\nop: compact\nkey: %s\nids: [%s, %s, %s]\n---\n",
		key_hex, root_hex, child_hex, standalone_hex,
	))
	testing.expect(t, strings.contains(result, "status: ok"), "compact must return ok")
	testing.expect(t, strings.contains(result, "moved: 3"), "must move 3 thoughts")

	// After compact: unprocessed should be empty, processed should have 2
	// (1 merged chain + 1 standalone)
	testing.expect(t, len(node.blob.unprocessed) == 0, "unprocessed must be empty after compact")
	testing.expect(t, len(node.blob.processed) == 2, "processed must have 2 (merged + standalone)")

	// Verify the merged thought contains both versions
	for p in node.blob.processed {
		pt, err := thought_decrypt(p, key, context.temp_allocator)
		if err != .None do continue
		if strings.contains(pt.description, "base thought") {
			testing.expect(t, strings.contains(pt.content, "v1"), "merged must contain v1")
			testing.expect(t, strings.contains(pt.content, "v2"), "merged must contain v2")
		}
	}
}

// Event hub — auto-emit on write, origin chain prevents loops
@(test)
test_event_hub_auto_emit :: proc(t: ^testing.T) {

	node := Node{
		registry     = make([dynamic]Registry_Entry),
		slots        = make(map[string]^Shard_Slot),
		event_queue  = Event_Queue{},
	}

	// Set up two related shards
	append(&node.registry, Registry_Entry{
		name      = "shard-a",
		data_path = ".shards/shard-a.shard",
		catalog   = Catalog{related = {"shard-b"}},
		gate_related = {"shard-b"},
	})
	append(&node.registry, Registry_Entry{
		name      = "shard-b",
		data_path = ".shards/shard-b.shard",
		catalog   = Catalog{related = {"shard-a"}},
		gate_related = {"shard-a"},
	})

	// Emit event from shard-a
	req := Request{
		source     = "shard-a",
		event_type = "knowledge_changed",
		agent      = "test-agent",
	}
	result := _op_notify(&node, req)
	testing.expect(t, strings.contains(result, "status: ok"), "notify must succeed")

	// shard-b should have a pending event
	events, has_events := node.event_queue["shard-b"]
	testing.expect(t, has_events, "shard-b must have pending events")
	if has_events {
		testing.expect(t, len(events) == 1, "shard-b must have exactly 1 event")
		if len(events) > 0 {
			testing.expect(t, events[0].source == "shard-a", "event source must be shard-a")
			testing.expect(t, events[0].event_type == "knowledge_changed", "event type must match")
		}
	}

	// shard-a should NOT have an event (origin chain prevents loop)
	_, has_a_events := node.event_queue["shard-a"]
	testing.expect(t, !has_a_events, "shard-a must NOT get its own event")
}

// Event hub — origin chain prevents circular propagation
@(test)
test_event_origin_chain_prevents_loop :: proc(t: ^testing.T) {
	node := Node{
		registry     = make([dynamic]Registry_Entry),
		slots        = make(map[string]^Shard_Slot),
		event_queue  = Event_Queue{},
	}

	// A -> B -> C -> A (circular)
	append(&node.registry, Registry_Entry{
		name      = "a",
		data_path = ".shards/a.shard",
		gate_related = {"b"},
	})
	append(&node.registry, Registry_Entry{
		name      = "b",
		data_path = ".shards/b.shard",
		gate_related = {"c"},
	})
	append(&node.registry, Registry_Entry{
		name      = "c",
		data_path = ".shards/c.shard",
		gate_related = {"a"},
	})

	// Emit from a -> b
	_op_notify(&node, Request{source = "a", event_type = "knowledge_changed", agent = "test"})

	// Now simulate b forwarding to c, with origin_chain = [a, b]
	_op_notify(&node, Request{source = "b", event_type = "knowledge_changed", agent = "test", origin_chain = {"a", "b"}})

	// c should have an event, but NOT loop back to a (a is in origin chain)
	c_events, has_c := node.event_queue["c"]
	testing.expect(t, has_c, "c must have events")

	// a should NOT get a second event from c's forwarding since a is in the origin chain
	a_events, has_a := node.event_queue["a"]
	if has_a {
		// a might have events from b's forwarding to c if c->a was tried,
		// but the origin chain should prevent it
		for ev in a_events {
			testing.expect(t, ev.source != "c" || false, "a must not get circular event from c")
		}
	}

	// Verify origin chain length grows
	if has_c && len(c_events) > 0 {
		testing.expect(t, len(c_events[0].origin_chain) >= 2, "origin chain must include a and b")
	}
}

// Blob load of non-existent file returns empty blob (valid behavior)
@(test)
test_blob_load_nonexistent :: proc(t: ^testing.T) {
	key := Master_Key{}
	blob, ok := blob_load(".shards/_nonexistent_test.shard", key)
	testing.expect(t, ok, "loading non-existent file must return ok (empty blob)")
	testing.expect(t, len(blob.processed) == 0, "empty blob must have no processed")
	testing.expect(t, len(blob.unprocessed) == 0, "empty blob must have no unprocessed")
}
