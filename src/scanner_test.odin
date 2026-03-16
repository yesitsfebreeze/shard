package shard

import "core:testing"

// =============================================================================
// Content scanner tests
// =============================================================================
//
// The scanner delegates all content evaluation to the configured LLM.
// When no LLM is configured, scan_content returns zero findings —
// the code itself never decides what is or isn't sensitive.
//

@(test)
test_scanner_no_llm_returns_empty :: proc(t: ^testing.T) {
	// Without an LLM configured, scanning must produce no findings.
	// The code must not impose its own judgment on content.
	findings := scan_content("password = hunter2", "sk-1234567890abcdef AKIA access_token=secret")
	defer delete(findings)
	testing.expect(t, len(findings) == 0, "scanner must not flag content without an LLM — content decisions belong to the AI")
}

@(test)
test_scanner_clean_content_no_llm :: proc(t: ^testing.T) {
	findings := scan_content("meeting notes", "We discussed the roadmap and agreed on priorities.")
	defer delete(findings)
	testing.expect(t, len(findings) == 0, "clean content must produce no findings")
}
