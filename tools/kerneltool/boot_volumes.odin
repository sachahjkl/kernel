package kerneltool

import "modus:contract/blake3"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

// The boot volumes of the build: what each one is, how one is built, when
// one is kept, and which ones a command needs
// (docs/TOOLS.md, "The incremental build").
//
// Each boot volume has its own boot program, because the boot program
// holds its boot image and its kernel (`#load`). So each volume has its own
// object folder and its own build record, and the volumes that must be
// built are built at the same time, each in its own process of this tool
// (the command `volume`), as the modules are (parallel_build.odin).
//
// The files of two volume processes never meet. A volume process writes
// only: the folder `build/boot/<name>` (the objects, the boot program, its
// signed copy, the list of the compiler), the boot image of the volume and
// the changed kernel beside the volume, the volume, and the file that says
// which key signed it. Each of these paths holds the name of the volume.
// The variable store of Secure Boot belongs to one volume only. The public
// key of the system, which every boot program loads, is written one time by
// the process that leads the build, before the first volume process starts.
//
// A command builds only the volumes that it boots. A volume that a command
// does not need stays as it is, with its record: the next command that
// needs it compares its record with the inputs of that time, and builds it
// when they differ. A machine starts only from a volume that this process
// built or kept (boot_volume_is_ready).

// One boot volume of the build. Its path is its identity.
Boot_Volume :: struct {
	path:                       string, // The volume file.
	image:                      string, // The boot image of the build that its boot image is made from.
	kernel:                     string, // The module of the table that its boot program holds as the kernel.
	self_test:                  int, // The test of the kernel on itself, or 0.
	change:                     Image_Change, // What a test of a refusal changes.
	firmware_signature:         Firmware_Signature,
	// The build of this volume also writes the variable store of Secure
	// Boot: every machine with Secure Boot on is in the part of this volume.
	with_secure_boot_variables: bool,
}

// The file of the boot program in the object folder of a volume.
BOOT_PROGRAM_FILE_NAME :: "BOOTX64.EFI"
BOOT_PROGRAM_SIGNED_FILE_NAME :: "BOOTX64.signed.EFI"
BOOT_PROGRAM_OBJECT_FILE_NAME :: "boot.obj"
// The name of the main volume: the name of its object folder.
MAIN_BOOT_VOLUME_NAME :: "main"

// boot_volumes gives every boot volume of the build: 13 fixed ones and one
// for each test of the kernel on itself. The list is new at each call: the
// path of a self test volume is a text of the temporary memory.
boot_volumes :: proc() -> []Boot_Volume {
	volumes := make([dynamic]Boot_Volume, context.temp_allocator)
	// A start that fails (no compositor), and a shortage of frames (no
	// input service): the two other boot images of the build.
	append(&volumes, Boot_Volume{path = BOOT_VOLUME_FAILS, image = BOOT_IMAGE_FAILS, kernel = "kernel"})
	append(&volumes, Boot_Volume{path = BOOT_VOLUME_SHORTAGE, image = BOOT_IMAGE_SHORTAGE, kernel = "kernel"})
	// A measure run: the modules of the test, and the resource that tells
	// the root service that the machine runs for a measure.
	append(&volumes, Boot_Volume{path = BOOT_VOLUME_MEASURE, image = BOOT_IMAGE_MEASURE, kernel = "kernel"})
	// The kernel with one check skipped.
	append(&volumes, Boot_Volume{path = BOOT_VOLUME_WITHOUT_RETURN_CHECK, image = BOOT_IMAGE, kernel = "kernel_without_return_check"})
	// The volumes of the trusted boot that the boot program must refuse, and
	// another system that it must accept and measure.
	append(&volumes, Boot_Volume{path = BOOT_VOLUME_CHANGED_MODULE, image = BOOT_IMAGE, kernel = "kernel", change = {module_changed_after_description = CHANGED_MODULE}})
	append(&volumes, Boot_Volume{path = BOOT_VOLUME_WRONG_SIGNATURE, image = BOOT_IMAGE, kernel = "kernel", change = {signature_changed = true}})
	append(&volumes, Boot_Volume{path = BOOT_VOLUME_OTHER_SYSTEM, image = BOOT_IMAGE, kernel = "kernel", change = {module_changed_before_description = OTHER_SYSTEM_MODULE}})
	append(&volumes, Boot_Volume{path = BOOT_VOLUME_CHANGED_KERNEL, image = BOOT_IMAGE, kernel = "kernel", change = {kernel_changed_after_description = true}})
	append(&volumes, Boot_Volume{path = BOOT_VOLUME_WITHOUT_DESCRIPTION, image = BOOT_IMAGE, kernel = "kernel", change = {description_left_out = true}})
	append(&volumes, Boot_Volume{path = BOOT_VOLUME_STATED_HASH, image = BOOT_IMAGE, kernel = "kernel", change = {stated_hash_changed_module = CHANGED_MODULE}})
	// Secure Boot: the boot program signed with the firmware signing key
	// (with the variable store that enrols its certificate), and the same
	// with one byte changed.
	append(&volumes, Boot_Volume{path = BOOT_VOLUME_SECURE_BOOT, image = BOOT_IMAGE, kernel = "kernel", firmware_signature = .Signed, with_secure_boot_variables = true})
	append(&volumes, Boot_Volume{path = BOOT_VOLUME_SECURE_BOOT_CHANGED, image = BOOT_IMAGE, kernel = "kernel", firmware_signature = .Signed_Then_Changed})
	// One volume for each test of the kernel on itself.
	for test in self_tests {
		append(&volumes, Boot_Volume{path = fmt.tprintf(BOOT_VOLUME_SELF_TEST, test.number), image = BOOT_IMAGE, kernel = "kernel", self_test = test.number})
	}
	append(&volumes, Boot_Volume{path = BOOT_VOLUME, image = BOOT_IMAGE, kernel = "kernel"})
	return volumes[:]
}

// boot_volume_name gives the short name of a volume, from its path:
// "main" for `boot_volume.img`, "self_test_3" for
// `boot_volume_self_test_3.img`. It names the object folder and the build
// record of the volume, and it is the argument of the command `volume`.
boot_volume_name :: proc(path: string) -> string {
	name := strings.trim_suffix(path[strings.last_index_byte(path, '/') + 1:], ".img")
	name = strings.trim_prefix(name, "boot_volume")
	name = strings.trim_prefix(name, "_")
	return name == "" ? MAIN_BOOT_VOLUME_NAME : name
}

// The object folder of a volume: no other volume writes in it.
boot_volume_folder :: proc(volume: Boot_Volume) -> string {
	return join(BOOT_OBJECT_FOLDER, "/", boot_volume_name(volume.path))
}

boot_volume_program_path :: proc(volume: Boot_Volume) -> string {
	return join(boot_volume_folder(volume), "/", BOOT_PROGRAM_FILE_NAME)
}

boot_volume_signed_program_path :: proc(volume: Boot_Volume) -> string {
	return join(boot_volume_folder(volume), "/", BOOT_PROGRAM_SIGNED_FILE_NAME)
}

boot_volume_object_path :: proc(volume: Boot_Volume) -> string {
	return join(boot_volume_folder(volume), "/", BOOT_PROGRAM_OBJECT_FILE_NAME)
}

// The list of the files that the compiler of the boot program read.
boot_volume_dependency_file :: proc(volume: Boot_Volume) -> string {
	return join(boot_volume_folder(volume), "/", DEPENDENCY_FILE_NAME)
}

// The build record is beside the object folder, not in it: the build of
// the volume empties the folder.
boot_volume_record_path :: proc(volume: Boot_Volume) -> string {
	return join(boot_volume_folder(volume), BUILD_RECORD_SUFFIX)
}

// boot_volume_kernel_module_path gives the kernel module that the boot
// program of a volume holds: the module of the build, or the copy with one
// byte changed that boot_image_signed_write writes beside the volume.
boot_volume_kernel_module_path :: proc(volume: Boot_Volume) -> string {
	if volume.change.kernel_changed_after_description {
		return join(strings.trim_suffix(signed_image_path(volume.path), ".image"), "_kernel.module")
	}
	return module_path(volume.kernel)
}

// boot_program_compile_command gives the command of the compiler for the
// boot program of a volume. Each flag is an input of the build key.
boot_program_compile_command :: proc(volume: Boot_Volume) -> []string {
	command := make([dynamic]string, context.temp_allocator)
	// The compiler reads the file of a `#load` from the folder of the boot
	// program; the tool names each file from the root of the repository.
	to_root := path_from_folder_to_root(SOURCE_FOLDER_BOOT)
	append(
		&command,
		"odin",
		"build",
		SOURCE_FOLDER_BOOT,
		"-target:freestanding_amd64_win64",
		"-build-mode:obj",
		"-no-entry-point",
		"-default-to-nil-allocator",
		"-disable-red-zone",
		"-o:speed",
		"-vet",
		"-source-code-locations:filename", // No path of the folder of the build in the program.
		// The list of the files that the compiler read: the inputs of the
		// build key of the volume.
		"-export-dependencies:json",
		join("-export-dependencies-file:", boot_volume_dependency_file(volume)),
		SOURCE_LIBRARY_FLAG,
		join("-define:BOOT_IMAGE=", to_root, signed_image_path(volume.path)),
		join("-define:SYSTEM_PUBLIC_KEY=", to_root, SYSTEM_PUBLIC_KEY_FILE),
		fmt.tprintf("-define:SELF_TEST=%d", volume.self_test),
		join("-define:KERNEL_MODULE=", to_root, boot_volume_kernel_module_path(volume)),
		join("-out:", boot_volume_object_path(volume)),
	)
	return command[:]
}

// The assembly file of the boot program: the jump to the kernel.
BOOT_PROGRAM_JUMP_SOURCE :: SOURCE_FOLDER_BOOT + "/jump.asm"

// The two assembly files of the boot program, and the object of each.
boot_program_jump_command :: proc(volume: Boot_Volume) -> []string {
	command := make([dynamic]string, context.temp_allocator)
	append(&command, "nasm", "-f", "win64", "-o", join(boot_volume_folder(volume), "/jump.obj"), BOOT_PROGRAM_JUMP_SOURCE)
	return command[:]
}

boot_program_memory_command :: proc(volume: Boot_Volume) -> []string {
	command := make([dynamic]string, context.temp_allocator)
	append(&command, "nasm", "-f", "win64", "-DWIN64", "-o", join(boot_volume_folder(volume), "/memory.obj"), RUNTIME_MEMORY)
	return command[:]
}

// boot_program_link_command gives the command of the linker with no
// object: the build adds the objects of the folder.
boot_program_link_command :: proc(volume: Boot_Volume) -> [dynamic]string {
	command := make([dynamic]string, context.temp_allocator)
	append(&command, "lld-link", "/subsystem:efi_application", "/entry:efi_main", "/nodefaultlib", join("/out:", boot_volume_program_path(volume)))
	return command
}

// boot_volume_recorded_outputs gives the files of a volume that a machine
// or a test reads: the volume, its boot image (the test of the measure
// reads its system description), the file that says which key signed it,
// and the variable store of Secure Boot. The build record holds the hash of
// each one. The boot program, its object and the changed kernel in the
// object folder are read only by the build of the volume itself, and by the
// checks that compare two whole builds: as for the object of a module, the
// record does not hold them, and a kept volume does not prove them.
boot_volume_recorded_outputs :: proc(volume: Boot_Volume) -> []string {
	outputs := make([dynamic]string, context.temp_allocator)
	append(&outputs, volume.path, signed_image_path(volume.path), signed_by_file_path(volume.path))
	if volume.with_secure_boot_variables {
		append(&outputs, SECURE_BOOT_VARIABLES)
	}
	return outputs[:]
}

// file_write_with_a_hole_at_its_end writes a file whose last bytes are
// zero without those bytes: it writes up to the last byte that is not zero,
// then gives the file its whole size. The file system stores no block for
// the end, and a read of it gives zero bytes: a reader, QEMU with a raw
// disk too, sees the same bytes as with a whole write, and so does the hash
// of the build record, which reads the content. A boot volume is 64 MiB,
// and its files fill only its start.
file_write_with_a_hole_at_its_end :: proc(path: string, data: []u8) -> bool {
	used := len(data)
	for used > 0 && data[used - 1] == 0 {
		used -= 1
	}
	file, open_error := os.open(path, {.Write, .Create, .Trunc}, os.Permissions_Default_File)
	if open_error != nil {
		fmt.eprintfln("kerneltool: cannot write %s: %v", path, open_error)
		return false
	}
	written, write_error := os.write(file, data[:used])
	size_error := os.truncate(file, i64(len(data)))
	close_error := os.close(file)
	if write_error != nil || size_error != nil || close_error != nil || written != used {
		fmt.eprintfln("kerneltool: cannot write %s", path)
		return false
	}
	return true
}

// boot_volume_build builds one boot volume in this process: the boot image
// of the volume with its system description and its description signature
// (system_description.odin), the boot program that holds it, and the volume
// file. It writes only files of this volume. The public key of the system
// is there before: system_public_key_write.
boot_volume_build :: proc(volume: Boot_Volume) -> bool {
	seconds :: proc(duration: time.Duration) -> f64 {
		return time.duration_seconds(duration)
	}
	folder := boot_volume_folder(volume)
	step_started := time.tick_now()
	signed_image := signed_image_path(volume.path)
	signed := boot_image_signed_write(volume.image, volume.kernel, signed_image, volume.change) or_return
	if signed.kernel_module_path != boot_volume_kernel_module_path(volume) {
		// The build key names the kernel module of the volume by this path.
		fmt.eprintfln("kerneltool: the kernel module of %s is %s, and the build key expects %s", volume.path, signed.kernel_module_path, boot_volume_kernel_module_path(volume))
		return false
	}
	signed_image_time := time.tick_since(step_started)
	step_started = time.tick_now()
	reset_folder(folder) or_return
	run(boot_program_compile_command(volume)) or_return
	compile_time := time.tick_since(step_started)
	step_started = time.tick_now()
	run(boot_program_jump_command(volume)) or_return
	run(boot_program_memory_command(volume)) or_return
	objects := files_with_suffix(folder, ".obj") or_return
	link := boot_program_link_command(volume)
	append(&link, ..objects)
	run(link[:]) or_return
	program_path := boot_volume_program_path(volume)
	if volume.firmware_signature != .None {
		boot_program_sign(volume.firmware_signature, program_path, boot_volume_signed_program_path(volume)) or_return
		program_path = boot_volume_signed_program_path(volume)
	}
	if volume.with_secure_boot_variables {
		secure_boot_variables_write() or_return
	}
	link_time := time.tick_since(step_started)
	step_started = time.tick_now()
	program := read_file(program_path) or_return
	// The debug image is a file of its own beside the boot program: the boot
	// program and the boot image are the same bytes with and without it.
	debug_image := read_file(DEBUG_IMAGE) or_return
	files := make([]Volume_File, 2, context.temp_allocator)
	files[0] = {
		path = BOOT_PROGRAM_PATH,
		data = program,
	}
	files[1] = {
		path = DEBUG_IMAGE_VOLUME_PATH,
		data = debug_image,
	}
	volume_bytes, fits := volume_encode(files, context.temp_allocator)
	if !fits {
		fmt.eprintln("kerneltool: the boot program and the debug image do not fit in the boot volume")
		return false
	}
	file_write_with_a_hole_at_its_end(volume.path, volume_bytes) or_return
	// Beside the volume: which key signed it. A volume that the test keys
	// signed is for a test machine only.
	signed_by := signed.signed_by_test_key ? "the TEST signing key, whose private key is published: do not install this volume on a real machine\n" : "the signing key of SYSTEM_SIGNING_KEY\n"
	if write_err := os.write_entire_file(signed_by_file_path(volume.path), signed_by); write_err != nil {
		fmt.eprintfln("kerneltool: cannot write %s: %v", signed_by_file_path(volume.path), write_err)
		return false
	}
	write_time := time.tick_since(step_started)
	fmt.printfln("kerneltool: measure: the build of the boot volume %s: the signed boot image %.2f s, the compiler of the boot program %.2f s, the assembler, the link and the firmware signature %.2f s, the volume file %.2f s", boot_volume_name(volume.path), seconds(signed_image_time), seconds(compile_time), seconds(link_time), seconds(write_time))
	return true
}

// main_boot_volume_build builds the main boot volume in this process, with
// no build record read: the checks that compare two builds run the compiler
// of the boot program again (repeat.odin).
main_boot_volume_build :: proc() -> bool {
	make_folder(BOOT_OBJECT_FOLDER) or_return
	system_public_key_write() or_return
	for volume in boot_volumes() {
		if volume.path == BOOT_VOLUME {
			return boot_volume_build(volume)
		}
	}
	return false
}

// The command volume: build one boot volume in this process. The build
// runs it for each volume that it must build; a developer can run it to
// see the errors of one volume alone, after a build wrote the modules, the
// boot images and the public key of the system.
run_volume :: proc(args: []string) -> int {
	if len(args) == 1 {
		for volume in boot_volumes() {
			if boot_volume_name(volume.path) == args[0] {
				// The process that leads the build said which key signs.
				signing_key_said = true
				return boot_volume_build(volume) ? 0 : EXIT_FAILURE
			}
		}
	}
	names := strings.builder_make(context.temp_allocator)
	for volume, index in boot_volumes() {
		fmt.sbprintf(&names, "%s%s", index > 0 ? ", " : "", boot_volume_name(volume.path))
	}
	fmt.eprintfln("kerneltool: volume <name>; the names: %s", strings.to_string(names))
	return EXIT_USAGE
}

// What the build keys of all the volumes of one build share: read one time,
// after the modules and the boot images were written and before the first
// volume process starts.
Boot_Volume_Shared_Inputs :: struct {
	tool_identity: blake3.Hash,
	// The programs that build and sign, and the values of the environment
	// that the build of a volume reads.
	settings:      []string,
	// The outputs of the earlier steps of the build that a volume reads:
	// each boot image, the debug image, each kernel, the public key of the
	// system. A file that cannot be read is not in the list.
	built_files:   []Record_Output,
}

// boot_volume_shared_inputs_read hashes each built file that a volume of
// the table reads, one time for all the volumes.
boot_volume_shared_inputs_read :: proc(volumes: []Boot_Volume) -> Boot_Volume_Shared_Inputs {
	paths := make([dynamic]string, context.temp_allocator)
	append(&paths, DEBUG_IMAGE, SYSTEM_PUBLIC_KEY_FILE)
	for volume in volumes {
		for path in ([]string{volume.image, module_path(volume.kernel)}) {
			known := false
			for earlier in paths {
				known = known || earlier == path
			}
			if !known {
				append(&paths, path)
			}
		}
	}
	contents := file_contents_read_in_parallel(paths[:], context.temp_allocator)
	built_files := make([dynamic]Record_Output, context.temp_allocator)
	for path, index in paths {
		if contents[index].readable {
			append(&built_files, Record_Output{path = path, hash = contents[index].hash})
		}
	}
	settings := make([dynamic]string, context.temp_allocator)
	append(&settings, ..build_inputs.volume_programs[:])
	append(&settings, join("OVMF_FULL_VARS=", os.get_env("OVMF_FULL_VARS", context.temp_allocator)))
	return {tool_identity = build_inputs.tool_identity, settings = settings[:], built_files = built_files[:]}
}

// boot_volume_key_inputs gives the inputs of the build key of one volume:
// the boot image of the build that it is made from, its kernel, the debug
// image and the public key of the system as they are now, each command of
// its build with each flag, what the volume is (its self test, its change,
// its firmware signature), the assembly files, the test keys, the programs
// that build and sign, the tool, and the sources of the boot program (the
// list of its compiler). ok is false when a built file cannot be read.
boot_volume_key_inputs :: proc(volume: Boot_Volume, shared: Boot_Volume_Shared_Inputs, source_files, load_files: []string) -> (inputs: Build_Key_Inputs, ok: bool) {
	settings := make([dynamic]string, context.temp_allocator)
	append(&settings, ..shared.settings)
	append(&settings, "the compiler")
	append(&settings, ..boot_program_compile_command(volume))
	append(&settings, "the assembler")
	append(&settings, ..boot_program_jump_command(volume))
	append(&settings, ..boot_program_memory_command(volume))
	append(&settings, "the linker")
	link := boot_program_link_command(volume)
	append(&settings, ..link[:])
	append(&settings, "the volume", volume.path, volume.image, volume.kernel)
	append(&settings, fmt.tprintf("self test %d", volume.self_test))
	append(&settings, fmt.tprintf("change %v", volume.change))
	append(&settings, fmt.tprintf("firmware signature %v", volume.firmware_signature))
	append(&settings, volume.with_secure_boot_variables ? "with the variable store of Secure Boot" : "with no variable store")
	fixed_files := make([dynamic]string, context.temp_allocator)
	append(&fixed_files, BOOT_PROGRAM_JUMP_SOURCE, RUNTIME_MEMORY, TEST_SIGNING_KEY_FILE)
	if volume.firmware_signature != .None || volume.with_secure_boot_variables {
		append(&fixed_files, TEST_FIRMWARE_SIGNING_KEY_FILE, TEST_FIRMWARE_CERTIFICATE_FILE)
	}
	built_files := make([dynamic]Record_Output, context.temp_allocator)
	for path in ([]string{volume.image, module_path(volume.kernel), DEBUG_IMAGE, SYSTEM_PUBLIC_KEY_FILE}) {
		found := false
		for file in shared.built_files {
			if file.path == path {
				append(&built_files, file)
				found = true
				break
			}
		}
		if !found {
			return {}, false
		}
	}
	inputs = {
		subject            = join("boot volume ", boot_volume_name(volume.path)),
		tool_identity      = shared.tool_identity,
		settings           = settings[:],
		fixed_files        = fixed_files[:],
		hashed_built_files = built_files[:],
		source_files       = source_files,
		load_files         = load_files,
	}
	return inputs, true
}

// The refusal to keep a volume that the signing key of the publisher of
// the system signs: the tool never hashes that key, so it cannot prove the
// inputs of such a volume.
SIGNING_KEY_REASON :: "the signing key of the publisher of the system signs: its volumes are never kept"

// boot_volumes_kept says, for each volume of a list, if its files are
// those of this build with no build: its record has the build key of its
// inputs as they are now, and each output is there with its recorded hash.
// The outputs of all the volumes whose key is the same are read and hashed
// at once, on several threads: a volume is 64 MiB, and one volume after the
// other costs the hash of each one on one thread. reasons says why a volume
// is built.
boot_volumes_kept :: proc(volumes: []Boot_Volume, shared: Boot_Volume_Shared_Inputs) -> (kept: []bool, reasons: []string) {
	kept = make([]bool, len(volumes), context.temp_allocator)
	reasons = make([]string, len(volumes), context.temp_allocator)
	refusal := ""
	switch {
	case build_whole:
		refusal = "a whole build"
	case build_inputs.table == nil || !build_inputs.usable:
		refusal = "a source of the tool cannot be read"
	case os.get_env(SIGNING_KEY_VARIABLE, context.temp_allocator) != "":
		refusal = SIGNING_KEY_REASON
	}
	if refusal != "" {
		for &reason in reasons {
			reason = refusal
		}
		return
	}
	// The volumes whose record has the key of now, and the paths of their
	// outputs, in the order of the volumes.
	records := make([]Build_Record, len(volumes), context.temp_allocator)
	paths := make([dynamic]string, context.temp_allocator)
	for volume, index in volumes {
		inputs, readable := boot_volume_key_inputs(volume, shared, nil, nil)
		if !readable {
			reasons[index] = "an input cannot be read"
			continue
		}
		records[index], kept[index], reasons[index] = recorded_build_has_its_key(boot_volume_record_path(volume), inputs, build_inputs.table)
		if kept[index] && !record_names_each_output(records[index], boot_volume_recorded_outputs(volume)) {
			kept[index] = false
			reasons[index] = OUTPUT_CHANGED_REASON
		}
		if kept[index] {
			for output in records[index].outputs {
				append(&paths, output.path)
			}
		}
	}
	contents := file_contents_read_in_parallel(paths[:], context.temp_allocator)
	first := 0
	for index in 0 ..< len(volumes) {
		if !kept[index] {
			continue
		}
		count := len(records[index].outputs)
		if !record_outputs_have_their_hashes(records[index], contents[first:][:count]) {
			kept[index] = false
			reasons[index] = OUTPUT_CHANGED_REASON
		}
		first += count
	}
	return
}

// boot_volume_record_write writes the build record of a volume that was
// just built. output_contents is what the caller read of the recorded
// outputs of the volume, in their order. With no list of the compiler,
// with an input that changed during the build, or with the signing key of
// the publisher of the system, it writes none.
boot_volume_record_write :: proc(volume: Boot_Volume, shared: Boot_Volume_Shared_Inputs, output_contents: []File_Content) -> bool {
	record_path := boot_volume_record_path(volume)
	_ = os.remove(record_path)
	if build_inputs.table == nil || !build_inputs.usable || os.get_env(SIGNING_KEY_VARIABLE, context.temp_allocator) != "" {
		return false
	}
	source_files, load_files, listed := dependency_list_read(boot_volume_dependency_file(volume))
	if !listed {
		return false
	}
	// The files of `#load` are outputs of this build: the key holds them as
	// built files.
	inputs, readable := boot_volume_key_inputs(volume, shared, paths_outside_the_build_folder(source_files), paths_outside_the_build_folder(load_files))
	if !readable {
		return false
	}
	key, complete := build_key(inputs, build_inputs.table, true)
	if !complete {
		return false
	}
	return build_record_write_of_contents(record_path, key, boot_volume_recorded_outputs(volume), output_contents, inputs.source_files, inputs.load_files)
}

// The boot volumes that this process built or kept in its last build: a
// machine starts only from one of them. A volume that the command did not
// ask for can be the volume of older sources.
boot_volumes_ready: [dynamic]string

boot_volumes_ready_forget :: proc() {
	for path in boot_volumes_ready {
		delete(path)
	}
	delete(boot_volumes_ready)
	boot_volumes_ready = nil
}

boot_volume_ready_note :: proc(path: string) {
	if !boot_volume_is_ready(path) {
		append(&boot_volumes_ready, strings.clone(path))
	}
}

boot_volume_is_ready :: proc(path: string) -> bool {
	for ready in boot_volumes_ready {
		if ready == path {
			return true
		}
	}
	return false
}

// The most volume processes at once when the command gives no count. Each
// volume process runs one compiler with `-o:speed` on a boot program that
// holds a boot image of 11 MB and a kernel, and holds the volume of 64 MiB
// in its own memory; the compiler also starts its own threads for the
// packages of the boot program. The work of one process is mostly on one
// thread (the one LLVM module that holds the image), so one process for
// each processor is the right count on a small host; the bound keeps the
// memory of all the processes under a few gigabytes on a large one.
MOST_BOOT_VOLUME_PROCESSES :: 8

// boot_volume_processes gives the count of volume processes at once: the
// count of `build <processes>`, or the count of the processors, at most
// MOST_BOOT_VOLUME_PROCESSES.
boot_volume_processes :: proc(volume_count: int, asked: int, processors: int) -> int {
	processes := asked
	if processes <= 0 {
		processes = min(processors, MOST_BOOT_VOLUME_PROCESSES)
	}
	return max(1, min(processes, volume_count))
}

// The names of the built volumes that the line of the kept volumes prints.
BUILT_VOLUME_NAMES_MOST :: 19

// boot_volumes_build builds or keeps each boot volume that a command
// needs. needed_paths names them by their paths; nil is every volume. A
// volume whose build record has the build key of its inputs, and whose
// outputs have their recorded hashes, is kept: it starts no process. The
// others are built at the same time, each in its own process.
boot_volumes_build :: proc(needed_paths: []string) -> bool {
	boot_volumes_ready_forget()
	make_folder(BOOT_OBJECT_FOLDER) or_return
	// Every boot program loads this file: it is written before the first
	// volume process starts, and no volume process writes it.
	system_public_key_write() or_return
	all := boot_volumes()
	needed := make([dynamic]Boot_Volume, context.temp_allocator)
	if needed_paths == nil {
		append(&needed, ..all)
	} else {
		for path in needed_paths {
			found := false
			for volume in all {
				if volume.path == path {
					append(&needed, volume)
					found = true
				}
			}
			if !found {
				fmt.eprintfln("kerneltool: %s is not a boot volume of the build", path)
				return false
			}
		}
	}
	checks_started := time.tick_now()
	shared := boot_volume_shared_inputs_read(all)
	to_build := make([dynamic]Boot_Volume, context.temp_allocator)
	built_names := strings.builder_make(context.temp_allocator)
	kept_count := 0
	kept, reasons := boot_volumes_kept(needed[:], shared)
	for volume, index in needed {
		if kept[index] {
			kept_count += 1
			boot_volume_ready_note(volume.path)
			continue
		}
		append(&to_build, volume)
		if len(to_build) <= BUILT_VOLUME_NAMES_MOST {
			fmt.sbprintf(&built_names, "%s%s (%s)", len(to_build) > 1 ? ", " : "", boot_volume_name(volume.path), reasons[index])
		}
		// The record of the last build does not stay beside files that a
		// build is about to change.
		_ = os.remove(boot_volume_record_path(volume))
	}
	build_measure_step("the checks of the build records of the boot volumes, with the hash of each kept volume", checks_started)
	not_needed := len(all) - len(needed)
	not_needed_text := not_needed > 0 ? fmt.tprintf("; %d not needed by this command, and not checked", not_needed) : ""
	if len(to_build) == 0 {
		fmt.printfln("kerneltool: %d of %d boot volumes kept: the inputs of each one are the same, and its files have their recorded hashes%s", kept_count, len(all), not_needed_text)
	} else if kept_count > 0 || not_needed > 0 || !build_whole {
		fmt.printfln("kerneltool: %d of %d boot volumes kept, %d built: %s%s", kept_count, len(all), len(to_build), strings.to_string(built_names), not_needed_text)
	}
	build_measure.volumes_kept = kept_count
	build_measure.volumes_not_needed = not_needed
	if len(to_build) == 0 {
		return true
	}
	// The file of this process, not its first argument (parallel_build.odin).
	tool_path, path_error := os.get_executable_path(context.temp_allocator)
	if path_error != nil {
		fmt.eprintfln("kerneltool: cannot find the file of the tool: %v", path_error)
		return false
	}
	commands := make([][]string, len(to_build), context.temp_allocator)
	for volume, place in to_build {
		command := make([]string, 3, context.temp_allocator)
		command[0] = tool_path
		command[1] = "volume"
		command[2] = boot_volume_name(volume.path)
		commands[place] = command
	}
	processes := boot_volume_processes(len(to_build), module_build_processes, os.get_processor_core_count())
	build_measure.volume_processes = processes
	outcomes := build_processes_run(commands, processes, context.temp_allocator)
	defer {
		for outcome in outcomes {
			delete(outcome.output)
		}
	}
	failed := false
	not_started := 0
	for volume, place in to_build {
		outcome := outcomes[place]
		if len(outcome.output) > 0 {
			os.write(os.stdout, outcome.output)
		}
		if !outcome.started {
			not_started += 1
		} else if !outcome.success {
			fmt.eprintfln("kerneltool: the build of the boot volume %s failed", boot_volume_name(volume.path))
			failed = true
		}
	}
	if failed || not_started > 0 {
		fmt.eprintfln("kerneltool: %d of %d boot volumes did not start, because a volume failed", not_started, len(to_build))
		return false
	}
	writes_started := time.tick_now()
	// The recorded outputs of all the built volumes are read and hashed at
	// once, on several threads.
	output_paths := make([dynamic]string, context.temp_allocator)
	for volume in to_build {
		append(&output_paths, ..boot_volume_recorded_outputs(volume))
	}
	output_contents := file_contents_read_in_parallel(output_paths[:], context.temp_allocator)
	first_output := 0
	for volume, place in to_build {
		build_measure.volumes_built += 1
		append(&build_measure.volume_times, Build_Step_Time{name = strings.clone(boot_volume_name(volume.path)), duration = outcomes[place].duration})
		output_count := len(boot_volume_recorded_outputs(volume))
		volume_contents := output_contents[first_output:][:output_count]
		first_output += output_count
		if !boot_volume_record_write(volume, shared, volume_contents) && build_inputs.usable && os.get_env(SIGNING_KEY_VARIABLE, context.temp_allocator) == "" {
			fmt.printfln("kerneltool: no build record for the boot volume %s: the compiler gave no list of its files, or an input changed during the build; the next build builds it again", boot_volume_name(volume.path))
		}
		// The volume is the volume of this build, with or without a record.
		boot_volume_ready_note(volume.path)
	}
	build_measure_step("the build records of the built boot volumes, with the hash of each volume", writes_started)
	return true
}

// The boot volumes of one part of the machine test, or of one other
// command that starts a machine. procedures names each procedure of the
// tool that starts a machine of the part: a host test reads the sources and
// checks that each volume that such a procedure names is in volumes
// (boot_volumes_test.odin).
Volumes_Of_Part :: struct {
	part:       string,
	procedures: []string,
	volumes:    []string, // The paths of the volumes.
}

// The table of the parts of `test`: one row for each part of test_parts.
// `test <part>` builds the volumes of its row only. The whole test builds
// every volume.
test_part_volumes := [?]Volumes_Of_Part {
	{part = "main", procedures = {"main_tests_run"}, volumes = {BOOT_VOLUME}},
	{part = "network", procedures = {"network_tests_run"}, volumes = {BOOT_VOLUME}},
	{part = "power", procedures = {"power_loss_run", "power_loss_sequence", "power_loss_settings_run", "power_loss_ranges_run"}, volumes = {BOOT_VOLUME}},
	{part = "hierarchy", procedures = {"hierarchy_tests_run"}, volumes = {BOOT_VOLUME}},
	{part = "ranges", procedures = {"ranges_tests_run"}, volumes = {BOOT_VOLUME}},
	{part = "tcp", procedures = {"tcp_tests_run"}, volumes = {BOOT_VOLUME}},
	{part = "quic", procedures = {"quic_tests_run"}, volumes = {BOOT_VOLUME}},
	{part = "quic-real", procedures = {"quic_real_tests_run"}, volumes = {BOOT_VOLUME}},
	{part = "crypto", procedures = {"cryptography_tests_run"}, volumes = {BOOT_VOLUME}},
	{part = "random", procedures = {"random_tests_run"}, volumes = {BOOT_VOLUME}},
	{part = "shortage", procedures = {"shortage_tests_run"}, volumes = {BOOT_VOLUME_SHORTAGE}},
	{part = "extended_state", procedures = {"extended_state_tests_run"}, volumes = {BOOT_VOLUME}},
	{part = "return_fault", procedures = {"return_fault_tests_run"}, volumes = {BOOT_VOLUME, BOOT_VOLUME_WITHOUT_RETURN_CHECK}},
	{part = "fault_ring", procedures = {"fault_ring_tests_run"}, volumes = {BOOT_VOLUME}},
	{part = "debugger", procedures = {"debugger_tests_run"}, volumes = {BOOT_VOLUME}},
	{part = "kernel_events", procedures = {"kernel_events_tests_run"}, volumes = {BOOT_VOLUME}},
	{part = "principals", procedures = {"principals_tests_run"}, volumes = {BOOT_VOLUME}},
	// With `trusted_boot tpm`, the two machines of the measure too: the
	// main volume and the other system.
	{
		part = "trusted_boot",
		procedures = {"trusted_boot_tests_run"},
		volumes = {BOOT_VOLUME, BOOT_VOLUME_CHANGED_MODULE, BOOT_VOLUME_WRONG_SIGNATURE, BOOT_VOLUME_OTHER_SYSTEM, BOOT_VOLUME_CHANGED_KERNEL, BOOT_VOLUME_WITHOUT_DESCRIPTION, BOOT_VOLUME_STATED_HASH, BOOT_VOLUME_SECURE_BOOT, BOOT_VOLUME_SECURE_BOOT_CHANGED},
	},
}

// The other commands that start a machine, and their volumes. Each form
// of `measure` boots the volume of a measure run, but `measure shortage`,
// which boots the volume of the shortage of frames. `screenshots` builds
// every volume, as the whole test that it runs first: its row names the
// volume of the measure runs that it starts after the test.
MEASURE_COMMAND :: "measure"
MEASURE_SHORTAGE_COMMAND :: "measure shortage"
command_volumes := [?]Volumes_Of_Part {
	{part = "run", procedures = {"run_machine"}, volumes = {BOOT_VOLUME}},
	{part = MEASURE_COMMAND, procedures = {"run_measure", "measure_windows", "measure_program_run"}, volumes = {BOOT_VOLUME_MEASURE}},
	{part = MEASURE_SHORTAGE_COMMAND, procedures = {"shortage_tests_run"}, volumes = {BOOT_VOLUME_SHORTAGE}},
	{part = "screenshots", procedures = {"measure_runs_of_the_record", "measure_program_run"}, volumes = {BOOT_VOLUME_MEASURE}},
	{part = "film", procedures = {"run_film"}, volumes = {BOOT_VOLUME}},
}

// boot_volumes_of_test gives the volumes that `test` with these arguments
// boots: those of the row of its part. nil is every volume: the whole test,
// and a part that has no row yet (a host test refuses such a table).
boot_volumes_of_test :: proc(args: []string) -> []string {
	if len(args) == 0 {
		return nil
	}
	for &row in test_part_volumes {
		if row.part == args[0] {
			return row.volumes
		}
	}
	return nil
}

// boot_volumes_of_command gives the volumes that a command of
// command_volumes boots; nil, every volume, for a command with no row.
boot_volumes_of_command :: proc(command: string) -> []string {
	for &row in command_volumes {
		if row.part == command {
			return row.volumes
		}
	}
	return nil
}
