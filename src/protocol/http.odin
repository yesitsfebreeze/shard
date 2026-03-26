package protocol

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:sys/posix"

HTTP_Read_Buf_Size :: 8192

HTTP_Request :: struct {
	method: string,
	path:   string,
	body:    string,
}

Http_Read_Request :: proc(fd: posix.FD, allocator: mem.Allocator) -> (HTTP_Request, bool) {
	buf := make([]u8, HTTP_Read_Buf_Size, allocator)
	if buf == nil do return {}, false

	n := posix.recv(fd, raw_data(buf), len(buf), {})
	if n <= 0 do return {}, false

	req := string(buf[:int(n)])
	first_line_end := strings.index(req, "\r\n")
	if first_line_end < 0 do first_line_end = strings.index(req, "\n")
	if first_line_end < 0 do return {}, false

	parts := strings.split(req[:first_line_end], " ", allocator = allocator)
	if len(parts) < 2 do return {}, false

	method := parts[0]
	path := parts[1]
	query_split := strings.index(path, "?")
	if query_split >= 0 do path = path[:query_split]

	body := ""
	body_start := strings.index(req, "\r\n\r\n")
	if body_start >= 0 do body = req[body_start + 4:]

	return HTTP_Request{method = method, path = path, body = body}, true
}

Http_Send_JSON_Response :: proc(fd: posix.FD, status: string, body: string, allocator: mem.Allocator) -> bool {
	resp := fmt.aprintf(
		"HTTP/1.1 %s\\r\\nContent-Type: application/json\\r\\nAccess-Control-Allow-Origin: *\\r\\nContent-Length: %d\\r\\nConnection: close\\r\\n\\r\\n%s",
		status,
		len(body),
		body,
		allocator = allocator,
	)

	sent := posix.send(fd, raw_data(transmute([]u8)resp), len(resp), {})
	return sent == len(resp)
}

Http_Send_Options_Response :: proc(fd: posix.FD) {
	options_resp := "HTTP/1.1 204 No Content\\r\\nAccess-Control-Allow-Origin: *\\r\\nAccess-Control-Allow-Methods: GET, POST, DELETE, OPTIONS\\r\\nAccess-Control-Allow-Headers: Content-Type\\r\\nConnection: close\\r\\n\\r\\n"
	posix.send(fd, raw_data(transmute([]u8)options_resp), len(options_resp), {})
}

Http_Content_Type :: proc(path: string) -> string {
	if strings.has_suffix(path, ".html") do return "text/html; charset=utf-8"
	if strings.has_suffix(path, ".js") do return "application/javascript"
	if strings.has_suffix(path, ".css") do return "text/css"
	if strings.has_suffix(path, ".svg") do return "image/svg+xml"
	if strings.has_suffix(path, ".json") do return "application/json"
	if strings.has_suffix(path, ".png") do return "image/png"
	if strings.has_suffix(path, ".ico") do return "image/x-icon"
	if strings.has_suffix(path, ".woff2") do return "font/woff2"
	if strings.has_suffix(path, ".woff") do return "font/woff"
	if strings.has_suffix(path, ".ttf") do return "font/ttf"
	return "application/octet-stream"
}

Http_Send_Static_Response :: proc(fd: posix.FD, full_path: string, data: []u8, allocator: mem.Allocator) {
	ct := Http_Content_Type(full_path)
	header := fmt.aprintf(
		"HTTP/1.1 200 OK\\r\\nContent-Type: %s\\r\\nContent-Length: %d\\r\\nConnection: close\\r\\n\\r\\n",
		ct,
		len(data),
		allocator = allocator,
	)
	posix.send(fd, raw_data(transmute([]u8)header), len(header), {})
	posix.send(fd, raw_data(data), len(data), {})
}
