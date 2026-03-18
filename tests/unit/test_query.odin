package shard_unit_test

import "core:testing"
import shard "shard:."

// Confirms search_query returns empty results for an empty index.
@(test)
test_search_query_empty_index :: proc(t: ^testing.T) {
	index: [dynamic]shard.Search_Entry
	results := shard.search_query(index[:], "anything")
	testing.expect_value(t, len(results), 0)
	delete(results)
}
