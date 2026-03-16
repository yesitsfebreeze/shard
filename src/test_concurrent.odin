package shard

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:testing"

// =============================================================================
// Concurrent stress test — validates multi-agent write safety
// =============================================================================
//
// Creates an in-process daemon node with a test shard slot, then spawns
// N threads that each write thoughts through dispatch() with the node mutex.
// Verifies all writes land, no data loss, and transaction isolation holds.
//

STRESS_AGENT_COUNT :: 10
STRESS_WRITES_EACH :: 5

// _make_test_key_hex converts a Master_Key to a 64-char hex string.
@(private)
_make_test_key_hex :: proc(master: Master_Key) -> string {
	key_full: [64]u8
	for i in 0 ..< 32 {
		hi := master[i] >> 4
		lo := master[i] & 0x0F
		key_full[i*2]   = hi < 10 ? '0' + hi : 'a' + hi - 10
		key_full[i*2+1] = lo < 10 ? '0' + lo : 'a' + lo - 10
	}
	return strings.clone(string(key_full[:]))
}

// _make_test_slot creates a shard slot with a real temp file for flush.
@(private)
_make_test_slot :: proc(name: string, path: string, master: Master_Key) -> ^Shard_Slot {
	slot := new(Shard_Slot)
	slot.name      = name
	slot.data_path = path
	slot.loaded    = true
	slot.key_set   = true
	slot.master    = master
	slot.blob = Blob{
		path        = path,
		master      = master,
		processed   = make([dynamic]Thought),
		unprocessed = make([dynamic]Thought),
		description = make([dynamic]string),
		positive    = make([dynamic]string),
		negative    = make([dynamic]string),
		related     = make([dynamic]string),
	}
	slot.index = make([dynamic]Search_Entry)
	return slot
}

// _make_test_daemon_node creates a daemon node for testing.
@(private)
_make_test_daemon_node :: proc() -> Node {
	return Node{
		name        = DAEMON_NAME,
		is_daemon   = true,
		running     = true,
		registry    = make([dynamic]Registry_Entry),
		slots       = make(map[string]^Shard_Slot),
		event_queue = make(Event_Queue),
		blob = Blob{
			processed   = make([dynamic]Thought),
			unprocessed = make([dynamic]Thought),
			description = make([dynamic]string),
			positive    = make([dynamic]string),
			negative    = make([dynamic]string),
			related     = make([dynamic]string),
		},
		index = make([dynamic]Search_Entry),
	}
}

// =============================================================================
// Stress test: N agents write concurrently, all writes must land
// =============================================================================

Stress_Thread_Data :: struct {
	node:       ^Node,
	agent_id:   int,
	key_hex:    string,
	success:    int,
	failed:     int,
}

@(test)
test_stress_concurrent_writes :: proc(t: ^testing.T) {
	master: Master_Key
	master[0] = 0xCC; master[1] = 0xDD
	key_str := _make_test_key_hex(master)
	defer delete(key_str)

	test_path := ".shards/_stress_test.shard"
	slot := _make_test_slot("stress-test", test_path, master)
	node := _make_test_daemon_node()
	node.slots["stress-test"] = slot
	append(&node.registry, Registry_Entry{
		name      = "stress-test",
		data_path = test_path,
		catalog   = Catalog{name = "stress-test"},
	})

	// Spawn threads
	thread_data := make([]Stress_Thread_Data, STRESS_AGENT_COUNT)
	threads := make([]^thread.Thread, STRESS_AGENT_COUNT)

	for i in 0 ..< STRESS_AGENT_COUNT {
		thread_data[i] = Stress_Thread_Data{
			node     = &node,
			agent_id = i,
			key_hex  = key_str,
		}
		threads[i] = thread.create(_stress_writer_proc)
		if threads[i] != nil {
			threads[i].data = &thread_data[i]
			thread.start(threads[i])
		}
	}

	// Wait for all threads
	for i in 0 ..< STRESS_AGENT_COUNT {
		if threads[i] != nil {
			thread.join(threads[i])
			thread.destroy(threads[i])
		}
	}

	// Count results
	total_success := 0
	total_failed := 0
	for i in 0 ..< STRESS_AGENT_COUNT {
		total_success += thread_data[i].success
		total_failed  += thread_data[i].failed
	}

	// Verify: total thoughts in the shard should equal total successful writes
	thought_count := len(slot.blob.processed) + len(slot.blob.unprocessed)
	expected := STRESS_AGENT_COUNT * STRESS_WRITES_EACH

	testing.expectf(t, total_success == expected,
		"all writes must succeed: got %d/%d (failed: %d)", total_success, expected, total_failed)
	testing.expectf(t, thought_count == expected,
		"shard must contain all thoughts: got %d, expected %d", thought_count, expected)

	// Cleanup
	delete(thread_data)
	delete(threads)
	os.remove(test_path)
}

@(private)
_stress_writer_proc :: proc(thr: ^thread.Thread) {
	data := cast(^Stress_Thread_Data)thr.data
	if data == nil do return

	for w in 0 ..< STRESS_WRITES_EACH {
		desc := fmt.tprintf("agent-%d-write-%d", data.agent_id, w)
		msg := fmt.tprintf(
			"---\nop: write\nname: stress-test\nkey: %s\ndescription: %s\nagent: agent-%d\n---\nContent from agent %d write %d\n",
			data.key_hex, desc, data.agent_id, data.agent_id, w,
		)

		sync.lock(&data.node.mu)
		result := dispatch(data.node, msg)
		sync.unlock(&data.node.mu)

		if strings.contains(result, "status: ok") {
			data.success += 1
		} else {
			data.failed += 1
		}
	}
}

// =============================================================================
// Transaction isolation test — locks prevent concurrent mutation,
// writes queue during lock and drain on commit
// =============================================================================

@(test)
test_transaction_isolation :: proc(t: ^testing.T) {
	master: Master_Key
	master[0] = 0xEE; master[1] = 0xFF
	key_str := _make_test_key_hex(master)
	defer delete(key_str)

	test_path := ".shards/_txn_test.shard"
	slot := _make_test_slot("txn-test", test_path, master)
	node := _make_test_daemon_node()
	node.slots["txn-test"] = slot
	append(&node.registry, Registry_Entry{
		name      = "txn-test",
		data_path = test_path,
		catalog   = Catalog{name = "txn-test"},
	})

	// Agent A locks the shard
	lock_msg := fmt.tprintf(
		"---\nop: transaction\nname: txn-test\nkey: %s\nagent: agent-A\nttl: 10\n---\n", key_str)

	sync.lock(&node.mu)
	lock_result := dispatch(&node, lock_msg)
	sync.unlock(&node.mu)

	testing.expect(t, strings.contains(lock_result, "lock_id:"), "transaction must return lock_id")

	// Extract lock_id
	lock_id := ""
	lock_result_copy := strings.clone(lock_result)
	defer delete(lock_result_copy)
	for line in strings.split_lines_iterator(&lock_result_copy) {
		trimmed := strings.trim_space(line)
		if strings.has_prefix(trimmed, "lock_id:") {
			lock_id = strings.clone(strings.trim_space(trimmed[len("lock_id:"):]))
			break
		}
	}
	defer delete(lock_id)
	testing.expect(t, lock_id != "", "must extract lock_id")

	// Agent B tries to write — should be queued
	write_msg := fmt.tprintf(
		"---\nop: write\nname: txn-test\nkey: %s\ndescription: agent B write\nagent: agent-B\n---\nQueued content\n", key_str)

	sync.lock(&node.mu)
	write_result := dispatch(&node, write_msg)
	sync.unlock(&node.mu)

	testing.expect(t, strings.contains(write_result, "queued"),
		"write during lock must be queued")

	// Verify: shard has 0 thoughts (nothing committed yet)
	pre_count := len(slot.blob.processed) + len(slot.blob.unprocessed)
	testing.expectf(t, pre_count == 0,
		"shard must have 0 thoughts before commit, got %d", pre_count)

	// Agent A commits
	commit_msg := fmt.tprintf(
		"---\nop: commit\nname: txn-test\nkey: %s\nlock_id: %s\ndescription: agent A commit\nagent: agent-A\n---\nCommit content\n", key_str, lock_id)

	sync.lock(&node.mu)
	commit_result := dispatch(&node, commit_msg)
	sync.unlock(&node.mu)

	testing.expect(t, strings.contains(commit_result, "status: ok"), "commit must succeed")

	// Verify: shard has 2 thoughts (Agent A commit + Agent B drained)
	post_count := len(slot.blob.processed) + len(slot.blob.unprocessed)
	testing.expectf(t, post_count == 2,
		"shard must have 2 thoughts after commit+drain, got %d", post_count)

	// Cleanup
	os.remove(test_path)
}
