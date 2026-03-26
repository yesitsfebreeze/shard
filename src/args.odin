package shard

import "core:os"
import "core:strings"
import "core:log"

parse_args :: proc() -> Command {
	args := os.args[1:]
	if len(args) == 0 do return .None

	cmd := Command.None
	for i := 0; i < len(args); i += 1 {
		arg := args[i]
		switch arg {
		case "--ai":
			state.ai_mode = true
		case "--daemon", "-d":
			cmd = .Daemon
		case "--mcp":
			cmd = .Mcp
		case "--compact":
			cmd = .Compact
		case "--init":
			cmd = .Init
		case "--selftest":
			cmd = .Selftest
			if i + 1 < len(args) && !strings.has_prefix(args[i + 1], "-") {
				state.selftest_target = strings.trim_space(args[i + 1])
				i += 1
			} else {
				state.selftest_target = "guarantees"
			}
		case "--keychain":
			cmd = .Keychain
		case "--help", "-h":
			cmd = .Help
		case "--version", "-v":
			cmd = .Version
		case "--info", "-i":
			cmd = .Info
		case:
			if strings.has_prefix(arg, "--selftest=") {
				cmd = .Selftest
				state.selftest_target = strings.trim_space(arg[len("--selftest="):])
				continue
			}
					if !strings.has_prefix(arg, "-") {
						subcommand := strings.to_lower(strings.trim_space(arg), runtime_alloc)
						switch subcommand {
				case "daemon":
					cmd = .Daemon
				case "mcp":
					cmd = .Mcp
				case "compact":
					cmd = .Compact
				case "init":
					cmd = .Init
				case "selftest":
					cmd = .Selftest
					if i + 1 < len(args) && !strings.has_prefix(args[i + 1], "-") {
						state.selftest_target = strings.trim_space(args[i + 1])
						i += 1
					} else {
						state.selftest_target = "guarantees"
					}
				case "keychain":
					cmd = .Keychain
						case "help":
							cmd = .Help
						case "version":
							cmd = .Version
						case "info":
							cmd = .Info
						case:
							log.errorf("Unknown command: %s", arg)
							log.infof("%s", HELP_TEXT[.Help][0])
							shutdown(1)
						}
						continue
					}
					if strings.has_prefix(arg, "-") {
						log.errorf("Unknown flag: %s", arg)
						log.infof("%s", HELP_TEXT[.Help][0])
						shutdown(1)
					}
		}
	}
	if cmd == .Selftest && len(strings.trim_space(state.selftest_target)) == 0 {
		state.selftest_target = "guarantees"
	}
	return cmd
}
