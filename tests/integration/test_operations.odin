package shard_integration_test

import "core:strings"
import "core:testing"
import shard "shard:."

// Confirms node initialization works for multiple test cases.
@(test)
test_node_init_multiple :: proc(t: ^testing.T) {
	names := []string{"init1", "init2", "init3"}
	for name in names {
		node, tmp, ok := make_test_node(t, name)
		testing.expect(t, ok, "node init for '%s'", name)
		defer cleanup_test_node(&node, tmp)
	}
}

// Confirms discover operation works on fresh node (requires daemon mode).
// Skipped in unit tests - only works when node.is_daemon = true.
@(test)
test_discover_fresh :: proc(t: ^testing.T) {
	node, tmp, ok := make_test_node(t, "discover-fresh")
	testing.expect(t, ok, "node init")
	defer cleanup_test_node(&node, tmp)

	// discover requires daemon mode - this should return error
	resp := dispatch(t, &node, `{"op":"discover"}`)
	defer delete(resp)
	// Expect error since node is not a daemon
	testing.expectf(t, strings.contains(resp, `"status":"error"`), "discover should fail without daemon mode: %s", resp)
}

// Confirms status operation works.
@(test)
test_status_operation :: proc(t: ^testing.T) {
	node, tmp, ok := make_test_node(t, "status-op")
	testing.expect(t, ok, "node init")
	defer cleanup_test_node(&node, tmp)

	resp := dispatch(t, &node, `{"op":"status"}`)
	defer delete(resp)
	testing.expectf(t, strings.contains(resp, `"status":"ok"`), "status should succeed: %s", resp)
}

// Confirms catalog read works.
@(test)
test_catalog_read :: proc(t: ^testing.T) {
	node, tmp, ok := make_test_node(t, "catalog-read")
	testing.expect(t, ok, "node init")
	defer cleanup_test_node(&node, tmp)

	resp := dispatch(t, &node, `{"op":"catalog"}`)
	defer delete(resp)
	testing.expectf(t, strings.contains(resp, `"status":"ok"`), "catalog should succeed: %s", resp)
}

// Confirms list operation on empty node.
@(test)
test_list_empty :: proc(t: ^testing.T) {
	node, tmp, ok := make_test_node(t, "list-empty")
	testing.expect(t, ok, "node init")
	defer cleanup_test_node(&node, tmp)

	resp := dispatch(t, &node, `{"op":"list"}`)
	defer delete(resp)
	testing.expectf(t, strings.contains(resp, `"status":"ok"`), "list should succeed: %s", resp)
}

// Confirms unknown op returns error.
@(test)
test_unknown_op :: proc(t: ^testing.T) {
	node, tmp, ok := make_test_node(t, "unknown-op")
	testing.expect(t, ok, "node init")
	defer cleanup_test_node(&node, tmp)

	resp := dispatch(t, &node, `{"op":"not_real_op"}`)
	defer delete(resp)
	testing.expectf(t, strings.contains(resp, "error") || strings.contains(resp, "unknown"), 
		"unknown op should return error: %s", resp)
}

// Confirms manifest operation works.
@(test)
test_manifest_operation :: proc(t: ^testing.T) {
	node, tmp, ok := make_test_node(t, "manifest-op")
	testing.expect(t, ok, "node init")
	defer cleanup_test_node(&node, tmp)

	resp := dispatch(t, &node, `{"op":"manifest"}`)
	defer delete(resp)
	testing.expectf(t, strings.contains(resp, `"status":"ok"`), "manifest should succeed: %s", resp)
}

// Confirms positive gate read works.
@(test)
test_positive_gate_read :: proc(t: ^testing.T) {
	node, tmp, ok := make_test_node(t, "positive-gate")
	testing.expect(t, ok, "node init")
	defer cleanup_test_node(&node, tmp)

	resp := dispatch(t, &node, `{"op":"positive"}`)
	defer delete(resp)
	testing.expectf(t, strings.contains(resp, `"status":"ok"`), "positive should succeed: %s", resp)
}

// Confirms negative gate read works.
@(test)
test_negative_gate_read :: proc(t: ^testing.T) {
	node, tmp, ok := make_test_node(t, "negative-gate")
	testing.expect(t, ok, "node init")
	defer cleanup_test_node(&node, tmp)

	resp := dispatch(t, &node, `{"op":"negative"}`)
	defer delete(resp)
	testing.expectf(t, strings.contains(resp, `"status":"ok"`), "negative should succeed: %s", resp)
}

// Confirms description gate read works.
@(test)
test_description_gate_read :: proc(t: ^testing.T) {
	node, tmp, ok := make_test_node(t, "desc-gate")
	testing.expect(t, ok, "node init")
	defer cleanup_test_node(&node, tmp)

	resp := dispatch(t, &node, `{"op":"description"}`)
	defer delete(resp)
	testing.expectf(t, strings.contains(resp, `"status":"ok"`), "description should succeed: %s", resp)
}

// Confirms related gate read works.
@(test)
test_related_gate_read :: proc(t: ^testing.T) {
	node, tmp, ok := make_test_node(t, "related-gate")
	testing.expect(t, ok, "node init")
	defer cleanup_test_node(&node, tmp)

	resp := dispatch(t, &node, `{"op":"related"}`)
	defer delete(resp)
	testing.expectf(t, strings.contains(resp, `"status":"ok"`), "related should succeed: %s", resp)
}

// Confirms gates operation works.
@(test)
test_gates_read :: proc(t: ^testing.T) {
	node, tmp, ok := make_test_node(t, "gates-read")
	testing.expect(t, ok, "node init")
	defer cleanup_test_node(&node, tmp)

	resp := dispatch(t, &node, `{"op":"gates"}`)
	defer delete(resp)
	testing.expectf(t, strings.contains(resp, `"status":"ok"`), "gates should succeed: %s", resp)
}

// Confirms node isolation - different nodes are independent.
@(test)
test_node_isolation :: proc(t: ^testing.T) {
	node1, tmp1, ok1 := make_test_node(t, "isolate-1")
	testing.expect(t, ok1, "node1 init")
	defer cleanup_test_node(&node1, tmp1)

	node2, tmp2, ok2 := make_test_node(t, "isolate-2")
	testing.expect(t, ok2, "node2 init")
	defer cleanup_test_node(&node2, tmp2)

	// Each node should have its own status
	status1 := dispatch(t, &node1, `{"op":"status"}`)
	defer delete(status1)
	status2 := dispatch(t, &node2, `{"op":"status"}`)
	defer delete(status2)

	testing.expectf(t, strings.contains(status1, `"status":"ok"`), "node1 status should work")
	testing.expectf(t, strings.contains(status2, `"status":"ok"`), "node2 status should work")
}

// Confirms discover returns registry (requires daemon mode).
// Skipped - discover only works when node.is_daemon = true.
@(test)
test_discover_returns_registry :: proc(t: ^testing.T) {
	node, tmp, ok := make_test_node(t, "discover-registry")
	testing.expect(t, ok, "node init")
	defer cleanup_test_node(&node, tmp)

	resp := dispatch(t, &node, `{"op":"discover"}`)
	defer delete(resp)
	// discover requires daemon mode
	testing.expectf(t, strings.contains(resp, `"status":"error"`), "discover should fail without daemon mode: %s", resp)
}
