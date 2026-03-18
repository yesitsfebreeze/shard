package shard

import "core:encoding/json"
import "core:fmt"
import "core:os/os2"
import "core:strings"

// =============================================================================
// LLM — endpoint URL builder and streaming chat via SSE
// =============================================================================

// Streaming_Callback is called for each SSE chunk. done=true signals completion.
Streaming_Callback :: #type proc(chunk: string, done: bool, user_data: rawptr)

// Streaming_Message is a single message in a chat conversation.
Streaming_Message :: struct {
	role:    string, // "system", "user", "assistant"
	content: string,
}

// _llm_endpoint constructs a full URL for an LLM API endpoint suffix.
@(private)
_llm_endpoint :: proc(suffix: string) -> string {
	cfg := config_get()
	trimmed := strings.trim_right(cfg.llm_url, "/")
	return fmt.tprintf("%s%s", trimmed, suffix)
}

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
