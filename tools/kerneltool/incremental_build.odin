package kerneltool

import "modus:contract/blake3"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

// The incremental build: a module is built again only when one of its
// inputs changed (docs/TOOLS.md, "The incremental build").
//
// The same inputs give the same bytes: each full check proves it with a
// second build (docs/REPRODUCIBLE_BUILD.md, "What the build does to give
// the same bytes"). So an output of an earlier build is the output of this
// build when the inputs are the same, and the tool keeps it.
//
// The tool does not guess the inputs of a module. The compiler writes the
// list of the files that it read (`-export-dependencies`), and the tool
// hashes them. A file that the compiler did not read can become a source
// with no change of a listed file in one way only: it is in the folder of
// a package of the list (a new file, or a file whose build tag now
// admits the target). So every file of each such folder is an input too.
//
// After a build, the tool writes a build record beside the outputs: the
// build key (one BLAKE3 hash over the inputs in a fixed order), the hash
// of each output, and the list of the compiler. At the next build, the
// tool computes the key again from the files of that list as they are now.
// The outputs are kept when the key is the same and each output is there
// with its recorded hash. A record that is absent or damaged is no record:
// the tool builds.
//
// A module has two steps, each with its key and its record: the compile
// step, which reads no import, and the conversion, which reads the file
// of each import. A change inside an import runs the conversion of its
// importers only (Module_Steps, below).

// A whole build ignores every build record, and writes new ones.
// `build whole` sets it; the checks that compare two builds set it too
// (repeat.odin), and the full checks (`check`, `screenshots`).
build_whole := false

BUILD_RECORD_FIRST_LINE :: "build record, form 1"
BUILD_RECORD_SUFFIX :: ".build_record"
DEPENDENCY_FILE_NAME :: "dependencies.json"
TOOL_SOURCE_FOLDER :: "tools/kerneltool"

// The folders of the repository that hold sources of a build. The tool
// hashes each of their files once, before the first compiler starts. A
// file outside them (the libraries of the compiler) is hashed at its first
// use.
INPUT_FOLDERS :: [?]string{SOURCE_FOLDER_BOOT, SOURCE_FOLDER_CONTRACT, SOURCE_FOLDER_KERNEL, SOURCE_FOLDER_MODULES, SOURCE_FOLDER_PROGRAMS, RESOURCE_FOLDER, SOURCE_FOLDER_RUNTIME, SOURCE_FOLDER_SUPPORT, TOOL_SOURCE_FOLDER}

// The threads that read and hash files at once. A thread holds one whole
// file in memory, and a boot volume is 64 MiB.
FILE_HASH_THREADS_MOST :: 8

// The content of one file, as the tool read it.
File_Content :: struct {
	hash:              blake3.Hash,
	size:              i64,
	modification_time: time.Time,
	readable:          bool,
}

// file_content_read reads one file and hashes it. It reads the time of
// the file before its bytes: a change between the two then leaves an old
// time beside new bytes, and the comparison of the times after a build
// sees it.
file_content_read :: proc(path: string) -> (content: File_Content) {
	information, stat_error := os.stat(path, context.allocator)
	if stat_error != nil {
		return
	}
	defer os.file_info_delete(information, context.allocator)
	if information.type != .Regular {
		return
	}
	bytes, read_error := os.read_entire_file(path, context.allocator)
	if read_error != nil {
		return
	}
	defer delete(bytes)
	return {hash = blake3.hash(bytes), size = information.size, modification_time = information.modification_time, readable = true}
}

@(private = "file")
File_Content_Work :: struct {
	paths:    []string,
	contents: []File_Content,
	next:     int, // The next place in paths to take (atomic).
}

@(private = "file")
file_content_worker :: proc(data: rawptr) {
	work := (^File_Content_Work)(data)
	for {
		place := sync.atomic_add(&work.next, 1)
		if place >= len(work.paths) {
			return
		}
		work.contents[place] = file_content_read(work.paths[place])
	}
}

// file_contents_read_in_parallel reads and hashes each file of a list, on
// several threads. The result has the order of the list.
file_contents_read_in_parallel :: proc(paths: []string, allocator := context.allocator) -> []File_Content {
	contents := make([]File_Content, len(paths), allocator)
	thread_count := min(os.get_processor_core_count(), len(paths), FILE_HASH_THREADS_MOST)
	if thread_count <= 1 {
		for path, index in paths {
			contents[index] = file_content_read(path)
		}
		return contents
	}
	work := File_Content_Work{paths = paths, contents = contents}
	workers := make([]^thread.Thread, thread_count, context.temp_allocator)
	for &worker in workers {
		worker = thread.create_and_start_with_data(&work, file_content_worker)
	}
	thread.join_multiple(..workers)
	for worker in workers {
		thread.destroy(worker)
	}
	return contents
}

// One input file of the table.
Input_File :: File_Content

// The least age of an input file at the start of a build, for a build
// record. A file system gives a file the time of its last clock tick, so
// two writes in one tick can have one time: a file this old was not
// written in the tick of the start of the build.
INPUT_FILE_AGE_LEAST :: time.Second

@(private = "file")
Folder_Listing :: struct {
	names:    []string, // The files of the folder, with no folder, sorted.
	readable: bool,
}

// The input files of one build, by absolute path: each file is hashed one
// time for all the modules. Only the thread that leads the build uses the
// table.
Input_File_Table :: struct {
	root:         string, // The folder of the repository: a relative path starts there.
	started:      time.Time, // Before the first read of a file.
	files:        map[string]Input_File,
	folders:      map[string]Folder_Listing,
	hashed_bytes: i64,
}

@(private = "file")
folder_files_collect :: proc(folder: string, paths: ^[dynamic]string) {
	entries, error := os.read_all_directory_by_path(folder, context.allocator)
	if error != nil {
		return
	}
	defer os.file_info_slice_delete(entries, context.allocator)
	for entry in entries {
		path := strings.concatenate({folder, "/", entry.name})
		#partial switch entry.type {
		case .Directory:
			folder_files_collect(path, paths)
			delete(path)
		case .Regular:
			append(paths, path)
		case:
			delete(path)
		}
	}
}

// input_file_table_make hashes every file of the folders, on several
// threads. root is absolute; the folders are relative to it.
input_file_table_make :: proc(root: string, folders: []string) -> ^Input_File_Table {
	table := new(Input_File_Table)
	table.started = time.now()
	table.root = strings.clone(root)
	paths := make([dynamic]string)
	defer delete(paths)
	for folder in folders {
		folder_files_collect(join(root, "/", folder), &paths)
	}
	contents := file_contents_read_in_parallel(paths[:])
	defer delete(contents)
	for path, index in paths {
		// The map keeps the path.
		table.files[path] = contents[index]
		table.hashed_bytes += contents[index].size
	}
	return table
}

input_file_table_destroy :: proc(table: ^Input_File_Table) {
	for path in table.files {
		delete(path)
	}
	delete(table.files)
	for folder, listing in table.folders {
		for name in listing.names {
			delete(name)
		}
		delete(listing.names)
		delete(folder)
	}
	delete(table.folders)
	delete(table.root)
	free(table)
}

// input_path gives the absolute path of an input: the key of the table.
input_path :: proc(table: ^Input_File_Table, path: string) -> string {
	if strings.has_prefix(path, "/") {
		return path
	}
	return join(table.root, "/", path)
}

// input_file gives the content of a file, from the table. A file that the
// table does not hold is read now.
input_file :: proc(table: ^Input_File_Table, path: string) -> Input_File {
	absolute := input_path(table, path)
	if known, found := table.files[absolute]; found {
		return known
	}
	file := file_content_read(absolute)
	table.files[strings.clone(absolute)] = file
	table.hashed_bytes += file.size
	return file
}

// input_file_is_unchanged says if the bytes that the table hashed are the
// bytes that a compiler of this build read: the file is older than the
// start of the build, and its size and its time are still those of the
// hash. So no write reached the file between the start of the build and
// now, and the hash and the compiler read the same bytes. If not, the
// tool writes no build record: a record would join the key of some bytes
// to the output of other bytes. The cost is one more build of the modules
// of a file that was saved in the last second before the build.
input_file_is_unchanged :: proc(table: ^Input_File_Table, path: string) -> bool {
	file := input_file(table, path)
	if !file.readable {
		return false
	}
	information, error := os.stat(input_path(table, path), context.temp_allocator)
	if error != nil || information.size != file.size || information.modification_time != file.modification_time {
		return false
	}
	return time.diff(file.modification_time, table.started) > INPUT_FILE_AGE_LEAST
}

// input_folder_file_names gives the names of the files of a folder,
// sorted, with no file of a folder below it.
input_folder_file_names :: proc(table: ^Input_File_Table, folder: string) -> (names: []string, readable: bool) {
	absolute := input_path(table, folder)
	if known, found := table.folders[absolute]; found {
		return known.names, known.readable
	}
	listing: Folder_Listing
	entries, error := os.read_all_directory_by_path(absolute, context.temp_allocator)
	if error == nil {
		list := make([dynamic]string)
		for entry in entries {
			if entry.type != .Directory {
				append(&list, strings.clone(entry.name))
			}
		}
		slice.sort(list[:])
		listing = {
			names    = list[:],
			readable = true,
		}
	}
	table.folders[strings.clone(absolute)] = listing
	return listing.names, listing.readable
}

// folder_of_path gives the folder of a file path.
folder_of_path :: proc(path: string) -> string {
	slash := strings.last_index_byte(path, '/')
	if slash < 0 {
		return "."
	}
	return path[:max(slash, 1)]
}

@(private = "file")
key_add_bytes :: proc(text: ^[dynamic]u8, label: string, value: []u8) {
	// Each part has its label and its size: two lists of parts never give
	// the same bytes.
	label_bytes := transmute([]u8)label
	append(text, ..label_bytes)
	append(text, 0)
	size := transmute([8]u8)u64le(len(value))
	append(text, ..size[:])
	append(text, ..value)
}

@(private = "file")
key_add :: proc(text: ^[dynamic]u8, label: string, value: string) {
	key_add_bytes(text, label, transmute([]u8)value)
}

@(private = "file")
key_add_input_file :: proc(text: ^[dynamic]u8, table: ^Input_File_Table, label: string, path: string, must_be_unchanged: bool) -> bool {
	key_add(text, label, input_path(table, path))
	file := input_file(table, path)
	if !file.readable {
		return false
	}
	hash := file.hash
	key_add_bytes(text, "content", hash[:])
	return !must_be_unchanged || input_file_is_unchanged(table, path)
}

@(private = "file")
sorted_copy :: proc(list: []string) -> []string {
	result := slice.clone(list, context.temp_allocator)
	slice.sort(result)
	return result
}

// The inputs of one build key.
Build_Key_Inputs :: struct {
	subject:       string, // What is built: "module console".
	tool_identity: blake3.Hash, // The sources of the tool (tool_identity_of).
	// The programs that build, the commands with each flag, the values of
	// the environment that the build reads: in the order of the list.
	settings:      []string,
	// Files of the repository that the build reads and that the compiler
	// does not list: the assembly files, the keys.
	fixed_files:   []string,
	// Outputs of an earlier step of this build: hashed at the time of the
	// key, never through the table.
	built_files:   []string,
	// Outputs of an earlier step of this build that the caller hashed
	// already: several keys of one build read the same large file.
	hashed_built_files: []Record_Output,
	// The list of the compiler: the source files of every package, and the
	// files of `#load`.
	source_files:  []string,
	load_files:    []string,
}

// build_key gives the build key of the inputs: one BLAKE3 hash over them,
// each list sorted. The files of the folder of each source file are
// inputs too. complete is false when an input cannot be read; with
// inputs_must_be_unchanged, also when a file changed after the tool
// hashed it. A key that is not complete is never recorded and never
// compared.
build_key :: proc(inputs: Build_Key_Inputs, table: ^Input_File_Table, inputs_must_be_unchanged := false) -> (key: blake3.Hash, complete: bool) {
	text := make([dynamic]u8, context.temp_allocator)
	complete = true
	key_add(&text, "subject", inputs.subject)
	tool_identity := inputs.tool_identity
	key_add_bytes(&text, "tool", tool_identity[:])
	for setting in inputs.settings {
		key_add(&text, "setting", setting)
	}
	for path in sorted_copy(inputs.fixed_files) {
		if !key_add_input_file(&text, table, "file", path, inputs_must_be_unchanged) {
			complete = false
		}
	}
	built_paths := sorted_copy(inputs.built_files)
	built_contents := file_contents_read_in_parallel(built_paths, context.temp_allocator)
	for path, index in built_paths {
		key_add(&text, "built file", path)
		if !built_contents[index].readable {
			complete = false
			continue
		}
		hash := built_contents[index].hash
		key_add_bytes(&text, "content", hash[:])
	}
	hashed_built_files := slice.clone(inputs.hashed_built_files, context.temp_allocator)
	slice.sort_by(hashed_built_files, proc(first, second: Record_Output) -> bool {
		return first.path < second.path
	})
	for file in hashed_built_files {
		key_add(&text, "built file", file.path)
		hash := file.hash
		key_add_bytes(&text, "content", hash[:])
	}
	source_paths := sorted_copy(inputs.source_files)
	for path in source_paths {
		if !key_add_input_file(&text, table, "source", path, inputs_must_be_unchanged) {
			complete = false
		}
	}
	for path in sorted_copy(inputs.load_files) {
		if !key_add_input_file(&text, table, "load", path, inputs_must_be_unchanged) {
			complete = false
		}
	}
	// The folder of each package: a file that the compiler did not read is
	// an input by its name and by its bytes, because a new file, or another
	// build tag in an old one, makes it a source.
	folders := make([dynamic]string, context.temp_allocator)
	for path in source_paths {
		append(&folders, folder_of_path(input_path(table, path)))
	}
	slice.sort(folders[:])
	for folder, index in folders {
		if index > 0 && folders[index - 1] == folder {
			continue
		}
		names, readable := input_folder_file_names(table, folder)
		key_add(&text, "folder", folder)
		if !readable {
			complete = false
			continue
		}
		for name in names {
			path := join(folder, "/", name)
			key_add(&text, "file of the folder", name)
			file := input_file(table, path)
			if !file.readable {
				// Not a file that a compiler can read: its name is the input.
				key_add(&text, "not readable", "")
				continue
			}
			hash := file.hash
			key_add_bytes(&text, "content", hash[:])
			if inputs_must_be_unchanged && !input_file_is_unchanged(table, path) {
				complete = false
			}
		}
	}
	return blake3.hash(text[:]), complete
}

// One output of a build record.
Record_Output :: struct {
	path: string,
	hash: blake3.Hash,
}

// A build record: what the tool keeps of one build of one thing.
Build_Record :: struct {
	key:          blake3.Hash,
	outputs:      []Record_Output,
	source_files: []string,
	load_files:   []string,
}

hash_as_hexadecimal :: proc(hash: blake3.Hash) -> string {
	digits := make([]u8, 2 * len(hash), context.temp_allocator)
	for value, index in hash {
		for nibble, place in ([2]u8{value >> 4, value & 0xF}) {
			digits[2 * index + place] = nibble < 10 ? '0' + nibble : 'a' + nibble - 10
		}
	}
	return string(digits)
}

hash_from_hexadecimal :: proc(text: string) -> (hash: blake3.Hash, ok: bool) {
	if len(text) != 2 * len(hash) {
		return {}, false
	}
	for index in 0 ..< len(text) {
		character := text[index]
		nibble: u8
		switch character {
		case '0' ..= '9':
			nibble = character - '0'
		case 'a' ..= 'f':
			nibble = character - 'a' + 10
		case:
			return {}, false
		}
		hash[index / 2] = hash[index / 2] << 4 | nibble
	}
	return hash, true
}

// build_record_text gives the text of a record file: one fact on each line.
build_record_text :: proc(record: Build_Record) -> string {
	text := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&text, "%s\n", BUILD_RECORD_FIRST_LINE)
	fmt.sbprintf(&text, "key %s\n", hash_as_hexadecimal(record.key))
	for output in record.outputs {
		fmt.sbprintf(&text, "output %s %s\n", hash_as_hexadecimal(output.hash), output.path)
	}
	for path in record.source_files {
		fmt.sbprintf(&text, "source %s\n", path)
	}
	for path in record.load_files {
		fmt.sbprintf(&text, "load %s\n", path)
	}
	return strings.to_string(text)
}

// build_record_parse reads the text of a record file. Each line that it
// does not know makes the record invalid: a damaged record is no record.
// The strings of the record are parts of the text.
build_record_parse :: proc(text: string) -> (record: Build_Record, ok: bool) {
	outputs := make([dynamic]Record_Output, context.temp_allocator)
	source_files := make([dynamic]string, context.temp_allocator)
	load_files := make([dynamic]string, context.temp_allocator)
	rest := text
	line_number := 0
	key_count := 0
	for line in strings.split_lines_iterator(&rest) {
		line_number += 1
		if line_number == 1 {
			if line != BUILD_RECORD_FIRST_LINE {
				return {}, false
			}
			continue
		}
		switch {
		case line == "":
		case strings.has_prefix(line, "key "):
			record.key = hash_from_hexadecimal(line[len("key "):]) or_return
			key_count += 1
		case strings.has_prefix(line, "output "):
			fields := line[len("output "):]
			space := strings.index_byte(fields, ' ')
			if space < 0 || space + 1 >= len(fields) {
				return {}, false
			}
			hash := hash_from_hexadecimal(fields[:space]) or_return
			append(&outputs, Record_Output{path = fields[space + 1:], hash = hash})
		case strings.has_prefix(line, "source ") && len(line) > len("source "):
			append(&source_files, line[len("source "):])
		case strings.has_prefix(line, "load ") && len(line) > len("load "):
			append(&load_files, line[len("load "):])
		case:
			return {}, false
		}
	}
	if key_count != 1 || len(outputs) == 0 || len(source_files) == 0 {
		return {}, false
	}
	record.outputs = outputs[:]
	record.source_files = source_files[:]
	record.load_files = load_files[:]
	return record, true
}

// build_record_read reads a record file. A file that is absent, or that
// cannot be read, or that is damaged, gives no record and no message: the
// tool then builds.
build_record_read :: proc(path: string) -> (record: Build_Record, ok: bool) {
	text, error := os.read_entire_file(path, context.temp_allocator)
	if error != nil {
		return {}, false
	}
	return build_record_parse(string(text))
}

// build_record_write hashes the outputs and writes the record file. If
// it cannot, it removes the file: an old record must not stay beside new
// outputs.
build_record_write :: proc(path: string, key: blake3.Hash, output_paths: []string, source_files, load_files: []string) -> bool {
	contents := file_contents_read_in_parallel(output_paths, context.temp_allocator)
	return build_record_write_of_contents(path, key, output_paths, contents, source_files, load_files)
}

// build_record_write_of_contents writes the record file with the hashes
// that the caller read: contents has the order of output_paths. A caller
// with many large outputs reads them all at once, on several threads.
build_record_write_of_contents :: proc(path: string, key: blake3.Hash, output_paths: []string, contents: []File_Content, source_files, load_files: []string) -> bool {
	outputs := make([]Record_Output, len(output_paths), context.temp_allocator)
	written := len(contents) == len(output_paths)
	for output_path, index in output_paths {
		if !written {
			break
		}
		written = contents[index].readable
		outputs[index] = {
			path = output_path,
			hash = contents[index].hash,
		}
	}
	record := Build_Record {
		key          = key,
		outputs      = outputs,
		source_files = source_files,
		load_files   = load_files,
	}
	if written {
		written = os.write_entire_file(path, build_record_text(record)) == nil
	}
	if !written {
		_ = os.remove(path)
	}
	return written
}

// record_names_each_output says if a record names each required path.
record_names_each_output :: proc(record: Build_Record, required_paths: []string) -> bool {
	for required in required_paths {
		named := false
		for output in record.outputs {
			named = named || output.path == required
		}
		if !named {
			return false
		}
	}
	return true
}

// record_outputs_have_their_hashes says if each output of a record is a
// file with the recorded hash. contents is what the caller read of the
// outputs of the record, in their order.
record_outputs_have_their_hashes :: proc(record: Build_Record, contents: []File_Content) -> bool {
	if len(contents) != len(record.outputs) {
		return false
	}
	for output, index in record.outputs {
		if !contents[index].readable || contents[index].hash != output.hash {
			return false
		}
	}
	return true
}

// record_outputs_are_present says if each output of a record is a file
// with the recorded hash, and if the record names each required path.
record_outputs_are_present :: proc(record: Build_Record, required_paths: []string) -> bool {
	if !record_names_each_output(record, required_paths) {
		return false
	}
	paths := make([]string, len(record.outputs), context.temp_allocator)
	for output, index in record.outputs {
		paths[index] = output.path
	}
	return record_outputs_have_their_hashes(record, file_contents_read_in_parallel(paths, context.temp_allocator))
}

// recorded_build_has_its_key reads the record of one thing and says if the
// build key of the inputs as they are now is the key of the record. inputs
// has every input but the list of the compiler, which the record gives.
// reason says why the thing is built.
recorded_build_has_its_key :: proc(record_path: string, inputs: Build_Key_Inputs, table: ^Input_File_Table) -> (record: Build_Record, same: bool, reason: string) {
	recorded: bool
	record, recorded = build_record_read(record_path)
	if !recorded {
		return {}, false, "no build record"
	}
	inputs_now := inputs
	inputs_now.source_files = record.source_files
	inputs_now.load_files = record.load_files
	key, complete := build_key(inputs_now, table)
	if !complete {
		return {}, false, "an input cannot be read"
	}
	if key != record.key {
		return {}, false, "an input changed"
	}
	return record, true, ""
}

// The reason of a build when a file of the last build is gone or has
// other bytes.
OUTPUT_CHANGED_REASON :: "an output is absent or changed"

// recorded_build_is_kept says if the outputs of one thing are those of
// this build with no build: the record is there, the build key of the
// inputs as they are now is the key of the record, and each output is
// there with its recorded hash. reason says why the thing is built.
recorded_build_is_kept :: proc(record_path: string, inputs: Build_Key_Inputs, table: ^Input_File_Table, required_outputs: []string) -> (kept: bool, reason: string) {
	record, same, why := recorded_build_has_its_key(record_path, inputs, table)
	if !same {
		return false, why
	}
	if !record_outputs_are_present(record, required_outputs) {
		return false, OUTPUT_CHANGED_REASON
	}
	return true, ""
}

// dependency_list_parse reads the file that the compiler writes with
// `-export-dependencies:json`: the source files of every package of the
// build, and the files of `#load`, one path on each line. A line that it
// does not know makes the list invalid.
dependency_list_parse :: proc(text: string) -> (source_files, load_files: []string, ok: bool) {
	sources := make([dynamic]string, context.temp_allocator)
	loads := make([dynamic]string, context.temp_allocator)
	Section :: enum {
		None,
		Sources,
		Loads,
	}
	section := Section.None
	sections_seen := 0
	rest := text
	for whole_line in strings.split_lines_iterator(&rest) {
		line := strings.trim(whole_line, " \t\r")
		line = strings.trim_suffix(line, ",")
		switch {
		case line == "" || line == "{" || line == "}":
		case line == "]":
			section = .None
		case line == "\"source_files\": [":
			section = .Sources
			sections_seen += 1
		case line == "\"load_files\": [":
			section = .Loads
			sections_seen += 1
		case len(line) > 2 && line[0] == '"' && line[len(line) - 1] == '"':
			path := line[1:len(line) - 1]
			switch section {
			case .Sources:
				append(&sources, path)
			case .Loads:
				append(&loads, path)
			case .None:
				return nil, nil, false
			}
		case:
			return nil, nil, false
		}
	}
	if sections_seen != 2 || len(sources) == 0 {
		return nil, nil, false
	}
	return sources[:], loads[:], true
}

// dependency_list_read reads the list of one compiler from its file.
dependency_list_read :: proc(path: string) -> (source_files, load_files: []string, ok: bool) {
	text, error := os.read_entire_file(path, context.temp_allocator)
	if error != nil {
		return nil, nil, false
	}
	return dependency_list_parse(string(text))
}

// path_without_dots resolves the parts "." and ".." of a relative path.
path_without_dots :: proc(path: string) -> string {
	parts := make([dynamic]string, context.temp_allocator)
	for part in strings.split(path, "/", context.temp_allocator) {
		switch part {
		case "", ".":
		case "..":
			if len(parts) > 0 && parts[len(parts) - 1] != ".." {
				pop(&parts)
			} else {
				append(&parts, part)
			}
		case:
			append(&parts, part)
		}
	}
	return strings.join(parts[:], "/", context.temp_allocator)
}

// imported_folders_of_source adds the folder of each package of the
// repository that a source file imports: "modus:contract/x" is src/library/contract/x,
// "modus:support/x" is src/library/support/x, and a path with no library is relative to the
// folder of the file. A library of the compiler ("core:", "base:") is not
// a folder of the repository: the compiler itself is an input.
imported_folders_of_source :: proc(source: string, folder: string, folders: ^[dynamic]string) {
	rest := source
	for whole_line in strings.split_lines_iterator(&rest) {
		line := strings.trim_left(whole_line, " \t")
		if !strings.has_prefix(line, "import") || len(line) == len("import") {
			continue
		}
		after := line[len("import")]
		if after != ' ' && after != '\t' && after != '"' {
			continue
		}
		first := strings.index_byte(line, '"')
		if first < 0 {
			continue
		}
		length := strings.index_byte(line[first + 1:], '"')
		if length <= 0 {
			continue
		}
		path := line[first + 1:][:length]
		colon := strings.index_byte(path, ':')
		if package_folder, in_source_library := source_library_package_folder(path); in_source_library {
			append(folders, package_folder)
		} else if colon < 0 {
			append(folders, path_without_dots(join(folder, "/", path)))
		}
	}
}

// tool_identity_of gives one hash over the sources of the tool: every file
// of its folder, and of the folder of each package of the repository that
// they import, to any depth. The code that builds a module is in the
// tool, so a change of the tool can change a module: the identity is an
// input of every build key. The executable of the tool is not the
// identity: two builds of the tool do not give the same file.
tool_identity_of :: proc(table: ^Input_File_Table, tool_folder: string) -> (identity: blake3.Hash, complete: bool) {
	text := make([dynamic]u8, context.temp_allocator)
	folders := make([dynamic]string, context.temp_allocator)
	append(&folders, tool_folder)
	complete = true
	// The list grows while the loop reads it: each folder is read one time.
	for place := 0; place < len(folders); place += 1 {
		folder := folders[place]
		names, readable := input_folder_file_names(table, folder)
		if !readable {
			// A line of a comment or of a text can look like an import: a
			// folder that is not there is not a package. The compiler
			// refuses a true import of such a folder.
			complete = complete && place != 0
			continue
		}
		key_add(&text, "folder", folder)
		for name in names {
			path := join(folder, "/", name)
			if !key_add_input_file(&text, table, "file of the tool", path, false) {
				complete = false
				continue
			}
			if !strings.has_suffix(name, ".odin") {
				continue
			}
			source, error := os.read_entire_file(input_path(table, path), context.temp_allocator)
			if error != nil {
				complete = false
				continue
			}
			imported := make([dynamic]string, context.temp_allocator)
			imported_folders_of_source(string(source), folder, &imported)
			for candidate in imported {
				if !slice.contains(folders[:], candidate) {
					append(&folders, candidate)
				}
			}
		}
	}
	return blake3.hash(text[:]), complete
}

// program_identity names the file of a program of the path: where it is
// after each link, its size and its time. In the store of Nix, the path
// holds the hash of the package: another version is another path.
program_identity :: proc(name: string) -> string {
	search := os.get_env("PATH", context.temp_allocator)
	for folder in strings.split(search, ":", context.temp_allocator) {
		if folder == "" {
			continue
		}
		candidate := join(folder, "/", name)
		information, error := os.stat(candidate, context.temp_allocator)
		if error != nil || information.type != .Regular {
			continue
		}
		resolved, resolve_error := os.get_absolute_path(candidate, context.temp_allocator)
		if resolve_error != nil {
			resolved = candidate
		}
		return fmt.tprintf("program %s: %s, %d bytes, time %d", name, resolved, information.size, time.to_unix_nanoseconds(information.modification_time))
	}
	return fmt.tprintf("program %s: not on the path", name)
}

// What the incremental build knows for the whole of one build.
Build_Inputs :: struct {
	table:           ^Input_File_Table,
	tool_identity:   blake3.Hash,
	// False: a source of the tool cannot be read. Then nothing is kept and
	// no record is written.
	usable:          bool,
	module_programs: [4]string,
	volume_programs: [5]string,
}

build_inputs: Build_Inputs

// build_inputs_prepare hashes the sources before the first compiler of a
// build starts. Each build has its own table: a file can change between
// two builds of one process.
build_inputs_prepare :: proc() {
	started := time.tick_now()
	if build_inputs.table != nil {
		input_file_table_destroy(build_inputs.table)
		for identity in build_inputs.module_programs {
			delete(identity)
		}
		for identity in build_inputs.volume_programs {
			delete(identity)
		}
	}
	build_inputs = {}
	root, error := os.get_working_directory(context.temp_allocator)
	if error != nil {
		root = "."
	}
	folders := INPUT_FOLDERS
	build_inputs.table = input_file_table_make(root, folders[:])
	build_inputs.tool_identity, build_inputs.usable = tool_identity_of(build_inputs.table, TOOL_SOURCE_FOLDER)
	for name, index in ([4]string{"odin", "llc", "nasm", "ld.lld"}) {
		build_inputs.module_programs[index] = strings.clone(program_identity(name))
	}
	for name, index in ([5]string{"odin", "nasm", "lld-link", "sbsign", "virt-fw-vars"}) {
		build_inputs.volume_programs[index] = strings.clone(program_identity(name))
	}
	if !build_inputs.usable {
		fmt.println("kerneltool: a source of the tool cannot be read: the build keeps no output and writes no build record")
	}
	build_measure.input_hash += time.tick_since(started)
	build_measure.input_files = len(build_inputs.table.files)
	build_measure.input_bytes = build_inputs.table.hashed_bytes
}

module_dependency_file :: proc(name: string) -> string {
	return join(module_build_folder, "/", name, "/", DEPENDENCY_FILE_NAME)
}

// The build of a module has two steps, each with its own build key and
// its own build record (docs/TOOLS.md, "The incremental build").
//
// The compile step runs the compiler, llc, the assembler and the link,
// and gives the linked file. It reads no file of an import: a source
// names an export of an import in a `foreign` block, and the link leaves
// the symbol not defined. So its key holds no import.
//
// The conversion writes the module file and the debug object from the
// linked file. It reads the file of each import, for its hash and for the
// numbers of its exports. So its key holds the file of each import, the
// linked file, and the key of the compile step: the description that the
// conversion writes comes from the sources that the compile key holds.
//
// A change inside an import then converts its importers, with no compiler.

COMPILE_RECORD_SUFFIX :: ".compile" + BUILD_RECORD_SUFFIX
CONVERT_RECORD_SUFFIX :: ".convert" + BUILD_RECORD_SUFFIX

// What a build does with one module.
Module_Step :: enum {
	Kept, // No step runs: the outputs of the two steps are those of this build.
	Converted, // The conversion runs alone: the linked file is kept.
	Built, // The compile step runs, then the conversion.
}

// The reason of a conversion when the key of the conversion is not the
// key of its record: the file of an import or the list of the imports
// changed, or a build stopped between the two steps.
CONVERSION_INPUT_CHANGED_REASON :: "an import or the linked file changed"

// The two steps of one module: the record, the inputs and the outputs of
// each. No field names a global of the build, so a test gives its own.
Module_Steps :: struct {
	compile_record_path: string,
	convert_record_path: string,
	// Every input of the compile step but the list of the compiler.
	compile_inputs:      Build_Key_Inputs,
	// The inputs of the conversion that are its own: the imports in the
	// order of the module table (settings), and the file of each one
	// (built_files). The compile key and the linked file are added to them
	// (module_convert_key).
	convert_inputs:      Build_Key_Inputs,
	compile_outputs:     []string, // The linked file.
	convert_outputs:     []string, // The module file, and its debug object.
}

// module_convert_key gives the build key of the conversion of a module.
// compile_key is the key of the compile step whose outputs are
// compiled_outputs, each with its hash.
module_convert_key :: proc(steps: Module_Steps, compile_key: blake3.Hash, compiled_outputs: []Record_Output, table: ^Input_File_Table) -> (key: blake3.Hash, complete: bool) {
	inputs := steps.convert_inputs
	settings := make([dynamic]string, context.temp_allocator)
	append(&settings, ..inputs.settings)
	append(&settings, "the key of the compile step", hash_as_hexadecimal(compile_key))
	inputs.settings = settings[:]
	inputs.hashed_built_files = compiled_outputs
	// The conversion reads no source through a list: the compile key
	// holds each source.
	inputs.source_files = nil
	inputs.load_files = nil
	return build_key(inputs, table)
}

// module_step_needed says what a build does with a module. The compile
// step is kept when its record has the build key of its inputs as they
// are now and the linked file has its recorded hash. The conversion is
// kept when, with that, its record has the key of the conversion as it is
// now (the file of each import) and each of its outputs has its recorded
// hash. reason says why a step runs.
module_step_needed :: proc(steps: Module_Steps, table: ^Input_File_Table) -> (step: Module_Step, reason: string) {
	compile_record, same, why := recorded_build_has_its_key(steps.compile_record_path, steps.compile_inputs, table)
	if !same {
		return .Built, why
	}
	if !record_outputs_are_present(compile_record, steps.compile_outputs) {
		return .Built, OUTPUT_CHANGED_REASON
	}
	convert_key, complete := module_convert_key(steps, compile_record.key, compile_record.outputs, table)
	if !complete {
		// The conversion says which import it cannot read.
		return .Converted, "the file of an import cannot be read"
	}
	convert_record, recorded := build_record_read(steps.convert_record_path)
	if !recorded {
		return .Converted, "no build record of the conversion"
	}
	if convert_record.key != convert_key {
		return .Converted, CONVERSION_INPUT_CHANGED_REASON
	}
	if !record_outputs_are_present(convert_record, steps.convert_outputs) {
		return .Converted, OUTPUT_CHANGED_REASON
	}
	return .Kept, ""
}

// module_step_records_write writes the build records of a module after
// its steps ran. compiled says that the compile step ran: source_files and
// load_files are then the new list of the compiler, and the record of the
// compile step is written. If not, they are the list of the record of
// the compile step, which stays.
//
// The conversion reads the sources too (the description of the exports).
// So the record of the conversion is written only when no input of the
// compile step changed since the tool hashed it: with a change, the tool
// removes the record, and the next build compiles the module.
module_step_records_write :: proc(steps: Module_Steps, table: ^Input_File_Table, compiled: bool, source_files, load_files: []string) -> bool {
	compile_inputs := steps.compile_inputs
	compile_inputs.source_files = source_files
	compile_inputs.load_files = load_files
	compile_key, complete := build_key(compile_inputs, table, true)
	if !complete || len(source_files) == 0 {
		// The linked file of a compile step that ran is not the linked
		// file of the old record: the old record must not stay beside it.
		if compiled {
			_ = os.remove(steps.compile_record_path)
		}
		_ = os.remove(steps.convert_record_path)
		return false
	}
	compiled_contents := file_contents_read_in_parallel(steps.compile_outputs, context.temp_allocator)
	compiled_outputs := make([]Record_Output, len(steps.compile_outputs), context.temp_allocator)
	for path, index in steps.compile_outputs {
		compiled_outputs[index] = {
			path = path,
			hash = compiled_contents[index].hash,
		}
	}
	if compiled {
		if !build_record_write_of_contents(steps.compile_record_path, compile_key, steps.compile_outputs, compiled_contents, source_files, load_files) {
			_ = os.remove(steps.convert_record_path)
			return false
		}
	} else {
		for content in compiled_contents {
			if !content.readable {
				_ = os.remove(steps.convert_record_path)
				return false
			}
		}
	}
	convert_key, convert_complete := module_convert_key(steps, compile_key, compiled_outputs, table)
	if !convert_complete {
		_ = os.remove(steps.convert_record_path)
		return false
	}
	// The form of a record asks for a list of sources: the record of the
	// conversion names those of the compile step, which its key covers.
	return build_record_write(steps.convert_record_path, convert_key, steps.convert_outputs, source_files, load_files)
}

module_compile_record_path :: proc(name: string) -> string {
	return join(module_build_folder, "/", name, COMPILE_RECORD_SUFFIX)
}

module_convert_record_path :: proc(name: string) -> string {
	return join(module_build_folder, "/", name, CONVERT_RECORD_SUFFIX)
}

// module_compile_key_inputs gives the inputs of the build key of the
// compile step of a module, without the list of the compiler. It names no
// import: the compile step reads none (modules.odin, module_compile).
module_compile_key_inputs :: proc(build: Module_Build) -> (inputs: Build_Key_Inputs, ok: bool) {
	settings := make([dynamic]string, context.temp_allocator)
	append(&settings, ..build_inputs.module_programs[:])
	append(&settings, "the compiler")
	append(&settings, ..module_compile_command(build))
	append(&settings, "the object")
	append(&settings, ..module_object_command(build))
	append(&settings, build.source, build.kernel ? "runs in kernel mode" : "runs in user mode", build.image ? "with the system library" : "with no system library")
	assembly_files := module_assembly_files(build) or_return
	inputs = {
		subject       = join("the compile step of the module ", build.name),
		tool_identity = build_inputs.tool_identity,
		settings      = settings[:],
		fixed_files   = assembly_files,
	}
	return inputs, true
}

// module_convert_key_inputs gives the inputs of the build key of the
// conversion of a module that are its own: the imports in the order of
// the module table, which is the order of the import table of the module
// file, and the module file of each one, hashed at the time of the key.
module_convert_key_inputs :: proc(build: Module_Build) -> Build_Key_Inputs {
	settings := make([dynamic]string, context.temp_allocator)
	append(&settings, debug_information ? "with a debug object" : "with no debug object")
	built_files := make([dynamic]string, context.temp_allocator)
	for name in build.imports {
		append(&settings, "imports", name)
		append(&built_files, module_path(name))
	}
	return {subject = join("the conversion of the module ", build.name), tool_identity = build_inputs.tool_identity, settings = settings[:], built_files = built_files[:]}
}

// module_steps_of gives the two steps of a module of the table, in the
// folder of this build.
module_steps_of :: proc(build: Module_Build) -> (steps: Module_Steps, ok: bool) {
	compile_outputs := make([]string, 1, context.temp_allocator)
	// The test of the stack trace reads the symbols of the linked file.
	compile_outputs[0] = module_linked_file(build.name)
	convert_outputs := make([dynamic]string, context.temp_allocator)
	append(&convert_outputs, module_path(build.name))
	if debug_information {
		append(&convert_outputs, debug_object_path(build.name))
	}
	compile_inputs := module_compile_key_inputs(build) or_return
	steps = {
		compile_record_path = module_compile_record_path(build.name),
		convert_record_path = module_convert_record_path(build.name),
		compile_inputs      = compile_inputs,
		convert_inputs      = module_convert_key_inputs(build),
		compile_outputs     = compile_outputs,
		convert_outputs     = convert_outputs[:],
	}
	return steps, true
}

// module_step_of_build says what this build does with a module of the
// table: nothing, its conversion alone, or its two steps. The LLVM IR
// and the object of a module that is not built stay from the build that
// made its linked file: only the checks that compare two whole builds
// read them.
module_step_of_build :: proc(build: Module_Build) -> (step: Module_Step, reason: string) {
	if build_whole {
		return .Built, "a whole build"
	}
	if !build_inputs.usable {
		return .Built, "a source of the tool cannot be read"
	}
	steps, readable := module_steps_of(build)
	if !readable {
		return .Built, "an input cannot be read"
	}
	return module_step_needed(steps, build_inputs.table)
}

// module_records_write writes the build records of a module of the table
// after its steps ran: step is what the build did with it. With no list
// of the compiler, or with an input that changed during the build, no
// record of the conversion stays: the next build runs a step again.
module_records_write :: proc(build: Module_Build, step: Module_Step) -> bool {
	compile_record_path := module_compile_record_path(build.name)
	convert_record_path := module_convert_record_path(build.name)
	steps, readable := module_steps_of(build)
	source_files, load_files: []string
	listed := false
	if step == .Built {
		source_files, load_files, listed = dependency_list_read(module_dependency_file(build.name))
	} else {
		compile_record: Build_Record
		compile_record, listed = build_record_read(compile_record_path)
		source_files, load_files = compile_record.source_files, compile_record.load_files
	}
	if !build_inputs.usable || !readable || !listed {
		if step == .Built {
			_ = os.remove(compile_record_path)
		}
		_ = os.remove(convert_record_path)
		return false
	}
	return module_step_records_write(steps, build_inputs.table, step == .Built, source_files, load_files)
}

// paths_outside_the_build_folder leaves out the files of the build
// folder: an output of this build is hashed as a built file, never
// through the table of the sources.
paths_outside_the_build_folder :: proc(paths: []string) -> []string {
	inside_by_name := join(build_inputs.table.root, "/", BUILD_FOLDER, "/")
	inside_by_link := inside_by_name
	// The build folder can be a link to another disk: the compiler names
	// a file where it is after the link.
	if resolved, error := os.get_absolute_path(BUILD_FOLDER, context.temp_allocator); error == nil {
		inside_by_link = join(resolved, "/")
	}
	outside := make([dynamic]string, context.temp_allocator)
	for path in paths {
		if !strings.has_prefix(path, inside_by_name) && !strings.has_prefix(path, inside_by_link) {
			append(&outside, path)
		}
	}
	return outside[:]
}

// The time of one step of a build after the modules.
Build_Step_Time :: struct {
	name:     string,
	duration: time.Duration,
}

// The measure of one build: where its time goes. Each number is a
// measure: nothing reads one, and nothing fails because of one.
Build_Measure :: struct {
	started:              time.Tick,
	input_hash:           time.Duration, // The hash of the sources, before the first compiler.
	input_files:          int,
	input_bytes:          i64,
	record_checks:        time.Duration, // The read of the records, the keys, the hash of the kept outputs.
	record_writes:        time.Duration,
	modules:              time.Duration, // The whole step of the modules, with the two above.
	modules_built:        int, // The two steps ran.
	modules_converted:    int, // The conversion ran alone.
	modules_kept:         int,
	// The time of the processes of each step, all levels together, as a
	// clock on the wall sees it: several processes run at once.
	module_compile_steps: time.Duration,
	module_conversions:   time.Duration,
	steps:                [dynamic]Build_Step_Time,
	volumes_built:        int,
	volumes_kept:         int,
	volumes_not_needed:   int, // The volumes that the command does not boot: not checked, not built.
	volume_processes:     int, // The volume processes at once.
	volume_times:         [dynamic]Build_Step_Time, // The whole time of the process of each built volume.
}

build_measure: Build_Measure

build_measure_start :: proc() {
	for step in build_measure.steps {
		delete(step.name)
	}
	delete(build_measure.steps)
	for volume_time in build_measure.volume_times {
		delete(volume_time.name)
	}
	delete(build_measure.volume_times)
	build_measure = {
		started = time.tick_now(),
	}
}

// build_measure_step records the time of one step, from started to now.
build_measure_step :: proc(name: string, started: time.Tick) {
	append(&build_measure.steps, Build_Step_Time{name = strings.clone(name), duration = time.tick_since(started)})
}

// build_measure_lines gives the lines of the measure of a build.
build_measure_lines :: proc(measure: Build_Measure, whole: time.Duration) -> []string {
	seconds :: proc(duration: time.Duration) -> f64 {
		return time.duration_seconds(duration)
	}
	lines := make([dynamic]string, context.temp_allocator)
	append(&lines, fmt.tprintf("the build %.1f s: the hash of %d input files (%d bytes) %.2f s; the modules %.1f s: %d built, %d converted, %d kept (the compile steps %.2f s, the conversions %.2f s, the checks of the build records %.2f s, their writes %.2f s)", seconds(whole), measure.input_files, measure.input_bytes, seconds(measure.input_hash), seconds(measure.modules), measure.modules_built, measure.modules_converted, measure.modules_kept, seconds(measure.module_compile_steps), seconds(measure.module_conversions), seconds(measure.record_checks), seconds(measure.record_writes)))
	for step in measure.steps {
		append(&lines, fmt.tprintf("the build: %8.2f s: %s", seconds(step.duration), step.name))
	}
	if measure.volumes_built + measure.volumes_kept + measure.volumes_not_needed > 0 {
		append(&lines, fmt.tprintf("the build: the boot volumes: %d built, %d kept, %d not needed by this command; %d volume processes at once", measure.volumes_built, measure.volumes_kept, measure.volumes_not_needed, measure.volume_processes))
	}
	for volume_time in measure.volume_times {
		append(&lines, fmt.tprintf("the build: %8.2f s: the process of the boot volume %s", seconds(volume_time.duration), volume_time.name))
	}
	return lines[:]
}

build_measure_print :: proc() {
	for line in build_measure_lines(build_measure, time.tick_since(build_measure.started)) {
		fmt.printfln("kerneltool: measure: %s", line)
	}
}
