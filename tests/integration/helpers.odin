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
	os.make_directory(tmp)
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
	shard.blob_flush(&node.blob)
	shard.node_destroy(node)
	// Drain logger message queue to avoid false-positive leak reports
	pending := shard.drain_messages()
	for i in 0 ..< pending.count {
		delete(pending.messages[i])
	}
	os2.remove_all(tmp) // recursively removes the temp dir and all contents
	delete(tmp)
}

// dispatch parses a YAML request string and calls daemon_dispatch in-process.
// Fails the test if parsing fails. Returns the raw response string.
// NOTE: The returned string is heap-allocated; caller should delete it when done.
dispatch :: proc(t: ^testing.T, node: ^shard.Node, yaml: string) -> string {
	req, ok := shard.md_parse_request(yaml)
	if !ok {
		testing.expectf(t, false, "dispatch: md_parse_request failed for input:\n%s", yaml)
		return ""
	}
	defer shard.request_destroy(&req)
	resp, _ := shard.daemon_dispatch(node, req)
	return resp
}
