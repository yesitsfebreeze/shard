package shard

import "core:mem"
import "core:os"
import "core:os/os2"
import "core:path/filepath"
import "core:log"

logger_init :: proc() {
	log_file_handle = os.INVALID_HANDLE
	console_logger = log.create_console_logger(.Debug)

	primary_path, fallback_path := logger_log_paths()
	handle, ok := logger_open_append(primary_path)
	if !ok && fallback_path != primary_path {
		ensure_dir(filepath.dir(fallback_path, runtime_alloc))
		handle, ok = logger_open_append(fallback_path)
	}
	if !ok {
		multi_logger = console_logger
		context.logger = multi_logger
		return
	}

	log_file_handle = handle
	file_logger = log.create_file_logger(handle, .Debug)
	multi_logger = log.create_multi_logger(console_logger, file_logger)
	context.logger = multi_logger
}

logger_open_append :: proc(path: string) -> (os.Handle, bool) {
	handle, err := os.open(path, os.O_WRONLY | os.O_CREATE | os.O_APPEND)
	if err == nil {
		os2.chmod(path, {.Read_User, .Write_User, .Read_Group, .Read_Other})
		return handle, true
	}

	if os.exists(path) {
		os2.chmod(path, {.Read_User, .Write_User, .Read_Group, .Read_Other})
		handle, err = os.open(path, os.O_WRONLY | os.O_CREATE | os.O_APPEND)
		if err == nil do return handle, true

		if os.remove(path) == nil {
			handle, err = os.open(path, os.O_WRONLY | os.O_CREATE | os.O_APPEND)
			if err == nil {
				os2.chmod(path, {.Read_User, .Write_User, .Read_Group, .Read_Other})
				return handle, true
			}
		}
	}

	return os.INVALID_HANDLE, false
}

logger_log_paths :: proc() -> (string, string) {
	primary := filepath.join({state.exe_dir, LOG_FILE}, runtime_alloc)
	fallback_base := state.run_dir
	if len(fallback_base) == 0 {
		if len(state.shards_dir) > 0 {
			fallback_base = filepath.join({state.shards_dir, RUN_DIR}, runtime_alloc)
		} else {
			fallback_base = state.exe_dir
		}
	}
	fallback := filepath.join({fallback_base, LOG_FILE}, runtime_alloc)
	return primary, fallback
}

logger_shutdown :: proc() {
	if log_file_handle != os.INVALID_HANDLE {
		log.destroy_multi_logger(multi_logger)
		log.destroy_file_logger(file_logger)
		os.close(log_file_handle)
	}
	log.destroy_console_logger(console_logger)
}

shutdown :: proc(code: int = 0) {
	logger_shutdown()
	if runtime_arena != nil do mem.arena_free_all(runtime_arena)
	os.exit(code)
}
