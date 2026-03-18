package shard_unit_test

import "core:testing"
import shard "shard:."

// =============================================================================
// Tests for HTTP MCP transport — session store and session ID generation
// =============================================================================

@(test)
test_session_new_id_is_32_hex :: proc(t: ^testing.T) {
	defer drain_logger()
	id := shard._session_new_id()
	defer delete(id)
	testing.expect_value(t, len(id), 32)
	for ch in id {
		testing.expect(
			t,
			(ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f'),
			"session ID chars should all be lowercase hex",
		)
	}
}

@(test)
test_session_ids_are_unique :: proc(t: ^testing.T) {
	defer drain_logger()
	id1 := shard._session_new_id()
	id2 := shard._session_new_id()
	defer delete(id1)
	defer delete(id2)
	testing.expect(t, id1 != id2, "two generated session IDs should differ")
}

@(test)
test_session_push_missing_returns_false :: proc(t: ^testing.T) {
	defer drain_logger()
	store: shard.Session_Store
	shard._session_store_init(&store)
	defer shard._session_store_destroy(&store)

	ok := shard._session_push(&store, "nonexistent-id", "data")
	testing.expect(t, !ok, "push to nonexistent session should return false")
}

@(test)
test_session_register_and_remove :: proc(t: ^testing.T) {
	defer drain_logger()
	store: shard.Session_Store
	shard._session_store_init(&store)
	defer shard._session_store_destroy(&store)

	// Register a session (conn is zero — we won't actually send through it)
	session       := new(shard.HTTP_Session)
	session.id     = "test-abc123"
	session.alive  = true
	shard._session_register(&store, session)

	// Remove it
	shard._session_remove(&store, "test-abc123")

	// Push should now fail cleanly
	ok := shard._session_push(&store, "test-abc123", "hello")
	testing.expect(t, !ok, "push after remove should return false")
}
