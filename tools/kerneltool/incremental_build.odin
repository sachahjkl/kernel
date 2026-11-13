package kerneltool

import "contract:blake3"
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

// A whole build ignores every build record, and writes new ones.
// `build whole` sets it; the checks that compare two builds set it too
// (repeat.odin), and the full checks (`check`, `screenshots`).
build_whole := false

BUILD_RECORD_FIRST_LINE :: "build record, form 1"
BUILD_RECORD_SUFFIX :: ".build_record"
DEPENDENCY_FILE_NAME :: "dependencies.json"
BOOT_DEPENDENCY_FILE :: BUILD_FOLDER + "/boot_" + DEPENDENCY_FILE_NAME
BOOT_VOLUMES_RECORD_FILE :: BUILD_FOLDER + "/boot_volumes" + BUILD_RECORD_SUFFIX
TOOL_SOURCE_FOLDER :: "tools/kerneltool"

// The folders of the repository that hold sources of a build. The tool
// hashes each of their files once, before the first compiler starts. A
// file outside them (the libraries of the compiler) is hashed at its first
// use.
INPUT_FOLDERS :: [?]string{"boot", "contract", "kernel", "modules", "programs", "resources", "runtime", "support", TOOL_SOURCE_FOLDER}

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
	outputs := make([]Record_Output, len(output_paths), context.temp_allocator)
	written := true
	for output_path, index in output_paths {
		written = written && contents[index].readable
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

// record_outputs_are_present says if each output of a record is a file
// with the recorded hash, and if the record names each required path.
record_outputs_are_present :: proc(record: Build_Record, required_paths: []string) -> bool {
	for required in required_paths {
		named := false
		for output in record.outputs {
			named = named || output.path == required
		}
		if !named {
			return false
		}
	}
	paths := make([]string, len(record.outputs), context.temp_allocator)
	for output, index in record.outputs {
		paths[index] = output.path
	}
	contents := file_contents_read_in_parallel(paths, context.temp_allocator)
	for output, index in record.outputs {
		if !contents[index].readable || contents[index].hash != output.hash {
			return false
		}
	}
	return true
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

@(private = "file")
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
// repository that a source file imports: "contract:x" is contract/x,
// "support:x" is support/x, and a path with no library is relative to the
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
		switch {
		case strings.has_prefix(path, "contract:"):
			append(folders, join("contract/", path[len("contract:"):]))
		case strings.has_prefix(path, "support:"):
			append(folders, join("support/", path[len("support:"):]))
		case colon >= 0:
		case:
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

module_record_path :: proc(name: string) -> string {
	return join(module_build_folder, "/", name, BUILD_RECORD_SUFFIX)
}

module_dependency_file :: proc(name: string) -> string {
	return join(module_build_folder, "/", name, "/", DEPENDENCY_FILE_NAME)
}

// module_recorded_outputs gives the outputs of a module that a later step
// or a test reads: the module, its debug object, and the linked file (the
// test of the stack trace reads its symbols). The LLVM IR and the object
// are read only by the checks that compare two whole builds.
module_recorded_outputs :: proc(build: Module_Build) -> []string {
	outputs := make([dynamic]string, context.temp_allocator)
	append(&outputs, module_path(build.name), join(module_build_folder, "/", build.name, "/linked.elf"))
	if debug_information {
		append(&outputs, debug_object_path(build.name))
	}
	return outputs[:]
}

// module_key_inputs gives the inputs of the build key of a module, with
// the list of the compiler of its last build.
module_key_inputs :: proc(build: Module_Build, source_files, load_files: []string) -> (inputs: Build_Key_Inputs, ok: bool) {
	settings := make([dynamic]string, context.temp_allocator)
	append(&settings, ..build_inputs.module_programs[:])
	append(&settings, "the compiler")
	append(&settings, ..module_compile_command(build))
	append(&settings, "the object")
	append(&settings, ..module_object_command(build))
	append(&settings, build.source, build.kernel ? "runs in kernel mode" : "runs in user mode", build.image ? "with the system library" : "with no system library")
	built_files := make([dynamic]string, context.temp_allocator)
	for name in build.imports {
		append(&settings, "imports", name)
		append(&built_files, module_path(name))
	}
	assembly_files := module_assembly_files(build) or_return
	inputs = {
		subject       = join("module ", build.name),
		tool_identity = build_inputs.tool_identity,
		settings      = settings[:],
		fixed_files   = assembly_files,
		built_files   = built_files[:],
		source_files  = source_files,
		load_files    = load_files,
	}
	return inputs, true
}

// module_is_kept says if the outputs of a module are those of this build
// with no build: its record has the build key of the inputs as they are
// now, and each output is there with its recorded hash. reason says why
// the module is built.
module_is_kept :: proc(build: Module_Build) -> (kept: bool, reason: string) {
	if build_whole {
		return false, "a whole build"
	}
	if !build_inputs.usable {
		return false, "a source of the tool cannot be read"
	}
	record, recorded := build_record_read(module_record_path(build.name))
	if !recorded {
		return false, "no build record"
	}
	inputs, readable := module_key_inputs(build, record.source_files, record.load_files)
	if !readable {
		return false, "an input cannot be read"
	}
	key, complete := build_key(inputs, build_inputs.table)
	if !complete {
		return false, "an input cannot be read"
	}
	if key != record.key {
		return false, "an input changed"
	}
	if !record_outputs_are_present(record, module_recorded_outputs(build)) {
		return false, "an output is absent or changed"
	}
	return true, ""
}

// module_record_write writes the build record of a module that was just
// built. With no list of the compiler, or with an input that changed
// during the build, it removes the record: the next build builds the
// module.
module_record_write :: proc(build: Module_Build) -> bool {
	record_path := module_record_path(build.name)
	if !build_inputs.usable {
		_ = os.remove(record_path)
		return false
	}
	source_files, load_files, listed := dependency_list_read(module_dependency_file(build.name))
	inputs, readable := module_key_inputs(build, source_files, load_files)
	key, complete := build_key(inputs, build_inputs.table, true)
	if !listed || !readable || !complete {
		_ = os.remove(record_path)
		return false
	}
	return build_record_write(record_path, key, module_recorded_outputs(build), source_files, load_files)
}

// The outputs of the boot volumes of this build, as build_boot_program
// wrote them.
boot_volume_outputs: [dynamic]string

// boot_volume_outputs_forget empties the list before the boot volumes of
// a build are written.
boot_volume_outputs_forget :: proc() {
	for path in boot_volume_outputs {
		delete(path)
	}
	clear(&boot_volume_outputs)
}

// boot_volume_output_note adds one output of the boot volumes.
boot_volume_output_note :: proc(path: string) {
	if !slice.contains(boot_volume_outputs[:], path) {
		append(&boot_volume_outputs, strings.clone(path))
	}
}

// paths_outside_the_build_folder leaves out the files of the build
// folder: an output of this build is hashed as a built file, never
// through the table of the sources.
@(private = "file")
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

// boot_volumes_key_inputs gives the inputs of the build key of all the
// boot volumes: the boot images, the debug image and the two kernels as
// they are now, the sources of the boot program (the list of its
// compiler), the test keys, and the programs that build and sign. With
// the signing key of the publisher of the system, usable is false: the
// tool never keeps a volume that this key signs, and never hashes that key.
boot_volumes_key_inputs :: proc(source_files, load_files: []string) -> (inputs: Build_Key_Inputs, usable: bool) {
	if os.get_env(SIGNING_KEY_VARIABLE, context.temp_allocator) != "" {
		return {}, false
	}
	settings := make([dynamic]string, context.temp_allocator)
	append(&settings, ..build_inputs.volume_programs[:])
	append(&settings, join("OVMF_FULL_VARS=", os.get_env("OVMF_FULL_VARS", context.temp_allocator)))
	fixed_files := make([dynamic]string, context.temp_allocator)
	append(&fixed_files, "boot/jump.asm", RUNTIME_MEMORY, TEST_SIGNING_KEY_FILE, TEST_FIRMWARE_SIGNING_KEY_FILE, TEST_FIRMWARE_CERTIFICATE_FILE)
	built_files := make([dynamic]string, context.temp_allocator)
	append(&built_files, BOOT_IMAGE, BOOT_IMAGE_FAILS, BOOT_IMAGE_SHORTAGE, DEBUG_IMAGE, module_path("kernel"), module_path("kernel_without_return_check"))
	inputs = {
		subject       = "the boot volumes",
		tool_identity = build_inputs.tool_identity,
		settings      = settings[:],
		fixed_files   = fixed_files[:],
		built_files   = built_files[:],
		source_files  = paths_outside_the_build_folder(source_files),
		load_files    = paths_outside_the_build_folder(load_files),
	}
	return inputs, true
}

// boot_volumes_are_kept says if every boot volume is that of this build
// with no build.
boot_volumes_are_kept :: proc() -> (kept: bool, reason: string) {
	if build_whole {
		return false, "a whole build"
	}
	if build_inputs.table == nil || !build_inputs.usable {
		return false, "a source of the tool cannot be read"
	}
	record, recorded := build_record_read(BOOT_VOLUMES_RECORD_FILE)
	if !recorded {
		return false, "no build record"
	}
	inputs, usable := boot_volumes_key_inputs(record.source_files, record.load_files)
	if !usable {
		return false, "the signing key of the publisher of the system signs: its volumes are never kept"
	}
	key, complete := build_key(inputs, build_inputs.table)
	if !complete {
		return false, "an input cannot be read"
	}
	if key != record.key {
		return false, "an input changed"
	}
	if !record_outputs_are_present(record, {BOOT_VOLUME}) {
		return false, "an output is absent or changed"
	}
	return true, ""
}

// boot_volumes_record_write writes the build record of the boot volumes
// that this build wrote.
boot_volumes_record_write :: proc() -> bool {
	if build_inputs.table == nil || !build_inputs.usable {
		_ = os.remove(BOOT_VOLUMES_RECORD_FILE)
		return false
	}
	source_files, load_files, listed := dependency_list_read(BOOT_DEPENDENCY_FILE)
	inputs, usable := boot_volumes_key_inputs(source_files, load_files)
	if !listed || !usable {
		_ = os.remove(BOOT_VOLUMES_RECORD_FILE)
		return false
	}
	key, complete := build_key(inputs, build_inputs.table, true)
	if !complete {
		_ = os.remove(BOOT_VOLUMES_RECORD_FILE)
		return false
	}
	return build_record_write(BOOT_VOLUMES_RECORD_FILE, key, boot_volume_outputs[:], inputs.source_files, inputs.load_files)
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
	modules_built:        int,
	modules_kept:         int,
	steps:                [dynamic]Build_Step_Time,
	volumes_built:        int,
	volumes_kept:         bool,
	volume_signed_images: time.Duration,
	volume_compiles:      time.Duration,
	volume_links:         time.Duration,
	volume_writes:        time.Duration,
}

build_measure: Build_Measure

build_measure_start :: proc() {
	for step in build_measure.steps {
		delete(step.name)
	}
	delete(build_measure.steps)
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
	append(&lines, fmt.tprintf("the build %.1f s: the hash of %d input files (%d bytes) %.2f s; the modules %.1f s: %d built, %d kept (the checks of the build records %.2f s, their writes %.2f s)", seconds(whole), measure.input_files, measure.input_bytes, seconds(measure.input_hash), seconds(measure.modules), measure.modules_built, measure.modules_kept, seconds(measure.record_checks), seconds(measure.record_writes)))
	for step in measure.steps {
		append(&lines, fmt.tprintf("the build: %8.2f s: %s", seconds(step.duration), step.name))
	}
	if measure.volumes_kept {
		append(&lines, "the build: the boot volumes are kept: no boot program was built")
	} else if measure.volumes_built > 0 {
		append(&lines, fmt.tprintf("the build: in the %d boot volumes: the signed boot images %.1f s, the compiler of the boot program %.1f s, the assembler, the link and the firmware signature %.1f s, the volume files %.1f s", measure.volumes_built, seconds(measure.volume_signed_images), seconds(measure.volume_compiles), seconds(measure.volume_links), seconds(measure.volume_writes)))
	}
	return lines[:]
}

build_measure_print :: proc() {
	for line in build_measure_lines(build_measure, time.tick_since(build_measure.started)) {
		fmt.printfln("kerneltool: measure: %s", line)
	}
}
