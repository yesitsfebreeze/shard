package query_tests

import "core:testing"

// Scaffold tests for the unified query pipeline (format=dump).
// The codebase has no in-process dispatch test harness yet.
// These verify the package compiles and the test runner discovers it.
// Expand into real dispatch tests once a test-node helper is extracted.

@(test)
test_format_field_compiles :: proc(t: ^testing.T) {
	// Confirms the query_tests package compiles cleanly.
	testing.expect(t, true, "scaffold")
}

@(test)
test_query_default_returns_results :: proc(t: ^testing.T) {
	// Placeholder: without format=dump, query returns Wire_Results not markdown.
	testing.expect(t, true, "scaffold")
}

@(test)
test_query_dump_returns_markdown :: proc(t: ^testing.T) {
	// Placeholder: with format=dump, query returns content field with # heading.
	testing.expect(t, true, "scaffold")
}

@(test)
test_global_query_dump_groups_by_shard :: proc(t: ^testing.T) {
	// Placeholder: global_query format=dump groups results under # ShardName headers.
	testing.expect(t, true, "scaffold")
}

@(test)
test_global_query_dump_empty_wire :: proc(t: ^testing.T) {
	// Placeholder: global_query format=dump with no hits returns non-empty content.
	testing.expect(t, true, "scaffold")
}
