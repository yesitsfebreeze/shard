package shard

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:strings"
import "core:time"
import "core:unicode"

// =============================================================================
// index.odin — unified two-level persistent search index
//
// Replaces vec_index + per-slot Search_Entry[].
// Lives at .shards/.index (JSON). Contains shard-level embeddings for routing
// and thought-level embeddings for precise hits. Falls back to keyword search
// when embeddings are unavailable.
// =============================================================================

// =============================================================================
// Persistence — .shards/.index
// =============================================================================

_index_path :: proc() -> string {
	return ".shards/.index"
}

// index_persist writes node.shard_index to .shards/.index as JSON.
// Does NOT acquire node.mu — caller manages locking.
// File I/O performed inline after serialization.
index_persist :: proc(node: ^Node) {
	if len(node.shard_index.shards) == 0 do return

	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "{\n")
	fmt.sbprintf(&b, "  \"dims\": %d,\n", node.shard_index.dims)
	strings.write_string(&b, "  \"shards\": [\n")

	for shard_entry, si in node.shard_index.shards {
		strings.write_string(&b, "    {\n")
		fmt.sbprintf(&b, "      \"name\": \"%s\",\n", json_escape(shard_entry.name))
		fmt.sbprintf(&b, "      \"text_hash\": %d,\n", shard_entry.text_hash)
		strings.write_string(&b, "      \"embedding\": [")
		for f, fi in shard_entry.embedding {
			if fi > 0 do strings.write_string(&b, ",")
			fmt.sbprintf(&b, "%g", f)
		}
		strings.write_string(&b, "],\n")
		strings.write_string(&b, "      \"thoughts\": [\n")
		for te, ti in shard_entry.thoughts {
			strings.write_string(&b, "        {\n")
			fmt.sbprintf(
				&b,
				"          \"id\": \"%s\",\n",
				id_to_hex(te.id, context.temp_allocator),
			)
			fmt.sbprintf(&b, "          \"text_hash\": %d,\n", te.text_hash)
			fmt.sbprintf(&b, "          \"description\": \"%s\",\n", json_escape(te.description))
			strings.write_string(&b, "          \"embedding\": [")
			for f, fi in te.embedding {
				if fi > 0 do strings.write_string(&b, ",")
				fmt.sbprintf(&b, "%g", f)
			}
			strings.write_string(&b, "]\n")
			if ti < len(shard_entry.thoughts) - 1 {
				strings.write_string(&b, "        },\n")
			} else {
				strings.write_string(&b, "        }\n")
			}
		}
		strings.write_string(&b, "      ]\n")
		if si < len(node.shard_index.shards) - 1 {
			strings.write_string(&b, "    },\n")
		} else {
			strings.write_string(&b, "    }\n")
		}
	}
	strings.write_string(&b, "  ]\n}\n")

	data := transmute([]u8)strings.to_string(b)
	tmp := fmt.tprintf("%s.tmp", _index_path())

	f, ferr := os.open(tmp, os.O_WRONLY | os.O_CREATE | os.O_TRUNC, 0o644)
	if ferr != nil {
		warnf("index: persist open failed: %v", ferr)
		return
	}
	_, werr := os.write(f, data)
	os.close(f)
	if werr != nil {
		warnf("index: persist write failed: %v", werr)
		return
	}
	when ODIN_OS == .Darwin {
		if !os.rename(tmp, _index_path()) {
			warnf("index: persist rename failed")
		}
	} else {
		if rename_err := os.rename(tmp, _index_path()); rename_err != nil {
			warnf("index: persist rename failed: %v", rename_err)
		}
	}
}

// =============================================================================
// Helpers
// =============================================================================

@(private)
_free_indexed_shard :: proc(se: ^Indexed_Shard) {
	delete(se.name)
	delete(se.embedding)
	for &te in se.thoughts {
		delete(te.description)
		delete(te.embedding)
	}
	delete(se.thoughts)
}

@(private)
_shard_file_exists :: proc(node: ^Node, name: string) -> bool {
	for entry in node.registry {
		if entry.name == name {
			return os.exists(entry.data_path)
		}
	}
	return false
}

@(private)
_find_indexed_shard :: proc(node: ^Node, name: string) -> ^Indexed_Shard {
	for &se in node.shard_index.shards {
		if se.name == name do return &se
	}
	return nil
}

// _index_blob_thoughts decrypts all thoughts in a slice and appends Indexed_Thought
// entries to se, collecting descriptions into descs for batch embedding.
@(private)
_index_blob_thoughts :: proc(
	thoughts: []Thought,
	master: Master_Key,
	se: ^Indexed_Shard,
	descs: ^[dynamic]string,
) {
	for thought in thoughts {
		pt, err := thought_decrypt(thought, master, context.temp_allocator)
		if err != .None do continue
		desc := strings.clone(pt.description)
		te := Indexed_Thought {
			id          = thought.id,
			description = desc,
			text_hash   = fnv_hash(desc),
		}
		append(&se.thoughts, te)
		append(descs, desc)
		delete(pt.description, context.temp_allocator)
		delete(pt.content, context.temp_allocator)
	}
}

// =============================================================================
// Load
// =============================================================================

// index_load reads .shards/.index and populates node.shard_index.
// Returns (restored count, list of shard names needing rebuild).
// needs_rebuild is allocated with allocator — caller must delete it.
index_load :: proc(
	node: ^Node,
	allocator := context.allocator,
) -> (
	restored: int,
	needs_rebuild: [dynamic]string,
) {
	needs_rebuild = make([dynamic]string, allocator)

	data, ok := os.read_entire_file(_index_path(), context.temp_allocator)
	if !ok do return 0, needs_rebuild

	parsed, parse_ok := _parse_index_json(string(data), node, allocator)
	if !parse_ok {
		warnf("index: load failed to parse — cold start")
		return 0, needs_rebuild
	}
	_ = parsed

	// Build set of loaded shard names
	loaded := make(map[string]bool, allocator = context.temp_allocator)
	for &se in node.shard_index.shards {
		loaded[se.name] = true
	}

	// Any registry shard not in index needs rebuild
	for entry in node.registry {
		if entry.name == DAEMON_NAME do continue
		if !(entry.name in loaded) {
			append(&needs_rebuild, strings.clone(entry.name, allocator))
		}
	}

	// Drop entries for shards not in registry or whose file is missing
	i := 0
	for i < len(node.shard_index.shards) {
		se := &node.shard_index.shards[i]
		in_registry := false
		for entry in node.registry {
			if entry.name == se.name {
				in_registry = true
				break
			}
		}
		if !in_registry || !_shard_file_exists(node, se.name) {
			_free_indexed_shard(se)
			ordered_remove(&node.shard_index.shards, i)
			continue
		}
		i += 1
	}

	restored = len(node.shard_index.shards)
	infof("index: loaded %d shards, %d need rebuild", restored, len(needs_rebuild))
	return restored, needs_rebuild
}

@(private)
_parse_index_json :: proc(
	data: string,
	node: ^Node,
	allocator := context.allocator,
) -> (
	int,
	bool,
) {
	val, err := json.parse(transmute([]u8)data, allocator = context.temp_allocator)
	if err != .None do return 0, false
	defer json.destroy_value(val, context.temp_allocator)

	root, is_obj := val.(json.Object)
	if !is_obj do return 0, false

	// Parse dims
	if dims_val, ok2 := root["dims"]; ok2 {
		#partial switch d in dims_val {
		case json.Float:
			node.shard_index.dims = int(d)
		case json.Integer:
			node.shard_index.dims = int(d)
		}
	}

	shards_val, has_shards := root["shards"]
	if !has_shards do return 0, false
	shards_arr, is_arr := shards_val.(json.Array)
	if !is_arr do return 0, false

	count := 0
	for shard_item in shards_arr {
		shard_obj, is_shard_obj := shard_item.(json.Object)
		if !is_shard_obj do continue

		name_val, _ := shard_obj["name"]
		name_str, name_ok := name_val.(json.String)
		if !name_ok do continue

		hash_val, _ := shard_obj["text_hash"]
		text_hash: u64
		#partial switch h in hash_val {
		case json.Float:
			text_hash = u64(h)
		case json.Integer:
			text_hash = u64(h)
		}

		se := Indexed_Shard {
			name      = strings.clone(string(name_str), allocator),
			text_hash = text_hash,
			thoughts  = make([dynamic]Indexed_Thought, allocator),
		}

		if emb_val, ok2 := shard_obj["embedding"]; ok2 {
			if emb_arr, is_emb := emb_val.(json.Array); is_emb {
				se.embedding = make([]f32, len(emb_arr), allocator)
				for fv, fi in emb_arr {
					#partial switch f in fv {
					case json.Float:
						se.embedding[fi] = f32(f)
					case json.Integer:
						se.embedding[fi] = f32(f)
					}
				}
			}
		}

		if thoughts_val, ok2 := shard_obj["thoughts"]; ok2 {
			if thoughts_arr, is_ta := thoughts_val.(json.Array); is_ta {
				for thought_item in thoughts_arr {
					thought_obj, is_to := thought_item.(json.Object)
					if !is_to do continue

					id_val, _ := thought_obj["id"]
					id_str, id_ok := id_val.(json.String)
					if !id_ok do continue
					tid, hex_ok := hex_to_id(string(id_str))
					if !hex_ok do continue

					desc_val, _ := thought_obj["description"]
					desc_str, desc_ok := desc_val.(json.String)
					if !desc_ok do continue

					th_hash_val, _ := thought_obj["text_hash"]
					th_hash: u64
					#partial switch h in th_hash_val {
					case json.Float:
						th_hash = u64(h)
					case json.Integer:
						th_hash = u64(h)
					}

					te := Indexed_Thought {
						id          = tid,
						description = strings.clone(string(desc_str), allocator),
						text_hash   = th_hash,
					}

					if emb_val, ok_emb := thought_obj["embedding"]; ok_emb {
						if emb_arr, is_emb := emb_val.(json.Array);
						   is_emb && len(emb_arr) > 0 {
							te.embedding = make([]f32, len(emb_arr), allocator)
							for fv, fi in emb_arr {
								#partial switch f in fv {
								case json.Float:
									te.embedding[fi] = f32(f)
								case json.Integer:
									te.embedding[fi] = f32(f)
								}
							}
						}
					}
					append(&se.thoughts, te)
				}
			}
		}

		append(&node.shard_index.shards, se)
		count += 1
	}
	return count, true
}

// =============================================================================
// Build
// =============================================================================

// index_build does a full rebuild of node.shard_index from all registry shards.
// Frees all existing entries first. Called on cold start or _op_discover.
index_build :: proc(node: ^Node) {
	for &se in node.shard_index.shards {
		_free_indexed_shard(&se)
	}
	delete(node.shard_index.shards)
	node.shard_index.shards = make([dynamic]Indexed_Shard)
	node.shard_index.dims = 0

	for entry in node.registry {
		if entry.name == DAEMON_NAME do continue
		_build_shard_entry(node, entry.name)
	}

	index_persist(node)
	infof("index: built %d shards", len(node.shard_index.shards))
}

// _build_shard_entry loads a shard's blob, decrypts thought descriptions,
// builds Indexed_Thought entries with batch embedding, and appends Indexed_Shard.
@(private)
_build_shard_entry :: proc(node: ^Node, name: string) {
	reg_entry: ^Registry_Entry
	for &e in node.registry {
		if e.name == name {
			reg_entry = &e
			break
		}
	}
	if reg_entry == nil do return

	se := Indexed_Shard {
		name     = strings.clone(name),
		thoughts = make([dynamic]Indexed_Thought),
	}

	// Shard-level embedding
	shard_text := embed_shard_text(reg_entry^)
	se.text_hash = fnv_hash(shard_text)
	if embed_ready() {
		emb, emb_ok := embed_text(shard_text, context.temp_allocator)
		if emb_ok {
			se.embedding = make([]f32, len(emb))
			copy(se.embedding, emb)
			node.shard_index.dims = len(emb)
		}
	}

	// Resolve key
	key_hex := _access_resolve_key(name)
	master: Master_Key
	if key_hex != "" {
		if k, ok := hex_to_key(key_hex); ok {
			master = k
		}
	}

	// Load blob to get thought descriptions
	blob, blob_ok := blob_load(reg_entry.data_path, master)
	if !blob_ok {
		append(&node.shard_index.shards, se)
		return
	}
	defer blob_destroy(&blob)

	descs := make([dynamic]string, context.temp_allocator)
	_index_blob_thoughts(blob.processed[:], master, &se, &descs)
	_index_blob_thoughts(blob.unprocessed[:], master, &se, &descs)

	if embed_ready() && len(descs) > 0 {
		embeddings, emb_ok := embed_texts(descs[:], context.temp_allocator)
		if emb_ok && len(embeddings) == len(se.thoughts) {
			for &te, i in se.thoughts {
				te.embedding = make([]f32, len(embeddings[i]))
				copy(te.embedding, embeddings[i])
			}
		}
	}

	append(&node.shard_index.shards, se)
}

// =============================================================================
// Shard-level mutations
// =============================================================================

// index_update_shard creates or updates the Indexed_Shard entry for a shard.
// Creates if absent (including thought entries). Re-embeds shard if metadata changed.
// Persists on completion.
index_update_shard :: proc(node: ^Node, name: string) {
	reg_entry: ^Registry_Entry
	for &e in node.registry {
		if e.name == name {
			reg_entry = &e
			break
		}
	}
	if reg_entry == nil do return

	shard_text := embed_shard_text(reg_entry^)
	new_hash := fnv_hash(shard_text)

	existing := _find_indexed_shard(node, name)
	if existing == nil {
		// Create new entry with full thought indexing
		_build_shard_entry(node, name)
		index_persist(node)
		return
	}

	// Update existing: re-embed shard if hash changed
	if existing.text_hash != new_hash {
		delete(existing.embedding)
		existing.embedding = nil
		existing.text_hash = new_hash
		if embed_ready() {
			emb, ok := embed_text(shard_text, context.temp_allocator)
			if ok {
				existing.embedding = make([]f32, len(emb))
				copy(existing.embedding, emb)
				node.shard_index.dims = len(emb)
			}
		}
	}
	index_persist(node)
}

// index_remove_shard removes an Indexed_Shard and all its thoughts. Frees memory.
// Does NOT persist — caller must call index_persist after.
index_remove_shard :: proc(node: ^Node, name: string) {
	for i := 0; i < len(node.shard_index.shards); i += 1 {
		if node.shard_index.shards[i].name == name {
			_free_indexed_shard(&node.shard_index.shards[i])
			ordered_remove(&node.shard_index.shards, i)
			return
		}
	}
}

// =============================================================================
// Thought-level mutations
// =============================================================================

// index_add_thought appends an Indexed_Thought to the named shard entry.
// Clones description. Embeds if LLM ready.
// Does NOT persist — caller must call index_persist after.
index_add_thought :: proc(
	node: ^Node,
	shard_name: string,
	id: Thought_ID,
	description: string,
) {
	se := _find_indexed_shard(node, shard_name)
	if se == nil do return

	te := Indexed_Thought {
		id          = id,
		description = strings.clone(description),
		text_hash   = fnv_hash(description),
	}
	if embed_ready() {
		emb, ok := embed_text(description, context.temp_allocator)
		if ok {
			te.embedding = make([]f32, len(emb))
			copy(te.embedding, emb)
			if node.shard_index.dims == 0 do node.shard_index.dims = len(emb)
		}
	}
	append(&se.thoughts, te)
}

// index_update_thought updates description and re-embeds if hash changed.
// Does NOT persist — caller must call index_persist after.
index_update_thought :: proc(
	node: ^Node,
	shard_name: string,
	id: Thought_ID,
	description: string,
) {
	se := _find_indexed_shard(node, shard_name)
	if se == nil do return

	new_hash := fnv_hash(description)
	for &te in se.thoughts {
		if te.id != id do continue
		if te.text_hash == new_hash do return // no change
		delete(te.description)
		te.description = strings.clone(description)
		te.text_hash = new_hash
		delete(te.embedding)
		te.embedding = nil
		if embed_ready() {
			emb, ok := embed_text(description, context.temp_allocator)
			if ok {
				te.embedding = make([]f32, len(emb))
				copy(te.embedding, emb)
			}
		}
		return
	}
}

// index_remove_thought removes an Indexed_Thought by ID. Frees its memory.
// Does NOT persist — caller must call index_persist after.
index_remove_thought :: proc(node: ^Node, shard_name: string, id: Thought_ID) {
	se := _find_indexed_shard(node, shard_name)
	if se == nil do return

	for i := 0; i < len(se.thoughts); i += 1 {
		if se.thoughts[i].id == id {
			delete(se.thoughts[i].description)
			delete(se.thoughts[i].embedding)
			ordered_remove(&se.thoughts, i)
			return
		}
	}
}

// =============================================================================
// Query
// =============================================================================

// index_query_shards returns shards ranked by relevance to query.
// Uses cosine similarity if embeddings present, keyword fallback otherwise.
// Falls back to gate scoring externally if no results returned.
// Uses context.temp_allocator.
index_query_shards :: proc(node: ^Node, query: string, limit: int) -> []Index_Shard_Result {
	results := make([dynamic]Index_Shard_Result, context.temp_allocator)

	if embed_ready() && node.shard_index.dims > 0 {
		q_embed, ok := embed_text(query, context.temp_allocator)
		if ok {
			for &se in node.shard_index.shards {
				if se.embedding == nil do continue
				score := cosine_similarity(q_embed, se.embedding)
				if score > 0.3 {
					append(&results, Index_Shard_Result{name = se.name, score = score})
				}
			}
		}
	}

	// Keyword fallback
	if len(results) == 0 {
		q_tokens := _tokenize(query, context.temp_allocator)
		if len(q_tokens) > 0 {
			for &se in node.shard_index.shards {
				score := _keyword_score(q_tokens, se.name)
				if score > 0 {
					append(&results, Index_Shard_Result{name = se.name, score = score})
				}
			}
		}
	}

	_sort_shard_results(results[:])

	n := min(limit, len(results))
	return results[:n]
}

// index_query_thoughts returns thoughts in a shard ranked by relevance to query.
// Uses context.temp_allocator.
index_query_thoughts :: proc(se: ^Indexed_Shard, query: string) -> []Index_Result {
	results := make([dynamic]Index_Result, context.temp_allocator)

	has_embeddings := len(se.thoughts) > 0 && se.thoughts[0].embedding != nil
	if embed_ready() && has_embeddings {
		q_embed, ok := embed_text(query, context.temp_allocator)
		if ok {
			for &te in se.thoughts {
				if te.embedding == nil do continue
				score := cosine_similarity(q_embed, te.embedding)
				if score > 0.3 {
					append(&results, Index_Result{id = te.id, score = score})
				}
			}
			_sort_index_results(results[:])
			return results[:]
		}
	}

	// Keyword fallback
	q_tokens := _tokenize(query, context.temp_allocator)
	if len(q_tokens) == 0 do return nil
	for &te in se.thoughts {
		score := _keyword_score(q_tokens, te.description)
		if score > 0 {
			append(&results, Index_Result{id = te.id, score = score})
		}
	}
	_sort_index_results(results[:])
	return results[:]
}

@(private)
_sort_shard_results :: proc(results: []Index_Shard_Result) {
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

@(private)
_sort_index_results :: proc(results: []Index_Result) {
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

// =============================================================================
// Scoring — moved from search.odin
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
			if qt == dt || qt_stem == _stem(dt) {
				matches += 1
				break
			}
		}
	}
	return f32(matches) / f32(len(q_tokens))
}

_stem :: proc(token: string) -> string {
	suffixes := [?]string{"tion", "sion", "ment", "ness", "ing", "ous", "ive", "ble", "ed", "er", "ly", "es", "s"}
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

// _thought_matches_tokens checks if a decrypted thought matches any query token.
@(private)
_thought_matches_tokens :: proc(pt: Thought_Plaintext, tokens: []string) -> bool {
	if len(tokens) == 0 do return true
	desc_lower := strings.to_lower(pt.description, context.temp_allocator)
	defer delete(desc_lower, context.temp_allocator)
	for t in tokens {
		if strings.contains(desc_lower, t) do return true
	}
	if pt.content != "" {
		content_lower := strings.to_lower(pt.content, context.temp_allocator)
		defer delete(content_lower, context.temp_allocator)
		for t in tokens {
			if strings.contains(content_lower, t) do return true
		}
	}
	return false
}

// _composite_score blends keyword/vector match, freshness, and usage into one score.
@(private)
_composite_score :: proc(base_score: f32, thought: Thought, now: time.Time) -> f32 {
	cfg := config_get()
	total_weight :=
		cfg.relevance_keyword_weight +
		cfg.relevance_vector_weight +
		cfg.relevance_freshness_weight +
		cfg.relevance_usage_weight
	if total_weight == 0 do return base_score

	match_weight := cfg.relevance_keyword_weight + cfg.relevance_vector_weight
	match_component := base_score * match_weight

	freshness: f32 = 1.0
	if thought.ttl > 0 {
		staleness := _compute_staleness(thought, now)
		freshness = 1.0 - staleness
	}
	freshness_component := freshness * cfg.relevance_freshness_weight

	usage: f32 = 0
	total_usage := f32(thought.read_count) + f32(thought.cite_count) * 2.0
	if total_usage > 0 {
		usage = math.log2(1.0 + total_usage) / math.log2(f32(101.0))
		usage = min(usage, 1.0)
	}
	usage_component := usage * cfg.relevance_usage_weight

	return match_component + freshness_component + usage_component
}

// _compute_staleness calculates how stale a thought is based on its TTL.
// Returns 0.0 for immortal thoughts (ttl=0), or [0.0, 1.0] where 1.0 = fully expired.
_compute_staleness :: proc(thought: Thought, now: time.Time) -> f32 {
	if thought.ttl == 0 do return 0
	if thought.updated_at == "" do return 1
	updated := _parse_rfc3339(thought.updated_at)
	zero_time: time.Time
	if updated == zero_time do return 1
	elapsed_secs := time.duration_seconds(time.diff(updated, now))
	if elapsed_secs < 0 do elapsed_secs = 0
	ratio := f32(elapsed_secs) / f32(thought.ttl)
	return min(ratio, 1.0)
}

// fnv_hash computes a 64-bit FNV-1a hash of s for change detection.
fnv_hash :: proc(s: string) -> u64 {
	h: u64 = 14695981039346656037
	for c in s {
		h ~= u64(c)
		h *= 1099511628211
	}
	return h
}

// =============================================================================
// Time — RFC3339 parsing (moved from search.odin)
// =============================================================================

@(private)
_parse_rfc3339 :: proc(s: string) -> time.Time {
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

// =============================================================================
// Full-text search — windowed excerpt extraction (moved from search.odin)
// =============================================================================

@(private)
_Line_Window :: struct {
	start: int,
	end:   int,
}

@(private)
_compute_windows :: proc(
	hit_indices: []int,
	lines_count: int,
	context_lines: int,
	allocator := context.allocator,
) -> []_Line_Window {
	if len(hit_indices) == 0 || lines_count == 0 do return nil
	windows := make([dynamic]_Line_Window, allocator)
	for hi in hit_indices {
		s := max(0, hi - context_lines)
		e := min(lines_count - 1, hi + context_lines)
		if len(windows) > 0 && s <= windows[len(windows) - 1].end + 1 {
			if e > windows[len(windows) - 1].end {
				windows[len(windows) - 1].end = e
			}
		} else {
			append(&windows, _Line_Window{start = s, end = e})
		}
	}
	return windows[:]
}

@(private)
_fulltext_hit_density :: proc(hit_count: int, total_lines: int) -> f32 {
	if total_lines == 0 do return 0
	return f32(hit_count) / f32(total_lines)
}

// _fulltext_search_thoughts searches one []Thought slice and appends matching
// Fulltext_Excerpt entries to results.
// thoughts: Indexed_Thought slice for description pre-pass (pass nil to skip).
@(private)
_fulltext_search_thoughts :: proc(
	raw_thoughts: []Thought,
	thoughts: []Indexed_Thought,
	master: Master_Key,
	shard_name: string,
	q_tokens: []string,
	context_lines: int,
	min_score: f32,
	results: ^[dynamic]Fulltext_Excerpt,
	allocator: mem.Allocator,
) {
	for thought, ti in raw_thoughts {
		has_desc_hit := false
		if ti < len(thoughts) {
			desc_lower := strings.to_lower(thoughts[ti].description, context.temp_allocator)
			for qt in q_tokens {
				if strings.contains(desc_lower, qt) {
					has_desc_hit = true
					break
				}
			}
		}

		pt, err := thought_decrypt(thought, master, context.temp_allocator)
		if err != .None {
			free_all(context.temp_allocator)
			continue
		}

		lines := strings.split(pt.content, "\n", context.temp_allocator)
		hit_indices := make([dynamic]int, context.temp_allocator)

		for line, li in lines {
			line_lower := strings.to_lower(line, context.temp_allocator)
			for qt in q_tokens {
				if strings.contains(line_lower, qt) {
					append(&hit_indices, li)
					break
				}
			}
		}

		if len(hit_indices) == 0 && !has_desc_hit {
			free_all(context.temp_allocator)
			continue
		}

		if len(hit_indices) > 0 {
			score := _fulltext_hit_density(len(hit_indices), len(lines))
			if score >= min_score {
				windows := _compute_windows(
					hit_indices[:],
					len(lines),
					context_lines,
					context.temp_allocator,
				)
				thought_hex := id_to_hex(thought.id, context.temp_allocator)
				for w in windows {
					excerpt_b := strings.builder_make(context.temp_allocator)
					for li := w.start; li <= w.end; li += 1 {
						is_hit := false
						for hi in hit_indices {
							if hi == li {
								is_hit = true
								break
							}
						}
						if is_hit do strings.write_string(&excerpt_b, ">>> ")
						strings.write_string(&excerpt_b, lines[li])
						if li < w.end do strings.write_string(&excerpt_b, "\n")
					}
					append(
						results,
						Fulltext_Excerpt {
							shard       = strings.clone(shard_name, allocator),
							id          = strings.clone(thought_hex, allocator),
							description = strings.clone(pt.description, allocator),
							score       = score,
							excerpt     = strings.clone(strings.to_string(excerpt_b), allocator),
						},
					)
				}
			}
		}
		free_all(context.temp_allocator)
	}
}

// fulltext_search decrypts all thoughts in a blob and returns windowed excerpts.
// thoughts: Indexed_Thought slice for description pre-pass (from shard_index).
//
// Memory contract:
//   - thought_decrypt is called with context.temp_allocator per thought.
//   - free_all(context.temp_allocator) is called after each thought.
//   - Only excerpt strings are cloned to allocator (persistent).
//   - Caller must free returned []Fulltext_Excerpt and all string fields.
fulltext_search :: proc(
	thoughts: []Indexed_Thought,
	blob: Blob,
	master: Master_Key,
	shard_name: string,
	query: string,
	context_lines: int,
	min_score: f32,
	allocator := context.allocator,
) -> []Fulltext_Excerpt {
	q_tokens := _tokenize(query, context.temp_allocator)
	if len(q_tokens) == 0 do return nil

	results := make([dynamic]Fulltext_Excerpt, allocator)

	_fulltext_search_thoughts(
		blob.processed[:],
		thoughts,
		master,
		shard_name,
		q_tokens,
		context_lines,
		min_score,
		&results,
		allocator,
	)
	// For unprocessed, pass nil so pre-pass is skipped
	_fulltext_search_thoughts(
		blob.unprocessed[:],
		nil,
		master,
		shard_name,
		q_tokens,
		context_lines,
		min_score,
		&results,
		allocator,
	)

	// Sort by score descending
	for i := 1; i < len(results); i += 1 {
		key := results[i]
		j := i - 1
		for j >= 0 && results[j].score < key.score {
			results[j + 1] = results[j]
			j -= 1
		}
		results[j + 1] = key
	}

	return results[:]
}

