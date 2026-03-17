#+build linux, darwin, freebsd, openbsd, netbsd
package shard

import "core:c"
import "core:fmt"
import "core:strings"
import "core:sys/posix"

// =============================================================================
// POSIX Unix Domain Socket IPC implementation
// =============================================================================
//
// Path format: /tmp/shard-<name>.sock
//

IPC_Listener :: struct {
	fd:   posix.FD,
	path: string,
	name: string,
}

IPC_Conn :: struct {
	fd: posix.FD,
}

// Accept result: ok, timed out, or error.
IPC_Accept_Result :: enum {
	Ok,
	Timeout,
	Error,
}

@(private)
_socket_path :: proc(name: string, allocator := context.allocator) -> string {
	return fmt.tprintf("/tmp/shard-%s.sock", name)
}

// ipc_listen creates a unix domain socket and starts listening.
ipc_listen :: proc(name: string) -> (IPC_Listener, bool) {
	sock_path := _socket_path(name)

	path_cstr := strings.clone_to_cstring(sock_path, context.temp_allocator)
	posix.unlink(path_cstr)

	fd := posix.socket(.UNIX, .STREAM)
	if fd == -1 do return {}, false

	addr: posix.sockaddr_un
	addr.sun_family = .UNIX
	path_bytes := transmute([]u8)sock_path
	for i in 0 ..< min(len(path_bytes), len(addr.sun_path) - 1) {
		addr.sun_path[i] = u8(path_bytes[i])
	}

	if posix.bind(fd, cast(^posix.sockaddr)&addr, size_of(addr)) == -1 {
		posix.close(fd)
		return {}, false
	}

	if posix.listen(fd, 16) == -1 {
		posix.close(fd)
		posix.unlink(path_cstr)
		return {}, false
	}

	return IPC_Listener{fd = fd, path = strings.clone(sock_path), name = strings.clone(name)}, true
}

// ipc_accept blocks until a client connects. No timeout.
ipc_accept :: proc(listener: ^IPC_Listener) -> (IPC_Conn, bool) {
	client_fd := posix.accept(listener.fd, nil, nil)
	if client_fd == -1 do return {}, false
	return IPC_Conn{fd = client_fd}, true
}

// ipc_accept_timed waits up to timeout_ms for a client to connect.
// Returns .Timeout if no client connected in time.
ipc_accept_timed :: proc(
	listener: ^IPC_Listener,
	timeout_ms: u32,
) -> (
	IPC_Conn,
	IPC_Accept_Result,
) {
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

// ipc_connect connects to an existing unix domain socket (client side).
ipc_connect :: proc(name: string) -> (IPC_Conn, bool) {
	sock_path := _socket_path(name)

	fd := posix.socket(.UNIX, .STREAM)
	if fd == -1 do return {}, false

	addr: posix.sockaddr_un
	addr.sun_family = .UNIX
	path_bytes := transmute([]u8)sock_path
	for i in 0 ..< min(len(path_bytes), len(addr.sun_path) - 1) {
		addr.sun_path[i] = u8(path_bytes[i])
	}

	if posix.connect(fd, cast(^posix.sockaddr)&addr, size_of(addr)) == -1 {
		posix.close(fd)
		return {}, false
	}

	return IPC_Conn{fd = fd}, true
}

// ipc_send writes data to the connection.
ipc_send :: proc(conn: IPC_Conn, data: []u8) -> bool {
	total := 0
	for total < len(data) {
		n := posix.send(conn.fd, raw_data(data[total:]), uint(len(data) - uint(total)), {.NONE})
		if n <= 0 do return false
		total += int(n)
	}
	return true
}

// ipc_recv reads available data from the connection.
ipc_recv :: proc(conn: IPC_Conn, buf: []u8) -> (int, bool) {
	n := posix.recv(conn.fd, raw_data(buf), uint(len(buf)), {.NONE})
	if n <= 0 do return 0, false
	return int(n), true
}

// ipc_close_conn closes a connection.
ipc_close_conn :: proc(conn: IPC_Conn) {
	posix.close(conn.fd)
}

// ipc_close_listener closes the listener and removes the socket file.
ipc_close_listener :: proc(listener: ^IPC_Listener) {
	posix.close(listener.fd)
	path_cstr := strings.clone_to_cstring(listener.path, context.temp_allocator)
	posix.unlink(path_cstr)
	delete(listener.path)
	delete(listener.name)
}
