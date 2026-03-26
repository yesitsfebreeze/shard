package shard

import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:strings"

Gates_JSON :: struct {
	gate:          string `json:"gate"`,
	descriptors:   []Descriptor_JSON `json:"descriptors"`,
	intake_prompt: string `json:"intake_prompt"`,
	shard_links:   []string `json:"links"`,
}

Descriptor_JSON :: struct {
	format:     string `json:"format"`,
	match_rule: string `json:"match"`,
	structure:  string `json:"structure"`,
	links:      string `json:"links"`,
}

Init_Descriptor :: struct {
	name:          string `json:"name"`,
	purpose:       string `json:"purpose"`,
	tags:          []string `json:"tags"`,
	gate:          string `json:"gate"`,
	descriptors:   []Descriptor_JSON `json:"descriptors"`,
	intake_prompt: string `json:"intake_prompt"`,
	links:         []string `json:"links"`,
}

Gate_Result :: enum {
	Accept,
	Reject,
	No_Match,
}

gates_serialize :: proc(g: ^Gates) -> string {
	gj := Gates_JSON {
		gate          = g.gate,
		intake_prompt = g.intake_prompt,
		shard_links   = g.shard_links,
	}
	if len(g.descriptors) > 0 {
		dj := make([]Descriptor_JSON, len(g.descriptors), runtime_alloc)
		for d, i in g.descriptors {
			dj[i] = Descriptor_JSON {
				format     = d.format,
				match_rule = d.match_rule,
				structure  = d.structure,
				links      = d.links,
			}
		}
		gj.descriptors = dj
	}
	data, err := json.marshal(gj, allocator = runtime_alloc)
	if err != nil do return "{}"
	return string(data)
}

gates_parse :: proc(data: []u8) -> Gates {
	g: Gates
	if len(data) == 0 do return g

	gj: Gates_JSON
	if json.unmarshal(data, &gj, allocator = runtime_alloc) != nil {
		g.gate = string(data)
		return g
	}

	g.gate = gj.gate
	g.intake_prompt = gj.intake_prompt
	g.shard_links = gj.shard_links

	if len(gj.descriptors) > 0 {
		descs := make([]Descriptor, len(gj.descriptors), runtime_alloc)
		for d, i in gj.descriptors {
			descs[i] = Descriptor {
				format     = d.format,
				match_rule = d.match_rule,
				structure  = d.structure,
				links      = d.links,
			}
		}
		g.descriptors = descs
	}

	return g
}

gates_embed :: proc(g: ^Gates) {
	if !state.has_embed || len(g.gate) == 0 do return
	embedding, ok := embed_text(g.gate)
	if ok do g.gate_embedding = embedding
}

gates_check :: proc(g: ^Gates, description: string, content: string) -> Gate_Result {
	if len(g.gate) == 0 do return .No_Match

	if len(g.gate_embedding) > 0 && state.has_embed {
		text := strings.concatenate({description, " ", content}, runtime_alloc)
		text_vec, ok := embed_text(text)
		if ok {
			similarity := cosine_similarity(g.gate_embedding, text_vec)
			if similarity > GATE_ACCEPT_THRESHOLD do return .Accept
			if similarity < GATE_REJECT_THRESHOLD do return .Reject
		}
	}

	lower_gate := strings.to_lower(g.gate, runtime_alloc)
	lower_text := strings.to_lower(
		strings.concatenate({description, " ", content}, runtime_alloc),
		runtime_alloc,
	)
	words := strings.split(lower_gate, " ", allocator = runtime_alloc)
	for word in words {
		trimmed := strings.trim_space(word)
		if len(trimmed) >= 3 && strings.contains(lower_text, trimmed) {
			return .Accept
		}
	}

	return .No_Match
}

gates_describe_for_llm :: proc(g: ^Gates) -> string {
	b := strings.builder_make(runtime_alloc)
	if len(g.gate) > 0 {
		fmt.sbprintf(&b, "Gate: %s\n", g.gate)
	}
	for d, i in g.descriptors {
		fmt.sbprintf(&b, "\nDescriptor %d:\n", i + 1)
		if len(d.format) > 0 do fmt.sbprintf(&b, "  Format: %s\n", d.format)
		if len(d.match_rule) > 0 do fmt.sbprintf(&b, "  Match: %s\n", d.match_rule)
		if len(d.structure) > 0 do fmt.sbprintf(&b, "  Structure: %s\n", d.structure)
		if len(d.links) > 0 do fmt.sbprintf(&b, "  Links: %s\n", d.links)
	}
	if len(g.intake_prompt) > 0 {
		fmt.sbprintf(&b, "\nIntake: %s\n", g.intake_prompt)
	}
	if len(g.shard_links) > 0 {
		fmt.sbprintf(
			&b,
			"Linked shards: %s\n",
			strings.join(g.shard_links, ", ", allocator = runtime_alloc),
		)
	}
	return strings.to_string(b)
}

gates_auto_learn :: proc(s: ^Shard_Data) {
	thought_count := len(s.processed) + len(s.unprocessed)
	if thought_count < 5 || thought_count % 5 != 0 do return
	if len(s.gates.gate) > 0 do return
	if !state.has_key do return

	descs: [dynamic]string
	descs.allocator = runtime_alloc
	for block in ([2][][]u8{s.processed, s.unprocessed}) {
		for blob in block {
			pos := 0
			t, ok := thought_parse(blob, &pos)
			if !ok do continue
			desc, _, decrypt_ok := thought_decrypt(state.key, &t)
			if !decrypt_ok do continue
			append(&descs, desc)
		}
	}
	if len(descs) == 0 do return

	s.gates.gate = strings.join(descs[:], " ", allocator = runtime_alloc)
	gates_embed(&s.gates)
	log.infof("Auto-learned gate from %d thought descriptions", len(descs))
}
