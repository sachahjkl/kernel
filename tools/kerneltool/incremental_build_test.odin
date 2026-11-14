package kerneltool

import "contract:blake3"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

// A small tree of sources in a new folder: a program that imports a
// library, an assembly file, a file that `#load` reads, and a package that
// the program does not use.
@(private = "file")
source_tree_make :: proc(t: ^testing.T) -> (root: string) {
	folder, error := os.make_directory_temp("", "incremental_build_test_*", context.temp_allocator)
	testing.expect_value(t, error, nil)
	// The two libraries are at the folders of the tool: the tool finds the
	// package of an import of a library there.
	for name in ([]string{"program", "library", "unused", "tool", SOURCE_FOLDER_CONTRACT + "/record", SOURCE_FOLDER_SUPPORT + "/draw", SOURCE_FOLDER_SUPPORT + "/idle"}) {
		_ = os.make_directory_all(fmt.tprintf("%s/%s", folder, name))
	}
	file_write(folder, "program/main.odin", "package program\n\nimport \"../library\"\n\nmain :: proc() {library.work()}\n")
	file_write(folder, "program/main_test.odin", "#+build !freestanding\npackage program\n")
	file_write(folder, "program/entry.asm", "global entry\nentry: ret\n")
	file_write(folder, "program/picture.pixels", "pixels")
	file_write(folder, "library/library.odin", "package library\n\nwork :: proc() {}\n")
	file_write(folder, "unused/unused.odin", "package unused\n")
	file_write(folder, "tool/main.odin", "package tool\n\nimport \"core:fmt\"\nimport record \"contract:record\"\n\t import \"support:draw\"\nSAMPLE :: `\nimport \"support:absent\"\n`\n")
	file_write(folder, SOURCE_FOLDER_CONTRACT + "/record/record.odin", "package record\n")
	file_write(folder, SOURCE_FOLDER_SUPPORT + "/draw/draw.odin", "package draw\n\nimport \"contract:record\"\n")
	file_write(folder, SOURCE_FOLDER_SUPPORT + "/idle/idle.odin", "package idle\n")
	return folder
}

@(private = "file")
file_write :: proc(root, name, text: string) {
	_ = os.write_entire_file(fmt.tprintf("%s/%s", root, name), text)
}

@(private = "file")
SOURCE_TREE_FOLDERS :: [?]string{"program", "library", "unused", "tool", SOURCE_FOLDER_CONTRACT, SOURCE_FOLDER_SUPPORT}

// The inputs of the key of the program of the tree, as a compiler lists them.
@(private = "file")
program_inputs :: proc(root: string) -> Build_Key_Inputs {
	sources := make([]string, 2, context.temp_allocator)
	sources[0] = fmt.tprintf("%s/program/main.odin", root)
	sources[1] = fmt.tprintf("%s/library/library.odin", root)
	loads := make([]string, 1, context.temp_allocator)
	loads[0] = fmt.tprintf("%s/program/picture.pixels", root)
	settings := make([]string, 3, context.temp_allocator)
	settings[0] = "odin"
	settings[1] = "build"
	settings[2] = "-o:speed"
	fixed := make([]string, 1, context.temp_allocator)
	fixed[0] = "program/entry.asm"
	return {subject = "module program", settings = settings, fixed_files = fixed, source_files = sources, load_files = loads}
}

// The key of the inputs, with a new table: as a new build computes it.
@(private = "file")
key_of_a_new_build :: proc(t: ^testing.T, root: string, inputs: Build_Key_Inputs) -> blake3.Hash {
	folders := SOURCE_TREE_FOLDERS
	table := input_file_table_make(root, folders[:])
	defer input_file_table_destroy(table)
	key, complete := build_key(inputs, table)
	testing.expect(t, complete, "each input of the tree can be read")
	return key
}

// The same inputs give the same key; one byte of a source, of a file of an
// imported package, of an assembly file or of a file of `#load` gives
// another key.
@(test)
build_key_changes_with_each_input_file :: proc(t: ^testing.T) {
	root := source_tree_make(t)
	defer os.remove_all(root)
	inputs := program_inputs(root)
	first := key_of_a_new_build(t, root, inputs)
	testing.expect_value(t, key_of_a_new_build(t, root, inputs), first)

	file_write(root, "program/main.odin", "package program\n\nimport \"../library\"\n\nmain :: proc() {library.work(); library.work()}\n")
	after_source := key_of_a_new_build(t, root, inputs)
	testing.expect(t, after_source != first, "a byte of a source file changes the key")

	file_write(root, "library/library.odin", "package library\n\nwork :: proc() {_ = 1}\n")
	after_import := key_of_a_new_build(t, root, inputs)
	testing.expect(t, after_import != after_source, "a byte of a file of an imported package changes the key")

	file_write(root, "program/entry.asm", "global entry\nentry: nop\nret\n")
	after_assembly := key_of_a_new_build(t, root, inputs)
	testing.expect(t, after_assembly != after_import, "a byte of an assembly file changes the key")

	file_write(root, "program/picture.pixels", "other pixels")
	after_load := key_of_a_new_build(t, root, inputs)
	testing.expect(t, after_load != after_assembly, "a byte of a file of #load changes the key")
}

// A flag of the compiler, the subject and the identity of the tool are
// inputs.
@(test)
build_key_changes_with_a_flag_and_with_the_tool :: proc(t: ^testing.T) {
	root := source_tree_make(t)
	defer os.remove_all(root)
	inputs := program_inputs(root)
	first := key_of_a_new_build(t, root, inputs)

	with_flag := inputs
	settings := make([]string, 4, context.temp_allocator)
	copy(settings, inputs.settings)
	settings[3] = "-debug"
	with_flag.settings = settings
	testing.expect(t, key_of_a_new_build(t, root, with_flag) != first, "one more flag changes the key")

	other_flag := inputs
	changed := make([]string, 3, context.temp_allocator)
	copy(changed, inputs.settings)
	changed[2] = "-o:none"
	other_flag.settings = changed
	testing.expect(t, key_of_a_new_build(t, root, other_flag) != first, "another value of a flag changes the key")

	other_tool := inputs
	other_tool.tool_identity[0] = 1
	testing.expect(t, key_of_a_new_build(t, root, other_tool) != first, "another identity of the tool changes the key")

	other_subject := inputs
	other_subject.subject = "module other"
	testing.expect(t, key_of_a_new_build(t, root, other_subject) != first, "another subject changes the key")
}

// A file of a package that the module does not import is not an input. A
// file of the folder of a package of the module is an input, also when the
// compiler did not read it: a new file, and a file that a build tag leaves
// out.
@(test)
build_key_follows_the_folders_of_the_packages_only :: proc(t: ^testing.T) {
	root := source_tree_make(t)
	defer os.remove_all(root)
	inputs := program_inputs(root)
	first := key_of_a_new_build(t, root, inputs)

	file_write(root, "unused/unused.odin", "package unused\n\nchanged :: 1\n")
	file_write(root, "unused/new.odin", "package unused\n")
	testing.expect_value(t, key_of_a_new_build(t, root, inputs), first)

	file_write(root, "program/main_test.odin", "package program\n")
	after_tag := key_of_a_new_build(t, root, inputs)
	testing.expect(t, after_tag != first, "a file that the compiler left out is an input: its build tag can change")

	file_write(root, "library/more.odin", "package library\n")
	testing.expect(t, key_of_a_new_build(t, root, inputs) != after_tag, "a new file in the folder of an imported package changes the key")
}

// The order of the list of the compiler does not change the key.
@(test)
build_key_does_not_depend_on_the_order_of_the_list :: proc(t: ^testing.T) {
	root := source_tree_make(t)
	defer os.remove_all(root)
	inputs := program_inputs(root)
	first := key_of_a_new_build(t, root, inputs)
	inputs.source_files[0], inputs.source_files[1] = inputs.source_files[1], inputs.source_files[0]
	testing.expect_value(t, key_of_a_new_build(t, root, inputs), first)
}

// An input that is gone gives a key that is not complete: the module is
// built. A file that changed after the tool hashed it gives no record.
@(test)
build_key_is_not_complete_with_a_lost_or_a_changed_input :: proc(t: ^testing.T) {
	root := source_tree_make(t)
	defer os.remove_all(root)
	inputs := program_inputs(root)
	folders := SOURCE_TREE_FOLDERS
	{
		first_table := input_file_table_make(root, folders[:])
		defer input_file_table_destroy(first_table)
		// A build that starts one hour after the files were written.
		first_table.started = time.time_add(time.now(), time.Hour)
		_, complete_before := build_key(inputs, first_table, true)
		testing.expect(t, complete_before, "no input changed since the table: the key can be recorded")
		// More bytes: the size of the file is not the size of the hash.
		file_write(root, "library/library.odin", "package library\n\nwork :: proc() {}\n\nlate :: 1\n")
		testing.expect(t, !input_file_is_unchanged(first_table, fmt.tprintf("%s/library/library.odin", root)), "the file changed after its hash")
		_, complete_after := build_key(inputs, first_table, true)
		testing.expect(t, !complete_after, "a key with a file that changed during the build is not recorded")
	}
	_ = os.remove(fmt.tprintf("%s/program/picture.pixels", root))
	table := input_file_table_make(root, folders[:])
	defer input_file_table_destroy(table)
	_, complete := build_key(inputs, table)
	testing.expect(t, !complete, "a file of #load that is gone: the key is not complete")
}

// A file is trusted for a build record only when it is older than the
// start of the build: a file as new as the build can change with no change
// of its time.
@(test)
input_file_must_be_older_than_the_build :: proc(t: ^testing.T) {
	root := source_tree_make(t)
	defer os.remove_all(root)
	table := input_file_table_make(root, {"program"})
	defer input_file_table_destroy(table)
	library := fmt.tprintf("%s/library/library.odin", root)
	program := fmt.tprintf("%s/program/main.odin", root)
	testing.expect(t, input_file(table, library).readable, "a file outside the folders of the table is read at its first use")
	// A build that starts one hour after the files were written.
	table.started = time.time_add(time.now(), time.Hour)
	testing.expect(t, input_file_is_unchanged(table, library), "a file that is older than the build, read at its first use")
	testing.expect(t, input_file_is_unchanged(table, program), "a file that is older than the build, hashed with the table")
	// A build that started before the files were written.
	table.started = time.Time{}
	testing.expect(t, !input_file_is_unchanged(table, library), "a file newer than the start of the build is not trusted")
	testing.expect(t, !input_file_is_unchanged(table, program), "also when the table hashed it")
	testing.expect(t, !input_file_is_unchanged(table, fmt.tprintf("%s/absent.odin", root)), "a file that is not there is not trusted")
}

// A record goes to its text and back. Its outputs are present while each
// file has its recorded hash.
@(test)
build_record_keeps_the_hash_of_each_output :: proc(t: ^testing.T) {
	root := source_tree_make(t)
	defer os.remove_all(root)
	module_file := fmt.tprintf("%s/program.module", root)
	debug_file := fmt.tprintf("%s/program.debug", root)
	record_file := fmt.tprintf("%s/program%s", root, BUILD_RECORD_SUFFIX)
	_ = os.write_entire_file(module_file, "the module")
	_ = os.write_entire_file(debug_file, "the debug object")
	inputs := program_inputs(root)
	key := key_of_a_new_build(t, root, inputs)
	testing.expect(t, build_record_write(record_file, key, {module_file, debug_file}, inputs.source_files, inputs.load_files), "the record is written")

	record, recorded := build_record_read(record_file)
	testing.expect(t, recorded, "the record is read")
	testing.expect_value(t, record.key, key)
	testing.expect_value(t, len(record.outputs), 2)
	testing.expect_value(t, record.outputs[0].path, module_file)
	module_bytes := "the module"
	testing.expect_value(t, record.outputs[0].hash, blake3.hash(transmute([]u8)module_bytes))
	testing.expect_value(t, len(record.source_files), 2)
	testing.expect_value(t, record.source_files[1], inputs.source_files[1])
	testing.expect_value(t, len(record.load_files), 1)
	testing.expect_value(t, build_record_text(record), build_record_text(Build_Record{key = key, outputs = record.outputs, source_files = inputs.source_files, load_files = inputs.load_files}))

	testing.expect(t, record_outputs_are_present(record, {module_file, debug_file}), "each output has its recorded hash")
	testing.expect(t, !record_outputs_are_present(record, {module_file, fmt.tprintf("%s/linked.elf", root)}), "an output that the record does not name forces a build")

	_ = os.write_entire_file(debug_file, "another debug object")
	testing.expect(t, !record_outputs_are_present(record, {module_file, debug_file}), "a changed output forces a build")
	_ = os.write_entire_file(debug_file, "the debug object")
	testing.expect(t, record_outputs_are_present(record, {module_file, debug_file}), "the same bytes again are the recorded output")
	_ = os.remove(module_file)
	testing.expect(t, !record_outputs_are_present(record, {module_file, debug_file}), "a missing output forces a build")
}

// A record with a missing output is not written, and an old record does
// not stay.
@(test)
build_record_is_removed_when_an_output_is_missing :: proc(t: ^testing.T) {
	root := source_tree_make(t)
	defer os.remove_all(root)
	record_file := fmt.tprintf("%s/program%s", root, BUILD_RECORD_SUFFIX)
	_ = os.write_entire_file(record_file, "an old record")
	inputs := program_inputs(root)
	testing.expect(t, !build_record_write(record_file, {}, {fmt.tprintf("%s/absent.module", root)}, inputs.source_files, nil), "no record without the output")
	testing.expect(t, !os.exists(record_file), "the old record is removed")
}

// A record file that is absent or damaged is no record: no error, no
// crash, and the tool builds.
@(test)
damaged_build_record_is_no_record :: proc(t: ^testing.T) {
	hash := strings.repeat("ab", 32, context.temp_allocator)
	good := fmt.tprintf("%s\nkey %s\noutput %s build/modules/console.module\nsource /repository/programs/console/main.odin\nload /repository/resources/fonts/paper_mono.ttf\n", BUILD_RECORD_FIRST_LINE, hash, hash)
	record, recorded := build_record_parse(good)
	testing.expect(t, recorded, "the text of a whole record is a record")
	testing.expect_value(t, record.key[0], 0xab)
	testing.expect_value(t, record.outputs[0].path, "build/modules/console.module")

	damaged := [?]string {
		"",
		"\n",
		"another file\n",
		BUILD_RECORD_FIRST_LINE,
		fmt.tprintf("%s\nkey %s\n", BUILD_RECORD_FIRST_LINE, hash), // No output and no source.
		fmt.tprintf("%s\nkey %s\noutput %s build/a.module\n", BUILD_RECORD_FIRST_LINE, hash, hash), // No source.
		fmt.tprintf("%s\noutput %s build/a.module\nsource a.odin\n", BUILD_RECORD_FIRST_LINE, hash), // No key.
		fmt.tprintf("%s\nkey %s\nkey %s\noutput %s build/a.module\nsource a.odin\n", BUILD_RECORD_FIRST_LINE, hash, hash, hash), // Two keys.
		fmt.tprintf("%s\nkey %s\noutput %s build/a.module\nsource a.odin\n", BUILD_RECORD_FIRST_LINE, hash[:63], hash), // A short key.
		fmt.tprintf("%s\nkey %sXY\noutput %s build/a.module\nsource a.odin\n", BUILD_RECORD_FIRST_LINE, hash[:62], hash), // Not hexadecimal.
		fmt.tprintf("%s\nkey %s\noutput %s\nsource a.odin\n", BUILD_RECORD_FIRST_LINE, hash, hash), // An output with no path.
		fmt.tprintf("%s\nkey %s\noutput %s \nsource a.odin\n", BUILD_RECORD_FIRST_LINE, hash, hash),
		fmt.tprintf("%s\nkey %s\noutput build/a.module\nsource a.odin\n", BUILD_RECORD_FIRST_LINE, hash), // An output with no hash.
		fmt.tprintf("%s\nkey %s\noutput %s build/a.module\nsource a.odin\nsomething else\n", BUILD_RECORD_FIRST_LINE, hash, hash),
		fmt.tprintf("%s\nkey %s\noutput %s build/a.module\nsource \n", BUILD_RECORD_FIRST_LINE, hash, hash),
		good[:len(good) / 2],
		good[:len(BUILD_RECORD_FIRST_LINE) + 10],
		"\x00\xff\xfe\x00\x01",
	}
	for text, index in damaged {
		_, parsed := build_record_parse(text)
		testing.expectf(t, !parsed, "the damaged record %d is no record", index)
	}

	root := source_tree_make(t)
	defer os.remove_all(root)
	_, absent := build_record_read(fmt.tprintf("%s/absent%s", root, BUILD_RECORD_SUFFIX))
	testing.expect(t, !absent, "an absent record file is no record")
	_, folder := build_record_read(root)
	testing.expect(t, !folder, "a folder is no record")
}

// The list of the compiler, in the form that it writes.
@(test)
dependency_list_of_the_compiler_is_read :: proc(t: ^testing.T) {
	text := "{\n\t\"source_files\": [\n\t\t\"/nix/store/odin/share/base/runtime/core.odin\",\n\t\t\"/repository/programs/temple/main.odin\"\n\t],\n\t\"load_files\": [\n\t\t\"/repository/programs/temple/portrait.pixels\"\n\t]\n}\n"
	sources, loads, listed := dependency_list_parse(text)
	testing.expect(t, listed, "the list is read")
	testing.expect_value(t, len(sources), 2)
	testing.expect_value(t, sources[0], "/nix/store/odin/share/base/runtime/core.odin")
	testing.expect_value(t, sources[1], "/repository/programs/temple/main.odin")
	testing.expect_value(t, len(loads), 1)
	testing.expect_value(t, loads[0], "/repository/programs/temple/portrait.pixels")

	without_loads := "{\n\t\"source_files\": [\n\t\t\"/repository/kernel/main.odin\"\n\t],\n\t\"load_files\": [\n\t]\n}\n"
	sources, loads, listed = dependency_list_parse(without_loads)
	testing.expect(t, listed, "a list with no file of #load is read")
	testing.expect_value(t, len(sources), 1)
	testing.expect_value(t, len(loads), 0)

	for damaged in ([]string{"", "{\n}\n", text[:len(text) / 2], "kernel.ll: kernel/main.odin\n", "{\n\t\"source_files\": [\n\t],\n\t\"load_files\": [\n\t]\n}\n", "\t\t\"/repository/kernel/main.odin\"\n"}) {
		_, _, parsed := dependency_list_parse(damaged)
		testing.expect(t, !parsed, "a damaged list is no list: the tool writes no record")
	}
}

// The imports of a source file that name a package of the repository.
@(test)
imports_of_a_source_name_the_folders_of_the_repository :: proc(t: ^testing.T) {
	folders := make([dynamic]string, context.temp_allocator)
	source := "package kerneltool\n\nimport \"core:fmt\"\nimport module \"contract:module\"\nimport \"support:cryptography/ed25519\"\nimport \"../shared\"\nimport\t\"./beside\"\nimported := 1\n// the word import in a comment\nforeign import library \"system:c\"\n"
	imported_folders_of_source(source, "tools/kerneltool", &folders)
	testing.expect_value(t, len(folders), 4)
	testing.expect_value(t, folders[0], SOURCE_FOLDER_CONTRACT + "/module")
	testing.expect_value(t, folders[1], SOURCE_FOLDER_SUPPORT + "/cryptography/ed25519")
	testing.expect_value(t, folders[2], "tools/shared")
	testing.expect_value(t, folders[3], "tools/kerneltool/beside")
	testing.expect_value(t, path_without_dots("a/b/../../c/./d"), "c/d")
}

// The identity of the tool covers its folder and the packages of the
// repository that it imports, to any depth, and no other package.
@(test)
tool_identity_follows_the_imports_of_the_tool :: proc(t: ^testing.T) {
	identity_of :: proc(t: ^testing.T, root: string) -> blake3.Hash {
		folders := SOURCE_TREE_FOLDERS
		table := input_file_table_make(root, folders[:])
		defer input_file_table_destroy(table)
		identity, complete := tool_identity_of(table, "tool")
		testing.expect(t, complete, "the sources of the tool can be read; an import of a folder that is not there is a comment or a text")
		return identity
	}
	root := source_tree_make(t)
	defer os.remove_all(root)
	first := identity_of(t, root)
	testing.expect_value(t, identity_of(t, root), first)

	file_write(root, SOURCE_FOLDER_SUPPORT + "/idle/idle.odin", "package idle\n\nchanged :: 1\n")
	file_write(root, "program/main.odin", "package program\n")
	testing.expect_value(t, identity_of(t, root), first)

	file_write(root, SOURCE_FOLDER_SUPPORT + "/draw/draw.odin", "package draw\n\nimport \"contract:record\"\n\nchanged :: 1\n")
	after_import := identity_of(t, root)
	testing.expect(t, after_import != first, "a package that the tool imports is a source of the tool")

	file_write(root, SOURCE_FOLDER_CONTRACT + "/record/record.odin", "package record\n\nchanged :: 1\n")
	after_deep_import := identity_of(t, root)
	testing.expect(t, after_deep_import != after_import, "a package that a package of the tool imports is a source of the tool")

	file_write(root, "tool/other.odin", "package tool\n")
	testing.expect(t, identity_of(t, root) != after_deep_import, "a new file of the tool changes its identity")

	table := input_file_table_make(root, {"tool"})
	defer input_file_table_destroy(table)
	_, complete := tool_identity_of(table, "absent")
	testing.expect(t, !complete, "a tool folder that is not there gives no identity")
}

// A hash goes to its hexadecimal text and back.
@(test)
hash_as_hexadecimal_and_back :: proc(t: ^testing.T) {
	hash: blake3.Hash
	for &value, index in hash {
		value = u8(index * 9 + 1)
	}
	text := hash_as_hexadecimal(hash)
	testing.expect_value(t, len(text), 64)
	testing.expect_value(t, text[:6], "010a13")
	back, valid := hash_from_hexadecimal(text)
	testing.expect(t, valid, "the text of a hash is a hash")
	testing.expect_value(t, back, hash)
	_, upper := hash_from_hexadecimal(strings.to_upper(text, context.temp_allocator))
	testing.expect(t, !upper, "the record writes lower case only")
}

// The measure of a build says the counts of the modules, each later step,
// the counts of the boot volumes, and the time of each built volume.
@(test)
build_measure_lines_name_the_counts_and_the_steps :: proc(t: ^testing.T) {
	steps := make([dynamic]Build_Step_Time, context.temp_allocator)
	append(&steps, Build_Step_Time{name = "the debug image", duration = 250 * time.Millisecond})
	volume_times := make([dynamic]Build_Step_Time, context.temp_allocator)
	append(&volume_times, Build_Step_Time{name = "main", duration = 3 * time.Second}, Build_Step_Time{name = "shortage", duration = 2500 * time.Millisecond})
	measure := Build_Measure{input_files = 1200, input_bytes = 9000000, input_hash = 200 * time.Millisecond, modules = 4 * time.Second, modules_built = 3, modules_converted = 33, modules_kept = 48, module_compile_steps = 3500 * time.Millisecond, module_conversions = 250 * time.Millisecond, steps = steps, volumes_built = 2, volumes_kept = 1, volumes_not_needed = 15, volume_processes = 2, volume_times = volume_times}
	lines := build_measure_lines(measure, 60 * time.Second)
	testing.expect_value(t, len(lines), 5)
	testing.expect(t, strings.contains(lines[0], "the hash of 1200 input files (9000000 bytes) 0.20 s"), lines[0])
	testing.expect(t, strings.contains(lines[0], "3 built, 33 converted, 48 kept (the compile steps 3.50 s, the conversions 0.25 s, "), lines[0])
	testing.expect(t, strings.contains(lines[1], "0.25 s: the debug image"), lines[1])
	testing.expect(t, strings.contains(lines[2], "the boot volumes: 2 built, 1 kept, 15 not needed by this command; 2 volume processes at once"), lines[2])
	testing.expect(t, strings.contains(lines[3], "3.00 s: the process of the boot volume main"), lines[3])
	testing.expect(t, strings.contains(lines[4], "2.50 s: the process of the boot volume shortage"), lines[4])
	// A build with no volume to build names the kept ones, and no process.
	measure.volumes_built = 0
	measure.volumes_kept = 18
	measure.volumes_not_needed = 0
	measure.volume_times = nil
	lines = build_measure_lines(measure, time.Second)
	testing.expect_value(t, len(lines), 3)
	testing.expect(t, strings.contains(lines[2], "0 built, 18 kept, 0 not needed"), lines[2])
}

// A library and a program that imports it, in a new folder: the sources of
// each, and the files of a build of the two. No compiler runs: the test
// writes the output of each step itself, as a function of what the step
// reads, so a step that the tool skips leaves a stale file that the test
// can see.
@(private = "file")
Two_Modules :: struct {
	root:    string,
	table:   ^Input_File_Table,
	library: Module_Steps,
	program: Module_Steps,
	final:   Module_Steps, // A module that imports the program: the second level of the chain.
}

@(private = "file")
two_modules_steps :: proc(root, name: string, imports: []string) -> Module_Steps {
	sources := make([]string, 1, context.temp_allocator)
	sources[0] = fmt.tprintf("%s/%s/main.odin", root, name)
	compile_settings := make([]string, 2, context.temp_allocator)
	compile_settings[0] = "odin"
	compile_settings[1] = "-o:speed"
	convert_settings := make([dynamic]string, context.temp_allocator)
	import_files := make([dynamic]string, context.temp_allocator)
	for imported in imports {
		append(&convert_settings, "imports", imported)
		append(&import_files, fmt.tprintf("%s/build/%s.module", root, imported))
	}
	compile_outputs := make([]string, 1, context.temp_allocator)
	compile_outputs[0] = fmt.tprintf("%s/build/%s.linked", root, name)
	convert_outputs := make([]string, 2, context.temp_allocator)
	convert_outputs[0] = fmt.tprintf("%s/build/%s.module", root, name)
	convert_outputs[1] = fmt.tprintf("%s/build/%s.debug", root, name)
	return {
		compile_record_path = fmt.tprintf("%s/build/%s%s", root, name, COMPILE_RECORD_SUFFIX),
		convert_record_path = fmt.tprintf("%s/build/%s%s", root, name, CONVERT_RECORD_SUFFIX),
		// The list of the compiler is a part of the inputs here only to
		// give the test its list: the tool takes it from the record.
		compile_inputs = {subject = fmt.tprintf("the compile step of the module %s", name), settings = compile_settings, source_files = sources},
		convert_inputs = {subject = fmt.tprintf("the conversion of the module %s", name), settings = convert_settings[:], built_files = import_files[:]},
		compile_outputs = compile_outputs,
		convert_outputs = convert_outputs,
	}
}

@(private = "file")
two_modules_make :: proc(t: ^testing.T) -> (modules: Two_Modules) {
	folder, error := os.make_directory_temp("", "module_steps_test_*", context.temp_allocator)
	testing.expect_value(t, error, nil)
	for name in ([]string{"library", "program", "final", "build"}) {
		_ = os.make_directory_all(fmt.tprintf("%s/%s", folder, name))
	}
	file_write(folder, "library/main.odin", "package library\n\n@(export)\nwork :: proc \"c\" (count: i64) -> i64 {return count}\n")
	file_write(folder, "program/main.odin", "package program\n\nforeign _ {\n\twork :: proc \"c\" (count: i64) -> i64 ---\n}\n")
	file_write(folder, "final/main.odin", "package final\n\nforeign _ {\n\trun :: proc \"c\" () -> i64 ---\n}\n")
	modules.root = folder
	modules.library = two_modules_steps(folder, "library", nil)
	modules.program = two_modules_steps(folder, "program", {"library"})
	modules.final = two_modules_steps(folder, "final", {"program"})
	two_modules_new_build(&modules)
	return modules
}

// A new build starts: a new table of the sources, as each build has. The
// build starts one hour after the files were written, so the tool can
// record each of them.
@(private = "file")
two_modules_new_build :: proc(modules: ^Two_Modules) {
	if modules.table != nil {
		input_file_table_destroy(modules.table)
	}
	modules.table = input_file_table_make(modules.root, {"library", "program", "final"})
	modules.table.started = time.time_add(time.now(), time.Hour)
}

@(private = "file")
two_modules_destroy :: proc(modules: ^Two_Modules) {
	input_file_table_destroy(modules.table)
	_ = os.remove_all(modules.root)
}

@(private = "file")
file_text :: proc(path: string) -> string {
	bytes, error := os.read_entire_file(path, context.temp_allocator)
	return error == nil ? string(bytes) : "(absent)"
}

// The compile step of the test: the linked file is the sources of the
// module, and nothing of an import.
@(private = "file")
test_compile :: proc(steps: Module_Steps) {
	text := strings.builder_make(context.temp_allocator)
	for source in steps.compile_inputs.source_files {
		fmt.sbprintf(&text, "linked from: %s", file_text(source))
	}
	_ = os.write_entire_file(steps.compile_outputs[0], strings.to_string(text))
}

// The conversion of the test: the module file is the linked file and the
// hash of the file of each import, as the import table of a module.
@(private = "file")
test_convert :: proc(steps: Module_Steps) {
	text := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&text, "module of: %s", file_text(steps.compile_outputs[0]))
	for imported in steps.convert_inputs.built_files {
		bytes := file_text(imported)
		fmt.sbprintf(&text, "import %s\n", hash_as_hexadecimal(blake3.hash(transmute([]u8)bytes)))
	}
	_ = os.write_entire_file(steps.convert_outputs[0], strings.to_string(text))
	_ = os.write_entire_file(steps.convert_outputs[1], fmt.tprintf("debug object of: %s", file_text(steps.compile_outputs[0])))
}

// One module of one build, as the tool builds it: the tool says which
// step runs, the test runs it, the tool writes the records.
@(private = "file")
test_build_one :: proc(t: ^testing.T, modules: ^Two_Modules, steps: Module_Steps) -> Module_Step {
	step, _ := module_step_needed(steps, modules.table)
	if step == .Kept {
		return step
	}
	source_files := steps.compile_inputs.source_files
	if step == .Built {
		test_compile(steps)
	}
	test_convert(steps)
	testing.expect(t, module_step_records_write(steps, modules.table, step == .Built, source_files, nil), "the records of the steps are written")
	return step
}

// One build of the three modules, in the order of their levels.
@(private = "file")
test_build_all :: proc(t: ^testing.T, modules: ^Two_Modules) -> (library, program, final: Module_Step) {
	two_modules_new_build(modules)
	library = test_build_one(t, modules, modules.library)
	program = test_build_one(t, modules, modules.program)
	final = test_build_one(t, modules, modules.final)
	return
}

// The files that a whole build of the sources as they are now gives.
@(private = "file")
expect_the_modules_of_a_whole_build :: proc(t: ^testing.T, modules: ^Two_Modules) {
	kept: [3]string
	for steps, index in ([3]Module_Steps{modules.library, modules.program, modules.final}) {
		kept[index] = strings.clone(file_text(steps.convert_outputs[0]), context.temp_allocator)
	}
	for steps, index in ([3]Module_Steps{modules.library, modules.program, modules.final}) {
		test_compile(steps)
		test_convert(steps)
		testing.expectf(t, file_text(steps.convert_outputs[0]) == kept[index], "module %d of the incremental build is the module of a whole build", index)
	}
}

// The first build builds each module; the second keeps each one.
@(test)
module_steps_build_first_and_keep_after :: proc(t: ^testing.T) {
	modules := two_modules_make(t)
	defer two_modules_destroy(&modules)
	library, program, final := test_build_all(t, &modules)
	testing.expect_value(t, library, Module_Step.Built)
	testing.expect_value(t, program, Module_Step.Built)
	testing.expect_value(t, final, Module_Step.Built)
	library, program, final = test_build_all(t, &modules)
	testing.expect_value(t, library, Module_Step.Kept)
	testing.expect_value(t, program, Module_Step.Kept)
	testing.expect_value(t, final, Module_Step.Kept)
}

// A change of the body of a procedure of a library builds the library,
// and converts its importer with no compile step. The importer of the
// importer is converted too: its import has a new hash. Each module is
// then the module of a whole build.
@(test)
change_inside_an_import_converts_the_importers_in_a_chain :: proc(t: ^testing.T) {
	modules := two_modules_make(t)
	defer two_modules_destroy(&modules)
	test_build_all(t, &modules)
	linked_before := strings.clone(file_text(modules.program.compile_outputs[0]), context.temp_allocator)
	module_before := strings.clone(file_text(modules.program.convert_outputs[0]), context.temp_allocator)
	final_before := strings.clone(file_text(modules.final.convert_outputs[0]), context.temp_allocator)

	// The same export, with the same description, and another body.
	file_write(modules.root, "library/main.odin", "package library\n\n@(export)\nwork :: proc \"c\" (count: i64) -> i64 {return count + 1}\n")
	library, program, final := test_build_all(t, &modules)
	testing.expect_value(t, library, Module_Step.Built)
	testing.expect_value(t, program, Module_Step.Converted)
	testing.expect_value(t, final, Module_Step.Converted)
	testing.expect_value(t, file_text(modules.program.compile_outputs[0]), linked_before)
	testing.expect(t, file_text(modules.program.convert_outputs[0]) != module_before, "the module of the importer names the new hash of its import")
	testing.expect(t, file_text(modules.final.convert_outputs[0]) != final_before, "the module of the second level names the new hash of the importer")
	expect_the_modules_of_a_whole_build(t, &modules)

	library, program, final = test_build_all(t, &modules)
	testing.expect_value(t, library, Module_Step.Kept)
	testing.expect_value(t, program, Module_Step.Kept)
	testing.expect_value(t, final, Module_Step.Kept)
}

// A change of the description of an export changes the file of the
// library, so its importer is converted. The importer is compiled when
// its own source changes: the declaration of the export that it calls is
// in its source, in a `foreign` block, and nowhere else.
@(test)
change_of_the_declaration_of_an_import_compiles_the_importer :: proc(t: ^testing.T) {
	modules := two_modules_make(t)
	defer two_modules_destroy(&modules)
	test_build_all(t, &modules)

	// The library gives its export one more parameter. The importer still
	// declares the old form: its compiled code is the same.
	file_write(modules.root, "library/main.odin", "package library\n\n@(export)\nwork :: proc \"c\" (count, step: i64) -> i64 {return count + step}\n")
	library, program, final := test_build_all(t, &modules)
	testing.expect_value(t, library, Module_Step.Built)
	testing.expect_value(t, program, Module_Step.Converted)
	testing.expect_value(t, final, Module_Step.Converted)

	// The importer declares the new form: this is a change of its source.
	file_write(modules.root, "program/main.odin", "package program\n\nforeign _ {\n\twork :: proc \"c\" (count, step: i64) -> i64 ---\n}\n")
	library, program, final = test_build_all(t, &modules)
	testing.expect_value(t, library, Module_Step.Kept)
	testing.expect_value(t, program, Module_Step.Built)
	testing.expect_value(t, final, Module_Step.Converted)
	expect_the_modules_of_a_whole_build(t, &modules)
}

// An import that is built again to the same bytes changes nothing above it.
@(test)
import_built_to_the_same_bytes_keeps_the_importer :: proc(t: ^testing.T) {
	modules := two_modules_make(t)
	defer two_modules_destroy(&modules)
	test_build_all(t, &modules)
	_ = os.remove(modules.library.compile_record_path)
	library, program, final := test_build_all(t, &modules)
	testing.expect_value(t, library, Module_Step.Built)
	testing.expect_value(t, program, Module_Step.Kept)
	testing.expect_value(t, final, Module_Step.Kept)
}

// A record with a missing or a changed output forces its step: the
// linked file forces the two steps, the module file or the debug object
// forces the conversion. A lost or a damaged record does the same.
@(test)
missing_output_or_record_forces_its_step :: proc(t: ^testing.T) {
	modules := two_modules_make(t)
	defer two_modules_destroy(&modules)
	test_build_all(t, &modules)
	program := modules.program

	expect_step :: proc(t: ^testing.T, modules: ^Two_Modules, wanted: Module_Step, wanted_reason: string, what: string) {
		two_modules_new_build(modules)
		step, reason := module_step_needed(modules.program, modules.table)
		testing.expectf(t, step == wanted, "%s: the step is %v, not %v", what, step, wanted)
		testing.expectf(t, reason == wanted_reason, "%s: the reason is \"%s\", not \"%s\"", what, reason, wanted_reason)
		// The build that follows puts each file back.
		test_build_one(t, modules, modules.program)
		again, _ := module_step_needed(modules.program, modules.table)
		testing.expectf(t, again == .Kept, "%s: after its step the module is kept", what)
	}

	_ = os.remove(program.convert_outputs[0])
	expect_step(t, &modules, .Converted, OUTPUT_CHANGED_REASON, "the module file is gone")
	_ = os.write_entire_file(program.convert_outputs[1], "another debug object")
	expect_step(t, &modules, .Converted, OUTPUT_CHANGED_REASON, "the debug object changed")
	_ = os.remove(program.convert_record_path)
	expect_step(t, &modules, .Converted, "no build record of the conversion", "the record of the conversion is gone")
	_ = os.write_entire_file(program.convert_record_path, "not a record")
	expect_step(t, &modules, .Converted, "no build record of the conversion", "the record of the conversion is damaged")
	_ = os.remove(program.compile_outputs[0])
	expect_step(t, &modules, .Built, OUTPUT_CHANGED_REASON, "the linked file is gone")
	_ = os.write_entire_file(program.compile_outputs[0], "another linked file")
	expect_step(t, &modules, .Built, OUTPUT_CHANGED_REASON, "the linked file changed")
	_ = os.remove(program.compile_record_path)
	expect_step(t, &modules, .Built, "no build record", "the record of the compile step is gone")
	// The file of the import is gone: the conversion runs, and says so.
	_ = os.remove(modules.library.convert_outputs[0])
	two_modules_new_build(&modules)
	step, reason := module_step_needed(modules.program, modules.table)
	testing.expect_value(t, step, Module_Step.Converted)
	testing.expect_value(t, reason, "the file of an import cannot be read")
	test_convert(modules.program)
	testing.expect(t, !module_step_records_write(modules.program, modules.table, false, modules.program.compile_inputs.source_files, nil), "no record of a conversion whose import cannot be read")
	testing.expect(t, !os.exists(program.convert_record_path), "the old record of the conversion is removed")
}

// A record of the conversion is the record of one compile step: a linked
// file of other sources never passes for the linked file of the record,
// and a compile step that ran with no conversion after it leaves no
// module that the tool keeps.
@(test)
conversion_record_holds_the_key_of_its_compile_step :: proc(t: ^testing.T) {
	modules := two_modules_make(t)
	defer two_modules_destroy(&modules)
	test_build_all(t, &modules)
	program := modules.program

	// The compile step runs for a new source, and the build stops before
	// the conversion: the record of the compile step is new, the record of
	// the conversion and the module file are old.
	file_write(modules.root, "program/main.odin", "package program\n\nforeign _ {\n\twork :: proc \"c\" (count: i64) -> i64 ---\n}\n\nmore :: 1\n")
	two_modules_new_build(&modules)
	test_compile(program)
	inputs := program.compile_inputs
	key, complete := build_key(inputs, modules.table, true)
	testing.expect(t, complete, "the key of the new source is complete")
	testing.expect(t, build_record_write(program.compile_record_path, key, program.compile_outputs, inputs.source_files, nil), "the record of the compile step is written")
	step, reason := module_step_needed(program, modules.table)
	testing.expect_value(t, step, Module_Step.Converted)
	testing.expect_value(t, reason, CONVERSION_INPUT_CHANGED_REASON)

	// The order of the imports is an input of the conversion: it is the
	// order of the import table of the module file.
	first, first_complete := module_convert_key(two_modules_steps(modules.root, "program", {"library", "final"}), key, nil, modules.table)
	second, second_complete := module_convert_key(two_modules_steps(modules.root, "program", {"final", "library"}), key, nil, modules.table)
	testing.expect(t, first_complete && second_complete, "the files of the two imports can be read")
	testing.expect(t, first != second, "two orders of the imports give two keys")
}

// No record of the conversion is written when a source changed after the
// tool hashed it: the conversion reads the sources for the description.
@(test)
no_conversion_record_with_a_source_that_changed_during_the_build :: proc(t: ^testing.T) {
	modules := two_modules_make(t)
	defer two_modules_destroy(&modules)
	test_build_all(t, &modules)
	// The import changes, so the program is converted in the next build.
	file_write(modules.root, "library/main.odin", "package library\n\n@(export)\nwork :: proc \"c\" (count: i64) -> i64 {return count + 2}\n")
	two_modules_new_build(&modules)
	testing.expect_value(t, test_build_one(t, &modules, modules.library), Module_Step.Built)
	step, _ := module_step_needed(modules.program, modules.table)
	testing.expect_value(t, step, Module_Step.Converted)
	// A source of the program is saved while the conversion runs.
	file_write(modules.root, "program/main.odin", "package program\n\nforeign _ {\n\twork :: proc \"c\" (count: i64) -> i64 ---\n}\n\nlate :: 1\n")
	test_convert(modules.program)
	testing.expect(t, !module_step_records_write(modules.program, modules.table, false, modules.program.compile_inputs.source_files, nil), "no record with a source that changed during the build")
	testing.expect(t, !os.exists(modules.program.convert_record_path), "the old record of the conversion is removed")
	testing.expect(t, os.exists(modules.program.compile_record_path), "the record of the compile step stays: its linked file is the same")
	two_modules_new_build(&modules)
	step, _ = module_step_needed(modules.program, modules.table)
	testing.expect_value(t, step, Module_Step.Built)
}

// The key of the compile step of a module of the table names no import
// and no built file: the compile step reads none.
@(test)
compile_key_of_a_module_holds_no_import :: proc(t: ^testing.T) {
	importer := Module_Build{name = "importer", source = MODULE_SOURCES + "agenda", imports = {"calendar"}}
	alone := Module_Build{name = "importer", source = MODULE_SOURCES + "agenda"}
	with_import, readable := module_compile_key_inputs(importer)
	without_import, readable_alone := module_compile_key_inputs(alone)
	testing.expect(t, readable && readable_alone, "the folder of the module can be listed")
	testing.expect_value(t, len(with_import.built_files), 0)
	testing.expect_value(t, len(with_import.hashed_built_files), 0)
	testing.expect_value(t, strings.join(with_import.settings, "\n", context.temp_allocator), strings.join(without_import.settings, "\n", context.temp_allocator))
	for setting in with_import.settings {
		testing.expect(t, setting != "imports" && !strings.contains(setting, "calendar"), setting)
	}
	conversion := module_convert_key_inputs(importer)
	testing.expect_value(t, len(conversion.built_files), 1)
	testing.expect(t, strings.has_suffix(conversion.built_files[0], "/calendar.module"), conversion.built_files[0])
}
