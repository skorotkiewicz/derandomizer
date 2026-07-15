package main

import "core:mem"
import "core:sync"
import sysinfo "core:sys/info"
import "core:thread"

MAX_THREADS :: 256

Parallel_Scanner :: struct {
	pool:         thread.Pool,
	wait_group:   sync.Wait_Group,
	tasks:        []Parallel_Scan_Task,
	allocator:    mem.Allocator,
	thread_count: int,
	initialized:  bool,
}

Parallel_Scan_Task :: struct {
	owner:        ^Parallel_Scanner,
	registry:     Scorer_Registry,
	scorers:      Scorer_Set,
	data:         []u8,
	base_offset:  u64,
	first_window: int,
	window_count: int,
	initial_best: Candidate,
	best:         Candidate,
	records:      [dynamic]Candidate,
}

resolve_thread_count :: proc(requested: int) -> int {
	if requested > 0 {
		return requested
	}
	_, logical, ok := sysinfo.cpu_core_count()
	if !ok || logical < 1 {
		return 1
	}
	return min(logical, MAX_THREADS)
}

scan_window_count :: proc(data: []u8) -> int {
	if len(data) < WINDOW {
		return 0
	}
	return (len(data) - WINDOW) / STRIDE + 1
}

parallel_scan_task_proc :: proc(pool_task: thread.Task) {
	task := (^Parallel_Scan_Task)(pool_task.data)
	defer sync.wait_group_done(&task.owner.wait_group)
	task.best = scan_range(
		&task.scorers,
		task.data,
		task.base_offset,
		task.first_window,
		task.window_count,
		task.initial_best,
		&task.records,
	)
}

parallel_scanner_init :: proc(
	scanner: ^Parallel_Scanner,
	scorer_spec: string,
	thread_count: int,
	allocator := context.allocator,
) -> (
	Scorer_Spec_Error,
	string,
) {
	assert(thread_count > 1 && thread_count <= MAX_THREADS)
	scanner.allocator = allocator
	scanner.thread_count = thread_count
	scanner.tasks = make([]Parallel_Scan_Task, thread_count, allocator)

	for &task in scanner.tasks {
		task.owner = scanner
		task.records = make([dynamic]Candidate, 0, 16, allocator)
		scorers, scorer_error, scorer_detail := parse_scorer_set(&task.registry, scorer_spec)
		if scorer_error != .None {
			for &initialized_task in scanner.tasks {
				delete(initialized_task.records)
			}
			delete(scanner.tasks, allocator)
			scanner^ = {}
			return scorer_error, scorer_detail
		}
		task.scorers = scorers
	}

	thread.pool_init(&scanner.pool, allocator, thread_count)
	thread.pool_start(&scanner.pool)
	scanner.initialized = true
	return .None, ""
}

parallel_scanner_destroy :: proc(scanner: ^Parallel_Scanner) {
	if scanner.initialized {
		thread.pool_finish(&scanner.pool)
		thread.pool_destroy(&scanner.pool)
	}
	for &task in scanner.tasks {
		delete(task.records)
	}
	delete(scanner.tasks, scanner.allocator)
	scanner^ = {}
}

parallel_scan_chunk :: proc(
	scanner: ^Parallel_Scanner,
	data: []u8,
	base_offset: u64,
	initial_best: Candidate,
	records: ^[dynamic]Candidate,
) -> Candidate {
	window_count := scan_window_count(data)
	if window_count == 0 {
		return initial_best
	}
	task_count := min(scanner.thread_count, window_count)

	sync.wait_group_add(&scanner.wait_group, task_count)
	for task_index := 0; task_index < task_count; task_index += 1 {
		task := &scanner.tasks[task_index]
		clear(&task.records)
		task.data = data
		task.base_offset = base_offset
		task.first_window = task_index * window_count / task_count
		next_first_window := (task_index + 1) * window_count / task_count
		task.window_count = next_first_window - task.first_window
		task.initial_best = initial_best
		thread.pool_add_task(
			&scanner.pool,
			scanner.allocator,
			parallel_scan_task_proc,
			task,
			task_index,
		)
	}

	sync.wait_group_wait(&scanner.wait_group)
	completed := 0
	for completed < task_count {
		if _, ok := thread.pool_pop_done(&scanner.pool); ok {
			completed += 1
		} else {
			thread.yield()
		}
	}

	best := initial_best
	for task in scanner.tasks[:task_count] {
		for candidate in task.records {
			if candidate.score > best.score {
				best = candidate
				append(records, candidate)
			}
		}
	}
	return best
}

scan_range :: proc(
	scorers: ^Scorer_Set,
	data: []u8,
	base_offset: u64,
	first_window: int,
	window_count: int,
	initial_best: Candidate,
	records: ^[dynamic]Candidate,
) -> Candidate {
	best := initial_best
	decoded: [WINDOW]u8
	scan_xor := scorer_set_requires_decoder(scorers, .Xor)
	scan_add := scorer_set_requires_decoder(scorers, .Add)

	for window_index := first_window;
	    window_index < first_window + window_count;
	    window_index += 1 {
		start := window_index * STRIDE
		src := data[start:start + WINDOW]
		offset := base_offset + u64(start)

		decode_raw(src, decoded[:])
		if consider(&best, scorers, decoded[:], offset, .Raw, 0) {
			append(records, best)
		}

		if scan_xor || scan_add {
			for key := 1; key < 256; key += 1 {
				k := u8(key)

				if scan_xor {
					decode_xor(src, decoded[:], k)
					if consider(&best, scorers, decoded[:], offset, .Xor, k) {
						append(records, best)
					}
				}

				if scan_add {
					decode_add(src, decoded[:], k)
					if consider(&best, scorers, decoded[:], offset, .Add, k) {
						append(records, best)
					}
				}
			}
		}

		decode_alphabet64(src, decoded[:])
		if consider(&best, scorers, decoded[:], offset, .Alphabet64, 0) {
			append(records, best)
		}
	}

	return best
}

scan_chunk :: proc(
	scorers: ^Scorer_Set,
	data: []u8,
	base_offset: u64,
	initial_best: Candidate,
	records: ^[dynamic]Candidate,
) -> Candidate {
	return scan_range(
		scorers,
		data,
		base_offset,
		0,
		scan_window_count(data),
		initial_best,
		records,
	)
}
