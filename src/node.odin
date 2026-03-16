package shard

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

// =============================================================================
// Node lifecycle
// =============================================================================

// Eviction defaults — overridden by .shards/config (evict_interval, slot_idle_max)
_evict_interval :: proc() -> time.Duration {
	cfg := config_get()
	return time.Duration(cfg.evict_interval) * time.Second
}

_slot_idle_max :: proc() -> time.Duration {
	cfg := config_get()
	return time.Duration(cfg.slot_idle_max) * time.Second
}

// node_init creates and initializes a node. Loads blob, builds index,
// starts IPC listener.
node_init :: proc(
	name:         string,
	master:       Master_Key,
	data_path:    string,
	idle_timeout: time.Duration,
	is_daemon:    bool = false,
) -> (node: Node, ok: bool) {
	now := time.now()
	node.name          = strings.clone(name)
	node.start_time    = now
	node.last_activity = now
	node.idle_timeout  = idle_timeout
	node.is_daemon     = is_daemon
	node.index         = make([dynamic]Search_Entry)
	node.registry      = make([dynamic]Registry_Entry)
	node.slots         = make(map[string]^Shard_Slot)

	// Ensure parent directory exists (e.g. .shards/)
	_ensure_parent_dir(data_path)

	// Load blob
	blob, blob_ok := blob_load(data_path, master)
	if !blob_ok {
		fmt.eprintln("error: could not load shard data:", data_path)
		return node, false
	}
	node.blob = blob

	// Key authentication: if there are existing thoughts but none decrypt,
	// the key is wrong. A fresh blob accepts any key.
	// Daemons use a zero key (no encrypted content in daemon blob).
	if !is_daemon {
		total_thoughts := len(node.blob.processed) + len(node.blob.unprocessed)
		if total_thoughts > 0 {
			decrypted_any := false
			descriptions := make([dynamic]string, context.temp_allocator)
			for thought in node.blob.processed {
				pt, err := thought_decrypt(thought, master, context.temp_allocator)
				if err == .None {
					desc := strings.clone(pt.description)
					append(&node.index, Search_Entry{
						id          = thought.id,
						description = desc,
						text_hash   = fnv_hash(desc),
					})
					append(&descriptions, desc)
					delete(pt.description, context.temp_allocator)
					delete(pt.content, context.temp_allocator)
					decrypted_any = true
				}
			}
			for thought in node.blob.unprocessed {
				pt, err := thought_decrypt(thought, master, context.temp_allocator)
				if err == .None {
					desc := strings.clone(pt.description)
					append(&node.index, Search_Entry{
						id          = thought.id,
						description = desc,
						text_hash   = fnv_hash(desc),
					})
					append(&descriptions, desc)
					delete(pt.description, context.temp_allocator)
					delete(pt.content, context.temp_allocator)
					decrypted_any = true
				}
			}
			if !decrypted_any {
				fmt.eprintln("error: wrong key — could not decrypt any existing thoughts")
				return node, false
			}
			if embed_ready() && len(descriptions) > 0 {
				embeddings, emb_ok := embed_texts(descriptions[:], context.temp_allocator)
				if emb_ok && len(embeddings) == len(node.index) {
					for &entry, i in node.index {
						stored := make([]f32, len(embeddings[i]))
						copy(stored, embeddings[i])
						entry.embedding = stored
					}
					fmt.eprintfln("node: embedded %d thoughts", len(node.index))
				}
			}
		}
	}

	// Daemon: load registry from manifest, scan for shards, build vector index
	if is_daemon {
		config_load()
		daemon_load_registry(&node)
		daemon_scan_shards(&node)
		index_build(&node)
	}

	// Start IPC listener
	listener, listen_ok := ipc_listen(name)
	if !listen_ok {
		fmt.eprintln("error: could not create IPC listener")
		return node, false
	}
	node.listener = listener
	fmt.eprintfln("node '%s' starting (idle timeout: %s)", name,
		idle_timeout > 0 ? fmt.tprintf("%ds", int(time.duration_seconds(idle_timeout))) : "none")

	node.running = true
	return node, true
}

// node_run is the main event loop.
// Uses timed accept so it can check idle timeout between connections.
node_run :: proc(node: ^Node) {
	fmt.eprintfln("node '%s' listening...", node.name)

	// Poll interval: check timeout every 5 seconds, or half the idle timeout if shorter
	poll_ms: u32 = 5000
	if node.idle_timeout > 0 {
		half := u32(time.duration_milliseconds(node.idle_timeout) / 2)
		if half < poll_ms && half > 0 do poll_ms = half
		if poll_ms < 500 do poll_ms = 500
	}

	last_evict := time.now()

	for node.running {
		// Check idle timeout (non-daemon nodes only)
		if node.idle_timeout > 0 {
			idle := time.diff(node.last_activity, time.now())
			if idle >= node.idle_timeout {
				fmt.eprintfln("node '%s' idle timeout reached — shutting down", node.name)
				node.running = false
				break
			}
		}

		// Daemon: periodically evict idle shard slots
		if node.is_daemon {
			since_evict := time.diff(last_evict, time.now())
			if since_evict >= _evict_interval() {
				daemon_evict_idle(node, _slot_idle_max())
				last_evict = time.now()
			}
		}

		conn, result := ipc_accept_timed(&node.listener, poll_ms)
		switch result {
		case .Ok:
			node.last_activity = time.now()
			_handle_connection(node, conn)
		case .Timeout:
			continue
		case .Error:
			continue
		}
	}
}

// _handle_connection processes requests on a single connection until it closes.
@(private)
_handle_connection :: proc(node: ^Node, conn: IPC_Conn) {
	defer ipc_close_conn(conn)

	for node.running {
		data, ok := ipc_recv_msg(conn)
		if !ok do break

		line := string(data)
		resp := dispatch(node, line)
		defer delete(data)

		node.last_activity = time.now()

		resp_bytes := transmute([]u8)resp
		if !ipc_send_msg(conn, resp_bytes) do break
	}
}

// node_shutdown gracefully shuts down the node.
node_shutdown :: proc(node: ^Node) {
	fmt.eprintfln("node '%s' shutting down...", node.name)
	node.running = false

	// Daemon: flush all loaded shard slots
	if node.is_daemon {
		daemon_flush_all(node)
	}

	blob_flush(&node.blob)
	ipc_close_listener(&node.listener)
	fmt.eprintfln("node '%s' stopped", node.name)
}

// _ensure_parent_dir creates the parent directory of a file path if it doesn't exist.
@(private)
_ensure_parent_dir :: proc(path: string) {
	// Find last / or \ separator
	last_sep := -1
	for i := len(path) - 1; i >= 0; i -= 1 {
		if path[i] == '/' || path[i] == '\\' {
			last_sep = i
			break
		}
	}
	if last_sep <= 0 do return // no parent dir or root
	dir := path[:last_sep]
	os.make_directory(dir)
}
