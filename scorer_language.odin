package main

COMMON :: [?]string {
	" the ",
	" and ",
	" that ",
	" this ",
	" with ",
	" from ",
	"ing",
	"ion",
	"ent",
	"her",
	"ere",
	"ter",
	"was",
	"you",
	"th",
	"he",
	"in",
	"er",
	"an",
	"re",
	"on",
	"at",
	"en",
	"nd",
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
			if lower_ascii(data[start + i]) != lower_ascii(needle[i]) {
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
		if data[i] == data[i - 1] {
			score -= 2
		}
	}

	return score
}

language_score_proc :: proc(state: rawptr, data: []u8) -> f64 {
	return f64(language_score(data))
}
