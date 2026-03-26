package transport

import "core:encoding/json"
import "core:log"
import "core:os"
import "core:strings"
import "core:mem"
import "core:sys/posix"

import "../protocol"

Http_Tool_Handler :: proc(tool_name: string, body: string) -> string
Http_Tool_Resolver :: proc(method: string, path: string) -> (tool_name: string, key: string, ok: bool)
Http_Meta_Single_Handler :: proc(bucket: int, shard_id: string) -> (string, string, bool)
Http_Meta_Batch_Handler :: proc(bucket: int, ids: [dynamic]string) -> (string, string, bool)

HTTP_Meta_Response :: struct {
	body:  string,
	status: string,
	ok: bool,
}

Http_Parse_Meta_Single_Path :: proc(path: string) -> (int, string, bool) {
	prefix := ""
	if strings.has_prefix(path, "/meta/") {
		prefix = "/meta/"
	} else if strings.has_prefix(path, "/mcp/meta/") {
		prefix = "/mcp/meta/"
	}
	if len(prefix) == 0 do return 0, "", false

	rest := path[len(prefix):]
	sep := strings.index(rest, "/")
	if sep <= 0 do return 0, "", false
	bucket_str := rest[:sep]
	shard_id := rest[sep + 1:]
	if len(shard_id) == 0 do return 0, "", false
	if strings.contains(shard_id, "/") do return 0, "", false

	bucket, ok := Parse_Decimal_Int(bucket_str)
	if !ok do return 0, "", false
	return bucket, shard_id, true
}

Http_Parse_Meta_Batch_Path :: proc(path: string) -> (int, bool) {
	prefix := ""
	if strings.has_prefix(path, "/meta/") {
		prefix = "/meta/"
	} else if strings.has_prefix(path, "/mcp/meta/") {
		prefix = "/mcp/meta/"
	}
	if len(prefix) == 0 do return 0, false

	rest := path[len(prefix):]
	if len(rest) == 0 do return 0, false
	if strings.contains(rest, "/") do return 0, false
	bucket, ok := Parse_Decimal_Int(rest)
	if !ok do return 0, false
	return bucket, true
}

Http_Parse_Meta_Request_Body :: proc(body: string, allocator: mem.Allocator) -> ([dynamic]string, bool) {
	if len(strings.trim_space(body)) == 0 do return make([dynamic]string, 0, allocator), true
	parsed, err := json.parse(transmute([]u8)body, allocator = allocator)
	if err != nil do return nil, false
	obj, obj_ok := parsed.(json.Object)
	if !obj_ok do return nil, false

	ids_val, has_ids := obj["ids"]
	if !has_ids do return make([dynamic]string, 0, allocator), true
	return Parse_JSON_String_Array(ids_val, allocator)
}

http_meta_error_response :: proc(code: string, message: string, bucket: int = -1, allocator: mem.Allocator) -> HTTP_Meta_Response {
	return HTTP_Meta_Response {
		body = JSON_Error_Payload(code, message, bucket, allocator),
		status = "400 Bad Request",
		ok = false,
	}
}

http_serve_static :: proc(fd: posix.FD, raw_path: string, allocator: mem.Allocator) {
	static_dir := os.get_env("SHARD_STATIC", allocator)
	if len(static_dir) == 0 do static_dir = "/srv"

	serve_path := raw_path
	qmark := strings.index(serve_path, "?")
	if qmark >= 0 do serve_path = serve_path[:qmark]

	if strings.contains(serve_path, "..") {
		resp := "HTTP/1.1 403 Forbidden\\r\\nContent-Length: 9\\r\\nConnection: close\\r\\n\\r\\nForbidden"
		posix.send(fd, raw_data(transmute([]u8)resp), len(resp), {})
		return
	}

	if serve_path == "/" do serve_path = "/index.html"

	full_path := strings.concatenate({static_dir, serve_path}, allocator)
	data, ok := os.read_entire_file(full_path, allocator)
	if !ok {
		full_path = strings.concatenate({static_dir, "/index.html"}, allocator)
		data, ok = os.read_entire_file(full_path, allocator)
	}

	if !ok {
		resp := "HTTP/1.1 404 Not Found\\r\\nContent-Length: 9\\r\\nConnection: close\\r\\n\\r\\nNot Found"
		posix.send(fd, raw_data(transmute([]u8)resp), len(resp), {})
		return
	}

	protocol.Http_Send_Static_Response(fd, full_path, data, allocator)
}

Http_Handle :: proc(
	fd: posix.FD,
	tool_handler: Http_Tool_Handler,
	tool_resolver: Http_Tool_Resolver,
	meta_single_handler: Http_Meta_Single_Handler,
	meta_batch_handler: Http_Meta_Batch_Handler,
	allocator: mem.Allocator,
) {
	defer posix.close(fd)
	log.infof("HTTP handle start: fd=%d", i32(fd))

	request, ok := protocol.Http_Read_Request(fd, allocator)
	if !ok {
		log.error("HTTP handle: failed to parse request")
		return
	}

	method := request.method
	path := request.path
	query_start := strings.index(path, "?")
	if query_start >= 0 do path = path[:query_start]
	log.infof("HTTP %s %s", method, path)

	body := request.body

	response_body: string
	status := "200 OK"
	meta_handled := false

	if method == "GET" {
		bucket, shard_id, meta_ok := Http_Parse_Meta_Single_Path(path)
		if meta_ok {
			mbody, mstatus, mok := meta_single_handler(bucket, shard_id)
			if mok {
				response_body, status = mbody, mstatus
			} else {
				response_body = mbody
				status = mstatus
			}
			meta_handled = true
		}
	} else if method == "POST" {
		bucket, meta_ok := Http_Parse_Meta_Batch_Path(path)
		if meta_ok {
			ids, ids_ok := Http_Parse_Meta_Request_Body(body, allocator)
			if !ids_ok {
				resp := http_meta_error_response("invalid_request", "ids must be an array of strings", -1, allocator)
				response_body, status = resp.body, resp.status
				meta_handled = true
			} else {
				mbody, mstatus, mok := meta_batch_handler(bucket, ids)
				if mok {
					response_body, status = mbody, mstatus
				} else {
					response_body = mbody
					status = mstatus
				}
				meta_handled = true
			}
		}
	}

	meta_prefix := strings.has_prefix(path, "/meta/") || strings.has_prefix(path, "/mcp/meta/")
	if meta_prefix && !meta_handled {
		if method == "GET" || method == "POST" {
			resp := http_meta_error_response("invalid_bucket", "bucket must be integer >= 0", -1, allocator)
			response_body, status = resp.body, resp.status
			meta_handled = true
		}
	}

	tool_name := ""
	cache_key := ""
	tool_ok := false
	if !meta_handled {
		tool_name, cache_key, tool_ok = tool_resolver(method, path)
		if tool_ok && len(cache_key) > 0 {
			cache_key_b := strings.builder_make(allocator)
			strings.write_string(&cache_key_b, `{"key":"`)
			strings.write_string(&cache_key_b, JSON_Escape(cache_key, allocator))
			strings.write_string(&cache_key_b, `"}`)
			body = strings.to_string(cache_key_b)
		}
	}

	if meta_handled {
		// response already prepared.
	} else if tool_ok {
		args := body if len(body) > 0 else "{}"
		resp := tool_handler(tool_name, args)
		parsed, err := json.parse(transmute([]u8)resp, allocator = allocator)
		if err == nil {
			obj, _ := parsed.(json.Object)
			result_obj, _ := obj["result"].(json.Object)
			content_arr, _ := result_obj["content"].(json.Array)
			if len(content_arr) > 0 {
				first, _ := content_arr[0].(json.Object)
				text, _ := first["text"].(json.String)
				text_b := strings.builder_make(allocator)
				strings.write_string(&text_b, `{"result":"`)
				strings.write_string(&text_b, JSON_Escape(text, allocator))
				strings.write_string(&text_b, `"}`)
				response_body = strings.to_string(text_b)
			}
			if _, has_err := obj["error"]; has_err {
				status = "400 Bad Request"
				response_body = resp
			}
		} else {
			status = "500 Internal Server Error"
			response_body = `{"error":"internal error"}`
		}
	} else if method == "GET" {
		log.infof("HTTP serving static: %s", path)
		http_serve_static(fd, path, allocator)
		return
	} else {
		log.errorf("HTTP 404: %s %s", method, path)
		status = "404 Not Found"
		response_body = `{"error":"not found"}`
	}

	if method == "OPTIONS" {
		protocol.Http_Send_Options_Response(fd)
		return
	}
	protocol.Http_Send_JSON_Response(fd, status, response_body, allocator)
}
