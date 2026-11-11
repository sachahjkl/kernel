package kerneltool

import module "contract:module"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"

// One source must give one module (property 11). Two commands check it:
// `check` builds everything a second time and compares; `repeat` builds
// again and again with no machine. Each compares the outputs of a build,
// not only the module: a difference in the LLVM IR or in the object is the
// early sign (choice 359: each object differed while each module was the
// same). When an output differs, each distinct content stays in
// DIFFERENT_BUILDS_FOLDER with the name of the file, and the tool prints
// where the first difference is.

// No build resets this folder (a build resets the folder of the objects).
// Each `check` and each `repeat` empties it first.
DIFFERENT_BUILDS_FOLDER :: BUILD_FOLDER + "/different_builds"

// One file that a build writes, and what it is.
Build_Output :: struct {
	kind: string, // "module", "LLVM IR", "object", "boot program"
	path: string,
}

// The outputs of one module: the module, the LLVM IR that Odin wrote, and the
// object that llc made from it.
module_build_outputs :: proc(build: Module_Build) -> [3]Build_Output {
	folder := fmt.aprintf("%s/%s", MODULE_BUILD_FOLDER, build.name)
	return {
		{kind = "module", path = fmt.aprintf("%s/%s.module", MODULE_BUILD_FOLDER, build.name)},
		{kind = "LLVM IR", path = fmt.aprintf("%s/%s.ll", folder, build.name)},
		{kind = "object", path = fmt.aprintf("%s/objects/%s.o", folder, build.name)},
	}
}

// The outputs of the boot program: the program, and the object that Odin made.
BOOT_PROGRAM_OUTPUTS :: [2]Build_Output{{kind = "boot program", path = BOOT_PROGRAM}, {kind = "object", path = BOOT_OBJECT_FOLDER + "/boot.obj"}}

// One output over several builds: each distinct content, in the order of its
// first build, and the count of builds that gave it.
Distinct_Results :: struct {
	owner:          string, // The module, or "boot".
	output:         Build_Output,
	contents:       [dynamic][]u8,
	builds_of_each: [dynamic]int,
}

// record_build_output reads the output after a build and adds it to the
// results. A new distinct content is kept as a file:
// DIFFERENT_BUILDS_FOLDER/<owner>/<file name>.variant_1 (the first
// content), .variant_2, ... The tool prints where it differs from the first
// content.
record_build_output :: proc(results: ^Distinct_Results, build_number: int) -> bool {
	bytes, err := os.read_entire_file(results.output.path, context.allocator)
	if err != nil {
		fmt.eprintfln("kerneltool: cannot read %s: %v", results.output.path, err)
		return false
	}
	for content, index in results.contents {
		if slice.equal(content, bytes) {
			results.builds_of_each[index] += 1
			delete(bytes)
			return true
		}
	}
	append(&results.contents, bytes)
	append(&results.builds_of_each, 1)
	variant := len(results.contents)
	if variant == 1 {
		return true
	}
	if variant == 2 {
		keep_variant_file(results, 1)
	}
	kept := keep_variant_file(results, variant)
	fmt.printfln(
		"kerneltool: the %s of %s of build %d is distinct result %d (kept as %s, the first as .variant_1): %s",
		results.output.kind,
		results.owner,
		build_number,
		variant,
		kept,
		first_difference(results.output.kind, results.contents[0], bytes),
	)
	return true
}

keep_variant_file :: proc(results: ^Distinct_Results, variant: int) -> string {
	folder := fmt.tprintf("%s/%s", DIFFERENT_BUILDS_FOLDER, results.owner)
	if !make_folder(folder) {
		return "(not kept)"
	}
	kept := fmt.tprintf("%s/%s.variant_%d", folder, results.output.path[strings.last_index(results.output.path, "/") + 1:], variant)
	if err := os.write_entire_file(kept, results.contents[variant - 1]); err != nil {
		fmt.eprintfln("kerneltool: cannot write %s: %v", kept, err)
	}
	return kept
}

// first_difference says where two contents of one output first differ: the
// line of an LLVM IR file (with the two lines), the part of a module file,
// the byte of another file.
first_difference :: proc(kind: string, first, other: []u8) -> string {
	at := 0
	for at < min(len(first), len(other)) && first[at] == other[at] {
		at += 1
	}
	switch kind {
	case "LLVM IR":
		line_start := at
		for line_start > 0 && first[line_start - 1] != '\n' {
			line_start -= 1
		}
		line_number := 1 + slice.count(first[:line_start], '\n')
		return fmt.tprintf("line %d is\n    first: %s\n    this:  %s", line_number, line_at(first, line_start), line_at(other, line_start))
	case "module":
		return fmt.tprintf("byte %d, in %s", at, part_of(first, u64(at)))
	}
	return fmt.tprintf("byte %d of %d and %d bytes", at, len(first), len(other))
}

// line_at gives the line that starts at a byte, at most 240 bytes of it.
line_at :: proc(text: []u8, start: int) -> string {
	if start >= len(text) {
		return "(the end of the file)"
	}
	end := start
	for end < len(text) && text[end] != '\n' && end - start < 240 {
		end += 1
	}
	return string(text[start:end])
}

// summary_of_results gives "1 distinct in 30 builds", or the count of
// builds of each distinct result: "3 distinct in 30 builds: 27, 2, 1".
summary_of_results :: proc(results: Distinct_Results) -> string {
	total := 0
	for count in results.builds_of_each {
		total += count
	}
	text := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&text, "%d distinct in %d builds", len(results.contents), total)
	if len(results.contents) > 1 {
		for count, index in results.builds_of_each {
			fmt.sbprintf(&text, "%s%d", index == 0 ? ": " : ", ", count)
		}
	}
	return strings.to_string(text)
}

free_results :: proc(results: ^Distinct_Results) {
	for content in results.contents {
		delete(content)
	}
	delete(results.contents)
	delete(results.builds_of_each)
}

// The command repeat: build one module, or every module and the boot
// program, again and again with no machine, and count the distinct results
// of each output.
run_repeat :: proc(args: []string) -> int {
	count, parsed := 0, false
	if len(args) == 2 || (len(args) == 3 && args[0] == "all") {
		count, parsed = strconv.parse_int(args[1])
	}
	if len(args) == 3 && parsed {
		parsed = parse_module_build_processes(args[2])
	}
	if !parsed || count < 2 {
		fmt.eprintln("kerneltool: repeat <module> <count>, or repeat all <count> [processes], with a count of 2 or more")
		return EXIT_USAGE
	}
	if args[0] == "all" {
		return repeat_all(count)
	}
	build: Module_Build
	for item in module_builds {
		if item.name == args[0] {
			build = item
		}
	}
	if build.name == "" {
		fmt.eprintfln("kerneltool: repeat: no module %s", args[0])
		return EXIT_USAGE
	}
	if !reset_folder(DIFFERENT_BUILDS_FOLDER) {
		return EXIT_FAILURE
	}
	results: [3]Distinct_Results
	for output, index in module_build_outputs(build) {
		results[index] = {owner = build.name, output = output}
	}
	for number in 1 ..= count {
		if !build_module(build) {
			return EXIT_FAILURE
		}
		for &result in results {
			if !record_build_output(&result, number) {
				return EXIT_FAILURE
			}
		}
		free_all(context.temp_allocator)
	}
	same := true
	for &result in results {
		fmt.printfln("kerneltool: repeat: %s of %s: %s", result.output.kind, build.name, summary_of_results(result))
		same = same && len(result.contents) == 1
		free_results(&result)
	}
	return same ? 0 : EXIT_FAILURE
}

// repeat_all builds every module and the boot program count times, in the
// order of `build`, and prints one row for each: the distinct modules (or
// boot programs), LLVM IR files and objects.
repeat_all :: proc(count: int) -> int {
	if !reset_folder(DIFFERENT_BUILDS_FOLDER) {
		return EXIT_FAILURE
	}
	all := make([dynamic]Distinct_Results)
	defer delete(all)
	for build in module_builds {
		for output in module_build_outputs(build) {
			append(&all, Distinct_Results{owner = build.name, output = output})
		}
	}
	for output in BOOT_PROGRAM_OUTPUTS {
		append(&all, Distinct_Results{owner = "boot", output = output})
	}
	for number in 1 ..= count {
		if !build_modules() || !build_boot_program("boot.image", BOOT_VOLUME, 0) {
			return EXIT_FAILURE
		}
		for &result in all {
			if !record_build_output(&result, number) {
				return EXIT_FAILURE
			}
		}
		fmt.printfln("kerneltool: repeat: build %d of %d done", number, count)
		free_all(context.temp_allocator)
	}
	fmt.printfln("kerneltool: repeat: %d builds of each of %d modules and of the boot program", count, len(module_builds))
	fmt.printfln("%-20s %8s %16s %12s %17s", "module", "builds", "distinct files", "distinct IR", "distinct objects")
	same := true
	for index := 0; index < len(all); {
		owner := all[index].owner
		// The columns: the module or the boot program, the LLVM IR, the object.
		row := [3]string{"-", "-", "-"}
		for index < len(all) && all[index].owner == owner {
			column := 0
			switch all[index].output.kind {
			case "LLVM IR":
				column = 1
			case "object":
				column = 2
			}
			row[column] = fmt.tprintf("%d", len(all[index].contents))
			same = same && len(all[index].contents) == 1
			if len(all[index].contents) > 1 {
				fmt.printfln("kerneltool: repeat: %s of %s: %s", all[index].output.kind, owner, summary_of_results(all[index]))
			}
			free_results(&all[index])
			index += 1
		}
		fmt.printfln("%-20s %8s %16s %12s %17s", owner, fmt.tprintf("%d", count), row[0], row[1], row[2])
	}
	return same ? 0 : EXIT_FAILURE
}

// outputs_same_after_second_build builds the modules and the boot program a
// second time and compares each output with the output of the first build:
// the module, its LLVM IR and its object, the pointer theme files (the
// resources of the boot image), the boot program and its object. The hash
// of a module is the identity of its source, not of one build (property 11).
outputs_same_after_second_build :: proc() -> bool {
	reset_folder(DIFFERENT_BUILDS_FOLDER) or_return
	all := make([dynamic]Distinct_Results)
	defer {
		for &result in all {
			free_results(&result)
		}
		delete(all)
	}
	for build in module_builds {
		for output in module_build_outputs(build) {
			append(&all, Distinct_Results{owner = build.name, output = output})
		}
	}
	theme_paths := files_with_suffix(POINTER_BUILD_FOLDER, ".pointers") or_return
	for path in theme_paths {
		append(&all, Distinct_Results{owner = "pointers", output = {kind = "pointer theme file", path = path}})
	}
	// The last build of `test` made the boot program of BOOT_VOLUME.
	for output in BOOT_PROGRAM_OUTPUTS {
		append(&all, Distinct_Results{owner = "boot", output = output})
	}
	for &result in all {
		record_build_output(&result, 1) or_return
	}
	build_modules() or_return
	build_boot_program("boot.image", BOOT_VOLUME, 0) or_return
	different := 0
	for &result in all {
		record_build_output(&result, 2) or_return
		if len(result.contents) > 1 {
			fmt.eprintfln("kerneltool: test failed: the %s %s is not the same bytes after a second build (both are kept in %s/%s)", result.output.kind, result.output.path, DIFFERENT_BUILDS_FOLDER, result.owner)
			different += 1
		}
	}
	if different != 0 {
		return false
	}
	fmt.printfln("kerneltool: test passed: %d modules, their LLVM IR and their objects, %d pointer theme files, and the boot program and its object are the same bytes after a second build", len(module_builds), len(theme_paths))
	return true
}

// part_of names the part of a module file that holds a byte: the header,
// the table directory, a table, or a segment.
part_of :: proc(file: []u8, at: u64) -> string {
	head, error := module.header(file)
	if error != .None {
		return "a file with no valid header"
	}
	if at < size_of(module.Header) {
		return "the header"
	}
	if at < u64(head.header_size) + u64(head.table_count) * size_of(module.Table_Entry) && at >= u64(head.header_size) {
		return "the table directory"
	}
	for kind in module.Table_Kind {
		entry := module.table(file, kind)
		if entry.count != 0 && at >= entry.offset && at < entry.offset + u64(entry.count) * u64(entry.record_size) {
			return fmt.tprintf("the table %v, record %d", kind, (at - entry.offset) / u64(max(entry.record_size, 1)))
		}
	}
	for index in 1 ..< module.count(file, .Segments) {
		segment, _ := module.record(file, .Segments, index, module.Segment)
		if at >= segment.file_offset && at < segment.file_offset + segment.file_size {
			return fmt.tprintf("segment %d (flags %v), memory offset %x", index, segment.flags, segment.memory_offset + (at - segment.file_offset))
		}
	}
	return "no table and no segment"
}
