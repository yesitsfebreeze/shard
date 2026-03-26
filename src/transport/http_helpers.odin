package transport

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:strings"

Parse_Decimal_Int :: proc(raw: string) -> (int, bool) {
	if len(raw) == 0 {
		return 0, false
	}
	value := 0
	for c in transmute([]u8)raw {
		if c < '0' || c > '9' {
			return 0, false
		}
		value = value * 10 + int(c - '0')
	}
	return value, true
}

Parse_JSON_String_Array :: proc(value: json.Value, allocator: mem.Allocator) -> ([dynamic]string, bool) {
	ids_arr, arr_ok := value.(json.Array)
	if !arr_ok {
		return nil, false
	}

	ids := make([dynamic]string, 0, allocator)
	for item in ids_arr {
		id, is_str := item.(json.String)
		if !is_str {
			return nil, false
		}
		append(&ids, strings.clone(id, allocator))
	}

	return ids, true
}

JSON_Error_Payload :: proc(code: string, message: string, bucket: int, allocator: mem.Allocator) -> string {
	b := strings.builder_make(allocator)
	fmt.sbprintf(
		&b,
		`{"error":{"code":"%s","message":"%s"`,
		JSON_Escape(code, allocator),
		JSON_Escape(message, allocator),
	)
	if bucket >= 0 do fmt.sbprintf(&b, `,"bucket":%d`, bucket)
	strings.write_string(&b, `}}`)
	return strings.to_string(b)
}

JSON_Escape :: proc(s: string, allocator: mem.Allocator) -> string {
	b := strings.builder_make(allocator)
	for c in s {
		switch c {
		case '"':
			strings.write_string(&b, `\\"`)
		case '\\':
			strings.write_string(&b, `\\\\`)
		case '\n':
			strings.write_string(&b, `\\n`)
		case '\r':
			strings.write_string(&b, `\\r`)
		case '\t':
			strings.write_string(&b, `\\t`)
		case:
			strings.write_rune(&b, c)
		}
	}
	return strings.to_string(b)
}
