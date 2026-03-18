package shard

import "core:fmt"
import "core:os"
import "core:strings"

// =============================================================================
// shard connect — session client, streams ops from stdin over IPC
// =============================================================================

@(private)
_run_connect :: proc() {
	name := "daemon"

	args := os.args[2:]
	for i := 0; i < len(args); i += 1 {
		if args[i] == "--help" || args[i] == "-h" {
			_print_help(HELP_CONNECT)
			return
		} else if args[i] == "--ai-help" {
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

	// State machine for parsing YAML frontmatter messages from stdin
	Connect_State :: enum {
		Waiting,
		In_Front,
		In_Body,
	}

	buf: [65536]u8
	state := Connect_State.Waiting
	msg_builder := strings.builder_make()
	defer strings.builder_destroy(&msg_builder)

	for {
		n, err := os.read(os.stdin, buf[:])
		if err != nil || n <= 0 do break

		chunk := string(buf[:n])
		lines := strings.split(chunk, "\n", context.temp_allocator)

		for line in lines {
			trimmed := strings.trim_right(line, "\r")

			switch state {
			case .Waiting:
				if strings.trim_space(trimmed) == "---" {
					strings.write_string(&msg_builder, "---\n")
					state = .In_Front
				}
			case .In_Front:
				if strings.trim_space(trimmed) == "---" {
					strings.write_string(&msg_builder, "---\n")
					state = .In_Body
				} else {
					strings.write_string(&msg_builder, trimmed)
					strings.write_string(&msg_builder, "\n")
				}
			case .In_Body:
				if strings.trim_space(trimmed) == "---" {
					if !_flush_msg(conn, &msg_builder) do return
					strings.write_string(&msg_builder, "---\n")
					state = .In_Front
				} else {
					strings.write_string(&msg_builder, trimmed)
					strings.write_string(&msg_builder, "\n")
				}
			}
		}
	}

	// EOF — flush any pending message
	if state == .In_Body {
		_flush_msg(conn, &msg_builder)
	}
}

@(private)
_flush_msg :: proc(conn: IPC_Conn, b: ^strings.Builder) -> bool {
	msg := strings.to_string(b^)
	if strings.trim_space(msg) == "" {
		strings.builder_reset(b)
		return true
	}
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
	strings.builder_reset(b)
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
