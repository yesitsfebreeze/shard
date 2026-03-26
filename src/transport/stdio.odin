package transport

import "core:log"
import "core:mem"
import "../protocol"

Transport_Line_Normalize_Response :: proc(resp: string, allocator: mem.Allocator) -> string {
	return protocol.Line_Normalize_Response(resp, allocator)
}

Transport_Stdio_Run :: proc(processor: protocol.Stdio_Processor, allocator: mem.Allocator) {
	log.info("Shard process server started on stdio")
	protocol.stdio_run(processor, allocator)
}
