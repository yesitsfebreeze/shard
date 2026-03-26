package shard

import "core:encoding/endian"

block_read_u32 :: proc(data: []u8, pos: int) -> (u32, bool) {
	if pos + 4 > len(data) do return 0, false
	return endian.get_u32(data[pos:pos + 4], .Little)
}

block_read_bytes :: proc(data: []u8, pos: int) -> ([]u8, int, bool) {
	size, ok := block_read_u32(data, pos)
	if !ok do return nil, pos, false
	start := pos + 4
	end := start + int(size)
	if end > len(data) do return nil, pos, false
	return data[start:end], end, true
}

block_read_thoughts :: proc(data: []u8, pos: int) -> ([][]u8, int, bool) {
	count, ok := block_read_u32(data, pos)
	if !ok do return nil, pos, false

	cursor := pos + 4
	thoughts := make([][]u8, count, runtime_alloc)
	for i in 0 ..< int(count) {
		blob: []u8
		blob, cursor, ok = block_read_bytes(data, cursor)
		if !ok do return nil, pos, false
		thoughts[i] = blob
	}
	return thoughts, cursor, true
}

block_write_u32 :: proc(buf: []u8, pos: int, val: u32) -> int {
	endian.put_u32(buf[pos:], .Little, val)
	return pos + 4
}

block_write_bytes :: proc(buf: []u8, pos: int, data: []u8) -> int {
	p := block_write_u32(buf, pos, u32(len(data)))
	copy(buf[p:], data)
	return p + len(data)
}

block_write_thoughts :: proc(buf: []u8, pos: int, thoughts: [][]u8) -> int {
	p := block_write_u32(buf, pos, u32(len(thoughts)))
	for t in thoughts do p = block_write_bytes(buf, p, t)
	return p
}
