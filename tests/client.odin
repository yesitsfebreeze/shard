package tests

import shard "../src"
import "core:fmt"
import "core:os"
import "core:strings"

// Shard client: connects to a shard node and streams ops over a persistent connection.
//
// Usage:
//   client <name>                    Session mode (default): read ops from stdin
//   client <name> <op> [op ...]      One-shot: send arg ops and exit
//
// Messages use YAML frontmatter format:
//   ---
//   op: list
//   ---
//
// With optional body (maps to content field):
//   ---
//   op: write
//   description: my thought
//   ---
//   Body text goes here.
//
// SESSION MODE (default):
//   Holds one persistent connection open. Reads complete YAML frontmatter
//   messages from stdin, sends each over IPC, prints the response to stdout.
//   Repeats until EOF. One connection for the entire session — no reconnect
//   overhead.
//
//   The parser reads lines until it has a complete message:
//     1. Lines before the first --- are ignored (whitespace, blank lines)
//     2. Opening --- starts a message
//     3. key: value lines are the frontmatter
//     4. Closing --- ends the frontmatter
//     5. Everything after closing --- until the next opening --- (or EOF) is body
//     6. Message is sent when the next --- is seen (starting the next message)
//        or at EOF
//
//   This means you can stream multiple messages naturally:
//     ---
//     op: search
//     query: weather
//     ---
//     ---
//     op: read
//     id: abc123
//     ---
//     ---
//     op: write
//     description: new thought
//     ---
//     Body content for the write op.
//
// Examples:
//   client notes < ops.txt
//   cat <<'EOF' | client notes
//   ---
//   op: list
//   ---
//   ---
//   op: status
//   ---
//   EOF

main :: proc() {
	name := "daemon"
	if len(os.args) > 1 do name = os.args[1]

	conn, ok := shard.ipc_connect(name)
	if !ok {
		fmt.eprintln("could not connect to:", name)
		os.exit(1)
	}
	defer shard.ipc_close_conn(conn)

	if len(os.args) > 2 {
		// One-shot: send each arg as an op
		for i := 2; i < len(os.args); i += 1 {
			_send_and_print(conn, os.args[i])
		}
	} else {
		// Default: session mode — read ops from stdin on a persistent connection
		_run_session(conn)
	}
}

// Session state machine for parsing YAML frontmatter messages from a stream.
Session_State :: enum {
	Waiting,       // waiting for opening ---
	In_Front,      // inside frontmatter (between --- and ---)
	In_Body,       // after closing ---, collecting body until next --- or EOF
}

// _run_session reads YAML frontmatter messages from stdin on a persistent connection.
// One connection, many ops. Send a message, get a response, send another.
_run_session :: proc(conn: shard.IPC_Conn) {
	buf: [65536]u8
	state := Session_State.Waiting
	msg_builder := strings.builder_make()
	defer strings.builder_destroy(&msg_builder)

	_flush_msg :: proc(conn: shard.IPC_Conn, b: ^strings.Builder) -> bool {
		msg := strings.to_string(b^)
		if strings.trim_space(msg) == "" {
			strings.builder_reset(b)
			return true
		}
		data := transmute([]u8)msg
		if !shard.ipc_send_msg(conn, data) {
			fmt.eprintln("send failed — connection lost")
			return false
		}
		resp, recv_ok := shard.ipc_recv_msg(conn)
		if !recv_ok {
			fmt.eprintln("recv failed — connection lost")
			return false
		}
		fmt.print(string(resp))
		// Add newline if response doesn't end with one
		resp_str := string(resp)
		if len(resp_str) > 0 && resp_str[len(resp_str)-1] != '\n' {
			fmt.println()
		}
		delete(resp)
		strings.builder_reset(b)
		return true
	}

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
					// Closing --- of frontmatter
					strings.write_string(&msg_builder, "---\n")
					state = .In_Body
				} else {
					strings.write_string(&msg_builder, trimmed)
					strings.write_string(&msg_builder, "\n")
				}

			case .In_Body:
				if strings.trim_space(trimmed) == "---" {
					// This --- starts the NEXT message. Flush current message first.
					if !_flush_msg(conn, &msg_builder) do return
					// Start the new message
					strings.write_string(&msg_builder, "---\n")
					state = .In_Front
				} else {
					// Body content
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

_send_and_print :: proc(conn: shard.IPC_Conn, msg: string) {
	data := transmute([]u8)msg
	if !shard.ipc_send_msg(conn, data) {
		fmt.eprintln("send failed")
		return
	}
	resp, ok := shard.ipc_recv_msg(conn)
	if !ok {
		fmt.eprintln("recv failed")
		return
	}
	defer delete(resp)
	fmt.printfln(">> %s", msg)
	fmt.printfln("<< %s", string(resp))
}
