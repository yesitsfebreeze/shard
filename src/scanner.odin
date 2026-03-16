package shard

import "core:strings"

// =============================================================================
// Content scanner — detect sensitive content before writes persist
// =============================================================================
//
// Checks description and content for API keys, passwords, PII patterns.
// Simple string matching — no regex library needed.
//

// API key prefixes that indicate leaked credentials
_API_KEY_PREFIXES :: [?]string{
	"sk-",          // OpenAI, Stripe
	"ghp_",         // GitHub personal access token
	"gho_",         // GitHub OAuth
	"ghu_",         // GitHub user-to-server
	"ghs_",         // GitHub server-to-server
	"AKIA",         // AWS access key
	"xox",          // Slack tokens (xoxb-, xoxp-, xoxs-)
	"Bearer ",      // Auth header values
	"eyJ",          // JWT tokens (base64-encoded JSON)
}

// Keywords that suggest password/secret values nearby
_SECRET_KEYWORDS :: [?]string{
	"password",
	"passwd",
	"secret",
	"api_key",
	"apikey",
	"api-key",
	"access_token",
	"private_key",
}

scan_content :: proc(description: string, content: string, allocator := context.allocator) -> [dynamic]Alert_Finding {
	findings := make([dynamic]Alert_Finding, allocator)

	_scan_text :: proc(text: string, findings: ^[dynamic]Alert_Finding, allocator := context.allocator) {
		if text == "" do return

		// Check API key prefixes
		for prefix in _API_KEY_PREFIXES {
			idx := strings.index(text, prefix)
			if idx >= 0 {
				end := min(idx + 32, len(text))
				snippet := text[idx:end]
				append(findings, Alert_Finding{
					category = "api_key",
					snippet  = strings.clone(snippet, allocator),
				})
				break // one finding per category per text block
			}
		}

		// Check password/secret patterns (keyword near = or :)
		lower := strings.to_lower(text, context.temp_allocator)
		for keyword in _SECRET_KEYWORDS {
			idx := strings.index(lower, keyword)
			if idx < 0 do continue
			// Look for = or : within 16 chars after the keyword
			after_start := idx + len(keyword)
			after_end := min(after_start + 16, len(lower))
			after := lower[after_start:after_end]
			if strings.contains(after, "=") || strings.contains(after, ":") {
				snippet_end := min(after_start + 32, len(text))
				snippet := text[idx:snippet_end]
				append(findings, Alert_Finding{
					category = "password",
					snippet  = strings.clone(snippet, allocator),
				})
				break
			}
		}

		// Check PII: email patterns (word@word.word)
		if _contains_email_pattern(text) {
			append(findings, Alert_Finding{
				category = "pii",
				snippet  = strings.clone("[email address detected]", allocator),
			})
		}
	}

	_scan_text(description, &findings, allocator)
	_scan_text(content, &findings, allocator)
	return findings
}

// Simple email detection: looks for @ surrounded by alphanumeric chars with a dot after
@(private)
_contains_email_pattern :: proc(text: string) -> bool {
	at_idx := strings.index(text, "@")
	if at_idx <= 0 || at_idx >= len(text) - 3 do return false
	// Check char before @ is alphanumeric
	before := text[at_idx - 1]
	if !_is_alnum(before) do return false
	// Check there's a dot after @
	after := text[at_idx + 1:]
	dot_idx := strings.index(after, ".")
	if dot_idx <= 0 do return false
	// Check char after dot exists and is alpha
	if dot_idx + 1 >= len(after) do return false
	if !_is_alpha(after[dot_idx + 1]) do return false
	return true
}

@(private)
_is_alnum :: proc(c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
}

@(private)
_is_alpha :: proc(c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}
