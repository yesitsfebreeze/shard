package shard

import "core:encoding/json"
import "core:fmt"
import "core:strings"

// =============================================================================
// JSON accessors — typed helpers for json.Object key lookups
// =============================================================================

md_json_get_str :: proc(obj: json.Object, key: string, allocator := context.allocator) -> string {
	if val, ok := obj[key]; ok {
		#partial switch v in val {
		case string:
			if v == "" do return ""
			return strings.clone(v, allocator)
		}
	}
	return ""
}

md_json_get_int :: proc(obj: json.Object, key: string) -> int {
	if val, ok := obj[key]; ok {
		#partial switch v in val {
		case i64:
			return int(v)
		case f64:
			return int(v)
		}
	}
	return 0
}

md_json_get_f64 :: proc(obj: json.Object, key: string) -> f64 {
	if val, ok := obj[key]; ok {
		#partial switch v in val {
		case f64:
			return v
		case i64:
			return f64(v)
		}
	}
	return 0.0
}

md_json_get_bool :: proc(obj: json.Object, key: string) -> (bool, bool) {
	if val, ok := obj[key]; ok {
		#partial switch v in val {
		case bool:
			return v, true
		}
	}
	return false, false
}

md_json_get_obj :: proc(obj: json.Object, key: string) -> (json.Object, bool) {
	if val, ok := obj[key]; ok {
		#partial switch v in val {
		case json.Object:
			return v, true
		}
	}
	return {}, false
}

md_json_get_str_array :: proc(
	obj: json.Object,
	key: string,
	allocator := context.allocator,
) -> []string {
	if val, ok := obj[key]; ok {
		#partial switch v in val {
		case json.Array:
			result := make([]string, len(v), allocator)
			count := 0
			for item in v {
				#partial switch s in item {
				case string:
					result[count] = strings.clone(s, allocator)
					count += 1
				}
			}
			return result[:count]
		}
	}
	return nil
}

md_json_str_array_to_json :: proc(arr: []string, allocator := context.allocator) -> json.Array {
	if arr == nil || len(arr) == 0 do return nil
	result := make(json.Array, len(arr), allocator)
	for s, i in arr {
		result[i] = s
	}
	return result
}

// md_json_get_float is the (f64, bool) variant — bool means "key was present".
// Use md_json_get_f64 when absence and zero are equivalent; use this when they differ.
md_json_get_float :: proc(obj: json.Object, key: string) -> (f64, bool) {
	val, ok := obj[key]
	if !ok do return 0, false
	#partial switch v in val {
	case f64:
		return v, true
	case i64:
		return f64(v), true
	}
	return 0, false
}

// =============================================================================
// JSON output helpers — writing JSON fields and escaped strings
// =============================================================================

// write_json_value writes a json.Value as a JSON literal to a strings.Builder.
write_json_value :: proc(b: ^strings.Builder, val: json.Value) {
	#partial switch v in val {
	case i64:
		fmt.sbprintf(b, "%d", v)
	case f64:
		fmt.sbprintf(b, "%v", v)
	case string:
		strings.write_string(b, `"`)
		strings.write_string(b, json_escape(v))
		strings.write_string(b, `"`)
	case:
		strings.write_string(b, "null")
	}
}

write_json_field :: proc(b: ^strings.Builder, key: string, value: string) {
	strings.write_string(b, `"`)
	strings.write_string(b, key)
	strings.write_string(b, `":"`)
	json_escape_to(b, value)
	strings.write_string(b, `"`)
}

write_json_array :: proc(b: ^strings.Builder, items: []string) {
	strings.write_string(b, "[")
	for s, i in items {
		if i > 0 do strings.write_string(b, ",")
		strings.write_string(b, `"`)
		json_escape_to(b, s)
		strings.write_string(b, `"`)
	}
	strings.write_string(b, "]")
}

json_escape_to :: proc(b: ^strings.Builder, s: string) {
	for ch in s {
		switch ch {
		case '"':
			strings.write_string(b, `\"`)
		case '\\':
			strings.write_string(b, `\\`)
		case '\n':
			strings.write_string(b, `\n`)
		case '\r':
			strings.write_string(b, `\r`)
		case '\t':
			strings.write_string(b, `\t`)
		case:
			strings.write_rune(b, ch)
		}
	}
}

// json_escape returns a JSON-escaped string (convenience wrapper around json_escape_to)
json_escape :: proc(s: string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	json_escape_to(&b, s)
	return strings.to_string(b)
}
