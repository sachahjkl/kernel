package kerneltool

import "contract:blake3"
import debug_object "contract:debug_object"
import module "contract:module"
import "core:fmt"
import "core:os"
import "core:strings"

// The source line of a row of the debugger (docs/TOOLS.md, "Debugging
// from another machine"). The machine holds no source text: the export
// `debugger.source` gives the path of a file from the root of the
// repository, a line, and the BLAKE3 hash of the file at the build of the
// module. The developer has the sources: `kerneltool call` reads the file
// of the repository and prints the line after the table, only when the
// file has that hash. With another hash the line of that number is not
// the line of the code, and the tool says so.
//
// The rule has no name of a service in it: each Table result whose record
// has the Text fields `path` and `hash` and the Integer field `line` gets
// its source lines.

// source_line_of_content gives the line `line` (from 1) of the content of
// a file, with no end of line.
source_line_of_content :: proc(content: string, line: int) -> (text: string, found: bool) {
	if line < 1 {
		return "", false
	}
	rest := content
	for number := 1; len(rest) > 0; number += 1 {
		end := strings.index_byte(rest, '\n')
		current := end < 0 ? rest : rest[:end]
		if number == line {
			return strings.trim_right(current, "\r"), true
		}
		if end < 0 {
			break
		}
		rest = rest[end + 1:]
	}
	return "", false
}

// source_path_is_of_the_repository says if a path that a machine gave
// stays under the root of the repository: not absolute, no part "..", and
// no file of the compiler ("base:", "core:").
source_path_is_of_the_repository :: proc(path: string) -> bool {
	if path == "" || path[0] == '/' || strings.index_byte(path, ':') >= 0 {
		return false
	}
	return !debug_object.path_has_parent_part(path)
}

// source_line_sentence gives the line that the tool prints for one source
// place: the text of the line when the content has the hash, else why not.
// `content_read` is false when the repository has no such file.
source_line_sentence :: proc(path: string, line: int, hash_text: string, content: []u8, content_read: bool) -> string {
	if !source_path_is_of_the_repository(path) {
		return fmt.tprintf("source: %s:%d: not a file of the repository: its line is not shown", path, line)
	}
	if !content_read {
		return fmt.tprintf("source: %s:%d: the repository has no such file", path, line)
	}
	if hash_text == "" {
		return fmt.tprintf("source: %s:%d: the build did not hash the file: its line is not shown", path, line)
	}
	hash := blake3.hash(content)
	if hex_of(hash[:]) != hash_text {
		return fmt.tprintf("source: %s:%d: the file changed since the build of the module (its hash differs): its line is not shown", path, line)
	}
	text, found := source_line_of_content(string(content), line)
	if !found {
		return fmt.tprintf("source: %s:%d: the file has no such line", path, line)
	}
	return fmt.tprintf("source: %s:%d: %s", path, line, text)
}

// source_lines_of_table adds one line for each row of a table that names
// a source place: see the top of this file. A table of another record
// gets nothing.
source_lines_of_table :: proc(lines: ^[dynamic]string, file: []u8, described: module.Record, bytes: []u8) {
	path_field, line_field, hash_field: module.Field
	has_path, has_line, has_hash: bool
	for number in 0 ..< described.field_count {
		item, valid := module.field(file, described, number)
		if !valid {
			return
		}
		switch module.string_at(file, item.name_offset, item.name_count) {
		case "path":
			path_field, has_path = item, item.type == .Text
		case "line":
			line_field, has_line = item, item.type == .Integer
		case "hash":
			hash_field, has_hash = item, item.type == .Text
		}
	}
	if !has_path || !has_line || !has_hash {
		return
	}
	size := int(max(described.size, 1))
	for row in 0 ..< len(bytes) / size {
		record := bytes[row * size:][:size]
		path := module.field_text(record, path_field)
		line := int(module.field_integer(record, line_field))
		content: []u8
		content_read := false
		if source_path_is_of_the_repository(path) {
			read, read_error := os.read_entire_file(path, context.temp_allocator)
			content, content_read = read, read_error == nil
		}
		append(lines, source_line_sentence(path, line, module.field_text(record, hash_field), content, content_read))
	}
}
