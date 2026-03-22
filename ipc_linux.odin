#+build linux
package shard

import "core:c"
import "core:encoding/endian"
import "core:fmt"
import "core:strings"
import "core:sys/posix"

IPC_Listener :: struct {
	fd:   posix.FD,
	path: string,
}

IPC_Conn :: struct {
	fd: posix.FD,
}

ipc_socket_path :: proc(shard_id: string) -> string {
	return fmt.aprintf("/tmp/shard-%s.sock", shard_id, allocator = runtime_alloc)
}

ipc_listen :: proc(shard_id: string) -> (IPC_Listener, bool) {
	sock_path := ipc_socket_path(shard_id)
	path_cstr := strings.clone_to_cstring(sock_path, runtime_alloc)
	posix.unlink(path_cstr)

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

	if posix.listen(fd, 16) != .OK {
		posix.close(fd)
		posix.unlink(path_cstr)
		return {}, false
	}

	return IPC_Listener{fd = fd, path = sock_path}, true
}

ipc_close_listener :: proc(listener: ^IPC_Listener) {
	posix.close(listener.fd)
	path_cstr := strings.clone_to_cstring(listener.path, runtime_alloc)
	posix.unlink(path_cstr)
}

ipc_accept_timed :: proc(listener: ^IPC_Listener, timeout_ms: i32) -> (IPC_Conn, IPC_Result) {
	pfd: posix.pollfd
	pfd.fd = listener.fd
	pfd.events = {.IN}

	n := posix.poll(&pfd, 1, c.int(timeout_ms))
	if n == 0 do return {}, .Timeout
	if n < 0 do return {}, .Error

	client_fd := posix.accept(listener.fd, nil, nil)
	if client_fd == -1 do return {}, .Error
	return IPC_Conn{fd = client_fd}, .Ok
}

ipc_close :: proc(conn: IPC_Conn) {
	posix.close(conn.fd)
}

ipc_send :: proc(conn: IPC_Conn, data: []u8) -> bool {
	total: uint = 0
	for total < len(data) {
		n := posix.send(conn.fd, raw_data(data[total:]), len(data) - total, {})
		if n <= 0 do return false
		total += uint(n)
	}
	return true
}

ipc_recv_exact :: proc(conn: IPC_Conn, buf: []u8) -> bool {
	total: uint = 0
	for total < len(buf) {
		n := posix.recv(conn.fd, raw_data(buf[total:]), len(buf) - total, {})
		if n <= 0 do return false
		total += uint(n)
	}
	return true
}

ipc_send_msg :: proc(conn: IPC_Conn, data: []u8) -> bool {
	if len(data) > MSG_MAX_SIZE do return false
	header: [4]u8
	endian.put_u32(header[:], .Little, u32(len(data)))
	if !ipc_send(conn, header[:]) do return false
	return len(data) == 0 || ipc_send(conn, data)
}

ipc_recv_msg :: proc(conn: IPC_Conn) -> ([]u8, bool) {
	header: [4]u8
	if !ipc_recv_exact(conn, header[:]) do return nil, false
	size_val, size_ok := endian.get_u32(header[:], .Little)
	if !size_ok do return nil, false
	size := int(size_val)
	if size <= 0 || size > MSG_MAX_SIZE do return nil, false
	buf := make([]u8, size, runtime_alloc)
	if !ipc_recv_exact(conn, buf) do return nil, false
	return buf, true
}
