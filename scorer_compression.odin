package main

import "core:fmt"
import "core:io"

// Compression_State is a generation-stamped hash table. Reusing it avoids
// clearing or allocating a dictionary for every candidate in the hot loop.
Compression_State :: struct {
	positions:   [256]int,
	generations: [256]u64,
	generation:  u64,
}

Compression_Analysis :: struct {
	raw_bits:      int,
	encoded_bits:  int,
	literal_count: int,
	match_count:   int,
	matched_bytes: int,
}

Compression_Match :: struct {
	offset:   int,
	distance: int,
	length:   int,
}

MAX_COMPRESSION_TRACE_MATCHES :: 64

Compression_Trace :: struct {
	items:   [MAX_COMPRESSION_TRACE_MATCHES]Compression_Match,
	count:   int,
	omitted: int,
}

compression_hash :: proc(data: []u8, index: int) -> int {
	a := u32(data[index])
	b := u32(data[index + 1])
	c := u32(data[index + 2])
	return int((a * 251 ~ b * 31 ~ c) & 255)
}

compression_remember :: proc(state: ^Compression_State, generation: u64, data: []u8, index: int) {
	if index + 2 >= len(data) {
		return
	}
	hash := compression_hash(data, index)
	state.positions[hash] = index
	state.generations[hash] = generation
}

compression_analyze :: proc(
	raw_state: rawptr,
	data: []u8,
	trace: ^Compression_Trace = nil,
) -> Compression_Analysis {
	result: Compression_Analysis
	if len(data) == 0 || raw_state == nil {
		return result
	}
	if trace != nil {
		trace^ = {}
	}

	state := (^Compression_State)(raw_state)
	if state.generation == max(u64) {
		state.generations = {}
		state.generation = 1
	} else {
		state.generation += 1
	}
	generation := state.generation

	// Estimate an LZSS stream: a literal costs a one-bit tag plus one byte;
	// a match costs a tag, an eight-bit distance, and an eight-bit length.
	result.raw_bits = len(data) * 8
	for index := 0; index < len(data); {
		match_length := 0
		match_distance := 0
		if index + 2 < len(data) {
			hash := compression_hash(data, index)
			if state.generations[hash] == generation {
				previous := state.positions[hash]
				distance := index - previous
				if distance > 0 && distance <= 256 {
					match_distance = distance
					limit := min(len(data) - index, 258)
					for match_length < limit &&
					    data[index + match_length] == data[index + match_length - distance] {
						match_length += 1
					}
				}
			}
		}

		if match_length >= 3 {
			result.encoded_bits += 17
			result.match_count += 1
			result.matched_bytes += match_length
			if trace != nil {
				if trace.count < len(trace.items) {
					trace.items[trace.count] = Compression_Match {
						offset   = index,
						distance = match_distance,
						length   = match_length,
					}
					trace.count += 1
				} else {
					trace.omitted += 1
				}
			}
			end := index + match_length
			for remembered := index; remembered < end; remembered += 1 {
				compression_remember(state, generation, data, remembered)
			}
			index = end
		} else {
			result.encoded_bits += 9
			result.literal_count += 1
			compression_remember(state, generation, data, index)
			index += 1
		}
	}

	return result
}

compression_score_proc :: proc(raw_state: rawptr, data: []u8) -> f64 {
	analysis := compression_analyze(raw_state, data)
	return f64(analysis.raw_bits - analysis.encoded_bits)
}

compression_explain_proc :: proc(
	raw_state: rawptr,
	data: []u8,
	weight: f64,
	writer: io.Writer,
) -> f64 {
	trace: Compression_Trace
	analysis := compression_analyze(raw_state, data, &trace)
	raw_score := f64(analysis.raw_bits - analysis.encoded_bits)
	fmt.wprintf(
		writer,
		"  compression: raw=%+.2f weight=%.2f contribution=%+.2f\n",
		raw_score,
		weight,
		weight * raw_score,
	)
	fmt.wprintf(
		writer,
		"    raw-bits=%d encoded-bits=%d literals=%d matches=%d matched-bytes=%d\n",
		analysis.raw_bits,
		analysis.encoded_bits,
		analysis.literal_count,
		analysis.match_count,
		analysis.matched_bytes,
	)
	if analysis.match_count == 0 {
		fmt.wprintf(writer, "    matches: none\n")
	} else {
		fmt.wprintf(writer, "    matches:\n")
		for match in trace.items[:trace.count] {
			fmt.wprintf(
				writer,
				"      offset %d <- distance %d length %d\n",
				match.offset,
				match.distance,
				match.length,
			)
		}
		if trace.omitted > 0 {
			fmt.wprintf(writer, "      ... %d more matches\n", trace.omitted)
		}
	}
	return raw_score
}
