package query_tests

import "core:testing"

// Full-text search helpers (_compute_windows, _fulltext_hit_density) are
// @(private) in package shard and tested directly in src/search.odin.
// End-to-end dispatch tests require a running daemon; add those separately.

@(test)
test_package_compiles :: proc(t: ^testing.T) {
	testing.expect(t, true, "query_tests package compiles")
}
