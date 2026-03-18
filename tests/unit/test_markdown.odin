package shard_unit_test

import "core:strings"
import "core:testing"
import shard "shard:."

// Confirms basic frontmatter request parsing works.
@(test)
test_md_parse_request_basic :: proc(t: ^testing.T) {
	defer drain_logger()
	yaml := `---
op: write
description: test thought
---
this is the body`
	req, ok := shard.md_parse_request(yaml)
	defer shard.request_destroy(&req)
	testing.expect(t, ok, "md_parse_request should succeed")
	testing.expect(t, req.op == "write", "op should be 'write'")
	testing.expect(t, req.description == "test thought", "description should match")
	testing.expect(t, strings.contains(req.content, "this is the body"), "content should contain body")
}

// Confirms list parsing works.
@(test)
test_md_parse_request_list :: proc(t: ^testing.T) {
	defer drain_logger()
	yaml := `---
op: set_positive
items: [go, rust, odin]
tags: [programming, systems]
---
`
	req, ok := shard.md_parse_request(yaml)
	defer shard.request_destroy(&req)
	testing.expect(t, ok, "md_parse_request should succeed")
	testing.expect(t, len(req.items) == 3, "should have 3 items")
	testing.expect(t, req.items[0] == "go", "first item should be 'go'")
	testing.expect(t, req.items[2] == "odin", "third item should be 'odin'")
	testing.expect(t, len(req.tags) == 2, "should have 2 tags")
}

// Confirms single value is treated as list.
@(test)
test_md_parse_request_single_value :: proc(t: ^testing.T) {
	defer drain_logger()
	yaml := `---
op: query
items: single_item
---
`
	req, ok := shard.md_parse_request(yaml)
	defer shard.request_destroy(&req)
	testing.expect(t, ok, "md_parse_request should succeed")
	testing.expect(t, len(req.items) == 1, "single value should become 1-element list")
	testing.expect(t, req.items[0] == "single_item", "item should match")
}

// Confirms integer parsing works.
@(test)
test_md_parse_request_integers :: proc(t: ^testing.T) {
	defer drain_logger()
	yaml := `---
op: write
thought_count: 42
max_depth: 5
limit: 100
ttl: 3600
budget: 5000
thought_ttl: 86400
max_bytes: 1048576
context_lines: 3
---
`
	req, ok := shard.md_parse_request(yaml)
	defer shard.request_destroy(&req)
	testing.expect(t, ok, "md_parse_request should succeed")
	testing.expect(t, req.thought_count == 42, "thought_count should be 42")
	testing.expect(t, req.max_depth == 5, "max_depth should be 5")
	testing.expect(t, req.limit == 100, "limit should be 100")
	testing.expect(t, req.ttl == 3600, "ttl should be 3600")
	testing.expect(t, req.budget == 5000, "budget should be 5000")
	testing.expect(t, req.thought_ttl == 86400, "thought_ttl should be 86400")
	testing.expect(t, req.max_bytes == 1048576, "max_bytes should be 1048576")
	testing.expect(t, req.context_lines == 3, "context_lines should be 3")
}

// Confirms float parsing works.
@(test)
test_md_parse_request_floats :: proc(t: ^testing.T) {
	defer drain_logger()
	yaml := `---
op: query
threshold: 0.75
freshness_weight: 0.3
---
`
	req, ok := shard.md_parse_request(yaml)
	defer shard.request_destroy(&req)
	testing.expect(t, ok, "md_parse_request should succeed")
	testing.expect(t, req.threshold > 0.74 && req.threshold < 0.76, "threshold should be ~0.75")
	testing.expect(t, req.freshness_weight > 0.29 && req.freshness_weight < 0.31, "freshness_weight should be ~0.3")
}

// Confirms empty body is valid.
@(test)
test_md_parse_request_empty_body :: proc(t: ^testing.T) {
	defer drain_logger()
	yaml := `---
op: list
---
`
	req, ok := shard.md_parse_request(yaml)
	defer shard.request_destroy(&req)
	testing.expect(t, ok, "md_parse_request should succeed")
	testing.expect(t, req.content == "", "content should be empty")
}

// Confirms multi-line body is preserved.
@(test)
test_md_parse_request_multiline_body :: proc(t: ^testing.T) {
	defer drain_logger()
	yaml := `---
op: write
description: code snippet
---
func main() {
    println("hello")
}
`
	req, ok := shard.md_parse_request(yaml)
	defer shard.request_destroy(&req)
	testing.expect(t, ok, "md_parse_request should succeed")
	testing.expect(t, strings.contains(req.content, "func main()"), "body should contain code")
	testing.expect(t, strings.contains(req.content, "println"), "body should contain println")
}

// Confirms all string fields are parsed.
@(test)
test_md_parse_request_all_fields :: proc(t: ^testing.T) {
	defer drain_logger()
	yaml := `---
op: write
id: abc123
description: field test
query: search query
name: test-shard
data_path: /path/to/shard
purpose: testing
agent: test-agent
key: 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
revises: parent123456789012345678901234
lock_id: lock-token
alert_id: alert-123
action: approve
event_type: knowledge_changed
source: source-shard
feedback: endorse
mode: lossless
format: results
topic: test-topic
---
body content here`
	req, ok := shard.md_parse_request(yaml)
	defer shard.request_destroy(&req)
	testing.expect(t, ok, "md_parse_request should succeed")
	testing.expect(t, req.op == "write", "op should be write")
	testing.expect(t, req.id == "abc123", "id should be parsed")
	testing.expect(t, req.description == "field test", "description should match")
	testing.expect(t, strings.contains(req.content, "body content"), "content should contain body")
	testing.expect(t, req.query == "search query", "query should match")
	testing.expect(t, req.name == "test-shard", "name should match")
	testing.expect(t, req.data_path == "/path/to/shard", "data_path should match")
	testing.expect(t, req.purpose == "testing", "purpose should match")
	testing.expect(t, req.agent == "test-agent", "agent should match")
	testing.expect(t, req.key == "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", "key should match")
	testing.expect(t, req.revises == "parent123456789012345678901234", "revises should match")
	testing.expect(t, req.lock_id == "lock-token", "lock_id should match")
	testing.expect(t, req.alert_id == "alert-123", "alert_id should match")
	testing.expect(t, req.action == "approve", "action should match")
	testing.expect(t, req.event_type == "knowledge_changed", "event_type should match")
	testing.expect(t, req.source == "source-shard", "source should match")
	testing.expect(t, req.feedback == "endorse", "feedback should match")
	testing.expect(t, req.mode == "lossless", "mode should match")
	testing.expect(t, req.format == "results", "format should match")
	testing.expect(t, req.topic == "test-topic", "topic should match")
}

// Confirms missing frontmatter delimiter fails.
@(test)
test_md_parse_request_missing_delimiter :: proc(t: ^testing.T) {
	defer drain_logger()
	yaml := `op: write
description: no delimiters
---`
	_, ok := shard.md_parse_request(yaml)
	testing.expect(t, !ok, "should fail without opening ---")
}

// Confirms missing closing delimiter fails.
@(test)
test_md_parse_request_missing_close :: proc(t: ^testing.T) {
	defer drain_logger()
	yaml := `---
op: write
description: no closing delimiter
`
	_, ok := shard.md_parse_request(yaml)
	testing.expect(t, !ok, "should fail without closing ---")
}

// Confirms empty input fails.
@(test)
test_md_parse_request_empty :: proc(t: ^testing.T) {
	defer drain_logger()
	_, ok := shard.md_parse_request("")
	testing.expect(t, !ok, "empty input should fail")

	_, ok = shard.md_parse_request("   ")
	testing.expect(t, !ok, "whitespace-only input should fail")
}

// Confirms response marshaling produces valid output.
@(test)
test_md_marshal_response_basic :: proc(t: ^testing.T) {
	defer drain_logger()
	resp := shard.Response {
		status = "ok",
	}
	marshaled := shard.md_marshal_response(resp)
	defer delete(marshaled)
	testing.expect(t, strings.contains(marshaled, "status: ok"), "should contain status")
	testing.expect(t, strings.contains(marshaled, "---"), "should have frontmatter delimiter")
}

// Confirms response with content includes body.
@(test)
test_md_marshal_response_with_content :: proc(t: ^testing.T) {
	defer drain_logger()
	resp := shard.Response {
		status      = "ok",
		id          = "abc123",
		description = "test description",
		content     = "This is the body content.",
	}
	marshaled := shard.md_marshal_response(resp)
	defer delete(marshaled)
	testing.expect(t, strings.contains(marshaled, "status: ok"), "should contain status")
	testing.expect(t, strings.contains(marshaled, "id: abc123"), "should contain id")
	testing.expect(t, strings.contains(marshaled, "description: test description"), "should contain description")
	testing.expect(t, strings.contains(marshaled, "This is the body content."), "should contain content body")
}

// Confirms response with results marshals correctly.
@(test)
test_md_marshal_response_with_results :: proc(t: ^testing.T) {
	defer drain_logger()
	resp := shard.Response {
		status = "ok",
		results = []shard.Wire_Result {
			{
				id          = "id1",
				shard_name  = "test-shard",
				score       = 0.85,
				description = "result 1",
				content     = "content 1",
			},
		},
	}
	marshaled := shard.md_marshal_response(resp)
	defer delete(marshaled)
	testing.expect(t, strings.contains(marshaled, "results:"), "should contain results section")
	testing.expect(t, strings.contains(marshaled, "id: id1"), "should contain result id")
	testing.expect(t, strings.contains(marshaled, "shard_name: test-shard"), "should contain shard_name")
	testing.expect(t, strings.contains(marshaled, "description: result 1"), "should contain description")
}

// Confirms response with catalog marshals correctly.
@(test)
test_md_marshal_response_with_catalog :: proc(t: ^testing.T) {
	defer drain_logger()
	resp := shard.Response {
		status = "ok",
		catalog = shard.Catalog {
			name    = "my-shard",
			purpose = "testing catalog",
			tags    = []string{"test", "unit"},
		},
	}
	marshaled := shard.md_marshal_response(resp)
	defer delete(marshaled)
	testing.expect(t, strings.contains(marshaled, "catalog:"), "should contain catalog section")
	testing.expect(t, strings.contains(marshaled, "name: my-shard"), "should contain name")
	testing.expect(t, strings.contains(marshaled, "purpose: testing catalog"), "should contain purpose")
}

// Confirms response with registry marshals correctly.
@(test)
test_md_marshal_response_with_registry :: proc(t: ^testing.T) {
	defer drain_logger()
	resp := shard.Response {
		status = "ok",
		registry = []shard.Registry_Entry {
			{
				name          = "shard1",
				data_path     = ".shards/shard1.shard",
				thought_count = 10,
				catalog       = shard.Catalog{name = "shard1", purpose = "test"},
			},
		},
	}
	marshaled := shard.md_marshal_response(resp)
	defer delete(marshaled)
	testing.expect(t, strings.contains(marshaled, "registry:"), "should contain registry section")
	testing.expect(t, strings.contains(marshaled, "name: shard1"), "should contain entry name")
	testing.expect(t, strings.contains(marshaled, "thought_count: 10"), "should contain count")
}

// Confirms error response marshals correctly.
@(test)
test_md_marshal_response_error :: proc(t: ^testing.T) {
	defer drain_logger()
	resp := shard.Response {
		status = "error",
		err    = "something went wrong",
	}
	marshaled := shard.md_marshal_response(resp)
	defer delete(marshaled)
	testing.expect(t, strings.contains(marshaled, "status: error"), "should contain error status")
	testing.expect(t, strings.contains(marshaled, "error: something went wrong"), "should contain error message")
}

// Confirms ids list marshaling works.
@(test)
test_md_marshal_response_ids :: proc(t: ^testing.T) {
	defer drain_logger()
	resp := shard.Response {
		status = "ok",
		ids    = []string{"id1", "id2", "id3"},
	}
	marshaled := shard.md_marshal_response(resp)
	defer delete(marshaled)
	testing.expect(t, strings.contains(marshaled, "ids: [id1, id2, id3]"), "should contain ids list")
}

// Confirms response status fields marshaling.
@(test)
test_md_marshal_response_status_fields :: proc(t: ^testing.T) {
	defer drain_logger()
	resp := shard.Response {
		status           = "ok",
		node_name        = "test-node",
		thoughts         = 42,
		uptime_secs      = 1234.5,
		moved            = 5,
		staleness_score  = 0.25,
		relevance_score  = 0.75,
		shards_searched  = 10,
		total_results    = 25,
	}
	marshaled := shard.md_marshal_response(resp)
	defer delete(marshaled)
	testing.expect(t, strings.contains(marshaled, "node_name: test-node"), "should contain node_name")
	testing.expect(t, strings.contains(marshaled, "thoughts: 42"), "should contain thoughts count")
	testing.expect(t, strings.contains(marshaled, "uptime_secs:"), "should contain uptime")
	testing.expect(t, strings.contains(marshaled, "moved: 5"), "should contain moved count")
}

// Confirms JSON request parsing works (for IPC).
@(test)
test_md_parse_request_json_basic :: proc(t: ^testing.T) {
	defer drain_logger()
	json_str := `{"op":"write","description":"test thought","content":"this is the body"}`
	req, ok := shard.md_parse_request_json(transmute([]u8)json_str)
	defer shard.request_destroy(&req)
	testing.expect(t, ok, "md_parse_request_json should succeed")
	testing.expect(t, req.op == "write", "op should be 'write'")
	testing.expect(t, req.description == "test thought", "description should match")
	testing.expect(t, req.content == "this is the body", "content should match")
}

// Confirms JSON list parsing works (for IPC).
@(test)
test_md_parse_request_json_list :: proc(t: ^testing.T) {
	defer drain_logger()
	json_str := `{"op":"set_positive","items":["go","rust","odin"],"tags":["programming","systems"]}`
	req, ok := shard.md_parse_request_json(transmute([]u8)json_str)
	defer shard.request_destroy(&req)
	testing.expect(t, ok, "md_parse_request_json should succeed")
	testing.expect(t, len(req.items) == 3, "should have 3 items")
	testing.expect(t, req.items[0] == "go", "first item should be 'go'")
	testing.expect(t, req.items[2] == "odin", "third item should be 'odin'")
}

// Confirms JSON response marshaling works (for IPC).
@(test)
test_md_marshal_response_json_basic :: proc(t: ^testing.T) {
	defer drain_logger()
	resp := shard.Response {
		status = "ok",
	}
	marshaled := shard.md_marshal_response_json(resp)
	defer delete(marshaled)
	marshaled_str := string(marshaled)
	testing.expect(t, strings.contains(marshaled_str, `"status":"ok"`), "should contain status")
	testing.expect(t, strings.has_prefix(marshaled_str, "{"), "should start with {")
	testing.expect(t, strings.has_suffix(marshaled_str, "}"), "should end with }")
}

// Confirms JSON response with content marshals correctly.
@(test)
test_md_marshal_response_json_with_content :: proc(t: ^testing.T) {
	defer drain_logger()
	resp := shard.Response {
		status      = "ok",
		id          = "abc123",
		description = "test description",
		content     = "This is the body content.",
	}
	marshaled := shard.md_marshal_response_json(resp)
	defer delete(marshaled)
	marshaled_str := string(marshaled)
	testing.expect(t, strings.contains(marshaled_str, `"status":"ok"`), "should contain status")
	testing.expect(t, strings.contains(marshaled_str, `"id":"abc123"`), "should contain id")
	testing.expect(t, strings.contains(marshaled_str, `"description":"test description"`), "should contain description")
}
