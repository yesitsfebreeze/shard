#+build windows
package shard

import "core:c"
import "core:net"
import win "core:sys/windows"

// =============================================================================
// HTTP server — Windows Winsock TCP implementation
// =============================================================================
//
// Exposes the same interface as http_server_posix.odin so mcp_http.odin
// compiles on all platforms without conditional code.
//
// Mirrors the style of ipc_windows.odin (named pipes) but uses TCP sockets.
//

HTTP_Listener :: struct {
	socket: win.SOCKET,
}

HTTP_Conn :: struct {
	socket: win.SOCKET,
}

// http_listen binds a TCP socket on host:port and starts listening.
// host is a dotted-decimal IPv4 string (e.g. "127.0.0.1" or "0.0.0.0").
http_listen :: proc(host: string, port: int) -> (HTTP_Listener, bool) {
	wsa: win.WSADATA
	if win.WSAStartup(0x0202, &wsa) != 0 do return {}, false

	sock := win.socket(win.AF_INET, win.SOCK_STREAM, win.IPPROTO_TCP)
	if sock == win.INVALID_SOCKET {
		win.WSACleanup()
		return {}, false
	}

	// Allow fast restart after crash
	one: c.int = 1
	win.setsockopt(sock, win.SOL_SOCKET, win.SO_REUSEADDR, cast(^u8)&one, size_of(one))

	// Parse IPv4 address string → 4 bytes → network-order u32
	ip4, ip_ok := net.parse_ip4_address(host)
	if !ip_ok {
		win.closesocket(sock)
		win.WSACleanup()
		return {}, false
	}
	// IP4_Address is [4]u8; pack into big-endian u32 for sin_addr.s_addr
	s_addr := u32(ip4[0]) | (u32(ip4[1]) << 8) | (u32(ip4[2]) << 16) | (u32(ip4[3]) << 24)

	addr: win.sockaddr_in
	addr.sin_family    = win.ADDRESS_FAMILY(win.AF_INET)
	addr.sin_port      = u16be(port) // u16be handles network byte order
	addr.sin_addr.s_addr = s_addr

	// bind/accept take ^SOCKADDR_STORAGE_LH in Odin's Windows bindings
	addr_storage := cast(^win.SOCKADDR_STORAGE_LH)&addr
	if win.bind(sock, addr_storage, win.socklen_t(size_of(addr))) != 0 {
		win.closesocket(sock)
		win.WSACleanup()
		return {}, false
	}
	if win.listen(sock, 128) != 0 {
		win.closesocket(sock)
		win.WSACleanup()
		return {}, false
	}
	infof("http: listening on %s:%d", host, port)
	return HTTP_Listener{socket = sock}, true
}

// http_accept blocks until a client connects.
http_accept :: proc(listener: ^HTTP_Listener) -> (HTTP_Conn, bool) {
	client := win.accept(listener.socket, nil, nil)
	if client == win.INVALID_SOCKET do return {}, false
	return HTTP_Conn{socket = client}, true
}

// http_send writes all of data to the connection.
http_send :: proc(conn: HTTP_Conn, data: []u8) -> bool {
	total: int = 0
	for total < len(data) {
		n := win.send(conn.socket, cast(^u8)raw_data(data[total:]), c.int(len(data) - total), 0)
		if n == win.SOCKET_ERROR do return false
		total += int(n)
	}
	return true
}

// http_recv reads available bytes into buf.
http_recv :: proc(conn: HTTP_Conn, buf: []u8) -> (int, bool) {
	n := win.recv(conn.socket, cast(^u8)raw_data(buf), c.int(len(buf)), 0)
	if n <= 0 do return 0, false
	return int(n), true
}

// http_close_conn shuts down and closes a client connection.
http_close_conn :: proc(conn: HTTP_Conn) {
	win.shutdown(conn.socket, win.SD_BOTH)
	win.closesocket(conn.socket)
}

// http_close_listener closes the listening socket and cleans up Winsock.
http_close_listener :: proc(listener: ^HTTP_Listener) {
	win.closesocket(listener.socket)
	win.WSACleanup()
}
