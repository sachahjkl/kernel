#+build !freestanding
package debug_object

import "core:testing"

// The names of a sample object, as the tool writes them: one after the other.
@(private = "file")
Sample_Names :: struct {
	bytes: [dynamic]u8,
}

@(private = "file")
name_offset_of :: proc(names: ^Sample_Names, text: string) -> u32 {
	offset := u32(len(names.bytes))
	append(&names.bytes, ..transmute([]u8)text)
	return offset
}

// The object of a small module with each table: two procedures, one
// source file with a hash, seven types (an integer, a pointer, a record
// that names itself through the pointer, an array, an enumeration with a
// negative value, a string, and "no type"), two globals, and four
// variables in six ranges with each kind of variable location.
@(private = "file")
sample_parts :: proc() -> Encode_Parts {
	names := new(Sample_Names, context.temp_allocator)
	names.bytes = make([dynamic]u8, context.temp_allocator)
	named_type :: proc(pool: ^Sample_Names, text: string, size: u32, kind: Type_Kind, element: u32, count: u32, first: u32) -> Type {
		return {name_offset = name_offset_of(pool, text), name_count = u32(len(text)), size = size, kind = kind, element = element, count = count, first = first}
	}
	named_field :: proc(pool: ^Sample_Names, text: string, offset: u32, type: u32) -> Field {
		return {name_offset = name_offset_of(pool, text), name_count = u32(len(text)), offset = offset, type = type}
	}
	named_variable :: proc(pool: ^Sample_Names, text: string, role: Variable_Role, type: u32, first_range: u32) -> Variable {
		return {name_offset = name_offset_of(pool, text), name_count = u16(len(text)), role = role, type = type, first_range = first_range}
	}
	procedures := make([]Procedure, 2, context.temp_allocator)
	procedures[0] = {start = 0x1000, size = 0x40, name_offset = name_offset_of(names, "fault::three"), name_count = 12, package_count = 5}
	procedures[1] = {start = 0x1100, size = 0x20, name_offset = name_offset_of(names, "entry"), name_count = 5}
	files := make([]File, 2, context.temp_allocator)
	files[1] = {path_offset = name_offset_of(names, "programs/fault/main.odin"), path_count = 24, content_hash = {0 = 0x11, 31 = 0x22}}
	lines := make([]Line, 2, context.temp_allocator)
	lines[0] = {offset = 0x1000, place = row_place(1, 14)}
	lines[1] = {offset = 0x1120}
	types := make([]Type, 7, context.temp_allocator)
	types[1] = named_type(names, "u64", 8, .Unsigned_Integer, 0, 0, 0)
	types[2] = named_type(names, "", 8, .Pointer, 3, 0, 0)
	types[3] = named_type(names, "fault::Pair", 16, .Record, 0, 2, 0)
	types[4] = named_type(names, "", 32, .Array, 1, 4, 0)
	types[5] = named_type(names, "enum i64 {None=0,Last=-1}", 8, .Enumeration, 1, 2, 0)
	types[6] = named_type(names, "string", 16, .String, 0, 2, 2)
	fields := make([]Field, 4, context.temp_allocator)
	fields[0] = named_field(names, "first", 0, 1)
	fields[1] = named_field(names, "next", 8, 2)
	fields[2] = named_field(names, "data", 0, 2)
	fields[3] = named_field(names, "len", 8, 1)
	values := make([]Enumeration_Value, 2, context.temp_allocator)
	values[0] = {name_offset = name_offset_of(names, "None"), name_count = 4}
	values[1] = {name_offset = name_offset_of(names, "Last"), name_count = 4, value_low = 0xFFFF_FFFF, value_high = 0xFFFF_FFFF}
	globals := make([]Global, 2, context.temp_allocator)
	globals[0] = {address = 0x3000, type = 4, name_offset = name_offset_of(names, "fault::TABLE"), name_count = 12}
	globals[1] = {address = 0x3020, type = 3, name_offset = name_offset_of(names, "fault::PAIR"), name_count = 11}
	// By their procedure, then their name; the ranges of each one by their start.
	variables := make([]Variable, 4, context.temp_allocator)
	variables[0] = named_variable(names, "address", .Parameter, 1, 0)
	variables[1] = named_variable(names, "pair", .Local, 3, 2)
	variables[2] = named_variable(names, "count", .Local, 1, 4)
	variables[3] = named_variable(names, "cursor", .Local, 2, 5)
	ranges := make([]Variable_Range, 6, context.temp_allocator)
	ranges[0] = {start = 0x1000, size = 0x10, location = .Register, register = 5}
	ranges[1] = {start = 0x1010, size = 0x30, location = .Not_Readable}
	ranges[2] = {start = 0x1000, size = 0x40, location = .Frame_Pointer_Offset, register = FRAME_POINTER_REGISTER, offset = -16}
	ranges[3] = {start = 0x1020, size = 0x8, location = .Register, register = 1}
	ranges[4] = {start = 0x1100, size = 0x20, location = .Stack_Pointer_Offset, register = STACK_POINTER_REGISTER, offset = 8}
	ranges[5] = {start = 0x1104, size = 0x4, location = .Register_Offset, register = 0, offset = 24}
	return {module_hash = {0 = 0xAB, 31 = 0xCD}, procedures = procedures, files = files, lines = lines, types = types, fields = fields, values = values, globals = globals, variables = variables, ranges = ranges, strings = names.bytes[:]}
}

@(private = "file")
sample_with_variables :: proc() -> []u8 {
	parts := sample_parts()
	bytes := make([]u8, encoded_size(parts), context.temp_allocator)
	if !encode(parts, bytes) {
		return nil
	}
	return bytes
}

@(test)
a_variable_is_found_by_its_procedure_and_its_instruction :: proc(t: ^testing.T) {
	object := sample_with_variables()
	testing.expect_value(t, check(object), Fault.None)
	first, count := variable_range_of_offset(object, 0x1005)
	testing.expect(t, first == 0 && count == 2, "the first procedure has the variables 0 and 1")
	first, count = variable_range_of_offset(object, 0x111F)
	testing.expect(t, first == 2 && count == 2, "the second procedure has the variables 2 and 3")
	_, count = variable_range_of_offset(object, 0x1050)
	testing.expect_value(t, count, u32(0)) // Between the two procedures.
	_, count = variable_range_of_offset(object, 0x2000)
	testing.expect_value(t, count, u32(0))

	// A register, then not readable: one range for each.
	address, found := variable_by_name_at(object, 0x1005, "address")
	testing.expect(t, found && address.role == .Parameter && address.location == .Register && address.register == 5 && address.type == 1, "address is in the register 5 at 0x1005")
	address, found = variable_by_name_at(object, 0x1015, "address")
	testing.expect(t, found && address.location == .Not_Readable, "address is not readable at 0x1015")
	_, found = variable_by_name_at(object, 0x1100, "address")
	testing.expect(t, !found, "the other procedure has no variable address")

	// Two readable ranges of one variable at one instruction: the shortest.
	pair, found_pair := variable_by_name_at(object, 0x1024, "pair")
	testing.expect(t, found_pair && pair.location == .Register && pair.register == 1 && pair.size == 8, "the inner pair is in a register")
	pair, found_pair = variable_by_name_at(object, 0x1030, "pair")
	testing.expect(t, found_pair && pair.location == .Frame_Pointer_Offset && pair.register == FRAME_POINTER_REGISTER && pair.offset == -16, "the outer pair is at the frame pointer less 16")

	count_variable, found_count := variable_by_name_at(object, 0x1100, "count")
	testing.expect(t, found_count && count_variable.location == .Stack_Pointer_Offset && count_variable.register == STACK_POINTER_REGISTER && count_variable.offset == 8)
	cursor, found_cursor := variable_by_name_at(object, 0x1105, "cursor")
	testing.expect(t, found_cursor && cursor.location == .Register_Offset && cursor.register == 0 && cursor.offset == 24)
	_, found_cursor = variable_by_name_at(object, 0x1108, "cursor")
	testing.expect(t, !found_cursor, "cursor does not live after its range")
	// A variable that is not visible at an instruction keeps its name and its type.
	hidden, has_hidden, hidden_visible := variable_at(object, 3, 0x1108)
	testing.expect(t, has_hidden && !hidden_visible && hidden.name == "cursor" && hidden.type == 2 && hidden.size == 0)
	_, has_hidden, _ = variable_at(object, 4, 0x1108)
	testing.expect(t, !has_hidden, "the table has four variables")
	// The ranges of one variable, by their start.
	testing.expect_value(t, variable_range_count(object, 1), u32(2))
	testing.expect_value(t, variable_range_count(object, 4), u32(0))
	inner, has_inner := variable_range_by_index(object, 1, 1)
	testing.expect(t, has_inner && inner.name == "pair" && inner.location == .Register && inner.start == 0x1020 && inner.size == 8)
	_, has_inner = variable_range_by_index(object, 1, 2)
	testing.expect(t, !has_inner)
}

@(test)
a_type_gives_its_fields_and_its_values :: proc(t: ^testing.T) {
	object := sample_with_variables()
	_, none_found := type_by_index(object, 0)
	testing.expect(t, !none_found, "the type 0 is no type")
	_, past_found := type_by_index(object, 7)
	testing.expect(t, !past_found)
	record, found := type_by_index(object, 3)
	testing.expect(t, found && record.name == "fault::Pair" && record.kind == .Record && record.size == 16 && record.count == 2)
	next, has_next := field_of_type(object, 3, 1)
	testing.expect(t, has_next && next.name == "next" && next.offset == 8 && next.type == 2)
	// The record names itself through the pointer.
	pointer, has_pointer := type_by_index(object, next.type)
	testing.expect(t, has_pointer && pointer.kind == .Pointer && pointer.name == "" && pointer.element == 3)
	_, has_third := field_of_type(object, 3, 2)
	testing.expect(t, !has_third, "the record has two fields")
	by_name, has_by_name := field_by_name(object, 3, "first")
	testing.expect(t, has_by_name && by_name.offset == 0 && by_name.type == 1)
	_, has_by_name = field_by_name(object, 3, "absent")
	testing.expect(t, !has_by_name)
	_, has_field_of_integer := field_of_type(object, 1, 0)
	testing.expect(t, !has_field_of_integer, "an integer has no field")
	text_data, has_text_data := field_of_type(object, 6, 0)
	testing.expect(t, has_text_data && text_data.name == "data")
	array, has_array := type_by_index(object, 4)
	testing.expect(t, has_array && array.kind == .Array && array.count == 4 && array.element == 1 && array.size == 32)
	name, value, has_value := enumeration_value_of_type(object, 5, 1)
	testing.expect(t, has_value && name == "Last" && value == max(u64), "the value Last is -1")
	_, _, has_value = enumeration_value_of_type(object, 5, 2)
	testing.expect(t, !has_value)
	_, _, has_value = enumeration_value_of_type(object, 3, 0)
	testing.expect(t, !has_value, "a record has no named value")
}

@(test)
a_global_is_found_by_its_name :: proc(t: ^testing.T) {
	object := sample_with_variables()
	testing.expect_value(t, global_count(object), u32(2))
	pair, found := global_by_name(object, "fault::PAIR")
	testing.expect(t, found && pair.address == 0x3020 && pair.type == 3)
	_, found = global_by_name(object, "fault::ABSENT")
	testing.expect(t, !found)
	_, found = global_by_name(object, "")
	testing.expect(t, !found)
	first, has_first := global_by_index(object, 0)
	testing.expect(t, has_first && first.name == "fault::TABLE" && first.address == 0x3000)
	_, has_first = global_by_index(object, 2)
	testing.expect(t, !has_first)
}

@(test)
a_debug_object_is_of_one_module_and_names_the_hash_of_each_source_file :: proc(t: ^testing.T) {
	object := sample_with_variables()
	testing.expect(t, describes_module(object, [32]u8{0 = 0xAB, 31 = 0xCD}))
	testing.expect(t, !describes_module(object, [32]u8{0 = 0xAB, 31 = 0xCE}), "another module is not described")
	testing.expect(t, !describes_module(object[:len(object) - 1], [32]u8{0 = 0xAB, 31 = 0xCD}), "a cut object describes no module")
	source, found := source_line_of(object, 0x1008)
	testing.expect(t, found && source.path == "programs/fault/main.odin" && source.line == 14 && source.content_hash_known)
	testing.expect(t, source.content_hash == [32]u8{0 = 0x11, 31 = 0x22}, "the hash of the content of the file")
	_, found = source_line_of(object, 0x1120)
	testing.expect(t, !found, "no line after the code")
	_, found = source_line_of(object, 0x10)
	testing.expect(t, !found, "no line before the code")
	// A file with no hash says so.
	parts := sample_parts()
	parts.files[1].content_hash = {}
	without_hash := make([]u8, encoded_size(parts), context.temp_allocator)
	testing.expect(t, encode(parts, without_hash))
	source, found = source_line_of(without_hash, 0x1008)
	testing.expect(t, found && !source.content_hash_known)
}

@(test)
a_hostile_table_of_types_or_variables_is_refused :: proc(t: ^testing.T) {
	object := sample_with_variables()
	with_word :: proc(source: []u8, offset: int, value: u32) -> []u8 {
		copy_of := make([]u8, len(source), context.temp_allocator)
		copy(copy_of, source)
		(^u32)(rawptr(raw_data(copy_of[offset:])))^ = value
		return copy_of
	}
	with_byte :: proc(source: []u8, offset: int, value: u8) -> []u8 {
		copy_of := make([]u8, len(source), context.temp_allocator)
		copy(copy_of, source)
		copy_of[offset] = value
		return copy_of
	}
	types_at := size_of(Header) + 2 * size_of(Procedure) + 2 * size_of(File) + 2 * size_of(Line)
	fields_at := types_at + 7 * size_of(Type)
	values_at := fields_at + 4 * size_of(Field)
	globals_at := values_at + 2 * size_of(Enumeration_Value)
	variables_at := globals_at + 2 * size_of(Global)
	ranges_at := variables_at + 4 * size_of(Variable)
	strings_at := ranges_at + 6 * size_of(Variable_Range)
	// The name "u64" is after "fault::three", "entry" and the path.
	name_of_first_type_at := strings_at + 12 + 5 + 24
	cases := []struct {
		object: []u8,
		fault:  Fault,
	} {
		{with_word(object, types_at + 8, 1), .Type_Zero}, // The type 0 with a size.
		{with_word(object, types_at + size_of(Type) + 12, 99), .Type_Form}, // A kind that the format does not have.
		{with_word(object, types_at + size_of(Type) + 12, 0), .Type_Form}, // The kind of the type 0.
		{with_word(object, types_at + size_of(Type), 0x00FF_FFFF), .Type_Form}, // A name outside the strings.
		{with_byte(object, name_of_first_type_at, 0x1B), .Type_Form}, // An escape in a name.
		{with_word(object, types_at + 2 * size_of(Type) + 16, 7), .Type_Form}, // A pointer to a type that the table does not have.
		{with_word(object, types_at + 3 * size_of(Type) + 20, 5), .Type_Form}, // Five fields from the first of four.
		{with_word(object, types_at + 5 * size_of(Type) + 24, 1), .Type_Form}, // Two values from the second of two.
		{with_word(object, fields_at + 12, 7), .Field_Form}, // A field of a type that the table does not have.
		{with_word(object, fields_at + size_of(Field) + 4, 0x00FF_FFFF), .Field_Form},
		{with_word(object, values_at + 4, 0x00FF_FFFF), .Value_Name},
		{with_word(object, globals_at + size_of(Global), 0x2000), .Global_Order},
		{with_word(object, globals_at + 4, 7), .Global_Form},
		{with_word(object, globals_at + 12, 0), .Global_Form}, // A global with no name.
		{with_word(object, variables_at + 12, 1), .Variable_Order}, // The first variable does not start at the range 0.
		{with_word(object, variables_at + size_of(Variable) + 12, 0), .Variable_Order}, // A variable with no range.
		{with_word(object, variables_at + 3 * size_of(Variable) + 12, 7), .Variable_Order}, // Ranges that the table does not have.
		{with_word(object, variables_at, 0x00FF_FFFF), .Variable_Form}, // A name outside the strings.
		{with_word(object, variables_at + 8, 7), .Variable_Form}, // A type that the table does not have.
		{with_byte(object, variables_at + 6, 2), .Variable_Form}, // A role that the format does not have.
		{with_byte(object, variables_at + 7, 1), .Variable_Form}, // A reserved byte.
		{with_byte(object, ranges_at + 8, 0), .Variable_Range}, // No byte.
		{with_word(object, ranges_at, 0x0FFF), .Variable_Range}, // Before its procedure.
		{with_byte(object, ranges_at + size_of(Variable_Range) + 8, 0x31), .Variable_Range}, // Past the end of its procedure.
		{with_word(object, ranges_at + size_of(Variable_Range), 0x0FFF), .Variable_Order}, // Before the range before it.
		{with_word(object, ranges_at + 4 * size_of(Variable_Range), 0x1050), .Variable_Range}, // Between two procedures.
		{with_word(object, ranges_at + 5 * size_of(Variable_Range), 0x1004), .Variable_Range}, // In a procedure before the one of the variable before it.
		{with_word(object, ranges_at + 5 * size_of(Variable_Range), 0x2000), .Variable_Range}, // After each procedure.
		{with_byte(object, ranges_at + 10, 5), .Variable_Form}, // A kind of location that the format does not have.
		{with_byte(object, ranges_at + 11, REGISTER_COUNT), .Variable_Form}, // A register that the register image does not have.
		{with_word(object, ranges_at + 4, 4), .Variable_Form}, // A register with an offset.
		{with_byte(object, ranges_at + size_of(Variable_Range) + 11, 3), .Variable_Form}, // Not readable, with a register.
		{with_byte(object, ranges_at + 2 * size_of(Variable_Range) + 11, 5), .Variable_Form}, // The frame pointer in another register.
		{with_byte(object, ranges_at + 4 * size_of(Variable_Range) + 11, 6), .Variable_Form}, // The stack pointer in another register.
		{with_word(object, 76, VARIABLE_CAPACITY + 1), .Too_Many},
		{with_word(object, 80, VARIABLE_RANGE_CAPACITY + 1), .Too_Many},
		{with_word(object, 84, 1), .Reserved},
		{with_word(object, 72, 3), .Size_Differs}, // One more global than the bytes hold.
	}
	for item, index in cases {
		testing.expectf(t, check(item.object) == item.fault, "case %d: %v, not %v", index, check(item.object), item.fault)
		// A reader that did not check reads inside the object: no fault.
		for offset in ([]u64{0x1005, 0x1024, 0x1105}) {
			first, count := variable_range_of_offset(item.object, offset)
			for record in first ..< first + count {
				variable, _, _ := variable_at(item.object, record, offset)
				_, _ = type_by_index(item.object, variable.type)
				for number in 0 ..< variable_range_count(item.object, record) {
					_, _ = variable_range_by_index(item.object, record, number)
				}
			}
			_, _ = variable_by_name_at(item.object, offset, "pair")
		}
		for type_index in 0 ..< u32(9) {
			_, _ = field_of_type(item.object, type_index, 1)
			_, _ = field_by_name(item.object, type_index, "absent")
			_, _, _ = enumeration_value_of_type(item.object, type_index, 1)
		}
		_, _ = global_by_name(item.object, "fault::PAIR")
		_, _ = source_line_of(item.object, 0x1008)
	}
}
