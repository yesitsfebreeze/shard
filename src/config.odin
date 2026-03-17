package shard

import "core:os"
import "core:strconv"
import "core:strings"

import logger "logger"
import "core:testing"

// If .shards/config doesn't exist, a default config file is generated.
// All values have sane defaults — the system works out of the box.
//
// Config file format:
//   # comment
//   KEY value

CONFIG_PATH :: ".shards/config"
DEFAULT_CONFIG_FILE :: #load("default.config")

Shard_Config :: struct {
	llm_url:                    string, // OpenAI-compatible API base URL
	llm_key:                    string, // API key (any string for ollama)
	llm_model:                  string, // chat model name (used for traverse)
	llm_temperature:            f64, // sampling temperature (chat completions)
	llm_max_tokens:             int, // max tokens in response (chat completions)
	llm_timeout:                int, // HTTP timeout in seconds
	embed_model:                string, // embedding model (overrides llm_model for /embeddings)
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
	compact_mode:               string, // "lossless" (default) or "lossy"
	log_level:                  string, // log level: debug, info, warn, error
	log_file:                   string, // log file path (empty = stderr only)
	log_format:                 string, // log format: json, text
	log_max_size:               int, // max log file size in MB before rotation
}


DEFAULT_CONFIG :: Shard_Config {
	llm_url                    = "",
	llm_key                    = "",
	llm_model                  = "",
	llm_temperature            = 0.3,
	llm_max_tokens             = 2048,
	llm_timeout                = 120,
	embed_model                = "", // empty = use llm_model for embeddings too
	slot_idle_max              = 300, // 5 minutes
	evict_interval             = 30, // 30 seconds
	max_shards                 = 64,
	max_related                = 32,
	default_query_limit        = 5,
	default_query_budget       = 0, // 0 = unlimited (agents can override per-request)
	default_freshness_weight   = 0.0, // disabled by default
	relevance_keyword_weight   = 0.3,
	relevance_vector_weight    = 0.3,
	relevance_freshness_weight = 0.2,
	relevance_usage_weight     = 0.2,
	fleet_max_parallel         = 8,
	global_query_threshold     = 0.1,
	explore_max_results        = 10,
	explore_max_depth          = 3,
	traverse_max_rounds        = 5,
	traverse_results           = 3,
	streaming_enabled          = false, // disabled by default
	stream_chunk_size          = 1024, // 1KB chunks
	compact_threshold          = 20, // auto-trigger at 20 unprocessed thoughts (0 = disabled)
	compact_mode               = "lossless", // lossless by default
	log_level                  = "info", // default log level
	log_file                   = "", // empty = stderr only
	log_format                 = "text", // text format by default (JSON available)
	log_max_size               = 10, // 10MB max log file size before rotation
}

_global_config: Shard_Config
_config_loaded: bool

config_load :: proc() -> Shard_Config {
	if _config_loaded do return _global_config

	_global_config = DEFAULT_CONFIG

	data, ok := os.read_entire_file(CONFIG_PATH)
	if !ok {
		logger.errf("shard: no config at .shards/config — generating default")
		_config_write_default()
		_config_loaded = true
		return _global_config
	}
	defer delete(data)

	content := string(data)
	for line in strings.split_lines_iterator(&content) {
		trimmed := strings.trim_space(line)
		if trimmed == "" || strings.has_prefix(trimmed, "#") do continue

		// Split on first whitespace
		sp := strings.index_any(trimmed, " \t")
		if sp == -1 do continue

		key := trimmed[:sp]
		val := strings.trim_space(trimmed[sp + 1:])
		if val == "" do continue

		switch key {
		// LLM
		case "LLM_URL":
			_global_config.llm_url = strings.clone(val)
		case "LLM_KEY":
			_global_config.llm_key = strings.clone(val)
		case "LLM_MODEL":
			_global_config.llm_model = strings.clone(val)
		case "LLM_TEMPERATURE":
			_global_config.llm_temperature = _parse_float(val, 0.3)
		case "LLM_MAX_TOKENS":
			_global_config.llm_max_tokens = _parse_int(val, 2048)
		case "LLM_TIMEOUT":
			_global_config.llm_timeout = _parse_int(val, 120)
		case "EMBED_MODEL":
			_global_config.embed_model = strings.clone(val)
		// Daemon
		case "SLOT_IDLE_MAX":
			_global_config.slot_idle_max = _parse_int(val, 300)
		case "EVICT_INTERVAL":
			_global_config.evict_interval = _parse_int(val, 30)
		case "MAX_SHARDS":
			_global_config.max_shards = _parse_int(val, 64)
		// Protocol
		case "MAX_RELATED":
			_global_config.max_related = _parse_int(val, 32)
		case "DEFAULT_QUERY_LIMIT":
			_global_config.default_query_limit = _parse_int(val, 5)
		case "DEFAULT_QUERY_BUDGET":
			_global_config.default_query_budget = _parse_int(val, 0)
		// Staleness
		case "DEFAULT_FRESHNESS_WEIGHT":
			_global_config.default_freshness_weight = f32(_parse_float(val, 0.0))
		// Relevance scoring
		case "RELEVANCE_KEYWORD_WEIGHT":
			_global_config.relevance_keyword_weight = f32(_parse_float(val, 0.3))
		case "RELEVANCE_VECTOR_WEIGHT":
			_global_config.relevance_vector_weight = f32(_parse_float(val, 0.3))
		case "RELEVANCE_FRESHNESS_WEIGHT":
			_global_config.relevance_freshness_weight = f32(_parse_float(val, 0.2))
		case "RELEVANCE_USAGE_WEIGHT":
			_global_config.relevance_usage_weight = f32(_parse_float(val, 0.2))
		// Fleet dispatch
		case "FLEET_MAX_PARALLEL":
			_global_config.fleet_max_parallel = _parse_int(val, 8)
		// Cross-shard queries
		case "GLOBAL_QUERY_THRESHOLD":
			_global_config.global_query_threshold = f32(_parse_float(val, 0.1))
		// Explore
		case "EXPLORE_MAX_RESULTS":
			_global_config.explore_max_results = _parse_int(val, 10)
		case "EXPLORE_MAX_DEPTH":
			_global_config.explore_max_depth = _parse_int(val, 3)
		// Traverse
		case "TRAVERSE_MAX_ROUNDS":
			_global_config.traverse_max_rounds = _parse_int(val, 5)
		case "TRAVERSE_RESULTS":
			_global_config.traverse_results = _parse_int(val, 3)
		// Streaming
		case "STREAMING_ENABLED":
			_global_config.streaming_enabled = _parse_bool(val)
		case "STREAM_CHUNK_SIZE":
			_global_config.stream_chunk_size = _parse_int(val, 1024)
		// Compaction
		case "COMPACT_THRESHOLD":
			_global_config.compact_threshold = _parse_int(val, 20)
		case "COMPACT_MODE":
			if val == "lossy" || val == "lossless" {
				_global_config.compact_mode = strings.clone(val)
			}
		// Logging
		case "LOG_LEVEL":
			_global_config.log_level = strings.clone(val)
		case "LOG_FILE":
			_global_config.log_file = strings.clone(val)
		case "LOG_FORMAT":
			_global_config.log_format = strings.clone(val)
		case "LOG_MAX_SIZE":
			_global_config.log_max_size = _parse_int(val, 10)
		}
	}

	_config_loaded = true

	if _global_config.llm_url != "" {
		logger.infof(
			"shard: config loaded (llm_model=%s, llm_url=%s)",
			_global_config.llm_model,
			_global_config.llm_url,
		)
	} else {
		logger.info("shard: config loaded (no LLM configured — keyword search only)")
	}

	return _global_config
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

@(private)
_parse_int :: proc(val: string, fallback: int) -> int {
	result, ok := strconv.parse_int(val)
	return ok ? result : fallback
}

@(private)
_parse_float :: proc(val: string, fallback: f64) -> f64 {
	result, ok := strconv.parse_f64(val)
	return ok ? result : fallback
}

@(private)
_parse_bool :: proc(val: string) -> bool {
	lower := strings.to_lower(val)
	return lower == "true" || lower == "1" || lower == "yes" || lower == "on"
}


// `# =============================================================================
// # Shard configuration
// # =============================================================================
// # All values shown are defaults. Uncomment and change as needed.
// # Format: KEY value

// # --- LLM (used for embeddings and AI-driven traversal) ---
// # Uses OpenAI-compatible API format (base URL — /embeddings and
// # /chat/completions are appended automatically).
// # Works with: ollama, OpenAI, Groq, Together, LM Studio, vLLM, etc.
// #
// # Example for ollama (local):
// #   LLM_URL   http://localhost:11434/v1
// #   LLM_KEY   ollama
// #   LLM_MODEL llama3.2
// #
// # Example for OpenAI:
// #   LLM_URL   https://api.openai.com/v1
// #   LLM_KEY   sk-...
// #   LLM_MODEL gpt-4.1-nano

// # LLM_URL
// # LLM_KEY
// # LLM_MODEL
// # LLM_TEMPERATURE 0.3
// # LLM_MAX_TOKENS  2048
// # LLM_TIMEOUT     120
// # EMBED_MODEL              (optional — uses LLM_MODEL if not set)

// # --- Daemon ---
// # SLOT_IDLE_MAX  300
// # EVICT_INTERVAL 30
// # MAX_SHARDS     64

// # --- Protocol ---
// # MAX_RELATED         32
// # DEFAULT_QUERY_LIMIT 5
// # DEFAULT_QUERY_BUDGET 0

// # --- Staleness ---
// # DEFAULT_FRESHNESS_WEIGHT 0.0

// # --- Relevance scoring ---
// # RELEVANCE_KEYWORD_WEIGHT  0.3
// # RELEVANCE_VECTOR_WEIGHT   0.3
// # RELEVANCE_FRESHNESS_WEIGHT 0.2
// # RELEVANCE_USAGE_WEIGHT    0.2

// # --- Fleet dispatch ---
// # FLEET_MAX_PARALLEL 8

// # --- Cross-shard queries ---
// # GLOBAL_QUERY_THRESHOLD 0.1

// # --- Explore (graph BFS) ---
// # EXPLORE_MAX_RESULTS 10
// # EXPLORE_MAX_DEPTH   3

// # --- Traverse (AI-driven) ---
// # TRAVERSE_MAX_ROUNDS 5
// # TRAVERSE_RESULTS    3

// # --- Streaming ---
// # STREAMING_ENABLED  false
// # STREAM_CHUNK_SIZE 1024

// # --- Auto-compaction ---
// # COMPACT_THRESHOLD 20    (0 = disabled, emit needs_compaction when unprocessed >= N)
// # COMPACT_MODE      lossless  (lossless or lossy)

// # --- Logging ---
// # LOG_LEVEL   info      (debug, info, warn, error)
// # LOG_FILE             (empty = stderr only)
// # LOG_FORMAT  text     (text or json)
// # LOG_MAX_SIZE 10     (max MB before rotation)
// `

// =============================================================================
// Config tests
// =============================================================================

@(test)
test_config_defaults :: proc(t: ^testing.T) {
	cfg := DEFAULT_CONFIG
	testing.expect(t, cfg.slot_idle_max == 300, "slot_idle_max default must be 300")
	testing.expect(t, cfg.evict_interval == 30, "evict_interval default must be 30")
	testing.expect(t, cfg.max_shards == 64, "max_shards default must be 64")
	testing.expect(t, cfg.default_query_limit == 5, "default_query_limit must be 5")
	testing.expect(t, cfg.default_query_budget == 0, "default_query_budget must be 0 (unlimited)")
	testing.expect(t, cfg.relevance_keyword_weight == 0.3, "relevance_keyword_weight must be 0.3")
	testing.expect(t, cfg.fleet_max_parallel == 8, "fleet_max_parallel must be 8")
	testing.expect(t, cfg.compact_threshold == 20, "compact_threshold must be 20")
	testing.expect(t, cfg.compact_mode == "lossless", "compact_mode must be lossless")
	testing.expect(t, !cfg.streaming_enabled, "streaming must be disabled by default")
}
