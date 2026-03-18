package shard_integration_test

import "core:strings"
import "core:testing"

// Smoke test — creates a test node and confirms it initialises without error.
@(test)
test_node_init :: proc(t: ^testing.T) {
	node, tmp, ok := make_test_node(t)
	testing.expect(t, ok, "node_init_test must succeed on a fresh temp dir")
	defer cleanup_test_node(&node, tmp)
}

// Smoke test — confirms a minimal dispatch round-trip works.
@(test)
test_discover_empty :: proc(t: ^testing.T) {
	node, tmp, ok := make_test_node(t, "discover")
	testing.expect(t, ok, "node init")
	defer cleanup_test_node(&node, tmp)

	resp := dispatch(t, &node, "---\nop: discover\n---\n")
	defer delete(resp)
	testing.expect(t, strings.contains(resp, `"status"`), resp)
}
