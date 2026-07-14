package main

import "core:fmt"

self_test_expect :: proc(failures: ^int, condition: bool, description: string) {
	if condition {
		return
	}
	failures^ += 1
	fmt.eprintf("self-test: FAIL: %s\n", description)
}

run_self_tests :: proc() -> bool {
	failures := 0

	options, options_error, _ := parse_options(nil)
	self_test_expect(&failures, options_error == .None, "default options parse")
	self_test_expect(&failures, options.mode == .Search, "default mode is search")
	self_test_expect(&failures, options.scorer_spec == "language", "default scorer is language")

	option_args := [?]string{"--scorer", "language=2,compression=0.5"}
	options, options_error, _ = parse_options(option_args[:])
	self_test_expect(&failures, options_error == .None, "explicit scorer option parses")
	self_test_expect(
		&failures,
		options.scorer_spec == "language=2,compression=0.5",
		"scorer option keeps its specification",
	)

	duplicate_args := [?]string{"--scorer=language", "--scorer", "compression"}
	_, options_error, _ = parse_options(duplicate_args[:])
	self_test_expect(
		&failures,
		options_error == .Duplicate_Scorer_Option,
		"duplicate scorer options are rejected",
	)

	registry: Scorer_Registry
	scorers, scorer_error, _ := parse_scorer_set(&registry, "language=2, compression=0.5")
	self_test_expect(&failures, scorer_error == .None, "weighted scorer set parses")
	self_test_expect(&failures, scorers.count == 2, "weighted scorer set has two entries")
	self_test_expect(&failures, scorers.items[0].weight == 2, "language weight is parsed")
	self_test_expect(&failures, scorers.items[1].weight == 0.5, "compression weight is parsed")

	_, scorer_error, _ = parse_scorer_set(&registry, "language,language")
	self_test_expect(
		&failures,
		scorer_error == .Duplicate_Scorer,
		"duplicate scorers are rejected",
	)
	_, scorer_error, _ = parse_scorer_set(&registry, "language=0")
	self_test_expect(&failures, scorer_error == .Invalid_Weight, "zero weights are rejected")
	_, scorer_error, _ = parse_scorer_set(&registry, "unknown")
	self_test_expect(&failures, scorer_error == .Unknown_Scorer, "unknown scorers are rejected")
	_, scorer_error, _ = parse_scorer_set(&registry, "language,")
	self_test_expect(&failures, scorer_error == .Empty_Item, "empty scorer items are rejected")

	english := transmute([]u8)string(" the quick brown fox and the lazy dog rested here ")
	binary: [48]u8
	self_test_expect(
		&failures,
		language_score(english) > language_score(binary[:]),
		"language scorer prefers an English fixture",
	)

	repeated := transmute([]u8)string("abcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabc")
	incompressible: [48]u8
	for &value, index in incompressible {
		value = u8(index)
	}
	compression, found := lookup_scorer(&registry, "compression")
	self_test_expect(&failures, found, "compression scorer is registered")
	repeated_score := score_with(compression, repeated)
	self_test_expect(
		&failures,
		repeated_score > score_with(compression, incompressible[:]),
		"compression scorer prefers repeated structure",
	)
	self_test_expect(
		&failures,
		repeated_score == score_with(compression, repeated),
		"compression scorer is stable across calls",
	)

	combined := score_with_set(&scorers, english)
	expected :=
		scorers.items[0].weight * score_with(scorers.items[0].scorer, english) +
		scorers.items[1].weight * score_with(scorers.items[1].scorer, english)
	self_test_expect(&failures, combined == expected, "weighted scorer values are summed")

	language_only, language_error, _ := parse_scorer_set(&registry, "language")
	self_test_expect(&failures, language_error == .None, "single scorer set parses")
	best := Candidate {
		score = -1.0e300,
	}
	consider(&best, &language_only, english, 17, .Alphabet64, 0)
	self_test_expect(
		&failures,
		best.score == score_with_set(&language_only, english) - decoder_cost(.Alphabet64),
		"decoder cost remains separate from scorer output",
	)

	if failures == 0 {
		fmt.println("self-test: ok")
		return true
	}
	fmt.eprintf("self-test: %d failure(s)\n", failures)
	return false
}
