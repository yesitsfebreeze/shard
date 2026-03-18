package shard_unit_test

import "core:testing"
import shard "shard:."

// Confirms index_query_thoughts returns empty results for an empty shard entry.
@(test)
test_index_query_thoughts_empty :: proc(t: ^testing.T) {
	se := shard.Indexed_Shard {
		name    = "test",
		thoughts = make([dynamic]shard.Indexed_Thought),
	}
	results := shard.index_query_thoughts(&se, "anything")
	testing.expect_value(t, len(results), 0)
	delete(se.thoughts)
}

// Confirms index_query_thoughts returns a match on keyword when no embeddings.
@(test)
test_index_query_thoughts_keyword :: proc(t: ^testing.T) {
	desc := "memory discipline in odin"
	se := shard.Indexed_Shard {
		name    = "test",
		thoughts = make([dynamic]shard.Indexed_Thought),
	}
	te := shard.Indexed_Thought {
		description = desc,
		text_hash   = shard.fnv_hash(desc),
	}
	append(&se.thoughts, te)

	results := shard.index_query_thoughts(&se, "memory")
	testing.expect(t, len(results) > 0, "expected at least one result")
	if len(results) > 0 {
		testing.expect(t, results[0].score > 0, "expected positive score")
	}

	delete(se.thoughts)
}
