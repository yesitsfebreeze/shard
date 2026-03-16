package shard

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"

// =============================================================================
// Fleet dispatch tests — validates parallel multi-shard operations
// =============================================================================

// _build_fleet_msg constructs a fleet YAML message with the given JSON task body.
@(private)
_build_fleet_msg :: proc(json_body: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "---\nop: fleet\n---\n")
	strings.write_string(&b, json_body)
	return strings.to_string(b)
}

// _build_fleet_task_json constructs a single JSON task object.
@(private)
_build_fleet_task_json :: proc(name, op, key: string, description: string = "", content: string = "", agent: string = "") -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `"name":"%s","op":"%s","key":"%s"`, name, op, key)
	if description != "" do fmt.sbprintf(&b, `,"description":"%s"`, description)
	if content != "" do fmt.sbprintf(&b, `,"content":"%s"`, content)
	if agent != "" do fmt.sbprintf(&b, `,"agent":"%s"`, agent)
	return strings.to_string(b)
}

// test_fleet_parallel_different_shards creates two shard slots and dispatches
// write ops to both via fleet. Both writes must succeed.
@(test)
test_fleet_parallel_different_shards :: proc(t: ^testing.T) {
	master: Master_Key
	master[0] = 0xA1; master[1] = 0xB2
	key_str := _make_test_key_hex(master)
	defer delete(key_str)

	path_a := ".shards/_fleet_a.shard"
	path_b := ".shards/_fleet_b.shard"
	slot_a := _make_test_slot("fleet-a", path_a, master)
	slot_b := _make_test_slot("fleet-b", path_b, master)

	node := _make_test_daemon_node()
	node.slots["fleet-a"] = slot_a
	node.slots["fleet-b"] = slot_b
	append(&node.registry, Registry_Entry{
		name      = "fleet-a",
		data_path = path_a,
		catalog   = Catalog{name = "fleet-a"},
	})
	append(&node.registry, Registry_Entry{
		name      = "fleet-b",
		data_path = path_b,
		catalog   = Catalog{name = "fleet-b"},
	})

	// Build fleet JSON body using builder (not fmt.tprintf which misinterprets braces)
	task_a := _build_fleet_task_json("fleet-a", "write", key_str, "thought for shard A", "content A", "test")
	task_b := _build_fleet_task_json("fleet-b", "write", key_str, "thought for shard B", "content B", "test")
	json_body := strings.concatenate({"[{", task_a, "},{", task_b, "}]"}, context.temp_allocator)
	fleet_msg := _build_fleet_msg(json_body)

	sync.lock(&node.mu)
	result := dispatch(&node, fleet_msg)
	sync.unlock(&node.mu)

	testing.expectf(t, strings.contains(result, "status: ok"),
		"fleet dispatch must return status: ok")
	testing.expect(t, strings.contains(result, "task_count: 2"),
		"fleet must report 2 tasks")

	// Verify: each shard has 1 thought
	count_a := len(slot_a.blob.processed) + len(slot_a.blob.unprocessed)
	count_b := len(slot_b.blob.processed) + len(slot_b.blob.unprocessed)
	testing.expectf(t, count_a == 1,
		"fleet-a must have 1 thought, got %d", count_a)
	testing.expectf(t, count_b == 1,
		"fleet-b must have 1 thought, got %d", count_b)

	// Cleanup
	os.remove(path_a)
	os.remove(path_b)
}

// test_fleet_same_shard_serialized dispatches 3 write ops to the same shard
// via fleet. All 3 writes must succeed (serialized by slot.mu).
@(test)
test_fleet_same_shard_serialized :: proc(t: ^testing.T) {
	master: Master_Key
	master[0] = 0xC3; master[1] = 0xD4
	key_str := _make_test_key_hex(master)
	defer delete(key_str)

	test_path := ".shards/_fleet_serial.shard"
	slot := _make_test_slot("fleet-serial", test_path, master)

	node := _make_test_daemon_node()
	node.slots["fleet-serial"] = slot
	append(&node.registry, Registry_Entry{
		name      = "fleet-serial",
		data_path = test_path,
		catalog   = Catalog{name = "fleet-serial"},
	})

	// Build fleet message with 3 tasks targeting the same shard
	t1 := _build_fleet_task_json("fleet-serial", "write", key_str, "write 1", "body 1", "test")
	t2 := _build_fleet_task_json("fleet-serial", "write", key_str, "write 2", "body 2", "test")
	t3 := _build_fleet_task_json("fleet-serial", "write", key_str, "write 3", "body 3", "test")
	json_body := strings.concatenate({"[{", t1, "},{", t2, "},{", t3, "}]"}, context.temp_allocator)
	fleet_msg := _build_fleet_msg(json_body)

	sync.lock(&node.mu)
	result := dispatch(&node, fleet_msg)
	sync.unlock(&node.mu)

	testing.expectf(t, strings.contains(result, "status: ok"),
		"fleet dispatch must return status: ok")
	testing.expect(t, strings.contains(result, "task_count: 3"),
		"fleet must report 3 tasks")

	// Verify: shard has 3 thoughts
	count := len(slot.blob.processed) + len(slot.blob.unprocessed)
	testing.expectf(t, count == 3,
		"fleet-serial must have 3 thoughts, got %d", count)

	// Cleanup
	os.remove(test_path)
}

// test_fleet_error_aggregation dispatches one valid and one invalid task.
// The valid task should succeed; the invalid one should show an error status.
@(test)
test_fleet_error_aggregation :: proc(t: ^testing.T) {
	master: Master_Key
	master[0] = 0xE5; master[1] = 0xF6
	key_str := _make_test_key_hex(master)
	defer delete(key_str)

	test_path := ".shards/_fleet_err.shard"
	slot := _make_test_slot("fleet-err", test_path, master)

	node := _make_test_daemon_node()
	node.slots["fleet-err"] = slot
	append(&node.registry, Registry_Entry{
		name      = "fleet-err",
		data_path = test_path,
		catalog   = Catalog{name = "fleet-err"},
	})

	// Task 1: valid write. Task 2: write to a non-existent shard (should error).
	good_task := _build_fleet_task_json("fleet-err", "write", key_str, "valid write", "ok", "test")
	bad_task := _build_fleet_task_json("nonexistent", "write", key_str, "bad write", "fail", "test")
	json_body := strings.concatenate({"[{", good_task, "},{", bad_task, "}]"}, context.temp_allocator)
	fleet_msg := _build_fleet_msg(json_body)

	sync.lock(&node.mu)
	result := dispatch(&node, fleet_msg)
	sync.unlock(&node.mu)

	testing.expectf(t, strings.contains(result, "status: ok"),
		"fleet dispatch must return status: ok (overall)")
	testing.expect(t, strings.contains(result, "task_count: 2"),
		"fleet must report 2 tasks")

	// The valid write should have succeeded
	count := len(slot.blob.processed) + len(slot.blob.unprocessed)
	testing.expectf(t, count == 1,
		"fleet-err must have 1 thought from valid write, got %d", count)

	// Cleanup
	os.remove(test_path)
}

// test_fleet_empty_tasks verifies that fleet op rejects empty task arrays.
@(test)
test_fleet_empty_tasks :: proc(t: ^testing.T) {
	node := _make_test_daemon_node()

	fleet_msg := _build_fleet_msg("[]")

	sync.lock(&node.mu)
	result := dispatch(&node, fleet_msg)
	sync.unlock(&node.mu)

	testing.expect(t, strings.contains(result, "status: error"),
		"fleet with empty tasks must return error")
	testing.expect(t, strings.contains(result, "empty"),
		"error must mention empty tasks")
}

// test_fleet_invalid_json verifies that fleet op rejects invalid JSON.
@(test)
test_fleet_invalid_json :: proc(t: ^testing.T) {
	node := _make_test_daemon_node()

	fleet_msg := _build_fleet_msg("not json")

	sync.lock(&node.mu)
	result := dispatch(&node, fleet_msg)
	sync.unlock(&node.mu)

	testing.expect(t, strings.contains(result, "status: error"),
		"fleet with invalid JSON must return error")
}
