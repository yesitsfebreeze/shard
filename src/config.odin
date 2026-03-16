package shard

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

// =============================================================================
// Config — reads .shards/config (key = value format)
// =============================================================================
//
// If .shards/config doesn't exist, a default config file is generated.
// All values have sane defaults — the system works out of the box.
//
// Config file format:
//   # comment
//   KEY value
//

CONFIG_PATH :: ".shards/config"

// =============================================================================
// Config struct — all configurable values in one place
// =============================================================================

Shard_Config :: struct {
	// --- Embeddings (for vector search) ---
	embed_url:     string,   // OpenAI-compatible embeddings endpoint
	embed_key:     string,   // API key (any string for ollama)
	embed_model:   string,   // embedding model name
	embed_timeout: int,      // HTTP timeout in seconds

	// --- Daemon ---
	slot_idle_max:   int,      // seconds before idle shard slot is evicted
	evict_interval:  int,      // seconds between eviction checks
	max_shards:      int,      // max shards the daemon will manage

	// --- Protocol ---
	max_related:     int,      // max entries in a shard's related gate list
	default_query_limit: int,  // default results for query/search ops

	// --- Explore ---
	explore_max_results:  int, // default max total results for shard_explore
	explore_max_depth:    int, // default max BFS depth for shard_explore
}

// =============================================================================
// Defaults
// =============================================================================

DEFAULT_CONFIG :: Shard_Config{
	// Embeddings — unconfigured by default (vector search disabled until set)
	embed_url     = "",
	embed_key     = "",
	embed_model   = "",
	embed_timeout = 30,

	// Daemon
	slot_idle_max   = 300,  // 5 minutes
	evict_interval  = 30,   // 30 seconds
	max_shards      = 64,

	// Protocol
	max_related         = 32,
	default_query_limit = 5,

	// Explore
	explore_max_results = 10,
	explore_max_depth   = 3,
}

DEFAULT_CONFIG_FILE :: `# =============================================================================
# Shard configuration
# =============================================================================
# All values shown are defaults. Uncomment and change as needed.
# Format: KEY value

# --- Embeddings (for vector-based shard routing) ---
# Uses OpenAI-compatible embeddings API format.
# Works with: ollama, OpenAI, Cohere, Together, LM Studio, vLLM, etc.
#
# Example for ollama (local):
#   EMBED_URL   http://localhost:11434/v1/embeddings
#   EMBED_KEY   ollama
#   EMBED_MODEL nomic-embed-text
#
# Example for OpenAI:
#   EMBED_URL   https://api.openai.com/v1/embeddings
#   EMBED_KEY   sk-...
#   EMBED_MODEL text-embedding-3-small

# EMBED_URL
# EMBED_KEY
# EMBED_MODEL
# EMBED_TIMEOUT  30

# --- Daemon ---
# SLOT_IDLE_MAX  300
# EVICT_INTERVAL 30
# MAX_SHARDS     64

# --- Protocol ---
# MAX_RELATED         32
# DEFAULT_QUERY_LIMIT 5

# --- Explore (graph BFS) ---
# EXPLORE_MAX_RESULTS 10
# EXPLORE_MAX_DEPTH   3
`

// =============================================================================
// Global state
// =============================================================================

_global_config: Shard_Config
_config_loaded: bool

// =============================================================================
// Load / Get / Ready
// =============================================================================

config_load :: proc() -> Shard_Config {
	if _config_loaded do return _global_config

	// Start with defaults
	_global_config = DEFAULT_CONFIG

	data, ok := os.read_entire_file(CONFIG_PATH)
	if !ok {
		// No config file — generate the default one
		fmt.eprintln("shard: no config at .shards/config — generating default")
		_config_write_default()
		_config_loaded = true
		return _global_config
	}
	defer delete(data)

	// Parse the config file — format: KEY value (no = signs)
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
		// Embeddings
		case "EMBED_URL":     _global_config.embed_url     = strings.clone(val)
		case "EMBED_KEY":     _global_config.embed_key     = strings.clone(val)
		case "EMBED_MODEL":   _global_config.embed_model   = strings.clone(val)
		case "EMBED_TIMEOUT": _global_config.embed_timeout  = _parse_int(val, 30)
		// Daemon
		case "SLOT_IDLE_MAX":   _global_config.slot_idle_max   = _parse_int(val, 300)
		case "EVICT_INTERVAL":  _global_config.evict_interval  = _parse_int(val, 30)
		case "MAX_SHARDS":      _global_config.max_shards      = _parse_int(val, 64)
		// Protocol
		case "MAX_RELATED":         _global_config.max_related         = _parse_int(val, 32)
		case "DEFAULT_QUERY_LIMIT": _global_config.default_query_limit = _parse_int(val, 5)
		// Explore
		case "EXPLORE_MAX_RESULTS": _global_config.explore_max_results = _parse_int(val, 10)
		case "EXPLORE_MAX_DEPTH":   _global_config.explore_max_depth   = _parse_int(val, 3)
		}
	}

	_config_loaded = true

	if _global_config.embed_url != "" {
		fmt.eprintfln("shard: config loaded (embed_model=%s, embed_url=%s)",
			_global_config.embed_model, _global_config.embed_url)
	} else {
		fmt.eprintln("shard: config loaded (no embeddings configured — keyword search only)")
	}

	return _global_config
}

config_get :: proc() -> Shard_Config {
	if !_config_loaded do config_load()
	return _global_config
}

// =============================================================================
// Internal helpers
// =============================================================================

@(private)
_config_write_default :: proc() {
	s := DEFAULT_CONFIG_FILE
	os.write_entire_file(CONFIG_PATH, transmute([]u8)s)
}

@(private)
_parse_int :: proc(val: string, fallback: int) -> int {
	result, ok := strconv.parse_int(val)
	return ok ? result : fallback
}
