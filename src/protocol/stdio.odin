package protocol

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"

MCP_READ_BUF :: 65536

Stdio_Processor :: proc(message: string) -> string

stdio_run :: proc(process: Stdio_Processor, allocator: mem.Allocator) {
	buf := make([]u8, MCP_READ_BUF, allocator)
	remainder := make([dynamic]u8, 0, 4096, allocator)
	use_header_framing := false
	for {
		n, err := os.read(os.stdin, buf[:])
		if err != nil || n <= 0 do break

		for b in buf[:n] do append(&remainder, b)

		for {
			if len(remainder) == 0 do break

			start := 0
			for start < len(remainder) && (remainder[start] == '\r' || remainder[start] == '\n') {
				start += 1
			}
			if start > 0 {
				consume_bytes(&remainder, start)
				if len(remainder) == 0 do break
			}

			if looks_like_headers(remainder[:]) {
				use_header_framing = true
				head_end, sep_len, has_headers := find_header_end(remainder[:])
				if !has_headers do break

				content_len, has_len := parse_content_length(remainder[:head_end])
				if !has_len {
					resp := `{"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"missing content-length"}}`
					send_response(resp, use_header_framing, allocator)
					consume_bytes(&remainder, head_end + sep_len)
					continue
				}

				payload_start := head_end + sep_len
				payload_end := payload_start + content_len
				if payload_end > len(remainder) do break

				payload := string(remainder[payload_start:payload_end])
				resp := process(payload)
				if len(resp) > 0 do send_response(resp, use_header_framing, allocator)

				consume_bytes(&remainder, payload_end)
				continue
			}

			nl := -1
			for i in 0 ..< len(remainder) {
				if remainder[i] == '\n' {nl = i; break}
			}
			if nl == -1 do break

			line := string(remainder[:nl])
			line = strings.trim_right(line, "\r")

			if len(strings.trim_space(line)) > 0 {
				resp := process(line)
				if len(resp) > 0 do send_response(resp, use_header_framing, allocator)
			}

			consume_bytes(&remainder, nl + 1)
		}
	}
}

send_response :: proc(resp: string, use_header_framing: bool, allocator: mem.Allocator) {
	if use_header_framing {
		framed := fmt.aprintf("Content-Length: %d\r\n\r\n%s", len(resp), resp)
		os.write(os.stdout, transmute([]u8)framed)
	} else {
		line_resp := line_normalize_response(resp, allocator)
		line := fmt.aprintf("%s\n", line_resp)
		os.write(os.stdout, transmute([]u8)line)
	}
}

line_normalize_response :: proc(resp: string, allocator: mem.Allocator) -> string {
	b := strings.builder_make(allocator)
		for c in resp {
			if c == '\n' || c == '\r' do continue
			strings.write_rune(&b, c)
		}
		return strings.to_string(b)
}

Line_Normalize_Response :: proc(resp: string, allocator: mem.Allocator) -> string {
	return line_normalize_response(resp, allocator)
}

consume_bytes :: proc(buf: ^[dynamic]u8, n: int) {
	if n <= 0 do return
	if n >= len(buf^) {
		resize(buf, 0)
		return
	}
	copy(buf^[:len(buf^) - n], buf^[n:])
	resize(buf, len(buf^) - n)
}

find_header_end :: proc(buf: []u8) -> (int, int, bool) {
	if len(buf) >= 4 {
		for i in 0 ..< len(buf) - 3 {
			if buf[i] == '\r' && buf[i + 1] == '\n' && buf[i + 2] == '\r' && buf[i + 3] == '\n' {
				return i, 4, true
			}
		}
	}
	if len(buf) >= 2 {
		for i in 0 ..< len(buf) - 1 {
			if buf[i] == '\n' && buf[i + 1] == '\n' {
				return i, 2, true
			}
		}
	}
	return 0, 0, false
}

looks_like_headers :: proc(buf: []u8) -> bool {
	if len(buf) == 0 do return false

	i := 0
	for i < len(buf) && (buf[i] == ' ' || buf[i] == '\t' || buf[i] == '\r' || buf[i] == '\n') do i += 1
	if i >= len(buf) do return false

	if buf[i] == '{' || buf[i] == '[' do return false

	line_end := i
	for line_end < len(buf) && buf[line_end] != '\n' && buf[line_end] != '\r' do line_end += 1
	if line_end <= i do return false

	for j in i ..< line_end {
		if buf[j] == ':' do return true
	}

	return false
}

parse_content_length :: proc(headers: []u8) -> (int, bool) {
	prefix := "content-length:"
	i := 0
	for i < len(headers) {
		line_start := i
		for i < len(headers) && headers[i] != '\n' do i += 1
		line_end := i
		if line_end > line_start && headers[line_end - 1] == '\r' do line_end -= 1

		if line_end - line_start >= len(prefix) {
			match := true
			for j in 0 ..< len(prefix) {
				c := headers[line_start + j]
				if c >= 'A' && c <= 'Z' do c += 32
				if c != prefix[j] {
					match = false
					break
				}
			}
			if match {
				k := line_start + len(prefix)
				for k < line_end && (headers[k] == ' ' || headers[k] == '\t') do k += 1

				val := 0
				has_digit := false
				for k < line_end && headers[k] >= '0' && headers[k] <= '9' {
					has_digit = true
					val = val * 10 + int(headers[k] - '0')
					k += 1
				}
				if has_digit do return val, true
			}
		}

		i += 1
	}

	return 0, false
}
