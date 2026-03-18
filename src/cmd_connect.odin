package shard

import "core:fmt"
import "core:os"
import "core:strings"

// =============================================================================
// shard connect — session client, streams JSON ops from stdin over IPC
// =============================================================================

@(private)
_run_connect :: proc() {
	name := "daemon"

	args := os.args[2:]
	for i := 0; i < len(args); i += 1 {
		if args[i] == "--help" || args[i] == "-h" {
			_print_help(HELP_CONNECT)
			return
		} else if args[i] == "--ai" {
			_print_help(HELP_AI_CONNECT)
			return
		} else {
			name = args[i]
		}
	}

	conn, ok := ipc_connect(name)
	if !ok {
		fmt.eprintfln("could not connect to '%s' (is the daemon running? try: shard daemon)", name)
		os.exit(1)
	}
	defer ipc_close_conn(conn)

	// Read raw JSON from stdin and stream each line as a request.
	// Each line should be a complete JSON message.
	buf: [65536]u8
	for {
		n, err := os.read(os.stdin, buf[:])
		if err != nil || n <= 0 do break

		chunk := string(buf[:n])
		lines := strings.split(chunk, "\n", context.temp_allocator)

		for line in lines {
			trimmed := strings.trim_right(line, "\r")
			if strings.trim_space(trimmed) == "" do continue
			if !_send_recv_json(conn, trimmed) do return
		}
	}
}

// _send_recv_json sends a raw JSON string to the daemon and prints the response.
@(private)
_send_recv_json :: proc(conn: IPC_Conn, msg: string) -> bool {
	data := transmute([]u8)msg
	if !ipc_send_msg(conn, data) {
		fmt.eprintln("send failed — connection lost")
		return false
	}
	resp, recv_ok := ipc_recv_msg(conn)
	if !recv_ok {
		fmt.eprintln("recv failed — connection lost")
		return false
	}
	fmt.print(string(resp))
	resp_str := string(resp)
	if len(resp_str) > 0 && resp_str[len(resp_str) - 1] != '\n' {
		fmt.println()
	}
	delete(resp)
	return true
}

// _notify_daemon_discover tells a running daemon to re-scan .shards/.
// Fails silently if the daemon isn't running.
@(private)
_notify_daemon_discover :: proc() {
	conn, ok := ipc_connect(DAEMON_NAME)
	if !ok do return
	defer ipc_close_conn(conn)

	msg := "---\nop: discover\n---\n"
	if !ipc_send_msg(conn, transmute([]u8)msg) do return

	// Read and discard response
	resp, _ := ipc_recv_msg(conn, context.temp_allocator)
	delete(resp, context.temp_allocator)

	fmt.eprintln("Daemon notified — shard is now discoverable.")
}

// _prompt prints a prompt and reads a line from stdin.
@(private)
_prompt :: proc(prompt: string) -> string {
	fmt.print(prompt)
	buf: [4096]u8
	n, err := os.read(os.stdin, buf[:])
	if err != nil || n <= 0 do return ""
	// Strip trailing newline / carriage return
	line := string(buf[:n])
	line = strings.trim_right(line, "\r\n")
	return strings.clone(line)
}
