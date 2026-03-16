package shard

import "core:encoding/json"
import "core:fmt"
import "core:math"
import os2 "core:os/os2"
import "core:strings"

// =============================================================================
// Embeddings — vector search for semantic shard routing
// =============================================================================
//
// Supports OpenAI-compatible embedding APIs (OpenAI, ollama, Cohere, etc.)
// Each shard's catalog + gates are embedded into a vector. Queries are
// embedded and compared via cosine similarity.
//
// Config (.shards/config):
//   LLM_URL    http://localhost:11434/v1    (base URL — /embeddings appended automatically)
//   LLM_KEY    ollama
//   LLM_MODEL  nomic-embed-text
//

// =============================================================================
// API
// =============================================================================

embed_ready :: proc() -> bool {
	cfg := config_get()
	model := cfg.embed_model if cfg.embed_model != "" else cfg.llm_model
	return cfg.llm_url != "" && model != ""
}

embed_text :: proc(text: string, allocator := context.allocator) -> ([]f32, bool) {
	cfg := config_get()
	if cfg.llm_url == "" do return nil, false

	model := cfg.embed_model if cfg.embed_model != "" else cfg.llm_model
	if model == "" do return nil, false

	embed_url := _llm_endpoint("/embeddings")
	body := _build_embed_body(model, text)
	response, ok := _embed_post(embed_url, cfg.llm_key, body, cfg.llm_timeout, allocator)
	if !ok do return nil, false

	embedding, parse_ok := _parse_embed_response(response, allocator)
	if !parse_ok {
		trunc := min(200, len(response))
		fmt.eprintfln("shard-embed: parse failed: %s", response[:trunc])
		return nil, false
	}
	return embedding, true
}

// Batch embed. Falls back to sequential calls if the API doesn't support batch input.
embed_texts :: proc(texts: []string, allocator := context.allocator) -> ([][]f32, bool) {
	if len(texts) == 0 do return nil, false
	cfg := config_get()
	if cfg.llm_url == "" do return nil, false
	model := cfg.embed_model if cfg.embed_model != "" else cfg.llm_model
	if model == "" do return nil, false

	embed_url := _llm_endpoint("/embeddings")
	body := _build_embed_body_batch(model, texts)
	response, ok := _embed_post(embed_url, cfg.llm_key, body, cfg.llm_timeout, allocator)
	if !ok do return nil, false

	embeddings, parse_ok := _parse_embed_response_batch(response, allocator)
	if parse_ok && len(embeddings) == len(texts) {
		return embeddings, true
	}

	// Fallback: sequential if batch parse failed
	result := make([][]f32, len(texts), allocator)
	for text, i in texts {
		emb, emb_ok := embed_text(text, allocator)
		if !emb_ok {
			for j in 0..<i do delete(result[j], allocator)
			delete(result, allocator)
			return nil, false
		}
		result[i] = emb
	}
	return result, true
}

// embed_shard_text builds the string to embed for a shard from its registry entry.
embed_shard_text :: proc(entry: Registry_Entry) -> string {
	b := strings.builder_make(context.temp_allocator)
	if entry.catalog.name != "" {
		strings.write_string(&b, entry.catalog.name)
		strings.write_string(&b, ". ")
	}
	if entry.catalog.purpose != "" {
		strings.write_string(&b, entry.catalog.purpose)
		strings.write_string(&b, ". ")
	}
	if entry.catalog.tags != nil && len(entry.catalog.tags) > 0 {
		strings.write_string(&b, "Tags: ")
		for tag, i in entry.catalog.tags {
			if i > 0 do strings.write_string(&b, ", ")
			strings.write_string(&b, tag)
		}
		strings.write_string(&b, ". ")
	}
	if entry.gate_positive != nil && len(entry.gate_positive) > 0 {
		strings.write_string(&b, "Topics: ")
		for item, i in entry.gate_positive {
			if i > 0 do strings.write_string(&b, ", ")
			strings.write_string(&b, item)
		}
		strings.write_string(&b, ". ")
	}
	if entry.gate_desc != nil && len(entry.gate_desc) > 0 {
		strings.write_string(&b, "Contains: ")
		for item, i in entry.gate_desc {
			if i > 0 do strings.write_string(&b, ", ")
			strings.write_string(&b, item)
		}
		strings.write_string(&b, ". ")
	}
	return strings.to_string(b)
}

cosine_similarity :: proc(a: []f32, b: []f32) -> f32 {
	if len(a) != len(b) || len(a) == 0 do return 0
	dot:    f32 = 0
	norm_a: f32 = 0
	norm_b: f32 = 0
	for i in 0 ..< len(a) {
		dot    += a[i] * b[i]
		norm_a += a[i] * a[i]
		norm_b += b[i] * b[i]
	}
	denom := math.sqrt(norm_a) * math.sqrt(norm_b)
	if denom == 0 do return 0
	return dot / denom
}

// =============================================================================
// Vector index — built at daemon startup, updated on gate changes
// =============================================================================

index_build :: proc(node: ^Node) {
	if !embed_ready() do return
	// Free old entries before clearing
	for &entry in node.vec_index.entries {
		delete(entry.name)
		delete(entry.embedding)
	}
	clear(&node.vec_index.entries)

	for entry in node.registry {
		text := embed_shard_text(entry)
		if text == "" do continue

		embedding, ok := embed_text(text, context.temp_allocator)
		if !ok {
			fmt.eprintfln("shard-embed: failed to embed '%s'", entry.name)
			continue
		}

		stored := make([]f32, len(embedding))
		copy(stored, embedding)
		append(&node.vec_index.entries, Vector_Entry{
			name      = strings.clone(entry.name),
			embedding = stored,
			text_hash = fnv_hash(text),
		})
		node.vec_index.dims = len(embedding)
	}

	if len(node.vec_index.entries) > 0 {
		fmt.eprintfln("shard-embed: indexed %d shards (%d dims)",
			len(node.vec_index.entries), node.vec_index.dims)
	}
}

index_update_shard :: proc(node: ^Node, name: string) {
	if !embed_ready() do return

	entry: ^Registry_Entry
	for &e in node.registry {
		if e.name == name { entry = &e; break }
	}
	if entry == nil do return

	text := embed_shard_text(entry^)
	if text == "" do return
	hash := fnv_hash(text)

	// Check cache — skip if unchanged
	for &ve in node.vec_index.entries {
		if ve.name == name {
			if ve.text_hash == hash do return
			embedding, ok := embed_text(text, context.temp_allocator)
			if !ok do return
			delete(ve.embedding)
			ve.embedding = make([]f32, len(embedding))
			copy(ve.embedding, embedding)
			ve.text_hash = hash
			return
		}
	}

	// New entry
	embedding, ok := embed_text(text, context.temp_allocator)
	if !ok do return
	stored := make([]f32, len(embedding))
	copy(stored, embedding)
	append(&node.vec_index.entries, Vector_Entry{
		name      = strings.clone(name),
		embedding = stored,
		text_hash = hash,
	})
	node.vec_index.dims = len(embedding)
}

index_query :: proc(node: ^Node, query: string, max_results: int, allocator := context.allocator) -> []Vector_Result {
	if len(node.vec_index.entries) == 0 do return nil

	q_embed, ok := embed_text(query, context.temp_allocator)
	if !ok do return nil

	scored := make([dynamic]Vector_Result, context.temp_allocator)
	for entry in node.vec_index.entries {
		score := cosine_similarity(q_embed, entry.embedding)
		if score > 0.01 {
			append(&scored, Vector_Result{name = entry.name, score = score})
		}
	}

	// Sort descending
	for i := 1; i < len(scored); i += 1 {
		key := scored[i]
		j := i - 1
		for j >= 0 && scored[j].score < key.score {
			scored[j + 1] = scored[j]
			j -= 1
		}
		scored[j + 1] = key
	}

	count := min(len(scored), max_results)
	results := make([]Vector_Result, count, allocator)
	copy(results, scored[:count])
	return results
}

// =============================================================================
// Internal — HTTP + JSON
// =============================================================================

@(private)
_llm_endpoint :: proc(suffix: string) -> string {
	cfg := config_get()
	trimmed := strings.trim_right(cfg.llm_url, "/")
	return fmt.tprintf("%s%s", trimmed, suffix)
}

fnv_hash :: proc(s: string) -> u64 {
	h: u64 = 14695981039346656037
	for c in s {
		h ~= u64(c)
		h *= 1099511628211
	}
	return h
}

@(private)
_build_embed_body :: proc(model: string, text: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"model":"`)
	strings.write_string(&b, _json_escape(model))
	strings.write_string(&b, `","input":"`)
	strings.write_string(&b, _json_escape(text))
	strings.write_string(&b, `"}`)
	return strings.to_string(b)
}

@(private)
_embed_post :: proc(url: string, api_key: string, body: string, timeout: int, allocator := context.allocator) -> (string, bool) {
	timeout_str := fmt.tprintf("%d", timeout)
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, "curl")
	append(&cmd, "-s", "-S")
	append(&cmd, "--max-time", timeout_str)
	append(&cmd, "-X", "POST")
	append(&cmd, "-H", "Content-Type: application/json")
	if api_key != "" {
		append(&cmd, "-H", fmt.tprintf("Authorization: Bearer %s", api_key))
	}
	append(&cmd, "-d", body)
	append(&cmd, url)

	state, stdout, stderr, err := os2.process_exec(
		os2.Process_Desc{command = cmd[:]},
		allocator,
	)
	if err != nil {
		fmt.eprintfln("shard-embed: curl error: %v", err)
		return "", false
	}
	if state.exit_code != 0 {
		stderr_str := string(stderr)
		trunc := min(200, len(stderr_str))
		fmt.eprintfln("shard-embed: curl exit %d: %s", state.exit_code, stderr_str[:trunc])
		return "", false
	}
	return string(stdout), true
}

@(private)
_parse_embed_response :: proc(response: string, allocator := context.allocator) -> ([]f32, bool) {
	parsed, err := json.parse(transmute([]u8)response, allocator = context.temp_allocator)
	if err != nil do return nil, false
	defer json.destroy_value(parsed, context.temp_allocator)

	obj, is_obj := parsed.(json.Object)
	if !is_obj do return nil, false

	// OpenAI format: {"data": [{"embedding": [...]}]}
	data, has_data := obj["data"]
	if has_data {
		arr, is_arr := data.(json.Array)
		if is_arr && len(arr) > 0 {
			first, is_first := arr[0].(json.Object)
			if is_first {
				emb, has_emb := first["embedding"]
				if has_emb {
					return _parse_f32_array(emb, allocator)
				}
			}
		}
	}

	// Ollama legacy format: {"embedding": [...]}
	emb, has_emb := obj["embedding"]
	if has_emb {
		return _parse_f32_array(emb, allocator)
	}

	return nil, false
}

@(private)
_parse_f32_array :: proc(val: json.Value, allocator := context.allocator) -> ([]f32, bool) {
	arr, is_arr := val.(json.Array)
	if !is_arr do return nil, false
	result := make([]f32, len(arr), allocator)
	for v, i in arr {
		#partial switch n in v {
		case f64: result[i] = f32(n)
		case i64: result[i] = f32(n)
		case:
			delete(result, allocator)
			return nil, false
		}
	}
	return result, true
}

@(private)
_build_embed_body_batch :: proc(model: string, texts: []string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"model":"`)
	strings.write_string(&b, _json_escape(model))
	strings.write_string(&b, `","input":[`)
	for text, i in texts {
		if i > 0 do strings.write_string(&b, `,`)
		strings.write_string(&b, `"`)
		strings.write_string(&b, _json_escape(text))
		strings.write_string(&b, `"`)
	}
	strings.write_string(&b, `]}`)
	return strings.to_string(b)
}

@(private)
_parse_embed_response_batch :: proc(response: string, allocator := context.allocator) -> ([][]f32, bool) {
	parsed, err := json.parse(transmute([]u8)response, allocator = context.temp_allocator)
	if err != nil do return nil, false
	defer json.destroy_value(parsed, context.temp_allocator)

	obj, is_obj := parsed.(json.Object)
	if !is_obj do return nil, false

	// OpenAI format: {"data": [{"embedding": [...]}, {"embedding": [...]}, ...]}
	data, has_data := obj["data"]
	if !has_data do return nil, false

	arr, is_arr := data.(json.Array)
	if !is_arr do return nil, false

	result := make([][]f32, len(arr), allocator)
	for item, i in arr {
		item_obj, is_item := item.(json.Object)
		if !is_item {
			_cleanup_batch(result[:i], allocator)
			return nil, false
		}
		emb, has_emb := item_obj["embedding"]
		if !has_emb {
			_cleanup_batch(result[:i], allocator)
			return nil, false
		}
		vec, vec_ok := _parse_f32_array(emb, allocator)
		if !vec_ok {
			_cleanup_batch(result[:i], allocator)
			return nil, false
		}
		result[i] = vec
	}
	return result, true
}

@(private)
_cleanup_batch :: proc(vecs: [][]f32, allocator := context.allocator) {
	for v in vecs do delete(v, allocator)
}
