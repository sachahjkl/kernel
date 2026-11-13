// The debug object of a module (docs/MODULE_CONTRACT.md, "Debug
// information"): the names of the procedures of the module and the source
// lines of its code, as sorted tables of fixed records. A reader names an
// offset of the module "fault::three + 0x8 (programs/fault/main.odin:15)"
// with a binary search, no allocator and no parser of DWARF.
//
// The kernel tool writes it at the build from the linked ELF file of the
// module: the procedure table from the symbol table, the line table from
// the line program of DWARF. The system reads no DWARF: a parser of DWARF
// is a large parser of hostile input, and the tool runs it on its own
// output at the build.
//
// The debug object names its module by the hash of the module file. The
// module names nothing: its bytes are the same with and without its debug
// object, and with each format of the debug object.
//
// The file, all numbers little-endian:
//
//   Header                                  64 bytes
//   Procedure, header.procedure_count times 16 bytes each, by their start
//   File, header.file_count times           8 bytes each; file 0 is "no file"
//   Line, header.line_count times           8 bytes each, by their offset
//   Strings                                 header.string_size bytes
//
// and no other byte. The reader refuses every other form (check).
//
// Who uses it: the kernel tool writes the debug objects (`encode`) into the
// debug image; the program `errors`, the console and the developer tools
// read them through `system.Debug_Names` to name the frames of a stop
// report (`check`, `place_of`).
//
// Example: the frame `0x0040_1234` of a stop report, in the module at
// 0x0040_0000, is the offset 0x1234; `place_of` gives `{procedure =
// "fault::three", offset_in_procedure = 8, file = "programs/fault/main.odin",
// line = 15}`.
//
// See [debug object](term:debug-object) and [debug image](term:debug-image).
package debug_object

import "base:intrinsics"

MAGIC :: u64(0x4A424F4755424544) // The bytes "DEBUGOBJ".
VERSION :: 1 // The version of the format. A reader refuses another.

// The bounds of a reader. The console module of today has about 210
// procedures and 270 KiB of code.
PROCEDURE_CAPACITY :: 1 << 20
FILE_CAPACITY :: 1 << ROW_FILE_BITS // The files: what the file part of a row holds.
LINE_CAPACITY :: 1 << 24 // The rows of the line table.
STRING_CAPACITY :: 1 << 26 // The bytes of the strings: 64 MiB.

// The first 64 bytes of a debug object.
Header :: struct {
	magic:           u64, // MAGIC.
	version:         u32, // VERSION.
	procedure_count: u32, // The records of the procedure table.
	module_hash:     [32]u8, // The BLAKE3 hash of the module file that this object describes.
	file_count:      u32, // With the file 0.
	line_count:      u32, // The rows of the line table.
	string_size:     u32, // The bytes of the strings.
	reserved:        u32, // Zero.
}
#assert(size_of(Header) == 64)

// One procedure of the module: a range of its code.
Procedure :: struct {
	start:         u32, // The offset of its first instruction in the memory of the module.
	size:          u32, // Bytes, 1 at least. Two procedures never overlap.
	name_offset:   u32, // In the strings.
	name_count:    u16, // The bytes of the name.
	// The first package_count bytes of the name are its package, then
	// "::" and the name of the procedure in the package. 0: the name has no
	// package (an export, a procedure of an assembler file).
	package_count: u16,
}
#assert(size_of(Procedure) == 16)

// One source file: its path from the root of the repository
// ("programs/fault/main.odin"), or "base:runtime/print.odin" for a file of
// the Odin compiler.
File :: struct {
	path_offset: u32, // In the strings.
	path_count:  u32, // The bytes of the path.
}
#assert(size_of(File) == 8)

// One row of the line table: the code from `offset` up to the offset of
// the next row comes from one line of one file. A row with the file 0 says
// that the code after it has no source line (the end of a procedure, the
// padding between two procedures). The last row has the file 0.
//
// The file and the line share one word: the rows are most of the bytes of
// a debug object, and a module has far fewer than 4096 source files and
// no file has a million lines. The tool refuses a module past either bound.
Line :: struct {
	offset: u32, // The offset in the memory of the module where the row starts.
	place:  u32, // The file in the high ROW_FILE_BITS bits, the line (from 1; 0 only with the file 0) in the others.
}
#assert(size_of(Line) == 8)

ROW_FILE_BITS :: 12 // The bits of the file in a row: 4096 files.
ROW_LINE_BITS :: 32 - ROW_FILE_BITS // The bits of the line in a row: about a million lines.
ROW_LINE_LIMIT :: u32(1) << ROW_LINE_BITS // The lines of a row are below it.

// row_place gives the word of a row for a file and a line, both inside
// their bounds.
row_place :: proc "contextless" (file: u32, line: u32) -> u32 {
	return file << ROW_LINE_BITS | line & (ROW_LINE_LIMIT - 1)
}

// row_file gives the file of a row.
row_file :: proc "contextless" (row: Line) -> u32 {
	return row.place >> ROW_LINE_BITS
}

// row_line gives the line of a row.
row_line :: proc "contextless" (row: Line) -> u32 {
	return row.place & (ROW_LINE_LIMIT - 1)
}

// Why a check refused a debug object.
Fault :: enum u32 {
	None               = 0, // The object is whole.
	Too_Small          = 1, // Shorter than its header.
	Not_A_Debug_Object = 2, // Another magic number.
	Version            = 3, // Another version.
	Too_Many           = 4, // A count over its capacity.
	Size_Differs       = 5, // The size of the file is not the size of its tables.
	Reserved           = 6, // A field that must be zero is not.
	Procedure_Order    = 7, // A procedure that does not start after the end of the one before it, or with no byte.
	Procedure_Name     = 8, // A name outside the strings, empty, or with a byte that is not a visible character (name_bytes_valid).
	Procedure_Package  = 9, // A package that is not followed by "::" in the name.
	File_Zero          = 10, // The file 0 is not all zero.
	File_Path          = 11, // A path outside the strings, empty, with a byte that is not a visible character, or with a part "..".
	Line_Order         = 12, // A row that does not come after the row before it.
	Line_File          = 13, // A row that names a file that the table does not have, or a line 0 with a file.
	Line_End           = 14, // The last row has a file.
}

// The sentence of each fault, for the log and the console.
@(rodata)
fault_sentences := [Fault]string {
	.None               = "the debug object is whole",
	.Too_Small          = "the debug object is shorter than its header",
	.Not_A_Debug_Object = "the file is not a debug object",
	.Version            = "the debug object has another version",
	.Too_Many           = "a table of the debug object has more records than a reader takes",
	.Size_Differs       = "the size of the debug object is not the size of its tables",
	.Reserved           = "a reserved field of the debug object is not zero",
	.Procedure_Order    = "a procedure does not start after the end of the one before it",
	.Procedure_Name     = "the name of a procedure is outside the strings, or has a byte that is not a visible character",
	.Procedure_Package  = "the package of a procedure is not followed by \"::\"",
	.File_Zero          = "the file 0 of the debug object is not all zero",
	.File_Path          = "the path of a file is outside the strings, has a byte that is not a visible character, or has a part \"..\"",
	.Line_Order         = "a row of the line table does not come after the row before it",
	.Line_File          = "a row of the line table names a file that the table does not have",
	.Line_End           = "the last row of the line table names a file",
}

// The tables of a debug object whose sizes agree with its header. A reader
// that has them reads each record with no fault; only check proves the
// order and the names.
Tables :: struct {
	header:     Header, // A copy of the header.
	procedures: []Procedure, // The procedure table, in the object.
	files:      []File, // The file table, in the object.
	lines:      []Line, // The line table, in the object.
	strings:    []u8, // The strings, in the object.
}

// tables gives the tables of an object, after a check of its header and of
// its size only: a constant time, for a reader that checked the whole
// object before.
tables :: proc "contextless" (object: []u8) -> (result: Tables, fault: Fault) {
	if len(object) < size_of(Header) {
		return {}, .Too_Small
	}
	header := intrinsics.unaligned_load((^Header)(raw_data(object)))
	if header.magic != MAGIC {
		return {}, .Not_A_Debug_Object
	}
	if header.version != VERSION {
		return {}, .Version
	}
	if header.procedure_count > PROCEDURE_CAPACITY || header.file_count > FILE_CAPACITY || header.line_count > LINE_CAPACITY || header.string_size > STRING_CAPACITY {
		return {}, .Too_Many
	}
	// No product overflows: each count is under its capacity.
	procedures_at := u64(size_of(Header))
	files_at := procedures_at + u64(header.procedure_count) * size_of(Procedure)
	lines_at := files_at + u64(header.file_count) * size_of(File)
	strings_at := lines_at + u64(header.line_count) * size_of(Line)
	end := strings_at + u64(header.string_size)
	if end != u64(len(object)) {
		return {}, .Size_Differs
	}
	if header.reserved != 0 {
		return {}, .Reserved
	}
	// Each table starts at a multiple of 4 bytes of the object, and the
	// fields of its records have 4 bytes at most: an object at the start
	// of a page of the debug image reads each field aligned.
	result.header = header
	result.procedures = ([^]Procedure)(rawptr(raw_data(object[procedures_at:])))[:header.procedure_count]
	result.files = ([^]File)(rawptr(raw_data(object[files_at:])))[:header.file_count]
	result.lines = ([^]Line)(rawptr(raw_data(object[lines_at:])))[:header.line_count]
	result.strings = object[strings_at:end]
	return result, .None
}

// text_of gives the bytes of a part of the strings, or "" when the part
// is not inside them.
text_of :: proc "contextless" (strings: []u8, offset: u32, count: u32) -> string {
	if u64(offset) + u64(count) > u64(len(strings)) {
		return ""
	}
	return string(strings[offset:][:count])
}

// name_bytes_valid says if each byte of a name or a path is a visible
// character of ASCII, 0x21 to 0x7E. A name and a path reach the log of the
// machine and the terminal of the host: a control byte (a carriage return,
// an escape sequence), the byte 0x7F, a byte of UTF-8 or a space would let
// a hostile debug object change or forge a line there, or split a frame of
// a stack trace in two. The real names of the build need more than letters,
// digits and "_" (a procedure of a generic type has its signature in its
// name: "module::record:proc\"contextless\"(file:[]u8,...)->(value:...)",
// "__$equal$$struct{...}", "sentence::[error.odin]::rights_text"), so the
// rule is the range of the visible characters, not a shorter list.
name_bytes_valid :: proc "contextless" (text: string) -> bool {
	for index in 0 ..< len(text) {
		if text[index] < 0x21 || text[index] > 0x7E {
			return false
		}
	}
	return true
}

// path_has_parent_part says if a path has the part "..": a path of a
// debug object stays under the root of the repository or of the compiler.
path_has_parent_part :: proc "contextless" (path: string) -> bool {
	start := 0
	for index in 0 ..= len(path) {
		if index == len(path) || path[index] == '/' {
			if index - start == 2 && path[start] == '.' && path[start + 1] == '.' {
				return true
			}
			start = index + 1
		}
	}
	return false
}

// check proves the whole form of a debug object: the header, the size, the
// order of the procedures and of the rows, each name and each path inside
// the strings, and each file of a row in the file table. Its cost is one
// pass over each table. A reader checks an object once, before its first
// lookup: the debug image is read-only memory.
check :: proc "contextless" (object: []u8) -> Fault {
	parts, fault := tables(object)
	if fault != .None {
		return fault
	}
	end_of_last := u64(0)
	for &procedure in parts.procedures {
		value := intrinsics.volatile_load(&procedure)
		if value.size == 0 || u64(value.start) < end_of_last {
			return .Procedure_Order
		}
		end_of_last = u64(value.start) + u64(value.size)
		name := text_of(parts.strings, value.name_offset, u32(value.name_count))
		if name == "" || !name_bytes_valid(name) {
			return .Procedure_Name
		}
		if value.package_count != 0 && (int(value.package_count) + 2 >= len(name) || name[value.package_count] != ':' || name[value.package_count + 1] != ':') {
			return .Procedure_Package
		}
	}
	if len(parts.files) == 0 || parts.files[0] != (File{}) {
		return .File_Zero
	}
	for &file in parts.files[1:] {
		value := intrinsics.volatile_load(&file)
		path := text_of(parts.strings, value.path_offset, value.path_count)
		if value.path_count == 0 || path == "" || !name_bytes_valid(path) || path_has_parent_part(path) {
			return .File_Path
		}
	}
	for &row, index in parts.lines {
		value := intrinsics.volatile_load(&row)
		if index > 0 && value.offset <= parts.lines[index - 1].offset {
			return .Line_Order
		}
		if u64(row_file(value)) >= u64(len(parts.files)) || (row_file(value) != 0) != (row_line(value) != 0) {
			return .Line_File
		}
	}
	if len(parts.lines) > 0 && row_file(parts.lines[len(parts.lines) - 1]) != 0 {
		return .Line_End
	}
	return .None
}

// What a debug object says of one offset of its module.
Place :: struct {
	procedure:           string, // The full name, "fault::three". "": no procedure holds the offset.
	package_count:       int, // The bytes of its package in `procedure`.
	offset_in_procedure: u64, // The offset less the start of the procedure.
	file:                string, // "": no source line.
	line:                u32, // The line, from 1. 0: no source line.
}

// place_of names an offset of the module: the procedure that holds it, and
// the source line of its instruction. The object must have passed check;
// with an object that did not, the reads stay inside the object and the
// answer can be wrong.
place_of :: proc "contextless" (object: []u8, offset: u64) -> (place: Place) {
	parts, fault := tables(object)
	if fault != .None {
		return {}
	}
	// The last procedure that starts at or before the offset.
	low, high := 0, len(parts.procedures)
	for low < high {
		middle := low + (high - low) / 2
		if u64(parts.procedures[middle].start) <= offset {
			low = middle + 1
		} else {
			high = middle
		}
	}
	if low > 0 {
		procedure := parts.procedures[low - 1]
		if offset - u64(procedure.start) < u64(procedure.size) {
			place.procedure = text_of(parts.strings, procedure.name_offset, u32(procedure.name_count))
			place.package_count = place.procedure == "" ? 0 : min(int(procedure.package_count), len(place.procedure))
			place.offset_in_procedure = offset - u64(procedure.start)
		}
	}
	// The last row at or before the offset.
	low, high = 0, len(parts.lines)
	for low < high {
		middle := low + (high - low) / 2
		if u64(parts.lines[middle].offset) <= offset {
			low = middle + 1
		} else {
			high = middle
		}
	}
	if low > 0 {
		row := parts.lines[low - 1]
		if row_file(row) != 0 && u64(row_file(row)) < u64(len(parts.files)) {
			file := parts.files[row_file(row)]
			place.file = text_of(parts.strings, file.path_offset, file.path_count)
			place.line = place.file == "" ? 0 : row_line(row)
		}
	}
	return place
}

// The parts of a debug object that encode receives. The names and the
// paths are offsets into `strings`.
Encode_Parts :: struct {
	module_hash: [32]u8, // The hash of the module file.
	procedures:  []Procedure, // By their start.
	files:       []File, // With the file 0, all zero.
	lines:       []Line, // By their offset; the last one with the file 0.
	strings:     []u8, // The names and the paths.
}

// encoded_size gives the bytes of the object of these parts.
encoded_size :: proc "contextless" (parts: Encode_Parts) -> u64 {
	return size_of(Header) + u64(len(parts.procedures)) * size_of(Procedure) + u64(len(parts.files)) * size_of(File) + u64(len(parts.lines)) * size_of(Line) + u64(len(parts.strings))
}

// encode writes the object of the parts into `into`, which has
// encoded_size bytes. It gives false when a count is over its capacity or
// `into` has another size; it does not check the order: the writer runs
// check on the result.
encode :: proc "contextless" (parts: Encode_Parts, into: []u8) -> bool {
	if len(parts.procedures) > PROCEDURE_CAPACITY || len(parts.files) > FILE_CAPACITY || len(parts.lines) > LINE_CAPACITY || len(parts.strings) > STRING_CAPACITY || u64(len(into)) != encoded_size(parts) {
		return false
	}
	header := Header {
		magic           = MAGIC,
		version         = VERSION,
		procedure_count = u32(len(parts.procedures)),
		module_hash     = parts.module_hash,
		file_count      = u32(len(parts.files)),
		line_count      = u32(len(parts.lines)),
		string_size     = u32(len(parts.strings)),
	}
	at := 0
	append_bytes :: proc "contextless" (destination: []u8, place: ^int, part: []u8) {
		if len(part) > 0 {
			intrinsics.mem_copy_non_overlapping(raw_data(destination[place^:]), raw_data(part), len(part))
		}
		place^ += len(part)
	}
	append_bytes(into, &at, ([^]u8)(rawptr(&header))[:size_of(Header)])
	append_bytes(into, &at, ([^]u8)(rawptr(raw_data(parts.procedures)))[:len(parts.procedures) * size_of(Procedure)])
	append_bytes(into, &at, ([^]u8)(rawptr(raw_data(parts.files)))[:len(parts.files) * size_of(File)])
	append_bytes(into, &at, ([^]u8)(rawptr(raw_data(parts.lines)))[:len(parts.lines) * size_of(Line)])
	append_bytes(into, &at, parts.strings)
	return true
}

// module_hash_of gives the hash of the module that an object describes,
// after the check of its header and its size.
module_hash_of :: proc "contextless" (object: []u8) -> (hash: [32]u8, valid: bool) {
	parts, fault := tables(object)
	return parts.header.module_hash, fault == .None
}
