package main

import "core:fmt"
import "core:strconv"
import "core:strings"

Run_Mode :: enum {
	Search,
	Self_Test,
	Help,
}

Options :: struct {
	mode:        Run_Mode,
	scorer_spec: string,
	threads:     int,
}

Options_Error :: enum {
	None,
	Unknown_Argument,
	Missing_Scorer_Spec,
	Duplicate_Scorer_Option,
	Missing_Thread_Count,
	Duplicate_Threads_Option,
	Invalid_Thread_Count,
}

parse_options :: proc(args: []string) -> (Options, Options_Error, string) {
	options := Options {
		mode        = .Search,
		scorer_spec = "language",
	}
	scorer_seen := false
	threads_seen := false

	for index := 0; index < len(args); index += 1 {
		argument := args[index]
		switch {
		case argument == "--help" || argument == "-h":
			options.mode = .Help
		case argument == "--self-test":
			options.mode = .Self_Test
		case argument == "--scorer":
			if scorer_seen {
				return options, .Duplicate_Scorer_Option, argument
			}
			if index + 1 >= len(args) {
				return options, .Missing_Scorer_Spec, argument
			}
			index += 1
			options.scorer_spec = args[index]
			scorer_seen = true
		case strings.has_prefix(argument, "--scorer="):
			if scorer_seen {
				return options, .Duplicate_Scorer_Option, argument
			}
			options.scorer_spec = argument[len("--scorer="):]
			scorer_seen = true
		case argument == "--threads":
			if threads_seen {
				return options, .Duplicate_Threads_Option, argument
			}
			if index + 1 >= len(args) {
				return options, .Missing_Thread_Count, argument
			}
			index += 1
			thread_count, ok := strconv.parse_int(args[index])
			if !ok || thread_count < 0 || thread_count > MAX_THREADS {
				return options, .Invalid_Thread_Count, args[index]
			}
			options.threads = thread_count
			threads_seen = true
		case strings.has_prefix(argument, "--threads="):
			if threads_seen {
				return options, .Duplicate_Threads_Option, argument
			}
			value := argument[len("--threads="):]
			thread_count, ok := strconv.parse_int(value)
			if !ok || thread_count < 0 || thread_count > MAX_THREADS {
				return options, .Invalid_Thread_Count, value
			}
			options.threads = thread_count
			threads_seen = true
		case:
			return options, .Unknown_Argument, argument
		}
	}

	return options, .None, ""
}

print_usage :: proc(program: string) {
	fmt.printf("usage: %s [--scorer SPEC] [--threads N]\n", program)
	fmt.printf("       %s --self-test\n", program)
	fmt.println()
	fmt.println("options:")
	fmt.println("  --scorer SPEC  language=1,compression=2")
	fmt.printf("  --threads N    worker threads; 0 = auto, maximum %d (default: 0)\n", MAX_THREADS)
	fmt.println()
	fmt.println("scorers:")
	fmt.println("  language     English-like text heuristic (default)")
	fmt.println("  compression  allocation-free LZSS compression gain")
}

print_options_error :: proc(kind: Options_Error, detail: string) {
	switch kind {
	case .Unknown_Argument:
		fmt.eprintf("derandomizer: unknown argument %q\n", detail)
	case .Missing_Scorer_Spec:
		fmt.eprintf("derandomizer: %s requires a scorer specification\n", detail)
	case .Duplicate_Scorer_Option:
		fmt.eprintln("derandomizer: --scorer may only be provided once")
	case .Missing_Thread_Count:
		fmt.eprintf("derandomizer: %s requires a thread count\n", detail)
	case .Duplicate_Threads_Option:
		fmt.eprintln("derandomizer: --threads may only be provided once")
	case .Invalid_Thread_Count:
		fmt.eprintf(
			"derandomizer: invalid thread count %q; expected an integer from 0 to %d\n",
			detail,
			MAX_THREADS,
		)
	case .None:
	}
}

print_scorer_spec_error :: proc(kind: Scorer_Spec_Error, detail: string) {
	switch kind {
	case .Empty_Spec:
		fmt.eprintln("derandomizer: scorer specification cannot be empty")
	case .Empty_Item:
		fmt.eprintln("derandomizer: scorer specification contains an empty item")
	case .Empty_Name:
		fmt.eprintln("derandomizer: scorer name cannot be empty")
	case .Invalid_Weight:
		fmt.eprintf(
			"derandomizer: invalid scorer weight %q; weights must be positive and finite\n",
			detail,
		)
	case .Unknown_Scorer:
		fmt.eprintf(
			"derandomizer: unknown scorer %q; available scorers: language, compression\n",
			detail,
		)
	case .Duplicate_Scorer:
		fmt.eprintf("derandomizer: scorer %q is listed more than once\n", detail)
	case .Too_Many_Scorers:
		fmt.eprintf("derandomizer: at most %d scorers may be combined\n", MAX_SCORERS)
	case .None:
	}
}
