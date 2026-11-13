// The debug object of a module (docs/MODULE_CONTRACT.md, "Debug
// information"): the names of the procedures of the module, the source
// lines of its code, its types, its global variables, and the parameters
// and the local variables of each procedure with their locations, as sorted
// tables of fixed records. A reader names an offset of the module
// "fault::three + 0x8 (programs/fault/main.odin:15)" with a binary search,
// and finds where a variable is and what its type is, with no allocator
// and no parser of DWARF.
//
// The kernel tool writes it at the build from the linked ELF file of the
// module: the procedure table from the symbol table, the line table from
// the line program of DWARF, the types and the variables from the entries
// of `.debug_info`. The system reads no DWARF: a parser of DWARF is a large
// parser of hostile input, and the tool runs it on its own output at the
// build.
//
// The debug object names its module by the hash of the module file. The
// module names nothing: its bytes are the same with and without its debug
// object, and with each format of the debug object. A reader uses a debug
// object only for the module whose file has that hash (`describes_module`).
//
// Each source file has the hash of its content at the build. A reader
// shows a line of a file only when the file that it holds has that hash
// (`source_line_of`).
//
// The file, all numbers little-endian:
//
//   Header                                          88 bytes
//   Procedure, header.procedure_count times         16 bytes each, by their start
//   File, header.file_count times                   40 bytes each; file 0 is "no file"
//   Line, header.line_count times                   8 bytes each, by their offset
//   Type, header.type_count times                   28 bytes each; type 0 is "no type"
//   Field, header.field_count times                 20 bytes each
//   Enumeration_Value, header.enumeration_value_count times  16 bytes each
//   Global, header.global_count times               16 bytes each, by their address
//   Variable, header.variable_count times           16 bytes each, by their procedure, then their name
//   Variable_Range, header.variable_range_count times  12 bytes each, by their variable, then their start
//   Strings                                         header.string_size bytes
//
// and no other byte. The reader refuses every other form (check).
//
// Who uses it: the kernel tool writes the debug objects (`encode`) into the
// debug image; the program `errors`, the console and the developer tools
// read them through `system.Debug_Names` to name the frames of a stop
// report (`check`, `place_of`). A debugger reads the variables
// (`variable_range_of_offset`, `variable_at`, `variable_by_name_at`,
// `global_by_name`) and
// the types (`type_by_index`, `field_of_type`).
//
// Example: the frame `0x0040_1234` of a stop report, in the module at
// 0x0040_0000, is the offset 0x1234; `place_of` gives `{procedure =
// "fault::three", offset_in_procedure = 8, file = "programs/fault/main.odin",
// line = 15}`, and `variable_by_name_at(object, 0x1234, "address")` gives
// the parameter `address`: a `uintptr` in the register 5 (`rdi`).
//
// See [debug object](term:debug-object) and [debug image](term:debug-image).
package debug_object

import "base:intrinsics"

MAGIC :: u64(0x4A424F4755424544) // The bytes "DEBUGOBJ".
VERSION :: 2 // The version of the format. A reader refuses another.

// The bounds of a reader. The console module of today has about 210
// procedures and 270 KiB of code.
PROCEDURE_CAPACITY :: 1 << 20
FILE_CAPACITY :: 1 << ROW_FILE_BITS // The files: what the file part of a row holds.
LINE_CAPACITY :: 1 << 24 // The rows of the line table.
STRING_CAPACITY :: 1 << 26 // The bytes of the strings: 64 MiB.
TYPE_CAPACITY :: 1 << 20 // The records of the type table, with the type 0.
FIELD_CAPACITY :: 1 << 22 // The records of the field table.
ENUMERATION_VALUE_CAPACITY :: 1 << 22 // The records of the enumeration value table.
GLOBAL_CAPACITY :: 1 << 20 // The records of the global table.
VARIABLE_CAPACITY :: 1 << 22 // The records of the variable table.
VARIABLE_RANGE_CAPACITY :: 1 << 24 // The records of the variable range table.
VARIABLE_RANGE_SIZE_LIMIT :: 0xFFFF // The bytes of one record of a range. A longer range is several records, one after the other.

// The first 88 bytes of a debug object.
Header :: struct {
	magic:                   u64, // MAGIC.
	version:                 u32, // VERSION.
	procedure_count:         u32, // The records of the procedure table.
	module_hash:             [32]u8, // The BLAKE3 hash of the module file that this object describes.
	file_count:              u32, // With the file 0.
	line_count:              u32, // The rows of the line table.
	string_size:             u32, // The bytes of the strings.
	type_count:              u32, // With the type 0.
	field_count:             u32, // The records of the field table.
	enumeration_value_count: u32, // The records of the enumeration value table.
	global_count:            u32, // The records of the global table.
	variable_count:          u32, // The records of the variable table.
	variable_range_count:    u32, // The records of the variable range table.
	reserved:                u32, // Zero.
}
#assert(size_of(Header) == 88)

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
//
// `content_hash` is the BLAKE3 hash of the bytes of the file when the tool
// built the module. A reader that shows a line of the file hashes the file
// that it holds first: another hash means another version of the source,
// and its line of that number is not the line of the code.
File :: struct {
	path_offset:  u32, // In the strings.
	path_count:   u32, // The bytes of the path.
	content_hash: [32]u8, // The BLAKE3 hash of the content of the file at the build. All zero: the tool did not hash the file.
}
#assert(size_of(File) == 40)

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

// What a type is.
Type_Kind :: enum u32 {
	None              = 0, // Only the type 0: "no type" (what `rawptr` points to, a procedure with no result).
	Signed_Integer    = 1, // `size` bytes, two's complement.
	Unsigned_Integer  = 2, // `size` bytes.
	Boolean           = 3, // `size` bytes: 0 is false.
	Float             = 4, // `size` bytes: 2, 4 or 8, IEEE 754.
	Pointer           = 5, // The address of a value of the type `element`; `element` 0: of any type.
	Array             = 6, // `count` values of the type `element`, one after the other.
	Slice             = 7, // An address and a count of values of the type `element`. Its two fields are in the field table.
	String            = 8, // An address and a count of bytes of text. Its two fields are in the field table.
	Record            = 9, // `count` fields from the field `first` of the field table, in the order of their offsets.
	Union             = 10, // As a record, and its fields share their bytes: one of them holds the value.
	Enumeration       = 11, // An integer of the type `element`, with `count` named values from the value `first` of the enumeration value table.
	Procedure_Address = 12, // The address of the code of a procedure.
	Other             = 13, // A type that the table does not describe: only its size and its name are true.
}

// One type that a variable, a field or another type uses. The type 0 is
// "no type", all zero.
//
// A type can name itself through a pointer (a list node). A reader that
// follows `element` or the types of the fields bounds its depth.
Type :: struct {
	name_offset: u32, // In the strings.
	name_count:  u32, // The bytes of the name. 0: the type has no name of its own (a pointer, an array).
	size:        u32, // The bytes of a value of the type.
	kind:        Type_Kind, // What the type is.
	element:     u32, // A type: what a pointer points to, the element of an array or a slice, the integer of an enumeration. 0 for each other kind.
	count:       u32, // An array: its elements. A record, a union, a slice, a string: its fields. An enumeration: its named values.
	first:       u32, // The first field in the field table, or the first value in the enumeration value table.
}
#assert(size_of(Type) == 28)

// One field of a record, a union, a slice or a string.
Field :: struct {
	name_offset: u32, // In the strings.
	name_count:  u32, // The bytes of the name.
	offset:      u32, // The bytes from the start of the value to the field.
	type:        u32, // In the type table.
	bit_shift:   u16, // With `bit_size` not 0: the field starts at this bit of the byte at `offset`, from the least bit.
	bit_size:    u16, // 0: the field is whole bytes, as its type says. Not 0: the field has this count of bits.
}
#assert(size_of(Field) == 20)

// One named value of an enumeration.
Enumeration_Value :: struct {
	name_offset: u32, // In the strings.
	name_count:  u32, // The bytes of the name.
	value_low:   u32, // The low 32 bits of the value.
	value_high:  u32, // The high 32 bits of the value: all ones for a negative value.
}
#assert(size_of(Enumeration_Value) == 16)

// One global variable of the module: a variable with one address for the
// whole run. A variable of a thread is not in the table.
Global :: struct {
	address:     u32, // The offset of its first byte in the memory of the module.
	type:        u32, // In the type table.
	name_offset: u32, // In the strings.
	name_count:  u32, // The bytes of the name, with its package: "errors::UNIT_NAMES".
}
#assert(size_of(Global) == 16)

// The registers of a variable location, by their order in `operation.Thread_Registers`:
// rax 0, rbx 1, rcx 2, rdx 3, rsi 4, rdi 5, rbp 6, rsp 7, r8 to r15 8 to
// 15, rip 16. A reader takes the register `n` as the n-th word of the
// register image of the thread.
REGISTER_COUNT :: 17
// The frame pointer: `rbp`. Each procedure that the compiler wrote keeps
// it: the word at its address is the frame pointer of the caller, and the
// word 8 bytes after is the return address.
FRAME_POINTER_REGISTER :: 6
STACK_POINTER_REGISTER :: 7 // `rsp`.
FRAME_CALLER_FRAME_POINTER_OFFSET :: 0 // From the frame pointer: the frame pointer of the caller.
FRAME_RETURN_ADDRESS_OFFSET :: 8 // From the frame pointer: the return address.

// Where the value of a variable is, in a range of instructions.
Location_Kind :: enum u8 {
	// The debug information gives no location that this table describes:
	// the compiler removed the variable, keeps only a known value, splits
	// it over several registers, or computes its address. A reader says "not
	// readable"; it never guesses.
	Not_Readable         = 0,
	Frame_Pointer_Offset    = 1, // In memory, at the frame pointer plus `offset`. `register` is FRAME_POINTER_REGISTER.
	Stack_Pointer_Offset = 2, // In memory, at the stack pointer plus `offset`. `register` is STACK_POINTER_REGISTER.
	Register             = 3, // In the register `register`: its low bytes are the value.
	Register_Offset      = 4, // In memory, at the value of the register `register` plus `offset`.
}

// What a variable of a procedure is.
Variable_Role :: enum u8 {
	Local     = 0, // A local variable.
	Parameter = 1, // A parameter.
}

// One variable of a procedure: a parameter or a local variable, with its
// ranges in the variable range table. The ranges of the variable `n` are
// the records from `first_range` up to the `first_range` of the variable
// `n + 1`, or up to the end of the table for the last variable. Each
// variable has one range at least.
//
// Two variables of one procedure with the same name, the same role and
// the same type are one record: a variable of a procedure that the
// compiler put inside another one, at each place where it did so, or two
// variables of two blocks. A variable of a procedure that the compiler put
// inside another one is a variable of the procedure that holds its
// instructions.
//
// The variables are in the order of their procedures, so the variables of
// one procedure are records in a row.
Variable :: struct {
	name_offset: u32, // In the strings.
	name_count:  u16, // The bytes of the name.
	role:        Variable_Role, // A parameter or a local variable.
	reserved:    u8, // Zero.
	type:        u32, // In the type table. 0: the debug information names no type.
	first_range: u32, // The first of its records in the variable range table.
}
#assert(size_of(Variable) == 16)

// One range of instructions of a variable, with the variable location in
// it. A variable that moves (a register, then the stack) has one record
// for each range.
//
// A variable is visible at an instruction that one of its ranges holds. A
// record of the kind Not_Readable says where the variable is visible; a
// record of another kind that holds the same instruction says where its
// value is there, and a reader takes that one. Of two readable records at
// one instruction, the shortest is the innermost.
//
// A variable location is true for the innermost frame when the next
// instruction of the thread is in the range. For a frame of a caller, the
// registers of a variable location are those of that frame: only the
// frame pointer is known there, from the walk of the frames.
Variable_Range :: struct {
	start:    u32, // The offset in the memory of the module of the first instruction of the range.
	offset:   i32, // The bytes to add to the register. 0 with Not_Readable and Register.
	size:     u16, // The bytes of the range, 1 at least, inside the procedure of the variable.
	location: Location_Kind, // The kind of the variable location.
	register: u8, // The register of the variable location. 0 with Not_Readable.
}
#assert(size_of(Variable_Range) == 12)

// Why a check refused a debug object.
Fault :: enum u32 {
	None               = 0, // The object is whole.
	Too_Small          = 1, // Shorter than its header.
	Not_A_Debug_Object = 2, // Another magic number.
	Version            = 3, // Another version.
	Too_Many           = 4, // A count over its capacity.
	Size_Differs       = 5, // The size of the file is not the size of its tables.
	Procedure_Order    = 6, // A procedure that does not start after the end of the one before it, or with no byte.
	Procedure_Name     = 7, // A name outside the strings, empty, or with a byte that is not a visible character (name_bytes_valid).
	Procedure_Package  = 8, // A package that is not followed by "::" in the name.
	File_Zero          = 9, // The file 0 is not all zero.
	File_Path          = 10, // A path outside the strings, empty, with a byte that is not a visible character, or with a part "..".
	Line_Order         = 11, // A row that does not come after the row before it.
	Line_File          = 12, // A row that names a file that the table does not have, or a line 0 with a file.
	Line_End           = 13, // The last row has a file.
	Type_Zero          = 14, // The type 0 is not all zero, or the table has no type 0.
	Type_Form          = 15, // A kind that the format does not have, a name outside the strings or with a byte that is not printable, an element that the table does not have, or fields or values outside their table.
	Field_Form         = 16, // A name outside the strings or with a byte that is not printable, or a type that the table does not have.
	Value_Name         = 17, // A name of an enumeration value outside the strings, or with a byte that is not printable.
	Global_Order       = 18, // A global with an address below the one before it.
	Global_Form        = 19, // A name outside the strings, empty or with a byte that is not printable, or a type that the table does not have.
	Variable_Order     = 20, // A variable with no range, with ranges outside their table, or with a range before the range before it.
	Variable_Range     = 21, // A range with no byte, in no procedure, in a procedure before the one of the variable before it, or outside the procedure of the first range of its variable.
	Variable_Form      = 22, // A name outside the strings, empty or with a byte that is not printable, a type that the table does not have, or a variable location that the format does not have.
	Reserved           = 23, // A field that must be zero is not.
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
	.Procedure_Order    = "a procedure does not start after the end of the one before it",
	.Procedure_Name     = "the name of a procedure is outside the strings, or has a byte that is not a visible character",
	.Procedure_Package  = "the package of a procedure is not followed by \"::\"",
	.File_Zero          = "the file 0 of the debug object is not all zero",
	.File_Path          = "the path of a file is outside the strings, has a byte that is not a visible character, or has a part \"..\"",
	.Line_Order         = "a row of the line table does not come after the row before it",
	.Line_File          = "a row of the line table names a file that the table does not have",
	.Line_End           = "the last row of the line table names a file",
	.Type_Zero          = "the type 0 of the debug object is not all zero",
	.Type_Form          = "a type has a kind that the format does not have, a name outside the strings, or an element, fields or values that the tables do not have",
	.Field_Form         = "a field has a name outside the strings, or a type that the table does not have",
	.Value_Name         = "the name of an enumeration value is outside the strings, or has a byte that is not printable",
	.Global_Order       = "a global variable has an address below the one before it",
	.Global_Form        = "a global variable has a name outside the strings, or a type that the table does not have",
	.Variable_Order     = "a variable has no range, or its ranges are not in their order",
	.Reserved           = "a reserved field of the debug object is not zero",
	.Variable_Range     = "the range of a variable is empty or outside its procedure",
	.Variable_Form      = "a variable has a name outside the strings, a type that the table does not have, or a variable location that the format does not have",
}

// The tables of a debug object whose sizes agree with its header. A reader
// that has them reads each record with no fault; only check proves the
// order and the names.
Tables :: struct {
	header:     Header, // A copy of the header.
	procedures: []Procedure, // The procedure table, in the object.
	files:      []File, // The file table, in the object.
	lines:      []Line, // The line table, in the object.
	types:      []Type, // The type table, in the object.
	fields:     []Field, // The field table, in the object.
	values:     []Enumeration_Value, // The enumeration value table, in the object.
	globals:    []Global, // The global table, in the object.
	variables:  []Variable, // The variable table, in the object.
	ranges:     []Variable_Range, // The variable range table, in the object.
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
	if header.type_count > TYPE_CAPACITY || header.field_count > FIELD_CAPACITY || header.enumeration_value_count > ENUMERATION_VALUE_CAPACITY || header.global_count > GLOBAL_CAPACITY || header.variable_count > VARIABLE_CAPACITY || header.variable_range_count > VARIABLE_RANGE_CAPACITY {
		return {}, .Too_Many
	}
	// No product overflows: each count is under its capacity.
	procedures_at := u64(size_of(Header))
	files_at := procedures_at + u64(header.procedure_count) * size_of(Procedure)
	lines_at := files_at + u64(header.file_count) * size_of(File)
	types_at := lines_at + u64(header.line_count) * size_of(Line)
	fields_at := types_at + u64(header.type_count) * size_of(Type)
	values_at := fields_at + u64(header.field_count) * size_of(Field)
	globals_at := values_at + u64(header.enumeration_value_count) * size_of(Enumeration_Value)
	variables_at := globals_at + u64(header.global_count) * size_of(Global)
	ranges_at := variables_at + u64(header.variable_count) * size_of(Variable)
	strings_at := ranges_at + u64(header.variable_range_count) * size_of(Variable_Range)
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
	result.types = ([^]Type)(rawptr(raw_data(object[types_at:])))[:header.type_count]
	result.fields = ([^]Field)(rawptr(raw_data(object[fields_at:])))[:header.field_count]
	result.values = ([^]Enumeration_Value)(rawptr(raw_data(object[values_at:])))[:header.enumeration_value_count]
	result.globals = ([^]Global)(rawptr(raw_data(object[globals_at:])))[:header.global_count]
	result.variables = ([^]Variable)(rawptr(raw_data(object[variables_at:])))[:header.variable_count]
	result.ranges = ([^]Variable_Range)(rawptr(raw_data(object[ranges_at:])))[:header.variable_range_count]
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

// text_bytes_printable says if each byte of a name of a type, a field, an
// enumeration value or a variable is a printable character of ASCII, 0x20
// to 0x7E. These names reach the terminal as the names of the procedures
// do, so no control byte and no byte of UTF-8; a space is allowed, because
// the compiler names a type "enum u8 {Info=0,Debug=1}".
text_bytes_printable :: proc "contextless" (text: string) -> bool {
	for index in 0 ..< len(text) {
		if text[index] < 0x20 || text[index] > 0x7E {
			return false
		}
	}
	return true
}

// text_is_inside says if a part of the strings is inside them. An empty
// part is inside.
text_is_inside :: proc "contextless" (strings: []u8, offset: u32, count: u32) -> bool {
	return u64(offset) + u64(count) <= u64(len(strings))
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
// order of the procedures, of the rows, of the globals and of the
// variables, each name and each path inside the strings, each file of a
// row in the file table, each type that a record names in the type table,
// and each range of a variable inside its procedure. Its cost is one pass
// over each table. A reader checks an object once, before its first
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
	return check_types_and_variables(parts)
}

// name_is_valid says if a name of the new tables is inside the strings and
// printable. `may_be_empty`: a name of no byte is valid.
@(private)
name_is_valid :: proc "contextless" (strings: []u8, offset: u32, count: u32, may_be_empty: bool) -> bool {
	if !text_is_inside(strings, offset, count) {
		return false
	}
	if count == 0 {
		return may_be_empty
	}
	return text_bytes_printable(string(strings[offset:][:count]))
}

// check_types_and_variables is the part of check for the type table, the
// field table, the enumeration value table, the global table and the
// variable table.
@(private)
check_types_and_variables :: proc "contextless" (parts: Tables) -> Fault {
	type_count := u64(len(parts.types))
	if type_count == 0 || parts.types[0] != (Type{}) {
		return .Type_Zero
	}
	for &type in parts.types[1:] {
		value := intrinsics.volatile_load(&type)
		if value.kind == .None || u32(value.kind) > u32(max(Type_Kind)) {
			return .Type_Form
		}
		if !name_is_valid(parts.strings, value.name_offset, value.name_count, true) || u64(value.element) >= type_count {
			return .Type_Form
		}
		#partial switch value.kind {
		case .Record, .Union, .Slice, .String:
			if u64(value.first) + u64(value.count) > u64(len(parts.fields)) {
				return .Type_Form
			}
		case .Enumeration:
			if u64(value.first) + u64(value.count) > u64(len(parts.values)) {
				return .Type_Form
			}
		}
	}
	for &field in parts.fields {
		value := intrinsics.volatile_load(&field)
		if !name_is_valid(parts.strings, value.name_offset, value.name_count, true) || u64(value.type) >= type_count {
			return .Field_Form
		}
	}
	for &named in parts.values {
		value := intrinsics.volatile_load(&named)
		if !name_is_valid(parts.strings, value.name_offset, value.name_count, true) {
			return .Value_Name
		}
	}
	address_of_last := u32(0)
	for &global in parts.globals {
		value := intrinsics.volatile_load(&global)
		if value.address < address_of_last {
			return .Global_Order
		}
		address_of_last = value.address
		if !name_is_valid(parts.strings, value.name_offset, value.name_count, false) || u64(value.type) >= type_count {
			return .Global_Form
		}
	}
	// The variables are in the order of their procedures: the procedure
	// of each variable is found from the one of the variable before it.
	range_count := u64(len(parts.ranges))
	if len(parts.variables) == 0 && range_count != 0 {
		return .Variable_Order
	}
	procedure_index := 0
	for &variable, index in parts.variables {
		value := intrinsics.volatile_load(&variable)
		ranges_end := index + 1 < len(parts.variables) ? u64(parts.variables[index + 1].first_range) : range_count
		if (index == 0 && value.first_range != 0) || ranges_end <= u64(value.first_range) || ranges_end > range_count {
			return .Variable_Order
		}
		if !name_is_valid(parts.strings, value.name_offset, u32(value.name_count), false) || u64(value.type) >= type_count {
			return .Variable_Form
		}
		if u8(value.role) > u8(max(Variable_Role)) || value.reserved != 0 {
			return .Variable_Form
		}
		start_of_last := u32(0)
		for number in u64(value.first_range) ..< ranges_end {
			part := intrinsics.volatile_load(&parts.ranges[number])
			if part.size == 0 {
				return .Variable_Range
			}
			if number == u64(value.first_range) {
				for procedure_index < len(parts.procedures) && u64(part.start) >= u64(parts.procedures[procedure_index].start) + u64(parts.procedures[procedure_index].size) {
					procedure_index += 1
				}
				if procedure_index >= len(parts.procedures) {
					return .Variable_Range
				}
			} else if part.start < start_of_last {
				return .Variable_Order
			}
			start_of_last = part.start
			procedure := parts.procedures[procedure_index]
			if part.start < procedure.start || u64(part.start) + u64(part.size) > u64(procedure.start) + u64(procedure.size) {
				return .Variable_Range
			}
			if u8(part.location) > u8(max(Location_Kind)) || part.register >= REGISTER_COUNT {
				return .Variable_Form
			}
			location_is_valid := true
			switch part.location {
			case .Not_Readable:
				location_is_valid = part.register == 0 && part.offset == 0
			case .Frame_Pointer_Offset:
				location_is_valid = part.register == FRAME_POINTER_REGISTER
			case .Stack_Pointer_Offset:
				location_is_valid = part.register == STACK_POINTER_REGISTER
			case .Register:
				location_is_valid = part.offset == 0
			case .Register_Offset:
			}
			if !location_is_valid {
				return .Variable_Form
			}
		}
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

// describes_module says if a debug object is the one of a module: the hash
// in its header is the hash of the module file. A debugger uses a debug
// object only for a loaded module with that hash: the tables of another
// build name other procedures and other variable locations, and a location that is wrong
// reads other memory.
describes_module :: proc "contextless" (object: []u8, module_hash: [32]u8) -> bool {
	hash, valid := module_hash_of(object)
	return valid && hash == module_hash
}

// The source line of an instruction, with what a reader needs to show the
// text of the line.
Source_Line :: struct {
	path:               string, // The path of the file from the root of the repository, or with the library of the compiler as a prefix.
	content_hash:       [32]u8, // The BLAKE3 hash of the content of the file at the build.
	content_hash_known: bool, // False: the hash is all zero, the tool did not hash the file.
	line:               u32, // The line, from 1.
}

// source_line_of gives the file and the line of the instruction at an
// offset of the module, with the hash of the content of the file at the
// build. `found` is false when the instruction has no source line.
//
// A reader that shows the text of the line hashes the file that it holds
// with BLAKE3 and compares: with another hash it shows the path and the
// line number only, and says that the source changed since the build.
source_line_of :: proc "contextless" (object: []u8, offset: u64) -> (source: Source_Line, found: bool) {
	parts, fault := tables(object)
	if fault != .None {
		return {}, false
	}
	low, high := 0, len(parts.lines)
	for low < high {
		middle := low + (high - low) / 2
		if u64(parts.lines[middle].offset) <= offset {
			low = middle + 1
		} else {
			high = middle
		}
	}
	if low == 0 {
		return {}, false
	}
	row := parts.lines[low - 1]
	if row_file(row) == 0 || u64(row_file(row)) >= u64(len(parts.files)) {
		return {}, false
	}
	file := parts.files[row_file(row)]
	source.path = text_of(parts.strings, file.path_offset, file.path_count)
	if source.path == "" {
		return {}, false
	}
	source.content_hash = file.content_hash
	source.content_hash_known = file.content_hash != ([32]u8{})
	source.line = row_line(row)
	return source, true
}

// A type, with its name as text.
Type_Description :: struct {
	index:   u32, // In the type table.
	name:    string, // "": the type has no name of its own.
	size:    u32, // The bytes of a value.
	kind:    Type_Kind, // What the type is.
	element: u32, // A type: see Type.element.
	count:   u32, // See Type.count.
}

// type_by_index gives a type of the type table. `found` is false for the
// type 0 and for an index that the table does not have.
type_by_index :: proc "contextless" (object: []u8, index: u32) -> (description: Type_Description, found: bool) {
	parts, fault := tables(object)
	if fault != .None || index == 0 || u64(index) >= u64(len(parts.types)) {
		return {}, false
	}
	type := parts.types[index]
	return {index = index, name = text_of(parts.strings, type.name_offset, type.name_count), size = type.size, kind = type.kind, element = type.element, count = type.count}, true
}

// A field of a type, with its name as text.
Field_Description :: struct {
	name:      string, // "": the field has no name.
	offset:    u32, // The bytes from the start of the value.
	type:      u32, // In the type table.
	bit_shift: u16, // See Field.bit_shift.
	bit_size:  u16, // See Field.bit_size.
}

// field_of_type gives the field `number` (from 0) of a record, a union, a
// slice or a string. `found` is false for another kind of type and past
// the last field.
field_of_type :: proc "contextless" (object: []u8, type_index: u32, number: u32) -> (description: Field_Description, found: bool) {
	parts, fault := tables(object)
	if fault != .None || type_index == 0 || u64(type_index) >= u64(len(parts.types)) {
		return {}, false
	}
	type := parts.types[type_index]
	if type.kind != .Record && type.kind != .Union && type.kind != .Slice && type.kind != .String {
		return {}, false
	}
	if number >= type.count || u64(type.first) + u64(number) >= u64(len(parts.fields)) {
		return {}, false
	}
	field := parts.fields[type.first + number]
	return {name = text_of(parts.strings, field.name_offset, field.name_count), offset = field.offset, type = field.type, bit_shift = field.bit_shift, bit_size = field.bit_size}, true
}

// field_by_name gives the field of a type with a name. Its cost is one
// pass over the fields of the type.
field_by_name :: proc "contextless" (object: []u8, type_index: u32, name: string) -> (description: Field_Description, found: bool) {
	for number in 0 ..< u32(FIELD_CAPACITY) {
		description, found = field_of_type(object, type_index, number)
		if !found || description.name == name {
			return
		}
	}
	return {}, false
}

// enumeration_value_of_type gives the named value `number` (from 0) of an
// enumeration: its name and its value, as the 64 bits of a two's
// complement integer. `found` is false for another kind of type and past
// the last value.
enumeration_value_of_type :: proc "contextless" (object: []u8, type_index: u32, number: u32) -> (name: string, value: u64, found: bool) {
	parts, fault := tables(object)
	if fault != .None || type_index == 0 || u64(type_index) >= u64(len(parts.types)) {
		return "", 0, false
	}
	type := parts.types[type_index]
	if type.kind != .Enumeration || number >= type.count || u64(type.first) + u64(number) >= u64(len(parts.values)) {
		return "", 0, false
	}
	named := parts.values[type.first + number]
	return text_of(parts.strings, named.name_offset, named.name_count), u64(named.value_high) << 32 | u64(named.value_low), true
}

// A global variable, with its name as text.
Global_Description :: struct {
	name:    string, // With its package: "errors::UNIT_NAMES".
	address: u64, // The offset of its first byte in the memory of the module: add the address where the module is mapped.
	type:    u32, // In the type table.
}

// global_count gives the count of the global variables of the object.
global_count :: proc "contextless" (object: []u8) -> u32 {
	parts, fault := tables(object)
	return fault == .None ? u32(len(parts.globals)) : 0
}

// global_by_index gives the global `index` of the table, which is in the
// order of the addresses.
global_by_index :: proc "contextless" (object: []u8, index: u32) -> (description: Global_Description, found: bool) {
	parts, fault := tables(object)
	if fault != .None || u64(index) >= u64(len(parts.globals)) {
		return {}, false
	}
	global := parts.globals[index]
	return {name = text_of(parts.strings, global.name_offset, global.name_count), address = u64(global.address), type = global.type}, true
}

// global_by_name gives the global variable with a name ("errors::UNIT_NAMES").
// The table is in the order of the addresses: the cost is one pass over
// it. Of two globals with one name, the one with the lowest address.
global_by_name :: proc "contextless" (object: []u8, name: string) -> (description: Global_Description, found: bool) {
	parts, fault := tables(object)
	if fault != .None || name == "" {
		return {}, false
	}
	for global in parts.globals {
		if text_of(parts.strings, global.name_offset, global.name_count) == name {
			return {name = name, address = u64(global.address), type = global.type}, true
		}
	}
	return {}, false
}

// A variable of a procedure at one instruction, with its name as text and
// its variable location there.
Variable_Description :: struct {
	name:     string, // The name of the variable in its procedure.
	role:     Variable_Role, // A parameter or a local variable.
	type:     u32, // In the type table. 0: no type.
	location: Location_Kind, // The kind of the variable location in the range.
	register: u32, // See Variable_Range.register.
	offset:   i32, // See Variable_Range.offset.
	start:    u64, // The offset in the memory of the module of the first instruction of the range.
	size:     u64, // The bytes of the range. 0: no range.
}

// procedure_index_of gives the index, in the procedure table, of the
// procedure that holds an offset of the module.
@(private)
procedure_index_of :: proc "contextless" (parts: Tables, offset: u64) -> (index: u32, found: bool) {
	low, high := 0, len(parts.procedures)
	for low < high {
		middle := low + (high - low) / 2
		if u64(parts.procedures[middle].start) <= offset {
			low = middle + 1
		} else {
			high = middle
		}
	}
	if low == 0 {
		return 0, false
	}
	procedure := parts.procedures[low - 1]
	if offset - u64(procedure.start) >= u64(procedure.size) {
		return 0, false
	}
	return u32(low - 1), true
}

// ranges_of_variable gives the records of the variable range table of one
// variable, or none when the table does not hold them.
@(private)
ranges_of_variable :: proc "contextless" (parts: Tables, index: u32) -> []Variable_Range {
	if u64(index) >= u64(len(parts.variables)) {
		return nil
	}
	first := u64(parts.variables[index].first_range)
	end := u64(index) + 1 < u64(len(parts.variables)) ? u64(parts.variables[index + 1].first_range) : u64(len(parts.ranges))
	if first >= end || end > u64(len(parts.ranges)) {
		return nil
	}
	return parts.ranges[first:end]
}

// start_of_variable gives the start of the first range of a variable: the
// variables are in the order of this number, by procedure.
@(private)
start_of_variable :: proc "contextless" (parts: Tables, index: int) -> u64 {
	first := u64(parts.variables[index].first_range)
	return first < u64(len(parts.ranges)) ? u64(parts.ranges[first].start) : max(u64)
}

// variable_range_of_offset gives the records of the variable table of the
// procedure that holds an offset of the module: `count` records from
// `first`. They are each parameter and each local variable of the
// procedure: a reader takes those that are visible at its instruction
// with variable_at. The cost is three binary searches.
variable_range_of_offset :: proc "contextless" (object: []u8, offset: u64) -> (first: u32, count: u32) {
	parts, fault := tables(object)
	if fault != .None {
		return 0, 0
	}
	procedure_index, found := procedure_index_of(parts, offset)
	if !found {
		return 0, 0
	}
	procedure := parts.procedures[procedure_index]
	// The first variable that starts in the procedure, then the first one
	// that starts after it.
	bounds: [2]int
	wanted := [2]u64{u64(procedure.start), u64(procedure.start) + u64(procedure.size)}
	for bound, which in wanted {
		low, high := 0, len(parts.variables)
		for low < high {
			middle := low + (high - low) / 2
			if start_of_variable(parts, middle) < bound {
				low = middle + 1
			} else {
				high = middle
			}
		}
		bounds[which] = low
	}
	// An object that did not pass check can have another order.
	if bounds[1] < bounds[0] {
		return 0, 0
	}
	return u32(bounds[0]), u32(bounds[1] - bounds[0])
}

// variable_at gives one variable of the variable table at an instruction
// of the module. `found`: the table has the variable; the name, the role
// and the type are its own. `visible`: one of its ranges holds the
// instruction; the variable location is the one of that range. Of two
// ranges that hold the instruction, a readable one comes before one that
// is not readable, then the shortest. The cost is one pass over the
// ranges of the variable.
variable_at :: proc "contextless" (object: []u8, index: u32, offset: u64) -> (description: Variable_Description, found: bool, visible: bool) {
	parts, fault := tables(object)
	if fault != .None || u64(index) >= u64(len(parts.variables)) {
		return {}, false, false
	}
	variable := parts.variables[index]
	description.name = text_of(parts.strings, variable.name_offset, u32(variable.name_count))
	description.role = variable.role
	description.type = variable.type
	for part in ranges_of_variable(parts, index) {
		if offset < u64(part.start) || offset - u64(part.start) >= u64(part.size) {
			continue
		}
		better := !visible
		if visible {
			part_readable := part.location != .Not_Readable
			chosen_readable := description.location != .Not_Readable
			better = part_readable != chosen_readable ? part_readable : u64(part.size) < description.size
		}
		if better {
			visible = true
			description.location = part.location
			description.register = u32(part.register)
			description.offset = part.offset
			description.start = u64(part.start)
			description.size = u64(part.size)
		}
	}
	return description, true, visible
}

// variable_range_count gives the count of the ranges of one variable.
variable_range_count :: proc "contextless" (object: []u8, index: u32) -> u32 {
	parts, fault := tables(object)
	return fault == .None ? u32(len(ranges_of_variable(parts, index))) : 0
}

// variable_range_by_index gives the range `number` (from 0) of one
// variable, with the name, the role and the type of the variable. The
// ranges of a variable are in the order of their starts.
variable_range_by_index :: proc "contextless" (object: []u8, index: u32, number: u32) -> (description: Variable_Description, found: bool) {
	parts, fault := tables(object)
	if fault != .None {
		return {}, false
	}
	ranges := ranges_of_variable(parts, index)
	if u64(number) >= u64(len(ranges)) {
		return {}, false
	}
	variable := parts.variables[index]
	part := ranges[number]
	return {
			name = text_of(parts.strings, variable.name_offset, u32(variable.name_count)),
			role = variable.role,
			type = variable.type,
			location = part.location,
			register = u32(part.register),
			offset = part.offset,
			start = u64(part.start),
			size = u64(part.size),
		},
		true
}

// variable_by_name_at gives the variable with a name that is visible at an
// offset of the module. Of two variables with the name there (another
// role or another type), one with a readable location comes before one
// that is not readable, then the one with the shortest range: the
// innermost. The cost is one pass over the variables of the procedure and
// their ranges.
variable_by_name_at :: proc "contextless" (object: []u8, offset: u64, name: string) -> (description: Variable_Description, found: bool) {
	first, count := variable_range_of_offset(object, offset)
	for index in first ..< first + count {
		candidate, valid, visible := variable_at(object, index, offset)
		if !valid || !visible || candidate.name != name {
			continue
		}
		better := !found
		if found {
			candidate_readable := candidate.location != .Not_Readable
			chosen_readable := description.location != .Not_Readable
			better = candidate_readable != chosen_readable ? candidate_readable : candidate.size < description.size
		}
		if better {
			description, found = candidate, true
		}
	}
	return
}

// The parts of a debug object that encode receives. The names and the
// paths are offsets into `strings`.
Encode_Parts :: struct {
	module_hash: [32]u8, // The hash of the module file.
	procedures:  []Procedure, // By their start.
	files:       []File, // With the file 0, all zero.
	lines:       []Line, // By their offset; the last one with the file 0.
	types:       []Type, // With the type 0, all zero.
	fields:      []Field, // The fields of each type, together.
	values:      []Enumeration_Value, // The values of each enumeration, together.
	globals:     []Global, // By their address.
	variables:   []Variable, // By their procedure, then their name.
	ranges:      []Variable_Range, // The ranges of each variable, together, by their start.
	strings:     []u8, // The names and the paths.
}

// encoded_size gives the bytes of the object of these parts.
encoded_size :: proc "contextless" (parts: Encode_Parts) -> u64 {
	size := u64(size_of(Header)) + u64(len(parts.procedures)) * size_of(Procedure) + u64(len(parts.files)) * size_of(File) + u64(len(parts.lines)) * size_of(Line)
	size += u64(len(parts.types)) * size_of(Type) + u64(len(parts.fields)) * size_of(Field) + u64(len(parts.values)) * size_of(Enumeration_Value)
	size += u64(len(parts.globals)) * size_of(Global) + u64(len(parts.variables)) * size_of(Variable) + u64(len(parts.ranges)) * size_of(Variable_Range)
	return size + u64(len(parts.strings))
}

// encode writes the object of the parts into `into`, which has
// encoded_size bytes. It gives false when a count is over its capacity or
// `into` has another size; it does not check the order: the writer runs
// check on the result.
encode :: proc "contextless" (parts: Encode_Parts, into: []u8) -> bool {
	if len(parts.procedures) > PROCEDURE_CAPACITY || len(parts.files) > FILE_CAPACITY || len(parts.lines) > LINE_CAPACITY || len(parts.strings) > STRING_CAPACITY || u64(len(into)) != encoded_size(parts) {
		return false
	}
	if len(parts.types) > TYPE_CAPACITY || len(parts.fields) > FIELD_CAPACITY || len(parts.values) > ENUMERATION_VALUE_CAPACITY || len(parts.globals) > GLOBAL_CAPACITY || len(parts.variables) > VARIABLE_CAPACITY || len(parts.ranges) > VARIABLE_RANGE_CAPACITY {
		return false
	}
	header := Header {
		magic                   = MAGIC,
		version                 = VERSION,
		procedure_count         = u32(len(parts.procedures)),
		module_hash             = parts.module_hash,
		file_count              = u32(len(parts.files)),
		line_count              = u32(len(parts.lines)),
		string_size             = u32(len(parts.strings)),
		type_count              = u32(len(parts.types)),
		field_count             = u32(len(parts.fields)),
		enumeration_value_count = u32(len(parts.values)),
		global_count            = u32(len(parts.globals)),
		variable_count          = u32(len(parts.variables)),
		variable_range_count    = u32(len(parts.ranges)),
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
	append_bytes(into, &at, ([^]u8)(rawptr(raw_data(parts.types)))[:len(parts.types) * size_of(Type)])
	append_bytes(into, &at, ([^]u8)(rawptr(raw_data(parts.fields)))[:len(parts.fields) * size_of(Field)])
	append_bytes(into, &at, ([^]u8)(rawptr(raw_data(parts.values)))[:len(parts.values) * size_of(Enumeration_Value)])
	append_bytes(into, &at, ([^]u8)(rawptr(raw_data(parts.globals)))[:len(parts.globals) * size_of(Global)])
	append_bytes(into, &at, ([^]u8)(rawptr(raw_data(parts.variables)))[:len(parts.variables) * size_of(Variable)])
	append_bytes(into, &at, ([^]u8)(rawptr(raw_data(parts.ranges)))[:len(parts.ranges) * size_of(Variable_Range)])
	append_bytes(into, &at, parts.strings)
	return true
}

// module_hash_of gives the hash of the module that an object describes,
// after the check of its header and its size.
module_hash_of :: proc "contextless" (object: []u8) -> (hash: [32]u8, valid: bool) {
	parts, fault := tables(object)
	return parts.header.module_hash, fault == .None
}
