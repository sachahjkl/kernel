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
SYSTEM_LIBRARY_FOLDER :: "system"

// The modules of the project, each one after its imports.
//   source:  the folder of the Odin package, and of its .asm files.
//   exports: export n + 1 of the module is exports[n]. The description must
//            agree with the source: no tool checks it yet.
//   kernel:  the module runs in kernel mode: interrupts use its stack.
//   image:   the module is in the boot image.
Module_Build :: struct {
	name:    string,
	source:  string,
	exports: []Export_Description,
	imports: []string,
	kernel:  bool,
	image:   bool,
}

module_builds := [?]Module_Build {
	{name = "test_callee", source = "modules/test_callee", exports = {{name = "apply", parameters = {.Integer, .Integer}, result = .Integer}}},
	{name = "test_caller", source = "modules/test_caller", exports = {{name = "entry"}}, imports = {"test_callee"}},
	{name = "kernel", source = "kernel", exports = {{name = "entry"}}, kernel = true},
	{name = "root", source = "programs/root", exports = {{name = "entry"}}, image = true},
	{name = "input", source = "programs/input", exports = {{name = "entry"}}, image = true},
	{name = "compositor", source = "programs/compositor", exports = {{name = "entry"}}, image = true},
	{name = "console", source = "programs/console", exports = {{name = "entry"}}, image = true},
	{name = "monitor", source = "programs/monitor", exports = {{name = "entry"}}, image = true},
	{name = "plasma", source = "programs/plasma", exports = {{name = "entry"}}, image = true},
	{name = "life", source = "programs/life", exports = {{name = "entry"}}, image = true},
	{name = "paint", source = "programs/paint", exports = {{name = "entry"}}, image = true},
	{name = "fault", source = "programs/fault", exports = {{name = "entry"}}, image = true},
	{name = "temple", source = "programs/temple", exports = {{name = "entry"}}, image = true},
	{
		name = "math",
		source = "modules/math",
		image = true,
		exports = {
			{name = "gcd", parameters = {.Integer, .Integer}, result = .Integer, about = "the greatest common divisor"},
			{name = "power", parameters = {.Integer, .Integer}, result = .Integer, about = "an integer to a power"},
			{name = "fibonacci", parameters = {.Integer}, result = .Integer, about = "the Fibonacci number of an index"},
			{name = "next_prime", parameters = {.Integer}, result = .Integer, about = "the first prime number from an integer"},
			{name = "number", parameters = {.Text}, result = .Integer, about = "the integer that a text holds"},
		},
	},
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
	return build_boot_image()
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
	for export in build.exports {
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
	file := convert(build.name, elf, build.exports, imports[:]) or_return
	defer delete(file)
	if err := os.write_entire_file(module_path(build.name), file); err != nil {
		fmt.eprintfln("kerneltool: cannot write %s: %v", module_path(build.name), err)
		return false
	}
	return true
}

// build_boot_image writes the modules that have `image` set into one block
// (boot_info/boot_info.odin).
build_boot_image :: proc() -> bool {
	entries := make([dynamic]info.Image_Entry, context.temp_allocator)
	files := make([dynamic][]u8, context.temp_allocator)
	for build in module_builds {
		if !build.image {
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
	if err := os.write_entire_file(BOOT_IMAGE, image[:]); err != nil {
		fmt.eprintfln("kerneltool: cannot write %s: %v", BOOT_IMAGE, err)
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
