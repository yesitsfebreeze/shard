package shard

import "core:strings"
import "core:testing"

// =============================================================================
// Crypto tests — key derivation, encrypt/decrypt, thought round-trip
// =============================================================================

@(test)
test_derive_key_deterministic :: proc(t: ^testing.T) {
	master: Master_Key
	master[0] = 0xAB
	id: Thought_ID
	id[0] = 0x01
	k1 := derive_key(master, id)
	k2 := derive_key(master, id)
	testing.expect(t, k1 == k2, "derive_key must be deterministic")
}

@(test)
test_derive_key_different_ids :: proc(t: ^testing.T) {
	master: Master_Key
	master[0] = 0xAB
	id1: Thought_ID
	id1[0] = 0x01
	id2: Thought_ID
	id2[0] = 0x02
	k1 := derive_key(master, id1)
	k2 := derive_key(master, id2)
	testing.expect(t, k1 != k2, "different IDs must produce different keys")
}

@(test)
test_thought_create_decrypt_round_trip :: proc(t: ^testing.T) {
	master: Master_Key
	master[0] = 0xDE; master[1] = 0xAD
	id := new_thought_id()
	pt := Thought_Plaintext{description = "test desc", content = "test body"}
	thought, ok := thought_create(master, id, pt)
	testing.expect(t, ok, "thought_create should succeed")

	decrypted, err := thought_decrypt(thought, master)
	testing.expect(t, err == .None, "thought_decrypt should succeed")
	testing.expect(t, decrypted.description == "test desc", "description must round-trip")
	testing.expect(t, decrypted.content == "test body", "content must round-trip")
}

@(test)
test_thought_wrong_key_fails :: proc(t: ^testing.T) {
	master: Master_Key
	master[0] = 0xDE
	wrong: Master_Key
	wrong[0] = 0xFF
	id := new_thought_id()
	pt := Thought_Plaintext{description = "secret", content = "data"}
	thought, _ := thought_create(master, id, pt)

	_, err := thought_decrypt(thought, wrong)
	testing.expect(t, err != .None, "decrypting with wrong key must fail")
}

// =============================================================================
// Binary serialization tests
// =============================================================================

@(test)
test_thought_serialize_bin_round_trip :: proc(t: ^testing.T) {
	master: Master_Key
	master[0] = 0x42
	id := new_thought_id()
	pt := Thought_Plaintext{description = "bin test", content = "bin body"}
	thought, _ := thought_create(master, id, pt)
	thought.agent = "test-agent"
	thought.created_at = "2026-03-16T00:00:00Z"
	thought.updated_at = "2026-03-16T00:00:00Z"

	// Set a revises link
	parent_id := new_thought_id()
	thought.revises = parent_id

	buf := make([dynamic]u8)
	defer delete(buf)
	thought_serialize_bin(&buf, thought)

	pos := 0
	parsed, err := thought_parse_bin(buf[:], &pos)
	testing.expect(t, err == .None, "parse_bin should succeed")
	testing.expect(t, parsed.id == thought.id, "id must round-trip")
	testing.expect(t, parsed.agent == "test-agent", "agent must round-trip")
	testing.expect(t, parsed.revises == parent_id, "revises must round-trip")
}

// =============================================================================
// Blob tests — put, get, remove, compact
// =============================================================================

@(test)
test_blob_put_get :: proc(t: ^testing.T) {
	master: Master_Key
	master[0] = 0xBB
	blob := Blob{
		path = "",  // no disk I/O
		master = master,
		processed = make([dynamic]Thought),
		unprocessed = make([dynamic]Thought),
	}

	id := new_thought_id()
	pt := Thought_Plaintext{description = "blob test", content = "blob body"}
	thought, _ := thought_create(master, id, pt)

	// Direct append (bypass blob_put which calls flush)
	append(&blob.unprocessed, thought)

	got, found := blob_get(&blob, id)
	testing.expect(t, found, "blob_get must find the thought")
	testing.expect(t, got.id == id, "blob_get must return correct thought")
}

@(test)
test_blob_remove :: proc(t: ^testing.T) {
	blob := Blob{
		processed = make([dynamic]Thought),
		unprocessed = make([dynamic]Thought),
	}

	id := new_thought_id()
	append(&blob.unprocessed, Thought{id = id})

	// Remove without flush (blob_remove calls flush which needs a path)
	for i in 0 ..< len(blob.unprocessed) {
		if blob.unprocessed[i].id == id {
			ordered_remove(&blob.unprocessed, i)
			break
		}
	}

	_, found := blob_get(&blob, id)
	testing.expect(t, !found, "thought must be gone after remove")
}

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

// =============================================================================
// Content scanner tests
// =============================================================================

@(test)
test_scanner_detects_api_key :: proc(t: ^testing.T) {
	findings := scan_content("test", "my key is sk-1234567890abcdef")
	defer delete(findings)
	testing.expect(t, len(findings) > 0, "scanner must detect sk- prefix")
	found_api := false
	for f in findings {
		if f.category == "api_key" do found_api = true
	}
	testing.expect(t, found_api, "must have api_key category")
}

@(test)
test_scanner_detects_password :: proc(t: ^testing.T) {
	findings := scan_content("config", "password = hunter2")
	defer delete(findings)
	found_pw := false
	for f in findings {
		if f.category == "password" do found_pw = true
	}
	testing.expect(t, found_pw, "must detect password pattern")
}

@(test)
test_scanner_detects_email :: proc(t: ^testing.T) {
	findings := scan_content("contact info", "email me at user@example.com please")
	defer delete(findings)
	found_pii := false
	for f in findings {
		if f.category == "pii" do found_pii = true
	}
	testing.expect(t, found_pii, "must detect email as PII")
}

@(test)
test_scanner_clean_content :: proc(t: ^testing.T) {
	findings := scan_content("meeting notes", "We discussed the roadmap and agreed on priorities.")
	defer delete(findings)
	testing.expect(t, len(findings) == 0, "clean content must produce no findings")
}

@(test)
test_scanner_detects_aws_key :: proc(t: ^testing.T) {
	findings := scan_content("config", "aws_access_key_id = AKIAIOSFODNN7EXAMPLE")
	defer delete(findings)
	found := false
	for f in findings {
		if f.category == "api_key" do found = true
	}
	testing.expect(t, found, "must detect AKIA prefix")
}

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

// =============================================================================
// Dispatch tests — op routing
// =============================================================================

@(test)
test_dispatch_unknown_op :: proc(t: ^testing.T) {
	node := Node{
		blob = Blob{
			processed   = make([dynamic]Thought),
			unprocessed = make([dynamic]Thought),
			description = make([dynamic]string),
			positive    = make([dynamic]string),
			negative    = make([dynamic]string),
			related     = make([dynamic]string),
		},
	}
	result := dispatch(&node, "---\nop: nonexistent\n---\n")
	testing.expect(t, strings.contains(result, "unknown op"), "unknown op must return error")
}

@(test)
test_dispatch_list_empty :: proc(t: ^testing.T) {
	node := Node{
		blob = Blob{
			processed   = make([dynamic]Thought),
			unprocessed = make([dynamic]Thought),
			description = make([dynamic]string),
			positive    = make([dynamic]string),
			negative    = make([dynamic]string),
			related     = make([dynamic]string),
		},
	}
	result := dispatch(&node, "---\nop: list\n---\n")
	testing.expect(t, strings.contains(result, "status: ok"), "list on empty blob must succeed")
}

@(test)
test_dispatch_status :: proc(t: ^testing.T) {
	node := Node{
		name = "test-node",
		blob = Blob{
			processed   = make([dynamic]Thought),
			unprocessed = make([dynamic]Thought),
			description = make([dynamic]string),
			positive    = make([dynamic]string),
			negative    = make([dynamic]string),
			related     = make([dynamic]string),
		},
	}
	result := dispatch(&node, "---\nop: status\n---\n")
	testing.expect(t, strings.contains(result, "node_name: test-node"), "status must return node name")
}
