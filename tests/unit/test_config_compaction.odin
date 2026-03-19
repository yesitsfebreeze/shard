package shard_unit_test

import "core:os"
import "core:strings"
import "core:testing"
import shard "shard:."

// Config compaction: default JSON template must expose only query_budget as
// the canonical budget key. default_query_budget must be absent.
@(test)
test_default_config_uses_canonical_query_budget_key :: proc(t: ^testing.T) {
	data, ok := os.read_entire_file("src/defaults.jsonc")
	testing.expect(t, ok, "expected to read src/defaults.jsonc")
	if !ok do return
	defer delete(data)

	content := string(data)
	testing.expect(t, strings.contains(content, `"query_budget"`), "defaults.jsonc should contain query_budget")
	testing.expect(t, !strings.contains(content, `"default_query_budget"`), "defaults.jsonc should not contain deprecated default_query_budget")
	testing.expect(t, !strings.contains(content, "LLM_URL"), "defaults.jsonc should use lowercase keys")
}

// Balanced large-data defaults (100k to 1M thoughts) should provide
// higher fanout headroom and steadier retrieval behavior.
@(test)
test_balanced_large_data_defaults :: proc(t: ^testing.T) {
	cfg := shard.DEFAULT_CONFIG
	testing.expect_value(t, cfg.max_shards, 256)
	testing.expect_value(t, cfg.max_related, 64)
	testing.expect(t, cfg.global_query_threshold == f32(0.20), "global_query_threshold should default to 0.20")
	testing.expect_value(t, cfg.default_query_budget, 8000)
	testing.expect_value(t, cfg.compact_threshold, 100)
	testing.expect_value(t, cfg.cache_compact_threshold, 50)
	testing.expect(t, cfg.smart_query == true, "SMART_QUERY should remain enabled by default")
}

@(test)
test_config_path_is_json :: proc(t: ^testing.T) {
	testing.expect_value(t, shard.CONFIG_PATH, ".shards/config.jsonc")
}
