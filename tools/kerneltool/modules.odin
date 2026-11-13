package kerneltool

import "contract:blake3"
import module "contract:module"
import "core:fmt"
import info "contract:boot_info"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sys/linux"

MODULE_BUILD_FOLDER :: BUILD_FOLDER + "/modules"
// The modules of the build with no debug information: the check that the
// debug objects change no byte of a module builds every module there
// (repeat.odin, modules_same_without_debug_information).
MODULE_BUILD_FOLDER_WITHOUT_DEBUG_INFORMATION :: BUILD_FOLDER + "/modules_without_debug_information"
BOOT_IMAGE :: BUILD_FOLDER + "/boot.image"
BOOT_IMAGE_FAILS :: BUILD_FOLDER + "/boot_fails.image"
BOOT_IMAGE_SHORTAGE :: BUILD_FOLDER + "/boot_shortage.image"
SYSTEM_LIBRARY_FOLDER :: "support/system"
// The copy and the fill of every module, of the kernel and of the boot
// program: copy_bytes_without_overlap, copy_bytes_with_overlap,
// fill_bytes_with_value, and the names that the compiler calls (memcpy,
// memmove, memset). The builds do not use -no-crt: with it, the Odin runtime
// gives its own functions under these names (loops of one byte, two with no
// optimization), and a symbol of another object cannot replace them.
RUNTIME_MEMORY :: "runtime/memory.asm"

// The features of llc for the kernel: no x87, MMX, SSE or AVX instruction,
// as the Linux kernel is built (-mno-80387 -mno-mmx -mno-sse -mno-sse2
// -mno-avx -msoft-float). soft-float passes the floating point values of
// the few runtime procedures that have them in general registers, and
// makes their arithmetic calls: no code of the kernel calls those
// procedures, and the link drops them (--gc-sections). The check after
// the link (vector_check.odin) is the proof.
KERNEL_TARGET_FEATURES :: "-mattr=-x87,-mmx,-sse,-sse2,-sse3,-ssse3,-sse4.1,-sse4.2,-avx,-avx2,-avx512f,+soft-float"

// The modules of the project, each one after its imports.
//   source:  the folder of the Odin package, and of its .asm files.
// The exports of a module and their descriptions come from the source
// (describe.odin).
//   kernel:  the module runs in kernel mode: interrupts use its stack.
//   image:   the module is in the boot image.
Module_Build :: struct {
	name:    string,
	source:  string,
	imports: []string,
	kernel:  bool,
	image:   bool,
	// Settings of the compiler for this module only (-define). Only a
	// kernel for one machine of the test has one.
	defines: []string,
}

module_builds := [?]Module_Build {
	{name = "test_callee", source = "modules/test_callee"},
	{name = "test_caller", source = "modules/test_caller", imports = {"test_callee"}},
	{name = "kernel", source = "kernel", kernel = true},
	// The same kernel with the check of the instruction address before a
	// return to a program skipped, for one machine of `test return_fault`
	// only: its boot volume is BOOT_VOLUME_WITHOUT_RETURN_CHECK, and
	// machine_test refuses the line of this kernel in every other machine.
	{name = "kernel_without_return_check", source = "kernel", kernel = true, defines = {"TEST_BUILD_SKIPS_THE_INSTRUCTION_ADDRESS_CHECK=true"}},
	{name = "root", source = "programs/root", image = true},
	{name = "input", source = "programs/input", image = true},
	{name = "compositor", source = "programs/compositor", image = true},
	{name = "console", source = "programs/console", image = true},
	{name = "monitor", source = "programs/monitor", image = true},
	{name = "plasma", source = "programs/plasma", image = true},
	{name = "life", source = "programs/life", image = true},
	{name = "paint", source = "programs/paint", image = true},
	{name = "fault", source = "programs/fault", image = true},
	{name = "temple", source = "programs/temple", image = true},
	{name = "node", source = "programs/node", image = true},
	{name = "rings", source = "programs/rings", image = true},
	{name = "threads", source = "programs/threads", image = true},
	{name = "workers", source = "programs/workers", image = true},
	{name = "rights", source = "programs/rights", image = true},
	{name = "origin", source = "programs/origin", image = true},
	{name = "limits", source = "programs/limits", image = true},
	{name = "budget", source = "programs/budget", image = true},
	{name = "flow", source = "programs/flow", image = true},
	{name = "crowd", source = "programs/crowd", image = true},
	{name = "tally", source = "programs/tally", image = true},
	{name = "manual", source = "programs/manual", image = true},
	{name = "clock", source = "programs/clock", image = true},
	{name = "randomness", source = "programs/randomness", image = true},
	{name = "extended_state", source = "programs/extended_state", image = true},
	{name = "return_fault", source = "programs/return_fault", image = true},
	{name = "fault_ring", source = "programs/fault_ring", image = true},
	{name = "debugged", source = "programs/debugged", image = true},
	{name = "debugger", source = "programs/debugger", image = true},
	{name = "debug_target", source = "programs/debug_target", image = true},
	{name = "kernel_events", source = "programs/kernel_events", image = true},
	{name = "terminal", source = "programs/terminal", image = true},
	{name = "flood", source = "programs/flood", image = true},
	{name = "processors", source = "programs/processors", image = true},
	{name = "boot", source = "programs/boot", image = true},
	{name = "pages", source = "programs/pages", image = true},
	{name = "frames", source = "programs/frames", image = true},
	{name = "twin", source = "programs/twin", image = true},
	{name = "locks", source = "programs/locks", image = true},
	{name = "shortage", source = "programs/shortage", image = true},
	{name = "scheduler", source = "programs/scheduler", image = true},
	{name = "address_space", source = "programs/address_space", image = true},
	{name = "locker", source = "programs/locker", image = true},
	{name = "log", source = "programs/log", image = true},
	{name = "block", source = "programs/block", image = true},
	{name = "frame", source = "programs/frame", image = true},
	{name = "network", source = "programs/network", image = true},
	{name = "net", source = "programs/net", image = true},
	{name = "server", source = "programs/server", image = true},
	{name = "fetch", source = "programs/fetch", image = true},
	{name = "inspect", source = "programs/inspect", image = true},
	{name = "disk", source = "programs/disk", image = true},
	{name = "storage", source = "programs/storage", image = true},
	{name = "notes", source = "programs/notes", image = true},
	{name = "hierarchy", source = "programs/hierarchy", image = true},
	{name = "ranges", source = "programs/ranges", image = true},
	{name = "host", source = "programs/host", image = true},
	{name = "probe", source = "modules/probe", image = true},
	{name = "math", source = "modules/math", image = true},
	{name = "cryptography", source = "modules/cryptography", image = true},
	{name = "cryptography_vectors", source = "programs/cryptography_vectors", imports = {"cryptography"}, image = true},
	{name = "quic_echo", source = "programs/quic_echo", imports = {"cryptography"}, image = true},
	{name = "remote", source = "programs/remote", imports = {"cryptography"}, image = true},
	{name = "unlock", source = "programs/unlock", imports = {"cryptography"}, image = true},
	{name = "sample", source = "modules/sample", image = true},
	{name = "hostile_exports", source = "modules/hostile_exports", image = true},
	{name = "calendar", source = "modules/calendar", image = true},
	{name = "calendar_fixed", source = "modules/calendar_fixed", image = true},
	{name = "calendar_changed", source = "modules/calendar_changed", image = true},
	{name = "agenda", source = "modules/agenda", imports = {"calendar"}, image = true},
	// Its import is not in the boot image: a loader refuses it.
	{name = "lonely", source = "modules/lonely", imports = {"test_callee"}, image = true},
	{name = "imports", source = "programs/imports", imports = {"calendar"}, image = true},
	{name = "errors", source = "programs/errors", image = true},
	{name = "interface_elements", source = "programs/interface_elements", image = true},
	{name = "tables", source = "programs/tables", image = true},
	{name = "interface_module", source = "modules/interface_module", image = true},
	{name = "interface_through_module", source = "programs/interface_through_module", imports = {"interface_module"}, image = true},
	{name = "text_shaping", source = "modules/text_shaping", image = true},
	{name = "vector_glyphs", source = "programs/vector_glyphs", image = true},
	{name = "interface_font", source = "programs/interface_font", image = true},
	{name = "pointers", source = "programs/pointers", image = true},
	{name = "settings", source = "programs/settings", image = true},
	{name = "date", source = "programs/date", image = true},
}

// The folder of the modules of this build, and whether the compiler writes
// debug information: a module process receives both from its command.
module_build_folder := MODULE_BUILD_FOLDER
debug_information := true

join :: proc(parts: ..string) -> string {
	return strings.concatenate(parts, context.temp_allocator)
}

module_path :: proc(name: string) -> string {
	return join(module_build_folder, "/", name, ".module")
}

build_modules :: proc() -> bool {
	// One process for each module, several at once (parallel_build.odin).
	build_modules_in_parallel() or_return
	// The debug objects, beside the modules, in one file for the boot volumes.
	debug_image_write() or_return
	// The pointer themes: the resources of the boot image (pointers.odin).
	resources := build_pointer_themes(os.get_env(POINTER_THEME_SOURCE_VARIABLE, context.temp_allocator), false) or_return
	// The glyph caches of the default font and of the interface font: five more resources (vector_fonts.odin).
	glyph_caches := build_glyph_caches() or_return
	all_resources := make([dynamic]Resource_File, context.temp_allocator)
	append(&all_resources, ..resources)
	append(&all_resources, ..glyph_caches[:])
	// The second boot image has no compositor: with it, the start fails.
	// The third has no input service: the root service starts only the
	// program shortage (the test of the shortage of frames).
	return build_boot_image(BOOT_IMAGE, "", all_resources[:]) && build_boot_image(BOOT_IMAGE_FAILS, "compositor", all_resources[:]) && build_boot_image(BOOT_IMAGE_SHORTAGE, "input", all_resources[:])
}

// files_with_suffix gives the paths of the files of a folder that end with suffix.
files_with_suffix :: proc(folder, suffix: string) -> (paths: []string, ok: bool) {
	entries, err := os.read_all_directory_by_path(folder, context.temp_allocator)
	if err != nil {
		fmt.eprintfln("kerneltool: cannot list %s: %v", folder, err)
		return nil, false
	}
	list := make([dynamic]string, context.temp_allocator)
	for entry in entries {
		if strings.has_suffix(entry.name, suffix) {
			append(&list, join(folder, "/", entry.name))
		}
	}
	slice.sort(list[:])
	return list[:], true
}

// The checks of the kernel: the lock order at each take (TEST_BUILD_CHECKS_LOCK_ORDER)
// and the sums of the frames at each report and each drain, with a drain
// of all the frame caches at each 64th refill (TEST_BUILD_CHECKS_FRAME_SUMS). The test
// build has them (`check`, `test`, `screenshots`, `measure`, `run`); the
// measure build has none (`measure without_checks`, `run without_checks`). The tool
// passes the two defines in each build: the defaults of the source never
// decide.
test_build_checks := true
// A measure run of the windows: the programs write the time of their
// pictures (display.MEASURE_RUN, `kerneltool measure windows`).
measure_run := false

// build_module compiles a package to objects, assembles its .asm files, links
// all with lld into one position-independent object, and converts that
// object into a module.
build_module :: proc(build: Module_Build) -> bool {
	folder := join(module_build_folder, "/", build.name)
	objects := join(folder, "/objects")
	reset_folder(objects) or_return
	llvm_ir_folder := join(folder, "/llvm_ir")
	reset_folder(llvm_ir_folder) or_return
	compile := make([dynamic]string, context.temp_allocator)
	append(
		&compile,
		"odin",
		"build",
		build.source,
		"-target:freestanding_amd64_sysv",
		// LLVM IR, then llc: Odin has no option that keeps the frame pointers
		// (rule 8 of docs/MODULE_CONTRACT.md); llc has one.
		"-build-mode:llvm-ir",
		"-reloc-mode:pic",
		"-no-entry-point",
		"-default-to-nil-allocator",
		"-o:speed",
		"-vet",
		// The file name and the line in a message of a check, not the full path:
		// the hash of a module does not depend on the folder of the build.
		"-source-code-locations:filename",
		CONTRACT_LIBRARY,
		join("-out:", llvm_ir_folder),
	)
	// The line program of DWARF, for the line table of the debug object.
	// The module itself has no byte of it: the converter copies the
	// segments only, and `check` proves that each module is the same bytes
	// without it.
	if debug_information {
		append(&compile, "-debug")
	}
	for define in build.defines {
		append(&compile, strings.concatenate({"-define:", define}, context.temp_allocator))
	}
	if build.kernel {
		append(&compile, "-disable-red-zone")
		append(&compile, test_build_checks ? "-define:TEST_BUILD_CHECKS_LOCK_ORDER=true" : "-define:TEST_BUILD_CHECKS_LOCK_ORDER=false")
		append(&compile, test_build_checks ? "-define:TEST_BUILD_CHECKS_FRAME_SUMS=true" : "-define:TEST_BUILD_CHECKS_FRAME_SUMS=false")
	} else {
		append(&compile, SUPPORT_LIBRARY) // The kernel has the contract library only.
		if measure_run {
			append(&compile, "-define:MEASURE_RUN=true")
		}
	}
	run(compile[:]) or_return
	// Odin writes the IR in the folder of -out, with the name of the first
	// package of the module. The folder was empty: its one .ll file is the IR.
	llvm_ir_files := files_with_suffix(llvm_ir_folder, ".ll") or_return
	if len(llvm_ir_files) != 1 {
		fmt.eprintfln("kerneltool: the compiler wrote %d LLVM IR files for %s; one module is one file", len(llvm_ir_files), build.name)
		return false
	}
	if err := file_move(llvm_ir_files[0], join(folder, "/", build.name, ".ll")); err != nil {
		fmt.eprintfln("kerneltool: cannot move the LLVM IR of %s: %v", build.name, err)
		return false
	}
	// The LLVM of the Odin compiler (18) makes the object. Each function keeps
	// its frame pointer: the kernel walks them for the stack trace of a fault.
	llc := make([dynamic]string, context.temp_allocator)
	append(&llc, "llc", "-O3", "--frame-pointer=all", "-relocation-model=pic", "--function-sections", "--data-sections", "-filetype=obj")
	if build.kernel {
		// The kernel has no x87, SSE or AVX instruction: the registers of a
		// program stay live through each kernel entry, and only the switch
		// of threads saves them (docs/ARCHITECTURE.md, "The extended state
		// of the processor"). These features hold for all of the IR only
		// while no function of it has target features of its own: a
		// function attribute would take the place of -mattr for that
		// function. The disassembly after the link would find its vector
		// instructions; this test gives the cause first.
		ir := read_file(join(folder, "/", build.name, ".ll")) or_return
		if strings.contains(string(ir), "\"target-features\"") {
			fmt.eprintfln("kerneltool: the LLVM IR of %s has functions with target features of their own: the features of llc for the kernel would not hold for them", build.name)
			return false
		}
		append(&llc, KERNEL_TARGET_FEATURES)
	}
	append(&llc, "-o", join(objects, "/", build.name, ".o"), join(folder, "/", build.name, ".ll"))
	run(llc[:]) or_return
	assembly := make([dynamic]string, context.temp_allocator)
	append(&assembly, RUNTIME_MEMORY)
	append(&assembly, ..(files_with_suffix(build.source, ".asm") or_return))
	if build.image {
		// A program uses the system library, which has instructions of its own.
		append(&assembly, ..(files_with_suffix(SYSTEM_LIBRARY_FOLDER, ".asm") or_return))
	}
	for source in assembly {
		name := source[strings.last_index(source, "/") + 1:]
		if build.kernel && source == RUNTIME_MEMORY {
			// The kernel form of the copies: no vector register.
			run({"nasm", "-f", "elf64", "-DWITHOUT_VECTOR_REGISTERS", "-o", join(objects, "/", name, ".o"), source}) or_return
		} else {
			run({"nasm", "-f", "elf64", "-o", join(objects, "/", name, ".o"), source}) or_return
		}
	}

	// Only the exports of the module are visible in the linked object.
	script := strings.builder_make(context.temp_allocator)
	strings.write_string(&script, "{ global: ")
	description := describe_package(build.source) or_return
	for export in description.exports {
		fmt.sbprintf(&script, "%s; ", export.name)
	}
	strings.write_string(&script, "local: *; };\n")
	script_path := join(folder, "/exports.version")
	if err := os.write_entire_file(script_path, strings.to_string(script)); err != nil {
		fmt.eprintfln("kerneltool: cannot write %s: %v", script_path, err)
		return false
	}

	linked := join(folder, "/linked.elf")
	link := make([dynamic]string, context.temp_allocator)
	append(
		&link,
		"ld.lld",
		"-shared",
		"-nostdlib",
		"-Bsymbolic",
		"--gc-sections",
		"--build-id=none",
		"-z",
		"now",
		"-z",
		"relro",
		join("--version-script=", script_path),
		"-o",
		linked,
	)
	append(&link, ..(files_with_suffix(objects, ".o") or_return))
	run(link[:]) or_return
	if build.kernel && !kernel_has_no_vector_instruction(linked) {
		return false
	}

	elf := read_file(linked) or_return
	imports := make([dynamic]Import_File, context.temp_allocator)
	for name in build.imports {
		append(&imports, Import_File{name = name, file = read_file(module_path(name)) or_return})
	}
	file := convert(build.name, elf, description, imports[:]) or_return
	defer delete(file)
	if err := os.write_entire_file(module_path(build.name), file); err != nil {
		fmt.eprintfln("kerneltool: cannot write %s: %v", module_path(build.name), err)
		return false
	}
	if debug_information {
		debug_object_write(build.name, elf, file) or_return
	}
	return true
}

// build_boot_image writes the modules that have `image` set, then the
// resources, into one block (boot_info/boot_info.odin). It leaves out the
// module `without`. A resource has its name and the hash of its bytes, as a
// module. This image has no system description: each boot
// volume gets a copy with its own (system_description.odin).
build_boot_image :: proc(path: string, without: string, resources: []Resource_File) -> bool {
	files := make([dynamic]Image_File, context.temp_allocator)
	for build in module_builds {
		if !build.image || build.name == without {
			continue
		}
		append(&files, Image_File{name = build.name, file = read_file(module_path(build.name)) or_return})
	}
	module_count := len(files)
	for resource in resources {
		append(&files, Image_File{name = resource.name, file = read_file(resource.path) or_return})
	}
	image := boot_image_encode(files[:], module_count)
	if err := os.write_entire_file(path, image); err != nil {
		fmt.eprintfln("kerneltool: cannot write %s: %v", path, err)
		return false
	}
	return true
}

// One file of a boot image: a module or a resource.
Image_File :: struct {
	name: string,
	file: []u8,
}

// boot_image_encode gives the bytes of a boot image: the header, the table
// of the first module_count files (the modules), the table of the others
// (the resources), then each file on a page boundary, each entry with the
// BLAKE3 hash of its file.
boot_image_encode :: proc(files: []Image_File, module_count: int) -> []u8 {
	entries := make([]info.Image_Entry, len(files), context.temp_allocator)
	image := make([dynamic]u8, context.temp_allocator)
	resize(&image, size_of(info.Image_Header) + len(files) * size_of(info.Image_Entry))
	for item, index in files {
		entries[index].hash = blake3.hash(item.file)
		entries[index].size = u64(len(item.file))
		copy(entries[index].name[:info.IMAGE_NAME_SIZE - 1], item.name)
		resize(&image, mem.align_forward_int(len(image), info.PAGE_SIZE))
		entries[index].offset = u64(len(image))
		append(&image, ..item.file)
	}
	header := info.Image_Header{magic = info.IMAGE_MAGIC, count = u32(module_count), resource_count = u32(len(files) - module_count)}
	mem.copy(&image[0], &header, size_of(header))
	if len(entries) > 0 {
		mem.copy(&image[size_of(header)], &entries[0], len(entries) * size_of(info.Image_Entry))
	}
	return image[:]
}

read_file :: proc(path: string) -> (data: []u8, ok: bool) {
	err: os.Error
	data, err = os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		fmt.eprintfln("kerneltool: cannot read %s: %v", path, err)
		return nil, false
	}
	return data, true
}

// A module that the tool loaded in its own address space.
Host_Module :: struct {
	file:   []u8,
	memory: []u8,
}

// load_on_host loads a module in the address space of this tool, with the
// loader code that the system uses (package module). imports are the loaded
// modules of the import table, in order.
load_on_host :: proc(name: string, imports: []Host_Module) -> (loaded: Host_Module, ok: bool) {
	fail :: proc(name: string, format: string, args: ..any) -> (Host_Module, bool) {
		fmt.eprintf("kerneltool: load %s: ", name)
		fmt.eprintfln(format, ..args)
		return {}, false
	}
	file := read_file(module_path(name)) or_return
	if error := module.validate(file); error != .None {
		return fail(name, "%v", error)
	}
	head, _ := module.header(file)
	if int(module.count(file, .Imports)) != len(imports) + 1 {
		return fail(name, "the module has %d imports; %d were given", module.count(file, .Imports) - 1, len(imports))
	}
	bound := make([dynamic]module.Bound_Import, context.temp_allocator)
	for item, index in imports {
		record, _ := module.record(file, .Imports, u32(index + 1), module.Import)
		if record.hash != blake3.hash(item.file) {
			return fail(name, "import %d does not have the hash that the module names", index + 1)
		}
		append(&bound, module.Bound_Import{file = item.file, base = uintptr(raw_data(item.memory))})
	}

	address, map_error := linux.mmap(0, uint(head.memory_size), {.READ, .WRITE}, {.PRIVATE, .ANONYMOUS})
	if map_error != .NONE {
		return fail(name, "cannot reserve %d bytes: %v", head.memory_size, map_error)
	}
	memory := ([^]u8)(address)[:head.memory_size]
	module.copy_segments(file, memory)
	if error := module.rebase(file, memory, uintptr(address)); error != .None {
		return fail(name, "rebase: %v", error)
	}
	if error: module.Load_Error; !module.bind(file, memory, bound[:], &error) {
		return fail(name, "bind: %v of slot %d", error.stage, error.slot)
	}
	for index in 1 ..< module.count(file, .Segments) {
		segment, _ := module.record(file, .Segments, index, module.Segment)
		protection: linux.Mem_Protection
		if .Read in segment.flags {protection += {.READ}}
		if .Write in segment.flags && .Read_Only_After_Load not_in segment.flags {protection += {.WRITE}}
		if .Execute in segment.flags {protection += {.EXEC}}
		if error := linux.mprotect(raw_data(memory[segment.memory_offset:]), uint(segment.memory_size), protection); error != .NONE {
			return fail(name, "cannot protect segment %d: %v", index, error)
		}
	}
	return {file = file, memory = memory}, true
}

// test_descriptions reads the description of each export from a module
// file, and compares it with the source of the module.
test_descriptions :: proc() -> bool {
	type_names := [module.Type]string {
		.None    = "None",
		.Integer = "Integer",
		.Text    = "Text",
		.Record  = "Record",
		.Handle  = "Handle",
		.Table   = "Table",
		.Bytes   = "Bytes",
	}
	for build in module_builds {
		file := read_file(module_path(build.name)) or_return
		described := describe_package(build.source) or_return
		exports := described.exports
		about, text := module.documentation(file)
		if about != described.about || text != described.text || about == "" {
			fmt.eprintfln("kerneltool: test failed: the documentation of %s does not agree with its source", build.name)
			return false
		}
		if int(module.count(file, .Exports)) != len(exports) + 1 {
			fmt.eprintfln("kerneltool: test failed: %s has %d exports, its source has %d", build.name, module.count(file, .Exports) - 1, len(exports))
			return false
		}
		last := strings.builder_make(context.temp_allocator)
		for description, index in exports {
			function, ok := module.function(file, u32(index + 1))
			agree :=
				ok &&
				module.string_at(file, function.name_offset, function.name_count) == description.name &&
				module.string_at(file, function.about_offset, function.about_count) == description.about &&
				module.string_at(file, function.text_offset, function.text_count) == description.text &&
				int(function.parameter_count) == len(description.parameters) &&
				function.result == description.result &&
				function.result_detail == description.result_detail &&
				function.error_record == description.error_record
			strings.builder_reset(&last)
			fmt.sbprintf(&last, "%s(", description.name)
			for parameter in 0 ..< (agree ? len(description.parameters) : 0) {
				parameter_name := module.string_at(file, function.parameter_names[parameter], u32(function.parameter_name_counts[parameter]))
				agree &&= function.parameters[parameter] == description.parameters[parameter] && parameter_name == description.names[parameter]
				agree &&= function.parameter_details[parameter] == description.details[parameter]
				agree &&= function.parameter_directions[parameter] == description.directions[parameter]
				fmt.sbprintf(&last, "%s%s: %s", parameter > 0 ? ", " : "", parameter_name, type_names[function.parameters[parameter]])
			}
			fmt.sbprintf(&last, ") -> %s", type_names[description.result])
			if !agree {
				fmt.eprintfln("kerneltool: test failed: the description of %s in %s does not agree with its source", description.name, build.name)
				return false
			}
		}
		// The records: the file has the layout that the tool read in the source.
		if int(max(module.count(file, .Records), 1)) != len(described.records) + 1 {
			fmt.eprintfln("kerneltool: test failed: %s has %d records, its source has %d", build.name, int(module.count(file, .Records)) - 1, len(described.records))
			return false
		}
		for item, index in described.records {
			record, ok := module.record_type(file, u32(index + 1))
			agree := ok && module.string_at(file, record.name_offset, record.name_count) == item.name && record.size == item.size && int(record.field_count) == len(item.fields)
			layout := strings.builder_make(context.temp_allocator)
			fmt.sbprintf(&layout, "%s {{", item.name)
			for field, number in (agree ? item.fields : nil) {
				stored, _ := module.field(file, record, u32(number))
				agree &&= module.string_at(file, stored.name_offset, stored.name_count) == field.name && stored.offset == field.offset && stored.type == field.type && stored.detail == field.detail && stored.unsigned == field.unsigned
				fmt.sbprintf(&layout, "%s%s: %s at %d", number > 0 ? ", " : "", field.name, type_names[field.type], field.offset)
			}
			if !agree {
				fmt.eprintfln("kerneltool: test failed: the record %s in %s does not agree with its source", item.name, build.name)
				return false
			}
			test_passed_print("the record %s}}, %d bytes, of %s comes from its source", strings.to_string(layout), item.size, build.name)
		}
		if build.name == "math" {
			test_passed_print("the documentation of %s comes from its source: \"%s\", and %d bytes of text", build.name, about, len(text))
		}
		if len(exports) > 1 {
			test_passed_print("the %d descriptions of %s come from its source; the last is %s", len(exports), build.name, strings.to_string(last))
		}
	}
	return true
}

MODULE_TEST_RESULT :: (10 * 3 + 1) + (10 * 2 + 2)

// test_modules loads test_callee and test_caller on the host, and calls the
// entry of test_caller. The entry calls test_callee through an import slot.
test_modules :: proc() -> bool {
	callee := load_on_host("test_callee", nil) or_return
	caller := load_on_host("test_caller", {callee}) or_return
	head, _ := module.header(caller.file)
	address, ok := module.export_address(caller.file, uintptr(raw_data(caller.memory)), head.entry_export)
	if !ok {
		fmt.eprintln("kerneltool: test failed: test_caller has no entry")
		return false
	}
	entry := cast(proc "c" (context_address: rawptr) -> i64)rawptr(address)
	result := entry(nil)
	if result != MODULE_TEST_RESULT {
		fmt.eprintfln("kerneltool: test failed: the entry of test_caller gave %d, not %d", result, MODULE_TEST_RESULT)
		return false
	}
	hash := blake3.hash(callee.file)
	test_passed_print(
		"test_caller called test_callee (%d bytes, %d rebase words, hash %x...) and got %d",
		len(callee.file),
		module.count(callee.file, .Rebases),
		hash[:4],
		result,
	)
	return true
}

// file_move renames a file, or copies it and removes the source when the
// two paths are on two file systems (build/ can be a link to another disk:
// /tmp/disk, when the memory file system of the computer is full).
file_move :: proc(source, destination: string) -> os.Error {
	if err := os.rename(source, destination); err == nil {
		return nil
	}
	if err := os.copy_file(destination, source); err != nil {
		return err
	}
	return os.remove(source)
}
