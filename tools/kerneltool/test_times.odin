package kerneltool

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"

// The times of a test: where the time of `kerneltool test` goes. The tool
// reads the monotonic clock of the host at the start and at the end of the
// build, of each machine and of each step, and writes one line for each
// step in a file. Each number is a measure: no test reads one, and nothing
// fails because of a time (docs/TOOLS.md, "The times of a test").

TEST_TIMES_FILE :: BUILD_FOLDER + "/test_times.txt"
// The bytes of the text of a step that a record keeps: enough to know the
// step, and a line of the file stays short.
TEST_TIMES_TEXT_BYTES :: 60
TEST_TIMES_SLOWEST_COUNT :: 25

// The parts of the time of one picture of the screen (screen_save).
Picture_Time :: struct {
	settle:     time.Duration, // The fixed wait before the tool asks QEMU for the picture.
	dump:       time.Duration, // From the command `screendump` to its reply: QEMU wrote the whole file.
	read:       time.Duration, // The read of the file and the check of its header.
	conversion: time.Duration, // The encoding of the PNG, on a worker thread: not a part of the time of the step.
	write:      time.Duration, // The write of the PNG file, on the same worker thread.
}

// The time of one step of a scenario.
Step_Time :: struct {
	machine:  int, // The place of its machine in the list of the machines of the run.
	number:   int, // The number of the step in its scenario, from 1.
	kind:     Step_Kind,
	text:     string, // The start of the text of the step.
	duration: time.Duration,
	waited:   time.Duration, // The part of the duration that the step waited for a line of the log.
	keys:     int, // The keys that the step sent.
	key_time: time.Duration, // The time in the sends of these keys, with the wait after each send.
	pictures: int,
	picture:  Picture_Time,
}

// The time of one machine of a test.
Machine_Time :: struct {
	output:          string, // The file of its log: it names the machine.
	passed:          bool,
	whole:           time.Duration, // From the call of machine_test to its end.
	first_line_seen: bool,
	first_line:      time.Duration, // From the start of QEMU to the first whole line of the log.
	steps:           time.Duration, // The run of the scenario.
	stop:            time.Duration, // From the end of the scenario to the end of machine_test.
}

// What a machine notes while it runs a step (the field `times` of Machine).
Machine_Step_Times :: struct {
	current:         Step_Time, // The step that runs now.
	first_line_seen: bool,
	first_line:      time.Duration,
}

Test_Times :: struct {
	build:    time.Duration,
	steps:    [dynamic]Step_Time,
	machines: [dynamic]Machine_Time,
}

// The times of this process: one test run.
test_times: Test_Times

Kind_Time :: struct {
	count:    int,
	duration: time.Duration,
}

Program_Wait :: struct {
	program: string,
	count:   int,
	waited:  time.Duration,
}

Test_Times_Summary :: struct {
	kinds:          [Step_Kind]Kind_Time,
	steps_duration: time.Duration,
	slowest:        []int, // The places of the slowest records, the slowest first; two equal durations keep the order of the run.
	keys:           int,
	key_time:       time.Duration,
	pictures:       int,
	picture:        Picture_Time,
	waited:         time.Duration,
	programs:       []Program_Wait, // The most waited first.
}

// step_kind_waits_for_a_line says if the text of a step of this kind is a
// text of the log that the step waits for.
step_kind_waits_for_a_line :: proc(kind: Step_Kind) -> bool {
	#partial switch kind {
	case .Wait, .Date, .Generation, .Trace, .Remember, .Quic_Key, .Remote_Key:
		return true
	}
	return false
}

// program_of_a_log_text gives the name of the program that writes a line
// of the log: the first word of the text before its first ":" ("clock" of
// "clock: ok", "[console]" of "[console] settings: 3 commands"). A text
// with no word gives "(no name)".
program_of_a_log_text :: proc(text: string) -> string {
	before := text
	if colon := strings.index_byte(before, ':'); colon >= 0 {
		before = before[:colon]
	}
	before = strings.trim_left(before, " \t")
	if space := strings.index_any(before, " \t"); space >= 0 {
		before = before[:space]
	}
	return before == "" ? "(no name)" : before
}

// text_first_bytes gives the first bytes of a text, at most limit, and never a
// part of a character of several bytes.
text_first_bytes :: proc(text: string, limit: int) -> string {
	if len(text) <= limit {
		return text
	}
	end := limit
	for end > 0 && text[end] & 0xC0 == 0x80 {
		end -= 1
	}
	return text[:end]
}

@(private = "file")
Record_Place :: struct {
	place:    int,
	duration: time.Duration,
}

// test_times_summary gives the sums of a list of step records. Its memory
// is of the temporary allocator.
test_times_summary :: proc(records: []Step_Time, slowest_count := TEST_TIMES_SLOWEST_COUNT) -> Test_Times_Summary {
	summary: Test_Times_Summary
	places := make([]Record_Place, len(records), context.temp_allocator)
	programs := make([dynamic]Program_Wait, context.temp_allocator)
	for record, place in records {
		places[place] = {place, record.duration}
		summary.kinds[record.kind].count += 1
		summary.kinds[record.kind].duration += record.duration
		summary.steps_duration += record.duration
		summary.keys += record.keys
		summary.key_time += record.key_time
		summary.pictures += record.pictures
		summary.picture.settle += record.picture.settle
		summary.picture.dump += record.picture.dump
		summary.picture.read += record.picture.read
		summary.picture.conversion += record.picture.conversion
		summary.picture.write += record.picture.write
		summary.waited += record.waited
		if !step_kind_waits_for_a_line(record.kind) {
			continue
		}
		name := program_of_a_log_text(record.text)
		known := false
		for &program in programs {
			if program.program == name {
				program.count += 1
				program.waited += record.waited
				known = true
				break
			}
		}
		if !known {
			append(&programs, Program_Wait{program = name, count = 1, waited = record.waited})
		}
	}
	// A stable sort: two equal durations keep the order of the run.
	slice.stable_sort_by(places, proc(first, second: Record_Place) -> bool {
		return first.duration > second.duration
	})
	slowest := make([]int, min(slowest_count, len(records)), context.temp_allocator)
	for &place, index in slowest {
		place = places[index].place
	}
	summary.slowest = slowest
	slice.stable_sort_by(programs[:], proc(first, second: Program_Wait) -> bool {
		return first.waited > second.waited
	})
	summary.programs = programs[:]
	return summary
}

// test_times_step_start starts the record of a step of a machine.
test_times_step_start :: proc(machine: ^Machine) {
	machine.times.current = {}
}

// test_times_step_end ends the record of a step: the scenario calls it
// when the step ends, with a pass or with a failure.
test_times_step_end :: proc(machine: ^Machine, index: int, step: Step, started: time.Tick) {
	record := machine.times.current
	record.machine = len(test_times.machines)
	record.number = index + 1
	record.kind = step.kind
	// A copy: the text of a step can be of the temporary allocator.
	record.text = strings.clone(text_first_bytes(step.text, TEST_TIMES_TEXT_BYTES))
	record.duration = time.tick_since(started)
	append(&test_times.steps, record)
}

// test_times_wait_note adds a wait for a line of the log to the step that
// runs.
test_times_wait_note :: proc(machine: ^Machine, started: time.Tick) {
	machine.times.current.waited += time.tick_since(started)
}

// test_times_keys_note adds the keys of one send to the step that runs:
// their count, and the time of the send with its wait.
test_times_keys_note :: proc(machine: ^Machine, count: int, started: time.Tick) {
	machine.times.current.keys += count
	machine.times.current.key_time += time.tick_since(started)
}

// test_times_picture_note adds one picture to the step that runs.
test_times_picture_note :: proc(machine: ^Machine, picture: Picture_Time) {
	current := &machine.times.current
	current.pictures += 1
	current.picture.settle += picture.settle
	current.picture.dump += picture.dump
	current.picture.read += picture.read
	current.picture.conversion += picture.conversion
	current.picture.write += picture.write
}

// test_times_picture_worker_note adds the time of the conversion and of
// the write of one picture, which a worker thread did while the scenario
// went on, to the record of the step of the picture. A picture outside a
// step has no record.
test_times_picture_worker_note :: proc(step_place: int, conversion, write: time.Duration) {
	if step_place < len(test_times.steps) {
		test_times.steps[step_place].picture.conversion += conversion
		test_times.steps[step_place].picture.write += write
	}
}

// test_times_first_line_note notes when the log of a machine has its first
// whole line: the tool sees it at the first read of the log that finds it,
// so the time is late by one period of the poll at most.
test_times_first_line_note :: proc(machine: ^Machine, log_bytes: int) {
	if log_bytes > 0 && !machine.times.first_line_seen {
		machine.times.first_line_seen = true
		machine.times.first_line = time.tick_since(machine.started_at)
	}
}

// test_times_machine_end records the time of a machine that ended.
test_times_machine_end :: proc(machine: ^Machine, passed: bool, started, scenario_started, scenario_ended: time.Tick) {
	append(
		&test_times.machines,
		Machine_Time {
			output = strings.clone(machine.output),
			passed = passed,
			whole = time.tick_since(started),
			first_line_seen = machine.times.first_line_seen,
			first_line = machine.times.first_line,
			steps = time.tick_diff(scenario_started, scenario_ended),
			stop = time.tick_since(scenario_ended),
		},
	)
}

@(private = "file")
seconds_of :: proc(duration: time.Duration) -> f64 {
	return time.duration_seconds(duration)
}

// test_times_file_text gives the text of the file of the times: for each
// machine one line, then one line for each of its steps, in the order of
// the run, in fixed columns.
test_times_file_text :: proc(times: ^Test_Times, whole: time.Duration) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "The times of one test run, on the monotonic clock of the host. Each number is a measure, in seconds.\n")
	fmt.sbprintf(&b, "whole %.3f, build %.3f, %d machines, %d steps\n", seconds_of(whole), seconds_of(times.build), len(times.machines), len(times.steps))
	next := 0
	for machine, place in times.machines {
		first_line := machine.first_line_seen ? fmt.tprintf("%.3f", seconds_of(machine.first_line)) : "none"
		fmt.sbprintf(&b, "\nmachine %s: %s, whole %.3f, from the start of QEMU to the first line of the log %s, the steps %.3f, the stop %.3f\n", machine.output, machine.passed ? "passed" : "failed", seconds_of(machine.whole), first_line, seconds_of(machine.steps), seconds_of(machine.stop))
		fmt.sbprintf(&b, "%6s %-12s %9s %9s %5s %9s %8s  %s\n", "step", "kind", "duration", "waited", "keys", "key_time", "pictures", "text")
		for next < len(times.steps) && times.steps[next].machine == place {
			record := times.steps[next]
			fmt.sbprintf(&b, "%6d %-12s %9.3f %9.3f %5d %9.3f %8d  %s\n", record.number, fmt.tprintf("%v", record.kind), seconds_of(record.duration), seconds_of(record.waited), record.keys, seconds_of(record.key_time), record.pictures, record.text)
			next += 1
		}
	}
	return strings.to_string(b)
}

// test_times_build_end records the time of the build of a test.
test_times_build_end :: proc(started: time.Tick) {
	test_times.build = time.tick_since(started)
}

// test_times_report writes the file of the times and prints the summary,
// at the end of a test that ran a machine, passed or failed. It never
// fails the test: each number is a measure.
test_times_report :: proc(started: time.Tick) {
	if len(test_times.machines) == 0 {
		return
	}
	whole := time.tick_since(started)
	if write_error := os.write_entire_file(TEST_TIMES_FILE, test_times_file_text(&test_times, whole)); write_error != nil {
		fmt.eprintfln("kerneltool: cannot write %s: %v", TEST_TIMES_FILE, write_error)
	}
	machines_whole, first_lines, stops: time.Duration
	for machine in test_times.machines {
		machines_whole += machine.whole
		first_lines += machine.first_line
		stops += machine.stop
	}
	summary := test_times_summary(test_times.steps[:])
	fmt.printfln("kerneltool: measure: the times of the test, on the clock of the host (each step is in %s):", TEST_TIMES_FILE)
	fmt.printfln("kerneltool: measure: the whole test %.1f s; the build %.1f s; %d machines %.1f s (from the start of QEMU to the first line of the log %.1f s, %d steps %.1f s, the stops %.1f s)", seconds_of(whole), seconds_of(test_times.build), len(test_times.machines), seconds_of(machines_whole), seconds_of(first_lines), len(test_times.steps), seconds_of(summary.steps_duration), seconds_of(stops))
	for kind_time, kind in summary.kinds {
		if kind_time.count > 0 {
			fmt.printfln("kerneltool: measure: the steps %-12s %5d steps, %8.1f s", fmt.tprintf("%v", kind), kind_time.count, seconds_of(kind_time.duration))
		}
	}
	fmt.printfln("kerneltool: measure: %d keys sent, %.1f s in the sends of keys, with the wait after each send", summary.keys, seconds_of(summary.key_time))
	fmt.printfln("kerneltool: measure: %d pictures, %.1f s in their steps: the fixed wait before each %.1f s, the screendump of QEMU %.1f s, the read of the file %.1f s; on worker threads, while the scenario goes on: the conversion to PNG %.1f s, the write %.1f s", summary.pictures, seconds_of(summary.picture.settle + summary.picture.dump + summary.picture.read), seconds_of(summary.picture.settle), seconds_of(summary.picture.dump), seconds_of(summary.picture.read), seconds_of(summary.picture.conversion), seconds_of(summary.picture.write))
	fmt.printfln("kerneltool: measure: %.1f s waited for lines of the log, by the program of the line:", seconds_of(summary.waited))
	for program in summary.programs {
		fmt.printfln("kerneltool: measure:     %8.1f s, %4d lines: %s", seconds_of(program.waited), program.count, program.program)
	}
	fmt.printfln("kerneltool: measure: the %d slowest steps:", len(summary.slowest))
	for place in summary.slowest {
		record := test_times.steps[place]
		fmt.printfln("kerneltool: measure:     %8.1f s, step %4d of %s, %v: %s", seconds_of(record.duration), record.number, test_times.machines[record.machine].output, record.kind, record.text)
	}
}
