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

print_candidate :: proc(c: ^Candidate) {
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

run_search :: proc(scorers: ^Scorer_Set) {
	entropy, err := os.open("/dev/urandom")
	if err != os.ERROR_NONE {
		fmt.printf("derandomizer: cannot open /dev/urandom: %v\n", err)
		os.exit(1)
	}
	defer os.close(entropy)

	fmt.println("DERANDOMIZER")
	fmt.println("mining /dev/urandom for suspiciously meaningful accidents")
	fmt.println("Ctrl-C stops the universe search")
	print_active_scorers(scorers)

	best := Candidate {
		score = -1.0e300,
	}
	block: [BLOCK_SIZE]u8
	decoded: [WINDOW]u8
	total: u64 = 0

	for {
		n, read_err := os.read_full(entropy, block[:])
		if read_err != os.ERROR_NONE || n != len(block) {
			fmt.printf("derandomizer: entropy read failed after %d bytes: %v\n", total, read_err)
			return
		}

		for start := 0; start + WINDOW <= len(block); start += STRIDE {
			src := block[start:start + WINDOW]
			offset := total + u64(start)

			decode_raw(src, decoded[:])
			if consider(&best, scorers, decoded[:], offset, .Raw, 0) {
				print_candidate(&best)
			}

			for key := 1; key < 256; key += 1 {
				k := u8(key)

				decode_xor(src, decoded[:], k)
				if consider(&best, scorers, decoded[:], offset, .Xor, k) {
					print_candidate(&best)
				}

				decode_add(src, decoded[:], k)
				if consider(&best, scorers, decoded[:], offset, .Add, k) {
					print_candidate(&best)
				}
			}

			decode_alphabet64(src, decoded[:])
			if consider(&best, scorers, decoded[:], offset, .Alphabet64, 0) {
				print_candidate(&best)
			}
		}

		total += u64(n)
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
	run_search(&scorers)
}
