package main

import "core:fmt"
import "core:io"

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

Language_Analysis :: struct {
	score:                 int,
	byte_points:           int,
	shape_points:          int,
	fragment_points:       int,
	repetition_points:     int,
	printable:             int,
	letters:               int,
	spaces:                int,
	vowels:                int,
	bad:                   int,
	longest_consonant_run: int,
	repeated_pairs:        int,
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

language_analyze :: proc(data: []u8) -> Language_Analysis {
	result: Language_Analysis
	consonant_run := 0

	for c in data {
		if is_printable(c) {
			result.printable += 1
			result.byte_points += 2
		} else {
			result.byte_points -= 7
			result.bad += 1
			consonant_run = 0
			continue
		}

		lc := lower_ascii(c)
		if is_letter(c) {
			result.letters += 1
			result.byte_points += 1
			if lc == 'a' || lc == 'e' || lc == 'i' || lc == 'o' || lc == 'u' || lc == 'y' {
				result.vowels += 1
				consonant_run = 0
			} else {
				consonant_run += 1
				if consonant_run > result.longest_consonant_run {
					result.longest_consonant_run = consonant_run
				}
			}
		} else {
			consonant_run = 0
			if c == ' ' {
				result.spaces += 1
				result.byte_points += 3
			} else if c == '.' || c == ',' || c == '!' || c == '?' || c == '\'' {
				result.byte_points += 1
			}
		}
	}

	// English-ish shape. This does not prove meaning; it only ranks candidates.
	if result.letters >= len(data) / 2 {
		result.shape_points += 8
	}
	if result.spaces >= 3 && result.spaces <= len(data) / 3 {
		result.shape_points += 8
	}
	if result.letters > 0 {
		vowel_percent := result.vowels * 100 / result.letters
		if vowel_percent >= 25 && vowel_percent <= 55 {
			result.shape_points += 10
		}
	}
	if result.longest_consonant_run > 6 {
		result.shape_points -= (result.longest_consonant_run - 6) * 4
	}
	if result.bad > len(data) / 5 {
		result.shape_points -= 20
	}

	for fragment, i in COMMON {
		if contains_ascii_fold(data, fragment) {
			// Longer fragments are stronger evidence than common bigrams.
			result.fragment_points += len(fragment) * len(fragment)
			if i < 6 {
				result.fragment_points += 20
			}
		}
	}

	// Reward repeated word separators a little, but punish obvious byte runs.
	for i := 1; i < len(data); i += 1 {
		if data[i] == data[i - 1] {
			result.repeated_pairs += 1
			result.repetition_points -= 2
		}
	}

	result.score =
		result.byte_points +
		result.shape_points +
		result.fragment_points +
		result.repetition_points
	return result
}

language_score :: proc(data: []u8) -> int {
	return language_analyze(data).score
}

language_score_proc :: proc(state: rawptr, data: []u8) -> f64 {
	return f64(language_score(data))
}

language_explain_proc :: proc(state: rawptr, data: []u8, weight: f64, writer: io.Writer) -> f64 {
	analysis := language_analyze(data)
	raw_score := f64(analysis.score)
	fmt.wprintf(
		writer,
		"  language: raw=%+.2f weight=%.2f contribution=%+.2f\n",
		raw_score,
		weight,
		weight * raw_score,
	)
	fmt.wprintf(
		writer,
		"    bytes: printable=%d letters=%d spaces=%d bad=%d points=%+d\n",
		analysis.printable,
		analysis.letters,
		analysis.spaces,
		analysis.bad,
		analysis.byte_points,
	)
	vowel_percent := 0
	if analysis.letters > 0 {
		vowel_percent = analysis.vowels * 100 / analysis.letters
	}
	fmt.wprintf(
		writer,
		"    shape: vowels=%d/%d (%d%%) longest-consonant-run=%d points=%+d\n",
		analysis.vowels,
		analysis.letters,
		vowel_percent,
		analysis.longest_consonant_run,
		analysis.shape_points,
	)
	fmt.wprintf(writer, "    fragments: points=%+d", analysis.fragment_points)
	matched_fragment := false
	for fragment in COMMON {
		if contains_ascii_fold(data, fragment) {
			fmt.wprintf(writer, " %q", fragment)
			matched_fragment = true
		}
	}
	if !matched_fragment {
		fmt.wprintf(writer, " none")
	}
	fmt.wprintf(writer, "\n")
	fmt.wprintf(
		writer,
		"    repeated-adjacent=%d points=%+d\n",
		analysis.repeated_pairs,
		analysis.repetition_points,
	)
	return raw_score
}
