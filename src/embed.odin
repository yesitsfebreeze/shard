package shard

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:os/os2"
import "core:strings"

import logger "logger"


// Supports OpenAI-compatible embedding APIs (OpenAI, ollama, Cohere, etc.)
// Each shard's catalog + gates are embedded into a vector. Queries are
// embedded and compared via cosine similarity.
//
// Config (.shards/config):
//   LLM_URL    http://localhost:11434/v1    (base URL — /embeddings appended automatically)
//   LLM_KEY    ollama
//   LLM_MODEL  nomic-embed-text
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
	response, ok := _embed_post(embed_url, cfg.llm_key, body, cfg.llm_timeout, allocator)
	if !ok do return nil, false

	embedding, parse_ok := _parse_embed_response(response, allocator)
	if !parse_ok {
		trunc := min(200, len(response))
		logger.errf("embed: parse failed: %s", response[:trunc])
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

index_build :: proc(node: ^Node) {
	if !embed_ready() do return
	// Free old entries before clearing
	for &entry in node.vec_index.entries {
		delete(entry.name)
		delete(entry.embedding)
	}
	clear(&node.vec_index.entries)

	// Restore unchanged entries from cache — avoids re-embedding on every restart
	_ = index_load(node)

	// Build set of already-cached shard names
	cached := make(map[string]bool, allocator = context.temp_allocator)
	for entry in node.vec_index.entries do cached[entry.name] = true

	new_count := 0
	for entry in node.registry {
		if entry.name in cached do continue // already loaded from cache

		text := embed_shard_text(entry)
		if text == "" do continue

		embedding, ok := embed_text(text, context.temp_allocator)
		if !ok {
			logger.errf("embed: failed to embed '%s'", entry.name)
			continue
		}

		stored := make([]f32, len(embedding))
		copy(stored, embedding)
		append(
			&node.vec_index.entries,
			Vector_Entry {
				name = strings.clone(entry.name),
				embedding = stored,
				text_hash = fnv_hash(text),
			},
		)
		node.vec_index.dims = len(embedding)
		new_count += 1
	}

	if len(node.vec_index.entries) > 0 {
		logger.infof("embed: indexed %d shards (%d dims), %d newly embedded", len(node.vec_index.entries), node.vec_index.dims, new_count)
	}

	// Persist so next restart can load from cache
	if new_count > 0 {
		index_persist(node)
	}
}

index_update_shard :: proc(node: ^Node, name: string) {
	if !embed_ready() do return

	entry: ^Registry_Entry
	for &e in node.registry {
		if e.name == name {entry = &e; break}
	}
	if entry == nil do return

	text := embed_shard_text(entry^)
	if text == "" do return
	hash := fnv_hash(text)

	changed := false

	// Check cache — skip if unchanged
	for &ve in node.vec_index.entries {
		if ve.name == name {
			if ve.text_hash == hash do return // unchanged — nothing to persist
			embedding, ok := embed_text(text, context.temp_allocator)
			if !ok do return
			delete(ve.embedding)
			ve.embedding = make([]f32, len(embedding))
			copy(ve.embedding, embedding)
			ve.text_hash = hash
			changed = true
			break
		}
	}

	if !changed {
		// New entry
		embedding, ok := embed_text(text, context.temp_allocator)
		if !ok do return
		stored := make([]f32, len(embedding))
		copy(stored, embedding)
		append(
			&node.vec_index.entries,
			Vector_Entry{name = strings.clone(name), embedding = stored, text_hash = hash},
		)
		node.vec_index.dims = len(embedding)
		changed = true
	}

	if changed do index_persist(node)
}

// =============================================================================
// Vec index persistence — .shards/.vec_index
// =============================================================================

_vec_index_path :: proc() -> string {
	return ".shards/.vec_index"
}

// index_persist writes node.vec_index to .shards/.vec_index as JSON.
// Uses atomic write (temp file + rename) matching blob_flush pattern.
index_persist :: proc(node: ^Node) {
	if len(node.vec_index.entries) == 0 do return

	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "[\n")
	for entry, i in node.vec_index.entries {
		fmt.sbprintf(&b, "  {\"name\":\"%s\",\"text_hash\":%d,\"embedding\":[", json_escape(entry.name), entry.text_hash)
		for v, j in entry.embedding {
			if j > 0 do strings.write_string(&b, ",")
			fmt.sbprintf(&b, "%f", v)
		}
		strings.write_string(&b, "]}")
		if i < len(node.vec_index.entries) - 1 do strings.write_string(&b, ",")
		strings.write_string(&b, "\n")
	}
	strings.write_string(&b, "]\n")

	data := transmute([]u8)strings.to_string(b)
	tmp := fmt.tprintf("%s.tmp", _vec_index_path())

	f, ferr := os.open(tmp, os.O_WRONLY | os.O_CREATE | os.O_TRUNC, 0o644)
	if ferr != nil {
		logger.warnf("vec_index: persist open failed: %v", ferr)
		return
	}
	_, werr := os.write(f, data)
	os.close(f)
	if werr != nil {
		logger.warnf("vec_index: persist write failed: %v", werr)
		os.remove(tmp)
		return
	}

	when ODIN_OS == .Darwin {
		if !os.rename(tmp, _vec_index_path()) {
			os.remove(tmp)
			logger.warnf("vec_index: persist rename failed")
		}
	} else {
		if rename_err := os.rename(tmp, _vec_index_path()); rename_err != nil {
			os.remove(tmp)
			logger.warnf("vec_index: persist rename failed: %v", rename_err)
		}
	}
}

// index_load reads .shards/.vec_index and restores entries whose text_hash
// still matches the current registry gate text. Returns count restored.
// Skips entries for unknown shards or shards whose gates have changed.
index_load :: proc(node: ^Node) -> int {
	data, ok := os.read_entire_file(_vec_index_path(), context.temp_allocator)
	if !ok do return 0
	defer delete(data, context.temp_allocator)

	val, err := json.parse(data, allocator = context.temp_allocator)
	if err != nil do return 0
	defer json.destroy_value(val, context.temp_allocator)

	arr, is_arr := val.(json.Array)
	if !is_arr do return 0

	restored := 0
	for item in arr {
		obj, is_obj := item.(json.Object)
		if !is_obj do continue

		name_val, has_name := obj["name"]
		hash_val, has_hash := obj["text_hash"]
		emb_val, has_emb := obj["embedding"]
		if !has_name || !has_hash || !has_emb do continue

		name, name_is_str := name_val.(json.String)
		if !name_is_str do continue

		hash_float, hash_is_float := hash_val.(json.Float)
		if !hash_is_float do continue
		hash := u64(hash_float)

		emb_arr, emb_is_arr := emb_val.(json.Array)
		if !emb_is_arr do continue

		// Verify shard still in registry with same gate text hash
		found := false
		for entry in node.registry {
			if entry.name == string(name) {
				text := embed_shard_text(entry)
				if fnv_hash(text) == hash {
					found = true
				}
				break
			}
		}
		if !found do continue

		embedding := make([]f32, len(emb_arr))
		for v, i in emb_arr {
			#partial switch n in v {
			case json.Float:
				embedding[i] = f32(n)
			case json.Integer:
				embedding[i] = f32(n)
			}
		}

		append(
			&node.vec_index.entries,
			Vector_Entry {
				name      = strings.clone(string(name)),
				embedding = embedding,
				text_hash = hash,
			},
		)
		if len(embedding) > 0 do node.vec_index.dims = len(embedding)
		restored += 1
	}

	if restored > 0 {
		logger.infof("vec_index: loaded %d/%d entries from cache", restored, len(arr))
	}
	return restored
}

index_query :: proc(
	node: ^Node,
	query: string,
	max_results: int,
	allocator := context.allocator,
) -> []Vector_Result {
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
	strings.write_string(&b, json_escape(model))
	strings.write_string(&b, `","input":"`)
	strings.write_string(&b, json_escape(text))
	strings.write_string(&b, `"}`)
	return strings.to_string(b)
}

@(private)
_embed_post :: proc(
	url: string,
	api_key: string,
	body: string,
	timeout: int,
	allocator := context.allocator,
) -> (
	string,
	bool,
) {
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

	state, stdout, stderr, err := os2.process_exec(os2.Process_Desc{command = cmd[:]}, allocator)
	if err != nil {
		fmt.eprintfln("embed: curl error: %v", err)
		return "", false
	}
	if state.exit_code != 0 {
		stderr_str := string(stderr)
		trunc := min(200, len(stderr_str))
		fmt.eprintfln("embed: curl exit %d: %s", state.exit_code, stderr_str[:trunc])
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


// Supports streaming responses from OpenAI-compatible APIs using SSE
// (Server-Sent Events). The callback is invoked for each chunk.
//
// Config:
//   STREAMING_ENABLED  true/false (default false)
//   STREAM_CHUNK_SIZE 1024 (default)

Streaming_Callback :: #type proc(chunk: string, done: bool, user_data: rawptr)

// stream_chat sends a chat completion request and streams the response.
// The callback is invoked for each SSE chunk until done=true.
// Returns true if streaming started successfully.
stream_chat :: proc(
	messages: []Streaming_Message,
	callback: Streaming_Callback,
	user_data: rawptr,
	allocator := context.allocator,
) -> bool {
	cfg := config_get()
	if cfg.llm_url == "" || cfg.llm_model == "" do return false

	// Build request body
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"model":"`)
	strings.write_string(&b, json_escape(cfg.llm_model))
	strings.write_string(&b, `","stream":true,"temperature":`)
	fmt.sbprintf(&b, "%g", cfg.llm_temperature)
	strings.write_string(&b, `,"max_tokens":`)
	fmt.sbprintf(&b, "%d", cfg.llm_max_tokens)
	strings.write_string(&b, `,"messages":[`)
	for msg, i in messages {
		if i > 0 do strings.write_string(&b, `,`)
		strings.write_string(&b, `{"role":"`)
		strings.write_string(&b, msg.role)
		strings.write_string(&b, `","content":"`)
		strings.write_string(&b, json_escape(msg.content))
		strings.write_string(&b, `"}`)
	}
	strings.write_string(&b, `]}`)

	body := strings.to_string(b)
	chat_url := fmt.tprintf("%s/chat/completions", strings.trim_right(cfg.llm_url, "/"))

	return _stream_post(chat_url, cfg.llm_key, body, cfg.llm_timeout, callback, user_data)
}

Streaming_Message :: struct {
	role:    string, // "system", "user", "assistant"
	content: string,
}

@(private)
_stream_post :: proc(
	url: string,
	api_key: string,
	body: string,
	timeout: int,
	callback: Streaming_Callback,
	user_data: rawptr,
	allocator := context.allocator,
) -> bool {
	timeout_str := fmt.tprintf("%d", timeout)
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, "curl")
	append(&cmd, "-s", "-S")
	append(&cmd, "--max-time", timeout_str)
	append(&cmd, "-X", "POST")
	append(&cmd, "-H", "Content-Type: application/json")
	append(&cmd, "-H", "Accept: text/event-stream")
	if api_key != "" {
		append(&cmd, "-H", fmt.tprintf("Authorization: Bearer %s", api_key))
	}
	append(&cmd, "-d", body)
	append(&cmd, url)

	state, stdout, stderr, err := os2.process_exec(os2.Process_Desc{command = cmd[:]}, allocator)
	if err != nil {
		fmt.eprintfln("stream_chat: curl error: %v", err)
		callback("", true, user_data)
		return false
	}
	if state.exit_code != 0 {
		stderr_str := string(stderr)
		trunc := min(200, len(stderr_str))
		fmt.eprintfln("stream_chat: curl exit %d: %s", state.exit_code, stderr_str[:trunc])
		callback("", true, user_data)
		return false
	}

	// Parse SSE response - each line is "data: <json>" or "data: [DONE]"
	content := string(stdout)
	lines := strings.split_lines(content, context.temp_allocator)
	defer delete(lines, context.temp_allocator)

	for line in lines {
		trimmed := strings.trim_space(line)
		if !strings.has_prefix(trimmed, "data: ") do continue

		data := trimmed[6:] // skip "data: "
		if data == "[DONE]" {
			callback("", true, user_data)
			return true
		}

		// Extract content from SSE JSON
		chunk := _extract_sse_content(data)
		if chunk != "" {
			callback(chunk, false, user_data)
		}
	}

	callback("", true, user_data)
	return true
}

@(private)
_extract_sse_content :: proc(sse_json: string) -> string {
	// Parse the SSE JSON to extract delta.content
	parsed, err := json.parse(transmute([]u8)sse_json, allocator = context.temp_allocator)
	if err != nil do return ""
	defer json.destroy_value(parsed, context.temp_allocator)

	obj, is_obj := parsed.(json.Object)
	if !is_obj do return ""

	choices, has_choices := obj["choices"]
	if !has_choices do return ""

	arr, is_arr := choices.(json.Array)
	if !is_arr || len(arr) == 0 do return ""

	first, is_first := arr[0].(json.Object)
	if !is_first do return ""

	delta, has_delta := first["delta"]
	if !has_delta do return ""

	delta_obj, is_delta_obj := delta.(json.Object)
	if !is_delta_obj do return ""

	content_val, has_content := delta_obj["content"]
	if !has_content do return ""

	if s, is_str := content_val.(string); is_str {
		return s
	}
	return ""
}
