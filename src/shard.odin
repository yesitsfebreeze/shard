package shard

import "core:unicode"
import "core:crypto"
import "core:crypto/hash"
import "core:crypto/hkdf"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:math"
import "core:mem"
import "core:os"
import "core:os/os2"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"
import "core:time"
import "base:runtime"
import "transport"
Query_Result :: struct {
	id:          Thought_ID,
	description: string,
	score:       int,
}

query_thoughts :: proc(keyword: string) -> []Query_Result {
	maybe_maintenance()
	if !state.has_key do return {}

	needle := strings.to_lower(keyword, runtime_alloc)
	results: [dynamic]Query_Result
	results.allocator = runtime_alloc

	s := &state.blob.shard
	for block in ([2][][]u8{s.processed, s.unprocessed}) {
		for blob in block {
			pos := 0
			t, ok := thought_parse(blob, &pos)
			if !ok do continue

			desc, content, decrypt_ok := thought_decrypt(state.key, &t)
			if !decrypt_ok do continue

			lower_desc := strings.to_lower(desc, runtime_alloc)
			lower_content := strings.to_lower(content, runtime_alloc)
			if strings.contains(lower_desc, needle) || strings.contains(lower_content, needle) {
				append(&results, Query_Result{id = t.id, description = desc, score = 1})
			}
		}
	}
	return results[:]
}




Event_Kind :: enum {
	Write,
	Compact,
	Gate_Change,
}

emit_event :: proc(kind: Event_Kind, detail: string) {
	peers := index_list()
	if len(peers) <= 1 do return

	b := strings.builder_make(runtime_alloc)
	kind_str: string
	switch kind {
	case .Write:
		kind_str = "write"
	case .Compact:
		kind_str = "compact"
	case .Gate_Change:
		kind_str = "gate_change"
	}
	fmt.sbprintf(
		&b,
		`{{"event":"%s","shard":"%s","detail":"%s"}}`,
		kind_str,
		process_json_escape(state.shard_id),
		process_json_escape(detail),
	)
	msg := transmute([]u8)strings.to_string(b)

	for peer in peers {
		if peer.shard_id == state.shard_id do continue
		conn, ok := ipc_connect(ipc_socket_path(peer.shard_id))
		if !ok do continue
		ipc_send_msg(conn, msg)
		ipc_close(conn)
	}
}

Fleet_Result :: struct {
	shard_id: string,
	response: string,
	ok:       bool,
}

fleet_ask :: proc(question: string) -> string {
	if !state.has_llm do return "no LLM configured"

	peers := index_list()
	answers: [dynamic]string
	answers.allocator = runtime_alloc

	local_ctx := build_context(question)
	if len(local_ctx) > 0 {
		answer, ok := shard_ask(question)
		if ok {
			append(
				&answers,
				fmt.aprintf("[%s] %s", state.shard_id, answer, allocator = runtime_alloc),
			)
		}
	}

	lower_q := strings.to_lower(question, runtime_alloc)
	for peer in peers {
		if peer.shard_id == state.shard_id do continue

		raw, read_ok := os.read_entire_file(peer.exe_path, runtime_alloc)
		if !read_ok do continue

		peer_blob := load_blob_from_raw(raw)
		if !peer_blob.has_data do continue

		cat_name := strings.to_lower(peer_blob.shard.catalog.name, runtime_alloc)
		cat_purpose := strings.to_lower(peer_blob.shard.catalog.purpose, runtime_alloc)
		catalog_relevant := false
		for word in strings.split(lower_q, " ", allocator = runtime_alloc) {
			w := strings.trim(strings.trim_space(word), "?!.,")
			if len(w) >= 3 && (strings.contains(cat_name, w) || strings.contains(cat_purpose, w)) {
				catalog_relevant = true
				break
			}
		}
		if !catalog_relevant && len(cat_name) > 0 do continue

		peer_ctx := build_context_from_blob(&peer_blob, question)
		if len(peer_ctx) == 0 do continue

		system := fmt.aprintf(
			"You are a knowledge assistant. Answer based ONLY on the context below. Be concise. If the context doesn't contain the answer, say so.\n\n%s",
			peer_ctx,
			allocator = runtime_alloc,
		)

		answer, ok := llm_chat(system, question)
		if ok &&
		   !strings.contains(answer, "don't have") &&
		   !strings.contains(answer, "no information") &&
		   !strings.contains(answer, "not provided") {
			append(
				&answers,
				fmt.aprintf("[%s] %s", peer.shard_id, answer, allocator = runtime_alloc),
			)
		}
	}

	if len(answers) == 0 do return "no shard had relevant knowledge"
	return strings.join(answers[:], "\n\n", allocator = runtime_alloc)
}

load_peer_blob :: proc(shard_id: string) -> (Blob, bool) {
	peers := index_list()
	for peer in peers {
		if peer.shard_id == shard_id {
			raw, ok := os.read_entire_file(peer.exe_path, runtime_alloc)
			if !ok do return {}, false
			blob := load_blob_from_raw(raw)
			return blob, blob.has_data
		}
	}
	return {}, false
}

query_peer :: proc(shard_id: string, keyword: string) -> []Query_Result {
	blob, ok := load_peer_blob(shard_id)
	if !ok do return {}
	return query_blob(&blob, keyword)
}

query_blob :: proc(b: ^Blob, keyword: string) -> []Query_Result {
	if !state.has_key do return {}
	needle := strings.to_lower(keyword, runtime_alloc)
	results: [dynamic]Query_Result
	results.allocator = runtime_alloc

	s := &b.shard
	for block in ([2][][]u8{s.processed, s.unprocessed}) {
		for blob in block {
			pos := 0
			t, parse_ok := thought_parse(blob, &pos)
			if !parse_ok do continue
			desc, content, decrypt_ok := thought_decrypt(state.key, &t)
			if !decrypt_ok do continue
			lower_desc := strings.to_lower(desc, runtime_alloc)
			lower_content := strings.to_lower(content, runtime_alloc)
			if strings.contains(lower_desc, needle) || strings.contains(lower_content, needle) {
				append(&results, Query_Result{id = t.id, description = desc, score = 1})
			}
		}
	}
	return results[:]
}

ask_peer :: proc(shard_id: string, question: string) -> (string, bool) {
	if !state.has_llm do return "no LLM configured", false

	blob, ok := load_peer_blob(shard_id)
	if !ok do return "shard not found", false

	ctx := build_context_from_blob(&blob, question)
	if len(ctx) == 0 do return "no relevant knowledge", false

	system := fmt.aprintf(
		"You are a knowledge assistant. Answer based ONLY on the context below. Be concise. If the context doesn't contain the answer, say so.\n\n%s",
		ctx,
		allocator = runtime_alloc,
	)
	return llm_chat(system, question)
}

build_context_from_blob :: proc(b: ^Blob, question: string) -> string {
	if !state.has_key do return ""
	s := &b.shard
	if len(s.processed) == 0 && len(s.unprocessed) == 0 do return ""

	out := strings.builder_make(runtime_alloc)
	if len(s.catalog.name) > 0 {
		fmt.sbprintf(&out, "## Shard: %s\n\n%s\n\n", s.catalog.name, s.catalog.purpose)
	}

	for block in ([2][][]u8{s.processed, s.unprocessed}) {
		for blob in block {
			pos := 0
			t, ok := thought_parse(blob, &pos)
			if !ok do continue
			desc, content, decrypt_ok := thought_decrypt(state.key, &t)
			if !decrypt_ok do continue
			fmt.sbprintf(&out, "### %s\n\n%s\n\n", desc, content)
		}
	}

	return strings.to_string(out)
}

fleet_query :: proc(keyword: string) -> []Fleet_Result {
	peers := index_list()
	results: [dynamic]Fleet_Result
	results.allocator = runtime_alloc

	for peer in peers {
		if peer.shard_id == state.shard_id do continue
		sock_path := ipc_socket_path(peer.shard_id)
		conn, conn_ok := ipc_connect(sock_path)
		if !conn_ok {
			append(&results, Fleet_Result{shard_id = peer.shard_id, ok = false})
			continue
		}
		defer ipc_close(conn)

		msg := fmt.aprintf(
			`{{"method":"query","keyword":"%s"}}`,
			process_json_escape(keyword),
			allocator = runtime_alloc,
		)
		if !ipc_send_msg(conn, transmute([]u8)msg) {
			append(&results, Fleet_Result{shard_id = peer.shard_id, ok = false})
			continue
		}

		resp, recv_ok := ipc_recv_msg(conn)
		append(
			&results,
			Fleet_Result {
				shard_id = peer.shard_id,
				response = string(resp) if recv_ok else "",
				ok = recv_ok,
			},
		)
	}
	return results[:]
}

create_shard :: proc(name: string, purpose: string) -> bool {
	data_dir := os.get_env("SHARD_DATA", runtime_alloc)
	shard_dir := state.run_dir
	if len(data_dir) > 0 {
		shard_dir = filepath.join({data_dir, "shards"}, runtime_alloc)
	}
	ensure_dir(shard_dir)

	new_id := slugify(name)
	new_path := filepath.join({shard_dir, new_id}, runtime_alloc)

	new_shard := Shard_Data {
		catalog = Catalog{name = name, purpose = purpose, created = now_rfc3339()},
	}
	buf := blob_serialize(state.blob.exe_code, &new_shard)

	if !os.write_entire_file(new_path, buf) {
		log.errorf("Failed to create shard: %s", new_path)
		return false
	}
	os2.chmod(
		new_path,
		{
			.Read_User,
			.Write_User,
			.Execute_User,
			.Read_Group,
			.Execute_Group,
			.Read_Other,
			.Execute_Other,
		},
	)

	index_write(new_id, new_path, "", state.shard_id)
	log.infof("Created shard '%s' at %s", name, new_path)
	return true
}

now_rfc3339 :: proc() -> string {
	now := time.now()
	y, mon, d := time.date(now)
	h, min, s := time.clock(now)
	return fmt.aprintf(
		"%04d-%02d-%02dT%02d:%02d:%02dZ",
		y,
		int(mon),
		d,
		h,
		min,
		s,
		allocator = runtime_alloc,
)
}

strip_jsonc_comments :: proc(input: string) -> string {
	b := strings.builder_make(runtime_alloc)
	in_string := false
	i := 0
	for i < len(input) {
		if in_string {
			if input[i] == '\\' && i + 1 < len(input) {
				strings.write_byte(&b, input[i])
				strings.write_byte(&b, input[i + 1])
				i += 2
				continue
			}
			if input[i] == '"' do in_string = false
			strings.write_byte(&b, input[i])
			i += 1
		} else {
			if input[i] == '"' {
				in_string = true
				strings.write_byte(&b, input[i])
				i += 1
			} else if i + 1 < len(input) && input[i] == '/' && input[i + 1] == '/' {
				for i < len(input) && input[i] != '\n' do i += 1
			} else if i + 1 < len(input) && input[i] == '/' && input[i + 1] == '*' {
				i += 2
				for i + 1 < len(input) && !(input[i] == '*' && input[i + 1] == '/') do i += 1
				if i + 1 < len(input) do i += 2
			} else {
				strings.write_byte(&b, input[i])
				i += 1
			}
		}
	}
	return strings.to_string(b)
}

load_config :: proc() {
	state.idle_timeout = DEFAULT_IDLE_TIMEOUT_MS
	state.http_port = DEFAULT_HTTP_PORT
	state.max_thoughts = DEFAULT_MAX_THOUGHTS

	config_path := filepath.join({state.shards_dir, CONFIG_FILE}, runtime_alloc)
	raw, ok := os.read_entire_file(config_path, runtime_alloc)
	if !ok do return

	cleaned := strip_jsonc_comments(string(raw))
	err := json.unmarshal(transmute([]u8)cleaned, &state.config, allocator = runtime_alloc)
	if err != nil {
		log.errorf("Failed to parse config: %s", config_path)
		return
	}

	c := &state.config
	if c.idle_timeout_ms > 0 do state.idle_timeout = c.idle_timeout_ms
	if c.http_port > 0 do state.http_port = c.http_port
	if c.max_thoughts > 0 do state.max_thoughts = c.max_thoughts

	log.infof("Config loaded from %s", config_path)
}

load_key :: proc() {
	key_hex := os.get_env("SHARD_KEY", runtime_alloc)
	if len(key_hex) == 0 do key_hex = state.config.shard_key
	if len(key_hex) == 0 do return

	k, ok := hex_to_key(key_hex)
	if !ok {
		log.error("SHARD_KEY must be exactly 64 hex characters (32 bytes)")
		return
	}
	state.key = k
	state.has_key = true
	log.info("Encryption key loaded from SHARD_KEY")
}

hex_to_key :: proc(s: string) -> (key: Key, ok: bool) {
	if len(s) != 64 do return {}, false
	b, decoded := hex.decode(transmute([]u8)s, runtime_alloc)
	if !decoded || len(b) != 32 do return {}, false
	copy(key[:], b)
	return key, true
}

load_llm_config :: proc() {
	c := &state.config
	state.llm_url = os.get_env("LLM_URL", runtime_alloc)
	if len(state.llm_url) == 0 do state.llm_url = c.llm_url
	state.llm_key = os.get_env("LLM_KEY", runtime_alloc)
	if len(state.llm_key) == 0 do state.llm_key = c.llm_key
	state.llm_model = os.get_env("LLM_MODEL", runtime_alloc)
	if len(state.llm_model) == 0 do state.llm_model = c.llm_model
	state.has_llm = len(state.llm_url) > 0 && len(state.llm_model) > 0
	if state.has_llm {
		log.infof("LLM configured: %s model=%s", state.llm_url, state.llm_model)
	}
	state.embed_model = os.get_env("EMBED_MODEL", runtime_alloc)
	if len(state.embed_model) == 0 do state.embed_model = c.embed_model
	state.has_embed = len(state.llm_url) > 0 && len(state.embed_model) > 0
	routing_guardrail := strings.to_lower(
		strings.trim_space(os.get_env("SHARD_SPLIT_ROUTING_FALLBACK_ONLY", runtime_alloc)),
		runtime_alloc,
	)
	state.split_routing_hash_only =
		routing_guardrail == "1" ||
		routing_guardrail == "true" ||
		routing_guardrail == "yes" ||
		routing_guardrail == "on"
	if state.split_routing_hash_only {
		log.info(
			"Split routing guardrail active: SHARD_SPLIT_ROUTING_FALLBACK_ONLY forces hash fallback routing",
		)
	}
	state.vec_index.allocator = runtime_alloc
}

embed_text :: proc(text: string) -> ([]f64, bool) {
	if !state.has_embed do return nil, false

	url := strings.concatenate(
		{strings.trim_right(state.llm_url, "/"), "/embeddings"},
		runtime_alloc,
	)

	b := strings.builder_make(runtime_alloc)
	strings.write_string(&b, `{"model":"`)
	strings.write_string(&b, process_json_escape(state.embed_model))
	strings.write_string(&b, `","input":"`)
	strings.write_string(&b, process_json_escape(text))
	strings.write_string(&b, `"}`)

	cmd: [dynamic]string
	cmd.allocator = runtime_alloc
	append(&cmd, "curl", "-s", "-S", "--max-time", "30", "-X", "POST")
	append(&cmd, "-H", "Content-Type: application/json")
	if len(state.llm_key) > 0 {
		append(
			&cmd,
			"-H",
			fmt.aprintf("Authorization: Bearer %s", state.llm_key, allocator = runtime_alloc),
		)
	}
	append(&cmd, "-d", strings.to_string(b), url)

	result, stdout, _, err := os2.process_exec(os2.Process_Desc{command = cmd[:]}, runtime_alloc)
	if err != nil || result.exit_code != 0 do return nil, false

	parsed, parse_err := json.parse(stdout, allocator = runtime_alloc)
	if parse_err != nil do return nil, false

	obj, _ := parsed.(json.Object)
	data_arr, _ := obj["data"].(json.Array)
	if len(data_arr) == 0 do return nil, false

	first, _ := data_arr[0].(json.Object)
	embedding, _ := first["embedding"].(json.Array)
	if len(embedding) == 0 do return nil, false

	vec := make([]f64, len(embedding), runtime_alloc)
	for v, i in embedding {
		switch n in v {
		case json.Float:
			vec[i] = n
		case json.Integer:
			vec[i] = f64(n)
		case json.Null, json.Boolean, json.String, json.Array, json.Object:
			vec[i] = 0
		}
	}
	return vec, true
}

thought_exists :: proc(description: string) -> bool {
	if !state.has_key do return false
	lower := strings.to_lower(description, runtime_alloc)
	s := &state.blob.shard
	for block in ([2][][]u8{s.processed, s.unprocessed}) {
		for blob in block {
			pos := 0
			t, ok := thought_parse(blob, &pos)
			if !ok do continue
			desc, _, decrypt_ok := thought_decrypt(state.key, &t)
			if !decrypt_ok do continue
			if strings.to_lower(desc, runtime_alloc) == lower do return true
		}
	}
	return false
}

vec_index_thought :: proc(id: Thought_ID, description: string) {
	embedding, ok := embed_text(description)
	if !ok do return
	append(&state.vec_index, Vec_Entry{id = id, desc = description, embedding = embedding})
}

vec_save_to_manifest :: proc(s: ^Shard_Data) {
	if len(state.vec_index) == 0 do return
	b := strings.builder_make(runtime_alloc)
	for entry, i in state.vec_index {
		if i > 0 do strings.write_string(&b, "\n")
		strings.write_string(&b, thought_id_to_hex(entry.id))
		strings.write_string(&b, "\t")
		strings.write_string(&b, entry.desc)
		strings.write_string(&b, "\t")
		for v, j in entry.embedding {
			if j > 0 do strings.write_string(&b, ",")
			fmt.sbprintf(&b, "%.6f", v)
		}
	}
	s.manifest = strings.to_string(b)
}

vec_load_from_manifest :: proc(s: ^Shard_Data) {
	if len(s.manifest) == 0 do return
	lines := strings.split(s.manifest, "\n", allocator = runtime_alloc)
	for line in lines {
		parts := strings.split(line, "\t", allocator = runtime_alloc)
		if len(parts) < 3 do continue
		id, id_ok := hex_to_thought_id(parts[0])
		if !id_ok do continue
		vals := strings.split(parts[2], ",", allocator = runtime_alloc)
		embedding := make([]f64, len(vals), runtime_alloc)
		for v, i in vals {
			f: f64 = 0
			neg := false
			j := 0
			if len(v) > 0 && v[0] == '-' {neg = true; j = 1}
			whole: f64 = 0
			for j < len(v) && v[j] != '.' {
				whole = whole * 10 + f64(v[j] - '0')
				j += 1
			}
			frac: f64 = 0
			scale: f64 = 0.1
			if j < len(v) && v[j] == '.' {
				j += 1
				for j < len(v) {
					frac += f64(v[j] - '0') * scale
					scale *= 0.1
					j += 1
				}
			}
			f = whole + frac
			if neg do f = -f
			embedding[i] = f
		}
		append(
			&state.vec_index,
			Vec_Entry {
				id = id,
				desc = strings.clone(parts[1], runtime_alloc),
				embedding = embedding,
			},
		)
	}
	if len(state.vec_index) > 0 {
		log.infof("Loaded %d vectors from manifest", len(state.vec_index))
	}
}

vec_search :: proc(query: string, top_k: int = 5) -> []Query_Result {
	query_vec, ok := embed_text(query)
	if !ok do return {}

	Scored :: struct {
		id:    Thought_ID,
		desc:  string,
		score: f64,
	}
	scored: [dynamic]Scored
	scored.allocator = runtime_alloc

	for entry in state.vec_index {
		score := cosine_similarity(query_vec, entry.embedding)
		append(&scored, Scored{id = entry.id, desc = entry.desc, score = score})
	}

	for i in 0 ..< len(scored) {
		for j in i + 1 ..< len(scored) {
			if scored[j].score > scored[i].score {
				scored[i], scored[j] = scored[j], scored[i]
			}
		}
	}

	n := min(top_k, len(scored))
	results := make([]Query_Result, n, runtime_alloc)
	for i in 0 ..< n {
		results[i] = Query_Result {
			id          = scored[i].id,
			description = scored[i].desc,
			score       = int(scored[i].score * 1000),
		}
	}
	return results
}

cosine_similarity :: proc(a: []f64, b: []f64) -> f64 {
	if len(a) != len(b) || len(a) == 0 do return 0

	dot: f64 = 0
	mag_a: f64 = 0
	mag_b: f64 = 0
	for i in 0 ..< len(a) {
		dot += a[i] * b[i]
		mag_a += a[i] * a[i]
		mag_b += b[i] * b[i]
	}

	denom := math.sqrt(mag_a) * math.sqrt(mag_b)
	if denom == 0 do return 0
	return dot / denom
}

llm_chat :: proc(system_prompt: string, user_prompt: string) -> (string, bool) {
	if !state.has_llm do return "", false

	url := strings.concatenate(
		{strings.trim_right(state.llm_url, "/"), "/chat/completions"},
		runtime_alloc,
	)

	b := strings.builder_make(runtime_alloc)
	strings.write_string(&b, `{"model":"`)
	strings.write_string(&b, process_json_escape(state.llm_model))
	strings.write_string(&b, `","messages":[{"role":"system","content":"`)
	strings.write_string(&b, process_json_escape(system_prompt))
	strings.write_string(&b, `"},{"role":"user","content":"`)
	strings.write_string(&b, process_json_escape(user_prompt))
	strings.write_string(&b, `"}]}`)

	cmd: [dynamic]string
	cmd.allocator = runtime_alloc
	append(&cmd, "curl", "-s", "-S", "--max-time", LLM_TIMEOUT_SECONDS, "-X", "POST")
	append(&cmd, "-H", "Content-Type: application/json")
	if len(state.llm_key) > 0 {
		append(
			&cmd,
			"-H",
			fmt.aprintf("Authorization: Bearer %s", state.llm_key, allocator = runtime_alloc),
		)
	}
	append(&cmd, "-d", strings.to_string(b), url)

	result, stdout, stderr, err := os2.process_exec(
		os2.Process_Desc{command = cmd[:]},
		runtime_alloc,
	)
	if err != nil {
		log.errorf("LLM curl error: %v", err)
		return "", false
	}
	if result.exit_code != 0 {
		log.errorf("LLM curl exit %d: %s", result.exit_code, string(stderr))
		return "", false
	}

	parsed, parse_err := json.parse(stdout, allocator = runtime_alloc)
	if parse_err != nil {
		log.errorf("LLM response parse error: %s", string(stdout[:min(len(stdout), 200)]))
		return "", false
	}

	obj, _ := parsed.(json.Object)
	choices, _ := obj["choices"].(json.Array)
	if len(choices) == 0 do return "", false
	first, _ := choices[0].(json.Object)
	message, _ := first["message"].(json.Object)
	content, _ := message["content"].(json.String)
	return strings.clone(content, runtime_alloc), true
}

shard_ask :: proc(question: string, agent: string = "") -> (string, bool) {
	if !state.has_llm do return "no LLM configured (set LLM_URL, LLM_KEY, LLM_MODEL)", false

	cache_load()
	cache_key := opaque_cache_key("answer", question)
	if cached, found := state.topic_cache[cache_key]; found {
		log.info("Cache hit for question")
		return cached.value, true
	}
	if cached, legacy_key, found := cache_migrate_legacy_answer_entry(cache_key, question); found {
		cache_save_key(cache_key, cached)
		cache_delete_key(legacy_key)
		log.info("Cache hit for question (legacy key migrated)")
		return cached.value, true
	}

	packet := build_context_packet(question, agent)
	ctx := context_packet_render(packet)
	if len(ctx) == 0 {
		log.infof("Shard %s not relevant to: %s", state.shard_id, question)
		return "this shard has no relevant knowledge for that question", false
	}

	related := find_related_shards(question)
	if len(related) > 0 {
		ctx = strings.concatenate({ctx, "\n## Related Shards\n\n", related}, runtime_alloc)
	}

	log.infof("Shard %s is relevant, %d bytes of context", state.shard_id, len(ctx))

	system := fmt.aprintf(
		"You are a knowledge assistant. Answer based ONLY on the context below. Be concise. If the context doesn't contain the answer, say so. If related shards are listed, mention them.\n\n%s",
		ctx,
		allocator = runtime_alloc,
	)

	answer, ok := llm_chat(system, question)
	if ok {
		state.topic_cache[strings.clone(cache_key, runtime_alloc)] = Cache_Entry {
			value   = strings.clone(answer, runtime_alloc),
			author  = "llm",
			expires = "",
		}
		cache_save()
	}
	return answer, ok
}

opaque_cache_key :: proc(namespace: string, raw: string) -> string {
	material := state.key
	if !state.has_key {
		if !state.has_cache_key_fallback {
			fallback: [32]u8
			crypto.rand_bytes(fallback[:])
			state.cache_key_fallback = Key(fallback)
			state.has_cache_key_fallback = true
		}
		material = state.cache_key_fallback
	}

	input := strings.concatenate({namespace, "\x00", raw}, runtime_alloc)
	digest: [32]u8
	m := material
	hkdf.extract_and_expand(.SHA256, nil, m[:], transmute([]u8)input, digest[:])

	h := HEX_CHARS
	buf := make([]u8, 24, runtime_alloc)
	for i in 0 ..< 12 {
		b := digest[i]
		buf[i * 2] = h[b >> 4]
		buf[i * 2 + 1] = h[b & 0x0f]
	}

	return fmt.aprintf("%s:%s", namespace, string(buf), allocator = runtime_alloc)
}

find_related_shards :: proc(question: string) -> string {
	peers := index_list()
	if len(peers) <= 1 do return ""

	b := strings.builder_make(runtime_alloc)
	for peer in peers {
		if peer.shard_id == state.shard_id do continue
		raw, ok := os.read_entire_file(peer.exe_path, runtime_alloc)
		if !ok do continue
		blob := load_blob_from_raw(raw)
		if !blob.has_data do continue
		s := &blob.shard
		if len(s.catalog.name) > 0 {
			fmt.sbprintf(&b, "- %s: %s\n", s.catalog.name, s.catalog.purpose)
		}
	}
	return strings.to_string(b)
}

write_thought :: proc(
	description: string,
	content: string,
	agent: string = "",
) -> (
	Thought_ID,
	bool,
) {
	if !state.has_key {
		log.error("Cannot write thought: no encryption key (set SHARD_KEY)")
		return {}, false
	}

	if thought_exists(description) {
		log.infof("Duplicate thought skipped: %s", description)
		return {}, false
	}

	gate_result := gates_check(&state.blob.shard.gates, description, content)
	if gate_result == .Reject {
		routed_id, routed := route_to_peer(description, content, agent)
		if routed do return routed_id, true
		return {}, false
	}

	id := new_thought_id()
	body_blob, seal_blob, trust := thought_encrypt(state.key, id, description, content)

	t := Thought {
		id         = id,
		trust      = trust,
		seal_blob  = seal_blob,
		body_blob  = body_blob,
		agent      = agent,
		created_at = now_rfc3339(),
		updated_at = "",
		ttl        = 0,
	}

	buf: [dynamic]u8
	buf.allocator = runtime_alloc
	thought_serialize(&buf, &t)

	s := &state.blob.shard
	new_unprocessed: [dynamic][]u8
	was_empty := len(s.unprocessed) <= 1 && len(s.processed) == 0

	new_unprocessed.allocator = runtime_alloc
	for entry in s.unprocessed do append(&new_unprocessed, entry)
	append(&new_unprocessed, buf[:])
	s.unprocessed = new_unprocessed[:]

	if !state.blob.has_data do state.blob.has_data = true

	if len(s.catalog.name) == 0 {
		s.catalog.name = description
		s.catalog.purpose = description
		s.catalog.created = now_rfc3339()
		state.shard_id = resolve_shard_id()
		log.infof("Auto-catalog: %s", s.catalog.name)
	}

	persist_ok := false
	if state.is_fork {
		persist_ok = congestion_append(buf[:])
	} else if was_empty {
		persist_ok = blob_write_self()
	} else {
		persist_ok = congestion_append(buf[:])
		if !persist_ok do persist_ok = blob_write_self()
	}
	if !persist_ok {
		log.errorf("Failed to persist thought %s", thought_id_to_hex(id))
		return {}, false
	}

	index_write(state.shard_id, state.exe_path)

	log.infof("Wrote thought %s (%d bytes body)", thought_id_to_hex(id), len(body_blob))
	meta_record_write()
	emit_event(.Write, thought_id_to_hex(id))
	vec_index_thought(id, description)
	gates_auto_learn(s)
	state.needs_maintenance = true
	return id, true
}

shard_ingest :: proc(raw_data: string, format: string = "") -> ([]Ingest_Result, bool) {
	if !state.has_llm do return nil, false

	g := &state.blob.shard.gates
	desc_text := gates_describe_for_llm(g)

	b := strings.builder_make(runtime_alloc)
	strings.write_string(&b, "You are a data intake processor for a shard.\n\n")
	if len(desc_text) > 0 {
		strings.write_string(&b, "Shard configuration:\n")
		strings.write_string(&b, desc_text)
		strings.write_string(&b, "\n")
	}

	cat := &state.blob.shard.catalog
	if len(cat.name) > 0 {
		fmt.sbprintf(&b, "Shard: %s — %s\n\n", cat.name, cat.purpose)
	}

	strings.write_string(&b, "Extract one or more thoughts from the incoming data.\n")
	strings.write_string(&b, "For each thought, output a JSON line:\n")
	strings.write_string(
		&b,
		"{\"description\":\"short title\",\"content\":\"full detail\",\"route_to\":\"\"}\n\n",
	)
	strings.write_string(&b, "IMPORTANT RULES:\n")
	strings.write_string(&b, "- Leave route_to EMPTY to store in THIS shard (the default)\n")
	strings.write_string(
		&b,
		"- ONLY set route_to if the content clearly belongs in a DIFFERENT linked shard\n",
	)
	fmt.sbprintf(&b, "- NEVER route to \"%s\" (that is this shard)\n", state.shard_id)
	strings.write_string(&b, "- Output ONLY JSON lines, no other text\n")

	system := strings.to_string(b)

	user := raw_data
	if len(format) > 0 {
		user = fmt.aprintf("Format: %s\n\n%s", format, raw_data, allocator = runtime_alloc)
	}

	response, ok := llm_chat(system, user)
	if !ok do return nil, false

	results: [dynamic]Ingest_Result
	results.allocator = runtime_alloc

	lines := strings.split(response, "\n", allocator = runtime_alloc)
	for line in lines {
		trimmed := strings.trim_space(line)
		if len(trimmed) == 0 || trimmed[0] != '{' do continue

		parsed, err := json.parse(transmute([]u8)trimmed, allocator = runtime_alloc)
		if err != nil do continue

		obj, obj_ok := parsed.(json.Object)
		if !obj_ok do continue

		desc, _ := obj["description"].(json.String)
		content, _ := obj["content"].(json.String)
		route, _ := obj["route_to"].(json.String)

		if len(desc) > 0 {
			append(
				&results,
				Ingest_Result {
					description = strings.clone(desc, runtime_alloc),
					content = strings.clone(content, runtime_alloc),
					route_to = strings.clone(route, runtime_alloc),
				},
			)
		}
	}

	return results[:], len(results) > 0
}

route_to_peer :: proc(description: string, content: string, agent: string) -> (Thought_ID, bool) {
	msg := fmt.aprintf(
		`{{"method":"tools/call","id":1,"params":{{"name":"shard_write","arguments":{{"description":"%s","content":"%s","agent":"%s"}}}}}}`,
		process_json_escape(description),
		process_json_escape(content),
		process_json_escape(agent),
		allocator = runtime_alloc,
	)
	msg_bytes := transmute([]u8)msg

	peers := index_list()
	cache_load()
	split_state, split_state_entry, has_split_state := cache_load_split_state()
	has_split_state_entry := has_split_state
	if has_split_state {
		resolved_state, changed := split_resolve_named_topics(
			split_state,
			peers,
			description,
			content,
		)
		if changed {
			split_state = resolved_state
			peers = index_list()
			_, split_state_entry, has_split_state_entry = cache_load_split_state()
		}
	}
	tried: map[string]bool
	tried.allocator = runtime_alloc
	split_mark_pretried_targets(&tried, split_state, has_split_state)

	if has_split_state && split_state.active {
		topic_a := split_state.topic_a
		topic_b := split_state.topic_b
		selected := ""
		if state.split_routing_hash_only {
			selected = split_route_target_hash_fallback(description, content, topic_a, topic_b)
		} else {
			signal_a := split_peer_signal_text(peers, topic_a)
			signal_b := split_peer_signal_text(peers, topic_b)
			semantic_target, semantic_ok := split_route_target_semantic(
				description,
				content,
				topic_a,
				topic_b,
				signal_a,
				signal_b,
				split_state_entry,
				has_split_state_entry,
			)
			if semantic_ok {
				selected = semantic_target
			} else {
				selected = split_route_target_hash_fallback(description, content, topic_a, topic_b)
			}
		}

		if len(selected) > 0 {
			tried[selected] = true
			if split_try_peer_write(msg_bytes, peers, selected) {
				log.infof("Routed thought to split peer %s", selected)
				return {}, true
			}
		}

		alternate := topic_a
		if selected == topic_a {
			alternate = topic_b
		}
		if len(alternate) > 0 && alternate != selected {
			tried[alternate] = true
			if split_try_peer_write(msg_bytes, peers, alternate) {
				log.infof("Routed thought to fallback split peer %s", alternate)
				return {}, true
			}
		}
	}
	for peer in peers {
		if peer.shard_id == state.shard_id || peer.shard_id in tried do continue
		if split_try_peer_write(msg_bytes, peers, peer.shard_id) {
			log.infof("Routed thought to peer %s", peer.shard_id)
			return {}, true
		}
	}

	log.info("No peer accepted thought, creating new shard")
	name := fmt.aprintf(
		"auto-%s",
		description[:min(len(description), 20)],
		allocator = runtime_alloc,
	)
	if create_shard(name, description) {
		return {}, true
	}
	return {}, false
}

read_thought_core :: proc(
	target_id: Thought_ID,
	count_usage: bool,
) -> (
	description: string,
	content: string,
	ok: bool,
) {
	if !state.has_key {
		log.error("Cannot read thought: no encryption key (set SHARD_KEY)")
		return "", "", false
	}

	s := &state.blob.shard
	for block in ([2][][]u8{s.processed, s.unprocessed}) {
		for blob in block {
			pos := 0
			t, parse_ok := thought_parse(blob, &pos)
			if !parse_ok do continue
			if t.id == target_id {
				if count_usage {
					if !read_count_touch(target_id, 1) {
						log.errorf(
							"Failed to record read usage for thought %s",
							thought_id_to_hex(target_id),
						)
					}
				}
				return thought_decrypt(state.key, &t)
			}
		}
	}
	return "", "", false
}

read_thought :: proc(target_id: Thought_ID) -> (description: string, content: string, ok: bool) {
	return read_thought_core(target_id, false)
}

slugify :: proc(name: string) -> string {
	buf := make([dynamic]u8, 0, len(name), runtime_alloc)
	prev_dash := true
	for r in name {
		if unicode.is_letter(r) || unicode.is_digit(r) {
			runtime.append_elem(&buf, u8(unicode.to_lower(r)))
			prev_dash = false
		} else if !prev_dash && len(buf) > 0 {
			runtime.append_elem(&buf, u8('-'))
			prev_dash = true
		}
	}
	if len(buf) > 0 && buf[len(buf) - 1] == '-' {
		pop(&buf)
	}
	if len(buf) > 64 {
		return string(buf[:64])
	}
	return string(buf[:])
}

resolve_shard_id :: proc() -> string {
	if state.blob.has_data && len(state.blob.shard.catalog.name) > 0 {
		return slugify(state.blob.shard.catalog.name)
	}
	h: [32]u8
	hash.hash_bytes_to_buffer(.SHA256, transmute([]u8)state.exe_path, h[:])
	hx := HEX_CHARS
	buf := make([]u8, 16, runtime_alloc)
	for i in 0 ..< 8 {
		buf[i * 2] = hx[h[i] >> 4]
		buf[i * 2 + 1] = hx[h[i] & 0x0f]
	}
	return string(buf)
}

ensure_dir :: proc(path: string) {
	if !os.exists(path) {
		parent := filepath.dir(path, runtime_alloc)
		if !os.exists(parent) do os.make_directory(parent)
		os.make_directory(path)
	}
}


working_copy_start :: proc() -> bool {
	ensure_dir(state.run_dir)
	state.working_copy = filepath.join({state.run_dir, state.shard_id}, runtime_alloc)
	raw, ok := os.read_entire_file(state.exe_path, runtime_alloc)
	if !ok do return false
	if !os.write_entire_file(state.working_copy, raw) do return false

	os2.chmod(
		state.working_copy,
		{
			.Read_User,
			.Write_User,
			.Execute_User,
			.Read_Group,
			.Execute_Group,
			.Read_Other,
			.Execute_Other,
		},
	)

	log.infof("Working copy created: %s", state.working_copy)
	return true
}

request_children_reap :: proc() {
	for {
		pid := posix.waitpid(-1, nil, {.NOHANG})
		if pid <= 0 do break
		if state.active_request_children > 0 {
			state.active_request_children -= 1
		}
	}
}

daemon_run :: proc() {
	log.infof("Shard daemon started: %s (id: %s)", state.exe_path, state.shard_id)

	if !working_copy_start() {
		log.error("Failed to create working copy")
		return
	}

	index_write(state.shard_id, state.exe_path)

	listener, listen_ok := ipc_listen(state.shard_id)
	if !listen_ok {
		log.error("Failed to start IPC listener")
		return
	}
	defer ipc_close_listener(&listener)

	log.infof("Listening on %s (idle timeout: %d ms)", listener.path, state.idle_timeout)

	http_pid := posix.fork()
	if http_pid == 0 {
		state.is_fork = true
		ipc_close_listener(&listener)
		http_run()
		os.exit(0)
	} else if http_pid > 0 {
		log.infof("HTTP server forked (pid: %d)", i32(http_pid))
	}

	for {
		request_children_reap()
		congestion_replay()
		conn, result := ipc_accept_timed(&listener, i32(state.idle_timeout))

		switch result {
		case .Timeout:
			request_children_reap()
			congestion_replay()
			log.info("Idle timeout reached, shutting down.")
			return
		case .Error:
			request_children_reap()
			congestion_replay()
			log.error("Accept error, shutting down.")
			return
		case .Ok:
			pid := posix.fork()
			if pid == 0 {
				state.is_fork = true
				ipc_close_listener(&listener)
				handle_connection(conn)
				os.exit(0)
			} else if pid > 0 {
				state.active_request_children += 1
				ipc_close(conn)
				request_children_reap()
				congestion_replay()
			} else {
				handle_connection(conn)
			}
		}
	}
}

handle_connection :: proc(conn: IPC_Conn) {
	defer ipc_close(conn)

	request_arena: mem.Arena
	request_buf := make([]byte, REQUEST_ARENA_SIZE, runtime_alloc)
	mem.arena_init(&request_arena, request_buf)
	defer mem.arena_free_all(&request_arena)

	ctx := context
	ctx.allocator = mem.arena_allocator(&request_arena)
	context = ctx

	msg, ok := ipc_recv_msg(conn)
	if !ok do return

	response := process_request(string(msg))
	if len(response) > 0 do ipc_send_msg(conn, transmute([]u8)response)
}

// --- Keychain shard ---


http_run :: proc() {
	port := state.http_port
	port_str := os.get_env("PORT", runtime_alloc)
	if len(port_str) > 0 {
		parsed := 0
		for c in port_str {
			if c >= '0' && c <= '9' do parsed = parsed * 10 + int(c - '0')
		}
		if parsed > 0 do port = parsed
	}

	posix.signal(
		transmute(posix.Signal)i32(13),
		transmute(proc "cdecl" (_: posix.Signal))uintptr(1),
	)

	fd := posix.socket(.INET, .STREAM)
	if fd == -1 {
		log.error("Failed to create HTTP socket")
		return
	}
	defer posix.close(fd)

	opt: i32 = 1
	posix.setsockopt(fd, posix.SOL_SOCKET, .REUSEADDR, &opt, size_of(i32))

	addr: posix.sockaddr_in
	addr.sin_family = .INET
	addr.sin_port = posix.in_port_t(u16(port))
	addr.sin_addr.s_addr = posix.in_addr_t(0)

	if posix.bind(fd, cast(^posix.sockaddr)&addr, size_of(addr)) != .OK {
		log.errorf("Failed to bind HTTP port %d", port)
		return
	}

	if posix.listen(fd, LISTEN_BACKLOG) != .OK {
		log.error("Failed to listen on HTTP socket")
		return
	}

	log.infof("HTTP server listening on port %d", port)

	for {
		request_children_reap()
		congestion_replay()

		client_addr: posix.sockaddr
		addr_len: posix.socklen_t = size_of(posix.sockaddr)
		client_fd := posix.accept(fd, &client_addr, &addr_len)
		if client_fd == -1 {
			request_children_reap()
			congestion_replay()
			log.errorf("HTTP accept failed: fd=%d", i32(fd))
			continue
		}
		log.infof("HTTP accepted connection: client_fd=%d", i32(client_fd))
		pid := posix.fork()
		if pid == 0 {
			state.is_fork = true
			posix.close(fd)
			transport.Http_Handle(
				client_fd,
				process_http_tool_handler,
				process_http_tool_resolver,
				process_http_meta_single_handler,
				process_http_meta_batch_handler,
				runtime_alloc,
			)
			os.exit(0)
		} else if pid > 0 {
			state.active_request_children += 1
			posix.close(client_fd)
			request_children_reap()
			congestion_replay()
		} else {
			request_children_reap()
			congestion_replay()
			log.error("HTTP fork failed, handling inline")
			transport.Http_Handle(
				client_fd,
				process_http_tool_handler,
				process_http_tool_resolver,
				process_http_meta_single_handler,
				process_http_meta_batch_handler,
				runtime_alloc,
			)
			request_children_reap()
			congestion_replay()
		}
	}
}

daemon_shutdown :: proc() {
	if len(state.working_copy) > 0 && state.working_copy != state.exe_path {
		index_write(state.shard_id, state.working_copy, state.exe_path)
		log.infof(
			"Index updated: %s -> %s (prev: %s)",
			state.shard_id,
			state.working_copy,
			state.exe_path,
		)
	}
	log.infof("Shard daemon stopped: %s", state.exe_path)
}
