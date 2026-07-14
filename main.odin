package main

import "core:fmt"
import "core:os"

BLOCK_SIZE :: 8 * 1024
WINDOW     :: 48
STRIDE     :: 8

Decoder :: enum {
	Raw,
	Xor,
	Add,
	Alphabet64,
}

Candidate :: struct {
	score:   int,
	offset:  u64,
	decoder: Decoder,
	param:   u8,
	bytes:   [WINDOW]u8,
}

COMMON :: [?]string{
	" the ", " and ", " that ", " this ", " with ", " from ",
	"ing", "ion", "ent", "her", "ere", "ter", "was", "you",
	"th", "he", "in", "er", "an", "re", "on", "at", "en", "nd",
}

is_letter :: proc(c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

is_printable :: proc(c: u8) -> bool {
	return c >= 32 && c <= 126
}

lower_ascii :: proc(c: u8) -> u8 {
	if c >= 'A' && c <= 'Z' {
		return c + ('a' - 'A')
	}
	return c
}

contains_ascii_fold :: proc(data: []u8, needle: string) -> bool {
	if len(needle) == 0 || len(needle) > len(data) {
		return false
	}

	for start := 0; start <= len(data) - len(needle); start += 1 {
		match := true
		for i := 0; i < len(needle); i += 1 {
			if lower_ascii(data[start+i]) != lower_ascii(needle[i]) {
				match = false
				break
			}
		}
		if match {
			return true
		}
	}
	return false
}

language_score :: proc(data: []u8) -> int {
	score := 0
	letters := 0
	spaces := 0
	vowels := 0
	bad := 0
	consonant_run := 0
	longest_consonant_run := 0

	for c in data {
		if is_printable(c) {
			score += 2
		} else {
			score -= 7
			bad += 1
			consonant_run = 0
			continue
		}

		lc := lower_ascii(c)
		if is_letter(c) {
			letters += 1
			score += 1
			if lc == 'a' || lc == 'e' || lc == 'i' || lc == 'o' || lc == 'u' || lc == 'y' {
				vowels += 1
				consonant_run = 0
			} else {
				consonant_run += 1
				if consonant_run > longest_consonant_run {
					longest_consonant_run = consonant_run
				}
			}
		} else {
			consonant_run = 0
			if c == ' ' {
				spaces += 1
				score += 3
			} else if c == '.' || c == ',' || c == '!' || c == '?' || c == '\'' {
				score += 1
			}
		}
	}

	// English-ish shape. This does not prove meaning; it only ranks candidates.
	if letters >= len(data) / 2 {
		score += 8
	}
	if spaces >= 3 && spaces <= len(data) / 3 {
		score += 8
	}
	if letters > 0 {
		vowel_percent := vowels * 100 / letters
		if vowel_percent >= 25 && vowel_percent <= 55 {
			score += 10
		}
	}
	if longest_consonant_run > 6 {
		score -= (longest_consonant_run - 6) * 4
	}
	if bad > len(data) / 5 {
		score -= 20
	}

	for fragment, i in COMMON {
		if contains_ascii_fold(data, fragment) {
			// Longer fragments are stronger evidence than common bigrams.
			score += len(fragment) * len(fragment)
			if i < 6 {
				score += 20
			}
		}
	}

	// Reward repeated word separators a little, but punish obvious byte runs.
	for i := 1; i < len(data); i += 1 {
		if data[i] == data[i-1] {
			score -= 2
		}
	}

	return score
}

decoder_cost :: proc(decoder: Decoder) -> int {
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

consider :: proc(best: ^Candidate, decoded: []u8, offset: u64, decoder: Decoder, param: u8) -> bool {
	score := language_score(decoded) - decoder_cost(decoder)
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

	fmt.printf("\nmeaning candidate: score=%d  offset=%d  decoder=%v", c.score, c.offset, c.decoder)
	if c.decoder == .Xor || c.decoder == .Add {
		fmt.printf("  key=0x%02x", c.param)
	}
	fmt.println()
	fmt.println(string(rendered[:]))
}

main :: proc() {
	entropy, err := os.open("/dev/urandom")
	if err != os.ERROR_NONE {
		fmt.printf("derandomizer: cannot open /dev/urandom: %v\n", err)
		os.exit(1)
	}
	defer os.close(entropy)

	fmt.println("DERANDOMIZER")
	fmt.println("mining /dev/urandom for suspiciously meaningful accidents")
	fmt.println("Ctrl-C stops the universe search")

	best := Candidate{score = -1_000_000}
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
			src := block[start:start+WINDOW]
			offset := total + u64(start)

			decode_raw(src, decoded[:])
			if consider(&best, decoded[:], offset, .Raw, 0) {
				print_candidate(&best)
			}

			for key := 1; key < 256; key += 1 {
				k := u8(key)

				decode_xor(src, decoded[:], k)
				if consider(&best, decoded[:], offset, .Xor, k) {
					print_candidate(&best)
				}

				decode_add(src, decoded[:], k)
				if consider(&best, decoded[:], offset, .Add, k) {
					print_candidate(&best)
				}
			}

			decode_alphabet64(src, decoded[:])
			if consider(&best, decoded[:], offset, .Alphabet64, 0) {
				print_candidate(&best)
			}
		}

		total += u64(n)
		if total % (1024 * 1024) == 0 {
			fmt.printf("\rsearched %d MiB | best score %d", total / (1024 * 1024), best.score)
		}
	}
}
