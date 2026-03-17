package shard

import "core:fmt"
import "core:strings"
import "core:testing"
import "core:time"

// =============================================================================
// Self-compacting intelligence tests
// =============================================================================

@(test)
test_compact_suggest_empty :: proc(t: ^testing.T) {
	key := Master_Key {
		1,
		2,
		3,
		4,
		5,
		6,
		7,
		8,
		9,
		10,
		11,
		12,
		13,
		14,
		15,
		16,
		17,
		18,
		19,
		20,
		21,
		22,
		23,
		24,
		25,
		26,
		27,
		28,
		29,
		30,
		31,
		32,
	}
	key_hex := _make_test_key_hex(key)

	blob := Blob {
		processed   = make([dynamic]Thought),
		unprocessed = make([dynamic]Thought),
		description = make([dynamic]string),
		positive    = make([dynamic]string),
		negative    = make([dynamic]string),
		related     = make([dynamic]string),
		master      = key,
	}

	node := Node {
		blob  = blob,
		index = make([dynamic]Search_Entry),
	}

	result := dispatch(&node, fmt.tprintf("---\nop: compact_suggest\nkey: %s\n---\n", key_hex))
	testing.expect(
		t,
		strings.contains(result, "status: ok"),
		"compact_suggest on empty shard must return ok",
	)
}

@(test)
test_compact_suggest_revision_chain :: proc(t: ^testing.T) {
	key := Master_Key {
		1,
		2,
		3,
		4,
		5,
		6,
		7,
		8,
		9,
		10,
		11,
		12,
		13,
		14,
		15,
		16,
		17,
		18,
		19,
		20,
		21,
		22,
		23,
		24,
		25,
		26,
		27,
		28,
		29,
		30,
		31,
		32,
	}
	key_hex := _make_test_key_hex(key)

	// Create a revision chain: root -> child
	root_id := new_thought_id()
	child_id := new_thought_id()

	pt_root := Thought_Plaintext {
		description = "architecture overview",
		content     = "v1 content",
	}
	thought_root, _ := thought_create(key, root_id, pt_root)
	thought_root.created_at = _format_time(time.now())
	thought_root.updated_at = _format_time(time.now())

	pt_child := Thought_Plaintext {
		description = "architecture overview updated",
		content     = "v2 content",
	}
	thought_child, _ := thought_create(key, child_id, pt_child)
	thought_child.revises = root_id
	thought_child.created_at = _format_time(time.now())
	thought_child.updated_at = _format_time(time.now())

	blob := Blob {
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

	node := Node {
		blob  = blob,
		index = make([dynamic]Search_Entry),
	}

	result := dispatch(&node, fmt.tprintf("---\nop: compact_suggest\nkey: %s\n---\n", key_hex))
	testing.expect(t, strings.contains(result, "status: ok"), "compact_suggest must return ok")
	testing.expect(t, strings.contains(result, "revision_chain"), "must detect revision chain")
	testing.expect(t, strings.contains(result, "merge"), "must suggest merge action")
}

@(test)
test_compact_suggest_duplicates :: proc(t: ^testing.T) {
	key := Master_Key {
		1,
		2,
		3,
		4,
		5,
		6,
		7,
		8,
		9,
		10,
		11,
		12,
		13,
		14,
		15,
		16,
		17,
		18,
		19,
		20,
		21,
		22,
		23,
		24,
		25,
		26,
		27,
		28,
		29,
		30,
		31,
		32,
	}
	key_hex := _make_test_key_hex(key)

	// Create two thoughts with very similar descriptions
	id1 := new_thought_id()
	id2 := new_thought_id()

	pt1 := Thought_Plaintext {
		description = "milestone two complete",
		content     = "content A",
	}
	thought1, _ := thought_create(key, id1, pt1)
	thought1.created_at = _format_time(time.now())
	thought1.updated_at = _format_time(time.now())

	pt2 := Thought_Plaintext {
		description = "milestone two complete",
		content     = "content B",
	}
	thought2, _ := thought_create(key, id2, pt2)
	thought2.created_at = _format_time(time.now())
	thought2.updated_at = _format_time(time.now())

	blob := Blob {
		processed   = make([dynamic]Thought),
		unprocessed = make([dynamic]Thought),
		description = make([dynamic]string),
		positive    = make([dynamic]string),
		negative    = make([dynamic]string),
		related     = make([dynamic]string),
		master      = key,
	}
	append(&blob.unprocessed, thought1)
	append(&blob.unprocessed, thought2)

	node := Node {
		blob  = blob,
		index = make([dynamic]Search_Entry),
	}

	result := dispatch(&node, fmt.tprintf("---\nop: compact_suggest\nkey: %s\n---\n", key_hex))
	testing.expect(t, strings.contains(result, "status: ok"), "compact_suggest must return ok")
	testing.expect(t, strings.contains(result, "duplicate"), "must detect duplicates")
	testing.expect(t, strings.contains(result, "deduplicate"), "must suggest deduplicate action")
}

@(test)
test_compact_suggest_lossy_stale :: proc(t: ^testing.T) {
	key := Master_Key {
		1,
		2,
		3,
		4,
		5,
		6,
		7,
		8,
		9,
		10,
		11,
		12,
		13,
		14,
		15,
		16,
		17,
		18,
		19,
		20,
		21,
		22,
		23,
		24,
		25,
		26,
		27,
		28,
		29,
		30,
		31,
		32,
	}
	key_hex := _make_test_key_hex(key)
	now := time.now()

	// Create a stale thought (TTL=60, updated 120s ago)
	id1 := new_thought_id()
	pt1 := Thought_Plaintext {
		description = "old status update",
		content     = "outdated",
	}
	thought1, _ := thought_create(key, id1, pt1)
	thought1.ttl = 60
	thought1.created_at = _format_time(time.time_add(now, -120 * time.Second))
	thought1.updated_at = _format_time(time.time_add(now, -120 * time.Second))

	// Create a fresh thought (should NOT be suggested for pruning)
	id2 := new_thought_id()
	pt2 := Thought_Plaintext {
		description = "current status",
		content     = "fresh",
	}
	thought2, _ := thought_create(key, id2, pt2)
	thought2.ttl = 3600
	thought2.created_at = _format_time(now)
	thought2.updated_at = _format_time(now)

	blob := Blob {
		processed   = make([dynamic]Thought),
		unprocessed = make([dynamic]Thought),
		description = make([dynamic]string),
		positive    = make([dynamic]string),
		negative    = make([dynamic]string),
		related     = make([dynamic]string),
		master      = key,
	}
	append(&blob.unprocessed, thought1)
	append(&blob.unprocessed, thought2)

	node := Node {
		blob  = blob,
		index = make([dynamic]Search_Entry),
	}

	// Lossless mode should NOT suggest pruning
	result_lossless := dispatch(
		&node,
		fmt.tprintf("---\nop: compact_suggest\nkey: %s\nmode: lossless\n---\n", key_hex),
	)
	testing.expect(
		t,
		!strings.contains(result_lossless, "prune"),
		"lossless mode must NOT suggest pruning",
	)

	// Lossy mode should suggest pruning stale thought
	result_lossy := dispatch(
		&node,
		fmt.tprintf("---\nop: compact_suggest\nkey: %s\nmode: lossy\n---\n", key_hex),
	)
	testing.expect(
		t,
		strings.contains(result_lossy, "stale"),
		"lossy mode must detect stale thought",
	)
	testing.expect(t, strings.contains(result_lossy, "prune"), "lossy mode must suggest pruning")
}

@(test)
test_compact_lossy_merge :: proc(t: ^testing.T) {
	key := Master_Key {
		1,
		2,
		3,
		4,
		5,
		6,
		7,
		8,
		9,
		10,
		11,
		12,
		13,
		14,
		15,
		16,
		17,
		18,
		19,
		20,
		21,
		22,
		23,
		24,
		25,
		26,
		27,
		28,
		29,
		30,
		31,
		32,
	}
	key_hex := _make_test_key_hex(key)

	// Create a revision chain
	root_id := new_thought_id()
	child_id := new_thought_id()

	pt_root := Thought_Plaintext {
		description = "test thought",
		content     = "original content",
	}
	thought_root, _ := thought_create(key, root_id, pt_root)
	thought_root.created_at = _format_time(time.time_add(time.now(), -60 * time.Second))
	thought_root.updated_at = _format_time(time.time_add(time.now(), -60 * time.Second))
	thought_root.agent = "agent-a"

	pt_child := Thought_Plaintext {
		description = "test thought updated",
		content     = "revised content",
	}
	thought_child, _ := thought_create(key, child_id, pt_child)
	thought_child.revises = root_id
	thought_child.created_at = _format_time(time.now())
	thought_child.updated_at = _format_time(time.now())
	thought_child.agent = "agent-b"

	root_hex := id_to_hex(root_id)
	child_hex := id_to_hex(child_id)

	blob := Blob {
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

	node := Node {
		blob  = blob,
		index = make([dynamic]Search_Entry),
	}

	// Lossy compact — should only keep latest revision
	result := dispatch(
		&node,
		fmt.tprintf(
			"---\nop: compact\nkey: %s\nmode: lossy\nids: [%s, %s]\n---\n",
			key_hex,
			root_hex,
			child_hex,
		),
	)
	testing.expect(t, strings.contains(result, "status: ok"), "compact must return ok")
	testing.expect(t, strings.contains(result, "moved: 2"), "must move 2 thoughts")

	// Verify the merged thought has latest content (lossy = only latest)
	testing.expect(t, len(node.blob.processed) == 1, "must have 1 merged thought in processed")
	if len(node.blob.processed) > 0 {
		merged, err := thought_decrypt(node.blob.processed[0], key, context.temp_allocator)
		testing.expect(t, err == .None, "merged thought must decrypt")
		if err == .None {
			testing.expect(
				t,
				strings.contains(merged.content, "revised content"),
				"lossy merge must keep latest content",
			)
			testing.expect(
				t,
				!strings.contains(merged.content, "original content"),
				"lossy merge must NOT keep old content",
			)
		}
	}
}

@(test)
test_description_similarity :: proc(t: ^testing.T) {
	// Identical strings
	testing.expect(
		t,
		_description_similarity("hello world", "hello world") == 1.0,
		"identical must be 1.0",
	)

	// Completely different
	testing.expect(
		t,
		_description_similarity("hello world", "foo bar") == 0.0,
		"different must be 0.0",
	)

	// Partial overlap
	sim := _description_similarity("milestone two complete", "milestone two done")
	testing.expect(t, sim >= 0.5, "partial overlap must be >= 0.5")

	// Empty strings
	testing.expect(t, _description_similarity("", "") == 1.0, "both empty must be 1.0")
	testing.expect(t, _description_similarity("hello", "") == 0.0, "one empty must be 0.0")
}

@(test)
test_extract_suggestion_ids :: proc(t: ^testing.T) {
	// Test the YAML suggestion ID extraction used by compact_apply
	resp := `---
status: ok
suggestion_count: 2
suggestions:
  - kind: revision_chain
    ids:
      - abcdef01234567890abcdef012345678
      - 12345678abcdef0123456789abcdef01
    description: 2 revisions of "test"
    action: merge
  - kind: duplicate
    ids:
      - aabbccdd11223344aabbccdd11223344
      - 11223344aabbccddee556677889900aa
    description: similar descriptions
    action: deduplicate
---`

	ids := make([dynamic]string, context.temp_allocator)
	_extract_suggestion_ids(resp, &ids)

	testing.expect(t, len(ids) == 4, fmt.tprintf("must extract 4 IDs, got %d", len(ids)))

	// Verify all expected IDs are present
	found_count := 0
	expected := [?]string {
		"abcdef01234567890abcdef012345678",
		"12345678abcdef0123456789abcdef01",
		"aabbccdd11223344aabbccdd11223344",
		"11223344aabbccddee556677889900aa",
	}
	for e in expected {
		for id in ids {
			if id == e {found_count += 1; break}
		}
	}
	testing.expect(
		t,
		found_count == 4,
		fmt.tprintf("must find all 4 expected IDs, found %d", found_count),
	)
}

@(test)
test_extract_suggestion_ids_dedup :: proc(t: ^testing.T) {
	// Same ID in two different suggestions should only appear once
	resp := `---
status: ok
suggestions:
  - kind: revision_chain
    ids:
      - abcdef01234567890abcdef012345678
    action: merge
  - kind: duplicate
    ids:
      - abcdef01234567890abcdef012345678
    action: deduplicate
---`

	ids := make([dynamic]string, context.temp_allocator)
	_extract_suggestion_ids(resp, &ids)

	testing.expect(
		t,
		len(ids) == 1,
		fmt.tprintf("duplicate IDs must be deduplicated, got %d", len(ids)),
	)
}

@(test)
test_extract_suggestion_ids_empty :: proc(t: ^testing.T) {
	// No suggestions should yield no IDs
	resp := `---
status: ok
suggestion_count: 0
---`

	ids := make([dynamic]string, context.temp_allocator)
	_extract_suggestion_ids(resp, &ids)

	testing.expect(t, len(ids) == 0, "empty suggestions must yield 0 IDs")
}

@(test)
test_compact_via_dispatch :: proc(t: ^testing.T) {
	// Test compact op through dispatch with explicit IDs (simulating MCP shard_compact flow)
	key := Master_Key {
		1,
		2,
		3,
		4,
		5,
		6,
		7,
		8,
		9,
		10,
		11,
		12,
		13,
		14,
		15,
		16,
		17,
		18,
		19,
		20,
		21,
		22,
		23,
		24,
		25,
		26,
		27,
		28,
		29,
		30,
		31,
		32,
	}
	key_hex := _make_test_key_hex(key)

	// Create standalone thoughts
	id1 := new_thought_id()
	id2 := new_thought_id()

	pt1 := Thought_Plaintext {
		description = "first thought",
		content     = "content one",
	}
	thought1, _ := thought_create(key, id1, pt1)
	pt2 := Thought_Plaintext {
		description = "second thought",
		content     = "content two",
	}
	thought2, _ := thought_create(key, id2, pt2)

	id1_hex := id_to_hex(id1)
	id2_hex := id_to_hex(id2)

	blob := Blob {
		processed   = make([dynamic]Thought),
		unprocessed = make([dynamic]Thought),
		description = make([dynamic]string),
		positive    = make([dynamic]string),
		negative    = make([dynamic]string),
		related     = make([dynamic]string),
		master      = key,
	}
	append(&blob.unprocessed, thought1)
	append(&blob.unprocessed, thought2)

	node := Node {
		blob  = blob,
		index = make([dynamic]Search_Entry),
	}

	// Compact both thoughts — should move from unprocessed to processed
	result := dispatch(
		&node,
		fmt.tprintf("---\nop: compact\nkey: %s\nids: [%s, %s]\n---\n", key_hex, id1_hex, id2_hex),
	)
	testing.expect(t, strings.contains(result, "status: ok"), "compact must succeed")
	testing.expect(t, strings.contains(result, "moved: 2"), "must move 2 standalone thoughts")
	testing.expect(t, len(node.blob.unprocessed) == 0, "unprocessed must be empty after compact")
	testing.expect(t, len(node.blob.processed) == 2, "processed must have 2 thoughts")
}

@(test)
test_needs_compaction_event :: proc(t: ^testing.T) {
	// Verify the needs_compaction event type is accepted by notify

	node := Node {
		registry    = make([dynamic]Registry_Entry),
		slots       = make(map[string]^Shard_Slot),
		event_queue = Event_Queue{},
	}

	// Register a shard with related shard
	append(
		&node.registry,
		Registry_Entry {
			name = "test-shard",
			data_path = ".shards/test-shard.shard",
			catalog = Catalog{related = {"other-shard"}},
		},
	)
	append(
		&node.registry,
		Registry_Entry{name = "other-shard", data_path = ".shards/other-shard.shard"},
	)

	// Call _op_notify directly (it's a daemon-level op, not shard-level)
	req := Request {
		source     = "test-shard",
		event_type = "needs_compaction",
		agent      = "test",
	}
	result := _op_notify(&node, req)
	testing.expect(
		t,
		strings.contains(result, "status: ok"),
		"needs_compaction event must be accepted",
	)
}

@(test)
test_incremental_compact_standalone :: proc(t: ^testing.T) {
	// Verify that writing a thought via dispatch immediately places it in processed.
	key := Master_Key {
		1,
		2,
		3,
		4,
		5,
		6,
		7,
		8,
		9,
		10,
		11,
		12,
		13,
		14,
		15,
		16,
		17,
		18,
		19,
		20,
		21,
		22,
		23,
		24,
		25,
		26,
		27,
		28,
		29,
		30,
		31,
		32,
	}
	key_hex := _make_test_key_hex(key)

	blob := Blob {
		processed   = make([dynamic]Thought),
		unprocessed = make([dynamic]Thought),
		description = make([dynamic]string),
		positive    = make([dynamic]string),
		negative    = make([dynamic]string),
		related     = make([dynamic]string),
		master      = key,
	}
	node := Node {
		blob  = blob,
		index = make([dynamic]Search_Entry),
	}

	r1 := dispatch(
		&node,
		fmt.tprintf(
			"---\nop: write\nkey: %s\ndescription: first thought\n---\ncontent one\n",
			key_hex,
		),
	)
	testing.expect(t, strings.contains(r1, "status: ok"), "write 1 must succeed")
	testing.expect(t, len(node.blob.unprocessed) == 0, "unprocessed must be empty after write 1")
	testing.expect(t, len(node.blob.processed) == 1, "processed must have 1 thought after write 1")

	r2 := dispatch(
		&node,
		fmt.tprintf(
			"---\nop: write\nkey: %s\ndescription: second thought\n---\ncontent two\n",
			key_hex,
		),
	)
	testing.expect(t, strings.contains(r2, "status: ok"), "write 2 must succeed")
	testing.expect(t, len(node.blob.unprocessed) == 0, "unprocessed must be empty after write 2")
	testing.expect(
		t,
		len(node.blob.processed) == 2,
		"processed must have 2 thoughts after write 2",
	)
}

@(test)
test_incremental_compact_revision_chain :: proc(t: ^testing.T) {
	// Verify that writing a revision merges the chain into processed.
	key := Master_Key {
		2,
		3,
		4,
		5,
		6,
		7,
		8,
		9,
		10,
		11,
		12,
		13,
		14,
		15,
		16,
		17,
		18,
		19,
		20,
		21,
		22,
		23,
		24,
		25,
		26,
		27,
		28,
		29,
		30,
		31,
		32,
		1,
	}
	key_hex := _make_test_key_hex(key)

	blob := Blob {
		processed   = make([dynamic]Thought),
		unprocessed = make([dynamic]Thought),
		description = make([dynamic]string),
		positive    = make([dynamic]string),
		negative    = make([dynamic]string),
		related     = make([dynamic]string),
		master      = key,
	}
	node := Node {
		blob  = blob,
		index = make([dynamic]Search_Entry),
	}

	r1 := dispatch(
		&node,
		fmt.tprintf(
			"---\nop: write\nkey: %s\ndescription: architecture overview\n---\nv1 content\n",
			key_hex,
		),
	)
	testing.expect(t, strings.contains(r1, "status: ok"), "write root must succeed")
	testing.expect(
		t,
		len(node.blob.processed) == 1,
		"processed must have 1 thought after root write",
	)

	root_id_start := strings.index(r1, "id: ")
	testing.expect(t, root_id_start >= 0, "response must contain id field")
	root_id := r1[root_id_start + 4:]
	if nl := strings.index(root_id, "\n"); nl >= 0 {root_id = root_id[:nl]}
	root_id = strings.trim_space(root_id)

	r2 := dispatch(
		&node,
		fmt.tprintf(
			"---\nop: write\nkey: %s\ndescription: architecture overview updated\nrevises: %s\n---\nv2 content\n",
			key_hex,
			root_id,
		),
	)
	testing.expect(t, strings.contains(r2, "status: ok"), "write revision must succeed")
	testing.expect(
		t,
		len(node.blob.unprocessed) == 0,
		"unprocessed must be empty after revision write",
	)
	testing.expect(
		t,
		len(node.blob.processed) == 1,
		"revision chain must merge into 1 processed thought",
	)

	if len(node.blob.processed) == 1 {
		merged, err := thought_decrypt(node.blob.processed[0], key, context.temp_allocator)
		testing.expect(t, err == .None, "merged thought must decrypt")
		if err == .None {
			testing.expect(
				t,
				strings.contains(merged.content, "v1 content"),
				"lossless merge must contain v1",
			)
			testing.expect(
				t,
				strings.contains(merged.content, "v2 content"),
				"lossless merge must contain v2",
			)
			delete(merged.description, context.temp_allocator)
			delete(merged.content, context.temp_allocator)
		}
	}
}
