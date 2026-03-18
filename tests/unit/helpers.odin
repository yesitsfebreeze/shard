package shard_unit_test

import shard "shard:."

// drain_logger frees all queued log messages from the shard logger.
// Call with defer at the end of each test to prevent false-positive leak reports.
drain_logger :: proc() {
	pending := shard.drain_messages()
	for i in 0 ..< pending.count {
		delete(pending.messages[i])
	}
}
