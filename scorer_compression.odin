package main

// Compression_State is a generation-stamped hash table. Reusing it avoids
// clearing or allocating a dictionary for every candidate in the hot loop.
Compression_State :: struct {
	positions:   [256]int,
	generations: [256]u64,
	generation:  u64,
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

compression_score_proc :: proc(raw_state: rawptr, data: []u8) -> f64 {
	if len(data) == 0 || raw_state == nil {
		return 0
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
	encoded_bits := 0
	for index := 0; index < len(data); {
		match_length := 0
		if index + 2 < len(data) {
			hash := compression_hash(data, index)
			if state.generations[hash] == generation {
				previous := state.positions[hash]
				distance := index - previous
				if distance > 0 && distance <= 256 {
					limit := min(len(data) - index, 258)
					for match_length < limit &&
					    data[index + match_length] == data[index + match_length - distance] {
						match_length += 1
					}
				}
			}
		}

		if match_length >= 3 {
			encoded_bits += 17
			end := index + match_length
			for remembered := index; remembered < end; remembered += 1 {
				compression_remember(state, generation, data, remembered)
			}
			index = end
		} else {
			encoded_bits += 9
			compression_remember(state, generation, data, index)
			index += 1
		}
	}

	return f64(len(data) * 8 - encoded_bits)
}
