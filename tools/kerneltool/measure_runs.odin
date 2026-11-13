package kerneltool

import "core:fmt"
import "core:os"
import "core:strings"

// The measure runs of the programs
// (docs/TOOLS.md, "A check by count, a measure by time").
//
// A program that measures a rate over a duration does so only in a measure
// run: a machine whose boot image holds the resource `measure_run`. The
// root service then writes 1 in the value of the context for it, in each
// program that it starts. The modules are the modules of the test: only
// the boot image differs. In a test, the same program runs its checks,
// which end after a count of work.

// One program that measures itself in a measure run, with no other program
// than the desktop.
Measure_Program :: struct {
	name:  string,
	lines: [2]string, // Parts of the lines of its measures that the scenario waits for, in the order of the log: only a measure run writes them. "": none.
	done:  string, // The last line of the program: its checks passed, in a measure run too.
}

@(rodata)
measure_programs := [?]Measure_Program {
	{name = "clock", lines = {"clock: the time page: ", " reads in one second, 0 kernel entries for one million reads"}, done = "clock: ok, the time never went back, the page and the kernel give the same time, the kernel refuses to remove the time page"},
	{name = "crowd", lines = {"crowd: shared queue, 1 writers, 1 readers: ", " records in one second, "}, done = "crowd: ok, 5 runs, each record written is read one time, each event started all the threads"},
	{name = "disk", lines = {"disk: read, 1 block in each request, 32 in flight: ", " blocks in one second, kernel entries for 100 requests: "}, done = "disk: ok, 5 runs, 0 errors, write then read back: 0 wrong"},
	{name = "flow", lines = {"flow: capacity 32, wait at once: ", " records in one second, "}, done = "flow: ok, 4 rings, 0 records lost"},
	{name = "limits", lines = {"limits: processor time of one second, used of limit: ", ""}, done = "limits: ok, 4 budgets within their processor time, "},
}

// The logs of the measure runs whose lines the measure record holds.
TEST_OUTPUT_MEASURE_CLOCK :: BUILD_FOLDER + "/test_output_measure_clock.txt"
TEST_OUTPUT_MEASURE_DISK :: BUILD_FOLDER + "/test_output_measure_disk.txt"
TEST_OUTPUT_MEASURE_SCHEDULER :: BUILD_FOLDER + "/test_output_scheduler_1.txt"

// measure_program_output gives the log of the measure run of a program.
// The text is in memory of its own: a scenario frees the temporary memory
// after each step.
measure_program_output :: proc(name: string) -> string {
	return fmt.aprintf("%s/test_output_measure_%s.txt", BUILD_FOLDER, name)
}

// measure_program_find gives the program of the table with a name.
measure_program_find :: proc(name: string) -> (program: Measure_Program, found: bool) {
	for item in measure_programs {
		if item.name == name {
			return item, true
		}
	}
	return {}, false
}

// measure_program_lines gives the lines of a log that a program wrote: the
// lines that hold "name: ".
measure_program_lines :: proc(log: string, name: string) -> []string {
	mark := strings.concatenate({name, ": "}, context.temp_allocator)
	lines := make([dynamic]string, context.temp_allocator)
	for line in strings.split_lines(log, context.temp_allocator) {
		if strings.contains(line, mark) {
			append(&lines, strings.trim_right(line, "\r"))
		}
	}
	return lines[:]
}

// measure_program_steps adds the scenario of the measure run of one
// program: the start of the machine, the program, the lines of its
// measures, its last line, and the stop.
measure_program_steps :: proc(program: Measure_Program, steps: ^[dynamic]Step) {
	append(steps, Step{kind = .Wait, text = "boot program: ok"}, Step{kind = .Wait, text = "kernel: ok"}, Step{kind = .Wait, text = "root: ok"})
	append(steps, Step{kind = .Wait, text = "compositor: first frame", any_order = true}, Step{kind = .Wait, text = "compositor: surface console"})
	append(steps, Step{kind = .Launch, text = program.name})
	for line in program.lines {
		if line != "" {
			append(steps, Step{kind = .Wait, text = line})
		}
	}
	append(steps, Step{kind = .Wait, text = program.done}, Step{kind = .Front, text = "console"}, Step{kind = .Type, text = "shutdown()"}, Step{kind = .Wait, text = "kernel: the machine stops with code 0"})
}

// measure_program_run starts one program alone on a machine of a measure
// run, waits for its last line, stops the machine, and prints the lines of
// the program. The tool checks no number: the program checks its counts.
measure_program_run :: proc(program: Measure_Program) -> bool {
	output := measure_program_output(program.name)
	defer delete(output)
	// Not in the temporary allocator: the scenario frees it after each step.
	steps := make([dynamic]Step)
	defer delete(steps)
	measure_program_steps(program, &steps)
	if !machine_test(steps[:], BOOT_VOLUME_MEASURE, output, MACHINE_STOP_OK, TEST_DATA_DISK) {
		return false
	}
	log, read_error := os.read_entire_file(output, context.temp_allocator)
	if read_error != nil {
		fmt.eprintfln("kerneltool: cannot read %s: %v", output, read_error)
		return false
	}
	fmt.printfln("kerneltool: the measure run of %s (%s):", program.name, output)
	for line in measure_program_lines(string(log), program.name) {
		fmt.println(line)
	}
	return true
}

// measure_runs_of_the_record runs the measure runs whose lines the measure
// record holds: the locks, the time page, the disk and the scheduling
// strategies. `kerneltool screenshots` calls it after the test: the test
// itself measures no rate.
measure_runs_of_the_record :: proc() -> bool {
	if !machine_test(scenario_measure[:], BOOT_VOLUME_MEASURE, TEST_OUTPUT_MEASURE, MACHINE_STOP_OK, TEST_DATA_DISK) {
		return false
	}
	for name in ([]string{"clock", "disk"}) {
		program := measure_program_find(name) or_return
		measure_program_run(program) or_return
	}
	return machine_test(scenario_measure_scheduler[:], BOOT_VOLUME_MEASURE, TEST_OUTPUT_MEASURE_SCHEDULER, MACHINE_STOP_OK, TEST_DATA_DISK)
}
