package shard

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import os2 "core:os/os2"

// =============================================================================
// Content scanner — AI-based sensitive content detection
// =============================================================================
//
// Uses the configured LLM to evaluate whether content contains sensitive data
// (API keys, passwords, PII). Returns findings but does NOT block writes.
// The write persists first; findings are attached as informational alerts.
//
// If no LLM is configured, scanning is skipped (no findings).
//

AI_SCANNER_SYSTEM_PROMPT :: `You are a content security reviewer. Analyze the given text and identify any sensitive content that probably should not be stored in a knowledge base.

Look for:
- API keys, tokens, or credentials (e.g. "sk-...", "AKIA...", Bearer tokens, JWTs)
- Passwords or secrets (e.g. "the password is apple", "secret = xyz")
- Personal identifiable information: phone numbers, addresses, SSNs
- Private keys, certificates, or cryptographic material
- Database connection strings with embedded credentials

Be conservative — only flag things that are clearly sensitive. Do not flag:
- General discussion about security concepts
- Placeholder or example values (e.g. "password123" in a tutorial)
- Public information or documentation

Respond with a JSON array of findings. Each finding has "category" (one of: api_key, password, pii, secret) and "snippet" (the relevant text, max 50 chars). If nothing sensitive is found, respond with an empty array: []

Examples:
Text: "The production DB password is swordfish"
Response: [{"category":"password","snippet":"password is swordfish"}]

Text: "The architecture uses a two-block design"
Response: []`

// scan_content asks the LLM to evaluate content for sensitive data.
// Returns an empty list if no LLM is configured or nothing is found.
scan_content :: proc(description: string, content: string, allocator := context.allocator) -> [dynamic]Alert_Finding {
	findings := make([dynamic]Alert_Finding, allocator)

	cfg := config_get()
	if cfg.llm_url == "" || cfg.llm_model == "" do return findings

	// Build the text to scan
	text := fmt.tprintf("Description: %s\n\nContent: %s", description, content)

	// Build chat completions request
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"model":"`)
	strings.write_string(&b, json_escape(cfg.llm_model))
	strings.write_string(&b, `","temperature":0,"max_tokens":512,"messages":[`)
	strings.write_string(&b, `{"role":"system","content":"`)
	strings.write_string(&b, json_escape(AI_SCANNER_SYSTEM_PROMPT))
	strings.write_string(&b, `"},{"role":"user","content":"`)
	strings.write_string(&b, json_escape(text))
	strings.write_string(&b, `"}]}`)

	chat_url := fmt.tprintf("%s/chat/completions", strings.trim_right(cfg.llm_url, "/"))
	response, ok := _scanner_post(chat_url, cfg.llm_key, strings.to_string(b), cfg.llm_timeout)
	if !ok do return findings

	// Parse the response — extract the assistant's message content
	content_str := _extract_chat_content(response)
	if content_str == "" do return findings

	_parse_ai_findings(content_str, &findings, allocator)
	return findings
}

// =============================================================================
// Response parsing
// =============================================================================

@(private)
_extract_chat_content :: proc(response: string) -> string {
	parsed, err := json.parse(transmute([]u8)response, allocator = context.temp_allocator)
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

	message, has_msg := first["message"]
	if !has_msg do return ""
	msg_obj, is_msg_obj := message.(json.Object)
	if !is_msg_obj do return ""

	content_val, has_content := msg_obj["content"]
	if !has_content do return ""
	if s, is_str := content_val.(string); is_str {
		return s
	}
	return ""
}

@(private)
_parse_ai_findings :: proc(content: string, findings: ^[dynamic]Alert_Finding, allocator := context.allocator) {
	// Find the JSON array in the content (might have markdown fences)
	start := strings.index(content, "[")
	end := strings.last_index(content, "]")
	if start < 0 || end <= start do return

	json_str := content[start:end+1]
	parsed, err := json.parse(transmute([]u8)json_str, allocator = context.temp_allocator)
	if err != nil do return
	defer json.destroy_value(parsed, context.temp_allocator)

	arr, is_arr := parsed.(json.Array)
	if !is_arr do return

	for item in arr {
		obj, is_obj := item.(json.Object)
		if !is_obj do continue

		cat_val, has_cat := obj["category"]
		if !has_cat do continue
		cat, cat_ok := cat_val.(string)
		if !cat_ok do continue

		snip_val, has_snip := obj["snippet"]
		snippet := ""
		if has_snip {
			if s, s_ok := snip_val.(string); s_ok {
				snippet = s
			}
		}

		// Accept any category the AI returns
		append(findings, Alert_Finding{
			category = strings.clone(cat, allocator),
			snippet  = strings.clone(snippet, allocator),
		})
	}
}

// =============================================================================
// HTTP helper
// =============================================================================

@(private)
_scanner_post :: proc(url: string, api_key: string, body: string, timeout: int, allocator := context.allocator) -> (string, bool) {
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

	state, stdout, _, err := os2.process_exec(
		os2.Process_Desc{command = cmd[:]},
		allocator,
	)
	if err != nil do return "", false
	if state.exit_code != 0 do return "", false
	return string(stdout), true
}
