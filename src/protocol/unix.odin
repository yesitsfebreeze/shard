package protocol

import "core:fmt"
import "core:c"
import "core:mem"
import "core:os"
import "core:sys/posix"

MSG_MAX_SIZE :: 16 * 1024 * 1024

Listener :: struct {
	fd:   posix.FD,
	path: string,
}

Conn :: struct {
	fd: posix.FD,
}

Result :: enum {
	Ok,
	Timeout,
	Error,
}

socket_path :: proc(shard_id: string, allocator: mem.Allocator) -> string {
	return fmt.aprintf("/tmp/shard-%s.sock", shard_id, allocator = allocator)
}

listen :: proc(shard_id: string, backlog: int, allocator: mem.Allocator) -> (Listener, bool) {
	sock_path := socket_path(shard_id, allocator)
	os.remove(sock_path)

	fd := posix.socket(.UNIX, .STREAM)
	if fd == -1 do return {}, false

	addr: posix.sockaddr_un
	addr.sun_family = .UNIX
	path_bytes := transmute([]u8)sock_path
	for i in 0 ..< min(len(path_bytes), len(addr.sun_path) - 1) {
		addr.sun_path[i] = path_bytes[i]
	}

	if posix.bind(fd, cast(^posix.sockaddr)&addr, size_of(addr)) != .OK {
		posix.close(fd)
		return {}, false
	}

	if posix.listen(fd, c.int(backlog)) != .OK {
		posix.close(fd)
		os.remove(sock_path)
		return {}, false
	}

	return Listener{fd = fd, path = sock_path}, true
}

connect :: proc(sock_path: string) -> (Conn, bool) {
	fd := posix.socket(.UNIX, .STREAM)
	if fd == -1 do return {}, false

	addr: posix.sockaddr_un
	addr.sun_family = .UNIX
	path_bytes := transmute([]u8)sock_path
	for i in 0 ..< min(len(path_bytes), len(addr.sun_path) - 1) {
		addr.sun_path[i] = path_bytes[i]
	}

	if posix.connect(fd, cast(^posix.sockaddr)&addr, size_of(addr)) != .OK {
		posix.close(fd)
		return {}, false
	}

	return Conn{fd = fd}, true
}

close_listener :: proc(listener: ^Listener) {
	posix.close(listener.fd)
	path := listener.path
	os.remove(path)
}

accept_timed :: proc(listener: ^Listener, timeout_ms: i32) -> (Conn, Result) {
	pfd: posix.pollfd
	pfd.fd = listener.fd
	pfd.events = {.IN}

	n := posix.poll(&pfd, 1, timeout_ms)
	if n == 0 do return {}, .Timeout
	if n < 0 do return {}, .Error

	client_fd := posix.accept(listener.fd, nil, nil)
	if client_fd == -1 do return {}, .Error
	return Conn{fd = client_fd}, .Ok
}

close :: proc(conn: Conn) {
	posix.close(conn.fd)
}

send :: proc(conn: Conn, data: []u8) -> bool {
	total: uint = 0
	for total < len(data) {
		n := posix.send(conn.fd, raw_data(data[total:]), len(data) - total, {})
		if n <= 0 do return false
		total += uint(n)
	}
	return true
}

recv_exact :: proc(conn: Conn, buf: []u8) -> bool {
	total: uint = 0
	for total < len(buf) {
		n := posix.recv(conn.fd, raw_data(buf[total:]), len(buf) - total, {})
		if n <= 0 do return false
		total += uint(n)
	}
	return true
}

send_msg :: proc(conn: Conn, data: []u8, allocator: mem.Allocator) -> bool {
	if len(data) > MSG_MAX_SIZE do return false
	header: [4]u8
	append_u32_to_header :: proc(buf: ^[4]u8, size: u32) {
		buf[0] = u8(size & 0xff)
		buf[1] = u8((size >> 8) & 0xff)
		buf[2] = u8((size >> 16) & 0xff)
		buf[3] = u8((size >> 24) & 0xff)
	}
	append_u32_to_header(&header, u32(len(data)))
	if !send(conn, header[:]) do return false
	return len(data) == 0 || send(conn, data)
}

recv_msg :: proc(conn: Conn, allocator: mem.Allocator) -> ([]u8, bool) {
	header: [4]u8
	if !recv_exact(conn, header[:]) do return nil, false
	size: u32
	size |= u32(header[0])
	size |= u32(header[1]) << 8
	size |= u32(header[2]) << 16
	size |= u32(header[3]) << 24

	if size <= 0 || size > MSG_MAX_SIZE do return nil, false
	buf := make([]u8, size, allocator)
	if !recv_exact(conn, buf) do return nil, false
	return buf, true
}
