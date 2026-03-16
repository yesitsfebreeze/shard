package shard

import "core:testing"

// =============================================================================
// Search tests
// =============================================================================

@(test)
test_keyword_search_basic :: proc(t: ^testing.T) {
	entries := []Search_Entry{
		{description = "meeting notes about the roadmap", text_hash = fnv_hash("meeting notes about the roadmap")},
		{description = "grocery list for the weekend", text_hash = fnv_hash("grocery list for the weekend")},
		{description = "roadmap priorities for Q2", text_hash = fnv_hash("roadmap priorities for Q2")},
	}
	results := search_query(entries, "roadmap")
	defer delete(results)
	testing.expect(t, len(results) >= 2, "should find at least 2 roadmap matches")
}

@(test)
test_keyword_search_no_match :: proc(t: ^testing.T) {
	entries := []Search_Entry{
		{description = "meeting notes", text_hash = fnv_hash("meeting notes")},
	}
	results := search_query(entries, "quantum physics")
	defer delete(results)
	testing.expect(t, len(results) == 0, "should find no matches")
}
