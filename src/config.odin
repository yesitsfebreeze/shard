package shard

import "core:encoding/json"
import "core:os"
import "core:strings"

// If .shards/config.jsonc doesn't exist, a default config file is generated.
// All values have sane defaults — the system works out of the box.

CONFIG_PATH :: ".shards/config.jsonc"
DEFAULT_CONFIG_FILE :: #load("defaults.jsonc")

Shard_Config :: struct {
	llm_url:                    string, // OpenAI-compatible API base URL
	llm_key:                    string, // API key (any string for ollama)
	llm_model:                  string, // chat model name (used for traverse)
	llm_temperature:            f64, // sampling temperature (chat completions)
	llm_max_tokens:             int, // max tokens in response (chat completions)
	llm_timeout:                int, // HTTP timeout in seconds
	embed_model:                string, // embedding model name (overrides llm_model for /embeddings)
	slot_idle_max:              int, // seconds before idle shard slot is evicted
	evict_interval:             int, // seconds between eviction checks
	max_shards:                 int, // max shards the daemon will manage
	max_related:                int, // max entries in a shard's related gate list
	default_query_limit:        int, // default results for query/search ops
	default_query_budget:       int, // default max content chars for query/access (0 = unlimited)
	default_freshness_weight:   f32, // default freshness weight for search (0.0 = disabled)
	relevance_keyword_weight:   f32, // weight for keyword match (default 0.3)
	relevance_vector_weight:    f32, // weight for vector similarity (default 0.3)
	relevance_freshness_weight: f32, // weight for freshness (default 0.2)
	relevance_usage_weight:     f32, // weight for usage signals (default 0.2)
	fleet_max_parallel:         int, // max concurrent fleet tasks (default 8)
	global_query_threshold:     f32, // gate score threshold for global_query (default 0.1)
	explore_max_results:        int, // default max total results for shard_explore
	explore_max_depth:          int, // default max BFS depth for shard_explore
	traverse_max_rounds:        int, // max LLM rounds per traversal
	traverse_results:           int, // max results to return
	streaming_enabled:          bool, // enable streaming responses for LLM ops
	stream_chunk_size:          int, // chunk size for streaming responses
	compact_threshold:          int, // auto-trigger compaction when unprocessed >= this (0 = disabled)
	cache_compact_threshold:    int, // auto-compact topic cache when entries >= this (0 = disabled)
	// Fulltext search
	fulltext_context_lines:     int, // lines above/below each hit (default 3)
	fulltext_min_score:         f32, // drop excerpts below this score (default 0.10)
	compact_mode:               string, // "lossless" (default) or "lossy"
	log_level:                  string, // log level: debug, info, warn, error
	log_file:                   string, // log file path (empty = stderr only)
	log_format:                 string, // log format: json, text
	log_max_size:               int, // max log file size in MB before rotation
	// HTTP MCP transport
	http_port:                  int,    // port for shard mcp --http (default 3000)
	http_host:                  string, // bind address (default "127.0.0.1")
	// Smart query — LLM-powered compaction during retrieval
	smart_query:                bool, // true = compact retrieved thoughts via LLM (default true)
}


DEFAULT_CONFIG :: Shard_Config {
	llm_url                    = "",
	llm_key                    = "",
	llm_model                  = "",
	llm_temperature            = 0.3,
	llm_max_tokens             = 2048,
	llm_timeout                = 120,
	embed_model                = "nomic-embed-text", // dedicated embedding model for semantic search
	slot_idle_max              = 300, // 5 minutes
	evict_interval             = 30, // 30 seconds
	max_shards                 = 256,
	max_related                = 64,
	default_query_limit        = 5,
	default_query_budget       = 8000, // smart-query default budget (0 = unlimited)
	default_freshness_weight   = 0.0, // disabled by default
	relevance_keyword_weight   = 0.3,
	relevance_vector_weight    = 0.3,
	relevance_freshness_weight = 0.2,
	relevance_usage_weight     = 0.2,
	fleet_max_parallel         = 8,
	global_query_threshold     = 0.2,
	explore_max_results        = 10,
	explore_max_depth          = 3,
	traverse_max_rounds        = 5,
	traverse_results           = 3,
	streaming_enabled          = false, // disabled by default
	stream_chunk_size          = 1024, // 1KB chunks
	compact_threshold          = 100, // auto-trigger at 100 unprocessed thoughts (0 = disabled)
	cache_compact_threshold    = 50, // auto-compact cache topics at 50 entries (0 = disabled)
	fulltext_context_lines     = 3,
	fulltext_min_score         = 0.10,
	compact_mode               = "lossless", // lossless by default
	log_level                  = "info", // default log level
	log_file                   = "", // empty = stderr only
	log_format                 = "text", // text format by default (JSON available)
	log_max_size               = 10, // 10MB max log file size before rotation
	http_port                  = 3000,
	http_host                  = "127.0.0.1",
	smart_query                = true, // enabled by default when LLM is configured
}

_global_config: Shard_Config
_config_loaded: bool

config_load :: proc() -> Shard_Config {
	if _config_loaded do return _global_config

	_global_config = DEFAULT_CONFIG
	_config_apply_json_string(string(DEFAULT_CONFIG_FILE), "embedded defaults")

	data, ok := os.read_entire_file(CONFIG_PATH)
	if !ok {
		debugf("shard: no config at %s — using defaults", CONFIG_PATH)
		_config_write_default()
		_config_loaded = true
		return _global_config
	}
	defer delete(data)

	_config_apply_json_string(string(data), CONFIG_PATH)

	_config_loaded = true

	if _global_config.llm_url != "" {
		embed :=
			_global_config.embed_model if _global_config.embed_model != "" else _global_config.llm_model
		infof(
			"shard: config loaded (llm_model=%s, embed_model=%s, llm_url=%s)",
			_global_config.llm_model,
			embed,
			_global_config.llm_url,
		)
	} else {
		info("shard: config loaded (no LLM configured — keyword search only)")
	}

	return _global_config
}

@(private)
_config_apply_json_string :: proc(content: string, source: string) {
	clean := config_strip_jsonc_comments(content)
	parsed, err := json.parse(transmute([]u8)clean, allocator = context.temp_allocator)
	if err != nil {
		fatalf("shard: invalid JSON in %s: %v", source, err)
		return
	}
	defer json.destroy_value(parsed, context.temp_allocator)

	#partial switch obj in parsed {
	case json.Object:
		_config_apply_json_object(obj)
	case:
		fatalf("shard: invalid config in %s: root must be a JSON object", source)
	}
}

config_strip_jsonc_comments :: proc(content: string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	in_string := false
	escape := false

	for i := 0; i < len(content); i += 1 {
		c := content[i]

		if in_string {
			strings.write_byte(&b, c)
			if escape {
				escape = false
				continue
			}
			if c == '\\' {
				escape = true
				continue
			}
			if c == '"' {
				in_string = false
			}
			continue
		}

		if c == '"' {
			in_string = true
			strings.write_byte(&b, c)
			continue
		}

		if c == '/' && i + 1 < len(content) && content[i + 1] == '/' {
			for i < len(content) && content[i] != '\n' {
				i += 1
			}
			if i < len(content) && content[i] == '\n' {
				strings.write_byte(&b, '\n')
			}
			continue
		}

		strings.write_byte(&b, c)
	}

	return strings.to_string(b)
}

@(private)
_config_apply_json_object :: proc(obj: json.Object) {
	if _, ok := obj["llm_url"]; ok {
		_global_config.llm_url = md_json_get_str(obj, "llm_url")
	}
	if _, ok := obj["llm_key"]; ok {
		_global_config.llm_key = md_json_get_str(obj, "llm_key")
	}
	if _, ok := obj["llm_model"]; ok {
		_global_config.llm_model = md_json_get_str(obj, "llm_model")
	}
	if v, ok := md_json_get_float(obj, "llm_temperature"); ok {
		_global_config.llm_temperature = v
	}
	if _, ok := obj["llm_max_tokens"]; ok {
		_global_config.llm_max_tokens = md_json_get_int(obj, "llm_max_tokens")
	}
	if _, ok := obj["llm_timeout"]; ok {
		_global_config.llm_timeout = md_json_get_int(obj, "llm_timeout")
	}
	if _, ok := obj["embed_model"]; ok {
		_global_config.embed_model = md_json_get_str(obj, "embed_model")
	}

	if _, ok := obj["slot_idle_max"]; ok {
		_global_config.slot_idle_max = md_json_get_int(obj, "slot_idle_max")
	}
	if _, ok := obj["evict_interval"]; ok {
		_global_config.evict_interval = md_json_get_int(obj, "evict_interval")
	}
	if _, ok := obj["max_shards"]; ok {
		_global_config.max_shards = md_json_get_int(obj, "max_shards")
	}
	if _, ok := obj["max_related"]; ok {
		_global_config.max_related = md_json_get_int(obj, "max_related")
	}
	if _, ok := obj["default_query_limit"]; ok {
		_global_config.default_query_limit = md_json_get_int(obj, "default_query_limit")
	}
	if _, ok := obj["query_budget"]; ok {
		_global_config.default_query_budget = md_json_get_int(obj, "query_budget")
	}
	if v, ok := md_json_get_float(obj, "default_freshness_weight"); ok {
		_global_config.default_freshness_weight = f32(v)
	}

	if v, ok := md_json_get_float(obj, "relevance_keyword_weight"); ok {
		_global_config.relevance_keyword_weight = f32(v)
	}
	if v, ok := md_json_get_float(obj, "relevance_vector_weight"); ok {
		_global_config.relevance_vector_weight = f32(v)
	}
	if v, ok := md_json_get_float(obj, "relevance_freshness_weight"); ok {
		_global_config.relevance_freshness_weight = f32(v)
	}
	if v, ok := md_json_get_float(obj, "relevance_usage_weight"); ok {
		_global_config.relevance_usage_weight = f32(v)
	}

	if _, ok := obj["fleet_max_parallel"]; ok {
		_global_config.fleet_max_parallel = md_json_get_int(obj, "fleet_max_parallel")
	}
	if v, ok := md_json_get_float(obj, "global_query_threshold"); ok {
		_global_config.global_query_threshold = f32(v)
	}
	if _, ok := obj["explore_max_results"]; ok {
		_global_config.explore_max_results = md_json_get_int(obj, "explore_max_results")
	}
	if _, ok := obj["explore_max_depth"]; ok {
		_global_config.explore_max_depth = md_json_get_int(obj, "explore_max_depth")
	}
	if _, ok := obj["traverse_max_rounds"]; ok {
		_global_config.traverse_max_rounds = md_json_get_int(obj, "traverse_max_rounds")
	}
	if _, ok := obj["traverse_results"]; ok {
		_global_config.traverse_results = md_json_get_int(obj, "traverse_results")
	}

	if v, ok := md_json_get_bool(obj, "streaming_enabled"); ok {
		_global_config.streaming_enabled = v
	}
	if _, ok := obj["stream_chunk_size"]; ok {
		_global_config.stream_chunk_size = md_json_get_int(obj, "stream_chunk_size")
	}

	if _, ok := obj["compact_threshold"]; ok {
		_global_config.compact_threshold = md_json_get_int(obj, "compact_threshold")
	}
	if _, ok := obj["cache_compact_threshold"]; ok {
		_global_config.cache_compact_threshold = md_json_get_int(obj, "cache_compact_threshold")
	}
	if _, ok := obj["fulltext_context_lines"]; ok {
		_global_config.fulltext_context_lines = md_json_get_int(obj, "fulltext_context_lines")
	}
	if v, ok := md_json_get_float(obj, "fulltext_min_score"); ok {
		_global_config.fulltext_min_score = f32(v)
	}
	if _, ok := obj["compact_mode"]; ok {
		mode := md_json_get_str(obj, "compact_mode")
		if mode == "lossy" || mode == "lossless" {
			_global_config.compact_mode = mode
		}
	}

	if _, ok := obj["log_level"]; ok {
		_global_config.log_level = md_json_get_str(obj, "log_level")
	}
	if _, ok := obj["log_file"]; ok {
		_global_config.log_file = md_json_get_str(obj, "log_file")
	}
	if _, ok := obj["log_format"]; ok {
		_global_config.log_format = md_json_get_str(obj, "log_format")
	}
	if _, ok := obj["log_max_size"]; ok {
		_global_config.log_max_size = md_json_get_int(obj, "log_max_size")
	}

	if _, ok := obj["http_port"]; ok {
		_global_config.http_port = md_json_get_int(obj, "http_port")
	}
	if _, ok := obj["http_host"]; ok {
		_global_config.http_host = md_json_get_str(obj, "http_host")
	}

	if v, ok := md_json_get_bool(obj, "smart_query"); ok {
		_global_config.smart_query = v
	}
}

config_get :: proc() -> Shard_Config {
	if !_config_loaded do config_load()
	return _global_config
}

@(private)
_config_write_default :: proc() {
	s := DEFAULT_CONFIG_FILE
	os.write_entire_file(CONFIG_PATH, s)
}
