package shard_integration_test

import "core:fmt"
import "core:os"
import os2 "core:os/os2"
import "core:testing"
import shard "shard:."

// make_test_node creates an isolated in-process Node backed by a temp directory.
// The node uses a zero Master_Key (no encryption). Call cleanup_test_node when done.
// Use a unique name per test to avoid temp-dir collisions under parallel runs.
make_test_node :: proc(
	t: ^testing.T,
	name := "test",
) -> (
	node: shard.Node,
	tmp: string,
	ok: bool,
) {
	base := os.get_env("TEMP")
	if base == "" do base = "/tmp"
	tmp = fmt.aprintf("%s/shard-test-%s", base, name)
	
	// Clean up any existing temp dir first (for retried tests)
	os2.remove_all(tmp)
	err := os.make_directory(tmp)
	if err != os.ERROR_NONE {
		testing.expectf(t, false, "make_test_node: could not create temp dir %s: %v", tmp, err)
		return
	}
	
	data_path := fmt.aprintf("%s/node.shard", tmp)
	defer delete(data_path) // node_init_test clones what it needs

	master: shard.Master_Key // zero key — no encrypted content
	node, ok = shard.node_init_test(name, master, data_path, 0)
	if !ok {
		testing.expectf(t, false, "make_test_node: node_init_test failed for path %s", data_path)
	}
	return
}

// cleanup_test_node flushes the node, frees all resources, and removes the temp directory.
cleanup_test_node :: proc(node: ^shard.Node, tmp: string) {
	shard.daemon_flush_all(node)
	// Skip blob_flush in tests — fresh test nodes have no backing file
	// and flush would fail when trying to write to non-existent temp path
	// shard.blob_flush(&node.blob)
	shard.node_destroy(node)
	// Drain logger message queue to avoid false-positive leak reports
	pending := shard.drain_messages()
	for i in 0 ..< pending.count {
		delete(pending.messages[i])
	}
	os2.remove_all(tmp) // recursively removes the temp dir and all contents
	delete(tmp)
}

// dispatch sends a JSON request through the protocol dispatch (not daemon_dispatch).
// This handles all ops including status, catalog, list, gates, etc.
// NOTE: The returned string is heap-allocated; caller should delete it when done.
dispatch :: proc(t: ^testing.T, node: ^shard.Node, json_str: string) -> string {
	resp := shard.dispatch(node, json_str)
	if resp == "" {
		testing.expectf(t, false, "dispatch: protocol.dispatch returned empty for input:\n%s", json_str)
		return ""
	}
	return resp
}
