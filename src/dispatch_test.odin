package shard

import "core:strings"
import "core:testing"

// =============================================================================
// Dispatch tests — op routing
// =============================================================================

@(test)
test_dispatch_unknown_op :: proc(t: ^testing.T) {
	node := Node{
		blob = Blob{
			processed   = make([dynamic]Thought),
			unprocessed = make([dynamic]Thought),
			description = make([dynamic]string),
			positive    = make([dynamic]string),
			negative    = make([dynamic]string),
			related     = make([dynamic]string),
		},
	}
	result := dispatch(&node, "---\nop: nonexistent\n---\n")
	testing.expect(t, strings.contains(result, "unknown op"), "unknown op must return error")
}

@(test)
test_dispatch_list_empty :: proc(t: ^testing.T) {
	node := Node{
		blob = Blob{
			processed   = make([dynamic]Thought),
			unprocessed = make([dynamic]Thought),
			description = make([dynamic]string),
			positive    = make([dynamic]string),
			negative    = make([dynamic]string),
			related     = make([dynamic]string),
		},
	}
	result := dispatch(&node, "---\nop: list\n---\n")
	testing.expect(t, strings.contains(result, "status: ok"), "list on empty blob must succeed")
}

@(test)
test_dispatch_status :: proc(t: ^testing.T) {
	node := Node{
		name = "test-node",
		blob = Blob{
			processed   = make([dynamic]Thought),
			unprocessed = make([dynamic]Thought),
			description = make([dynamic]string),
			positive    = make([dynamic]string),
			negative    = make([dynamic]string),
			related     = make([dynamic]string),
		},
	}
	result := dispatch(&node, "---\nop: status\n---\n")
	testing.expect(t, strings.contains(result, "node_name: test-node"), "status must return node name")
}
