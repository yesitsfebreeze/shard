package shard

import "core:strings"
import "core:testing"

// =============================================================================
// Markdown wire format tests
// =============================================================================

@(test)
test_md_parse_request_basic :: proc(t: ^testing.T) {
	input := "---\nop: write\ndescription: hello\nkey: abcd\n---\nBody here"
	req, ok := md_parse_request(input)
	testing.expect(t, ok, "parse should succeed")
	testing.expect(t, req.op == "write", "op must be write")
	testing.expect(t, req.description == "hello", "description must parse")
	testing.expect(t, req.key == "abcd", "key must parse")
	testing.expect(t, req.content == "Body here", "body must map to content")
}

@(test)
test_md_parse_request_with_revises :: proc(t: ^testing.T) {
	input := "---\nop: write\ndescription: revised\nrevises: aabbccdd11223344aabbccdd11223344\n---\n"
	req, ok := md_parse_request(input)
	testing.expect(t, ok, "parse should succeed")
	testing.expect(t, req.revises == "aabbccdd11223344aabbccdd11223344", "revises must parse")
}

@(test)
test_md_parse_request_with_lock_id :: proc(t: ^testing.T) {
	input := "---\nop: commit\nlock_id: abc123\nttl: 60\n---\n"
	req, ok := md_parse_request(input)
	testing.expect(t, ok, "parse should succeed")
	testing.expect(t, req.lock_id == "abc123", "lock_id must parse")
	testing.expect(t, req.ttl == 60, "ttl must parse")
}

@(test)
test_md_parse_request_with_alert :: proc(t: ^testing.T) {
	input := "---\nop: alert_response\nalert_id: xyz789\naction: approve\n---\n"
	req, ok := md_parse_request(input)
	testing.expect(t, ok, "parse should succeed")
	testing.expect(t, req.alert_id == "xyz789", "alert_id must parse")
	testing.expect(t, req.action == "approve", "action must parse")
}

@(test)
test_md_marshal_response_with_revisions :: proc(t: ^testing.T) {
	resp := Response{
		status    = "ok",
		revisions = {"aabb", "ccdd"},
	}
	out := md_marshal_response(resp)
	testing.expect(t, strings.contains(out, "revisions: [aabb, ccdd]"), "revisions must be marshalled")
}

@(test)
test_md_marshal_response_with_lock_id :: proc(t: ^testing.T) {
	resp := Response{
		status  = "ok",
		lock_id = "lock123",
	}
	out := md_marshal_response(resp)
	testing.expect(t, strings.contains(out, "lock_id: lock123"), "lock_id must be marshalled")
}

@(test)
test_md_marshal_response_with_alert :: proc(t: ^testing.T) {
	resp := Response{
		status   = "content_alert",
		alert_id = "alert456",
		findings = {
			{category = "api_key", snippet = "sk-test123"},
		},
	}
	out := md_marshal_response(resp)
	testing.expect(t, strings.contains(out, "alert_id: alert456"), "alert_id must be marshalled")
	testing.expect(t, strings.contains(out, "category: api_key"), "findings must be marshalled")
}
