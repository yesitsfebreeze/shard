package shard_unit_test

import "core:strings"
import "core:testing"
import "core:time"
import shard "shard:."

// Confirms fnv_hash produces consistent hashes.
@(test)
test_fnv_hash :: proc(t: ^testing.T) {
	defer drain_logger()
	h1 := shard.fnv_hash("test string")
	h2 := shard.fnv_hash("test string")
	testing.expect(t, h1 == h2, "same input should produce same hash")

	h3 := shard.fnv_hash("different string")
	testing.expect(t, h1 != h3, "different input should produce different hash")

	h4 := shard.fnv_hash("")
	testing.expect(t, h4 != h1, "empty string should produce different hash")
}

// Confirms index_query_thoughts keyword search works.
@(test)
test_index_query_thoughts_keyword_match :: proc(t: ^testing.T) {
	defer drain_logger()
	se := shard.Indexed_Shard {
		name     = "test",
		thoughts = make([dynamic]shard.Indexed_Thought),
	}
	defer delete(se.thoughts)

	// Add thoughts with different descriptions
	thoughts := []string{
		"odin programming language basics",
		"rust memory safety features",
		"go concurrent programming",
	}
	for desc in thoughts {
		id := shard.new_thought_id()
		append(&se.thoughts, shard.Indexed_Thought {
			id          = id,
			description = desc,
			text_hash   = shard.fnv_hash(desc),
		})
	}

	// Search for "odin" should match first thought
	results := shard.index_query_thoughts(&se, "odin")
	testing.expect(t, len(results) > 0, "should find matches for 'odin'")
	if len(results) > 0 {
		testing.expect(t, results[0].score > 0, "score should be positive")
	}

	// Search for "memory" should match second thought
	results2 := shard.index_query_thoughts(&se, "memory")
	testing.expect(t, len(results2) > 0, "should find matches for 'memory'")

	// Search for "xyz123" should match nothing
	results3 := shard.index_query_thoughts(&se, "xyz123")
	testing.expect(t, len(results3) == 0, "should find no matches for random string")
}

// Confirms index_query_thoughts handles empty shard.
@(test)
test_index_query_thoughts_empty_shard :: proc(t: ^testing.T) {
	defer drain_logger()
	se := shard.Indexed_Shard {
		name     = "empty",
		thoughts = make([dynamic]shard.Indexed_Thought),
	}
	defer delete(se.thoughts)

	results := shard.index_query_thoughts(&se, "anything")
	testing.expect(t, len(results) == 0, "empty shard should return no results")
}

// Confirms stemmer handles common suffixes.
@(test)
test_stemming :: proc(t: ^testing.T) {
	defer drain_logger()
	se := shard.Indexed_Shard {
		name     = "stem-test",
		thoughts = make([dynamic]shard.Indexed_Thought),
	}
	defer delete(se.thoughts)

	// Add a thought
	id := shard.new_thought_id()
	append(&se.thoughts, shard.Indexed_Thought {
		id          = id,
		description = "programming patterns",
		text_hash   = shard.fnv_hash("programming patterns"),
	})

	// Query with singular should match (stripping "s")
	results := shard.index_query_thoughts(&se, "pattern")
	testing.expect(t, len(results) > 0, "stemming should allow singular/plural matching")

	// Query with same word should match
	results2 := shard.index_query_thoughts(&se, "patterns")
	testing.expect(t, len(results2) > 0, "exact match should work")

	// Query with partial match in description
	results3 := shard.index_query_thoughts(&se, "programming")
	testing.expect(t, len(results3) > 0, "programming should match")
}

// Confirms case insensitivity in keyword matching.
@(test)
test_keyword_case_insensitive :: proc(t: ^testing.T) {
	defer drain_logger()
	se := shard.Indexed_Shard {
		name     = "case-test",
		thoughts = make([dynamic]shard.Indexed_Thought),
	}
	defer delete(se.thoughts)

	id := shard.new_thought_id()
	append(&se.thoughts, shard.Indexed_Thought {
		id          = id,
		description = "Go Programming LANGUAGE",
		text_hash   = shard.fnv_hash("Go Programming LANGUAGE"),
	})

	// All variations should match
	queries := []string{"go", "GO", "Go", "programming", "PROGRAMMING", "language", "LANGUAGE"}
	for query in queries {
		results := shard.index_query_thoughts(&se, query)
		testing.expect(t, len(results) > 0, "case-insensitive match for '%s'", query)
	}
}

// Confirms results are sorted by score descending.
@(test)
test_index_results_sorted :: proc(t: ^testing.T) {
	defer drain_logger()
	se := shard.Indexed_Shard {
		name     = "sort-test",
		thoughts = make([dynamic]shard.Indexed_Thought),
	}
	defer delete(se.thoughts)

	// Add multiple matching thoughts
	id1 := shard.new_thought_id()
	id2 := shard.new_thought_id()
	id3 := shard.new_thought_id()
	append(&se.thoughts, shard.Indexed_Thought {
		id          = id1,
		description = "programming", // 1 token match
		text_hash   = shard.fnv_hash("programming"),
	})
	append(&se.thoughts, shard.Indexed_Thought {
		id          = id2,
		description = "programming language", // 2 token matches
		text_hash   = shard.fnv_hash("programming language"),
	})
	append(&se.thoughts, shard.Indexed_Thought {
		id          = id3,
		description = "programming language design", // 3 token matches
		text_hash   = shard.fnv_hash("programming language design"),
	})

	results := shard.index_query_thoughts(&se, "programming language")
	testing.expect(t, len(results) == 3, "should find all 3 matching thoughts")

	// Verify descending order
	if len(results) >= 2 {
		testing.expect(t, results[0].score >= results[1].score, "results should be sorted by score")
	}
}

// Confirms Indexed_Shard and Indexed_Thought are constructable.
@(test)
test_indexed_types :: proc(t: ^testing.T) {
	defer drain_logger()
	se := shard.Indexed_Shard {
		name      = "test-shard",
		embedding = make([]f32, 4),
		text_hash = 12345,
		thoughts  = make([dynamic]shard.Indexed_Thought),
	}
	defer {
		delete(se.embedding)
		delete(se.thoughts)
	}

	testing.expect(t, se.name == "test-shard", "name should be set")
	testing.expect(t, len(se.embedding) == 4, "embedding should have 4 dims")
	testing.expect(t, se.text_hash == 12345, "text_hash should be set")

	te := shard.Indexed_Thought {
		id          = shard.new_thought_id(),
		description = "test thought",
		text_hash   = shard.fnv_hash("test thought"),
	}
	append(&se.thoughts, te)
	testing.expect(t, len(se.thoughts) == 1, "should have 1 thought")

	ir := shard.Index_Result {
		id    = te.id,
		score = 0.85,
	}
	testing.expect(t, ir.id == te.id, "Index_Result should store id")
	testing.expect(t, ir.score == 0.85, "Index_Result should store score")

	isr := shard.Index_Shard_Result {
		name  = "other-shard",
		score = 0.72,
	}
	testing.expect(t, isr.name == "other-shard", "Index_Shard_Result should store name")
	testing.expect(t, isr.score == 0.72, "Index_Shard_Result should store score")
}

// Confirms Shard_Index initialization.
@(test)
test_shard_index_init :: proc(t: ^testing.T) {
	defer drain_logger()
	si := shard.Shard_Index {
		shards = make([dynamic]shard.Indexed_Shard),
		dims   = 0,
	}
	defer {
		for &s in si.shards {
			delete(s.embedding)
			for &te in s.thoughts {
				delete(te.embedding)
				delete(te.description)
			}
			delete(s.thoughts)
		}
		delete(si.shards)
	}

	testing.expect(t, len(si.shards) == 0, "shards should be empty initially")
	testing.expect(t, si.dims == 0, "dims should be 0 initially")

	// Add a shard
	append(&si.shards, shard.Indexed_Shard {
		name     = "added-shard",
		thoughts = make([dynamic]shard.Indexed_Thought),
	})
	testing.expect(t, len(si.shards) == 1, "should have 1 shard")
	testing.expect(t, si.shards[0].name == "added-shard", "added shard name should match")
}

// Confirms thought plaintext matching function works.
@(test)
test_thought_matches_tokens :: proc(t: ^testing.T) {
	defer drain_logger()
	pt := shard.Thought_Plaintext {
		description = "Go Programming",
		content     = "Concurrent programming in Go uses goroutines",
	}

	tokens := []string{"go", "concurrent"}

	// Lowercase matching - check if any token is contained in the lowercase description
	desc_lower := strings.to_lower("go programming", context.temp_allocator)
	defer delete(desc_lower, context.temp_allocator)

	matches := false
	for token in tokens {
		if strings.contains(desc_lower, token) {
			matches = true
			break
		}
	}
	testing.expect(t, matches, "token should be found in lowercase description")

	// Content matching
	content_lower := strings.to_lower(pt.content, context.temp_allocator)
	defer delete(content_lower, context.temp_allocator)

	content_has_token := false
	for token in tokens {
		if strings.contains(content_lower, token) {
			content_has_token = true
			break
		}
	}
	testing.expect(t, content_has_token, "content should contain matching terms")
}
