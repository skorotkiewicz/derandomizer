package main

import "core:fmt"
import "core:os"

BLOCK_SIZE :: 8 * 1024
WINDOW :: 48
STRIDE :: 8

Decoder :: enum {
	Raw,
	Xor,
	Add,
	Alphabet64,
}

Candidate :: struct {
	score:   f64,
	offset:  u64,
	decoder: Decoder,
	param:   u8,
	bytes:   [WINDOW]u8,
}

decoder_cost :: proc(decoder: Decoder) -> f64 {
	switch decoder {
	case .Raw:
		return 0
	case .Xor, .Add:
		return 10
	case .Alphabet64:
		// This decoder forces bytes into a printable alphabet, so it must pay for it.
		return 55
	}
	return 0
}

decode_raw :: proc(src: []u8, dst: []u8) {
	copy(dst, src)
}

decode_xor :: proc(src: []u8, dst: []u8, key: u8) {
	for b, i in src {
		dst[i] = b ~ key
	}
}

decode_add :: proc(src: []u8, dst: []u8, key: u8) {
	for b, i in src {
		dst[i] = u8((u16(b) + u16(key)) & 255)
	}
}

ALPHABET64 :: " etaoinshrdlucmfwypvbgkjqxzETAOINSHRDLUCMFWYPVBGKJQXZ,.!?'-01234"

decode_alphabet64 :: proc(src: []u8, dst: []u8) {
	alphabet := ALPHABET64
	for b, i in src {
		dst[i] = alphabet[int(b & 63)]
	}
}

consider :: proc(
	best: ^Candidate,
	scorers: ^Scorer_Set,
	decoded: []u8,
	offset: u64,
	decoder: Decoder,
	param: u8,
) -> bool {
	score := score_with_set(scorers, decoded) - decoder_cost(decoder)
	if score <= best.score {
		return false
	}

	best.score = score
	best.offset = offset
	best.decoder = decoder
	best.param = param
	copy(best.bytes[:], decoded)
	return true
}

print_candidate :: proc(c: ^Candidate, scorers: ^Scorer_Set, show_explanation: bool) {
	rendered: [WINDOW]u8
	for b, i in c.bytes {
		if is_printable(b) {
			rendered[i] = b
		} else {
			rendered[i] = '.'
		}
	}

	fmt.printf(
		"\nmeaning candidate: score=%.2f  offset=%d  decoder=%v",
		c.score,
		c.offset,
		c.decoder,
	)
	if c.decoder == .Xor || c.decoder == .Add {
		fmt.printf("  key=0x%02x", c.param)
	}
	fmt.println()
	fmt.println(string(rendered[:]))
	if show_explanation {
		explain_score_with_set(scorers, c.bytes[:], c.decoder, os.to_writer(os.stdout))
	}
}

print_active_scorers :: proc(scorers: ^Scorer_Set) {
	fmt.print("scorers: ")
	for item, index in scorers.items[:scorers.count] {
		if index > 0 {
			fmt.print(", ")
		}
		fmt.printf("%s=%.2f", item.scorer.name, item.weight)
	}
	fmt.println()
}

run_search :: proc(
	scorers: ^Scorer_Set,
	scorer_spec: string,
	thread_count: int,
	automatic_threads: bool,
	show_explanation: bool,
) {
	entropy, err := os.open("/dev/urandom")
	if err != os.ERROR_NONE {
		fmt.printf("derandomizer: cannot open /dev/urandom: %v\n", err)
		os.exit(1)
	}
	defer os.close(entropy)

	parallel_scanner: Parallel_Scanner
	parallel_initialized := false
	if thread_count > 1 {
		scorer_error, scorer_detail := parallel_scanner_init(
			&parallel_scanner,
			scorer_spec,
			thread_count,
		)
		if scorer_error != .None {
			print_scorer_spec_error(scorer_error, scorer_detail)
			return
		}
		parallel_initialized = true
	}
	defer if parallel_initialized {
		parallel_scanner_destroy(&parallel_scanner)
	}

	fmt.println("DERANDOMIZER")
	fmt.println("mining /dev/urandom for suspiciously meaningful accidents")
	fmt.println("Ctrl-C stops the universe search")
	print_active_scorers(scorers)
	if automatic_threads {
		fmt.printf("threads: %d (auto)\n", thread_count)
	} else {
		fmt.printf("threads: %d\n", thread_count)
	}

	best := Candidate {
		score = -1.0e300,
	}
	block: [BLOCK_SIZE + WINDOW - STRIDE]u8
	records := make([dynamic]Candidate, 0, 32)
	defer delete(records)
	carry_length := 0
	base_offset: u64 = 0
	total: u64 = 0

	for {
		read_buffer := block[carry_length:carry_length + BLOCK_SIZE]
		n, read_err := os.read_full(entropy, read_buffer)
		if read_err != os.ERROR_NONE || n != len(read_buffer) {
			fmt.printf("derandomizer: entropy read failed after %d bytes: %v\n", total, read_err)
			return
		}

		data_length := carry_length + n
		data := block[:data_length]
		clear(&records)
		if thread_count > 1 {
			best = parallel_scan_chunk(&parallel_scanner, data, base_offset, best, &records)
		} else {
			best = scan_chunk(scorers, data, base_offset, best, &records)
		}
		for &candidate in records {
			print_candidate(&candidate, scorers, show_explanation)
		}

		total += u64(n)
		next_start := scan_window_count(data) * STRIDE
		carry_length = data_length - next_start
		copy(block[:carry_length], block[next_start:data_length])
		base_offset += u64(next_start)

		if total % (1024 * 1024) == 0 {
			fmt.printf("\rsearched %d MiB | best score %.2f", total / (1024 * 1024), best.score)
		}
	}
}

main :: proc() {
	options, options_error, options_detail := parse_options(os.args[1:])
	if options_error != .None {
		print_options_error(options_error, options_detail)
		print_usage(os.args[0])
		os.exit(2)
	}
	if options.mode == .Help {
		print_usage(os.args[0])
		return
	}
	if options.mode == .Self_Test {
		if !run_self_tests() {
			os.exit(1)
		}
		return
	}

	registry: Scorer_Registry
	scorers, scorer_error, scorer_detail := parse_scorer_set(&registry, options.scorer_spec)
	if scorer_error != .None {
		print_scorer_spec_error(scorer_error, scorer_detail)
		os.exit(2)
	}
	thread_count := resolve_thread_count(options.threads)
	run_search(&scorers, options.scorer_spec, thread_count, options.threads == 0, options.explain)
}
