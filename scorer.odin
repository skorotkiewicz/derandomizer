package main

import "core:math"
import "core:strconv"
import "core:strings"

Score_Proc :: #type proc(state: rawptr, data: []u8) -> f64

Scorer :: struct {
	name:      string,
	procedure: Score_Proc,
	state:     rawptr,
}

Weighted_Scorer :: struct {
	scorer: Scorer,
	weight: f64,
}

MAX_SCORERS :: 8

Scorer_Set :: struct {
	items: [MAX_SCORERS]Weighted_Scorer,
	count: int,
}

Scorer_Registry :: struct {
	compression: Compression_State,
}

Scorer_Spec_Error :: enum {
	None,
	Empty_Spec,
	Empty_Item,
	Empty_Name,
	Invalid_Weight,
	Unknown_Scorer,
	Duplicate_Scorer,
	Too_Many_Scorers,
}

lookup_scorer :: proc(registry: ^Scorer_Registry, name: string) -> (Scorer, bool) {
	switch name {
	case "language":
		return Scorer{name = "language", procedure = language_score_proc}, true
	case "compression":
		return Scorer {
				name = "compression",
				procedure = compression_score_proc,
				state = &registry.compression,
			},
			true
	}
	return {}, false
}

parse_scorer_set :: proc(
	registry: ^Scorer_Registry,
	spec: string,
) -> (
	Scorer_Set,
	Scorer_Spec_Error,
	string,
) {
	result: Scorer_Set
	spec := strings.trim_space(spec)
	if len(spec) == 0 {
		return result, .Empty_Spec, spec
	}
	if spec[0] == ',' || spec[len(spec) - 1] == ',' {
		return result, .Empty_Item, spec
	}

	remainder := spec
	for raw_item in strings.split_by_byte_iterator(&remainder, ',') {
		item := strings.trim_space(raw_item)
		if len(item) == 0 {
			return result, .Empty_Item, raw_item
		}

		name := item
		weight := 1.0
		if separator := strings.index_byte(item, '='); separator >= 0 {
			name = strings.trim_space(item[:separator])
			weight_text := strings.trim_space(item[separator + 1:])
			if len(name) == 0 {
				return result, .Empty_Name, item
			}
			parsed_weight, ok := strconv.parse_f64(weight_text)
			if !ok ||
			   parsed_weight <= 0 ||
			   math.is_nan(parsed_weight) ||
			   math.is_inf(parsed_weight, 0) {
				return result, .Invalid_Weight, weight_text
			}
			weight = parsed_weight
		}

		if len(name) == 0 {
			return result, .Empty_Name, item
		}
		scorer, found := lookup_scorer(registry, name)
		if !found {
			return result, .Unknown_Scorer, name
		}
		for existing in result.items[:result.count] {
			if existing.scorer.name == scorer.name {
				return result, .Duplicate_Scorer, name
			}
		}
		if result.count == len(result.items) {
			return result, .Too_Many_Scorers, name
		}

		result.items[result.count] = Weighted_Scorer {
			scorer = scorer,
			weight = weight,
		}
		result.count += 1
	}

	if result.count == 0 {
		return result, .Empty_Spec, spec
	}
	return result, .None, ""
}

score_with :: proc(scorer: Scorer, data: []u8) -> f64 {
	return scorer.procedure(scorer.state, data)
}

score_with_set :: proc(scorers: ^Scorer_Set, data: []u8) -> f64 {
	total := 0.0
	for item in scorers.items[:scorers.count] {
		total += item.weight * score_with(item.scorer, data)
	}
	return total
}
