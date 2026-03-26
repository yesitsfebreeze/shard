package shard

import "protocol"

ipc_socket_path :: proc(shard_id: string) -> string {
	return protocol.socket_path(shard_id, runtime_alloc)
}

ipc_listen :: proc(shard_id: string) -> (IPC_Listener, bool) {
	listener, ok := protocol.listen(shard_id, LISTEN_BACKLOG, runtime_alloc)
	if !ok do return {}, false
	return IPC_Listener{fd = listener.fd, path = listener.path}, true
}

ipc_connect :: proc(sock_path: string) -> (IPC_Conn, bool) {
	conn, ok := protocol.connect(sock_path)
	if !ok do return {}, false
	return IPC_Conn{fd = conn.fd}, true
}

ipc_close_listener :: proc(listener: ^IPC_Listener) {
	p := protocol.Listener {
		fd   = listener.fd,
		path = listener.path,
	}
	protocol.close_listener(&p)
}

ipc_accept_timed :: proc(listener: ^IPC_Listener, timeout_ms: i32) -> (IPC_Conn, IPC_Result) {
	p := protocol.Listener {
		fd   = listener.fd,
		path = listener.path,
	}
	conn, result := protocol.accept_timed(&p, timeout_ms)
	if !(result == .Ok) {
		if result == .Timeout {return {}, .Timeout}
		return {}, .Error
	}
	return IPC_Conn{fd = conn.fd}, .Ok
}

ipc_close :: proc(conn: IPC_Conn) {
	protocol.close(protocol.Conn{fd = conn.fd})
}

ipc_send :: proc(conn: IPC_Conn, data: []u8) -> bool {
	return protocol.send(protocol.Conn{fd = conn.fd}, data)
}

ipc_recv_exact :: proc(conn: IPC_Conn, buf: []u8) -> bool {
	return protocol.recv_exact(protocol.Conn{fd = conn.fd}, buf)
}

ipc_send_msg :: proc(conn: IPC_Conn, data: []u8) -> bool {
	return protocol.send_msg(protocol.Conn{fd = conn.fd}, data, runtime_alloc)
}

ipc_recv_msg :: proc(conn: IPC_Conn) -> ([]u8, bool) {
	buf, ok := protocol.recv_msg(protocol.Conn{fd = conn.fd}, runtime_alloc)
	return buf, ok
}
