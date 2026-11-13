package kerneltool

import "contract:blake3"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

// The table of the boot volumes: 13 fixed volumes and one for each test of
// the kernel on itself, each with its own name and its own files.
@(test)
boot_volume_table_gives_each_volume_its_own_files :: proc(t: ^testing.T) {
	volumes := boot_volumes()
	testing.expect_value(t, len(volumes), 13 + len(self_tests))
	testing.expect_value(t, len(volumes), 19)
	files := make([dynamic]string, context.temp_allocator)
	main_found := false
	for volume in volumes {
		testing.expectf(t, strings.has_prefix(volume.path, BUILD_FOLDER + "/boot_volume") && strings.has_suffix(volume.path, ".img"), "%s is a volume file of the build folder", volume.path)
		if volume.path == BOOT_VOLUME {
			main_found = true
			testing.expect_value(t, boot_volume_name(volume.path), MAIN_BOOT_VOLUME_NAME)
			testing.expect_value(t, boot_volume_program_path(volume), BOOT_PROGRAM)
			testing.expect_value(t, boot_volume_object_path(volume), BOOT_PROGRAM_OBJECT)
		}
		// What only this volume writes: its folder, its record, the list of
		// its compiler, and each recorded output.
		append(&files, boot_volume_name(volume.path), boot_volume_folder(volume), boot_volume_record_path(volume), boot_volume_dependency_file(volume), boot_volume_program_path(volume), boot_volume_object_path(volume), boot_volume_signed_program_path(volume))
		append(&files, ..boot_volume_recorded_outputs(volume))
		// The kernel module that the build key names is the module of the
		// table, or the changed copy of this volume.
		if volume.change.kernel_changed_after_description {
			testing.expect(t, strings.contains(boot_volume_kernel_module_path(volume), boot_volume_name(volume.path)), "the changed kernel has the name of its volume")
		} else {
			testing.expect_value(t, boot_volume_kernel_module_path(volume), module_path(volume.kernel))
		}
	}
	testing.expect(t, main_found, "the main boot volume is in the table")
	for file, index in files {
		for other in files[index + 1:] {
			testing.expectf(t, file != other, "%s belongs to one volume only", file)
		}
	}
	testing.expect_value(t, boot_volume_name(BUILD_FOLDER + "/boot_volume_self_test_3.img"), "self_test_3")
	testing.expect_value(t, boot_volume_name(BOOT_VOLUME_SHORTAGE), "shortage")
	testing.expect_value(t, boot_volume_name(BOOT_VOLUME_MEASURE), "measure")
	// The volume of a measure run has its own boot image.
	for volume in volumes {
		testing.expectf(t, (volume.path == BOOT_VOLUME_MEASURE) == (volume.image == BOOT_IMAGE_MEASURE), "only the volume of a measure run holds the boot image of a measure run: %s", volume.path)
	}
	// The variable store of Secure Boot is an output of one volume.
	stores := 0
	for volume in volumes {
		if volume.with_secure_boot_variables {
			stores += 1
			testing.expect_value(t, volume.path, BOOT_VOLUME_SECURE_BOOT)
		}
	}
	testing.expect_value(t, stores, 1)
}

@(private = "file")
row_has_volume :: proc(row: Volumes_Of_Part, path: string) -> bool {
	for volume in row.volumes {
		if volume == path {
			return true
		}
	}
	return false
}

// The table part -> volumes is complete: one row for each part of the
// machine test, and each volume of a row is a volume of the build.
@(test)
each_test_part_has_its_boot_volumes :: proc(t: ^testing.T) {
	volumes := boot_volumes()
	for part in test_parts {
		rows := 0
		for row in test_part_volumes {
			rows += row.part == part ? 1 : 0
		}
		testing.expectf(t, rows == 1, "the part %s has %d rows in test_part_volumes, and must have one: a part with no row builds every volume", part, rows)
		needed := boot_volumes_of_test([]string{part})
		testing.expectf(t, len(needed) > 0, "the part %s names its volumes", part)
	}
	for row in test_part_volumes {
		known := false
		for part in test_parts {
			known = known || part == row.part
		}
		testing.expectf(t, known, "the row %s is a part of the machine test", row.part)
	}
	for table in ([][]Volumes_Of_Part{test_part_volumes[:], command_volumes[:]}) {
		for row in table {
			testing.expectf(t, len(row.volumes) > 0 && len(row.procedures) > 0, "the row %s has its volumes and its procedures", row.part)
			for path in row.volumes {
				found := false
				for volume in volumes {
					found = found || volume.path == path
				}
				testing.expectf(t, found, "the volume %s of the row %s is a volume of the build", path, row.part)
			}
		}
	}
	// The whole test builds every volume.
	testing.expect(t, boot_volumes_of_test(nil) == nil, "the whole test builds every volume")
	testing.expect(t, boot_volumes_of_test([]string{"a part with no row"}) == nil, "a part with no row builds every volume")
	testing.expect(t, boot_volumes_of_command("a command with no row") == nil, "a command with no row builds every volume")
	// `trusted_boot tpm` boots the volume of the other system too.
	with_tpm := boot_volumes_of_test([]string{"trusted_boot", "tpm"})
	found_other_system, found_main := false, false
	for path in with_tpm {
		found_other_system = found_other_system || path == BOOT_VOLUME_OTHER_SYSTEM
		found_main = found_main || path == BOOT_VOLUME
	}
	testing.expect(t, found_other_system && found_main, "trusted_boot tpm builds the main volume and the other system")
	for command in ([]string{"run", MEASURE_COMMAND, MEASURE_SHORTAGE_COMMAND, "screenshots", "film"}) {
		testing.expectf(t, len(boot_volumes_of_command(command)) > 0, "the command %s names its volumes", command)
	}
	// Each form of `measure` boots the volume of a measure run, but
	// `measure shortage`.
	measure := boot_volumes_of_command(MEASURE_COMMAND)
	testing.expect(t, len(measure) == 1 && measure[0] == BOOT_VOLUME_MEASURE, "measure builds the volume of a measure run only")
	measure_shortage := boot_volumes_of_command(MEASURE_SHORTAGE_COMMAND)
	testing.expect(t, len(measure_shortage) == 1 && measure_shortage[0] == BOOT_VOLUME_SHORTAGE, "measure shortage builds the volume of the shortage only")
}

// The constants of the tool that name a boot volume, by their names in the
// sources. BOOT_VOLUME_SELF_TEST is the pattern of the self test volumes:
// only the whole test boots them.
@(private = "file")
volume_constants := [?][2]string {
	{"BOOT_VOLUME", BOOT_VOLUME},
	{"BOOT_VOLUME_FAILS", BOOT_VOLUME_FAILS},
	{"BOOT_VOLUME_SHORTAGE", BOOT_VOLUME_SHORTAGE},
	{"BOOT_VOLUME_MEASURE", BOOT_VOLUME_MEASURE},
	{"BOOT_VOLUME_WITHOUT_RETURN_CHECK", BOOT_VOLUME_WITHOUT_RETURN_CHECK},
	{"BOOT_VOLUME_SELF_TEST", BOOT_VOLUME_SELF_TEST},
	{"BOOT_VOLUME_CHANGED_MODULE", BOOT_VOLUME_CHANGED_MODULE},
	{"BOOT_VOLUME_WRONG_SIGNATURE", BOOT_VOLUME_WRONG_SIGNATURE},
	{"BOOT_VOLUME_OTHER_SYSTEM", BOOT_VOLUME_OTHER_SYSTEM},
	{"BOOT_VOLUME_CHANGED_KERNEL", BOOT_VOLUME_CHANGED_KERNEL},
	{"BOOT_VOLUME_WITHOUT_DESCRIPTION", BOOT_VOLUME_WITHOUT_DESCRIPTION},
	{"BOOT_VOLUME_STATED_HASH", BOOT_VOLUME_STATED_HASH},
	{"BOOT_VOLUME_SECURE_BOOT", BOOT_VOLUME_SECURE_BOOT},
	{"BOOT_VOLUME_SECURE_BOOT_CHANGED", BOOT_VOLUME_SECURE_BOOT_CHANGED},
}

// The procedures that only the whole test runs: it builds every volume.
@(private = "file")
whole_test_procedures := [?]string{"run_test", "self_tests_run", "persistence_run"}

// The procedures that name a volume and start no machine from it by that
// name: the table of the volumes, the build of the main volume for the
// checks of two builds, the refusal of a volume that is not ready, and the
// comparison of the machine test.
@(private = "file")
procedures_that_start_no_machine := [?]string{"boot_volumes", "main_boot_volume_build", "machine_command", "machine_test"}

// One volume constant in the body of one procedure of the tool.
@(private = "file")
Named_Volume :: struct {
	procedure: string,
	constant:  string,
}

@(private = "file")
is_identifier_byte :: proc(character: u8) -> bool {
	switch character {
	case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '_':
		return true
	}
	return false
}

// volumes_named_in_source finds each volume constant in the body of each
// procedure of one source file, and each procedure that the file declares.
// A procedure starts at a line `name :: proc` at the start of a line and
// ends at a line that is `}`. The text after `//` is a comment.
@(private = "file")
volumes_named_in_source :: proc(source: string, named: ^[dynamic]Named_Volume, declared: ^[dynamic]string) {
	procedure := ""
	rest := source
	for whole_line in strings.split_lines_iterator(&rest) {
		if whole_line == "}" {
			procedure = ""
			continue
		}
		line := whole_line
		if comment := strings.index(line, "//"); comment >= 0 {
			line = line[:comment]
		}
		if declaration := strings.index(line, " :: proc"); declaration > 0 && is_identifier_byte(line[0]) {
			procedure = line[:declaration]
			append(declared, procedure)
			continue
		}
		if procedure == "" {
			continue
		}
		for at := 0; at < len(line); {
			found := strings.index(line[at:], "BOOT_VOLUME")
			if found < 0 {
				break
			}
			start := at + found
			end := start
			for end < len(line) && is_identifier_byte(line[end]) {
				end += 1
			}
			// A longer name that holds these letters is another constant.
			if start == 0 || !is_identifier_byte(line[start - 1]) {
				append(named, Named_Volume{procedure = procedure, constant = line[start:end]})
			}
			at = end
		}
	}
}

// The reader of the sources finds a volume in a procedure, and not in a
// comment, in a table outside a procedure, or in a longer name.
@(test)
volume_constants_are_found_in_the_procedures_of_a_source :: proc(t: ^testing.T) {
	source := "BOOT_VOLUME :: \"a\"\ntable := [?]string {\n\tBOOT_VOLUME,\n}\n\n// first_run starts BOOT_VOLUME_FAILS.\nfirst_run :: proc() -> bool {\n\t// BOOT_VOLUME_SHORTAGE in a comment\n\treturn machine_test(steps[:], BOOT_VOLUME, output) && machine_test(steps[:], BOOT_VOLUME_SECURE_BOOT, MAIN_BOOT_VOLUME_NAME)\n}\n\nsecond_run :: proc() {\n\tx := self_test_file(BOOT_VOLUME_SELF_TEST, 1) // BOOT_VOLUME\n}\n"
	named := make([dynamic]Named_Volume, context.temp_allocator)
	declared := make([dynamic]string, context.temp_allocator)
	volumes_named_in_source(source, &named, &declared)
	testing.expect_value(t, len(declared), 2)
	testing.expect_value(t, len(named), 3)
	if len(named) == 3 {
		testing.expect_value(t, named[0], Named_Volume{procedure = "first_run", constant = "BOOT_VOLUME"})
		testing.expect_value(t, named[1], Named_Volume{procedure = "first_run", constant = "BOOT_VOLUME_SECURE_BOOT"})
		testing.expect_value(t, named[2], Named_Volume{procedure = "second_run", constant = "BOOT_VOLUME_SELF_TEST"})
	}
}

// Every boot volume that a procedure of the tool names is in the row of
// each part of that procedure: a part never boots a volume that its build
// did not build. The test reads the sources of the tool, from the root of
// the repository.
@(test)
each_volume_that_a_scenario_names_is_in_the_table_of_its_part :: proc(t: ^testing.T) {
	paths, listed := files_with_suffix(TOOL_SOURCE_FOLDER, ".odin")
	testing.expect(t, listed, "the test runs from the root of the repository")
	named := make([dynamic]Named_Volume, context.temp_allocator)
	declared := make([dynamic]string, context.temp_allocator)
	for path in paths {
		if strings.has_suffix(path, "_test.odin") {
			continue
		}
		source, error := os.read_entire_file(path, context.temp_allocator)
		testing.expectf(t, error == nil, "%s can be read", path)
		volumes_named_in_source(string(source), &named, &declared)
	}
	testing.expect(t, len(named) > 40, "the sources of the tool name the volumes in their procedures")
	is_declared :: proc(declared: []string, procedure: string) -> bool {
		for name in declared {
			if name == procedure {
				return true
			}
		}
		return false
	}
	// Each procedure of a table is a procedure of the tool: a name with a
	// mistake would check nothing.
	for table in ([][]Volumes_Of_Part{test_part_volumes[:], command_volumes[:]}) {
		for row in table {
			for procedure in row.procedures {
				testing.expectf(t, is_declared(declared[:], procedure), "the procedure %s of the row %s is a procedure of the tool", procedure, row.part)
			}
		}
	}
	for procedure in whole_test_procedures {
		testing.expectf(t, is_declared(declared[:], procedure), "the procedure %s of the whole test is a procedure of the tool", procedure)
	}
	for procedure in procedures_that_start_no_machine {
		testing.expectf(t, is_declared(declared[:], procedure), "the procedure %s is a procedure of the tool", procedure)
	}
	for item in named {
		path := ""
		for constant in volume_constants {
			if constant[0] == item.constant {
				path = constant[1]
			}
		}
		testing.expectf(t, path != "", "%s, in %s, is a volume constant that this test knows", item.constant, item.procedure)
		outside_the_parts := false
		for procedure in whole_test_procedures {
			outside_the_parts = outside_the_parts || procedure == item.procedure
		}
		for procedure in procedures_that_start_no_machine {
			outside_the_parts = outside_the_parts || procedure == item.procedure
		}
		if outside_the_parts || path == "" {
			continue
		}
		rows := 0
		for table in ([][]Volumes_Of_Part{test_part_volumes[:], command_volumes[:]}) {
			for row in table {
				in_row := false
				for procedure in row.procedures {
					in_row = in_row || procedure == item.procedure
				}
				if !in_row {
					continue
				}
				rows += 1
				testing.expectf(t, row_has_volume(row, path), "the procedure %s of the part %s names %s, which is not in the volumes of the part: the part would boot a volume that its build did not build", item.procedure, row.part, item.constant)
			}
		}
		testing.expectf(t, rows > 0, "the procedure %s names %s and is in no row of test_part_volumes or command_volumes", item.procedure, item.constant)
	}
}

// A small tree with the sources of a boot program, its assembly files and
// the test signing key, as the build key of a volume names them.
@(private = "file")
boot_tree_make :: proc(t: ^testing.T) -> (root: string) {
	folder, error := os.make_directory_temp("", "boot_volumes_test_*", context.temp_allocator)
	testing.expect_value(t, error, nil)
	for name in ([]string{"boot", "runtime", "resources/keys"}) {
		_ = os.make_directory_all(fmt.tprintf("%s/%s", folder, name))
	}
	boot_tree_file_write(folder, "boot/main.odin", "package boot\n\nefi_main :: proc() {}\n")
	boot_tree_file_write(folder, "boot/jump.asm", "global jump\njump: ret\n")
	boot_tree_file_write(folder, RUNTIME_MEMORY, "global copy\ncopy: ret\n")
	boot_tree_file_write(folder, TEST_SIGNING_KEY_FILE, "00\n")
	boot_tree_file_write(folder, TEST_FIRMWARE_SIGNING_KEY_FILE, "a key\n")
	boot_tree_file_write(folder, TEST_FIRMWARE_CERTIFICATE_FILE, "a certificate\n")
	return folder
}

@(private = "file")
boot_tree_file_write :: proc(root, name, text: string) {
	_ = os.write_entire_file(fmt.tprintf("%s/%s", root, name), text)
}

@(private = "file")
hash_of_text :: proc(text: string) -> blake3.Hash {
	return blake3.hash(transmute([]u8)text)
}

// The built files that the volumes of the tests read, with the hash of a
// text in place of the hash of a file.
@(private = "file")
shared_inputs_of_a_test :: proc(image_content: string) -> Boot_Volume_Shared_Inputs {
	built_files := make([dynamic]Record_Output, context.temp_allocator)
	append(&built_files, Record_Output{path = BOOT_IMAGE, hash = hash_of_text(image_content)})
	append(&built_files, Record_Output{path = BOOT_IMAGE_SHORTAGE, hash = hash_of_text("the image of the shortage")})
	append(&built_files, Record_Output{path = BOOT_IMAGE_MEASURE, hash = hash_of_text("the image of a measure run")})
	append(&built_files, Record_Output{path = module_path("kernel"), hash = hash_of_text("the kernel")})
	append(&built_files, Record_Output{path = DEBUG_IMAGE, hash = hash_of_text("the debug image")})
	append(&built_files, Record_Output{path = SYSTEM_PUBLIC_KEY_FILE, hash = hash_of_text("the public key")})
	settings := make([]string, 1, context.temp_allocator)
	settings[0] = "program odin: /store/odin"
	return {settings = settings, built_files = built_files[:]}
}

@(private = "file")
boot_sources :: proc(root: string) -> []string {
	sources := make([]string, 1, context.temp_allocator)
	sources[0] = fmt.tprintf("%s/boot/main.odin", root)
	return sources
}

// The key of a volume, with a new table: as a new build computes it.
@(private = "file")
volume_key_of_a_new_build :: proc(t: ^testing.T, root: string, volume: Boot_Volume, shared: Boot_Volume_Shared_Inputs) -> blake3.Hash {
	inputs, readable := boot_volume_key_inputs(volume, shared, boot_sources(root), nil)
	testing.expect(t, readable, "each built file of the volume has its hash")
	table := input_file_table_make(root, {"boot"})
	defer input_file_table_destroy(table)
	key, complete := build_key(inputs, table)
	testing.expect(t, complete, "each input of the tree can be read")
	return key
}

// The key of a volume changes with its boot image, its kernel, a flag of
// its compiler, what the volume is, a source of the boot program and an
// assembly file; two volumes never have the same key.
@(test)
boot_volume_key_changes_with_each_input :: proc(t: ^testing.T) {
	root := boot_tree_make(t)
	defer os.remove_all(root)
	main_volume := Boot_Volume{path = BOOT_VOLUME, image = BOOT_IMAGE, kernel = "kernel"}
	shared := shared_inputs_of_a_test("the boot image")
	first := volume_key_of_a_new_build(t, root, main_volume, shared)
	testing.expect_value(t, volume_key_of_a_new_build(t, root, main_volume, shared), first)

	testing.expect(t, volume_key_of_a_new_build(t, root, main_volume, shared_inputs_of_a_test("the boot image with one changed program")) != first, "another boot image changes the key")

	other_kernel := shared_inputs_of_a_test("the boot image")
	for &file in other_kernel.built_files {
		if file.path == module_path("kernel") {
			file.hash = hash_of_text("another kernel")
		}
	}
	testing.expect(t, volume_key_of_a_new_build(t, root, main_volume, other_kernel) != first, "another kernel changes the key")

	other_tool := shared
	other_tool.tool_identity[0] = 1
	testing.expect(t, volume_key_of_a_new_build(t, root, main_volume, other_tool) != first, "another identity of the tool changes the key")

	other_program := shared
	programs := make([]string, 1, context.temp_allocator)
	programs[0] = "program odin: /store/another_odin"
	other_program.settings = programs
	testing.expect(t, volume_key_of_a_new_build(t, root, main_volume, other_program) != first, "another compiler changes the key")

	// The same volume file with the flag of a self test: one flag of the
	// compiler differs.
	with_self_test := main_volume
	with_self_test.self_test = 3
	testing.expect(t, volume_key_of_a_new_build(t, root, with_self_test, shared) != first, "a flag of the compiler changes the key")

	with_change := main_volume
	with_change.change.signature_changed = true
	testing.expect(t, volume_key_of_a_new_build(t, root, with_change, shared) != first, "a change of the boot image changes the key")

	signed := main_volume
	signed.firmware_signature = .Signed
	testing.expect(t, volume_key_of_a_new_build(t, root, signed, shared) != first, "a firmware signature changes the key")

	shortage := Boot_Volume{path = BOOT_VOLUME_SHORTAGE, image = BOOT_IMAGE_SHORTAGE, kernel = "kernel"}
	testing.expect(t, volume_key_of_a_new_build(t, root, shortage, shared) != first, "another volume has another key")

	measure_volume := Boot_Volume{path = BOOT_VOLUME_MEASURE, image = BOOT_IMAGE_MEASURE, kernel = "kernel"}
	measure_key := volume_key_of_a_new_build(t, root, measure_volume, shared)
	testing.expect(t, measure_key != first, "the volume of a measure run has another key")
	// The boot image of a measure run is an input of its volume only.
	other_measure_image := shared_inputs_of_a_test("the boot image")
	for &file in other_measure_image.built_files {
		if file.path == BOOT_IMAGE_MEASURE {
			file.hash = hash_of_text("the image of a measure run with another resource")
		}
	}
	testing.expect(t, volume_key_of_a_new_build(t, root, measure_volume, other_measure_image) != measure_key, "another boot image of a measure run changes the key of its volume")
	testing.expect_value(t, volume_key_of_a_new_build(t, root, main_volume, other_measure_image), first)

	boot_tree_file_write(root, "boot/main.odin", "package boot\n\nefi_main :: proc() {_ = 1}\n")
	after_source := volume_key_of_a_new_build(t, root, main_volume, shared)
	testing.expect(t, after_source != first, "a byte of a source of the boot program changes the key")

	boot_tree_file_write(root, "boot/jump.asm", "global jump\njump: nop\nret\n")
	after_assembly := volume_key_of_a_new_build(t, root, main_volume, shared)
	testing.expect(t, after_assembly != after_source, "a byte of an assembly file changes the key")

	boot_tree_file_write(root, TEST_SIGNING_KEY_FILE, "01\n")
	testing.expect(t, volume_key_of_a_new_build(t, root, main_volume, shared) != after_assembly, "another test signing key changes the key")

	// A volume whose boot image has no hash has no key: it is built.
	without_return_check := Boot_Volume{path = BOOT_VOLUME_WITHOUT_RETURN_CHECK, image = BOOT_IMAGE, kernel = "kernel_without_return_check"}
	_, readable := boot_volume_key_inputs(without_return_check, shared, boot_sources(root), nil)
	testing.expect(t, !readable, "a kernel that cannot be read gives no key")
}

// A kept volume whose file changed is built again; so is a volume whose
// boot image or whose source changed, and a volume with no record.
@(test)
kept_boot_volume_with_a_changed_file_is_built_again :: proc(t: ^testing.T) {
	root := boot_tree_make(t)
	defer os.remove_all(root)
	volume_file := fmt.tprintf("%s/boot_volume.img", root)
	image_file := fmt.tprintf("%s/boot_volume.image", root)
	record_file := fmt.tprintf("%s/main%s", root, BUILD_RECORD_SUFFIX)
	_ = os.write_entire_file(volume_file, "the volume")
	_ = os.write_entire_file(image_file, "the signed boot image")
	main_volume := Boot_Volume{path = BOOT_VOLUME, image = BOOT_IMAGE, kernel = "kernel"}
	shared := shared_inputs_of_a_test("the boot image")
	sources := boot_sources(root)
	inputs, readable := boot_volume_key_inputs(main_volume, shared, nil, nil)
	testing.expect(t, readable, "each built file of the volume has its hash")
	key := volume_key_of_a_new_build(t, root, main_volume, shared)
	testing.expect(t, build_record_write(record_file, key, {volume_file, image_file}, sources, nil), "the record is written")

	decision :: proc(root, record_file: string, inputs: Build_Key_Inputs, outputs: []string) -> (kept: bool, reason: string) {
		table := input_file_table_make(root, {"boot"})
		defer input_file_table_destroy(table)
		return recorded_build_is_kept(record_file, inputs, table, outputs)
	}
	kept, reason := decision(root, record_file, inputs, {volume_file, image_file})
	testing.expectf(t, kept, "the volume is kept with the same inputs and the same files: %s", reason)

	_ = os.write_entire_file(volume_file, "the volume with one changed byte")
	kept, reason = decision(root, record_file, inputs, {volume_file, image_file})
	testing.expect(t, !kept, "a volume file that changed is built again")
	testing.expect_value(t, reason, "an output is absent or changed")

	_ = os.write_entire_file(volume_file, "the volume")
	kept, _ = decision(root, record_file, inputs, {volume_file, image_file})
	testing.expect(t, kept, "the same bytes again are the recorded volume")

	_ = os.remove(image_file)
	kept, reason = decision(root, record_file, inputs, {volume_file, image_file})
	testing.expect(t, !kept, "a missing boot image of the volume forces a build")
	testing.expect_value(t, reason, "an output is absent or changed")
	_ = os.write_entire_file(image_file, "the signed boot image")

	kept, reason = decision(root, record_file, inputs, {volume_file, image_file, fmt.tprintf("%s/BOOTX64.EFI", root)})
	testing.expect(t, !kept, "an output that the record does not name forces a build")

	other_image, other_readable := boot_volume_key_inputs(main_volume, shared_inputs_of_a_test("the boot image with one changed program"), nil, nil)
	testing.expect(t, other_readable)
	kept, reason = decision(root, record_file, other_image, {volume_file, image_file})
	testing.expect(t, !kept, "a volume whose boot image changed is built again")
	testing.expect_value(t, reason, "an input changed")

	boot_tree_file_write(root, "boot/main.odin", "package boot\n\nefi_main :: proc() {_ = 2}\n")
	kept, reason = decision(root, record_file, inputs, {volume_file, image_file})
	testing.expect(t, !kept, "a volume whose boot program changed is built again")
	testing.expect_value(t, reason, "an input changed")
	boot_tree_file_write(root, "boot/main.odin", "package boot\n\nefi_main :: proc() {}\n")
	kept, _ = decision(root, record_file, inputs, {volume_file, image_file})
	testing.expect(t, kept, "the same source again gives the recorded key")

	// The two parts of the decision, as the build of all the volumes uses
	// them: the key first, then the hashes of the outputs read at once.
	{
		table := input_file_table_make(root, {"boot"})
		defer input_file_table_destroy(table)
		record, same, _ := recorded_build_has_its_key(record_file, inputs, table)
		testing.expect(t, same, "the record has the key of the inputs")
		testing.expect(t, record_names_each_output(record, {volume_file, image_file}), "the record names each output")
		contents := file_contents_read_in_parallel({volume_file, image_file}, context.temp_allocator)
		testing.expect(t, record_outputs_have_their_hashes(record, contents), "each output has its recorded hash")
		testing.expect(t, !record_outputs_have_their_hashes(record, contents[:1]), "a list with one output less proves nothing")
		contents[0].hash[0] ~= 1
		testing.expect(t, !record_outputs_have_their_hashes(record, contents), "another hash of the volume file forces a build")
		testing.expect(t, !build_record_write_of_contents(fmt.tprintf("%s/other%s", root, BUILD_RECORD_SUFFIX), record.key, {volume_file, image_file}, contents[:1], sources, nil), "no record with a hash less than the outputs")
	}

	_ = os.write_entire_file(record_file, "a damaged record")
	kept, reason = decision(root, record_file, inputs, {volume_file, image_file})
	testing.expect(t, !kept, "a damaged record is no record")
	testing.expect_value(t, reason, "no build record")
	_ = os.remove(record_file)
	kept, reason = decision(root, record_file, inputs, {volume_file, image_file})
	testing.expect(t, !kept, "a volume with no record is built")
	testing.expect_value(t, reason, "no build record")
}

// A file with zero bytes at its end reads as the whole bytes, with any
// older content gone.
@(test)
file_with_a_hole_at_its_end_reads_as_its_whole_bytes :: proc(t: ^testing.T) {
	root := boot_tree_make(t)
	defer os.remove_all(root)
	path := fmt.tprintf("%s/volume.img", root)
	// An older, longer file with other bytes.
	older := make([]u8, 3 << 20, context.temp_allocator)
	for &value in older {
		value = 0xEE
	}
	_ = os.write_entire_file(path, older)
	cases := [?][2]int{{1 << 20, 4097}, {1 << 20, 0}, {4096, 4096}, {0, 0}}
	for one in cases {
		data := make([]u8, one[0], context.temp_allocator)
		for index in 0 ..< one[1] {
			data[index] = u8(index % 251 + 1)
		}
		testing.expect(t, file_write_with_a_hole_at_its_end(path, data), "the file is written")
		read, error := os.read_entire_file(path, context.temp_allocator)
		testing.expect(t, error == nil, "the file is read")
		testing.expect_value(t, len(read), len(data))
		same := len(read) == len(data)
		for index := 0; same && index < len(data); index += 1 {
			same = read[index] == data[index]
		}
		testing.expectf(t, same, "a file of %d bytes with %d bytes that are not zero reads as its bytes", one[0], one[1])
		// The hash of the build record is the hash of the content.
		content := file_content_read(path)
		testing.expect(t, content.readable && content.hash == blake3.hash(data), "the hash of the file is the hash of its whole bytes")
	}
}

// The count of volume processes at once: the count that the command gives,
// or the processors up to the bound, and never more than the volumes.
@(test)
boot_volume_processes_follow_the_processors_up_to_the_bound :: proc(t: ^testing.T) {
	testing.expect_value(t, boot_volume_processes(18, 0, 4), 4)
	testing.expect_value(t, boot_volume_processes(18, 0, 16), MOST_BOOT_VOLUME_PROCESSES)
	testing.expect_value(t, boot_volume_processes(2, 0, 16), 2)
	testing.expect_value(t, boot_volume_processes(18, 3, 16), 3)
	testing.expect_value(t, boot_volume_processes(18, 12, 16), 12)
	testing.expect_value(t, boot_volume_processes(1, 0, 0), 1)
}

// A machine starts only from a volume that the build of the process built
// or kept; a new build forgets the volumes of the build before.
@(test)
only_a_volume_of_this_build_is_ready :: proc(t: ^testing.T) {
	boot_volumes_ready_forget()
	testing.expect(t, !boot_volume_is_ready(BOOT_VOLUME), "no volume is ready before a build")
	boot_volume_ready_note(BOOT_VOLUME)
	boot_volume_ready_note(BOOT_VOLUME)
	testing.expect(t, boot_volume_is_ready(BOOT_VOLUME), "a volume that the build built or kept is ready")
	testing.expect(t, !boot_volume_is_ready(BOOT_VOLUME_SHORTAGE), "a volume that the command did not ask for is not ready")
	testing.expect_value(t, len(boot_volumes_ready), 1)
	boot_volumes_ready_forget()
	testing.expect(t, !boot_volume_is_ready(BOOT_VOLUME), "a new build forgets the volumes of the build before")
}

// The pool gives one outcome for each command, in the order of the
// commands; a command that cannot start is a failure.
@(test)
build_processes_keep_the_outcome_of_each_command :: proc(t: ^testing.T) {
	commands := make([][]string, 1, context.temp_allocator)
	command := make([]string, 1, context.temp_allocator)
	command[0] = "/a program that is not there"
	commands[0] = command
	outcomes := build_processes_run(commands, 4, context.temp_allocator)
	testing.expect_value(t, len(outcomes), 1)
	testing.expect(t, outcomes[0].started && !outcomes[0].success, "a command that cannot start is a failure")
	testing.expect(t, outcomes[0].duration >= time.Duration(0), "the time of a process is a measure")
	// The output is memory of the worker thread, outside the memory that
	// the test runner follows: the test does not free it.
	none := build_processes_run(nil, 4, context.temp_allocator)
	testing.expect_value(t, len(none), 0)
}
