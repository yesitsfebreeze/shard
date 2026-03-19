package shard_unit_test

import "core:encoding/json"
import "core:strings"
import "core:testing"
import shard "shard:."

@(test)
test_strip_jsonc_line_comments_preserves_urls :: proc(t: ^testing.T) {
	input := `{
  "llm_url": "http://localhost:11434/v1", // local ollama endpoint
  "query_budget": 8000 // per-query budget
}`

	stripped := shard.config_strip_jsonc_comments(input)
	testing.expect(t, strings.contains(stripped, "http://localhost:11434/v1"), "should preserve URL containing //")
	testing.expect(t, !strings.contains(stripped, "local ollama endpoint"), "should strip trailing // comments")

	parsed, err := json.parse(transmute([]u8)stripped, allocator = context.temp_allocator)
	testing.expect(t, err == nil, "stripped config should be valid JSON")
	if err == nil do json.destroy_value(parsed, context.temp_allocator)
}

@(test)
test_strip_jsonc_line_comments_strips_full_line_comment :: proc(t: ^testing.T) {
	input := `{
  // comment line
  "smart_query": true
}`

	stripped := shard.config_strip_jsonc_comments(input)
	testing.expect(t, !strings.contains(stripped, "comment line"), "should strip full-line // comments")
	testing.expect(t, strings.contains(stripped, `"smart_query": true`), "should preserve real fields")
}
