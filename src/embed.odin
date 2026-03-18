package shard

import "core:encoding/json"
import "core:math"
import "core:strings"


// embed.odin — OpenAI-compatible embedding API client.
// Provides embed_text, embed_texts, embed_shard_text, cosine_similarity.
// All index logic has moved to index.odin.
//
// Config (.shards/config):
//   LLM_URL          http://localhost:11434/v1  (base URL — /embeddings appended automatically)
//   LLM_KEY          ollama
//   LLM_MODEL        (used as fallback embed model)
//   EMBED_MODEL      nomic-embed-text
//

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
	response, ok := _http_post(embed_url, cfg.llm_key, body, cfg.llm_timeout, allocator)
	if !ok do return nil, false

	embedding, parse_ok := _parse_embed_response(response, allocator)
	if !parse_ok {
		trunc := min(200, len(response))
		errf("embed: parse failed: %s", response[:trunc])
		return nil, false
	}
	return embedding, true
}

embed_texts :: proc(texts: []string, allocator := context.allocator) -> ([][]f32, bool) {
	if len(texts) == 0 do return nil, false
	cfg := config_get()
	if cfg.llm_url == "" do return nil, false
	model := cfg.embed_model if cfg.embed_model != "" else cfg.llm_model
	if model == "" do return nil, false

	embed_url := _llm_endpoint("/embeddings")
	body := _build_embed_body_batch(model, texts)
	response, ok := _http_post(embed_url, cfg.llm_key, body, cfg.llm_timeout, allocator)
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
			for j in 0 ..< i do delete(result[j], allocator)
			delete(result, allocator)
			return nil, false
		}
		result[i] = emb
	}
	return result, true
}

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
	dot: f32 = 0
	norm_a: f32 = 0
	norm_b: f32 = 0
	for i in 0 ..< len(a) {
		dot += a[i] * b[i]
		norm_a += a[i] * a[i]
		norm_b += b[i] * b[i]
	}
	denom := math.sqrt(norm_a) * math.sqrt(norm_b)
	if denom == 0 do return 0
	return dot / denom
}

@(private)
_build_embed_body :: proc(model: string, text: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"model":"`)
	strings.write_string(&b, json_escape(model))
	strings.write_string(&b, `","input":"`)
	strings.write_string(&b, json_escape(text))
	strings.write_string(&b, `"}`)
	return strings.to_string(b)
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

	// Ollama single-embedding format: {"embedding": [...]}
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
		case f64:
			result[i] = f32(n)
		case i64:
			result[i] = f32(n)
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
	strings.write_string(&b, json_escape(model))
	strings.write_string(&b, `","input":[`)
	for text, i in texts {
		if i > 0 do strings.write_string(&b, `,`)
		strings.write_string(&b, `"`)
		strings.write_string(&b, json_escape(text))
		strings.write_string(&b, `"`)
	}
	strings.write_string(&b, `]}`)
	return strings.to_string(b)
}

@(private)
_parse_embed_response_batch :: proc(
	response: string,
	allocator := context.allocator,
) -> (
	[][]f32,
	bool,
) {
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
