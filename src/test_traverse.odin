package shard

import "core:strings"
import "core:testing"
import "core:time"

// =============================================================================
// Layered traversal tests
// =============================================================================

// _make_test_daemon builds a daemon node with the given shard configurations.
// Each shard config creates a registry entry, a loaded slot with encrypted thoughts,
// and a search index. Returns a node ready for dispatch.
@(private)
Test_Shard_Config :: struct {
	name:     string,
	purpose:  string,
	positive: []string,
	related:  []string,
	thoughts: []Thought_Plaintext,
}

@(private)
_make_test_daemon :: proc(key: Master_Key, configs: []Test_Shard_Config) -> Node {
	node := Node {
		name = "daemon",
		is_daemon = true,
		blob = Blob {
			processed = make([dynamic]Thought),
			unprocessed = make([dynamic]Thought),
			description = make([dynamic]string),
			positive = make([dynamic]string),
			negative = make([dynamic]string),
			related = make([dynamic]string),
		},
		registry = make([dynamic]Registry_Entry),
		slots = make(map[string]^Shard_Slot),
		event_queue = make(Event_Queue),
	}

	for cfg in configs {
		slot := new(Shard_Slot)
		slot.name = cfg.name
		slot.loaded = true
		slot.key_set = true
		slot.master = key
		slot.last_access = time.now()
		slot.blob = Blob {
			processed = make([dynamic]Thought),
			unprocessed = make([dynamic]Thought),
			description = make([dynamic]string),
			positive = make([dynamic]string),
			negative = make([dynamic]string),
			related = make([dynamic]string),
			master = key,
			catalog = Catalog{name = cfg.name, purpose = cfg.purpose},
		}

		// Set positive gates
		for p in cfg.positive {
			append(&slot.blob.positive, p)
		}

		// Set related
		for r in cfg.related {
			append(&slot.blob.related, r)
		}

		// Add thoughts
		slot.index = make([dynamic]Search_Entry)
		for pt_cfg in cfg.thoughts {
			tid := new_thought_id()
			thought, _ := thought_create(key, tid, pt_cfg)
			thought.created_at = _format_time(time.now())
			thought.updated_at = _format_time(time.now())
			append(&slot.blob.unprocessed, thought)

			// Build index entry
			append(
				&slot.index,
				Search_Entry {
					id = tid,
					description = pt_cfg.description,
					text_hash = fnv_hash(pt_cfg.description),
				},
			)
		}

		// Clone positive/related for registry entry
		pos_clone := make([]string, len(cfg.positive))
		for p, i in cfg.positive {pos_clone[i] = p}
		rel_clone := make([]string, len(cfg.related))
		for r, i in cfg.related {rel_clone[i] = r}

		append(
			&node.registry,
			Registry_Entry {
				name = cfg.name,
				thought_count = len(cfg.thoughts),
				catalog = Catalog{name = cfg.name, purpose = cfg.purpose},
				gate_positive = pos_clone,
				gate_related = rel_clone,
			},
		)
		node.slots[cfg.name] = slot
	}

	return node
}

@(test)
test_traverse_layer0_returns_shard_names :: proc(t: ^testing.T) {
	key := Master_Key {
		1,
		2,
		3,
		4,
		5,
		6,
		7,
		8,
		9,
		10,
		11,
		12,
		13,
		14,
		15,
		16,
		17,
		18,
		19,
		20,
		21,
		22,
		23,
		24,
		25,
		26,
		27,
		28,
		29,
		30,
		31,
		32,
	}

	configs := []Test_Shard_Config {
		{
			name = "alpha",
			purpose = "Database design and SQL queries",
			positive = {"database", "sql", "schema"},
			thoughts = {
				{
					description = "Database schema overview",
					content = "Tables and relations for the main database",
				},
			},
		},
		{
			name = "beta",
			purpose = "Networking and HTTP protocols",
			positive = {"networking", "http", "tcp"},
			thoughts = {
				{description = "HTTP request handling", content = "How we handle HTTP requests"},
			},
		},
	}

	node := _make_test_daemon(key, configs)

	// Layer 0: should return shard names, not thought content
	req := Request {
		op           = "traverse",
		query        = "database schema",
		max_branches = 5,
		layer        = 0,
	}
	result, handled := daemon_dispatch(&node, req)
	testing.expect(t, handled, "traverse must be handled by daemon")
	testing.expect(t, strings.contains(result, "status: ok"), "traverse L0 must return ok")
	testing.expect(t, strings.contains(result, "alpha"), "traverse L0 must find alpha shard")
	// Layer 0 should NOT contain thought content
	testing.expect(
		t,
		!strings.contains(result, "Tables and relations"),
		"L0 must not include thought content",
	)
}

@(test)
test_traverse_layer1_returns_thought_content :: proc(t: ^testing.T) {
	key := Master_Key {
		1,
		2,
		3,
		4,
		5,
		6,
		7,
		8,
		9,
		10,
		11,
		12,
		13,
		14,
		15,
		16,
		17,
		18,
		19,
		20,
		21,
		22,
		23,
		24,
		25,
		26,
		27,
		28,
		29,
		30,
		31,
		32,
	}

	configs := []Test_Shard_Config {
		{
			name = "alpha",
			purpose = "Database design and SQL queries",
			positive = {"database", "sql", "schema"},
			thoughts = {
				{
					description = "Database schema overview",
					content = "Tables and relations for the main database",
				},
				{
					description = "SQL query optimization",
					content = "Index strategies for fast queries",
				},
			},
		},
		{
			name = "beta",
			purpose = "Networking and HTTP protocols",
			positive = {"networking", "http", "tcp"},
			thoughts = {
				{description = "HTTP request handling", content = "How we handle HTTP requests"},
			},
		},
	}

	node := _make_test_daemon(key, configs)

	// Layer 1: should search within matched shards and return thought content
	req := Request {
		op           = "traverse",
		query        = "database schema",
		max_branches = 5,
		layer        = 1,
	}
	result, handled := daemon_dispatch(&node, req)
	testing.expect(t, handled, "traverse must be handled by daemon")
	testing.expect(t, strings.contains(result, "status: ok"), "traverse L1 must return ok")
	// Layer 1 should contain thought descriptions and content from alpha
	testing.expect(
		t,
		strings.contains(result, "Database schema overview"),
		"L1 must include thought description from matched shard",
	)
	testing.expect(
		t,
		strings.contains(result, "Tables and relations"),
		"L1 must include thought content from matched shard",
	)
	// Result IDs should be in shard_name/thought_hex format
	testing.expect(
		t,
		strings.contains(result, "alpha/"),
		"L1 result IDs must be prefixed with shard name",
	)
	// Should NOT contain thoughts from non-matching shard
	testing.expect(
		t,
		!strings.contains(result, "HTTP request handling"),
		"L1 must not include thoughts from non-matching shard",
	)
}

@(test)
test_traverse_layer2_follows_related :: proc(t: ^testing.T) {
	key := Master_Key {
		1,
		2,
		3,
		4,
		5,
		6,
		7,
		8,
		9,
		10,
		11,
		12,
		13,
		14,
		15,
		16,
		17,
		18,
		19,
		20,
		21,
		22,
		23,
		24,
		25,
		26,
		27,
		28,
		29,
		30,
		31,
		32,
	}

	configs := []Test_Shard_Config {
		{
			name = "alpha",
			purpose = "Database design and SQL queries",
			positive = {"database", "sql", "schema"},
			related = {"gamma"},
			thoughts = {
				{
					description = "Database schema overview",
					content = "Tables and relations for the main database",
				},
			},
		},
		{
			name = "beta",
			purpose = "Networking and HTTP protocols",
			positive = {"networking", "http", "tcp"},
			thoughts = {
				{description = "HTTP request handling", content = "How we handle HTTP requests"},
			},
		},
		{
			name = "gamma",
			purpose = "Database migration tools",
			positive = {"migration", "schema", "versioning"},
			thoughts = {
				{
					description = "Migration strategy for schema changes",
					content = "How to safely evolve database schemas",
				},
			},
		},
	}

	node := _make_test_daemon(key, configs)

	// Layer 2: should search matched shards AND related shards
	req := Request {
		op           = "traverse",
		query        = "database schema",
		max_branches = 5,
		layer        = 2,
	}
	result, handled := daemon_dispatch(&node, req)
	testing.expect(t, handled, "traverse must be handled by daemon")
	testing.expect(t, strings.contains(result, "status: ok"), "traverse L2 must return ok")
	// Should contain alpha's thoughts (direct match)
	testing.expect(
		t,
		strings.contains(result, "Database schema overview"),
		"L2 must include thoughts from matched shard",
	)
	// Should contain gamma's thoughts (related to alpha)
	testing.expect(
		t,
		strings.contains(result, "Migration strategy"),
		"L2 must include thoughts from related shard",
	)
	// Should NOT contain beta's thoughts (not matched, not related)
	testing.expect(
		t,
		!strings.contains(result, "HTTP request handling"),
		"L2 must not include thoughts from unrelated shard",
	)
}

@(test)
test_traverse_layer1_budget_truncation :: proc(t: ^testing.T) {
	key := Master_Key {
		1,
		2,
		3,
		4,
		5,
		6,
		7,
		8,
		9,
		10,
		11,
		12,
		13,
		14,
		15,
		16,
		17,
		18,
		19,
		20,
		21,
		22,
		23,
		24,
		25,
		26,
		27,
		28,
		29,
		30,
		31,
		32,
	}

	long_content := "This is a very long content string that should be truncated when a budget is applied during layer 1 traversal of multiple shards"

	configs := []Test_Shard_Config {
		{
			name = "alpha",
			purpose = "Database design and SQL queries",
			positive = {"database", "sql", "schema"},
			thoughts = {{description = "Database schema overview", content = long_content}},
		},
	}

	node := _make_test_daemon(key, configs)

	// Layer 1 with small budget
	req := Request {
		op           = "traverse",
		query        = "database schema",
		max_branches = 5,
		layer        = 1,
		budget       = 20,
	}
	result, handled := daemon_dispatch(&node, req)
	testing.expect(t, handled, "traverse must be handled by daemon")
	testing.expect(
		t,
		strings.contains(result, "status: ok"),
		"traverse L1 with budget must return ok",
	)
	testing.expect(
		t,
		strings.contains(result, "truncated: true"),
		"L1 with budget must set truncated flag",
	)
	// Full content should NOT be present
	testing.expect(
		t,
		!strings.contains(result, long_content),
		"full content must not be present when budget is small",
	)
}

@(test)
test_traverse_layer_parse :: proc(t: ^testing.T) {
	req, ok := md_parse_request("---\nop: traverse\nquery: test\nlayer: 2\n---\n")
	testing.expect(t, ok, "parse must succeed")
	testing.expect(t, req.layer == 2, "layer must be parsed as 2")
	testing.expect(t, req.op == "traverse", "op must be traverse")
}

@(test)
test_traverse_layer0_unchanged :: proc(t: ^testing.T) {
	// Verify that layer 0 (default) behavior is exactly the same as before
	key := Master_Key {
		1,
		2,
		3,
		4,
		5,
		6,
		7,
		8,
		9,
		10,
		11,
		12,
		13,
		14,
		15,
		16,
		17,
		18,
		19,
		20,
		21,
		22,
		23,
		24,
		25,
		26,
		27,
		28,
		29,
		30,
		31,
		32,
	}

	configs := []Test_Shard_Config {
		{
			name = "alpha",
			purpose = "Database design and SQL queries",
			positive = {"database", "sql"},
			thoughts = {{description = "Schema doc", content = "Content"}},
		},
	}

	node := _make_test_daemon(key, configs)

	// Default (no layer specified) should behave as Layer 0
	req := Request {
		op           = "traverse",
		query        = "database",
		max_branches = 5,
	}
	result, handled := daemon_dispatch(&node, req)
	testing.expect(t, handled, "traverse must be handled by daemon")
	testing.expect(t, strings.contains(result, "status: ok"), "default traverse must return ok")
	testing.expect(t, strings.contains(result, "alpha"), "default traverse must find alpha shard")
	// Default should return shard names, not thought content
	testing.expect(
		t,
		!strings.contains(result, "Schema doc"),
		"default traverse must not include thought descriptions",
	)
}
