#+build !freestanding
package debugging

import debug_object "contract:debug_object"
import "core:testing"
import "support:sentence"

// Memory that a test made by hand, in the place of the memory of a
// debugged program.
@(private = "file")
Fake_Memory :: struct {
	base:  u64,
	bytes: []u8,
}

@(private = "file")
fake_read :: proc "contextless" (state: rawptr, address: u64, into: []u8) -> bool {
	memory := (^Fake_Memory)(state)
	if address < memory.base || address - memory.base > u64(len(memory.bytes)) || u64(len(into)) > u64(len(memory.bytes)) - (address - memory.base) {
		return false
	}
	copy(into, memory.bytes[address - memory.base:][:len(into)])
	return true
}

@(private = "file")
fake_memory_make :: proc(base: u64, size: int) -> ^Fake_Memory {
	memory := new(Fake_Memory, context.temp_allocator)
	memory.base = base
	memory.bytes = make([]u8, size, context.temp_allocator)
	return memory
}

@(private = "file")
put :: proc(memory: ^Fake_Memory, address: u64, value: u64, size := 8) {
	for index in 0 ..< size {
		memory.bytes[address - memory.base + u64(index)] = u8(value >> uint(8 * index))
	}
}

@(private = "file")
reader_of :: proc(memory: ^Fake_Memory) -> Memory_Reader {
	return {read = fake_read, state = memory}
}

@(test)
a_path_is_a_name_then_steps :: proc(t: ^testing.T) {
	path, problem, _ := path_parse("pair.next^.first")
	testing.expect_value(t, problem, Path_Problem.None)
	testing.expect_value(t, path.name, "pair")
	testing.expect_value(t, path.step_count, 3)
	testing.expect(t, path.steps[0].kind == .Field && path.steps[0].name == "next")
	testing.expect(t, path.steps[1].kind == .Dereference)
	testing.expect(t, path.steps[2].kind == .Field && path.steps[2].name == "first")

	path, problem, _ = path_parse("table[3]")
	testing.expect(t, problem == .None && path.name == "table" && path.step_count == 1 && path.steps[0].kind == .Index && path.steps[0].index == 3)

	// A global has its package in its name; a field has none.
	path, problem, _ = path_parse("debug_target::shape.size.x")
	testing.expect(t, problem == .None && path.name == "debug_target::shape" && path.step_count == 2 && path.steps[1].name == "x")
	path, problem, _ = path_parse("_one")
	testing.expect(t, problem == .None && path.name == "_one" && path.step_count == 0)
}

@(test)
a_text_that_is_not_a_path_is_refused_with_its_byte :: proc(t: ^testing.T) {
	Case :: struct {
		text:    string,
		problem: Path_Problem,
		at:      int,
	}
	cases := []Case {
		{"", .Empty, 0},
		{"3x", .Bad_Name, 0},
		{".x", .Bad_Name, 0},
		{"a.", .Bad_Step, 1},
		{"a.3", .Bad_Step, 1},
		{"a b", .Bad_Step, 1},
		{"a[", .Bad_Index, 2},
		{"a[]", .Bad_Index, 2},
		{"a[1", .Bad_Index, 2},
		{"a[x]", .Bad_Index, 2},
		{"a[99999999999]", .Bad_Index, 2},
		{"a.b::c", .Bad_Step, 3},
		{"a^^^^^^^^^", .Too_Many_Steps, 9},
	}
	for item in cases {
		_, problem, at := path_parse(item.text)
		testing.expectf(t, problem == item.problem && at == item.at, "%q: the problem %v at %d, not %v at %d", item.text, problem, at, item.problem, item.at)
	}
}

@(test)
the_place_of_a_breakpoint_is_a_procedure_or_a_file_and_a_line :: proc(t: ^testing.T) {
	kind, name, line, ok := place_parse("fault::three")
	testing.expect(t, ok && kind == .Procedure && name == "fault::three" && line == 0)
	kind, name, line, ok = place_parse("programs/fault/main.odin:15")
	testing.expect(t, ok && kind == .Line && name == "programs/fault/main.odin" && line == 15)
	// A name that ends with a digit, after "::", is a procedure.
	kind, name, _, ok = place_parse("fault::three9")
	testing.expect(t, ok && kind == .Procedure && name == "fault::three9")
	kind, name, _, ok = place_parse("a::9")
	testing.expect(t, ok && kind == .Procedure && name == "a::9")
	_, _, _, ok = place_parse("")
	testing.expect(t, !ok, "an empty place")
	_, _, _, ok = place_parse("file.odin:0")
	testing.expect(t, !ok, "the line 0")
	_, _, _, ok = place_parse("file.odin:99999999")
	testing.expect(t, !ok, "a line that a row cannot hold")
}

@(test)
an_address_is_hexadecimal_or_decimal :: proc(t: ^testing.T) {
	address, ok := address_parse("0x403010")
	testing.expect(t, ok && address == 0x403010)
	address, ok = address_parse("0XFFFFFFFFFFFFFFFF")
	testing.expect(t, ok && address == max(u64))
	address, ok = address_parse("4096")
	testing.expect(t, ok && address == 4096)
	address, ok = address_parse("18446744073709551615")
	testing.expect(t, ok && address == max(u64))
	for text in ([]string{"", "0x", "0xZZ", "12a", "0x10000000000000000", "18446744073709551616", "debug_target::rounds", "-1"}) {
		_, ok = address_parse(text)
		testing.expectf(t, !ok, "%q is not an address", text)
	}
}

// A stack made by hand: three frames above the frame of the instruction.
@(private = "file")
stack_make :: proc() -> ^Fake_Memory {
	memory := fake_memory_make(0x7000, 0x100)
	put(memory, 0x7008, 0x40_1050) // At the first instruction of a procedure: its return address.
	put(memory, 0x7010, 0x7030)
	put(memory, 0x7018, 0x40_1100)
	put(memory, 0x7030, 0x7050)
	put(memory, 0x7038, 0x40_1200)
	put(memory, 0x7050, 0)
	put(memory, 0x7058, 0x40_1300)
	return memory
}

@(test)
the_frames_follow_the_frame_pointers :: proc(t: ^testing.T) {
	memory := stack_make()
	frames: [FRAME_CAPACITY]Frame
	count := frames_walk(reader_of(memory), 0x40_1000, 0x7010, 0x6FF0, .In_Body, frames[:])
	testing.expect_value(t, count, 4)
	testing.expect_value(t, frames[0], Frame{instruction = 0x40_1000, frame_pointer = 0x7010, return_address = 0x40_1100})
	testing.expect_value(t, frames[1], Frame{instruction = 0x40_1100, frame_pointer = 0x7030, return_address = 0x40_1200})
	testing.expect_value(t, frames[2], Frame{instruction = 0x40_1200, frame_pointer = 0x7050, return_address = 0x40_1300})
	// The last frame has the frame pointer 0: the walk ends there.
	testing.expect_value(t, frames[3], Frame{instruction = 0x40_1300})
	// The address that names a frame: the instruction, then the byte
	// before each return address.
	testing.expect_value(t, frame_lookup_address(frames[0], 0), u64(0x40_1000))
	testing.expect_value(t, frame_lookup_address(frames[1], 1), u64(0x40_10FF))
}

@(test)
at_the_start_of_a_procedure_the_return_address_is_at_the_stack_pointer :: proc(t: ^testing.T) {
	memory := stack_make()
	frames: [FRAME_CAPACITY]Frame
	// Before `push rbp`: the frame pointer is the one of the caller.
	count := frames_walk(reader_of(memory), 0x40_2000, 0x7010, 0x7008, .At_First_Instruction, frames[:])
	testing.expect_value(t, count, 5)
	testing.expect_value(t, frames[0], Frame{instruction = 0x40_2000, frame_pointer = 0x7010, return_address = 0x40_1050})
	testing.expect_value(t, frames[1], Frame{instruction = 0x40_1050, frame_pointer = 0x7010, return_address = 0x40_1100})
	testing.expect_value(t, frames[2].instruction, u64(0x40_1100))
	// After `push rbp`: the return address is one word higher.
	count = frames_walk(reader_of(memory), 0x40_2001, 0x7010, 0x7000, .After_Frame_Pointer_Push, frames[:])
	testing.expect_value(t, count, 5)
	testing.expect_value(t, frames[0].return_address, u64(0x40_1050))
	// A stack pointer that the program does not map: the one frame.
	count = frames_walk(reader_of(memory), 0x40_2000, 0x7010, 0x9000, .At_First_Instruction, frames[:])
	testing.expect_value(t, count, 1)
}

@(test)
the_walk_of_the_frames_ends :: proc(t: ^testing.T) {
	frames: [FRAME_CAPACITY]Frame
	// A frame pointer of 0, one that is not a multiple of 8, one that the
	// program does not map: the frame of the instruction only.
	for pointer in ([]u64{0, 0x7011, 0x9000, 0x70F8}) {
		count := frames_walk(reader_of(stack_make()), 0x40_1000, pointer, 0x6FF0, .In_Body, frames[:])
		testing.expectf(t, count == 1, "the frame pointer %x gives %d frames", pointer, count)
	}
	// A frame pointer that is not above the one before it: the return
	// address of the frame is read, and the walk ends.
	below := stack_make()
	put(below, 0x7030, 0x7020)
	count := frames_walk(reader_of(below), 0x40_1000, 0x7010, 0x6FF0, .In_Body, frames[:])
	testing.expect_value(t, count, 2)
	testing.expect_value(t, frames[1].return_address, u64(0x40_1200))
	// A frame pointer that names itself.
	loop := stack_make()
	put(loop, 0x7030, 0x7030)
	testing.expect_value(t, frames_walk(reader_of(loop), 0x40_1000, 0x7010, 0x6FF0, .In_Body, frames[:]), 2)
	// A return address 0.
	no_return := stack_make()
	put(no_return, 0x7018, 0)
	testing.expect_value(t, frames_walk(reader_of(no_return), 0x40_1000, 0x7010, 0x6FF0, .In_Body, frames[:]), 1)
	// The count of the frames that the caller has room for.
	testing.expect_value(t, frames_walk(reader_of(stack_make()), 0x40_1000, 0x7010, 0x6FF0, .In_Body, frames[:2]), 2)
	testing.expect_value(t, frames_walk(reader_of(stack_make()), 0x40_1000, 0x7010, 0x6FF0, .In_Body, nil), 0)
}

// The names of a debug object made by hand, one after the other.
@(private = "file")
Names :: struct {
	bytes: [dynamic]u8,
}

@(private = "file")
name_put :: proc(names: ^Names, text: string) -> u32 {
	offset := u32(len(names.bytes))
	append(&names.bytes, ..transmute([]u8)text)
	return offset
}

// The types of the object of the tests, by their index.
TYPE_U64 :: 1
TYPE_I32 :: 2
TYPE_BOOL :: 3
TYPE_F64 :: 4
TYPE_PAIR_POINTER :: 5
TYPE_PAIR :: 6
TYPE_ARRAY :: 7
TYPE_PHASE :: 8
TYPE_U8 :: 9
TYPE_STRING :: 10
TYPE_U8_POINTER :: 11
TYPE_INT :: 12
TYPE_SLICE :: 13
TYPE_U64_POINTER :: 14
TYPE_SHAPE :: 15
TYPE_PROCEDURE :: 16
TYPE_OTHER :: 17
TYPE_RAW_POINTER :: 18

// An object with each kind of type, two procedures, one source file and
// five rows of the line table.
@(private = "file")
object_make :: proc(t: ^testing.T) -> []u8 {
	names := new(Names, context.temp_allocator)
	names.bytes = make([dynamic]u8, context.temp_allocator)
	type :: proc(pool: ^Names, text: string, size: u32, kind: debug_object.Type_Kind, element: u32 = 0, count: u32 = 0, first: u32 = 0) -> debug_object.Type {
		return {name_offset = name_put(pool, text), name_count = u32(len(text)), size = size, kind = kind, element = element, count = count, first = first}
	}
	field :: proc(pool: ^Names, text: string, offset: u32, type_index: u32) -> debug_object.Field {
		return {name_offset = name_put(pool, text), name_count = u32(len(text)), offset = offset, type = type_index}
	}
	procedures := make([]debug_object.Procedure, 2, context.temp_allocator)
	procedures[0] = {start = 0x1000, size = 0x40, name_offset = name_put(names, "test::one"), name_count = 9, package_count = 4}
	procedures[1] = {start = 0x1100, size = 0x20, name_offset = name_put(names, "test::two"), name_count = 9, package_count = 4}
	files := make([]debug_object.File, 2, context.temp_allocator)
	files[1] = {path_offset = name_put(names, "programs/test/main.odin"), path_count = 23, content_hash = {0 = 1}}
	lines := make([]debug_object.Line, 5, context.temp_allocator)
	lines[0] = {offset = 0x1000, place = debug_object.row_place(1, 10)}
	lines[1] = {offset = 0x1010, place = debug_object.row_place(1, 11)}
	lines[2] = {offset = 0x1020, place = debug_object.row_place(1, 10)}
	lines[3] = {offset = 0x1100, place = debug_object.row_place(1, 20)}
	lines[4] = {offset = 0x1120}
	types := make([]debug_object.Type, 19, context.temp_allocator)
	types[TYPE_U64] = type(names, "u64", 8, .Unsigned_Integer)
	types[TYPE_I32] = type(names, "i32", 4, .Signed_Integer)
	types[TYPE_BOOL] = type(names, "bool", 1, .Boolean)
	types[TYPE_F64] = type(names, "f64", 8, .Float)
	types[TYPE_PAIR_POINTER] = type(names, "", 8, .Pointer, TYPE_PAIR)
	types[TYPE_PAIR] = type(names, "test::Pair", 16, .Record, 0, 2, 0)
	types[TYPE_ARRAY] = type(names, "", 32, .Array, TYPE_U64, 4)
	types[TYPE_PHASE] = type(names, "test::Phase", 1, .Enumeration, TYPE_U8, 2, 0)
	types[TYPE_U8] = type(names, "u8", 1, .Unsigned_Integer)
	types[TYPE_STRING] = type(names, "string", 16, .String, 0, 2, 2)
	types[TYPE_U8_POINTER] = type(names, "", 8, .Pointer, TYPE_U8)
	types[TYPE_INT] = type(names, "int", 8, .Signed_Integer)
	types[TYPE_SLICE] = type(names, "", 16, .Slice, TYPE_U64, 2, 4)
	types[TYPE_U64_POINTER] = type(names, "", 8, .Pointer, TYPE_U64)
	types[TYPE_SHAPE] = type(names, "test::Shape", 24, .Record, 0, 2, 6)
	types[TYPE_PROCEDURE] = type(names, "", 8, .Procedure_Address)
	types[TYPE_OTHER] = type(names, "odd", 3, .Other)
	types[TYPE_RAW_POINTER] = type(names, "", 8, .Pointer)
	fields := make([]debug_object.Field, 8, context.temp_allocator)
	fields[0] = field(names, "first", 0, TYPE_U64)
	fields[1] = field(names, "next", 8, TYPE_PAIR_POINTER)
	fields[2] = field(names, "data", 0, TYPE_U8_POINTER)
	fields[3] = field(names, "len", 8, TYPE_INT)
	fields[4] = field(names, "data", 0, TYPE_U64_POINTER)
	fields[5] = field(names, "len", 8, TYPE_INT)
	fields[6] = field(names, "pair", 0, TYPE_PAIR)
	fields[7] = field(names, "phase", 16, TYPE_PHASE)
	values := make([]debug_object.Enumeration_Value, 2, context.temp_allocator)
	values[0] = {name_offset = name_put(names, "Starting"), name_count = 8}
	values[1] = {name_offset = name_put(names, "Counting"), name_count = 8, value_low = 1}
	parts := debug_object.Encode_Parts {
		module_hash = {0 = 0xAB},
		procedures  = procedures,
		files       = files,
		lines       = lines,
		types       = types,
		fields      = fields,
		values      = values,
		strings     = names.bytes[:],
	}
	bytes := make([]u8, debug_object.encoded_size(parts), context.temp_allocator)
	testing.expect(t, debug_object.encode(parts, bytes), "the object of the tests is encoded")
	testing.expect_value(t, debug_object.check(bytes), debug_object.Fault.None)
	return bytes
}

// The memory of the values of the tests.
@(private = "file")
values_make :: proc() -> ^Fake_Memory {
	memory := fake_memory_make(0x1_0000, 0x200)
	put(memory, 0x1_0000, 7) // Pair A: first.
	put(memory, 0x1_0008, 0x1_0010) // Pair A: next, the address of Pair B.
	put(memory, 0x1_0010, 9) // Pair B: first; its next is 0.
	for index in 0 ..< u64(4) {
		put(memory, 0x1_0020 + index * 8, (index + 1) * 10) // The array.
	}
	put(memory, 0x1_0040, 0x1_0060) // The string: its address and its count.
	put(memory, 0x1_0048, 5)
	put(memory, 0x1_0050, 0x1_0020) // The slice: three elements of the array.
	put(memory, 0x1_0058, 3)
	copy(memory.bytes[0x60:], "hello")
	put(memory, 0x1_0070, 1) // The shape: its pair, then its phase.
	put(memory, 0x1_0080, 1, 1)
	put(memory, 0x1_0090, 0xFFFF_FFFB, 4) // An i32: -5.
	put(memory, 0x1_0094, 1, 1) // A boolean.
	put(memory, 0x1_0098, 0x3FF8_0000_0000_0000) // A float: 1.5.
	put(memory, 0x1_00A0, 7, 1) // A phase with no name.
	put(memory, 0x1_00A8, 0x40_1000) // The address of a procedure.
	return memory
}

@(private = "file")
at :: proc(type_index: u32, address: u64) -> Located {
	return {type = type_index, in_memory = true, address = address}
}

@(private = "file")
text_of :: proc(ctx: ^Value_Context, located: Located) -> string {
	writer := sentence.Writer{buffer = make([]u8, 256, context.temp_allocator)}
	value_write(&writer, ctx, located)
	return sentence.written(&writer)
}

@(private = "file")
name_the_second_pair :: proc "contextless" (state: rawptr, writer: ^sentence.Writer, address: u64) {
	if address == 0x1_0010 {
		sentence.write_part(writer, "test::second")
	}
}

@(test)
a_value_is_written_by_the_kind_of_its_type :: proc(t: ^testing.T) {
	ctx := Value_Context{object = object_make(t), reader = reader_of(values_make())}
	testing.expect_value(t, text_of(&ctx, at(TYPE_U64, 0x1_0000)), "7")
	testing.expect_value(t, text_of(&ctx, at(TYPE_I32, 0x1_0090)), "-5")
	testing.expect_value(t, text_of(&ctx, at(TYPE_BOOL, 0x1_0094)), "true")
	testing.expect_value(t, text_of(&ctx, at(TYPE_BOOL, 0x1_0095)), "false")
	testing.expect_value(t, text_of(&ctx, at(TYPE_F64, 0x1_0098)), "float bits 0x3ff8000000000000")
	testing.expect_value(t, text_of(&ctx, at(TYPE_PAIR_POINTER, 0x1_0008)), "0x0000000000010010")
	testing.expect_value(t, text_of(&ctx, at(TYPE_PAIR_POINTER, 0x1_0018)), "nil")
	testing.expect_value(t, text_of(&ctx, at(TYPE_PROCEDURE, 0x1_00A8)), "0x0000000000401000")
	testing.expect_value(t, text_of(&ctx, at(TYPE_PHASE, 0x1_0080)), "Counting")
	testing.expect_value(t, text_of(&ctx, at(TYPE_PHASE, 0x1_00A0)), "7 (no name)")
	testing.expect_value(t, text_of(&ctx, at(TYPE_PAIR, 0x1_0000)), "{first = 7, next = 0x0000000000010010}")
	testing.expect_value(t, text_of(&ctx, at(TYPE_SHAPE, 0x1_0070)), "{pair = {first = 1, next = nil}, phase = Counting}")
	testing.expect_value(t, text_of(&ctx, at(TYPE_ARRAY, 0x1_0020)), "[10, 20, 30, 40]")
	testing.expect_value(t, text_of(&ctx, at(TYPE_STRING, 0x1_0040)), "\"hello\"")
	testing.expect_value(t, text_of(&ctx, at(TYPE_SLICE, 0x1_0050)), "3 elements at 0x0000000000010020")
	testing.expect_value(t, text_of(&ctx, at(TYPE_OTHER, 0x1_0000)), "a value of 3 bytes")
	testing.expect_value(t, text_of(&ctx, at(0, 0x1_0000)), "no type")
	// Memory that the program does not map.
	testing.expect_value(t, text_of(&ctx, at(TYPE_U64, 0x9_0000)), "not readable")
	testing.expect_value(t, text_of(&ctx, at(TYPE_PAIR, 0x9_0000)), "{first = not readable, next = not readable}")
	// A value in a register: its low bytes.
	in_register := Located{type = TYPE_U64}
	in_register.bytes[0] = 42
	testing.expect_value(t, text_of(&ctx, in_register), "42")
	// A pointer with the name of what it points to.
	ctx.namer = {write = name_the_second_pair}
	testing.expect_value(t, text_of(&ctx, at(TYPE_PAIR_POINTER, 0x1_0008)), "0x0000000000010010 (test::second)")
	testing.expect_value(t, text_of(&ctx, at(TYPE_PROCEDURE, 0x1_00A8)), "0x0000000000401000")
}

@(test)
a_type_has_its_name_or_its_form :: proc(t: ^testing.T) {
	object := object_make(t)
	name_of :: proc(object: []u8, type_index: u32) -> string {
		writer := sentence.Writer{buffer = make([]u8, 64, context.temp_allocator)}
		type_name_write(&writer, object, type_index)
		return sentence.written(&writer)
	}
	testing.expect_value(t, name_of(object, TYPE_U64), "u64")
	testing.expect_value(t, name_of(object, TYPE_PAIR_POINTER), "^test::Pair")
	testing.expect_value(t, name_of(object, TYPE_ARRAY), "[4]u64")
	testing.expect_value(t, name_of(object, TYPE_SLICE), "[]u64")
	testing.expect_value(t, name_of(object, TYPE_RAW_POINTER), "rawptr")
	testing.expect_value(t, name_of(object, TYPE_PROCEDURE), "proc")
	testing.expect_value(t, name_of(object, 0), "no type")
}

@(test)
a_path_leads_from_a_value_to_one_of_its_parts :: proc(t: ^testing.T) {
	ctx := Value_Context{object = object_make(t), reader = reader_of(values_make())}
	resolve :: proc(ctx: ^Value_Context, start: Located, text: string) -> (Located, Resolve_Problem, int) {
		path, problem, _ := path_parse(text)
		if problem != .None {
			return {}, .Not_Readable, -1
		}
		return path_resolve(ctx, start, &path)
	}
	pair := at(TYPE_PAIR, 0x1_0000)
	located, problem, _ := resolve(&ctx, pair, "pair.next^.first")
	testing.expect(t, problem == .None && located.type == TYPE_U64 && located.address == 0x1_0010, "the field of the record that the pointer points to")
	// As in the language, the field of a pointer to a record.
	located, problem, _ = resolve(&ctx, pair, "pair.next.first")
	testing.expect(t, problem == .None && located.address == 0x1_0010)
	testing.expect_value(t, text_of(&ctx, located), "9")
	// A field of a record inside a record.
	located, problem, _ = resolve(&ctx, at(TYPE_SHAPE, 0x1_0070), "shape.pair.first")
	testing.expect(t, problem == .None && located.type == TYPE_U64 && located.address == 0x1_0070)
	located, problem, _ = resolve(&ctx, at(TYPE_SHAPE, 0x1_0070), "shape.phase")
	testing.expect(t, problem == .None && located.type == TYPE_PHASE && located.address == 0x1_0080)
	// An element of an array, and of a slice by a second read.
	located, problem, _ = resolve(&ctx, at(TYPE_ARRAY, 0x1_0020), "table[2]")
	testing.expect(t, problem == .None && located.address == 0x1_0030)
	testing.expect_value(t, text_of(&ctx, located), "30")
	located, problem, _ = resolve(&ctx, at(TYPE_SLICE, 0x1_0050), "slice[1]")
	testing.expect(t, problem == .None && located.type == TYPE_U64 && located.address == 0x1_0028)
	// The count of a string is a field.
	located, problem, _ = resolve(&ctx, at(TYPE_STRING, 0x1_0040), "text.len")
	testing.expect(t, problem == .None && located.address == 0x1_0048)

	step: int
	_, problem, step = resolve(&ctx, pair, "pair.missing")
	testing.expect(t, problem == .No_Field && step == 0)
	_, problem, step = resolve(&ctx, pair, "pair.first.x")
	testing.expect(t, problem == .Not_A_Record && step == 1)
	_, problem, _ = resolve(&ctx, pair, "pair.first^")
	testing.expect_value(t, problem, Resolve_Problem.Not_A_Pointer)
	_, problem, _ = resolve(&ctx, pair, "pair[0]")
	testing.expect_value(t, problem, Resolve_Problem.Not_Indexable)
	_, problem, _ = resolve(&ctx, at(TYPE_ARRAY, 0x1_0020), "table[4]")
	testing.expect_value(t, problem, Resolve_Problem.Index_Past_End)
	_, problem, _ = resolve(&ctx, at(TYPE_SLICE, 0x1_0050), "slice[3]")
	testing.expect_value(t, problem, Resolve_Problem.Index_Past_End)
	_, problem, step = resolve(&ctx, at(TYPE_PAIR, 0x1_0010), "second.next^.first")
	testing.expect(t, problem == .Nil_Pointer && step == 1)
	_, problem, _ = resolve(&ctx, at(TYPE_PAIR_POINTER, 0x9_0000), "pointer^")
	testing.expect_value(t, problem, Resolve_Problem.Not_Readable)
	_, problem, _ = resolve(&ctx, at(TYPE_RAW_POINTER, 0x1_0008), "raw^")
	testing.expect_value(t, problem, Resolve_Problem.Not_A_Pointer)
}

@(test)
a_value_gives_its_parts_one_by_one :: proc(t: ^testing.T) {
	ctx := Value_Context{object = object_make(t), reader = reader_of(values_make())}
	buffer: [16]u8
	// The fields of a record, by their names.
	part, name, found := value_part(&ctx, at(TYPE_PAIR, 0x1_0000), 0, buffer[:])
	testing.expect(t, found && name == "first" && part.type == TYPE_U64 && part.address == 0x1_0000)
	part, name, found = value_part(&ctx, at(TYPE_PAIR, 0x1_0000), 1, buffer[:])
	testing.expect(t, found && name == "next" && part.address == 0x1_0008)
	_, _, found = value_part(&ctx, at(TYPE_PAIR, 0x1_0000), 2, buffer[:])
	testing.expect(t, !found, "a record of two fields has no third part")
	// The elements of an array and of a slice, by their numbers.
	part, name, found = value_part(&ctx, at(TYPE_ARRAY, 0x1_0020), 3, buffer[:])
	testing.expect(t, found && name == "[3]" && part.address == 0x1_0038)
	_, _, found = value_part(&ctx, at(TYPE_ARRAY, 0x1_0020), 4, buffer[:])
	testing.expect(t, !found)
	part, name, found = value_part(&ctx, at(TYPE_SLICE, 0x1_0050), 2, buffer[:])
	testing.expect(t, found && name == "[2]" && part.address == 0x1_0030)
	_, _, found = value_part(&ctx, at(TYPE_SLICE, 0x1_0050), 3, buffer[:])
	testing.expect(t, !found)
	// A value with no part is its own one part, with no name.
	part, name, found = value_part(&ctx, at(TYPE_U64, 0x1_0000), 0, buffer[:])
	testing.expect(t, found && name == "" && part.address == 0x1_0000)
	_, _, found = value_part(&ctx, at(TYPE_U64, 0x1_0000), 1, buffer[:])
	testing.expect(t, !found)
	_, _, found = value_part(&ctx, at(TYPE_ARRAY, 0x1_0020), VALUE_PART_LIMIT, buffer[:])
	testing.expect(t, !found, "the bound of the parts")
}

@(test)
a_procedure_and_a_line_are_found_in_the_tables :: proc(t: ^testing.T) {
	object := object_make(t)
	offset, found := procedure_start_by_name(object, "test::two")
	testing.expect(t, found && offset == 0x1100)
	_, found = procedure_start_by_name(object, "test::three")
	testing.expect(t, !found)
	_, found = procedure_start_by_name(object, "")
	testing.expect(t, !found)
	// A line with two rows: the lowest instruction.
	offset, found = line_first_offset(object, "programs/test/main.odin", 10)
	testing.expect(t, found && offset == 0x1000)
	offset, found = line_first_offset(object, "programs/test/main.odin", 11)
	testing.expect(t, found && offset == 0x1010)
	offset, found = line_first_offset(object, "programs/test/main.odin", 20)
	testing.expect(t, found && offset == 0x1100)
	_, found = line_first_offset(object, "programs/test/main.odin", 12)
	testing.expect(t, !found, "a line with no instruction")
	_, found = line_first_offset(object, "programs/other/main.odin", 10)
	testing.expect(t, !found, "a file that the module does not have")
	_, found = line_first_offset(object, "programs/test/main.odin", 0)
	testing.expect(t, !found)
	_, found = line_first_offset(nil, "programs/test/main.odin", 10)
	testing.expect(t, !found, "no debug object")
}

@(test)
a_variable_is_located_by_the_registers_of_its_frame :: proc(t: ^testing.T) {
	innermost := Frame_Registers{innermost = true, frame_pointer = 0x7010}
	innermost.registers[debug_object.FRAME_POINTER_REGISTER] = 0x7010
	innermost.registers[debug_object.STACK_POINTER_REGISTER] = 0x6FF0
	innermost.registers[5] = 42
	innermost.registers[0] = 0x1_0000
	caller := Frame_Registers{frame_pointer = 0x7030}
	caller.registers = innermost.registers

	on_the_frame := debug_object.Variable_Description{type = TYPE_U64, location = .Frame_Pointer_Offset, register = debug_object.FRAME_POINTER_REGISTER, offset = -16}
	located, verdict := variable_locate(on_the_frame, innermost)
	testing.expect(t, verdict == .Readable && located.in_memory && located.address == 0x7000 && located.type == TYPE_U64)
	// In the frame of a caller, the frame pointer of that frame.
	located, verdict = variable_locate(on_the_frame, caller)
	testing.expect(t, verdict == .Readable && located.address == 0x7020)

	on_the_stack := debug_object.Variable_Description{location = .Stack_Pointer_Offset, register = debug_object.STACK_POINTER_REGISTER, offset = 8}
	located, verdict = variable_locate(on_the_stack, innermost)
	testing.expect(t, verdict == .Readable && located.address == 0x6FF8)
	_, verdict = variable_locate(on_the_stack, caller)
	testing.expect_value(t, verdict, Location_Verdict.Not_Readable_In_This_Frame)

	in_a_register := debug_object.Variable_Description{location = .Register, register = 5}
	located, verdict = variable_locate(in_a_register, innermost)
	testing.expect(t, verdict == .Readable && !located.in_memory && located.bytes[0] == 42)
	_, verdict = variable_locate(in_a_register, caller)
	testing.expect_value(t, verdict, Location_Verdict.Not_Readable_In_This_Frame)

	from_a_register := debug_object.Variable_Description{location = .Register_Offset, register = 0, offset = 24}
	located, verdict = variable_locate(from_a_register, innermost)
	testing.expect(t, verdict == .Readable && located.address == 0x1_0018)
	_, verdict = variable_locate(from_a_register, caller)
	testing.expect_value(t, verdict, Location_Verdict.Not_Readable_In_This_Frame)
	// From the frame pointer, by the general form: known in each frame.
	from_the_frame_pointer := debug_object.Variable_Description{location = .Register_Offset, register = debug_object.FRAME_POINTER_REGISTER, offset = 8}
	located, verdict = variable_locate(from_the_frame_pointer, caller)
	testing.expect(t, verdict == .Readable && located.address == 0x7038)

	_, verdict = variable_locate(debug_object.Variable_Description{location = .Not_Readable}, innermost)
	testing.expect_value(t, verdict, Location_Verdict.Not_Readable)
}
