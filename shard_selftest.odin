package shard

import "core:fmt"
import "core:os"

Selftest_Counter :: struct {
	total:  int,
	failed: int,
}

selftest_check :: proc(counter: ^Selftest_Counter, name: string, ok: bool) {
	counter.total += 1
	if ok {
		fmt.printfln("[PASS] %s", name)
		return
	}
	counter.failed += 1
	fmt.printfln("[FAIL] %s", name)
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

	updated, ok := cache_load_split_state()
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

selftest_guarantees :: proc() -> bool {
	fmt.println("Running selftest suite: guarantees")
	counter := Selftest_Counter{}
	selftest_split_routing(&counter)
	selftest_split_state_upgrade_after_routed_write(&counter)
	selftest_cli_parse(&counter)
	passed := counter.total - counter.failed
	fmt.printfln("Selftest: %d passed, %d failed, %d total", passed, counter.failed, counter.total)
	return counter.failed == 0
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
