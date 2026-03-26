package shard

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

meta_bucket_label :: proc(bucket: int) -> (string, bool) {
	if bucket < 0 do return "", false
	switch bucket {
	case 0:
		return "1h", true
	case 1:
		return "24h", true
	case 2:
		return "7d", true
	case 3:
		return "30d", true
	case:
		years := bucket - 3
		return fmt.aprintf("%dy", years, allocator = runtime_alloc), true
	}
}

meta_bucket_from_string :: proc(raw: string) -> (int, bool) {
	return parse_decimal_int(raw)
}

META_ACCESS_EVENTS_KEY :: "meta_access_events"
META_WRITE_EVENTS_KEY :: "meta_write_events"
META_EVENT_MAX :: 4096

meta_trim_events_csv :: proc(csv: string, max_events: int = META_EVENT_MAX) -> string {
	if len(csv) == 0 do return ""
	parts := strings.split(csv, ",", allocator = runtime_alloc)
	if len(parts) <= max_events do return csv
	start := len(parts) - max_events
	return strings.join(parts[start:], ",", allocator = runtime_alloc)
}

meta_append_event :: proc(key: string, ts: string) {
	if len(ts) == 0 do return
	cache_load()
	entry := state.topic_cache[key]
	if len(entry.value) == 0 {
		entry.value = strings.clone(ts, runtime_alloc)
	} else {
		entry.value = strings.concatenate({entry.value, ",", ts}, runtime_alloc)
	}
	entry.value = meta_trim_events_csv(entry.value)
	state.topic_cache[strings.clone(key, runtime_alloc)] = entry
	cache_save_key(key, entry)
}

meta_record_access :: proc() {
	meta_append_event(META_ACCESS_EVENTS_KEY, now_rfc3339())
}

meta_record_write :: proc() {
	meta_append_event(META_WRITE_EVENTS_KEY, now_rfc3339())
}

parse_rfc3339_hour :: proc(s: string) -> int {
	if len(s) < 13 do return 0
	return parse_int_simple(s[11:13])
}

meta_event_in_bucket :: proc(ts: string, bucket: int) -> bool {
	y, mon, d := parse_rfc3339_date(ts)
	if y == 0 do return false
	h := parse_rfc3339_hour(ts)

	now := time.now()
	now_y, now_mon, now_d := time.date(now)
	now_h, _, _ := time.clock(now)

	delta_days := (now_y - y) * 365 + (int(now_mon) - mon) * 30 + (now_d - d)
	if delta_days < 0 do return false
	delta_hours := delta_days * 24 + (now_h - h)
	if delta_hours < 0 do return false

	switch {
	case bucket == 0:
		return delta_hours <= 1
	case bucket == 1:
		return delta_days <= 1
	case bucket == 2:
		return delta_days <= 7
	case bucket == 3:
		return delta_days <= 30
	case bucket >= 4:
		years := bucket - 3
		return delta_days <= years * 365
	case:
		return false
	}
}

meta_count_events_in_bucket :: proc(csv: string, bucket: int) -> (u64, string) {
	if len(csv) == 0 do return 0, ""
	parts := strings.split(csv, ",", allocator = runtime_alloc)
	count: u64 = 0
	last := ""
	for raw in parts {
		ts := strings.trim_space(raw)
		if len(ts) == 0 do continue
		if !meta_event_in_bucket(ts, bucket) do continue
		count += 1
		if len(last) == 0 || ts > last do last = ts
	}
	return count, last
}

meta_stats_for_bucket :: proc(bucket: int) -> Meta_Stats {
	cache_load()
	access_entry := state.topic_cache[META_ACCESS_EVENTS_KEY]
	write_entry := state.topic_cache[META_WRITE_EVENTS_KEY]
	access_count, last_access := meta_count_events_in_bucket(access_entry.value, bucket)
	write_count, _ := meta_count_events_in_bucket(write_entry.value, bucket)
	return Meta_Stats {
		access_count = access_count,
		write_count = write_count,
		last_access_at = last_access,
	}
}

meta_item_from_blob :: proc(shard_id: string, bucket: int, blob: ^Blob) -> Meta_Item {
	item := Meta_Item {
		id               = shard_id,
		name             = shard_id,
		thought_count    = 0,
		linked_shard_ids = make([dynamic]string, 0, runtime_alloc),
		stats            = meta_stats_for_bucket(bucket),
	}
	if !blob.has_data do return item

	s := &blob.shard
	if len(s.catalog.name) > 0 do item.name = s.catalog.name
	item.thought_count = len(s.processed) + len(s.unprocessed)
	if len(s.gates.shard_links) > 0 {
		item.linked_shard_ids = make([dynamic]string, len(s.gates.shard_links), runtime_alloc)
		for link, i in s.gates.shard_links {
			item.linked_shard_ids[i] = strings.clone(link, runtime_alloc)
		}
	}
	return item
}

meta_item_for_shard :: proc(shard_id: string, bucket: int) -> (Meta_Single_Response, bool) {
	window, ok := meta_bucket_label(bucket)
	if !ok do return {}, false

	if shard_id == state.shard_id {
		item := meta_item_from_blob(shard_id, bucket, &state.blob)
		return Meta_Single_Response {
				id = item.id,
				name = item.name,
				bucket = bucket,
				window = window,
				thought_count = item.thought_count,
				linked_shard_ids = item.linked_shard_ids,
				stats = item.stats,
			},
			true
	}

	peers := index_list()
	for peer in peers {
		if peer.shard_id != shard_id do continue
		raw, read_ok := os.read_entire_file(peer.exe_path, runtime_alloc)
		if !read_ok do return {}, false
		blob := load_blob_from_raw(raw)
		item := meta_item_from_blob(shard_id, bucket, &blob)
		return Meta_Single_Response {
				id = item.id,
				name = item.name,
				bucket = bucket,
				window = window,
				thought_count = item.thought_count,
				linked_shard_ids = item.linked_shard_ids,
				stats = item.stats,
			},
			true
	}

	return {}, false
}
