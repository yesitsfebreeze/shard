package shard

import "core:math"
import "core:strings"
import "core:time"
import "core:unicode"

import logger "logger"

// =============================================================================
// Search index — build and query
// =============================================================================

build_search_index :: proc(
	index: ^[dynamic]Search_Entry,
	blob: Blob,
	master: Master_Key,
	label: string = "",
) -> bool {
	for &entry in index do delete(entry.embedding)
	clear(index)

	descriptions := make([dynamic]string, context.temp_allocator)
	decrypted_any := false

	_index_thoughts :: proc(
		thoughts: []Thought,
		master: Master_Key,
		index: ^[dynamic]Search_Entry,
		descriptions: ^[dynamic]string,
	) -> bool {
		any := false
		for thought in thoughts {
			pt, err := thought_decrypt(thought, master, context.temp_allocator)
			if err == .None {
				desc := strings.clone(pt.description)
				append(
					index,
					Search_Entry{id = thought.id, description = desc, text_hash = fnv_hash(desc)},
				)
				append(descriptions, desc)
				delete(pt.description, context.temp_allocator)
				delete(pt.content, context.temp_allocator)
				any = true
			}
		}
		return any
	}

	if _index_thoughts(blob.processed[:], master, index, &descriptions) do decrypted_any = true
	if _index_thoughts(blob.unprocessed[:], master, index, &descriptions) do decrypted_any = true

	if embed_ready() && len(descriptions) > 0 {
		embeddings, ok := embed_texts(descriptions[:], context.temp_allocator)
		if ok && len(embeddings) == len(index) {
			for &entry, i in index {
				stored := make([]f32, len(embeddings[i]))
				copy(stored, embeddings[i])
				entry.embedding = stored
			}
			if label != "" do logger.debugf("%s: embedded %d thoughts", label, len(index))
		}
	}

	return decrypted_any
}

search_query :: proc(
	entries: []Search_Entry,
	query: string,
	allocator := context.allocator,
) -> []Search_Result {
	if embed_ready() && _entries_have_embeddings(entries) {
		results := _vector_search(entries, query, allocator)
		if results != nil && len(results) > 0 {
			return results
		}
	}
	return _keyword_search(entries, query, allocator)
}

@(private)
_entries_have_embeddings :: proc(entries: []Search_Entry) -> bool {
	if len(entries) == 0 do return false
	return entries[0].embedding != nil
}

@(private)
_vector_search :: proc(
	entries: []Search_Entry,
	query: string,
	allocator := context.allocator,
) -> []Search_Result {
	q_embed, ok := embed_text(query, context.temp_allocator)
	if !ok do return nil

	results := make([dynamic]Search_Result, allocator)
	for entry in entries {
		if entry.embedding == nil do continue
		score := cosine_similarity(q_embed, entry.embedding)
		if score > 0.3 {
			append(&results, Search_Result{id = entry.id, score = score})
		}
	}
	_sort_results(results[:])
	return results[:]
}

@(private)
_keyword_search :: proc(
	entries: []Search_Entry,
	query: string,
	allocator := context.allocator,
) -> []Search_Result {
	q_tokens := _tokenize(query, context.temp_allocator)
	defer delete(q_tokens, context.temp_allocator)
	if len(q_tokens) == 0 do return nil

	results := make([dynamic]Search_Result, allocator)
	for entry in entries {
		score := _keyword_score(q_tokens, entry.description)
		if score <= 0 do continue
		append(&results, Search_Result{id = entry.id, score = score})
	}
	_sort_results(results[:])
	return results[:]
}

// =============================================================================
// Scoring — keyword, vector, composite, staleness
// =============================================================================

@(private)
_keyword_score :: proc(q_tokens: []string, description: string) -> f32 {
	d_tokens := _tokenize(description, context.temp_allocator)
	defer delete(d_tokens, context.temp_allocator)
	if len(q_tokens) == 0 do return 0
	matches := 0
	for qt in q_tokens {
		qt_stem := _stem(qt)
		for dt in d_tokens {
			if qt == dt || qt_stem == _stem(dt) {matches += 1; break}
		}
	}
	return f32(matches) / f32(len(q_tokens))
}

_stem :: proc(token: string) -> string {
	suffixes := [?]string {
		"tion",
		"sion",
		"ment",
		"ness",
		"ing",
		"ous",
		"ive",
		"ble",
		"ed",
		"er",
		"ly",
		"es",
		"s",
	}
	for suffix in suffixes {
		if len(token) > len(suffix) + 2 && strings.has_suffix(token, suffix) {
			return token[:len(token) - len(suffix)]
		}
	}
	return token
}

@(private)
_tokenize :: proc(s: string, allocator := context.allocator) -> []string {
	tokens := make([dynamic]string, allocator)
	start := -1
	for i := 0; i < len(s); i += 1 {
		c := rune(s[i])
		is_word := unicode.is_letter(c) || unicode.is_digit(c)
		if is_word && start == -1 {
			start = i
		} else if !is_word && start != -1 {
			append(&tokens, strings.to_lower(s[start:i], allocator))
			start = -1
		}
	}
	if start != -1 do append(&tokens, strings.to_lower(s[start:], allocator))
	return tokens[:]
}

// Check if a decrypted thought matches any of the query tokens
@(private)
_thought_matches_tokens :: proc(pt: Thought_Plaintext, tokens: []string) -> bool {
	if len(tokens) == 0 do return true

	// Check description
	desc_lower := strings.to_lower(pt.description, context.temp_allocator)
	defer delete(desc_lower, context.temp_allocator)

	for t in tokens {
		if strings.contains(desc_lower, t) {
			return true
		}
	}

	// Check content
	if pt.content != "" {
		content_lower := strings.to_lower(pt.content, context.temp_allocator)
		defer delete(content_lower, context.temp_allocator)
		for t in tokens {
			if strings.contains(content_lower, t) {
				return true
			}
		}
	}

	return false
}

@(private)
_sort_results :: proc(results: []Search_Result) {
	// Simple insertion sort — fine for typical result counts
	for i := 1; i < len(results); i += 1 {
		key := results[i]
		j := i - 1
		for j >= 0 && results[j].score < key.score {
			results[j + 1] = results[j]
			j -= 1
		}
		results[j + 1] = key
	}
}

// _composite_score blends keyword/vector match, freshness, and usage into one score.
// Formula: (match * (kw+vw)) + (freshness * fw) + (usage * uw)
// where kw+vw+fw+uw should sum to ~1.0 (configurable).
@(private)
_composite_score :: proc(base_score: f32, thought: Thought, now: time.Time) -> f32 {
	cfg := config_get()

	// Guard: if all weights are zero, return base_score
	total_weight :=
		cfg.relevance_keyword_weight +
		cfg.relevance_vector_weight +
		cfg.relevance_freshness_weight +
		cfg.relevance_usage_weight
	if total_weight == 0 do return base_score

	// Match component (keyword or vector — already computed)
	match_weight := cfg.relevance_keyword_weight + cfg.relevance_vector_weight
	match_component := base_score * match_weight

	// Freshness component: 1.0 = perfectly fresh, 0.0 = fully stale
	freshness: f32 = 1.0
	if thought.ttl > 0 {
		staleness := _compute_staleness(thought, now)
		freshness = 1.0 - staleness
	}
	freshness_component := freshness * cfg.relevance_freshness_weight

	// Usage component: log-scaled read+cite count, normalized to 0-1
	usage: f32 = 0
	total_usage := f32(thought.read_count) + f32(thought.cite_count) * 2.0
	if total_usage > 0 {
		// log2(1 + total) / log2(1 + 100) — caps at ~1.0 for 100 interactions
		usage = math.log2(1.0 + total_usage) / math.log2(f32(101.0))
		usage = min(usage, 1.0)
	}
	usage_component := usage * cfg.relevance_usage_weight

	return match_component + freshness_component + usage_component
}

// _compute_staleness calculates how stale a thought is based on its TTL.
// Returns 0.0 for immortal thoughts (ttl=0), or a value in [0.0, 1.0] where
// 1.0 means fully expired. Based on elapsed time since updated_at vs TTL.
_compute_staleness :: proc(thought: Thought, now: time.Time) -> f32 {
	if thought.ttl == 0 do return 0 // immortal
	if thought.updated_at == "" do return 1 // no timestamp = maximally stale

	updated := _parse_rfc3339(thought.updated_at)
	zero_time: time.Time
	if updated == zero_time do return 1 // unparseable = maximally stale

	elapsed_secs := time.duration_seconds(time.diff(updated, now))
	if elapsed_secs < 0 do elapsed_secs = 0
	ratio := f32(elapsed_secs) / f32(thought.ttl)
	return min(ratio, 1.0)
}

// =============================================================================
// Time — RFC3339 parsing
// =============================================================================

// _parse_rfc3339 parses "YYYY-MM-DDThh:mm:ssZ" into time.Time.
// Returns zero time on failure.
@(private)
_parse_rfc3339 :: proc(s: string) -> time.Time {
	// Expected format: 2026-03-16T12:34:56Z (exactly 20 chars)
	if len(s) < 19 do return {}
	y, y_ok := _atoi4(s[0:4])
	m, m_ok := _atoi2(s[5:7])
	d, d_ok := _atoi2(s[8:10])
	h, h_ok := _atoi2(s[11:13])
	mn, mn_ok := _atoi2(s[14:16])
	sc, sc_ok := _atoi2(s[17:19])
	if !y_ok || !m_ok || !d_ok || !h_ok || !mn_ok || !sc_ok do return {}

	dt, dt_ok := time.datetime_to_time(i64(y), i64(m), i64(d), i64(h), i64(mn), i64(sc))
	if !dt_ok do return {}
	return dt
}

@(private)
_atoi2 :: proc(s: string) -> (int, bool) {
	if len(s) < 2 do return 0, false
	d0 := int(s[0]) - '0'
	d1 := int(s[1]) - '0'
	if d0 < 0 || d0 > 9 || d1 < 0 || d1 > 9 do return 0, false
	return d0 * 10 + d1, true
}

@(private)
_atoi4 :: proc(s: string) -> (int, bool) {
	if len(s) < 4 do return 0, false
	result := 0
	for i in 0 ..< 4 {
		d := int(s[i]) - '0'
		if d < 0 || d > 9 do return 0, false
		result = result * 10 + d
	}
	return result, true
}

// fnv_hash computes a 64-bit FNV-1a hash of s. Used by build_search_index to
// track per-entry content hashes for change detection.
fnv_hash :: proc(s: string) -> u64 {
	h: u64 = 14695981039346656037
	for c in s {
		h ~= u64(c)
		h *= 1099511628211
	}
	return h
}
