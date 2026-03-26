package shard

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "transport"

test_opaque_cache_key :: proc() {
		old_has_key := state.has_key
		old_key := state.key
		old_cache_key_fallback := state.cache_key_fallback
		old_has_cache_key_fallback := state.has_cache_key_fallback
		old_cache_dir := state.cache_dir
		old_topic_cache := state.topic_cache
		old_blob := state.blob
		old_shard_id := state.shard_id
		defer {
			state.has_key = old_has_key
			state.key = old_key
			state.cache_key_fallback = old_cache_key_fallback
			state.has_cache_key_fallback = old_has_cache_key_fallback
			state.cache_dir = old_cache_dir
			state.topic_cache = old_topic_cache
			state.blob = old_blob
			state.shard_id = old_shard_id
		}

		question := "How do we rotate API keys safely?"
		key_1, ok_1 := hex_to_key("00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff")
		key_2, ok_2 := hex_to_key("ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100")
		assert(ok_1)
		assert(ok_2)

		state.key = key_1
		state.has_key = true
		state.has_cache_key_fallback = false
		key_a := opaque_cache_key("answer", question)
		key_b := opaque_cache_key("answer", question)
		key_c := opaque_cache_key("answer", "How do we rotate cache salts safely?")
		state.key = key_2
		key_d := opaque_cache_key("answer", question)

		state.has_key = false
		state.has_cache_key_fallback = false
		fallback_a := opaque_cache_key("answer", question)
		fallback_b := opaque_cache_key("answer", question)

		assert(key_a == key_b)
		assert(key_a != key_c)
		assert(key_a != key_d)
		assert(fallback_a == fallback_b)
		assert(strings.has_prefix(key_a, "answer:"))
		assert(len(key_a) == len("answer:") + 24)

		lower_key := strings.to_lower(key_a, runtime_alloc)
		words := strings.split(strings.to_lower(question, runtime_alloc), " ", allocator = runtime_alloc)
		for word in words {
			clean := strings.trim(strings.trim_space(word), "?!.,;:\"'()[]{}")
			if len(clean) < 3 do continue
			assert(!strings.contains(lower_key, clean))
		}

		tmp_name := fmt.aprintf("cache-test-%s", slugify(now_rfc3339()), allocator = runtime_alloc)
		state.cache_dir = filepath.join({state.exe_dir, tmp_name}, runtime_alloc)
		ensure_dir(state.cache_dir)
		cache_save_key(key_a, Cache_Entry{value = "cached", author = "llm", expires = ""})
		dh, dir_err := os.open(state.cache_dir)
		assert(dir_err == nil)
		if dir_err == nil {
			entries, _ := os.read_dir(dh, -1, runtime_alloc)
			os.close(dh)
			for entry in entries {
				lower_name := strings.to_lower(entry.name, runtime_alloc)
				for word in words {
					clean := strings.trim(strings.trim_space(word), "?!.,;:\"'()[]{}")
					if len(clean) < 3 do continue
					assert(!strings.contains(lower_name, clean))
				}
			}
		}
		cache_delete_key(key_a)
		os.remove(state.cache_dir)

		state.topic_cache = make(map[string]Cache_Entry, runtime_alloc)
		state.topic_cache[strings.clone(key_a, runtime_alloc)] = Cache_Entry {
			value   = "cached answer text",
			author  = "llm",
			expires = "",
		}
		state.blob = Blob {
			has_data = true,
			shard = Shard_Data {
				catalog = Catalog{name = "privacy", purpose = "privacy"},
			},
		}
		state.shard_id = "privacy"
		id := new_thought_id()
		body, seal, trust := thought_encrypt(state.key, id, "privacy thought", "details")
		t := Thought {
			id         = id,
			trust      = trust,
			seal_blob  = seal,
			body_blob  = body,
			agent      = "test",
			created_at = now_rfc3339(),
			updated_at = "",
			ttl        = 0,
		}
		buf: [dynamic]u8
		buf.allocator = runtime_alloc
		thought_serialize(&buf, &t)
		state.blob.shard.unprocessed = [][]u8{buf[:]}

		ctx := build_context("privacy")
		assert(!strings.contains(ctx, key_a))
		id_fragment := key_a
		if len(id_fragment) > len("answer:")+8 {
			id_fragment = id_fragment[:len("answer:")+8]
		}
		assert(strings.contains(ctx, id_fragment))

		list_out := process_tool_cache_list(json.Integer(1), json.Object{})
		assert(strings.contains(list_out, key_a))
		assert(strings.contains(list_out, "cached answer"))
		assert(!strings.contains(list_out, legacy_answer_cache_key(question)))
	}

	test_legacy_answer_cache_migration_compatibility :: proc() {
		old_topic_cache := state.topic_cache
		defer {
			state.topic_cache = old_topic_cache
		}

		long_question := "How should compatibility migration handle historical answer cache keys that truncate at fifty characters?"
		full_legacy_key := legacy_answer_cache_key(long_question)
		truncated_legacy_key := legacy_answer_cache_key_truncated(long_question)
		expected_truncated := legacy_answer_cache_key(long_question[:50])
		opaque_key := opaque_cache_key("answer", long_question)

		assert(truncated_legacy_key == expected_truncated)
		assert(truncated_legacy_key != full_legacy_key)

		state.topic_cache = make(map[string]Cache_Entry, runtime_alloc)
		state.topic_cache[strings.clone(truncated_legacy_key, runtime_alloc)] = Cache_Entry {
			value   = "legacy truncated hit",
			author  = "llm",
			expires = "",
		}

		if cached, key, found := cache_lookup_legacy_answer_entry(long_question); found {
			assert(key == truncated_legacy_key)
			assert(cached.value == "legacy truncated hit")
		} else {
			assert(false)
		}

		if migrated, migrated_key, migrated_ok := cache_migrate_legacy_answer_entry(opaque_key, long_question); migrated_ok {
			assert(migrated.value == "legacy truncated hit")
			assert(migrated_key == truncated_legacy_key)
			_, still_legacy := state.topic_cache[truncated_legacy_key]
			assert(!still_legacy)
			if opaque_entry, has_opaque := state.topic_cache[opaque_key]; has_opaque {
				assert(opaque_entry.value == "legacy truncated hit")
			} else {
				assert(false)
			}
		} else {
			assert(false)
		}

		state.topic_cache[strings.clone(full_legacy_key, runtime_alloc)] = Cache_Entry {
			value   = "legacy full hit",
			author  = "llm",
			expires = "",
		}
		state.topic_cache[strings.clone(truncated_legacy_key, runtime_alloc)] = Cache_Entry {
			value   = "legacy truncated stale",
			author  = "llm",
			expires = "",
		}

		if cached, key, found := cache_lookup_legacy_answer_entry(long_question); found {
			assert(key == full_legacy_key)
			assert(cached.value == "legacy full hit")
		} else {
			assert(false)
		}
	}

	test_context_packet_invariants :: proc() {
		old_has_key := state.has_key
		old_key := state.key
		old_blob := state.blob
		old_shard_id := state.shard_id
		old_topic_cache := state.topic_cache
		old_context_sessions := state.context_sessions
		defer {
			state.has_key = old_has_key
			state.key = old_key
			state.blob = old_blob
			state.shard_id = old_shard_id
			state.topic_cache = old_topic_cache
			state.context_sessions = old_context_sessions
		}

		test_key, key_ok := hex_to_key("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
		assert(key_ok)
		state.key = test_key
		state.has_key = true
		state.shard_id = "context-tests"
		state.topic_cache = make(map[string]Cache_Entry, runtime_alloc)
		state.context_sessions = make(map[string]Context_Session, runtime_alloc)
		state.blob = Blob {
			has_data = true,
			shard = Shard_Data {
				catalog = Catalog{name = "context-tests", purpose = "context packet tests"},
			},
		}

		build_test_thought :: proc(desc: string, content: string) -> []u8 {
			id := new_thought_id()
			body, seal, trust := thought_encrypt(state.key, id, desc, content)
			t := Thought {
				id         = id,
				trust      = trust,
				seal_blob  = seal,
				body_blob  = body,
				agent      = "test",
				created_at = now_rfc3339(),
				updated_at = "",
				ttl        = 0,
			}
			buf: [dynamic]u8
			buf.allocator = runtime_alloc
			thought_serialize(&buf, &t)
			return buf[:]
		}

		t1 := build_test_thought(
			"Context packet overview",
			"Context packets summarize relevant thoughts for agent responses.",
		)
		t2 := build_test_thought(
			"context packet overview",
			"Context packets summarize relevant thoughts for agent responses.",
		)
		t3 := build_test_thought("Unrelated build note", "Docker image pinned to Ubuntu base")
		state.blob.shard.unprocessed = [][]u8{t1, t2, t3}

		question := "How should context packets summarize relevant thoughts?"
		packet_a := build_context_packet(question, "agent-alpha")
		packet_b := build_context_packet(question, "agent-alpha")
		packet_c := build_context_packet(question, "")
		packet_d := build_context_packet(question, "")
		fallback_packet := build_context_packet("zzqv unscored token", "agent-beta")

		for i in 0 ..< CONTEXT_SESSION_MAX_ENTRIES + 3 {
			agent := fmt.aprintf("agent-%d", i, allocator = runtime_alloc)
			_ = build_context_packet(question, agent)
		}

		assert(len(packet_a.session_id) > 0)
		assert(packet_a.session_id == packet_b.session_id)
		assert(len(packet_c.session_id) > 0)
		assert(packet_c.session_id != packet_d.session_id)
		assert(len(packet_a.summary) > 0)
		assert(len(packet_a.included_thought_ids) == 1)
		assert(len(fallback_packet.included_thought_ids) > 0)
		assert(len(state.context_sessions) <= CONTEXT_SESSION_MAX_ENTRIES)
		_, has_oldest := state.context_sessions["agent-0"]
		assert(!has_oldest)
	}

	test_split_routing_semantic_and_fallback :: proc() {
		topic_a := "parent-topic-a"
		topic_b := "parent-topic-b"
		hints := Cache_Entry {
			value = `{"topic_a_keywords":["auth","token","oauth"],"topic_b_keywords":["render","shader","gpu"]}`,
		}

		semantic_target, semantic_ok := split_route_target_semantic(
			"rotate auth tokens",
			"oauth token refresh for api clients",
			topic_a,
			topic_b,
			"identity access auth session token login",
			"graphics render pipeline gpu shader",
			hints,
			true,
		)
		assert(semantic_ok)
		assert(semantic_target == topic_a)

		tie_target, tie_ok := split_route_target_semantic(
			"neutral note",
			"miscellaneous update",
			topic_a,
			topic_b,
			"auth login",
			"auth login",
			Cache_Entry{},
			false,
		)
		assert(!tie_ok)
		assert(len(tie_target) == 0)

		hash_a := split_route_target_hash_fallback("neutral note", "miscellaneous update", topic_a, topic_b)
		hash_b := split_route_target_hash_fallback("neutral note", "miscellaneous update", topic_a, topic_b)
		assert(hash_a == hash_b)
		assert(hash_a == topic_a || hash_a == topic_b)
	}

	test_split_routing_pretried_marks_split_peers :: proc() {
		split_state := Split_State {active = true, topic_a = "parent-shard-topic-a", topic_b = "parent-shard-topic-b"}

		normal_tried: map[string]bool
		normal_tried.allocator = runtime_alloc
		split_mark_pretried_targets(&normal_tried, split_state, true)
		_, has_normal_a := normal_tried[split_state.topic_a]
		_, has_normal_b := normal_tried[split_state.topic_b]
		assert(has_normal_a)
		assert(has_normal_b)
	}

	test_meta_bucket_mapping :: proc() {
		label, ok := meta_bucket_label(0)
		assert(ok)
		assert(label == "1h")

		label, ok = meta_bucket_label(1)
		assert(ok)
		assert(label == "24h")

		label, ok = meta_bucket_label(2)
		assert(ok)
		assert(label == "7d")

		label, ok = meta_bucket_label(3)
		assert(ok)
		assert(label == "30d")

		label, ok = meta_bucket_label(4)
		assert(ok)
		assert(label == "1y")

		label, ok = meta_bucket_label(7)
		assert(ok)
		assert(label == "4y")

		_, ok = meta_bucket_label(-1)
		assert(!ok)
	}

	test_meta_item_for_shard :: proc() {
		old_blob := state.blob
		old_shard_id := state.shard_id
		defer {
			state.blob = old_blob
			state.shard_id = old_shard_id
		}

		state.shard_id = "meta-self"
		state.blob = Blob {
			has_data = true,
			shard = Shard_Data {
				catalog = Catalog{name = "meta-self", purpose = "meta tests"},
				gates = Gates{shard_links = []string{"people", "tickets"}},
			},
		}

		item, found := meta_item_for_shard("meta-self", 1)
		assert(found)
		assert(item.id == "meta-self")
		assert(item.window == "24h")
		assert(item.thought_count == 0)
		assert(len(item.linked_shard_ids) == 2)
		assert(item.linked_shard_ids[0] == "people")

		_, found = meta_item_for_shard("missing-shard", 1)
		assert(!found)
	}

	test_meta_http_path_parsing :: proc() {
		bucket, id, ok := transport.Http_Parse_Meta_Single_Path("/meta/1/surfing-technique")
		assert(ok)
		assert(bucket == 1)
		assert(id == "surfing-technique")

		bucket, id, ok = transport.Http_Parse_Meta_Single_Path("/mcp/meta/4/people")
		assert(ok)
		assert(bucket == 4)
		assert(id == "people")

		_, _, ok = transport.Http_Parse_Meta_Single_Path("/meta/1")
		assert(!ok)

		bucket, ok = transport.Http_Parse_Meta_Batch_Path("/meta/2")
		assert(ok)
		assert(bucket == 2)

		bucket, ok = transport.Http_Parse_Meta_Batch_Path("/mcp/meta/7")
		assert(ok)
		assert(bucket == 7)

		_, ok = transport.Http_Parse_Meta_Batch_Path("/meta/not-a-number")
		assert(!ok)
	}

test_meta_http_request_body_parsing :: proc() {
	ids, ok := transport.Http_Parse_Meta_Request_Body("", runtime_alloc)
	assert(ok)
	assert(len(ids) == 0)

		ids, ok = transport.Http_Parse_Meta_Request_Body(`{}`, runtime_alloc)
		assert(ok)
		assert(len(ids) == 0)

		ids, ok = transport.Http_Parse_Meta_Request_Body(`{"ids":["a","b","c"]}`, runtime_alloc)
		assert(ok)
		assert(len(ids) == 3)
		assert(ids[0] == "a")
		assert(ids[2] == "c")

		ids, ok = transport.Http_Parse_Meta_Request_Body(`{"ids":[1, "x"]}`, runtime_alloc)
		assert(!ok)

	ids, ok = transport.Http_Parse_Meta_Request_Body(`not json`, runtime_alloc)
	assert(!ok)
}

test_process_tool_routing_table :: proc() {
	tool, key, ok := process_http_tool_resolver("POST", "/compact")
	assert(ok)
	assert(tool == "compact")
	assert(len(key) == 0)

	tool, _, ok = process_http_tool_resolver("POST", "/vec/search")
	assert(ok)
	assert(tool == "vec_search")

	tool, key, ok = process_http_tool_resolver("GET", "/cache/working-context")
	assert(ok)
	assert(tool == "cache_get")
	assert(key == "working-context")

	tool, _, ok = process_http_tool_resolver("GET", "/cache")
	assert(ok)
	assert(tool == "cache_list")

	_, _, ok = process_http_tool_resolver("POST", "/meta/1/abc")
	assert(!ok)

	_, found := process_tool_by_name("compact")
	assert(found)

	_, found = process_tool_by_name("missing_tool")
	assert(!found)
}

test_util_json_escape :: proc() {
	assert(json_escape("abc", runtime_alloc) == "abc")
		assert(json_escape("a\"b", runtime_alloc) == "a\\\"b")
		assert(json_escape("x\\y", runtime_alloc) == "x\\\\y")
		assert(json_escape("c\\nd", runtime_alloc) == "c\\nd")
	}

	test_util_parse_int_from_string :: proc() {
		v, ok := parse_decimal_int("12")
		assert(ok)
		assert(v == 12)

		v, ok = parse_decimal_int("001")
		assert(ok)
		assert(v == 1)

		_, ok = parse_decimal_int("a12")
		assert(!ok)
	}

test_util_parse_json_string_array :: proc() {
	valid_body := "[\"a\",\"b\"]"
	valid_array, parse_err := json.parse(transmute([]u8)valid_body, allocator = runtime_alloc)
	assert(parse_err == nil)

	ids, ok := parse_json_string_array(valid_array, runtime_alloc)
	assert(ok)
	assert(len(ids) == 2)
	assert(ids[0] == "a")
	assert(ids[1] == "b")

	invalid_body := `[1,"x"]`
	invalid_array, invalid_parse_err := json.parse(transmute([]u8)invalid_body, allocator = runtime_alloc)
	assert(invalid_parse_err == nil)
	_, ok = parse_json_string_array(invalid_array, runtime_alloc)
	assert(!ok)

	ids, ok = transport.Parse_JSON_String_Array(valid_array, runtime_alloc)
	assert(ok)
	assert(len(ids) == 2)
	assert(ids[0] == "a")
}

test_shared_json_helpers_alignment :: proc() {
	v, ok := parse_decimal_int("1234")
	v2, ok2 := transport.Parse_Decimal_Int("1234")
	assert(ok)
	assert(ok2)
	assert(v == v2)

	err := json_error_payload("bad", "x", -1, runtime_alloc)
	parsed, p_ok := json.parse(transmute([]u8)err, allocator = runtime_alloc)
	assert(p_ok == nil)
	obj, obj_ok := parsed.(json.Object)
	assert(obj_ok)
	_, has := obj["error"]
	assert(has)
}

	test_meta_stats_from_event_cache :: proc() {
		old_topic_cache := state.topic_cache
		defer {
			state.topic_cache = old_topic_cache
		}

		now := now_rfc3339()
		state.topic_cache = make(map[string]Cache_Entry, runtime_alloc)
		state.topic_cache["meta_access_events"] = Cache_Entry {
			value = strings.concatenate({"2000-01-01T00:00:00Z", ",", now}, runtime_alloc),
		}
		state.topic_cache["meta_write_events"] = Cache_Entry {
			value = now,
		}

		hour_stats := meta_stats_for_bucket(0)
		assert(hour_stats.access_count >= 1)
		assert(hour_stats.write_count >= 1)
		assert(len(hour_stats.last_access_at) > 0)

		year_stats := meta_stats_for_bucket(4)
		assert(year_stats.access_count >= 1)
	}
