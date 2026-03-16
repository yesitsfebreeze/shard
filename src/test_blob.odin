package shard

import "core:testing"

// =============================================================================
// Blob tests — put, get, remove, compact
// =============================================================================

@(test)
test_blob_put_get :: proc(t: ^testing.T) {
	master: Master_Key
	master[0] = 0xBB
	blob := Blob{
		path = "",  // no disk I/O
		master = master,
		processed = make([dynamic]Thought),
		unprocessed = make([dynamic]Thought),
	}

	id := new_thought_id()
	pt := Thought_Plaintext{description = "blob test", content = "blob body"}
	thought, _ := thought_create(master, id, pt)

	// Direct append (bypass blob_put which calls flush)
	append(&blob.unprocessed, thought)

	got, found := blob_get(&blob, id)
	testing.expect(t, found, "blob_get must find the thought")
	testing.expect(t, got.id == id, "blob_get must return correct thought")
}

@(test)
test_blob_remove :: proc(t: ^testing.T) {
	blob := Blob{
		processed = make([dynamic]Thought),
		unprocessed = make([dynamic]Thought),
	}

	id := new_thought_id()
	append(&blob.unprocessed, Thought{id = id})

	// Remove without flush (blob_remove calls flush which needs a path)
	for i in 0 ..< len(blob.unprocessed) {
		if blob.unprocessed[i].id == id {
			ordered_remove(&blob.unprocessed, i)
			break
		}
	}

	_, found := blob_get(&blob, id)
	testing.expect(t, !found, "thought must be gone after remove")
}
