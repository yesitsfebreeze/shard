#+build !linux
package shard

IPC_Listener :: struct {
	fd:   i32,
	path: string,
}

IPC_Conn :: struct {
	fd: i32,
}

ipc_socket_path :: proc(shard_id: string) -> string { return "" }
ipc_listen :: proc(shard_id: string) -> (IPC_Listener, bool) { return {}, false }
ipc_close_listener :: proc(listener: ^IPC_Listener) {}
ipc_accept_timed :: proc(listener: ^IPC_Listener, timeout_ms: i32) -> (IPC_Conn, IPC_Result) { return {}, .Error }
ipc_close :: proc(conn: IPC_Conn) {}
ipc_send :: proc(conn: IPC_Conn, data: []u8) -> bool { return false }
ipc_recv_exact :: proc(conn: IPC_Conn, buf: []u8) -> bool { return false }
ipc_send_msg :: proc(conn: IPC_Conn, data: []u8) -> bool { return false }
ipc_recv_msg :: proc(conn: IPC_Conn) -> ([]u8, bool) { return nil, false }
