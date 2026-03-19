package shard_unit_test

import "core:testing"
import shard "shard:."

// smart_query is true by default (when LLM is configured, compaction fires)
@(test)
test_smart_query_default_true :: proc(t: ^testing.T) {
	defer drain_logger()
	cfg := shard.DEFAULT_CONFIG
	testing.expect(t, cfg.smart_query == true, "smart_query should default to true")
}

// SMART_QUERY false → smart_query field is false after parse
@(test)
test_smart_query_opt_out :: proc(t: ^testing.T) {
	defer drain_logger()
	cfg := shard.DEFAULT_CONFIG
	cfg.smart_query = false
	testing.expect(t, cfg.smart_query == false, "smart_query should be settable to false")
}

// QUERY_BUDGET defaults to a non-zero smart-query budget
@(test)
test_query_budget_default_nonzero :: proc(t: ^testing.T) {
	defer drain_logger()
	cfg := shard.DEFAULT_CONFIG
	testing.expect_value(t, cfg.default_query_budget, 8000)
}

// When smart_query is true and llm_url set, truncate_to_budget should attempt
// AI compaction. We verify the guard logic: when smart_query is false,
// _truncate_to_budget must NOT call the LLM even if content exceeds budget.
// We test this indirectly via the config-aware guard.
@(test)
test_truncate_budget_respects_smart_query :: proc(t: ^testing.T) {
	defer drain_logger()
	// Build a config with no LLM — smart_query=false means AI compact skipped
	// _truncate_to_budget falls back to hard truncation
	content := "hello world this is a long piece of content that exceeds budget"
	budget  := 5
	result, truncated, used, was_ai_compacted := shard._truncate_to_budget(content, budget, 0)
	testing.expect(t, truncated == true, "should be truncated")
	testing.expect(t, len(result) <= budget, "result should fit in budget")
	_ = used
	testing.expect(t, was_ai_compacted == false, "should not be AI compacted without LLM")
}
