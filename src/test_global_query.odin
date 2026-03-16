package shard

import "core:fmt"
import "core:strings"
import "core:testing"

// =============================================================================
// Cross-shard global query tests
// =============================================================================

@(test)
test_global_query_basic :: proc(t: ^testing.T) {
	key := Master_Key{1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32}

	configs := []Test_Shard_Config{
		{
			name     = "alpha",
			purpose  = "Database design and SQL queries",
			positive = {"database", "sql", "schema"},
			thoughts = {
				{description = "Database schema overview", content = "Tables and relations for the main database"},
			},
		},
		{
			name     = "beta",
			purpose  = "Networking and HTTP protocols",
			positive = {"networking", "http", "tcp"},
			thoughts = {
				{description = "HTTP request handling", content = "How we handle HTTP requests"},
			},
		},
	}

	node := _make_test_daemon(key, configs)

	req := Request{op = "global_query", query = "database schema"}
	result, handled := daemon_dispatch(&node, req)
	testing.expect(t, handled, "global_query must be handled by daemon")
	testing.expect(t, strings.contains(result, "status: ok"), "global_query must return ok")
	testing.expect(t, strings.contains(result, "Database schema overview"), "must find matching thought")
	testing.expect(t, strings.contains(result, "alpha/"), "result ID must include shard name")
	testing.expect(t, strings.contains(result, "shard_name: alpha"), "result must include shard_name field")
	// Should NOT contain unrelated shard's thoughts
	testing.expect(t, !strings.contains(result, "HTTP request handling"), "must not include unrelated thoughts")
}

@(test)
test_global_query_multiple_shards :: proc(t: ^testing.T) {
	key := Master_Key{1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32}

	configs := []Test_Shard_Config{
		{
			name     = "alpha",
			purpose  = "Database design patterns",
			positive = {"database", "design", "patterns"},
			thoughts = {
				{description = "Database design patterns", content = "Common patterns for database design"},
			},
		},
		{
			name     = "beta",
			purpose  = "Software design patterns",
			positive = {"software", "design", "patterns"},
			thoughts = {
				{description = "Software design patterns", content = "Common software design patterns"},
			},
		},
		{
			name     = "gamma",
			purpose  = "Networking protocols",
			positive = {"networking", "tcp", "udp"},
			thoughts = {
				{description = "TCP protocol details", content = "How TCP works"},
			},
		},
	}

	node := _make_test_daemon(key, configs)

	// "design patterns" should match alpha and beta but not gamma
	req := Request{op = "global_query", query = "design patterns"}
	result, handled := daemon_dispatch(&node, req)
	testing.expect(t, handled, "global_query must be handled by daemon")
	testing.expect(t, strings.contains(result, "status: ok"), "must return ok")
	testing.expect(t, strings.contains(result, "Database design patterns"), "must find alpha's thought")
	testing.expect(t, strings.contains(result, "Software design patterns"), "must find beta's thought")
	testing.expect(t, !strings.contains(result, "TCP protocol"), "must not find gamma's thought")
	testing.expect(t, strings.contains(result, "shards_searched:"), "must report shards_searched")
}

@(test)
test_global_query_threshold_filtering :: proc(t: ^testing.T) {
	key := Master_Key{1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32}

	configs := []Test_Shard_Config{
		{
			name     = "alpha",
			purpose  = "Database design and SQL queries",
			positive = {"database", "sql", "schema"},
			thoughts = {
				{description = "Database schema overview", content = "Tables and relations"},
			},
		},
		{
			name     = "beta",
			purpose  = "General notes",
			positive = {"notes"},
			thoughts = {
				{description = "Random notes", content = "Some random notes"},
			},
		},
	}

	node := _make_test_daemon(key, configs)

	// High threshold should filter out weakly matching shards
	req := Request{op = "global_query", query = "database schema", threshold = 0.8}
	result, handled := daemon_dispatch(&node, req)
	testing.expect(t, handled, "global_query must be handled by daemon")
	testing.expect(t, strings.contains(result, "status: ok"), "must return ok")
	// beta should be filtered out by high threshold
	testing.expect(t, !strings.contains(result, "Random notes"), "high threshold must filter weak matches")
}

@(test)
test_global_query_budget_truncation :: proc(t: ^testing.T) {
	key := Master_Key{1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32}

	long_content := "This is a very long content string that should be truncated when a budget is applied during global cross-shard query execution"

	configs := []Test_Shard_Config{
		{
			name     = "alpha",
			purpose  = "Database design and SQL queries",
			positive = {"database", "sql", "schema"},
			thoughts = {
				{description = "Database schema overview", content = long_content},
			},
		},
	}

	node := _make_test_daemon(key, configs)

	req := Request{op = "global_query", query = "database schema", budget = 20}
	result, handled := daemon_dispatch(&node, req)
	testing.expect(t, handled, "global_query must be handled by daemon")
	testing.expect(t, strings.contains(result, "status: ok"), "must return ok")
	testing.expect(t, strings.contains(result, "truncated: true"), "must set truncated flag")
	testing.expect(t, !strings.contains(result, long_content), "full content must not be present")
}

@(test)
test_global_query_limit :: proc(t: ^testing.T) {
	key := Master_Key{1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32}

	configs := []Test_Shard_Config{
		{
			name     = "alpha",
			purpose  = "Database design and SQL queries",
			positive = {"database", "sql", "schema"},
			thoughts = {
				{description = "Database schema overview", content = "Schema content 1"},
				{description = "Database query patterns", content = "Query content 2"},
				{description = "Database index strategies", content = "Index content 3"},
			},
		},
	}

	node := _make_test_daemon(key, configs)

	// Limit to 1 result
	req := Request{op = "global_query", query = "database", limit = 1}
	result, handled := daemon_dispatch(&node, req)
	testing.expect(t, handled, "global_query must be handled by daemon")
	testing.expect(t, strings.contains(result, "status: ok"), "must return ok")
	// Count result entries — should have exactly 1
	count := strings.count(result, "  - id:")
	testing.expect(t, count == 1, fmt.tprintf("expected 1 result, got %d", count))
}

@(test)
test_global_query_empty_query :: proc(t: ^testing.T) {
	key := Master_Key{1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32}

	configs := []Test_Shard_Config{
		{
			name     = "alpha",
			purpose  = "Database design",
			positive = {"database"},
			thoughts = {{description = "Test", content = "Content"}},
		},
	}

	node := _make_test_daemon(key, configs)

	req := Request{op = "global_query", query = ""}
	result, handled := daemon_dispatch(&node, req)
	testing.expect(t, handled, "global_query must be handled by daemon")
	testing.expect(t, strings.contains(result, "error"), "empty query must return error")
}

@(test)
test_global_query_shard_attribution :: proc(t: ^testing.T) {
	key := Master_Key{1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32}

	configs := []Test_Shard_Config{
		{
			name     = "alpha",
			purpose  = "Database design and SQL queries",
			positive = {"database", "sql"},
			thoughts = {
				{description = "Database schema overview", content = "Alpha's database content"},
			},
		},
		{
			name     = "beta",
			purpose  = "Database optimization and performance",
			positive = {"database", "optimization", "performance"},
			thoughts = {
				{description = "Database performance tuning", content = "Beta's database content"},
			},
		},
	}

	node := _make_test_daemon(key, configs)

	req := Request{op = "global_query", query = "database"}
	result, handled := daemon_dispatch(&node, req)
	testing.expect(t, handled, "global_query must be handled by daemon")
	testing.expect(t, strings.contains(result, "status: ok"), "must return ok")
	// Both shards should appear with attribution
	testing.expect(t, strings.contains(result, "shard_name: alpha"), "must attribute alpha results")
	testing.expect(t, strings.contains(result, "shard_name: beta"), "must attribute beta results")
}
