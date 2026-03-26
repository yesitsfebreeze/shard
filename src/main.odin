package shard

import "core:log"
import "core:mem"
import "core:os"
import "core:os/os2"
import "core:path/filepath"
import "core:strings"

boot :: proc() {
	runtime_arena = new(mem.Arena)
	mem.arena_init(runtime_arena, make([]byte, RUNTIME_ARENA_SIZE))
	runtime_alloc = mem.arena_allocator(runtime_arena)

	state = new(State, runtime_alloc)
	state.topic_cache.allocator = runtime_alloc
	state.context_sessions.allocator = runtime_alloc

	exe_path, exe_err := os2.get_executable_path(runtime_alloc)
	if exe_err != nil do shutdown(1)
	state.exe_path = exe_path
	state.exe_dir = filepath.dir(exe_path, runtime_alloc)

	home := os.get_env("HOME", runtime_alloc)
	home_shards_dir := ""
	if len(home) > 0 {
		home_shards_dir = filepath.join({home, SHARDS_DIR}, runtime_alloc)
	}
	exe_parent := filepath.dir(state.exe_dir, runtime_alloc)
	exe_parent_shards := filepath.join({exe_parent, "shards"}, runtime_alloc)
	if len(home_shards_dir) > 0 {
		state.shards_dir = home_shards_dir
	} else {
		state.shards_dir = exe_parent
	}
	if os.exists(exe_parent_shards) {
		state.shards_dir = exe_parent
	}
	if data_override := os.get_env("SHARD_DATA", runtime_alloc); len(data_override) > 0 {
		state.shards_dir = data_override
	}
	state.index_dir = filepath.join({state.shards_dir, INDEX_DIR}, runtime_alloc)
	state.run_dir = filepath.join({state.shards_dir, RUN_DIR}, runtime_alloc)
	data_dir := state.shards_dir
	state.cache_dir = filepath.join({data_dir, "cache"}, runtime_alloc)
	logger_init()

	load_config()
	blob_read_self()
	load_key()
	congestion_replay()
	load_llm_config()

	state.shard_id = resolve_shard_id()
	index_cleanup_prev()
	index_bootstrap_known_shards()
}


main :: proc() {
	boot()
	context.logger = multi_logger
	defer shutdown()

	log.infof("shard v%s started from %s (id: %s)", VERSION, state.exe_path, state.shard_id)

	state.command = parse_args()

	switch state.command {
	case .Help:
		hel := HELP_TEXT[.Help]
		log.infof("%s", hel[int(state.ai_mode)])
	case .Version:
		if state.ai_mode {
			log.infof("shard %s", VERSION)
		} else {
			log.infof("shard v%s", VERSION)
		}
	case .Info:
		index_write(state.shard_id, state.exe_path)
		info_help := HELP_TEXT[.Info]
		if state.ai_mode {
			log.infof("%s", info_help[int(state.ai_mode)])
		} else {
			log.infof("shard v%s", VERSION)
			log.infof("exe path:    %s", state.exe_path)
			log.infof("shard id:    %s", state.shard_id)
			log.infof("exe code:    %d bytes", len(state.blob.exe_code))
			log.infof("has data:    %v", state.blob.has_data)
			if state.blob.has_data {
				s := &state.blob.shard
				log.infof(
					"catalog:      name=%s purpose=%s tags=%d",
					s.catalog.name,
					s.catalog.purpose,
					len(s.catalog.tags),
				)
				log.infof(
					"gates:        gate=%s descriptors=%d links=%d",
					s.gates.gate,
					len(s.gates.descriptors),
					len(s.gates.shard_links),
				)
				log.infof(
					"thoughts:     processed=%d unprocessed=%d",
					len(s.processed),
					len(s.unprocessed),
				)
				log.infof("manifest:    %d bytes", len(s.manifest))
			}
			log.infof("index dir:   %s", state.index_dir)
			peers := index_list()
			index_sort_tree(peers)
			log.infof("known shards: %d", len(peers))
			for p in peers {
				prefix := index_depth_prefix(p.depth)
				name := p.shard_id
				if len(prefix) > 0 do name = strings.concatenate({prefix, p.shard_id}, runtime_alloc)
				log.infof("  - %s (%s) -> %s", name, p.tree_path, p.exe_path)
			}
		}
	case .Mcp:
		process_stdio()
	case .Compact:
		if !compact() do shutdown(1)
	case .Init:
		if !shard_init() do shutdown(1)
	case .Selftest:
		target := strings.to_lower(strings.trim_space(state.selftest_target), runtime_alloc)
		if len(target) == 0 do target = "guarantees"
		if target == "guarantees" {
			if !selftest_guarantees() do shutdown(1)
		} else {
			log.errorf("unknown selftest suite: %s", state.selftest_target)
			shutdown(1)
		}
	case .Keychain:
		keychain_run()
	case .Daemon, .None:
		daemon_run()
		defer daemon_shutdown()
	}
}
