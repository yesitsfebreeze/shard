package shard

import "core:strings"
import "core:testing"

// =============================================================================
// Consumption tracking tests
// =============================================================================

// _free_node cleans up a test node.
@(private)
_free_node :: proc(node: ^Node) {
	for &record in node.consumption_log {
		delete(record.agent)
		delete(record.shard)
		delete(record.op)
		delete(record.timestamp)
	}
	delete(node.consumption_log)
	delete(node.registry)
	delete(node.slots)
	delete(node.event_queue)
	delete(node.blob.processed)
	delete(node.blob.unprocessed)
	delete(node.blob.description)
	delete(node.blob.positive)
	delete(node.blob.negative)
	delete(node.blob.related)
	delete(node.index)
}

@(test)
test_consumption_record_tracking :: proc(t: ^testing.T) {
	// Create a daemon node
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
		registry = make([dynamic]Registry_Entry),
		slots    = make(map[string]^Shard_Slot),
		event_queue = make(Event_Queue),
	}

	// Record some consumption
	_record_consumption(&node, "agent-1", "notes", "read")
	_record_consumption(&node, "agent-2", "todos", "write")
	_record_consumption(&node, "agent-1", "notes", "query")

	testing.expect(t, len(node.consumption_log) == 3, "should have 3 records")
	testing.expect(t, node.consumption_log[0].agent == "agent-1", "first record agent")
	testing.expect(t, node.consumption_log[0].shard == "notes", "first record shard")
	testing.expect(t, node.consumption_log[0].op == "read", "first record op")
	testing.expect(t, node.consumption_log[1].agent == "agent-2", "second record agent")
	testing.expect(t, node.consumption_log[2].op == "query", "third record op")

	_free_node(&node)
}

@(test)
test_consumption_ring_buffer :: proc(t: ^testing.T) {
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
		registry = make([dynamic]Registry_Entry),
		slots    = make(map[string]^Shard_Slot),
		event_queue = make(Event_Queue),
	}

	// Fill beyond MAX_CONSUMPTION_RECORDS
	for i in 0 ..< MAX_CONSUMPTION_RECORDS + 50 {
		_record_consumption(&node, "agent", "shard", "read")
	}

	testing.expect(t, len(node.consumption_log) <= MAX_CONSUMPTION_RECORDS,
		"ring buffer should cap at MAX_CONSUMPTION_RECORDS")
}

@(test)
test_consumption_unknown_agent :: proc(t: ^testing.T) {
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
		registry = make([dynamic]Registry_Entry),
		slots    = make(map[string]^Shard_Slot),
		event_queue = make(Event_Queue),
	}

	// Empty agent should become "unknown"
	_record_consumption(&node, "", "notes", "read")
	testing.expect(t, node.consumption_log[0].agent == "unknown", "empty agent should become 'unknown'")
}

@(test)
test_consumption_log_op :: proc(t: ^testing.T) {
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
		registry = make([dynamic]Registry_Entry),
		slots    = make(map[string]^Shard_Slot),
		event_queue = make(Event_Queue),
	}

	_record_consumption(&node, "agent-1", "notes", "read")
	_record_consumption(&node, "agent-2", "todos", "write")
	_record_consumption(&node, "agent-1", "notes", "query")

	// Test unfiltered
	result := _op_consumption_log(&node, Request{limit = 10})
	testing.expect(t, strings.contains(result, "status: ok"), "consumption_log should succeed")
	testing.expect(t, strings.contains(result, "record_count: 3"), "should have 3 records")

	// Test filtered by shard
	result2 := _op_consumption_log(&node, Request{name = "notes", limit = 10})
	testing.expect(t, strings.contains(result2, "record_count: 2"), "should have 2 records for notes")

	// Test filtered by agent
	result3 := _op_consumption_log(&node, Request{agent = "agent-2", limit = 10})
	testing.expect(t, strings.contains(result3, "record_count: 1"), "should have 1 record for agent-2")
}

@(test)
test_needs_attention_empty :: proc(t: ^testing.T) {
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
		registry = make([dynamic]Registry_Entry),
		slots    = make(map[string]^Shard_Slot),
		event_queue = make(Event_Queue),
	}

	// No unprocessed = no attention needed
	testing.expect(t, !_shard_needs_attention(&node, "notes", 0), "0 unprocessed should not need attention")

	// Below threshold = no attention needed
	testing.expect(t, !_shard_needs_attention(&node, "notes", 2), "2 unprocessed (below threshold) should not need attention")
}

@(test)
test_needs_attention_unvisited :: proc(t: ^testing.T) {
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
		registry = make([dynamic]Registry_Entry),
		slots    = make(map[string]^Shard_Slot),
		event_queue = make(Event_Queue),
	}

	// 5 unprocessed, no visits = needs attention
	testing.expect(t, _shard_needs_attention(&node, "notes", 5), "unvisited shard with 5 unprocessed should need attention")

	// Record a visit
	_record_consumption(&node, "agent-1", "notes", "read")

	// Now it should NOT need attention (recently visited)
	testing.expect(t, !_shard_needs_attention(&node, "notes", 5), "recently visited shard should not need attention")
}

@(test)
test_consumption_dispatch :: proc(t: ^testing.T) {
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
		registry = make([dynamic]Registry_Entry),
		slots    = make(map[string]^Shard_Slot),
		event_queue = make(Event_Queue),
	}

	// Test that consumption_log op routes through daemon_dispatch
	result := dispatch(&node, "---\nop: consumption_log\n---\n")
	testing.expect(t, strings.contains(result, "status: ok"), "consumption_log op should succeed via dispatch")
}
