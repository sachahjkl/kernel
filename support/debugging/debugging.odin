// The parts of a debugger that need no kernel operation: the path of a
// value, the walk of the frames of a stack, the place of a breakpoint, the
// location of a variable, and the text of a value by its type
// (docs/TOOLS.md, "The debugger").
//
// The debugger service (`programs/debugger`) compiles it in, and gives it
// the memory of the debugged program through a `Memory_Reader`. The host
// tests give it memory that they made by hand, so each rule is tested with
// no machine.
//
// The parts:
//
// - `path_parse`, `path_resolve` (this file, `values.odin`): a path such as
//   `pair.next^.first` or `table[3]`, from a variable or a global to one of
//   its parts.
// - `place_parse`, `procedure_start_by_name`, `line_first_offset`: where a
//   breakpoint goes, from a procedure name or from a file and a line.
// - `frames_walk` (`frames.odin`): the frames of a stack, from the frame
//   pointer.
// - `variable_locate`: where a variable is, from its variable location and
//   the registers of a frame.
// - `value_write`, `value_part` (`values.odin`): the text of a value by the
//   kind of its type, and its fields or its elements one by one.
//
// It reads a debug object only through `contract:debug_object`, and it
// computes no location that the tables do not give.
//
// See [debugger](term:debugger) and [debug object](term:debug-object).
package debugging

import debug_object "contract:debug_object"

// The memory of the debugged program, as its reader gives it. `read` fills
// `into` whole from `address` and gives true, or gives false and the bytes
// have no meaning: a page that the program does not map, or a range that is
// not whole.
Memory_Reader :: struct {
	read:  proc "contextless" (state: rawptr, address: u64, into: []u8) -> bool,
	state: rawptr, // What `read` receives: the reader of the service names its program here.
}

// memory_read reads bytes of the debugged program. False with no reader.
memory_read :: proc "contextless" (reader: Memory_Reader, address: u64, into: []u8) -> bool {
	if reader.read == nil {
		return false
	}
	if len(into) == 0 {
		return true
	}
	return reader.read(reader.state, address, into)
}

// memory_word reads one word of 8 bytes of the debugged program.
memory_word :: proc "contextless" (reader: Memory_Reader, address: u64) -> (word: u64, ok: bool) {
	bytes: [8]u8
	if !memory_read(reader, address, bytes[:]) {
		return 0, false
	}
	return integer_of_bytes(bytes[:]), true
}

// integer_of_bytes gives the number of at most 8 bytes, the low byte first.
integer_of_bytes :: proc "contextless" (bytes: []u8) -> (value: u64) {
	for index in 0 ..< min(len(bytes), 8) {
		value |= u64(bytes[index]) << uint(8 * index)
	}
	return value
}

// The steps of one path. A longer path is refused.
PATH_STEP_CAPACITY :: 8

// What one step of a path does to the value before it.
Step_Kind :: enum u8 {
	Field       = 0, // `.name`: the field of a record. Through a pointer to a record, the field of the record that it points to.
	Index       = 1, // `[number]`: the element of an array or of a slice, from 0.
	Dereference = 2, // `^`: the value that a pointer points to.
}

// One step of a path.
Step :: struct {
	kind:  Step_Kind,
	name:  string, // A Field: the name of the field, inside the text of the path.
	index: u64, // An Index: the number of the element.
}

// A path: the name of a variable or of a global, then its steps.
//
// The grammar:
//
//   path = name { step }
//   step = "." field | "[" number "]" | "^"
//   name = a letter or "_", then letters, digits, "_" and "::"
//   field = a letter or "_", then letters, digits and "_"
//   number = decimal digits
//
// `pair.next^.first`, `table[3]`, `debug_target::rounds`. The names are
// parts of the text that was parsed: the text must stay.
Path :: struct {
	name:       string, // The variable or the global. With "::" it is a global with its package.
	steps:      [PATH_STEP_CAPACITY]Step,
	step_count: int, // The steps in use.
}

// Why a text is not a path.
Path_Problem :: enum {
	None           = 0,
	Empty          = 1, // No byte.
	Bad_Name       = 2, // The text does not start with a name.
	Bad_Step       = 3, // A byte that starts no step, or a field with no name.
	Bad_Index      = 4, // An index that is not a decimal number below 2^32, or with no "]".
	Too_Many_Steps = 5, // More than PATH_STEP_CAPACITY steps.
}

@(private)
is_name_start :: proc "contextless" (b: u8) -> bool {
	return b >= 'a' && b <= 'z' || b >= 'A' && b <= 'Z' || b == '_'
}

@(private)
is_name_byte :: proc "contextless" (b: u8) -> bool {
	return is_name_start(b) || b >= '0' && b <= '9'
}

// name_end gives the place after the name that starts at `start`. With
// `with_package`, a "::" before a name byte is a part of the name.
@(private)
name_end :: proc "contextless" (text: string, start: int, with_package: bool) -> int {
	at := start
	for at < len(text) {
		if is_name_byte(text[at]) {
			at += 1
			continue
		}
		if with_package && text[at] == ':' && at + 2 < len(text) && text[at + 1] == ':' && is_name_byte(text[at + 2]) {
			at += 2
			continue
		}
		break
	}
	return at
}

// path_parse reads a path. `at` is the byte where a problem was found.
path_parse :: proc "contextless" (text: string) -> (path: Path, problem: Path_Problem, at: int) {
	if len(text) == 0 {
		return {}, .Empty, 0
	}
	if !is_name_start(text[0]) {
		return {}, .Bad_Name, 0
	}
	at = name_end(text, 0, true)
	path.name = text[:at]
	for at < len(text) {
		if path.step_count == PATH_STEP_CAPACITY {
			return {}, .Too_Many_Steps, at
		}
		step := &path.steps[path.step_count]
		switch text[at] {
		case '.':
			start := at + 1
			if start >= len(text) || !is_name_start(text[start]) {
				return {}, .Bad_Step, at
			}
			end := name_end(text, start, false)
			step^ = {kind = .Field, name = text[start:end]}
			at = end
		case '[':
			start := at + 1
			end := start
			value: u64
			for end < len(text) && text[end] >= '0' && text[end] <= '9' {
				value = value * 10 + u64(text[end] - '0')
				end += 1
				if value > u64(max(u32)) {
					return {}, .Bad_Index, start
				}
			}
			if end == start || end >= len(text) || text[end] != ']' {
				return {}, .Bad_Index, start
			}
			step^ = {kind = .Index, index = value}
			at = end + 1
		case '^':
			step^ = {kind = .Dereference}
			at += 1
		case:
			return {}, .Bad_Step, at
		}
		path.step_count += 1
	}
	return path, .None, 0
}

// What the place of a breakpoint names.
Place_Kind :: enum {
	Procedure = 0, // The name of a procedure: "fault::three".
	Line      = 1, // A source file and a line: "programs/fault/main.odin:15".
}

// place_parse reads the place of a breakpoint. A text that ends with ":"
// and decimal digits, after a path, is a file and a line; each other text
// is the name of a procedure. `ok` is false for an empty text, a line 0 and
// a line that a row of a line table cannot hold.
place_parse :: proc "contextless" (text: string) -> (kind: Place_Kind, name: string, line: u32, ok: bool) {
	if len(text) == 0 {
		return .Procedure, "", 0, false
	}
	digits_start := len(text)
	for digits_start > 0 && text[digits_start - 1] >= '0' && text[digits_start - 1] <= '9' {
		digits_start -= 1
	}
	// "file:15": a single ":" before the digits. "package::name9" ends with
	// a digit too, and has no ":" just before its digits.
	if digits_start < len(text) && digits_start >= 2 && text[digits_start - 1] == ':' && text[digits_start - 2] != ':' {
		value: u64
		for index in digits_start ..< len(text) {
			value = value * 10 + u64(text[index] - '0')
			if value >= u64(debug_object.ROW_LINE_LIMIT) {
				return .Line, "", 0, false
			}
		}
		if value == 0 {
			return .Line, "", 0, false
		}
		return .Line, text[:digits_start - 1], u32(value), true
	}
	return .Procedure, text, 0, true
}

// procedure_start_by_name gives the offset in the module of the first
// instruction of the procedure with a full name ("fault::three"). The cost
// is one pass over the procedure table.
procedure_start_by_name :: proc "contextless" (object: []u8, name: string) -> (offset: u64, found: bool) {
	parts, fault := debug_object.tables(object)
	if fault != .None || name == "" {
		return 0, false
	}
	for procedure in parts.procedures {
		if debug_object.text_of(parts.strings, procedure.name_offset, u32(procedure.name_count)) == name {
			return u64(procedure.start), true
		}
	}
	return 0, false
}

// line_first_offset gives the offset in the module of the first row of the
// line table with a file and a line: the lowest instruction of that line.
// The path is the path of the file table, from the root of the repository.
// The cost is one pass over the file table and one over the line table.
line_first_offset :: proc "contextless" (object: []u8, path: string, line: u32) -> (offset: u64, found: bool) {
	parts, fault := debug_object.tables(object)
	if fault != .None || path == "" || line == 0 {
		return 0, false
	}
	// Two records of the file table can have one path: each one is tried.
	for file, index in parts.files {
		if index == 0 || debug_object.text_of(parts.strings, file.path_offset, file.path_count) != path {
			continue
		}
		for row in parts.lines {
			if debug_object.row_file(row) == u32(index) && debug_object.row_line(row) == line {
				if !found || u64(row.offset) < offset {
					offset, found = u64(row.offset), true
				}
				break // The rows are in the order of their offsets.
			}
		}
	}
	return offset, found
}

// A value of the debugged program: its type, and where its bytes are.
Located :: struct {
	type:      u32, // In the type table. 0: no type.
	in_memory: bool, // True: the bytes are at `address`. False: they are `bytes`, the low bytes of a register.
	address:   u64, // In memory: the address of the first byte.
	bytes:     [8]u8, // Not in memory: the value, the low byte first.
	bit_shift: u16, // A field of bits: see debug_object.Field.bit_shift.
	bit_size:  u16, // 0: whole bytes.
}

// The registers of one frame of a stack, for the variable locations.
Frame_Registers :: struct {
	registers:     [debug_object.REGISTER_COUNT]u64, // The register image of the thread, in the order of debug_object.REGISTER_COUNT.
	innermost:     bool, // The frame 0: each register is the one of this frame. Else only the frame pointer is known.
	frame_pointer: u64, // The frame pointer of this frame, from the walk.
}

// Whether a variable can be read in a frame.
Location_Verdict :: enum {
	Readable                   = 0,
	Not_Readable               = 1, // The table gives no location at this instruction.
	Not_Readable_In_This_Frame = 2, // The location needs a register that is known only in the innermost frame.
}

// variable_locate gives where a variable is, from its variable location
// at the instruction of a frame and the registers of that frame. In the
// frame of a caller only the frame pointer is known: a location from
// another register is not readable there.
variable_locate :: proc "contextless" (variable: debug_object.Variable_Description, frame: Frame_Registers) -> (located: Located, verdict: Location_Verdict) {
	located.type = variable.type
	register_known := frame.innermost || variable.register == debug_object.FRAME_POINTER_REGISTER
	register_value: u64
	if variable.register < debug_object.REGISTER_COUNT {
		register_value = variable.register == debug_object.FRAME_POINTER_REGISTER ? frame.frame_pointer : frame.registers[variable.register]
	}
	// The offset is signed: the sum wraps as the processor adds.
	offset := u64(i64(variable.offset))
	switch variable.location {
	case .Not_Readable:
		return located, .Not_Readable
	case .Frame_Pointer_Offset:
		located.in_memory = true
		located.address = frame.frame_pointer + offset
		return located, .Readable
	case .Stack_Pointer_Offset:
		if !frame.innermost {
			return located, .Not_Readable_In_This_Frame
		}
		located.in_memory = true
		located.address = frame.registers[debug_object.STACK_POINTER_REGISTER] + offset
		return located, .Readable
	case .Register:
		if !register_known || variable.register >= debug_object.REGISTER_COUNT {
			return located, .Not_Readable_In_This_Frame
		}
		for index in 0 ..< 8 {
			located.bytes[index] = u8(register_value >> uint(8 * index))
		}
		return located, .Readable
	case .Register_Offset:
		if !register_known || variable.register >= debug_object.REGISTER_COUNT {
			return located, .Not_Readable_In_This_Frame
		}
		located.in_memory = true
		located.address = register_value + offset
		return located, .Readable
	}
	return located, .Not_Readable
}

// address_parse reads an address: "0x" and hexadecimal digits, or decimal
// digits. `ok` is false for an empty text, another byte, and a number that
// 64 bits do not hold.
address_parse :: proc "contextless" (text: string) -> (address: u64, ok: bool) {
	if len(text) > 2 && text[0] == '0' && (text[1] == 'x' || text[1] == 'X') {
		if len(text) > 18 {
			return 0, false
		}
		for index in 2 ..< len(text) {
			digit: u64
			switch b := text[index]; b {
			case '0' ..= '9':
				digit = u64(b - '0')
			case 'a' ..= 'f':
				digit = u64(b - 'a') + 10
			case 'A' ..= 'F':
				digit = u64(b - 'A') + 10
			case:
				return 0, false
			}
			address = address << 4 | digit
		}
		return address, true
	}
	if len(text) == 0 {
		return 0, false
	}
	for index in 0 ..< len(text) {
		if text[index] < '0' || text[index] > '9' {
			return 0, false
		}
		digit := u64(text[index] - '0')
		if address > (max(u64) - digit) / 10 {
			return 0, false
		}
		address = address * 10 + digit
	}
	return address, true
}
