package shard

import "core:crypto/hash"
import "core:fmt"
import "core:encoding/json"
import "core:log"
import "core:os"
import "core:os/os2"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"
import "core:time"


KEYCHAIN_PBKDF2_ITERATIONS :: 600_000
KEYCHAIN_SALT_PREFIX :: "shard-keychain-v1:"

passphrase_derive_key :: proc(passphrase: string, salt_id: string) -> Key {
	salt := strings.concatenate({KEYCHAIN_SALT_PREFIX, salt_id}, runtime_alloc)
	prev: [32]u8
	material := strings.concatenate({passphrase, salt, "\x00\x00\x00\x01"}, runtime_alloc)
	hash.hash_bytes_to_buffer(.SHA256, transmute([]u8)material, prev[:])
	result := prev
	chain := make([]u8, len(passphrase) + 32, runtime_alloc)
	for i := 1; i < KEYCHAIN_PBKDF2_ITERATIONS; i += 1 {
		next: [32]u8
		copy(chain, transmute([]u8)passphrase)
		copy(chain[len(passphrase):], prev[:])
		hash.hash_bytes_to_buffer(.SHA256, chain, next[:])
		for j := 0; j < 32; j += 1 {
			result[j] ~= next[j]
		}
		prev = next
	}
	return Key(result)
}

keychain_run :: proc() {
	passphrase := os.get_env("SHARD_PASSPHRASE", runtime_alloc)
	if len(passphrase) == 0 {
		log.error("Keychain requires SHARD_PASSPHRASE environment variable")
		shutdown(1)
	}

	derived := passphrase_derive_key(passphrase, state.shard_id)
	state.key = derived
	state.has_key = true
	log.info("Keychain: derived encryption key from passphrase")

	keychain_ipc_run()
}

keychain_ipc_run :: proc() {
	sock_path := filepath.join({state.run_dir, "keychain.sock"}, runtime_alloc)
	posix.unlink(strings.clone_to_cstring(sock_path, runtime_alloc))

	fd := posix.socket(.UNIX, .STREAM)
	if fd == -1 {
		log.error("Keychain: failed to create socket")
		return
	}
	defer posix.close(fd)

	addr: posix.sockaddr_un
	addr.sun_family = .UNIX
	path_bytes := transmute([]u8)sock_path
	for i := 0; i < min(len(path_bytes), len(addr.sun_path) - 1); i += 1 {
		addr.sun_path[i] = path_bytes[i]
	}

	if posix.bind(fd, cast(^posix.sockaddr)&addr, size_of(addr)) != .OK {
		log.errorf("Keychain: failed to bind %s", sock_path)
		return
	}
	if posix.listen(fd, 8) != .OK {
		log.error("Keychain: failed to listen")
		return
	}

	log.infof("Keychain listening on %s", sock_path)

	for {
		client_addr: posix.sockaddr
		addr_len: posix.socklen_t = size_of(posix.sockaddr)
		client_fd := posix.accept(fd, &client_addr, &addr_len)
		if client_fd == -1 do continue
		keychain_handle(client_fd)
		posix.close(client_fd)
	}
}

keychain_handle :: proc(fd: posix.FD) {
	buf: [4096]u8
	n := posix.read(fd, raw_data(buf[:]), len(buf))
	if n <= 0 do return

	request := string(buf[:int(n)])
	parsed, err := json.parse(transmute([]u8)request, allocator = runtime_alloc)
	if err != nil do return
	obj, ok := parsed.(json.Object)
	if !ok do return

	method_val, has_method := obj["method"]
	if !has_method do return
	method, method_ok := method_val.(json.String)
	if !method_ok do return

	switch method {
	case "get":
		key_name, _ := obj["key"].(json.String)
		keychain_handle_get(fd, key_name)
	case "set":
		key_name, _ := obj["key"].(json.String)
		key_value, _ := obj["value"].(json.String)
		keychain_handle_set(fd, key_name, key_value)
	case "list":
		keychain_handle_list(fd)
	case:
		resp := `{"error":"unknown method"}`
		posix.write(fd, raw_data(transmute([]u8)resp), len(resp))
	}
}

keychain_handle_get :: proc(fd: posix.FD, key_name: string) {
	if len(key_name) == 0 {
		resp := `{"error":"key name required"}`
		posix.write(fd, raw_data(transmute([]u8)resp), len(resp))
		return
	}

	s := &state.blob.shard
	for block in ([2][][]u8{s.processed, s.unprocessed}) {
		for blob in block {
			pos := 0
			t, ok := thought_parse(blob, &pos)
			if !ok do continue
			desc, content, decrypt_ok := thought_decrypt(state.key, &t)
			if !decrypt_ok do continue
			if desc == key_name {
				resp := fmt.aprintf(
					`{{"key":"%s","value":"%s"}}`,
					process_json_escape(key_name),
					process_json_escape(content),
					allocator = runtime_alloc,
				)
				posix.write(fd, raw_data(transmute([]u8)resp), len(resp))
				return
			}
		}
	}
	resp := `{"error":"not found"}`
	posix.write(fd, raw_data(transmute([]u8)resp), len(resp))
}

keychain_handle_set :: proc(fd: posix.FD, key_name: string, key_value: string) {
	if len(key_name) == 0 || len(key_value) == 0 {
		resp := `{"error":"key and value required"}`
		posix.write(fd, raw_data(transmute([]u8)resp), len(resp))
		return
	}

	id, wok := write_thought(key_name, key_value, "keychain")
	if !wok {
		resp := `{"error":"failed to store key"}`
		posix.write(fd, raw_data(transmute([]u8)resp), len(resp))
		return
	}

	resp := fmt.aprintf(
		`{{"ok":true,"key":"%s","id":"%s"}}`,
		process_json_escape(key_name),
		thought_id_to_hex(id),
		allocator = runtime_alloc,
	)
	posix.write(fd, raw_data(transmute([]u8)resp), len(resp))
}

keychain_handle_list :: proc(fd: posix.FD) {
	s := &state.blob.shard
	b := strings.builder_make(runtime_alloc)
	strings.write_string(&b, `{"keys":[`)
	first := true
	for block in ([2][][]u8{s.processed, s.unprocessed}) {
		for blob in block {
			pos := 0
			t, ok := thought_parse(blob, &pos)
			if !ok do continue
			desc, _, decrypt_ok := thought_decrypt(state.key, &t)
			if !decrypt_ok do continue
			if !first do strings.write_string(&b, ",")
			fmt.sbprintf(&b, `"%s"`, process_json_escape(desc))
			first = false
		}
	}
	strings.write_string(&b, "]}")
	resp := strings.to_string(b)
	posix.write(fd, raw_data(transmute([]u8)resp), len(resp))
}

keychain_query :: proc(key_name: string) -> (string, bool) {
	sock_path := filepath.join({state.run_dir, "keychain.sock"}, runtime_alloc)

	fd := posix.socket(.UNIX, .STREAM)
	if fd == -1 do return "", false
	defer posix.close(fd)

	addr: posix.sockaddr_un
	addr.sun_family = .UNIX
	path_bytes := transmute([]u8)sock_path
	for i := 0; i < min(len(path_bytes), len(addr.sun_path) - 1); i += 1 {
		addr.sun_path[i] = path_bytes[i]
	}

	if posix.connect(fd, cast(^posix.sockaddr)&addr, size_of(addr)) != .OK {
		log.info("Keychain not running, attempting auto-spawn")
		if !keychain_auto_spawn() do return "", false
		posix.close(fd)
		fd = posix.socket(.UNIX, .STREAM)
		if fd == -1 do return "", false
		if posix.connect(fd, cast(^posix.sockaddr)&addr, size_of(addr)) != .OK {
			log.error("Keychain: failed to connect after auto-spawn")
			return "", false
		}
	}

	req := fmt.aprintf(
		`{{"method":"get","key":"%s"}}`,
		process_json_escape(key_name),
		allocator = runtime_alloc,
	)
	posix.write(fd, raw_data(transmute([]u8)req), len(req))

	buf: [4096]u8
	n := posix.read(fd, raw_data(buf[:]), len(buf))
	if n <= 0 do return "", false

	resp_parsed, resp_err := json.parse(buf[:int(n)], allocator = runtime_alloc)
	if resp_err != nil do return "", false
	resp_obj, resp_ok := resp_parsed.(json.Object)
	if !resp_ok do return "", false

	if value, has_value := resp_obj["value"].(json.String); has_value {
		return strings.clone(value, runtime_alloc), true
	}
	return "", false
}

keychain_auto_spawn :: proc() -> bool {
	keychain_id := fmt.aprintf("%s-keychain", state.shard_id, allocator = runtime_alloc)
	keychain_path := filepath.join({state.run_dir, keychain_id}, runtime_alloc)

	if !os.exists(keychain_path) {
		new_shard := Shard_Data {
			catalog = Catalog{name = keychain_id, purpose = "keychain", created = now_rfc3339()},
		}
		buf := blob_serialize(state.blob.exe_code, &new_shard)
		if !os.write_entire_file(keychain_path, buf) {
			log.errorf("Keychain: failed to create binary at %s", keychain_path)
			return false
		}
		os2.chmod(
			keychain_path,
			{
				.Read_User,
				.Write_User,
				.Execute_User,
				.Read_Group,
				.Execute_Group,
				.Read_Other,
				.Execute_Other,
			},
		)
		log.infof("Keychain: created binary at %s", keychain_path)
	}

	pid := posix.fork()
	if pid == 0 {
		args := [?]cstring {
			strings.clone_to_cstring(keychain_path, runtime_alloc),
			"--keychain",
			nil,
		}
		posix.execv(args[0], raw_data(args[:]))
		os.exit(1)
	} else if pid < 0 {
		log.error("Keychain: failed to fork process")
		return false
	}

	wait_sock := filepath.join({state.run_dir, "keychain.sock"}, runtime_alloc)
	for attempt := 0; attempt < 10; attempt += 1 {
		time.sleep(100 * time.Millisecond)
		test_fd := posix.socket(.UNIX, .STREAM)
		if test_fd == -1 do continue
		test_addr: posix.sockaddr_un
		test_addr.sun_family = .UNIX
		sp := transmute([]u8)wait_sock
		for i := 0; i < min(len(sp), len(test_addr.sun_path) - 1); i += 1 {
			test_addr.sun_path[i] = sp[i]
		}
		if posix.connect(test_fd, cast(^posix.sockaddr)&test_addr, size_of(test_addr)) == .OK {
			posix.close(test_fd)
			log.info("Keychain: auto-spawned and connected")
			return true
		}
		posix.close(test_fd)
	}

	log.error("Keychain: auto-spawn timed out")
	return false
}
