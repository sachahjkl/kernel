package kerneltool

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

// The parallel build of the modules, and the pool of processes that it
// shares with the boot volumes (boot_volumes.odin). Each step of a module runs in its own
// process of this tool (the command `module`): the compile step runs one compiler.
// The compiler uses its own threads too: its output does not depend on
// their count (docs/REPRODUCIBLE_BUILD.md, section 7). The tool runs at
// most `module_build_processes` processes at once, keeps the output of
// each one, prints it whole in the order of the module table, and
// assembles the boot image in that order.
//
// A module whose inputs are the same as at its last build starts no
// process: the tool keeps its outputs (incremental_build.odin). A module
// whose sources are the same and whose import changed starts its
// conversion only.
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

// The names of the modules with a step that the line of the kept modules
// prints.
BUILT_MODULE_NAMES_MOST :: 12

// The last argument of the command `module`, for one step alone.
MODULE_STEP_COMPILE :: "compile"
MODULE_STEP_CONVERT :: "convert"

// module_step_processes_run runs one step (MODULE_STEP_COMPILE or
// MODULE_STEP_CONVERT) of each module of a list, each in its own process
// of the tool, and prints the output of each process in the order of the
// list. finished says, for each place of the list, that its process
// ended with success.
module_step_processes_run :: proc(tool_path: string, indexes: []int, step: string, processes: int) -> (finished: []bool, ok: bool) {
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
		command[4] = debug_information ? "with_debug_information" : "without_debug_information"
		command[5] = step
		commands[place] = command
	}
	outcomes := build_processes_run(commands, processes, context.temp_allocator)
	finished = make([]bool, len(indexes), context.temp_allocator)
	ok = true
	for index, place in indexes {
		outcome := outcomes[place]
		if len(outcome.output) > 0 {
			os.write(os.stdout, outcome.output)
		}
		delete(outcome.output)
		finished[place] = outcome.started && outcome.success
		if outcome.started && !outcome.success {
			fmt.eprintfln("kerneltool: the %s step of %s failed", step, module_builds[index].name)
			ok = false
		}
	}
	return finished, ok
}

// build_modules_in_parallel builds every module of the table, level after
// level. It prints the output of each process in the order of the table.
// After a failure, no new process starts; the processes that run end, and
// the tool names each module that failed.
//
// For each module the tool says what this build does (incremental_build.odin):
// kept, no process starts; converted, the conversion runs alone, because
// the file of an import changed and the linked file is the same; built,
// the compile step runs, then the conversion.
//
// The tool decides for a level after the level before it ended, because
// the file of an import is an input of the conversion. A module that is
// converted has a new hash, as a module that is built: the level after it
// then reads the new file, and converts each importer of it. So a change
// goes up the levels as a chain of conversions.
//
// In a level, the compile steps run first, all at once, then the
// conversions: each step has its own process and its own time in the
// measure of the build.
build_modules_in_parallel :: proc() -> bool {
	levels := module_levels() or_return
	modules_started := time.tick_now()
	// Before the first compiler starts: the hash of each source.
	build_inputs_prepare()
	kept_count := 0
	converted_count := 0
	built_count := 0
	step_names := strings.builder_make(context.temp_allocator)
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
	// The modules whose steps of this build are done, kept ones too.
	done_count := 0
	highest := 0
	for level in levels {
		highest = max(highest, level)
	}
	for level_number in 0 ..= highest {
		// What the build does with each module of the level.
		checks_started := time.tick_now()
		compile_indexes := make([dynamic]int, context.temp_allocator)
		convert_indexes := make([dynamic]int, context.temp_allocator)
		convert_steps := make([dynamic]Module_Step, context.temp_allocator)
		for level, index in levels {
			if level != level_number {
				continue
			}
			step, reason := module_step_of_build(module_builds[index])
			switch step {
			case .Kept:
				kept_count += 1
				done_count += 1
				continue
			case .Converted:
				converted_count += 1
			case .Built:
				built_count += 1
				append(&compile_indexes, index)
			}
			append(&convert_indexes, index)
			append(&convert_steps, step)
			if built_count + converted_count <= BUILT_MODULE_NAMES_MOST {
				fmt.sbprintf(&step_names, "%s%s (%s: %s)", built_count + converted_count > 1 ? ", " : "", module_builds[index].name, step == .Built ? "built" : "converted", reason)
			}
		}
		build_measure.record_checks += time.tick_since(checks_started)
		step_started := time.tick_now()
		_, compiled := module_step_processes_run(tool_path, compile_indexes[:], MODULE_STEP_COMPILE, processes)
		build_measure.module_compile_steps += time.tick_since(step_started)
		finished: []bool
		converted := false
		if compiled {
			step_started = time.tick_now()
			finished, converted = module_step_processes_run(tool_path, convert_indexes[:], MODULE_STEP_CONVERT, processes)
			build_measure.module_conversions += time.tick_since(step_started)
		}
		// The build record of each module whose conversion ended: the key
		// of each step, and the hash of each output. After a failure too:
		// the modules of the level that ended are not built again.
		writes_started := time.tick_now()
		for index, place in convert_indexes {
			if place >= len(finished) || !finished[place] {
				continue
			}
			done_count += 1
			if !module_records_write(module_builds[index], convert_steps[place]) && build_inputs.usable {
				fmt.printfln("kerneltool: no build record for %s: the compiler gave no list of its files, or an input changed during the build; the next build builds it again", module_builds[index].name)
			}
		}
		build_measure.record_writes += time.tick_since(writes_started)
		if !compiled || !converted {
			fmt.eprintfln("kerneltool: %d of %d modules are not built, because a step of a module failed", len(module_builds) - done_count, len(module_builds))
			return false
		}
	}
	build_measure.modules_built += built_count
	build_measure.modules_converted += converted_count
	build_measure.modules_kept += kept_count
	build_measure.modules += time.tick_since(modules_started)
	if built_count + converted_count == 0 {
		fmt.printfln("kerneltool: %d of %d modules kept: the inputs of each one are the same, and its outputs have their recorded hashes", kept_count, len(module_builds))
	} else if kept_count + converted_count > 0 || !build_whole {
		more := built_count + converted_count > BUILT_MODULE_NAMES_MOST ? fmt.tprintf(", and %d more", built_count + converted_count - BUILT_MODULE_NAMES_MOST) : ""
		fmt.printfln("kerneltool: %d of %d modules kept, %d converted, %d built: %s%s", kept_count, len(module_builds), converted_count, built_count, strings.to_string(step_names), more)
	}
	return true
}

// The command module: build one module of the table in this process, or
// run one of its two steps. The parallel build runs each step in its own
// process; a developer runs the command with no step to build one module.
run_module :: proc(args: []string) -> int {
	step_is_known := len(args) == 3 || (len(args) == 4 && (args[3] == MODULE_STEP_COMPILE || args[3] == MODULE_STEP_CONVERT))
	if !step_is_known || (args[1] != "with_checks" && args[1] != "without_checks") || (args[2] != "with_debug_information" && args[2] != "without_debug_information") {
		fmt.eprintln("kerneltool: module <name> with_checks|without_checks with_debug_information|without_debug_information [compile|convert]")
		return EXIT_USAGE
	}
	test_build_checks = args[1] == "with_checks"
	// A module with no debug information goes to a folder of its own: the
	// modules of the build stay as they are.
	debug_information = args[2] == "with_debug_information"
	module_build_folder = debug_information ? MODULE_BUILD_FOLDER : MODULE_BUILD_FOLDER_WITHOUT_DEBUG_INFORMATION
	for build in module_builds {
		if build.name != args[0] {
			continue
		}
		built: bool
		switch {
		case len(args) == 3:
			built = build_module(build)
		case args[3] == MODULE_STEP_COMPILE:
			built = module_compile(build)
		case:
			built = module_convert(build)
		}
		return built ? 0 : EXIT_FAILURE
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
