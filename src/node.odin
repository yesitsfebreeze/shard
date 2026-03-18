package shard

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
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
	name: string,
	master: Master_Key,
	data_path: string,
	idle_timeout: time.Duration,
	is_daemon: bool = false,
) -> (
	node: Node,
	ok: bool,
) {
	now := time.now()
	node.name = strings.clone(name)
	node.start_time = now
	node.last_activity = now
	node.idle_timeout = idle_timeout
	node.is_daemon = is_daemon
	node.registry = make([dynamic]Registry_Entry)
	node.slots = make(map[string]^Shard_Slot)
	node.cache_slots = make(map[string]^Cache_Slot)
	node.event_queue = make(Event_Queue)

	// Ensure parent directory exists (e.g. .shards/)
	_ensure_parent_dir(data_path)

	// Load blob
	blob, blob_ok := blob_load(data_path, master)
	if !blob_ok {
		errf("node: could not load shard data: %s", data_path)
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
			for thought in node.blob.processed {
				pt, err := thought_decrypt(thought, master, context.temp_allocator)
				if err == .None {
					delete(pt.description, context.temp_allocator)
					delete(pt.content, context.temp_allocator)
					decrypted_any = true
					break
				}
			}
			if !decrypted_any {
				fmt.eprintfln("node: wrong key — could not decrypt any existing thoughts")
				return node, false
			}
		}
		// Build index for standalone node
		_, needs_rebuild := index_load(&node)
		defer delete(needs_rebuild)
		if len(needs_rebuild) > 0 || len(node.shard_index.shards) == 0 {
			se := Indexed_Shard {
				name    = strings.clone(node.name),
				thoughts = make([dynamic]Indexed_Thought),
			}
			descs := make([dynamic]string, context.temp_allocator)
			_index_blob_thoughts(node.blob.processed[:], master, &se, &descs)
			_index_blob_thoughts(node.blob.unprocessed[:], master, &se, &descs)
			if embed_ready() && len(descs) > 0 {
				embeddings, emb_ok := embed_texts(descs[:], context.temp_allocator)
				if emb_ok && len(embeddings) == len(se.thoughts) {
					for &te, i in se.thoughts {
						te.embedding = make([]f32, len(embeddings[i]))
						copy(te.embedding, embeddings[i])
					}
					if len(embeddings) > 0 do node.shard_index.dims = len(embeddings[0])
				}
			}
			append(&node.shard_index.shards, se)
			index_persist(&node)
		}
	}

	// Daemon: load registry from manifest, scan for shards, build unified index, load events
	if is_daemon {
		config_load()
		daemon_load_registry(&node)
		daemon_scan_shards(&node)
		index_build(&node)
		daemon_load_events(&node)
		daemon_load_consumption(&node)
		_cache_load_all(&node)
	}

	// Start IPC listener
	listener, listen_ok := ipc_listen(name)
	if !listen_ok {
		fmt.eprintfln("node: could not create IPC listener")
		return node, false
	}
	node.listener = listener
	fmt.eprintfln(
		"node '%s' starting (idle timeout: %s)",
		name,
		idle_timeout > 0 ? fmt.tprintf("%ds", int(time.duration_seconds(idle_timeout))) : "none",
	)

	node.running = true
	return node, true
}

// node_init_test creates an in-process Node for testing.
// No IPC listener is started — use daemon_dispatch directly; do not call node_run.
// idle_timeout defaults to 0 (no eviction). is_daemon is always false.
node_init_test :: proc(
	name: string,
	master: Master_Key,
	data_path: string,
	idle_timeout: time.Duration = 0,
) -> (
	node: Node,
	ok: bool,
) {
	now := time.now()
	node.name = strings.clone(name)
	node.start_time = now
	node.last_activity = now
	node.idle_timeout = idle_timeout
	node.is_daemon = false
	node.registry = make([dynamic]Registry_Entry)
	node.slots = make(map[string]^Shard_Slot)
	node.cache_slots = make(map[string]^Cache_Slot)
	node.event_queue = make(Event_Queue)

	_ensure_parent_dir(data_path)

	blob, blob_ok := blob_load(data_path, master)
	if !blob_ok {
		errf("node: could not load shard data: %s", data_path)
		return node, false
	}
	node.blob = blob

	total_thoughts := len(node.blob.processed) + len(node.blob.unprocessed)
	if total_thoughts > 0 {
		decrypted_any := false
		for thought in node.blob.processed {
			pt, err := thought_decrypt(thought, master, context.temp_allocator)
			if err == .None {
				delete(pt.description, context.temp_allocator)
				delete(pt.content, context.temp_allocator)
				decrypted_any = true
				break
			}
		}
		if !decrypted_any {
			fmt.eprintfln("node: wrong key — could not decrypt any existing thoughts")
			return node, false
		}
	}

	// Build shard_index for test node
	se := Indexed_Shard {
		name    = strings.clone(node.name),
		thoughts = make([dynamic]Indexed_Thought),
	}
	descs := make([dynamic]string, context.temp_allocator)
	_index_blob_thoughts(node.blob.processed[:], master, &se, &descs)
	_index_blob_thoughts(node.blob.unprocessed[:], master, &se, &descs)
	append(&node.shard_index.shards, se)

	node.running = true
	return node, true
}

// node_run is the main event loop.
// Accepts connections and spawns a thread per connection. The main thread
// handles accept, idle timeout, and eviction. Connection threads lock the
// node mutex around dispatch to serialize access to shared state.
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

		// Daemon: periodically evict idle shard slots (main thread only)
		if node.is_daemon {
			since_evict := time.diff(last_evict, time.now())
			if since_evict >= _evict_interval() {
				sync.lock(&node.mu)
				daemon_evict_idle(node, _slot_idle_max())
				sync.unlock(&node.mu)
				last_evict = time.now()
			}
		}

		conn, result := ipc_accept_timed(&node.listener, poll_ms)
		switch result {
		case .Ok:
			node.last_activity = time.now()
			_spawn_connection_thread(node, conn)
		case .Timeout:
			continue
		case .Error:
			continue
		}
	}
}

// Connection thread context — passed to the spawned thread.
@(private)
Conn_Thread_Data :: struct {
	node: ^Node,
	conn: IPC_Conn,
}

// _spawn_connection_thread launches a thread to handle a single connection.
@(private)
_spawn_connection_thread :: proc(node: ^Node, conn: IPC_Conn) {
	data := new(Conn_Thread_Data)
	data.node = node
	data.conn = conn
	t := thread.create(_connection_thread_proc)
	if t == nil {
		// Fallback: handle inline if thread creation fails
		fmt.eprintfln("node: could not create thread, handling connection inline")
		_handle_connection(node, conn)
		free(data)
		return
	}
	t.data = data
	thread.start(t)
}

@(private)
_connection_thread_proc :: proc(t: ^thread.Thread) {
	data := cast(^Conn_Thread_Data)t.data
	if data == nil do return
	_handle_connection(data.node, data.conn)
	free(data)
}

// _handle_connection processes requests on a single connection until it closes.
// Locks the node mutex around each dispatch call to serialize shared state access.
// The recv/send (I/O) happens outside the lock so other connections can be served.
@(private)
_handle_connection :: proc(node: ^Node, conn: IPC_Conn) {
	defer ipc_close_conn(conn)

	for node.running {
		// Receive outside the lock — allows other connections to dispatch
		data, ok := ipc_recv_msg(conn)
		if !ok do break

		line := string(data)
		infof("node: received %d bytes: %.100q", len(data), line)

		// Lock, dispatch, unlock — serializes access to node state
		sync.lock(&node.mu)
		resp := dispatch(node, line)
		node.last_activity = time.now()
		sync.unlock(&node.mu)

		infof("node: sending resp %d bytes", len(resp))
		resp_bytes := transmute([]u8)resp
		send_ok := ipc_send_msg(conn, resp_bytes)
		infof("node: send_ok=%v", send_ok)

		// Free per-request allocations after send
		delete(resp)
		delete(data)

		// Reset thread-local temp allocator to prevent monotonic growth
		free_all(context.temp_allocator)

		if !send_ok do break
	}
}

// node_shutdown gracefully shuts down the node.
// Called from the main thread after the event loop exits.
node_shutdown :: proc(node: ^Node) {
	fmt.eprintfln("node '%s' shutting down...", node.name)
	node.running = false

	// Lock to ensure no connection threads are mid-dispatch
	sync.lock(&node.mu)

	// Daemon: flush all loaded shard slots and persist events
	if node.is_daemon {
		daemon_flush_all(node)
		_daemon_persist_events(node)
		_daemon_persist_consumption(node)
	}

	blob_flush(&node.blob)
	sync.unlock(&node.mu)

	ipc_close_listener(&node.listener)

	// Free all heap allocations owned by the node
	node_destroy(node)
	fmt.eprintfln("node '%s' stopped", node.name)
}

// node_destroy frees all heap-allocated resources owned by a Node.
// Call after flushing any persistent state. Safe for both daemon and standalone nodes.
node_destroy :: proc(node: ^Node) {
	// Free node name
	delete(node.name)

	// Free the node's own blob
	blob_destroy(&node.blob)

	// Free shard index
	for &se in node.shard_index.shards {
		delete(se.name)
		delete(se.embedding)
		for &te in se.thoughts {
			delete(te.description)
			delete(te.embedding)
		}
		delete(se.thoughts)
	}
	delete(node.shard_index.shards)

	// Free registry entries
	for &entry in node.registry {
		_free_registry_entry(&entry)
	}
	delete(node.registry)

	// Free shard slots (daemon)
	for name, slot in node.slots {
		if slot.loaded {
			blob_destroy(&slot.blob)
		}
		delete(slot.name)
		delete(slot.data_path)
		delete(slot.lock_agent)
		delete(slot.lock_id)
		for &req in slot.write_queue {
			request_destroy(&req)
		}
		delete(slot.write_queue)
		if slot.pending_alerts != nil {
			for alert_id, &alert in slot.pending_alerts {
				delete(alert.alert_id)
				delete(alert.shard_name)
				delete(alert.agent)
				delete(alert.created_at)
				request_destroy(&alert.request)
				delete(alert_id)
			}
			delete(slot.pending_alerts)
		}
		free(slot)
		delete(name)
	}
	delete(node.slots)

	// Free cache slots
	for topic, slot in node.cache_slots {
		for &entry in slot.entries {
			delete(entry.id)
			delete(entry.agent)
			delete(entry.timestamp)
			delete(entry.content)
		}
		delete(slot.entries)
		delete(slot.topic)
		free(slot)
		delete(topic)
	}
	delete(node.cache_slots)

	// Free event queue
	for target, evts in node.event_queue {
		for ev in evts {
			delete(ev.source)
			delete(ev.event_type)
			delete(ev.agent)
			delete(ev.timestamp)
			for s in ev.origin_chain do delete(s)
			delete(ev.origin_chain)
		}
		delete(evts)
		delete(target)
	}
	delete(node.event_queue)

	// Free consumption log
	for rec in node.consumption_log {
		delete(rec.agent)
		delete(rec.shard)
		delete(rec.op)
		delete(rec.timestamp)
	}
	delete(node.consumption_log)

	// Free audit trail
	for entry in node.audit_trail {
		delete(entry.timestamp)
		delete(entry.alert_id)
		delete(entry.shard)
		delete(entry.agent)
		delete(entry.action)
		delete(entry.category)
	}
	delete(node.audit_trail)

	// Free pending alerts
	if node.pending_alerts != nil {
		for alert_id, &alert in node.pending_alerts {
			delete(alert.alert_id)
			delete(alert.shard_name)
			delete(alert.agent)
			delete(alert.created_at)
			request_destroy(&alert.request)
			delete(alert_id)
		}
		delete(node.pending_alerts)
	}
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
