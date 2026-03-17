package logger

// Multi-logger module — Logs to stdout, file, and provides a message queue
// for in-game console consumption.
//
// Usage:
//   logger.init()
//   defer logger.shutdown()
//   context.logger = logger.get_logger()
//
//   // In console update loop:
//   for msg in logger.drain_messages() { console.print(msg) }
//
//   // Log messages:
//   logger.info("message")
//   logger.infof("format %s", arg)

import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:os/os2"
import "core:strings"

// Force mem import to be used even when USE_TRACKING_ALLOCATOR is false
_ :: mem

USE_TRACKING_ALLOCATOR :: #config(USE_TRACKING_ALLOCATOR, ODIN_DEBUG)
LOG_FILE_PATH :: #config(LOG_FILE_PATH, "shard.log")

// ── Configuration ───────────────────────────────────────────────────

MAX_QUEUED_MESSAGES :: 256
MAX_MESSAGE_LEN :: 512

// ── State ───────────────────────────────────────────────────────────

@(private = "file")
_state: struct {
	tracking_allocator: mem.Tracking_Allocator,
	console_logger:     log.Logger,
	file_logger:        log.Logger,
	multi_logger:       log.Logger,
	log_file_handle:    os.Handle,
	initialized:        bool,
	// Message queue for console consumption
	msg_queue:          [MAX_QUEUED_MESSAGES]string,
	msg_write_idx:      int,
	msg_count:          int,
}

// ── Initialization ──────────────────────────────────────────────────

// init creates console and file loggers, returns combined logger.
// Log file is placed in the executable's directory, not the current working directory.
init :: proc() -> log.Logger {
	_state.log_file_handle = os.INVALID_HANDLE
	_state.msg_count = 0
	_state.msg_write_idx = 0

	// Create console logger (stdout)
	_state.console_logger = log.create_console_logger()

	// Resolve log file path relative to executable directory
	log_path: string
	exe_dir, exe_err := os2.get_executable_directory(context.temp_allocator)
	if exe_err != nil {
		// Fallback to CWD if exe dir resolution fails
		log_path = LOG_FILE_PATH
	} else {
		log_path, _ = os2.join_path({exe_dir, LOG_FILE_PATH}, context.temp_allocator)
	}

	// Create file logger
	_state.log_file_handle, _ = os.open(log_path, os.O_WRONLY | os.O_CREATE | os.O_TRUNC, 0o644)
	if _state.log_file_handle != os.INVALID_HANDLE {
		_state.file_logger = log.create_file_logger(_state.log_file_handle)
		// Multi-logger combining console + file
		_state.multi_logger = log.create_multi_logger(_state.console_logger, _state.file_logger)
	} else {
		// Fall back to console only
		_state.multi_logger = _state.console_logger
	}

	_state.initialized = true
	return _state.multi_logger
}

// configure rebuilds the loggers using runtime settings loaded from config.
// Call after config_load(). The caller must re-assign context.logger = logger.get_logger()
// so that Odin's log.xxx calls respect the new level and file settings.
configure :: proc(level: string, file: string, _format: string) {
	lvl := _parse_log_level(level)

	// Tear down existing loggers before rebuilding.
	if _state.log_file_handle != os.INVALID_HANDLE {
		log.destroy_multi_logger(_state.multi_logger)
		log.destroy_file_logger(_state.file_logger)
		log.destroy_console_logger(_state.console_logger)
		_state.log_file_handle = os.INVALID_HANDLE
	} else if _state.initialized {
		log.destroy_console_logger(_state.console_logger)
	}

	_state.console_logger = log.create_console_logger(lowest = lvl)

	if file != "" {
		_state.log_file_handle, _ = os.open(file, os.O_WRONLY | os.O_CREATE | os.O_APPEND, 0o644)
		if _state.log_file_handle != os.INVALID_HANDLE {
			_state.file_logger = log.create_file_logger(_state.log_file_handle, lowest = lvl)
			_state.multi_logger = log.create_multi_logger(
				_state.console_logger,
				_state.file_logger,
			)
		} else {
			_state.multi_logger = _state.console_logger
		}
	} else {
		_state.multi_logger = _state.console_logger
	}
}

@(private = "file")
_parse_log_level :: proc(level: string) -> log.Level {
	switch level {
	case "debug":
		return .Debug
	case "warn", "warning":
		return .Warning
	case "error":
		return .Error
	case "fatal":
		return .Fatal
	}
	return .Info
}

// shutdown cleans up logger resources. Call cleanup_tracking_allocator first if used.
shutdown :: proc() {
	if !_state.initialized do return

	// Free any remaining queued messages
	for i := 0; i < _state.msg_count; i += 1 {
		idx :=
			(_state.msg_write_idx - _state.msg_count + i + MAX_QUEUED_MESSAGES) %
			MAX_QUEUED_MESSAGES
		delete(_state.msg_queue[idx])
	}
	_state.msg_count = 0

	if _state.log_file_handle != os.INVALID_HANDLE {
		log.destroy_multi_logger(_state.multi_logger)
		log.destroy_file_logger(_state.file_logger)
		log.destroy_console_logger(_state.console_logger)
	} else {
		log.destroy_console_logger(_state.console_logger)
	}

	_state.initialized = false
}

// get_logger returns the multi-logger for setting context.logger.
get_logger :: proc() -> log.Logger {
	return _state.multi_logger
}

// ── Message Queue (for console consumption) ─────────────────────────

// Pending_Messages holds messages to be consumed by the console.
// Caller must delete each message after use.
Pending_Messages :: struct {
	messages: []string,
	count:    int,
}

// Static buffer for returning messages (avoids allocation).
@(private = "file")
_pending_buf: [MAX_QUEUED_MESSAGES]string

// drain_messages returns all pending log messages and clears the queue.
// Caller must delete(msg) for each message after consumption.
// Usage:
//   pending := logger.drain_messages()
//   for i in 0..<pending.count { console.print(pending.messages[i]); delete(pending.messages[i]) }
drain_messages :: proc() -> Pending_Messages {
	if _state.msg_count == 0 {
		return Pending_Messages{messages = _pending_buf[:], count = 0}
	}

	// Copy messages to pending buffer in order (oldest first)
	start := (_state.msg_write_idx - _state.msg_count + MAX_QUEUED_MESSAGES) % MAX_QUEUED_MESSAGES
	for i := 0; i < _state.msg_count; i += 1 {
		queue_idx := (start + i) % MAX_QUEUED_MESSAGES
		_pending_buf[i] = _state.msg_queue[queue_idx]
	}

	count := _state.msg_count
	_state.msg_count = 0
	_state.msg_write_idx = 0

	return Pending_Messages{messages = _pending_buf[:], count = count}
}

// ── Log Functions ───────────────────────────────────────────────────

// print is a simple debug print (debug builds only).
print :: proc(args: ..any, location := #caller_location) {
	when ODIN_DEBUG {
		log.debug(args = args, location = location)
		_console_log(args)
	}
}

debug :: proc(args: ..any, location := #caller_location) {
	when ODIN_DEBUG {
		log.debug(args = args, location = location)
		_console_log(args)
	}
}

info :: proc(args: ..any, location := #caller_location) {
	log.info(args = args, location = location)
	_console_log(args)
}

warn :: proc(args: ..any, location := #caller_location) {
	log.warn(args = args, location = location)
	_console_log(args, "[WARN] ")
}

err :: proc(args: ..any, location := #caller_location) {
	log.error(args = args, location = location)
	_console_log(args, "[ERROR] ")
}

fatal :: proc(args: ..any, location := #caller_location) {
	log.fatal(args = args, location = location)
	_console_log(args, "[FATAL] ")
}

// ── Formatted Logging ───────────────────────────────────────────────

debugf :: proc(fmt_str: string, args: ..any, location := #caller_location) {
	when ODIN_DEBUG {
		log.debugf(fmt_str, ..args, location = location)
		_console_logf(fmt_str, ..args)
	}
}

infof :: proc(fmt_str: string, args: ..any, location := #caller_location) {
	log.infof(fmt_str, ..args, location = location)
	_console_logf(fmt_str, ..args)
}

warnf :: proc(fmt_str: string, args: ..any, location := #caller_location) {
	log.warnf(fmt_str, ..args, location = location)
	_console_logf_prefix("[WARN] ", fmt_str, ..args)
}

errf :: proc(fmt_str: string, args: ..any, location := #caller_location) {
	log.errorf(fmt_str, ..args, location = location)
	_console_logf_prefix("[ERROR] ", fmt_str, ..args)
}

fatalf :: proc(fmt_str: string, args: ..any, location := #caller_location) {
	log.fatalf(fmt_str, ..args, location = location)
	_console_logf_prefix("[FATAL] ", fmt_str, ..args)
}

// ── Tracking Allocator ──────────────────────────────────────────────

init_tracking_allocator :: proc() -> mem.Allocator {
	when USE_TRACKING_ALLOCATOR {
		default_allocator := context.allocator
		mem.tracking_allocator_init(&_state.tracking_allocator, default_allocator)
		return mem.tracking_allocator(&_state.tracking_allocator)
	} else {
		return context.allocator
	}
}

cleanup_tracking_allocator :: proc() {
	when USE_TRACKING_ALLOCATOR {
		if len(_state.tracking_allocator.allocation_map) > 0 {
			errf(
				"=== %v allocations not freed: ===",
				len(_state.tracking_allocator.allocation_map),
			)
			for _, entry in _state.tracking_allocator.allocation_map {
				errf("- %v bytes @ %v", entry.size, entry.location)
			}
		}
		if len(_state.tracking_allocator.bad_free_array) > 0 {
			errf("=== %v bad frees: ===", len(_state.tracking_allocator.bad_free_array))
			for entry in _state.tracking_allocator.bad_free_array {
				errf("- %p @ %v", entry.memory, entry.location)
			}
		}
		// Get backing allocator before destroying
		backing := _state.tracking_allocator.backing
		mem.tracking_allocator_destroy(&_state.tracking_allocator)
		// Restore default allocator for cleanup
		context.allocator = backing
	}
}

// ── Internal ────────────────────────────────────────────────────────

@(private = "file")
_queue_message :: proc(msg: string) {
	// Clone the message for storage
	cloned := strings.clone(msg)

	// Ring buffer write
	idx := _state.msg_write_idx % MAX_QUEUED_MESSAGES

	// Free old message if overwriting
	if _state.msg_count == MAX_QUEUED_MESSAGES {
		delete(_state.msg_queue[idx])
	} else {
		_state.msg_count += 1
	}

	_state.msg_queue[idx] = cloned
	_state.msg_write_idx = (_state.msg_write_idx + 1) % MAX_QUEUED_MESSAGES
}

@(private = "file")
_console_log :: proc(args: []any, prefix: string = "") {
	// Format args into string
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)

	if len(prefix) > 0 {
		strings.write_string(&builder, prefix)
	}

	for idx := 0; idx < len(args); idx += 1 {
		if idx > 0 do strings.write_byte(&builder, ' ')
		fmt.sbprint(&builder, args[idx])
	}
	strings.write_byte(&builder, '\n')

	_queue_message(strings.to_string(builder))
}

@(private = "file")
_console_logf :: proc(fmt_str: string, args: ..any) {
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)

	fmt.sbprintf(&builder, fmt_str, ..args)
	_queue_message(strings.to_string(builder))
}

@(private = "file")
_console_logf_prefix :: proc(prefix: string, fmt_str: string, args: ..any) {
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)

	strings.write_string(&builder, prefix)
	fmt.sbprintf(&builder, fmt_str, ..args)
	_queue_message(strings.to_string(builder))
}
