package shard

// =============================================================================
// IPC abstraction layer
// =============================================================================
//
// Platform-neutral interface for local IPC.
// Windows: Named Pipes (\\.\pipe\shard-<name>)
// POSIX:   Unix domain sockets (/tmp/shard-<name>.sock)
//
// Actual implementations are in ipc_windows.odin and ipc_posix.odin,
// selected at compile time via `when ODIN_OS == ...` guards.
//

// Length-prefixed message framing: [u32 LE: payload_length][payload bytes]

MSG_MAX_SIZE :: 16 * 1024 * 1024 // 16 MiB max message

// ipc_send_msg sends a length-prefixed message.
ipc_send_msg :: proc(conn: IPC_Conn, data: []u8) -> bool {
	if len(data) > MSG_MAX_SIZE do return false
	header: [4]u8
	_put_u32(header[:], u32(len(data)))
	if !ipc_send(conn, header[:]) do return false
	if len(data) > 0 {
		if !ipc_send(conn, data) do return false
	}
	return true
}

// ipc_recv_msg receives a length-prefixed message.
ipc_recv_msg :: proc(conn: IPC_Conn, allocator := context.allocator) -> ([]u8, bool) {
	header: [4]u8
	if !_ipc_recv_exact(conn, header[:]) do return nil, false
	size := int(_u32_le(header[:]))
	if size <= 0 || size > MSG_MAX_SIZE do return nil, false
	buf := make([]u8, size, allocator)
	if !_ipc_recv_exact(conn, buf) {
		delete(buf, allocator)
		return nil, false
	}
	return buf, true
}

// _ipc_recv_exact reads exactly len(buf) bytes from conn.
@(private)
_ipc_recv_exact :: proc(conn: IPC_Conn, buf: []u8) -> bool {
	total := 0
	for total < len(buf) {
		n, ok := ipc_recv(conn, buf[total:])
		if !ok || n <= 0 do return false
		total += n
	}
	return true
}
