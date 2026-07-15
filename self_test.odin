package main

import "core:fmt"
import "core:strings"

self_test_expect :: proc(failures: ^int, condition: bool, description: string) {
	if condition {
		return
	}
	failures^ += 1
	fmt.eprintf("self-test: FAIL: %s\n", description)
}

candidate_equal :: proc(a, b: Candidate) -> bool {
	return(
		a.score == b.score &&
		a.offset == b.offset &&
		a.decoder == b.decoder &&
		a.param == b.param &&
		a.bytes == b.bytes \
	)
}

candidate_records_equal :: proc(a, b: []Candidate) -> bool {
	if len(a) != len(b) {
		return false
	}
	for candidate, index in a {
		if !candidate_equal(candidate, b[index]) {
			return false
		}
	}
	return true
}

scan_streamed_for_test :: proc(
	scorers: ^Scorer_Set,
	data: []u8,
	read_size: int,
	records: ^[dynamic]Candidate,
) -> (
	Candidate,
	int,
) {
	assert(read_size > 0)
	buffer := make([]u8, read_size + WINDOW - STRIDE)
	defer delete(buffer)

	best := Candidate {
		score = -1.0e300,
	}
	carry_length := 0
	base_offset: u64 = 0
	source_offset := 0
	windows_scanned := 0

	for source_offset < len(data) {
		read_length := min(read_size, len(data) - source_offset)
		copy(
			buffer[carry_length:carry_length + read_length],
			data[source_offset:source_offset + read_length],
		)
		data_length := carry_length + read_length
		chunk := buffer[:data_length]
		window_count := scan_window_count(chunk)
		windows_scanned += window_count
		best = scan_chunk(scorers, chunk, base_offset, best, records)

		next_start := window_count * STRIDE
		carry_length = data_length - next_start
		copy(buffer[:carry_length], buffer[next_start:data_length])
		base_offset += u64(next_start)
		source_offset += read_length
	}

	return best, windows_scanned
}

run_self_tests :: proc() -> bool {
	failures := 0

	options, options_error, _ := parse_options(nil)
	self_test_expect(&failures, options_error == .None, "default options parse")
	self_test_expect(&failures, options.mode == .Search, "default mode is search")
	self_test_expect(&failures, options.scorer_spec == "language", "default scorer is language")
	self_test_expect(&failures, options.threads == 0, "default thread count is automatic")
	self_test_expect(&failures, !options.explain, "score explanations are disabled by default")

	option_args := [?]string{"--scorer", "language=2,compression=0.5", "--threads=4", "--explain"}
	options, options_error, _ = parse_options(option_args[:])
	self_test_expect(&failures, options_error == .None, "explicit scorer option parses")
	self_test_expect(
		&failures,
		options.scorer_spec == "language=2,compression=0.5",
		"scorer option keeps its specification",
	)
	self_test_expect(&failures, options.threads == 4, "thread count option parses")
	self_test_expect(&failures, options.explain, "explain option parses")

	duplicate_args := [?]string{"--scorer=language", "--scorer", "compression"}
	_, options_error, _ = parse_options(duplicate_args[:])
	self_test_expect(
		&failures,
		options_error == .Duplicate_Scorer_Option,
		"duplicate scorer options are rejected",
	)
	invalid_threads_args := [?]string{"--threads", "-1"}
	_, options_error, _ = parse_options(invalid_threads_args[:])
	self_test_expect(
		&failures,
		options_error == .Invalid_Thread_Count,
		"negative thread counts are rejected",
	)
	duplicate_threads_args := [?]string{"--threads=2", "--threads", "4"}
	_, options_error, _ = parse_options(duplicate_threads_args[:])
	self_test_expect(
		&failures,
		options_error == .Duplicate_Threads_Option,
		"duplicate thread options are rejected",
	)
	self_test_expect(&failures, resolve_thread_count(3) == 3, "explicit thread count is preserved")
	automatic_threads := resolve_thread_count(0)
	self_test_expect(
		&failures,
		automatic_threads >= 1 && automatic_threads <= MAX_THREADS,
		"automatic thread count is bounded",
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
	language_analysis := language_analyze(english)
	self_test_expect(
		&failures,
		language_analysis.score ==
		language_analysis.byte_points +
			language_analysis.shape_points +
			language_analysis.fragment_points +
			language_analysis.repetition_points,
		"language explanation components sum to its score",
	)

	repeated := transmute([]u8)string("abcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabc")
	incompressible: [48]u8
	for &value, index in incompressible {
		value = u8(index)
	}
	compression, found := lookup_scorer(&registry, "compression")
	self_test_expect(&failures, found, "compression scorer is registered")
	self_test_expect(&failures, compression.explain != nil, "compression scorer has an explainer")
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
	compression_trace: Compression_Trace
	compression_analysis := compression_analyze(compression.state, repeated, &compression_trace)
	self_test_expect(
		&failures,
		compression_analysis.raw_bits - compression_analysis.encoded_bits == int(repeated_score),
		"compression explanation arithmetic matches its score",
	)
	self_test_expect(
		&failures,
		compression_trace.count > 0 && compression_analysis.match_count > 0,
		"compression explanation records repeated matches",
	)

	combined := score_with_set(&scorers, english)
	expected :=
		scorers.items[0].weight * score_with(scorers.items[0].scorer, english) +
		scorers.items[1].weight * score_with(scorers.items[1].scorer, english)
	self_test_expect(&failures, combined == expected, "weighted scorer values are summed")
	explanation_buffer: [16 * 1024]u8
	explanation_builder := strings.builder_from_bytes(explanation_buffer[:])
	expected_explained_score := score_with_set(&scorers, english) - decoder_cost(.Alphabet64)
	explained_score := explain_score_with_set(
		&scorers,
		english,
		.Alphabet64,
		strings.to_writer(&explanation_builder),
	)
	explanation := strings.to_string(explanation_builder)
	self_test_expect(
		&failures,
		explained_score == expected_explained_score,
		"explained total matches normal weighted scoring and decoder cost",
	)
	self_test_expect(
		&failures,
		strings.contains(explanation, "  language: raw=") &&
		strings.contains(explanation, "  compression: raw=") &&
		strings.contains(explanation, "    matches:") &&
		strings.contains(explanation, "  decoder: Alphabet64 cost=55.00") &&
		strings.contains(explanation, "  total: "),
		"explanation includes scorer contributions, decoder cost, and total",
	)
	strings.builder_reset(&explanation_builder)
	compression_only: Scorer_Set
	compression_only.items[0] = Weighted_Scorer {
		scorer = compression,
		weight = 1,
	}
	compression_only.count = 1
	explain_score_with_set(
		&compression_only,
		repeated,
		.Raw,
		strings.to_writer(&explanation_builder),
	)
	compression_explanation := strings.to_string(explanation_builder)
	self_test_expect(
		&failures,
		strings.contains(compression_explanation, "offset 3 <- distance 3 length 45"),
		"compression explanation includes match offset, distance, and length",
	)

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

	boundary_data: [128]u8
	for &value in boundary_data {
		value = 0xff
	}
	boundary_text := transmute([]u8)string(" the quick brown fox and the lazy dog rests now.")
	self_test_expect(&failures, len(boundary_text) == WINDOW, "boundary fixture is one window")
	copy(boundary_data[24:24 + WINDOW], boundary_text)

	whole_registry: Scorer_Registry
	whole_scorers, whole_error, _ := parse_scorer_set(&whole_registry, "language")
	self_test_expect(&failures, whole_error == .None, "whole-input scorer parses")
	whole_records := make([dynamic]Candidate, 0, 16)
	whole_initial := Candidate {
		score = -1.0e300,
	}
	whole_best := scan_chunk(&whole_scorers, boundary_data[:], 0, whole_initial, &whole_records)
	self_test_expect(
		&failures,
		whole_best.offset == 24,
		"boundary fixture best starts at offset 24",
	)

	streamed_registry: Scorer_Registry
	streamed_scorers, streamed_error, _ := parse_scorer_set(&streamed_registry, "language")
	self_test_expect(&failures, streamed_error == .None, "streamed scorer parses")
	streamed_records := make([dynamic]Candidate, 0, 16)
	streamed_best, streamed_windows := scan_streamed_for_test(
		&streamed_scorers,
		boundary_data[:],
		64,
		&streamed_records,
	)
	self_test_expect(
		&failures,
		streamed_windows == scan_window_count(boundary_data[:]),
		"streaming overlap scans every window exactly once",
	)
	self_test_expect(
		&failures,
		candidate_equal(whole_best, streamed_best),
		"streamed best matches whole input",
	)
	self_test_expect(
		&failures,
		candidate_records_equal(whole_records[:], streamed_records[:]),
		"streamed record sequence matches whole input",
	)

	parallel_registry: Scorer_Registry
	parallel_baseline_scorers, parallel_baseline_error, _ := parse_scorer_set(
		&parallel_registry,
		"language=1,compression=0.25",
	)
	self_test_expect(
		&failures,
		parallel_baseline_error == .None,
		"parallel baseline scorers parse",
	)
	parallel_baseline_records := make([dynamic]Candidate, 0, 16)
	parallel_initial := Candidate {
		score = -1.0e300,
	}
	parallel_baseline_best := scan_chunk(
		&parallel_baseline_scorers,
		boundary_data[:],
		0,
		parallel_initial,
		&parallel_baseline_records,
	)

	parallel_scanner: Parallel_Scanner
	parallel_error, _ := parallel_scanner_init(&parallel_scanner, "language=1,compression=0.25", 4)
	self_test_expect(&failures, parallel_error == .None, "parallel scanner initializes")
	parallel_records := make([dynamic]Candidate, 0, 16)
	if parallel_error == .None {
		parallel_best := parallel_scan_chunk(
			&parallel_scanner,
			boundary_data[:],
			0,
			parallel_initial,
			&parallel_records,
		)
		self_test_expect(
			&failures,
			candidate_equal(parallel_baseline_best, parallel_best),
			"parallel best matches sequential best",
		)
		self_test_expect(
			&failures,
			candidate_records_equal(parallel_baseline_records[:], parallel_records[:]),
			"parallel record sequence matches sequential order",
		)
		parallel_scanner_destroy(&parallel_scanner)
	}

	delete(whole_records)
	delete(streamed_records)
	delete(parallel_baseline_records)
	delete(parallel_records)

	if failures == 0 {
		fmt.println("self-test: ok")
		return true
	}
	fmt.eprintf("self-test: %d failure(s)\n", failures)
	return false
}
