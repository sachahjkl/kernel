package kerneltool

import "../../blake3"
import module "../../module"
import "core:fmt"
import info "../../boot_info"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sys/linux"

MODULE_BUILD_FOLDER :: BUILD_FOLDER + "/modules"
BOOT_IMAGE :: BUILD_FOLDER + "/boot.image"
BOOT_IMAGE_FAILS :: BUILD_FOLDER + "/boot_fails.image"
SYSTEM_LIBRARY_FOLDER :: "system"

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
}

module_builds := [?]Module_Build {
	{name = "test_callee", source = "modules/test_callee"},
	{name = "test_caller", source = "modules/test_caller", imports = {"test_callee"}},
	{name = "kernel", source = "kernel", kernel = true},
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
	{name = "budget", source = "programs/budget", image = true},
	{name = "processors", source = "programs/processors", image = true},
	{name = "boot", source = "programs/boot", image = true},
	{name = "pages", source = "programs/pages", image = true},
	{name = "host", source = "programs/host", image = true},
	{name = "probe", source = "modules/probe", image = true},
	{name = "math", source = "modules/math", image = true},
}

join :: proc(parts: ..string) -> string {
	return strings.concatenate(parts, context.temp_allocator)
}

module_path :: proc(name: string) -> string {
	return join(MODULE_BUILD_FOLDER, "/", name, ".module")
}

build_modules :: proc() -> bool {
	for build in module_builds {
		build_module(build) or_return
	}
	// The second boot image has no compositor: with it, the start fails.
	return build_boot_image(BOOT_IMAGE, "") && build_boot_image(BOOT_IMAGE_FAILS, "compositor")
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

// build_module compiles a package to objects, assembles its .asm files, links
// all with lld into one position-independent object, and converts that
// object into a module.
build_module :: proc(build: Module_Build) -> bool {
	folder := join(MODULE_BUILD_FOLDER, "/", build.name)
	objects := join(folder, "/objects")
	reset_folder(objects) or_return
	compile := make([dynamic]string, context.temp_allocator)
	append(
		&compile,
		"odin",
		"build",
		build.source,
		"-target:freestanding_amd64_sysv",
		"-build-mode:obj",
		"-reloc-mode:pic",
		"-no-entry-point",
		"-no-crt",
		"-default-to-nil-allocator",
		"-o:speed",
		"-vet",
		join("-out:", objects, "/", build.name, ".o"),
	)
	if build.kernel {
		append(&compile, "-disable-red-zone")
	}
	run(compile[:]) or_return
	assembly := make([dynamic]string, context.temp_allocator)
	append(&assembly, ..(files_with_suffix(build.source, ".asm") or_return))
	if build.image {
		// A program uses the system library, which has instructions of its own.
		append(&assembly, ..(files_with_suffix(SYSTEM_LIBRARY_FOLDER, ".asm") or_return))
	}
	for source in assembly {
		name := source[strings.last_index(source, "/") + 1:]
		run({"nasm", "-f", "elf64", "-o", join(objects, "/", name, ".o"), source}) or_return
	}

	// Only the exports of the module are visible in the linked object.
	script := strings.builder_make(context.temp_allocator)
	strings.write_string(&script, "{ global: ")
	exports := describe_package(build.source) or_return
	for export in exports {
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

	elf := read_file(linked) or_return
	imports := make([dynamic]Import_File, context.temp_allocator)
	for name in build.imports {
		append(&imports, Import_File{name = name, file = read_file(module_path(name)) or_return})
	}
	file := convert(build.name, elf, exports, imports[:]) or_return
	defer delete(file)
	if err := os.write_entire_file(module_path(build.name), file); err != nil {
		fmt.eprintfln("kerneltool: cannot write %s: %v", module_path(build.name), err)
		return false
	}
	return true
}

// build_boot_image writes the modules that have `image` set into one block
// (boot_info/boot_info.odin). It leaves out the module `without`.
build_boot_image :: proc(path: string, without: string) -> bool {
	entries := make([dynamic]info.Image_Entry, context.temp_allocator)
	files := make([dynamic][]u8, context.temp_allocator)
	for build in module_builds {
		if !build.image || build.name == without {
			continue
		}
		file := read_file(module_path(build.name)) or_return
		entry := info.Image_Entry{hash = blake3.hash(file), size = u64(len(file))}
		copy(entry.name[:info.IMAGE_NAME_SIZE - 1], build.name)
		append(&entries, entry)
		append(&files, file)
	}
	image := make([dynamic]u8, context.temp_allocator)
	resize(&image, size_of(info.Image_Header) + len(entries) * size_of(info.Image_Entry))
	for file, index in files {
		resize(&image, mem.align_forward_int(len(image), info.PAGE_SIZE))
		entries[index].offset = u64(len(image))
		append(&image, ..file)
	}
	header := info.Image_Header{magic = info.IMAGE_MAGIC, count = u32(len(entries))}
	mem.copy(&image[0], &header, size_of(header))
	if len(entries) > 0 {
		mem.copy(&image[size_of(header)], &entries[0], len(entries) * size_of(info.Image_Entry))
	}
	if err := os.write_entire_file(path, image[:]); err != nil {
		fmt.eprintfln("kerneltool: cannot write %s: %v", path, err)
		return false
	}
	return true
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
	import_files := make([dynamic][]u8, context.temp_allocator)
	import_bases := make([dynamic]uintptr, context.temp_allocator)
	for item, index in imports {
		record, _ := module.record(file, .Imports, u32(index + 1), module.Import)
		if record.hash != blake3.hash(item.file) {
			return fail(name, "import %d does not have the hash that the module names", index + 1)
		}
		append(&import_files, item.file)
		append(&import_bases, uintptr(raw_data(item.memory)))
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
	if error := module.bind(file, memory, import_files[:], import_bases[:]); error != .None {
		return fail(name, "bind: %v", error)
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
	}
	for build in module_builds {
		file := read_file(module_path(build.name)) or_return
		exports := describe_package(build.source) or_return
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
				int(function.parameter_count) == len(description.parameters) &&
				function.result == description.result
			strings.builder_reset(&last)
			fmt.sbprintf(&last, "%s(", description.name)
			for parameter in 0 ..< (agree ? len(description.parameters) : 0) {
				parameter_name := module.string_at(file, function.parameter_names[parameter], u32(function.parameter_name_counts[parameter]))
				agree &&= function.parameters[parameter] == description.parameters[parameter] && parameter_name == description.names[parameter]
				fmt.sbprintf(&last, "%s%s: %s", parameter > 0 ? ", " : "", parameter_name, type_names[function.parameters[parameter]])
			}
			fmt.sbprintf(&last, ") -> %s", type_names[description.result])
			if !agree {
				fmt.eprintfln("kerneltool: test failed: the description of %s in %s does not agree with its source", description.name, build.name)
				return false
			}
		}
		if len(exports) > 1 {
			fmt.printfln("kerneltool: test passed: the %d descriptions of %s come from its source; the last is %s", len(exports), build.name, strings.to_string(last))
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
	fmt.printfln(
		"kerneltool: test passed: test_caller called test_callee (%d bytes, %d rebase words, hash %x...) and got %d",
		len(callee.file),
		module.count(callee.file, .Rebases),
		hash[:4],
		result,
	)
	return true
}
