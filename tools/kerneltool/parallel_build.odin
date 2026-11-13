package kerneltool

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

// The parallel build of the modules, and the pool of processes that it
// shares with the boot volumes (boot_volumes.odin). Each module is built by its own
// process of this tool (the command `module`), which runs one compiler.
// The compiler uses its own threads too: its output does not depend on
// their count (docs/REPRODUCIBLE_BUILD.md, section 7). The tool runs at
// most `module_build_processes` processes at once, keeps the output of
// each one, prints it whole in the order of the module table, and
// assembles the boot image in that order.
//
// A module whose inputs are the same as at its last build starts no
// process: the tool keeps its outputs (incremental_build.odin).
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

// What one process of a build gave.
Build_Process_Outcome :: struct {
	started:  bool,
	success:  bool,
	output:   []u8, // Its standard output, then its standard error.
	duration: time.Duration, // From its start to its end: a measure.
}

// The processes of one step of a build, which the worker threads share:
// the modules of one level, or the boot volumes that must be built.
Build_Process_Pool :: struct {
	commands: [][]string, // One command for each process.
	next:     int, // The next place in commands to take (atomic).
	failed:   bool, // A process failed: no new process starts (atomic).
	outcomes: []Build_Process_Outcome, // By place in commands.
}

// build_processes_run runs each command in its own process, at most
// `processes` at once, and keeps the output of each one. After a failure no
// new process starts; the processes that run end. The outcomes have the
// order of the commands; the caller frees the output of each one.
build_processes_run :: proc(commands: [][]string, processes: int, allocator := context.allocator) -> []Build_Process_Outcome {
	pool := Build_Process_Pool {
		commands = commands,
		outcomes = make([]Build_Process_Outcome, len(commands), allocator),
	}
	workers := make([]^thread.Thread, max(0, min(processes, len(commands))), context.temp_allocator)
	for &worker in workers {
		worker = thread.create_and_start_with_data(&pool, build_process_worker)
	}
	thread.join_multiple(..workers)
	for worker in workers {
		thread.destroy(worker)
	}
	return pool.outcomes
}

// build_process_worker takes the commands of a pool one at a time and runs
// each one.
build_process_worker :: proc(data: rawptr) {
	pool := (^Build_Process_Pool)(data)
	for {
		place := sync.atomic_add(&pool.next, 1)
		if place >= len(pool.commands) || sync.atomic_load(&pool.failed) {
			return
		}
		command := pool.commands[place]
		started := time.tick_now()
		state, standard_output, standard_error, error := os.process_exec({command = command}, context.allocator)
		output := make([]u8, len(standard_output) + len(standard_error))
		copy(output, standard_output)
		copy(output[len(standard_output):], standard_error)
		if error != nil {
			delete(output)
			output = transmute([]u8)fmt.aprintfln("kerneltool: cannot start %s: %v", command[0], error)
		}
		delete(standard_output)
		delete(standard_error)
		success := error == nil && state.exited && state.success
		pool.outcomes[place] = {
			started  = true,
			success  = success,
			output   = output,
			duration = time.tick_since(started),
		}
		if !success {
			sync.atomic_store(&pool.failed, true)
		}
	}
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

// The names of the built modules that the line of the kept modules prints.
BUILT_MODULE_NAMES_MOST :: 12

// build_modules_in_parallel builds every module of the table, level after
// level. It prints the output of each process in the order of the table.
// After a failure, no new process starts; the processes that run end, and
// the tool names each module that failed or did not start.
//
// A module whose build record has the build key of its inputs, and whose
// outputs have their recorded hashes, is kept: it starts no process. The
// tool decides for a level after the level before it ended, because the
// file of an import is an input.
build_modules_in_parallel :: proc() -> bool {
	levels := module_levels() or_return
	modules_started := time.tick_now()
	// Before the first compiler starts: the hash of each source.
	build_inputs_prepare()
	kept_count := 0
	built_names := strings.builder_make(context.temp_allocator)
	built_count := 0
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
	outcomes := make([]Build_Process_Outcome, len(module_builds))
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
		// The modules of the level that are built: the others are kept.
		checks_started := time.tick_now()
		level_indexes := indexes[:]
		indexes = make([dynamic]int, context.temp_allocator)
		for index in level_indexes {
			kept, reason := module_is_kept(module_builds[index])
			if kept {
				kept_count += 1
				continue
			}
			append(&indexes, index)
			built_count += 1
			if built_count <= BUILT_MODULE_NAMES_MOST {
				fmt.sbprintf(&built_names, "%s%s (%s)", built_count > 1 ? ", " : "", module_builds[index].name, reason)
			}
		}
		build_measure.record_checks += time.tick_since(checks_started)
		// Each setting of the build that this process holds goes to the
		// module process as an argument: a setting that stays here gives a
		// module of another build, with no error.
		commands := make([][]string, len(indexes), context.temp_allocator)
		for index, place in indexes {
			command := make([]string, 6, context.temp_allocator)
			command[0] = tool_path
			command[1] = "module"
			command[2] = module_builds[index].name
			command[3] = test_build_checks ? "with_checks" : "without_checks"
			command[4] = measure_run ? "measure_run" : "usual_run"
			command[5] = debug_information ? "with_debug_information" : "without_debug_information"
			commands[place] = command
		}
		level_outcomes := build_processes_run(commands, processes, context.temp_allocator)
		for index, place in indexes {
			outcomes[index] = level_outcomes[place]
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
			fmt.eprintfln("kerneltool: %d of %d modules did not start, because a module failed", not_started - kept_count, len(module_builds))
			return false
		}
		// The build record of each module that was built: its key, and the
		// hash of each output.
		writes_started := time.tick_now()
		for index in indexes {
			if !module_record_write(module_builds[index]) && build_inputs.usable {
				fmt.printfln("kerneltool: no build record for %s: the compiler gave no list of its files, or an input changed during the build; the next build builds it again", module_builds[index].name)
			}
		}
		build_measure.record_writes += time.tick_since(writes_started)
	}
	build_measure.modules_built += built_count
	build_measure.modules_kept += kept_count
	build_measure.modules += time.tick_since(modules_started)
	if built_count == 0 {
		fmt.printfln("kerneltool: %d of %d modules kept: the inputs of each one are the same, and its outputs have their recorded hashes", kept_count, len(module_builds))
	} else if kept_count > 0 || !build_whole {
		more := built_count > BUILT_MODULE_NAMES_MOST ? fmt.tprintf(", and %d more", built_count - BUILT_MODULE_NAMES_MOST) : ""
		fmt.printfln("kerneltool: %d of %d modules kept, %d built: %s%s", kept_count, len(module_builds), built_count, strings.to_string(built_names), more)
	}
	return true
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
