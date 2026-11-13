package kerneltool

import "core:strings"
import "core:testing"
import "core:time"

// A list of step records made by hand: two machines, with waits, typed
// lines, a picture and a launch.
@(private = "file")
hand_made_records :: proc() -> [8]Step_Time {
	return {
		{machine = 0, number = 1, kind = .Wait, text = "compositor: surface console", duration = 3 * time.Second, waited = 3 * time.Second},
		{machine = 0, number = 2, kind = .Type, text = "start(\"clock\")", duration = 2 * time.Second, keys = 15, key_time = 1900 * time.Millisecond},
		{machine = 0, number = 3, kind = .Wait, text = "clock: ok, 4 cases", duration = 5 * time.Second, waited = 5 * time.Second},
		{machine = 0, number = 4, kind = .Shot, text = "clock", duration = 700 * time.Millisecond, pictures = 1, picture = {settle = 400 * time.Millisecond, dump = 100 * time.Millisecond, read = 10 * time.Millisecond, conversion = 150 * time.Millisecond, write = 40 * time.Millisecond}},
		{machine = 0, number = 5, kind = .Wait, text = "[console] settings: 3 commands of a service that runs", duration = 2 * time.Second, waited = 2 * time.Second},
		{machine = 1, number = 1, kind = .Wait, text = "clock: the date of the machine ", duration = 5 * time.Second, waited = 4 * time.Second},
		{machine = 1, number = 2, kind = .Launch, text = "clock", duration = 5 * time.Second},
		{machine = 1, number = 3, kind = .Key, text = "ret", duration = 100 * time.Millisecond, keys = 1, key_time = 100 * time.Millisecond},
	}
}

// The summary adds the durations and counts the steps of each kind.
@(test)
times_summary_adds_the_durations_by_kind :: proc(t: ^testing.T) {
	records := hand_made_records()
	summary := test_times_summary(records[:])
	testing.expect_value(t, summary.kinds[.Wait], Kind_Time{count = 4, duration = 15 * time.Second})
	testing.expect_value(t, summary.kinds[.Type], Kind_Time{count = 1, duration = 2 * time.Second})
	testing.expect_value(t, summary.kinds[.Shot], Kind_Time{count = 1, duration = 700 * time.Millisecond})
	testing.expect_value(t, summary.kinds[.Launch], Kind_Time{count = 1, duration = 5 * time.Second})
	testing.expect_value(t, summary.kinds[.Key], Kind_Time{count = 1, duration = 100 * time.Millisecond})
	testing.expect_value(t, summary.kinds[.Call], Kind_Time{})
	testing.expect_value(t, summary.steps_duration, 22800 * time.Millisecond)
	testing.expect_value(t, summary.keys, 16)
	testing.expect_value(t, summary.key_time, 2 * time.Second)
	testing.expect_value(t, summary.pictures, 1)
	testing.expect_value(t, summary.picture, Picture_Time{settle = 400 * time.Millisecond, dump = 100 * time.Millisecond, read = 10 * time.Millisecond, conversion = 150 * time.Millisecond, write = 40 * time.Millisecond})
	testing.expect_value(t, summary.waited, 14 * time.Second)
}

// The slowest steps come first, and two steps of the same duration keep
// the order of the run.
@(test)
times_summary_orders_the_slowest_steps :: proc(t: ^testing.T) {
	records := hand_made_records()
	summary := test_times_summary(records[:], 4)
	testing.expect_value(t, len(summary.slowest), 4)
	// Three steps of 5 s, in the order of the run, then the step of 3 s.
	testing.expect_value(t, summary.slowest[0], 2)
	testing.expect_value(t, summary.slowest[1], 5)
	testing.expect_value(t, summary.slowest[2], 6)
	testing.expect_value(t, summary.slowest[3], 0)
	// A list shorter than the count gives each of its records.
	all := test_times_summary(records[:2])
	testing.expect_value(t, len(all.slowest), 2)
	testing.expect_value(t, all.slowest[0], 0)
	testing.expect_value(t, all.slowest[1], 1)
	none := test_times_summary(nil)
	testing.expect_value(t, len(none.slowest), 0)
	testing.expect_value(t, len(none.programs), 0)
}

// The waits are added by the program of the line, the most waited first;
// a step that waits for no line of the log is not a wait of a program.
@(test)
times_summary_adds_the_waits_by_program :: proc(t: ^testing.T) {
	records := hand_made_records()
	summary := test_times_summary(records[:])
	testing.expect_value(t, len(summary.programs), 3)
	testing.expect_value(t, summary.programs[0], Program_Wait{program = "clock", count = 2, waited = 9 * time.Second})
	testing.expect_value(t, summary.programs[1], Program_Wait{program = "compositor", count = 1, waited = 3 * time.Second})
	testing.expect_value(t, summary.programs[2], Program_Wait{program = "[console]", count = 1, waited = 2 * time.Second})
}

// The program of a line is the first word of its text before the first ":".
@(test)
program_name_is_the_first_word_before_the_colon :: proc(t: ^testing.T) {
	testing.expect_value(t, program_of_a_log_text("clock: ok, 4 cases"), "clock")
	testing.expect_value(t, program_of_a_log_text("scheduler: strategy fair: 3 threads"), "scheduler")
	testing.expect_value(t, program_of_a_log_text("[console] settings: 3 commands"), "[console]")
	testing.expect_value(t, program_of_a_log_text("[console] 18"), "[console]")
	testing.expect_value(t, program_of_a_log_text("boot program: the firmware has no TPM protocol"), "boot")
	testing.expect_value(t, program_of_a_log_text("   threads     "), "threads")
	testing.expect_value(t, program_of_a_log_text(""), "(no name)")
	testing.expect_value(t, program_of_a_log_text(": no name"), "(no name)")
}

// The start of a text never ends inside a character of several bytes.
@(test)
text_first_bytes_keeps_whole_characters :: proc(t: ^testing.T) {
	testing.expect_value(t, text_first_bytes("clock", 60), "clock")
	testing.expect_value(t, text_first_bytes("clock: ok", 5), "clock")
	testing.expect_value(t, text_first_bytes("cafés", 4), "caf")
	testing.expect_value(t, text_first_bytes("cafés", 5), "café")
}

// The file has one line for each step, in the order of the run, under the
// line of its machine.
@(test)
times_file_keeps_the_order_of_the_run :: proc(t: ^testing.T) {
	records := hand_made_records()
	times: Test_Times
	defer delete(times.steps)
	defer delete(times.machines)
	append(&times.steps, ..records[:])
	append(&times.machines, Machine_Time{output = "build/first.txt", passed = true, whole = 14 * time.Second, first_line_seen = true, first_line = 1500 * time.Millisecond}, Machine_Time{output = "build/second.txt", passed = false, whole = 11 * time.Second})
	times.build = 60 * time.Second
	text := test_times_file_text(&times, 90 * time.Second)
	first_machine := strings.index(text, "machine build/first.txt: passed, whole 14.000, from the start of QEMU to the first line of the log 1.500,")
	second_machine := strings.index(text, "machine build/second.txt: failed, whole 11.000, from the start of QEMU to the first line of the log none,")
	slow_wait := strings.index(text, "     3 Wait             5.000     5.000     0     0.000        0  clock: ok, 4 cases\n")
	typed := strings.index(text, "     2 Type             2.000     0.000    15     1.900        0  start(\"clock\")\n")
	launch := strings.index(text, "     2 Launch           5.000     0.000     0     0.000        0  clock\n")
	testing.expect(t, strings.contains(text, "whole 90.000, build 60.000, 2 machines, 8 steps\n"))
	testing.expect(t, first_machine >= 0, "the line of the first machine")
	testing.expect(t, typed > first_machine, "the typed line is under the first machine")
	testing.expect(t, slow_wait > typed, "the steps keep the order of the run")
	testing.expect(t, second_machine > slow_wait, "the second machine comes after the steps of the first")
	testing.expect(t, launch > second_machine, "the launch is under the second machine")
}
