package shard

import "core:encoding/endian"
import "core:encoding/json"
import "core:mem"
import "core:strings"

import "transport"

json_escape :: proc(s: string, allocator: mem.Allocator) -> string {
	return transport.JSON_Escape(s, allocator)
}

parse_decimal_int :: proc(raw: string) -> (int, bool) {
	return transport.Parse_Decimal_Int(raw)
}

parse_non_negative_int_from_json :: proc(value: json.Value) -> (int, bool) {
	switch v in value {
	case json.Integer:
		if v < 0 do return 0, false
		return int(v), true
	case json.Float:
		if v < 0 do return 0, false
		if f64(int(v)) != v do return 0, false
		return int(v), true
	case json.String:
		return parse_decimal_int(v)
	case json.Null, json.Boolean, json.Array, json.Object:
		return 0, false
	case:
		return 0, false
	}
}

parse_json_string_array :: proc(
	value: json.Value,
	allocator: mem.Allocator,
) -> (
	[dynamic]string,
	bool,
) {
	return transport.Parse_JSON_String_Array(value, allocator)
}

json_first_non_empty_string :: proc(
	obj: json.Object,
	fields: []string,
	allocator: mem.Allocator,
) -> (
	string,
	bool,
) {
	for field in fields {
		if s, ok := obj[field].(json.String); ok {
			clean := strings.trim_space(s)
			if len(clean) > 0 do return strings.clone(clean, allocator), true
		}
	}

	return "", false
}

json_value_to_text :: proc(value: json.Value, allocator: mem.Allocator) -> string {
	if s, ok := value.(json.String); ok {
		return strings.clone(string(s), allocator)
	}
	if arr, ok := value.(json.Array); ok {
		b := strings.builder_make(allocator)
		wrote := false
		for item in arr {
			if s, s_ok := item.(json.String); s_ok {
				if len(strings.trim_space(string(s))) == 0 do continue
				if wrote do strings.write_string(&b, " ")
				strings.write_string(&b, string(s))
				wrote = true
			}
		}
		return strings.to_string(b)
	}
	return ""
}

json_first_non_empty_text :: proc(
	obj: json.Object,
	fields: []string,
	allocator: mem.Allocator,
) -> (
	string,
	bool,
) {
	for field in fields {
		if raw, ok := obj[field]; ok {
			text := json_value_to_text(raw, allocator)
			clean := strings.trim_space(text)
			if len(clean) > 0 do return strings.clone(clean, allocator), true
		}
	}
	return "", false
}

json_error_payload :: proc(
	code: string,
	message: string,
	bucket: int = -1,
	allocator: mem.Allocator,
) -> string {
	return transport.JSON_Error_Payload(code, message, bucket, allocator)
}

string_suffix_after_char :: proc(
	value: string,
	sep: string,
	allocator: mem.Allocator,
) -> (
	string,
	bool,
) {
	idx := strings.index(value, sep)
	if idx < 0 do return "", false
	if idx + 1 >= len(value) do return "", false
	return strings.clone(value[idx + 1:], allocator), true
}

string_has_colon_suffix_of_hex :: proc(value: string, suffix_len: int) -> bool {
	sep := strings.index(value, ":")
	if sep < 0 || sep + 1 >= len(value) do return false

	suffix := value[sep + 1:]
	if len(suffix) != suffix_len do return false

	for c in suffix {
		if !(c >= '0' && c <= '9') && !(c >= 'a' && c <= 'f') && !(c >= 'A' && c <= 'F') do return false
	}
	return true
}

parse_rfc3339_date :: proc(s: string) -> (year: int, month: int, day: int) {
	if len(s) < 10 do return 0, 0, 0
	year = parse_int_simple(s[0:4])
	month = parse_int_simple(s[5:7])
	day = parse_int_simple(s[8:10])
	return
}

parse_int_simple :: proc(s: string) -> int {
	result := 0
	for c in transmute([]u8)s {
		if c >= '0' && c <= '9' {
			result = result * 10 + int(c - '0')
		}
	}
	return result
}

append_raw :: proc(buf: ^[dynamic]u8, data: []u8) {
	for b in data do append(buf, b)
}

append_u32 :: proc(buf: ^[dynamic]u8, val: u32) {
	b: [4]u8
	endian.put_u32(b[:], .Little, val)
	for x in b do append(buf, x)
}

append_str8 :: proc(buf: ^[dynamic]u8, s: string) {
	append(buf, u8(min(len(s), STR8_MAX_LEN)))
	for i in 0 ..< min(len(s), STR8_MAX_LEN) do append(buf, s[i])
}

read_raw :: proc(data: []u8, pos: ^int, out: []u8) -> bool {
	if pos^ + len(out) > len(data) do return false
	copy(out, data[pos^:pos^ + len(out)])
	pos^ += len(out)
	return true
}

read_u32 :: proc(data: []u8, pos: ^int) -> (val: u32, ok: bool) {
	if pos^ + 4 > len(data) do return 0, false
	val, ok = endian.get_u32(data[pos^:pos^ + 4], .Little)
	if ok do pos^ += 4
	return val, ok
}

read_blob :: proc(data: []u8, pos: ^int) -> (result: []u8, ok: bool) {
	size := read_u32(data, pos) or_return
	if pos^ + int(size) > len(data) do return nil, false
	result = make([]u8, size, runtime_alloc)
	copy(result, data[pos^:pos^ + int(size)])
	pos^ += int(size)
	return result, true
}

read_str8 :: proc(data: []u8, pos: ^int) -> (result: string, ok: bool) {
	if pos^ >= len(data) do return "", false
	length := int(data[pos^])
	pos^ += 1
	if pos^ + length > len(data) do return "", false
	result = strings.clone(string(data[pos^:pos^ + length]), runtime_alloc)
	pos^ += length
	return result, true
}
