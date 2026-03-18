package shard_unit_test

import "core:os"
import "core:testing"
import shard "shard:."

// Confirms blob_put and blob_get work correctly.
@(test)
test_blob_put_get :: proc(t: ^testing.T) {
	defer drain_logger()
	b := shard.Blob {
		path        = "", // in-memory blob
		master      = {},
		description = make([dynamic]string),
		positive    = make([dynamic]string),
		negative    = make([dynamic]string),
		related     = make([dynamic]string),
	}
	defer {
		shard.blob_destroy(&b)
	}

	master: shard.Master_Key
	id := shard.new_thought_id()
	pt := shard.Thought_Plaintext {
		description = "test thought",
		content     = "content here",
	}
	thought, ok := shard.thought_create(master, id, pt)
	testing.expect(t, ok, "thought_create should succeed")

	// Put returns true for in-memory blobs
	put_ok := shard.blob_put(&b, thought)
	testing.expect(t, put_ok, "blob_put should succeed for in-memory blob")

	// Get should return the thought
	retrieved, found := shard.blob_get(&b, id)
	testing.expect(t, found, "blob_get should find the thought")
	testing.expect(t, retrieved.id == id, "retrieved id should match")

	// Decrypt to verify content
	decrypted, err := shard.thought_decrypt(retrieved, master)
	testing.expect(t, err == .None, "decrypt should succeed")
	testing.expect(t, decrypted.description == pt.description, "description should match")
}

// Confirms blob_put updates existing thoughts.
@(test)
test_blob_put_update :: proc(t: ^testing.T) {
	defer drain_logger()
	b := shard.Blob {
		path        = "",
		master      = {},
		description = make([dynamic]string),
		positive    = make([dynamic]string),
		negative    = make([dynamic]string),
		related     = make([dynamic]string),
	}
	defer shard.blob_destroy(&b)

	master: shard.Master_Key
	id := shard.new_thought_id()

	// Create first thought
	pt1 := shard.Thought_Plaintext{description = "v1", content = "version 1"}
	t1, _ := shard.thought_create(master, id, pt1)
	shard.blob_put(&b, t1)

	// Verify initial count
	ids1 := shard.blob_ids(&b)
	testing.expect(t, len(ids1) == 1, "should have 1 thought initially")

	// Update with new thought using same ID
	pt2 := shard.Thought_Plaintext{description = "v2", content = "version 2"}
	t2, _ := shard.thought_create(master, id, pt2)
	shard.blob_put(&b, t2)

	// Should still have 1 thought (updated, not added)
	ids2 := shard.blob_ids(&b)
	testing.expect(t, len(ids2) == 1, "should still have 1 thought after update")

	// Verify content was updated
	retrieved, _ := shard.blob_get(&b, id)
	decrypted, _ := shard.thought_decrypt(retrieved, master)
	testing.expect(t, decrypted.description == "v2", "description should be updated to v2")
}

// Confirms blob_remove works correctly.
@(test)
test_blob_remove :: proc(t: ^testing.T) {
	defer drain_logger()
	b := shard.Blob {
		path        = "",
		master      = {},
		description = make([dynamic]string),
		positive    = make([dynamic]string),
		negative    = make([dynamic]string),
		related     = make([dynamic]string),
	}
	defer shard.blob_destroy(&b)

	master: shard.Master_Key
	id1 := shard.new_thought_id()
	id2 := shard.new_thought_id()

	// Add two thoughts
	t1, _ := shard.thought_create(master, id1, shard.Thought_Plaintext{description = "t1", content = ""})
	t2, _ := shard.thought_create(master, id2, shard.Thought_Plaintext{description = "t2", content = ""})
	shard.blob_put(&b, t1)
	shard.blob_put(&b, t2)

	ids := shard.blob_ids(&b)
	testing.expect(t, len(ids) == 2, "should have 2 thoughts")

	// Remove one
	removed := shard.blob_remove(&b, id1)
	testing.expect(t, removed, "blob_remove should return true")

	// Should only find t2 now
	_, found1 := shard.blob_get(&b, id1)
	testing.expect(t, !found1, "removed thought should not be found")

	_, found2 := shard.blob_get(&b, id2)
	testing.expect(t, found2, "remaining thought should still be found")

	ids2 := shard.blob_ids(&b)
	testing.expect(t, len(ids2) == 1, "should have 1 thought after removal")
}

// Confirms blob_ids returns all thought IDs.
@(test)
test_blob_ids :: proc(t: ^testing.T) {
	defer drain_logger()
	b := shard.Blob {
		path        = "",
		master      = {},
		description = make([dynamic]string),
		positive    = make([dynamic]string),
		negative    = make([dynamic]string),
		related     = make([dynamic]string),
	}
	defer shard.blob_destroy(&b)

	master: shard.Master_Key
	expected_ids := make([dynamic]shard.Thought_ID)

	// Add multiple thoughts
	for i := 0; i < 5; i += 1 {
		id := shard.new_thought_id()
		pt := shard.Thought_Plaintext {
			description = shard.id_to_hex(id),
			content     = "",
		}
		t, _ := shard.thought_create(master, id, pt)
		shard.blob_put(&b, t)
		append(&expected_ids, id)
	}

	ids := shard.blob_ids(&b)
	testing.expect(t, len(ids) == 5, "should have 5 ids")

	// Verify all expected IDs are present
	for eid in expected_ids {
		found := false
		for id in ids {
			if id == eid {
				found = true
				break
			}
		}
		testing.expect(t, found, "expected id should be in blob_ids result")
	}
}

// Confirms blob_compact moves thoughts between blocks.
@(test)
test_blob_compact :: proc(t: ^testing.T) {
	defer drain_logger()
	b := shard.Blob {
		path        = "",
		master      = {},
		description = make([dynamic]string),
		positive    = make([dynamic]string),
		negative    = make([dynamic]string),
		related     = make([dynamic]string),
	}
	defer shard.blob_destroy(&b)

	master: shard.Master_Key
	id := shard.new_thought_id()
	pt := shard.Thought_Plaintext{description = "compact test", content = "body"}
	thought, _ := shard.thought_create(master, id, pt)
	shard.blob_put(&b, thought)

	// Initially in unprocessed
	testing.expect(t, len(b.processed) == 0, "processed should be empty initially")
	testing.expect(t, len(b.unprocessed) == 1, "unprocessed should have 1 thought")

	// Compact moves it to processed
	moved := shard.blob_compact(&b, []shard.Thought_ID{id})
	testing.expect(t, moved == 1, "should have moved 1 thought")
	testing.expect(t, len(b.processed) == 1, "processed should have 1 thought now")
	testing.expect(t, len(b.unprocessed) == 0, "unprocessed should be empty")
}

// Confirms blob_compact handles unknown IDs gracefully.
@(test)
test_blob_compact_unknown_id :: proc(t: ^testing.T) {
	defer drain_logger()
	b := shard.Blob {
		path        = "",
		master      = {},
		description = make([dynamic]string),
		positive    = make([dynamic]string),
		negative    = make([dynamic]string),
		related     = make([dynamic]string),
	}
	defer shard.blob_destroy(&b)

	// Compact with non-existent ID should return 0
	unknown_id := shard.new_thought_id()
	moved := shard.blob_compact(&b, []shard.Thought_ID{unknown_id})
	testing.expect(t, moved == 0, "should return 0 for unknown id")
}

// Confirms empty blob is valid.
@(test)
test_blob_empty :: proc(t: ^testing.T) {
	defer drain_logger()
	b := shard.Blob {
		path        = "",
		master      = {},
		description = make([dynamic]string),
		positive    = make([dynamic]string),
		negative    = make([dynamic]string),
		related     = make([dynamic]string),
	}
	defer shard.blob_destroy(&b)

	testing.expect(t, len(b.processed) == 0, "empty blob processed should be empty")
	testing.expect(t, len(b.unprocessed) == 0, "empty blob unprocessed should be empty")

	ids := shard.blob_ids(&b)
	testing.expect(t, len(ids) == 0, "empty blob should have no ids")

	_, found := shard.blob_get(&b, shard.new_thought_id())
	testing.expect(t, !found, "getting from empty blob should return not found")
}

// Confirms catalog fields are preserved.
@(test)
test_blob_catalog :: proc(t: ^testing.T) {
	defer drain_logger()
	b := shard.Blob {
		path        = "",
		master      = {},
		description = make([dynamic]string),
		positive    = make([dynamic]string),
		negative    = make([dynamic]string),
		related     = make([dynamic]string),
	}
	// NOTE: catalog fields set via literals — blob_destroy would cause bad_free.
	// Dynamic arrays (description, positive, negative, related) are tracked and freed
	// by the tracking allocator when the test exits. String literals and []string
	// array literals are not heap-allocated and need no explicit free.

	b.catalog = shard.Catalog {
		name    = "test-shard",
		purpose = "testing catalog storage",
		tags    = []string{"test", "unit"},
		related = []string{"other-shard"},
		created = "2024-01-01T00:00:00Z",
	}

	testing.expect(t, b.catalog.name == "test-shard", "catalog name should match")
	testing.expect(t, b.catalog.purpose == "testing catalog storage", "purpose should match")
	testing.expect(t, len(b.catalog.tags) == 2, "should have 2 tags")
	testing.expect(t, b.catalog.tags[0] == "test", "first tag should be test")
}

// Confirms gate fields are preserved.
@(test)
test_blob_gates :: proc(t: ^testing.T) {
	defer drain_logger()
	b := shard.Blob {
		path        = "",
		master      = {},
		description = make([dynamic]string),
		positive    = make([dynamic]string),
		negative    = make([dynamic]string),
		related     = make([dynamic]string),
	}
	// NOTE: append grows dynamic arrays via default allocator (not tracking allocator).
	// blob_destroy would cause bad_free. String literals aren't heap-allocated;
	// the dynamic array headers are freed by the tracking allocator on test exit.

	append(&b.description, "code design patterns")
	append(&b.positive, "go", "rust", "odin")
	append(&b.negative, "javascript", "php")
	append(&b.related, "algorithms", "architecture")

	testing.expect(t, len(b.description) == 1, "should have 1 description")
	testing.expect(t, len(b.positive) == 3, "should have 3 positive gates")
	testing.expect(t, len(b.negative) == 2, "should have 2 negative gates")
	testing.expect(t, len(b.related) == 2, "should have 2 related shards")
}
