package shard

import "core:fmt"
import "core:os/os2"

// =============================================================================
// HTTP — shared curl POST helper used by embed and daemon LLM calls
// =============================================================================

// _http_post sends a JSON POST request via curl and returns the response body.
// api_key is optional — pass "" to omit the Authorization header.
// timeout is in seconds (0 = no limit).
_http_post :: proc(
	url: string,
	api_key: string,
	body: string,
	timeout: int,
	allocator := context.allocator,
) -> (string, bool) {
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, "curl", "-s", "-S")
	if timeout > 0 {
		append(&cmd, "--max-time", fmt.tprintf("%d", timeout))
	}
	append(&cmd, "-X", "POST")
	append(&cmd, "-H", "Content-Type: application/json")
	if api_key != "" {
		append(&cmd, "-H", fmt.tprintf("Authorization: Bearer %s", api_key))
	}
	append(&cmd, "-d", body)
	append(&cmd, url)

	state, stdout, stderr, err := os2.process_exec(os2.Process_Desc{command = cmd[:]}, allocator)
	if err != nil {
		fmt.eprintfln("http: curl error: %v", err)
		delete(stdout, allocator)
		delete(stderr, allocator)
		return "", false
	}
	if state.exit_code != 0 {
		stderr_str := string(stderr)
		trunc := min(200, len(stderr_str))
		fmt.eprintfln("http: curl exit %d: %s", state.exit_code, stderr_str[:trunc])
		delete(stdout, allocator)
		delete(stderr, allocator)
		return "", false
	}
	delete(stderr, allocator)
	return string(stdout), true
}
