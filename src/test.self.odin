package shard

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"

Selftest_Counter :: struct {
	total:  int,
	failed: int,
}

selftest_check :: proc(counter: ^Selftest_Counter, name: string, ok: bool) {
	counter.total += 1
	if ok {
		log.infof("[PASS] %s", name)
		return
	}
	counter.failed += 1
	log.errorf("[FAIL] %s", name)
}

selftest_split_routing :: proc(counter: ^Selftest_Counter) {
	old_id := state.shard_id
	defer state.shard_id = old_id

	state.shard_id = "parent-root"
	topic_a := "parent-root-topic-a"
	topic_b := "parent-root-topic-b"

	hash_a := split_route_target_hash_fallback("routing note", "generic content", topic_a, topic_b)
	hash_b := split_route_target_hash_fallback("routing note", "generic content", topic_a, topic_b)
	selftest_check(counter, "hash routing deterministic", hash_a == hash_b)
	selftest_check(counter, "hash routing targets split peers", hash_a == topic_a || hash_a == topic_b)
	selftest_check(counter, "split topics are non-empty", len(topic_a) > 0 && len(topic_b) > 0)
	placeholder_state := Split_State {active = true, topic_a = "parent-root-topic-a", topic_b = "parent-root-topic-b"}
	named_state := Split_State {active = true, topic_a = "parent-root-auth-flow", topic_b = "parent-root-render-pipeline"}
	selftest_check(counter, "placeholder split state needs resolution", split_state_needs_topic_resolution(placeholder_state))
	selftest_check(counter, "named split state skips resolution", !split_state_needs_topic_resolution(named_state))
}

selftest_split_state_upgrade_after_routed_write :: proc(counter: ^Selftest_Counter) {
	old_id := state.shard_id
	old_has_llm := state.has_llm
	old_topic_cache := state.topic_cache
	defer {
		state.shard_id = old_id
		state.has_llm = old_has_llm
		state.topic_cache = old_topic_cache
	}

	state.shard_id = "selftest-upgrade-root"
	state.has_llm = false
	state.topic_cache = make(map[string]Cache_Entry, runtime_alloc)

	placeholder := Split_State {
		active = true,
		topic_a = "selftest-upgrade-root-topic-a",
		topic_b = "selftest-upgrade-root-topic-b",
		label = "auto split state",
	}
	cache_key := split_state_cache_key()
	state.topic_cache[cache_key] = Cache_Entry {
		value = split_state_normalized_value(placeholder),
		author = "selftest",
		expires = "",
	}

	_, _ = route_to_peer("oauth token rotation", "refresh session token for auth clients", "selftest")

	updated, _, ok := cache_load_split_state()
	selftest_check(counter, "split-state cache exists after routed write", ok)
	if !ok do return

	selftest_check(counter, "topic_a upgraded from placeholder", !split_topic_is_placeholder(updated.topic_a))
	selftest_check(counter, "topic_b upgraded from placeholder", !split_topic_is_placeholder(updated.topic_b))
	selftest_check(counter, "split topics remain distinct", updated.topic_a != updated.topic_b)
	selftest_check(counter, "split-state label remains present", len(updated.label) > 0)
}

selftest_cli_parse :: proc(counter: ^Selftest_Counter) {
	old_args := os.args
	old_target := state.selftest_target
	old_ai := state.ai_mode
	defer {
		os.args = old_args
		state.selftest_target = old_target
		state.ai_mode = old_ai
	}

	os.args = []string{"shard", "selftest", "guarantees"}
	state.selftest_target = ""
	state.ai_mode = false
	cmd := parse_args()

	selftest_check(counter, "selftest command parsed", cmd == .Selftest)
	selftest_check(counter, "selftest target parsed", state.selftest_target == "guarantees")
}

selftest_mcp_line_response_normalization :: proc(counter: ^Selftest_Counter) {
	multiline := "{\n  \"jsonrpc\": \"2.0\",\n  \"result\": {\n    \"ok\": true\n  }\n}\r\n"
	normalized := process_line_normalize_response(multiline)
	selftest_check(counter, "mcp line response strips newlines", !strings.contains(normalized, "\n"))
	selftest_check(counter, "mcp line response strips carriage returns", !strings.contains(normalized, "\r"))
	selftest_check(counter, "mcp line response keeps payload", strings.contains(normalized, `"jsonrpc": "2.0"`))
}

selftest_logger_path_fallback :: proc(counter: ^Selftest_Counter) {
	old_exe_dir := state.exe_dir
	old_run_dir := state.run_dir
	old_shards_dir := state.shards_dir
	defer {
		state.exe_dir = old_exe_dir
		state.run_dir = old_run_dir
		state.shards_dir = old_shards_dir
	}

	state.exe_dir = filepath.join({"/tmp", "selftest", "bin"}, runtime_alloc)
	state.run_dir = filepath.join({"/tmp", "selftest", "run"}, runtime_alloc)
	state.shards_dir = filepath.join({"/tmp", "selftest"}, runtime_alloc)

	primary, fallback := logger_log_paths()
	selftest_check(counter, "logger primary path uses exe dir", strings.has_prefix(primary, state.exe_dir))
	selftest_check(counter, "logger fallback path uses run dir", strings.has_prefix(fallback, state.run_dir))
	selftest_check(counter, "logger fallback differs from primary", primary != fallback)
}

selftest_thought_encrypt_decrypt :: proc(counter: ^Selftest_Counter) {
	test_key: Key
	for i := 0; i < 32; i += 1 {
		test_key[i] = u8(i + 1)
	}
	id := new_thought_id()
	body_blob, seal_blob, trust := thought_encrypt(test_key, id, "test description", "test content body")

	selftest_check(counter, "encrypt produces body blob", len(body_blob) > 0)
	selftest_check(counter, "encrypt produces seal blob", len(seal_blob) > 0)
	selftest_check(counter, "encrypt produces trust", len(trust) > 0)

	t := Thought {
		id        = id,
		trust     = trust,
		seal_blob = seal_blob,
		body_blob = body_blob,
	}

	desc, content, ok := thought_decrypt(test_key, &t)
	selftest_check(counter, "decrypt succeeds", ok)
	selftest_check(counter, "decrypt recovers description", desc == "test description")
	selftest_check(counter, "decrypt recovers content", content == "test content body")

	wrong_key: Key
	for i := 0; i < 32; i += 1 {
		wrong_key[i] = u8(99)
	}
	_, _, wrong_ok := thought_decrypt(wrong_key, &t)
	selftest_check(counter, "wrong key fails decrypt", !wrong_ok)
}

selftest_blob_serialize_parse :: proc(counter: ^Selftest_Counter) {
	test_key: Key
	for i := 0; i < 32; i += 1 {
		test_key[i] = u8(i + 10)
	}

	id := new_thought_id()
	body_blob, seal_blob, trust := thought_encrypt(test_key, id, "blob test", "blob content")
	t := Thought{id = id, trust = trust, seal_blob = seal_blob, body_blob = body_blob}
	thought_buf: [dynamic]u8
	thought_buf.allocator = runtime_alloc
	thought_serialize(&thought_buf, &t)

	original := Shard_Data {
		catalog = Catalog{name = "test-shard", purpose = "testing", created = "2026-03-25T00:00:00Z"},
		processed = {thought_buf[:]},
		manifest = "test-manifest",
	}

	exe_stub := []u8{0xEF, 0xBE}
	buf := blob_serialize(exe_stub, &original)
	selftest_check(counter, "blob serialize produces output", len(buf) > len(exe_stub))

	parsed := shard_data_parse(buf[len(exe_stub):len(buf) - SHARD_FOOTER_SIZE])
	selftest_check(counter, "blob parse recovers catalog name", parsed.catalog.name == "test-shard")
	selftest_check(counter, "blob parse recovers catalog purpose", parsed.catalog.purpose == "testing")
	selftest_check(counter, "blob parse recovers processed count", len(parsed.processed) == 1)
	selftest_check(counter, "blob parse recovers manifest", parsed.manifest == "test-manifest")
}

selftest_passphrase_derivation :: proc(counter: ^Selftest_Counter) {
	key_a := passphrase_derive_key("test-passphrase", "test-salt")
	key_b := passphrase_derive_key("test-passphrase", "test-salt")
	selftest_check(counter, "passphrase derivation is deterministic", key_a == key_b)

	key_c := passphrase_derive_key("different-passphrase", "test-salt")
	selftest_check(counter, "different passphrase produces different key", key_a != key_c)

	key_d := passphrase_derive_key("test-passphrase", "different-salt")
	selftest_check(counter, "different salt produces different key", key_a != key_d)

	zero_key: Key
	selftest_check(counter, "derived key is non-zero", key_a != zero_key)
}

selftest_parse_rfc3339 :: proc(counter: ^Selftest_Counter) {
	y, m, d := parse_rfc3339_date("2026-03-25T14:30:00Z")
	selftest_check(counter, "rfc3339 parses year", y == 2026)
	selftest_check(counter, "rfc3339 parses month", m == 3)
	selftest_check(counter, "rfc3339 parses day", d == 25)

	y2, m2, d2 := parse_rfc3339_date("short")
	selftest_check(counter, "rfc3339 handles short input", y2 == 0 && m2 == 0 && d2 == 0)

	y3, m3, d3 := parse_rfc3339_date("")
	selftest_check(counter, "rfc3339 handles empty input", y3 == 0 && m3 == 0 && d3 == 0)
}

selftest_fork_guards :: proc(counter: ^Selftest_Counter) {
	old_is_fork := state.is_fork
	defer state.is_fork = old_is_fork

	state.is_fork = true
	selftest_check(counter, "compact skips in fork", compact())
	selftest_check(counter, "blob_write_self refuses in fork", !blob_write_self())

	state.is_fork = false
}

selftest_maintenance_flag :: proc(counter: ^Selftest_Counter) {
	old_flag := state.needs_maintenance
	old_is_fork := state.is_fork
	defer {
		state.needs_maintenance = old_flag
		state.is_fork = old_is_fork
	}

	state.needs_maintenance = false
	state.is_fork = true
	maybe_maintenance()
	selftest_check(counter, "maintenance no-op when flag is false", !state.needs_maintenance)

	state.needs_maintenance = true
	state.is_fork = true
	maybe_maintenance()
	selftest_check(counter, "maintenance skipped in fork", state.needs_maintenance)

	state.is_fork = false
	state.needs_maintenance = false
}

selftest_peer_hash_verification :: proc(counter: ^Selftest_Counter) {
	exe_stub := []u8{0xCA, 0xFE}
	test_shard := Shard_Data {
		catalog = Catalog{name = "peer-test", purpose = "hash verification"},
	}
	valid_buf := blob_serialize(exe_stub, &test_shard)
	valid_blob := load_blob_from_raw(valid_buf)
	selftest_check(counter, "valid peer blob loads", valid_blob.has_data)
	selftest_check(counter, "valid peer has catalog", valid_blob.shard.catalog.name == "peer-test")

	if len(valid_buf) > 10 {
		corrupt_buf := make([]u8, len(valid_buf), runtime_alloc)
		copy(corrupt_buf, valid_buf)
		corrupt_buf[len(exe_stub) + 2] ~= 0xFF
		corrupt_blob := load_blob_from_raw(corrupt_buf)
		selftest_check(counter, "corrupted peer blob rejected", !corrupt_blob.has_data)
	}
}

selftest_guarantees :: proc() -> bool {
	log.info("Running selftest suite: guarantees")
	counter := Selftest_Counter{}
	selftest_split_routing(&counter)
	selftest_split_state_upgrade_after_routed_write(&counter)
	selftest_cli_parse(&counter)
	selftest_mcp_line_response_normalization(&counter)
	selftest_logger_path_fallback(&counter)
	selftest_thought_encrypt_decrypt(&counter)
	selftest_blob_serialize_parse(&counter)
	selftest_passphrase_derivation(&counter)
	selftest_parse_rfc3339(&counter)
	selftest_tooling_routing(&counter)
	selftest_fork_guards(&counter)
	selftest_maintenance_flag(&counter)
	selftest_peer_hash_verification(&counter)
	passed := counter.total - counter.failed
	log.infof("Selftest: %d passed, %d failed, %d total", passed, counter.failed, counter.total)
	return counter.failed == 0
}

selftest_tooling_routing :: proc(counter: ^Selftest_Counter) {
	tool, key, ok := process_http_tool_resolver("POST", "/compact")
	selftest_check(counter, "compact routes to MCP tool", ok && tool == "compact" && len(key) == 0)

	tool, _, ok = process_http_tool_resolver("POST", "/vec/search")
	selftest_check(counter, "vec_search routes to MCP tool", ok && tool == "vec_search")

	tool, key, ok = process_http_tool_resolver("GET", "/cache/working-context")
	selftest_check(counter, "cache_get resolves dynamic key", ok && tool == "cache_get" && key == "working-context")

	tool, _, ok = process_http_tool_resolver("GET", "/cache")
	selftest_check(counter, "cache_list resolves static path", ok && tool == "cache_list")

	_, _, ok = process_http_tool_resolver("POST", "/meta/1/abc")
	selftest_check(counter, "meta path is not HTTP tool route", !ok)

	_, found := process_tool_by_name("compact")
	selftest_check(counter, "compact is registered in tool catalog", found)

	_, found = process_tool_by_name("missing_tool")
	selftest_check(counter, "missing tool not found in catalog", !found)
}

when ODIN_TEST {
	test_selftest_unit_and_runtime :: proc() {
		old_id := state.shard_id
		defer state.shard_id = old_id

	state.shard_id = "unit-root"
	topic_a := "unit-root-topic-a"
	topic_b := "unit-root-topic-b"
	hash_a := split_route_target_hash_fallback("neutral note", "miscellaneous update", topic_a, topic_b)
	hash_b := split_route_target_hash_fallback("neutral note", "miscellaneous update", topic_a, topic_b)
	assert(hash_a == hash_b)
	assert(hash_a == topic_a || hash_a == topic_b)
	assert(selftest_guarantees())
}
}
