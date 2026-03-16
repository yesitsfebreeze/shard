package shard

import "core:fmt"
import "core:strings"
import "core:testing"

// =============================================================================
// Digest and budget tests
// =============================================================================

@(test)
test_digest_op_returns_ok :: proc(t: ^testing.T) {
	key := Master_Key{1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32}
	key_hex := _make_test_key_hex(key)

	// Create a thought
	id := new_thought_id()
	create_pt := Thought_Plaintext{description = "Architecture overview", content = "Full content about architecture"}
	thought, _ := thought_create(key, id, create_pt)

	// Build a slot with the thought
	slot := new(Shard_Slot)
	slot.name     = "test-shard"
	slot.loaded   = true
	slot.key_set  = true
	slot.master   = key
	slot.blob = Blob{
		processed   = make([dynamic]Thought),
		unprocessed = make([dynamic]Thought),
		description = make([dynamic]string),
		positive    = make([dynamic]string),
		negative    = make([dynamic]string),
		related     = make([dynamic]string),
		master      = key,
		catalog     = Catalog{name = "test-shard", purpose = "Test shard for digest"},
	}
	append(&slot.blob.unprocessed, thought)

	pt, _ := thought_decrypt(thought, key)
	slot.index = make([dynamic]Search_Entry)
	append(&slot.index, Search_Entry{id = thought.id, description = pt.description})

	// Create daemon node
	node := Node{
		name      = "daemon",
		is_daemon = true,
		blob = Blob{
			processed   = make([dynamic]Thought),
			unprocessed = make([dynamic]Thought),
			description = make([dynamic]string),
			positive    = make([dynamic]string),
			negative    = make([dynamic]string),
			related     = make([dynamic]string),
		},
		registry    = make([dynamic]Registry_Entry),
		slots       = make(map[string]^Shard_Slot),
		event_queue = make(Event_Queue),
	}
	append(&node.registry, Registry_Entry{
		name          = "test-shard",
		thought_count = 1,
		catalog       = Catalog{name = "test-shard", purpose = "Test shard for digest"},
	})
	node.slots["test-shard"] = slot

	// Call digest
	req := Request{op = "digest", key = key_hex}
	result, handled := daemon_dispatch(&node, req)
	testing.expect(t, handled, "digest must be handled by daemon")
	testing.expect(t, strings.contains(result, "status: ok"), "digest must return ok")
	testing.expect(t, strings.contains(result, "op: digest"), "digest must include op field")
	testing.expect(t, strings.contains(result, "test-shard"), "digest must include shard name")
	testing.expect(t, strings.contains(result, "Architecture overview"), "digest must include thought description")
}

@(test)
test_budget_query_truncates_content :: proc(t: ^testing.T) {
	key := Master_Key{1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32}
	key_hex := _make_test_key_hex(key)

	// Create a thought with long content
	long_content := "This is a very long content string that should be truncated when budget is applied to the query operation"
	id := new_thought_id()
	create_pt := Thought_Plaintext{description = "Budget test thought", content = long_content}
	thought, _ := thought_create(key, id, create_pt)

	// Build node
	blob := Blob{
		processed   = make([dynamic]Thought),
		unprocessed = make([dynamic]Thought),
		description = make([dynamic]string),
		positive    = make([dynamic]string),
		negative    = make([dynamic]string),
		related     = make([dynamic]string),
		master      = key,
	}
	append(&blob.unprocessed, thought)

	pt, _ := thought_decrypt(thought, key)
	index := make([dynamic]Search_Entry)
	append(&index, Search_Entry{id = thought.id, description = pt.description, text_hash = fnv_hash(pt.description)})

	node := Node{
		blob  = blob,
		index = index,
	}

	// Query with budget of 20 chars
	result := dispatch(&node, fmt.tprintf("---\nop: query\nkey: %s\nquery: Budget test\nbudget: 20\n---\n", key_hex))
	testing.expect(t, strings.contains(result, "status: ok"), "budget query must succeed")
	testing.expect(t, strings.contains(result, "truncated: true"), "truncated flag must be set")
	testing.expect(t, strings.contains(result, "Budget test thought"), "description must be present")
	// The full content should NOT be present
	testing.expect(t, !strings.contains(result, long_content), "full content must not be present when budget is small")
}

@(test)
test_budget_zero_returns_full_content :: proc(t: ^testing.T) {
	key := Master_Key{1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32}
	key_hex := _make_test_key_hex(key)

	content := "Full content that should not be truncated"
	id := new_thought_id()
	create_pt := Thought_Plaintext{description = "Full content test", content = content}
	thought, _ := thought_create(key, id, create_pt)

	blob := Blob{
		processed   = make([dynamic]Thought),
		unprocessed = make([dynamic]Thought),
		description = make([dynamic]string),
		positive    = make([dynamic]string),
		negative    = make([dynamic]string),
		related     = make([dynamic]string),
		master      = key,
	}
	append(&blob.unprocessed, thought)

	pt, _ := thought_decrypt(thought, key)
	index := make([dynamic]Search_Entry)
	append(&index, Search_Entry{id = thought.id, description = pt.description, text_hash = fnv_hash(pt.description)})

	node := Node{
		blob  = blob,
		index = index,
	}

	result := dispatch(&node, fmt.tprintf("---\nop: query\nkey: %s\nquery: Full content\nbudget: 0\n---\n", key_hex))
	testing.expect(t, strings.contains(result, "status: ok"), "query must succeed")
	testing.expect(t, strings.contains(result, content), "full content must be present with budget 0")
	testing.expect(t, !strings.contains(result, "truncated: true"), "truncated must not be set with budget 0")
}

@(test)
test_budget_parse_in_request :: proc(t: ^testing.T) {
	req, ok := md_parse_request("---\nop: query\nbudget: 5000\n---\n")
	testing.expect(t, ok, "parse must succeed")
	testing.expect(t, req.budget == 5000, "budget must be parsed correctly")
}

@(test)
test_truncated_flag_in_marshal :: proc(t: ^testing.T) {
	results := []Wire_Result{
		{id = "abc123", score = 0.9, description = "test", content = "partial...", truncated = true},
		{id = "def456", score = 0.8, description = "test2", content = "full content", truncated = false},
	}
	resp := Response{status = "ok", results = results}
	output := md_marshal_response(resp)
	testing.expect(t, strings.contains(output, "truncated: true"), "truncated flag must appear for truncated result")
	// Count occurrences — should only appear once (for the first result)
	count := strings.count(output, "truncated: true")
	testing.expect(t, count == 1, "truncated: true should appear exactly once")
}
