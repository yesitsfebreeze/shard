#+build linux, darwin, freebsd, openbsd, netbsd
package shard

import "core:c"
import "core:fmt"
import "core:sys/posix"

// =============================================================================
// HTTP server — POSIX TCP implementation
// =============================================================================
//
// Exposes the same interface as http_server_windows.odin so mcp_http.odin
// compiles on all platforms without conditional code.
//
// Mirrors the style of ipc_posix.odin (Unix domain sockets) but uses
// AF_INET TCP instead of AF_UNIX.
//

HTTP_Listener :: struct {
	fd: posix.FD,
}

HTTP_Conn :: struct {
	fd: posix.FD,
}

// http_listen binds a TCP socket on host:port and starts listening.
// host is a dotted-decimal IPv4 string (e.g. "127.0.0.1" or "0.0.0.0").
http_listen :: proc(host: string, port: int) -> (HTTP_Listener, bool) {
	// Protocol defaults to .IP (0) — explicit cast avoids untyped-int error
	fd := posix.socket(.INET, .STREAM, posix.Protocol.IP)
	if fd == -1 do return {}, false

	// Allow fast restart after crash
	one: c.int = 1
	posix.setsockopt(fd, posix.SOL_SOCKET, .REUSEADDR, &one, size_of(one))

	addr: posix.sockaddr_in
	addr.sin_family = .INET
	addr.sin_port   = posix.in_port_t(port) // in_port_t is u16be — direct assignment
	posix.inet_pton(.INET, fmt.ctprintf("%s", host), &addr.sin_addr)

	if posix.bind(fd, cast(^posix.sockaddr)&addr, size_of(addr)) != nil {
		posix.close(fd)
		return {}, false
	}
	if posix.listen(fd, 128) != nil {
		posix.close(fd)
		return {}, false
	}
	infof("http: listening on %s:%d", host, port)
	return HTTP_Listener{fd = fd}, true
}

// http_accept blocks until a client connects.
http_accept :: proc(listener: ^HTTP_Listener) -> (HTTP_Conn, bool) {
	client_fd := posix.accept(listener.fd, nil, nil)
	if client_fd == -1 do return {}, false
	return HTTP_Conn{fd = client_fd}, true
}

// http_send writes all of data to the connection.
http_send :: proc(conn: HTTP_Conn, data: []u8) -> bool {
	total := 0
	for total < len(data) {
		n := posix.send(conn.fd, raw_data(data[total:]), uint(len(data)) - uint(total), {})
		if n <= 0 do return false
		total += int(n)
	}
	return true
}

// http_recv reads available bytes into buf.
http_recv :: proc(conn: HTTP_Conn, buf: []u8) -> (int, bool) {
	n := posix.recv(conn.fd, raw_data(buf), uint(len(buf)), {})
	if n <= 0 do return 0, false
	return int(n), true
}

// http_close_conn shuts down and closes a client connection.
http_close_conn :: proc(conn: HTTP_Conn) {
	posix.shutdown(conn.fd, .RDWR)
	posix.close(conn.fd)
}

// http_close_listener closes the listening socket.
http_close_listener :: proc(listener: ^HTTP_Listener) {
	posix.close(listener.fd)
}
