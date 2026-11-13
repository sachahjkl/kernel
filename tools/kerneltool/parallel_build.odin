package kerneltool

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:sync"
import "core:thread"

// The parallel build of the modules. Each module is built by its own
// process of this tool (the command `module`), which runs one compiler.
// The compiler uses its own threads too: its output does not depend on
// their count (docs/REPRODUCIBLE_BUILD.md, section 7). The tool runs at
// most `module_build_processes` processes at once, keeps the output of
// each one, prints it whole in the order of the module table, and
// assembles the boot image in that order.
//
// A module needs the files of its imports only at its conversion (their
// hashes go into its import table). So the modules are built in levels: a
// module with no import is in level 0, and a module is in the level after
// the highest level of its imports. Each level starts after the last one
// ended.
//
// The files of two processes never meet: each module writes only in its
// own folder, `<name>.module`, and `<name>.ll` in the folder of the
// repository before the move (the compiler writes the IR where it runs);
// the names of the module table are distinct (checked below).

// The count of module processes at once. 0: the count of processors.
// `kerneltool build <processes>` and `repeat all <count> <processes>` set it.
module_build_processes := 0

// What one module process gave.
Module_Build_Outcome :: struct {
	started: bool,
	success: bool,
	output:  []u8, // Its standard output, then its standard error.
}

// The work of one level, which the worker threads share.
Module_Build_Level :: struct {
	module_indexes: []int, // Indexes in module_builds.
	next:           int, // The next place in module_indexes to take (atomic).
	failed:         bool, // A module of the level failed: no new process starts (atomic).
	outcomes:       []Module_Build_Outcome, // By index in module_builds.
	tool_path:      string,
}

// module_levels gives the level of each module of the table: 0 with no
// import, else one more than the highest level of its imports. The table
// lists each module after its imports.
module_levels :: proc() -> (levels: []int, ok: bool) {
	levels = make([]int, len(module_builds), context.temp_allocator)
	for build, index in module_builds {
		for earlier in module_builds[:index] {
			if earlier.name == build.name {
				fmt.eprintfln("kerneltool: two modules of the table have the name %s", build.name)
				return nil, false
			}
		}
		for name in build.imports {
			found := false
			for earlier, earlier_index in module_builds[:index] {
				if earlier.name == name {
					levels[index] = max(levels[index], levels[earlier_index] + 1)
					found = true
				}
			}
			if !found {
				fmt.eprintfln("kerneltool: the module %s imports %s, which is not before it in the table", build.name, name)
				return nil, false
			}
		}
	}
	return levels, true
}

// build_modules_in_parallel builds every module of the table, level after
// level. It prints the output of each process in the order of the table.
// After a failure, no new process starts; the processes that run end, and
// the tool names each module that failed or did not start.
build_modules_in_parallel :: proc() -> bool {
	levels := module_levels() or_return
	processes := module_build_processes
	if processes <= 0 {
		processes = os.get_processor_core_count()
	}
	// The file of this process, not its first argument: the compiler that
	// runs the tool gives only the name of the file there, and that name
	// finds the wrapper of the shell, which builds the tool again.
	tool_path, path_error := os.get_executable_path(context.temp_allocator)
	if path_error != nil {
		fmt.eprintfln("kerneltool: cannot find the file of the tool: %v", path_error)
		return false
	}
	// The folder that every module process writes under exists before the
	// first process starts.
	make_folder(module_build_folder) or_return
	outcomes := make([]Module_Build_Outcome, len(module_builds))
	defer {
		for outcome in outcomes {
			delete(outcome.output)
		}
		delete(outcomes)
	}
	highest := 0
	for level in levels {
		highest = max(highest, level)
	}
	for level_number in 0 ..= highest {
		indexes := make([dynamic]int, context.temp_allocator)
		for level, index in levels {
			if level == level_number {
				append(&indexes, index)
			}
		}
		level := Module_Build_Level{module_indexes = indexes[:], outcomes = outcomes, tool_path = tool_path}
		workers := make([]^thread.Thread, min(processes, len(indexes)), context.temp_allocator)
		for &worker in workers {
			worker = thread.create_and_start_with_data(&level, module_build_worker)
		}
		thread.join_multiple(..workers)
		for worker in workers {
			thread.destroy(worker)
		}
		failed := false
		for index in indexes {
			outcome := outcomes[index]
			if len(outcome.output) > 0 {
				os.write(os.stdout, outcome.output)
			}
			if outcome.started && !outcome.success {
				fmt.eprintfln("kerneltool: the build of %s failed", module_builds[index].name)
				failed = true
			}
		}
		if failed {
			not_started := 0
			for outcome in outcomes {
				not_started += outcome.started ? 0 : 1
			}
			fmt.eprintfln("kerneltool: %d of %d modules did not start, because a module failed", not_started, len(module_builds))
			return false
		}
	}
	return true
}

// module_build_worker takes the modules of a level one at a time and runs
// the command `module` of this tool for each one.
module_build_worker :: proc(data: rawptr) {
	level := (^Module_Build_Level)(data)
	for {
		place := sync.atomic_add(&level.next, 1)
		if place >= len(level.module_indexes) || sync.atomic_load(&level.failed) {
			return
		}
		index := level.module_indexes[place]
		// Each setting of the build that this process holds goes to the
		// module process as an argument: a setting that stays here gives a
		// module of another build, with no error.
		command := [?]string{level.tool_path, "module", module_builds[index].name, test_build_checks ? "with_checks" : "without_checks", measure_run ? "measure_run" : "usual_run", debug_information ? "with_debug_information" : "without_debug_information"}
		state, standard_output, standard_error, error := os.process_exec({command = command[:]}, context.allocator)
		output := make([]u8, len(standard_output) + len(standard_error))
		copy(output, standard_output)
		copy(output[len(standard_output):], standard_error)
		if error != nil {
			delete(output)
			output = transmute([]u8)fmt.aprintfln("kerneltool: cannot start %s: %v", level.tool_path, error)
		}
		delete(standard_output)
		delete(standard_error)
		success := error == nil && state.exited && state.success
		level.outcomes[index] = {started = true, success = success, output = output}
		if !success {
			sync.atomic_store(&level.failed, true)
		}
	}
}

// The command module: build one module of the table in this process. The
// parallel build runs it; a developer can run it to build one module.
run_module :: proc(args: []string) -> int {
	if len(args) != 4 || (args[1] != "with_checks" && args[1] != "without_checks") || (args[2] != "measure_run" && args[2] != "usual_run") || (args[3] != "with_debug_information" && args[3] != "without_debug_information") {
		fmt.eprintln("kerneltool: module <name> with_checks|without_checks measure_run|usual_run with_debug_information|without_debug_information")
		return EXIT_USAGE
	}
	test_build_checks = args[1] == "with_checks"
	measure_run = args[2] == "measure_run"
	// A module with no debug information goes to a folder of its own: the
	// modules of the build stay as they are.
	debug_information = args[3] == "with_debug_information"
	module_build_folder = debug_information ? MODULE_BUILD_FOLDER : MODULE_BUILD_FOLDER_WITHOUT_DEBUG_INFORMATION
	for build in module_builds {
		if build.name == args[0] {
			return build_module(build) ? 0 : EXIT_FAILURE
		}
	}
	fmt.eprintfln("kerneltool: module: no module %s", args[0])
	return EXIT_USAGE
}

// parse_module_build_processes reads the count of processes of the
// parallel build from an argument of a command.
parse_module_build_processes :: proc(text: string) -> bool {
	count, parsed := strconv.parse_int(text)
	if !parsed || count < 1 {
		fmt.eprintfln("kerneltool: %s is not a count of processes (1 or more)", text)
		return false
	}
	module_build_processes = count
	return true
}
