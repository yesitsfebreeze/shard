#+build windows
package shard

import "core:fmt"
import "core:strings"
import win "core:sys/windows"

// =============================================================================
// Windows Named Pipe IPC implementation
// =============================================================================
//
// Path format: \\.\pipe\shard-<name>
//

IPC_Listener :: struct {
	handle: win.HANDLE,
	name:   string,
}

IPC_Conn :: struct {
	handle: win.HANDLE,
}

// Accept result: ok, timed out, or error.
IPC_Accept_Result :: enum {
	Ok,
	Timeout,
	Error,
}

@(private)
_pipe_path :: proc(name: string, allocator := context.allocator) -> win.wstring {
	path := fmt.tprintf(`\\.\pipe\shard-%s`, name)
	return win.utf8_to_wstring(path)
}

@(private)
_create_pipe :: proc(name: string, overlapped: bool) -> win.HANDLE {
	pipe_name := _pipe_path(name, context.temp_allocator)
	flags := win.PIPE_ACCESS_DUPLEX
	if overlapped do flags |= win.FILE_FLAG_OVERLAPPED
	return win.CreateNamedPipeW(
		pipe_name,
		flags,
		win.PIPE_TYPE_BYTE | win.PIPE_READMODE_BYTE | win.PIPE_WAIT,
		255,          // PIPE_UNLIMITED_INSTANCES
		64 * 1024,    // out buffer
		64 * 1024,    // in buffer
		0,            // default timeout
		nil,          // default security
	)
}

// ipc_listen creates a named pipe listener.
ipc_listen :: proc(name: string) -> (IPC_Listener, bool) {
	h := _create_pipe(name, true) // overlapped for timed accept
	if h == win.INVALID_HANDLE_VALUE do return {}, false
	return IPC_Listener{handle = h, name = strings.clone(name)}, true
}

// ipc_accept blocks until a client connects. No timeout.
ipc_accept :: proc(listener: ^IPC_Listener) -> (IPC_Conn, bool) {
	if win.ConnectNamedPipe(listener.handle, nil) == win.FALSE {
		err := win.GetLastError()
		if err != win.ERROR_PIPE_CONNECTED do return {}, false
	}

	conn := IPC_Conn{handle = listener.handle}

	// Create new pipe instance for next client (non-overlapped for data I/O)
	new_h := _create_pipe(listener.name, true)
	if new_h != win.INVALID_HANDLE_VALUE do listener.handle = new_h

	return conn, true
}

// ipc_accept_timed waits up to timeout_ms for a client to connect.
// Returns .Timeout if no client connected in time.
ipc_accept_timed :: proc(listener: ^IPC_Listener, timeout_ms: u32) -> (IPC_Conn, IPC_Accept_Result) {
	ov: win.OVERLAPPED
	ov.hEvent = win.CreateEventW(nil, win.TRUE, win.FALSE, nil) // manual-reset event
	if ov.hEvent == nil do return {}, .Error
	defer win.CloseHandle(ov.hEvent)

	result := win.ConnectNamedPipe(listener.handle, &ov)
	if result != win.FALSE {
		// Connected immediately
		conn := IPC_Conn{handle = listener.handle}
		new_h := _create_pipe(listener.name, true)
		if new_h != win.INVALID_HANDLE_VALUE do listener.handle = new_h
		return conn, .Ok
	}

	err := win.GetLastError()
	switch err {
	case win.ERROR_PIPE_CONNECTED:
		// Client was already connected before ConnectNamedPipe
		conn := IPC_Conn{handle = listener.handle}
		new_h := _create_pipe(listener.name, true)
		if new_h != win.INVALID_HANDLE_VALUE do listener.handle = new_h
		return conn, .Ok

	case win.ERROR_IO_PENDING:
		// Waiting for connection — use WaitForSingleObject with timeout
		wait := win.WaitForSingleObject(ov.hEvent, win.DWORD(timeout_ms))
		switch wait {
		case win.WAIT_OBJECT_0:
			// Connection arrived
			conn := IPC_Conn{handle = listener.handle}
			new_h := _create_pipe(listener.name, true)
			if new_h != win.INVALID_HANDLE_VALUE do listener.handle = new_h
			return conn, .Ok
		case win.WAIT_TIMEOUT:
			// Cancel the pending ConnectNamedPipe
			win.CancelIo(listener.handle)
			return {}, .Timeout
		case:
			win.CancelIo(listener.handle)
			return {}, .Error
		}

	case:
		return {}, .Error
	}
	return {}, .Error
}

// ipc_connect connects to an existing named pipe (client side).
// Retries up to 5 times with 500ms waits to handle daemon startup race.
ipc_connect :: proc(name: string) -> (IPC_Conn, bool) {
	pipe_name := _pipe_path(name, context.temp_allocator)
	MAX_RETRIES :: 5
	for attempt in 0 ..< MAX_RETRIES {
		h := win.CreateFileW(
			pipe_name,
			win.GENERIC_READ | win.GENERIC_WRITE,
			0,
			nil,
			win.OPEN_EXISTING,
			0,
			nil,
		)
		if h != win.INVALID_HANDLE_VALUE do return IPC_Conn{handle = h}, true

		err := win.GetLastError()
		if err == win.ERROR_PIPE_BUSY {
			// Pipe exists but all instances are busy — wait for availability
			win.WaitNamedPipeW(pipe_name, 2000)
		} else {
			// Pipe doesn't exist yet (daemon still starting) — sleep and retry
			if attempt < MAX_RETRIES - 1 do win.Sleep(500)
		}
	}
	return {}, false
}

// ipc_send writes data to the connection.
ipc_send :: proc(conn: IPC_Conn, data: []u8) -> bool {
	total: u32 = 0
	for total < u32(len(data)) {
		written: win.DWORD
		ok := win.WriteFile(conn.handle, raw_data(data[total:]), win.DWORD(len(data) - int(total)), &written, nil)
		if ok == win.FALSE do return false
		total += u32(written)
	}
	return true
}

// ipc_recv reads available data from the connection.
ipc_recv :: proc(conn: IPC_Conn, buf: []u8) -> (int, bool) {
	read: win.DWORD
	ok := win.ReadFile(conn.handle, raw_data(buf), win.DWORD(len(buf)), &read, nil)
	if ok == win.FALSE do return 0, false
	return int(read), true
}

// ipc_close_conn closes a connection handle.
ipc_close_conn :: proc(conn: IPC_Conn) {
	win.FlushFileBuffers(conn.handle)
	win.DisconnectNamedPipe(conn.handle)
	win.CloseHandle(conn.handle)
}

// ipc_close_listener closes the listener pipe handle.
ipc_close_listener :: proc(listener: ^IPC_Listener) {
	win.CloseHandle(listener.handle)
	delete(listener.name)
}
