package kerneltool

import debug_object "contract:debug_object"
import "core:strings"
import "core:testing"

// The writers of the hand-made sections of DWARF of these tests.
@(private = "file")
put_unsigned :: proc(bytes: ^[dynamic]u8, value: u64, size: int) {
	for index in 0 ..< size {
		append(bytes, u8(value >> uint(8 * index)))
	}
}

@(private = "file")
put_leb128 :: proc(bytes: ^[dynamic]u8, value: u64) {
	rest := value
	for {
		part := u8(rest & 0x7F)
		rest >>= 7
		if rest == 0 {
			append(bytes, part)
			return
		}
		append(bytes, part | 0x80)
	}
}

@(private = "file")
put_text :: proc(bytes: ^[dynamic]u8, text: string) {
	append(bytes, ..transmute([]u8)text)
	append(bytes, 0)
}

// One abbreviation: its code, its tag, if it has children, then pairs of
// an attribute and a form.
@(private = "file")
put_abbreviation :: proc(bytes: ^[dynamic]u8, code: u64, tag: u64, has_children: bool, pairs: []u64) {
	put_leb128(bytes, code)
	put_leb128(bytes, tag)
	append(bytes, has_children ? u8(1) : u8(0))
	for value in pairs {
		put_leb128(bytes, value)
	}
	append(bytes, 0, 0)
}

// The header of a unit of the version 4 before its entries: 11 bytes.
@(private = "file")
UNIT_HEADER_SIZE :: 11

// unit_of gives a whole unit of .debug_info around its entries.
@(private = "file")
unit_of :: proc(entries: []u8, version: u64 = 4, address_size: u64 = 8, abbreviation_offset: u64 = 0) -> []u8 {
	bytes := make([dynamic]u8, context.temp_allocator)
	put_unsigned(&bytes, u64(len(entries)) + 7, 4)
	put_unsigned(&bytes, version, 2)
	put_unsigned(&bytes, abbreviation_offset, 4)
	put_unsigned(&bytes, address_size, 1)
	append(&bytes, ..entries)
	return bytes[:]
}

// The forms of the abbreviations of the sample.
@(private = "file")
FORM_ADDRESS :: 0x01
@(private = "file")
FORM_REFERENCE4 :: 0x13
@(private = "file")
FORM_SECTION_OFFSET :: 0x17
@(private = "file")
FORM_EXPRESSION :: 0x18
@(private = "file")
FORM_SIGNED :: 0x0D

@(private = "file")
sample_abbreviations :: proc() -> []u8 {
	bytes := make([dynamic]u8, context.temp_allocator)
	put_abbreviation(&bytes, 1, DW_TAG_COMPILE_UNIT, true, {DW_AT_NAME, DW_FORM_STRP, DW_AT_LOW_PC, FORM_ADDRESS})
	put_abbreviation(&bytes, 2, DW_TAG_BASE_TYPE, false, {DW_AT_NAME, DW_FORM_STRING, DW_AT_ENCODING, DW_FORM_DATA1, DW_AT_BYTE_SIZE, DW_FORM_DATA1})
	put_abbreviation(&bytes, 3, DW_TAG_POINTER_TYPE, false, {DW_AT_TYPE, FORM_REFERENCE4})
	put_abbreviation(&bytes, 4, DW_TAG_STRUCTURE_TYPE, true, {DW_AT_NAME, DW_FORM_STRING, DW_AT_BYTE_SIZE, DW_FORM_DATA1})
	put_abbreviation(&bytes, 5, DW_TAG_MEMBER, false, {DW_AT_NAME, DW_FORM_STRING, DW_AT_TYPE, FORM_REFERENCE4, DW_AT_DATA_MEMBER_LOCATION, DW_FORM_DATA1})
	put_abbreviation(&bytes, 6, DW_TAG_VARIABLE, false, {DW_AT_NAME, DW_FORM_STRING, DW_AT_TYPE, FORM_REFERENCE4, DW_AT_LOCATION, FORM_EXPRESSION})
	put_abbreviation(&bytes, 7, DW_TAG_SUBPROGRAM, true, {DW_AT_LOW_PC, FORM_ADDRESS, DW_AT_HIGH_PC, DW_FORM_DATA4, DW_AT_FRAME_BASE, FORM_EXPRESSION})
	put_abbreviation(&bytes, 8, DW_TAG_FORMAL_PARAMETER, false, {DW_AT_NAME, DW_FORM_STRING, DW_AT_TYPE, FORM_REFERENCE4, DW_AT_LOCATION, FORM_SECTION_OFFSET})
	put_abbreviation(&bytes, 9, DW_TAG_ARRAY_TYPE, true, {DW_AT_TYPE, FORM_REFERENCE4})
	put_abbreviation(&bytes, 10, DW_TAG_SUBRANGE_TYPE, false, {DW_AT_COUNT, DW_FORM_DATA2})
	put_abbreviation(&bytes, 11, DW_TAG_ENUMERATION_TYPE, true, {DW_AT_NAME, DW_FORM_STRING, DW_AT_TYPE, FORM_REFERENCE4, DW_AT_BYTE_SIZE, DW_FORM_DATA1})
	put_abbreviation(&bytes, 12, DW_TAG_ENUMERATOR, false, {DW_AT_NAME, DW_FORM_STRING, DW_AT_CONST_VALUE, FORM_SIGNED})
	put_abbreviation(&bytes, 13, DW_TAG_TYPEDEF, false, {DW_AT_NAME, DW_FORM_STRING, DW_AT_TYPE, FORM_REFERENCE4})
	put_abbreviation(&bytes, 14, DW_TAG_LEXICAL_BLOCK, true, {DW_AT_RANGES, FORM_SECTION_OFFSET})
	put_abbreviation(&bytes, 15, DW_TAG_VARIABLE, false, {DW_AT_NAME, DW_FORM_STRING, DW_AT_TYPE, FORM_REFERENCE4})
	put_abbreviation(&bytes, 16, DW_TAG_VARIABLE, false, {DW_AT_ABSTRACT_ORIGIN, FORM_REFERENCE4, DW_AT_LOCATION, FORM_EXPRESSION})
	put_abbreviation(&bytes, 17, DW_TAG_MEMBER, false, {DW_AT_NAME, DW_FORM_STRING, DW_AT_TYPE, FORM_REFERENCE4, DW_AT_BIT_SIZE, DW_FORM_DATA1, DW_AT_DATA_BIT_OFFSET, DW_FORM_UDATA})
	put_abbreviation(&bytes, 18, DW_TAG_SUBPROGRAM, true, {DW_AT_NAME, DW_FORM_STRING})
	put_abbreviation(&bytes, 19, DW_TAG_INLINED_SUBROUTINE, true, {DW_AT_ABSTRACT_ORIGIN, FORM_REFERENCE4, DW_AT_LOW_PC, FORM_ADDRESS, DW_AT_HIGH_PC, DW_FORM_DATA4})
	append(&bytes, 0)
	return bytes[:]
}

// The sections of a small linked file:
//
//   u64, i32, a pointer to fault::Node, fault::Node (value, next, a field
//   of one bit), an array of 4 u64, fault::Kind (None = 0, Last = -1),
//   fault::Count (another name of u64), the global fault::TABLE at 0x3000,
//   the global fault::GONE that the link dropped, the procedure
//   fault::inner that the compiler put inside the other one, with its
//   variable step, and the procedure at 0x1000 to 0x1040 with the
//   parameter address (a location list), the variable node (the frame
//   base less 16), a block of two ranges with kind (a register) and gone
//   (no place), and the instance of fault::inner at 0x1020 to 0x1028.
@(private = "file")
Sample_Sections :: struct {
	units:         []u8,
	abbreviations: []u8,
	debug_strings: []u8,
	locations:     []u8,
	ranges:        []u8,
	sections:      []Elf_Section_Header,
}

@(private = "file")
sample_sections :: proc() -> Sample_Sections {
	entries := make([dynamic]u8, context.temp_allocator)
	offset_of_next :: proc(bytes: ^[dynamic]u8) -> u64 {
		return u64(len(bytes)) + UNIT_HEADER_SIZE
	}
	// The compile unit: its name in .debug_str, and the base address 0.
	put_leb128(&entries, 1)
	put_unsigned(&entries, 0, 4)
	put_unsigned(&entries, 0, 8)
	unsigned_type := offset_of_next(&entries)
	put_leb128(&entries, 2)
	put_text(&entries, "u64")
	append(&entries, DW_ATE_UNSIGNED, 8)
	signed_type := offset_of_next(&entries)
	put_leb128(&entries, 2)
	put_text(&entries, "i32")
	append(&entries, DW_ATE_SIGNED, 4)
	// The pointer names the record after it: its reference is written
	// when the offset of the record is known.
	pointer_type := offset_of_next(&entries)
	put_leb128(&entries, 3)
	pointer_reference_at := len(entries)
	put_unsigned(&entries, 0, 4)
	record_type := offset_of_next(&entries)
	for index in 0 ..< 4 {
		entries[pointer_reference_at + index] = u8(record_type >> uint(8 * index))
	}
	put_leb128(&entries, 4)
	put_text(&entries, "fault::Node")
	append(&entries, 24)
	put_leb128(&entries, 5)
	put_text(&entries, "value")
	put_unsigned(&entries, unsigned_type, 4)
	append(&entries, 0)
	put_leb128(&entries, 5)
	put_text(&entries, "next")
	put_unsigned(&entries, pointer_type, 4)
	append(&entries, 8)
	put_leb128(&entries, 17)
	put_text(&entries, "flag")
	put_unsigned(&entries, unsigned_type, 4)
	append(&entries, 1)
	put_leb128(&entries, 131) // The bit 3 of the byte 16.
	append(&entries, 0)
	array_type := offset_of_next(&entries)
	put_leb128(&entries, 9)
	put_unsigned(&entries, unsigned_type, 4)
	put_leb128(&entries, 10)
	put_unsigned(&entries, 4, 2)
	append(&entries, 0)
	enumeration_type := offset_of_next(&entries)
	put_leb128(&entries, 11)
	put_text(&entries, "fault::Kind")
	put_unsigned(&entries, signed_type, 4)
	append(&entries, 4)
	put_leb128(&entries, 12)
	put_text(&entries, "None")
	append(&entries, 0)
	put_leb128(&entries, 12)
	put_text(&entries, "Last")
	append(&entries, 0x7F) // -1.
	append(&entries, 0)
	alias_type := offset_of_next(&entries)
	put_leb128(&entries, 13)
	put_text(&entries, "fault::Count")
	put_unsigned(&entries, unsigned_type, 4)
	put_leb128(&entries, 6)
	put_text(&entries, "fault::TABLE")
	put_unsigned(&entries, array_type, 4)
	append(&entries, 9, DW_OP_ADDR)
	put_unsigned(&entries, 0x3000, 8)
	put_leb128(&entries, 6)
	put_text(&entries, "fault::GONE")
	put_unsigned(&entries, unsigned_type, 4)
	append(&entries, 9, DW_OP_ADDR)
	put_unsigned(&entries, 0, 8)
	abstract_procedure := offset_of_next(&entries)
	put_leb128(&entries, 18)
	put_text(&entries, "fault::inner")
	abstract_variable := offset_of_next(&entries)
	put_leb128(&entries, 15)
	put_text(&entries, "step")
	put_unsigned(&entries, alias_type, 4)
	append(&entries, 0)
	// The procedure, with rbp as its frame base.
	put_leb128(&entries, 7)
	put_unsigned(&entries, 0x1000, 8)
	put_unsigned(&entries, 0x40, 4)
	append(&entries, 1, DW_OP_REG0 + 6)
	put_leb128(&entries, 8)
	put_text(&entries, "address")
	put_unsigned(&entries, unsigned_type, 4)
	put_unsigned(&entries, 0, 4)
	put_leb128(&entries, 6)
	put_text(&entries, "node")
	put_unsigned(&entries, record_type, 4)
	append(&entries, 2, DW_OP_FBREG, 0x70) // The frame base less 16.
	put_leb128(&entries, 14)
	put_unsigned(&entries, 0, 4)
	put_leb128(&entries, 6)
	put_text(&entries, "kind")
	put_unsigned(&entries, enumeration_type, 4)
	append(&entries, 1, DW_OP_REG0 + 3) // The register 3 of DWARF is rbx.
	put_leb128(&entries, 15)
	put_text(&entries, "gone")
	put_unsigned(&entries, signed_type, 4)
	append(&entries, 0)
	put_leb128(&entries, 19)
	put_unsigned(&entries, abstract_procedure, 4)
	put_unsigned(&entries, 0x1020, 8)
	put_unsigned(&entries, 8, 4)
	put_leb128(&entries, 16)
	put_unsigned(&entries, abstract_variable, 4)
	append(&entries, 2, DW_OP_BREG0 + 7, 8) // The stack pointer plus 8.
	append(&entries, 0)
	append(&entries, 0)
	append(&entries, 0)

	locations := make([dynamic]u8, context.temp_allocator)
	put_unsigned(&locations, 0x1000, 8)
	put_unsigned(&locations, 0x1010, 8)
	put_unsigned(&locations, 1, 2)
	append(&locations, DW_OP_REG0 + 5) // rdi.
	put_unsigned(&locations, 0x1010, 8)
	put_unsigned(&locations, 0x1040, 8)
	put_unsigned(&locations, 4, 2)
	append(&locations, 0xF3, 0x01, DW_OP_REG0 + 5, 0x9F) // The value of rdi at the entry: not a place.
	put_unsigned(&locations, 0, 16)

	ranges := make([dynamic]u8, context.temp_allocator)
	put_unsigned(&ranges, 0x1004, 8)
	put_unsigned(&ranges, 0x1010, 8)
	put_unsigned(&ranges, 0x1030, 8)
	put_unsigned(&ranges, 0x1038, 8)
	put_unsigned(&ranges, 0, 16)

	sections := make([]Elf_Section_Header, 1, context.temp_allocator)
	sections[0] = {flags = ELF_SECTION_FLAG_ALLOCATED, address = 0x3000, size = 0x100}
	debug_strings := make([dynamic]u8, context.temp_allocator)
	put_text(&debug_strings, "unit")
	return {units = unit_of(entries[:]), abbreviations = sample_abbreviations(), debug_strings = debug_strings[:], locations = locations[:], ranges = ranges[:], sections = sections}
}

@(test)
a_location_expression_of_one_operation_is_a_place :: proc(t: ^testing.T) {
	Case :: struct {
		expression: []u8,
		frame_base: bool,
		location:   debug_object.Location_Kind,
		register:   u32,
		offset:     i32,
	}
	cases := []Case {
		{{DW_OP_REG0 + 5}, true, .Register, 5, 0}, // rdi.
		{{DW_OP_REG0 + 1}, true, .Register, 3, 0}, // The register 1 of DWARF is rdx.
		{{DW_OP_REG0 + 3}, true, .Register, 1, 0}, // The register 3 of DWARF is rbx.
		{{DW_OP_REG0 + 15}, true, .Register, 15, 0},
		{{DW_OP_REGX, 5}, true, .Register, 5, 0},
		{{DW_OP_BREG0 + 6, 0x68}, true, .Frame_Pointer_Offset, 6, -24},
		{{DW_OP_BREG0 + 6, 0x68}, false, .Frame_Pointer_Offset, 6, -24}, // rbp by its own name needs no frame base.
		{{DW_OP_BREG0 + 7, 0x10}, true, .Stack_Pointer_Offset, 7, 16},
		{{DW_OP_BREG0, 0x08}, true, .Register_Offset, 0, 8},
		{{DW_OP_BREGX, 3, 0x08}, true, .Register_Offset, 1, 8},
		{{DW_OP_FBREG, 0x70}, true, .Frame_Pointer_Offset, 6, -16},
		// Not readable: each other expression.
		{{}, true, .Not_Readable, 0, 0},
		{{DW_OP_FBREG, 0x70}, false, .Not_Readable, 0, 0}, // A frame base that is not rbp.
		{{DW_OP_REG0 + 17}, true, .Not_Readable, 0, 0}, // A vector register.
		{{DW_OP_REGX, 33}, true, .Not_Readable, 0, 0},
		{{DW_OP_BREG0 + 6, 0x68, 0x06}, true, .Not_Readable, 0, 0}, // Then a read of memory.
		{{0x30, 0x9F}, true, .Not_Readable, 0, 0}, // A known value, no place.
		{{DW_OP_REG0 + 5, 0x93, 0x08}, true, .Not_Readable, 0, 0}, // One piece of a variable.
		{{0xF3, 0x01, DW_OP_REG0 + 5, 0x9F}, true, .Not_Readable, 0, 0}, // The value at the entry.
		{{DW_OP_BREG0 + 6}, true, .Not_Readable, 0, 0}, // Cut.
		{{DW_OP_BREG0 + 6, 0x80}, true, .Not_Readable, 0, 0}, // Cut inside the number.
		{{DW_OP_BREG0 + 6, 0x80, 0x80, 0x80, 0x80, 0x10}, true, .Not_Readable, 0, 0}, // An offset past 32 bits.
		{{DW_OP_ADDR, 1, 2}, true, .Not_Readable, 0, 0}, // A cut address.
	}
	for item, index in cases {
		place := dwarf_location_of_expression(item.expression, 8, item.frame_base)
		testing.expectf(t, !place.is_address && place.location == item.location && place.register == item.register && place.offset == item.offset, "case %d: %v", index, place)
	}
	address := dwarf_location_of_expression({DW_OP_ADDR, 0x00, 0x30, 0, 0, 0, 0, 0, 0}, 8, true)
	testing.expect(t, address.is_address && address.address == 0x3000, "a fixed address")
	// A fixed address, then another operation: not an address.
	testing.expect(t, !dwarf_location_of_expression({DW_OP_ADDR, 0x00, 0x30, 0, 0, 0, 0, 0, 0, 0x06}, 8, true).is_address)
}

@(test)
the_entries_of_a_unit_are_read_with_each_form :: proc(t: ^testing.T) {
	sample := sample_sections()
	information, error := dwarf_entries_read(sample.units, sample.abbreviations, sample.debug_strings)
	testing.expect_value(t, error, "")
	testing.expect_value(t, len(information.units), 1)
	testing.expect_value(t, information.units[0].address_size, 8)
	// The compile unit holds each other entry.
	testing.expect(t, len(information.entries) > 20 && information.entries[0].tag == DW_TAG_COMPILE_UNIT && information.entries[0].end == len(information.entries))
	testing.expect_value(t, dwarf_text_of(&information, 0, DW_AT_NAME), "unit")
	for entry, index in information.entries {
		testing.expectf(t, entry.end > index && entry.end <= len(information.entries), "the entry %d ends after itself", index)
		testing.expectf(t, index == 0 || (entry.parent >= 0 && entry.parent < index), "the entry %d has its parent before it", index)
		found, known := information.by_offset[entry.offset]
		testing.expect(t, known && found == index)
	}
	// The record: three members, and the pointer before it names it.
	record := -1
	for entry, index in information.entries {
		if entry.tag == DW_TAG_STRUCTURE_TYPE {
			record = index
		}
	}
	testing.expect(t, record > 0 && information.entries[record].end == record + 4)
	pointed, has_pointed := dwarf_referenced_entry(&information, record - 1, DW_AT_TYPE)
	testing.expect(t, has_pointed && pointed == record)
	bit_offset, has_bit_offset := dwarf_number_of(&information, record + 3, DW_AT_DATA_BIT_OFFSET)
	testing.expect(t, has_bit_offset && bit_offset == 131)
}

@(test)
the_types_and_the_variables_come_from_the_entries :: proc(t: ^testing.T) {
	sample := sample_sections()
	information, error := debug_information_from_dwarf(sample.units, sample.abbreviations, sample.debug_strings, sample.locations, sample.ranges, sample.sections)
	testing.expect_value(t, error, "")
	testing.expect_value(t, len(information.globals), 1) // fault::GONE has no address in the module.
	testing.expect_value(t, len(information.variables), 9) // With the scope of address, where it is visible.
	procedures := []Debug_Procedure{{start = 0x1000, size = 0x40, name = "fault::three"}}
	rows := []Debug_Row{{address = 0x1000, path = "programs/fault/main.odin", line = 14}, {address = 0x1040}}
	object, encode_error := debug_object_encode(procedures, rows, 0x2000, {}, nil, information)
	testing.expect_value(t, encode_error, "")
	testing.expect_value(t, debug_object.check(object), debug_object.Fault.None)

	// The parameter: a register, then not readable.
	address, found := debug_object.variable_by_name_at(object, 0x1005, "address")
	address_type, _ := debug_object.type_by_index(object, address.type)
	testing.expect(t, found && address.role == .Parameter && address.location == .Register && address.register == 5 && address.start == 0x1000 && address.size == 0x10)
	testing.expect(t, address_type.name == "u64" && address_type.kind == .Unsigned_Integer && address_type.size == 8)
	address, found = debug_object.variable_by_name_at(object, 0x1010, "address")
	testing.expect(t, found && address.location == .Not_Readable && address.start == 0x1000 && address.size == 0x40, "after its register, address is visible in its scope and not readable")

	// The record at the frame base, with a field of one bit and a pointer to itself.
	node, has_node := debug_object.variable_by_name_at(object, 0x103F, "node")
	node_type, _ := debug_object.type_by_index(object, node.type)
	testing.expect(t, has_node && node.role == .Local && node.location == .Frame_Pointer_Offset && node.register == debug_object.FRAME_POINTER_REGISTER && node.offset == -16)
	testing.expect(t, node_type.name == "fault::Node" && node_type.kind == .Record && node_type.size == 24 && node_type.count == 3)
	next, _ := debug_object.field_by_name(object, node.type, "next")
	next_type, _ := debug_object.type_by_index(object, next.type)
	testing.expect(t, next.offset == 8 && next_type.kind == .Pointer && next_type.size == 8 && next_type.element == node.type)
	flag, has_flag := debug_object.field_by_name(object, node.type, "flag")
	testing.expect(t, has_flag && flag.offset == 16 && flag.bit_shift == 3 && flag.bit_size == 1)

	// The variables of the block live in its two ranges only.
	kind, has_kind := debug_object.variable_by_name_at(object, 0x1006, "kind")
	kind_type, _ := debug_object.type_by_index(object, kind.type)
	testing.expect(t, has_kind && kind.location == .Register && kind.register == 1 && kind.start == 0x1004 && kind.size == 0xC)
	testing.expect(t, kind_type.name == "fault::Kind" && kind_type.kind == .Enumeration && kind_type.size == 4 && kind_type.count == 2)
	value_name, value, has_value := debug_object.enumeration_value_of_type(object, kind.type, 1)
	testing.expect(t, has_value && value_name == "Last" && value == max(u64))
	_, has_kind = debug_object.variable_by_name_at(object, 0x1020, "kind")
	testing.expect(t, !has_kind, "kind does not live between the ranges of its block")
	kind, has_kind = debug_object.variable_by_name_at(object, 0x1037, "kind")
	testing.expect(t, has_kind && kind.start == 0x1030)
	gone, has_gone := debug_object.variable_by_name_at(object, 0x1030, "gone")
	testing.expect(t, has_gone && gone.location == .Not_Readable, "a variable with no place is not readable")

	// The variable of the procedure inside the other one: its name and
	// its type come from its declaration.
	step, has_step := debug_object.variable_by_name_at(object, 0x1024, "step")
	step_type, _ := debug_object.type_by_index(object, step.type)
	testing.expect(t, has_step && step.location == .Stack_Pointer_Offset && step.register == debug_object.STACK_POINTER_REGISTER && step.offset == 8 && step.size == 8)
	testing.expect(t, step_type.name == "fault::Count" && step_type.kind == .Unsigned_Integer && step_type.size == 8, "a typedef is its type with its own name")

	table, has_table := debug_object.global_by_name(object, "fault::TABLE")
	table_type, _ := debug_object.type_by_index(object, table.type)
	testing.expect(t, has_table && table.address == 0x3000 && table_type.kind == .Array && table_type.count == 4 && table_type.size == 32 && table_type.element == address.type)
	_, has_dropped := debug_object.global_by_name(object, "fault::GONE")
	testing.expect(t, !has_dropped)
}

// expect_error checks that a read failed with a sentence that holds a text.
@(private = "file")
expect_error :: proc(t: ^testing.T, error: string, part: string, loc := #caller_location) {
	testing.expectf(t, strings.contains(error, part), "the error \"%s\" does not hold \"%s\"", error, part, loc = loc)
}

@(test)
a_malformed_section_is_an_error_with_its_offset :: proc(t: ^testing.T) {
	sample := sample_sections()
	abbreviations := sample.abbreviations
	// A unit longer than its section, and each cut of the section.
	for size in 1 ..< len(sample.units) {
		_, cut_error := dwarf_entries_read(sample.units[:size], abbreviations, sample.debug_strings)
		expect_error(t, cut_error, "of .debug_info")
	}
	// The header.
	entries := sample.units[UNIT_HEADER_SIZE:]
	_, error := dwarf_entries_read(unit_of(entries, 5), abbreviations, sample.debug_strings)
	expect_error(t, error, "has the version 5 of DWARF")
	_, error = dwarf_entries_read(unit_of(entries, 4, 3), abbreviations, sample.debug_strings)
	expect_error(t, error, "addresses of 3 bytes")
	_, error = dwarf_entries_read(unit_of(entries, 4, 8, 0x4000), abbreviations, sample.debug_strings)
	expect_error(t, error, "outside .debug_abbrev")
	_, error = dwarf_entries_read({3, 0, 0, 0, 4, 0, 0}, abbreviations, sample.debug_strings)
	expect_error(t, error, "the header of the unit at 0x0 of .debug_info is cut")
	// An entry with a code that the table does not have.
	_, error = dwarf_entries_read(unit_of({0x7E}), abbreviations, sample.debug_strings)
	expect_error(t, error, "the entry at 0xb of .debug_info has the code 126")
	// An entry cut inside an attribute: the base type with no size.
	_, error = dwarf_entries_read(unit_of({2, 'u', 0, DW_ATE_UNSIGNED}), abbreviations, sample.debug_strings)
	expect_error(t, error, "the entry at 0xb of .debug_info is cut in its attribute 0xb")
	// A text with no end.
	_, error = dwarf_entries_read(unit_of({2, 'u', '6', '4'}), abbreviations, sample.debug_strings)
	expect_error(t, error, "is cut in its attribute 0x3")
	// A name outside .debug_str.
	_, error = dwarf_entries_read(unit_of({1, 0x00, 0x10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}), abbreviations, sample.debug_strings)
	expect_error(t, error, "outside .debug_str")
	// An expression longer than the unit.
	_, error = dwarf_entries_read(unit_of({6, 'n', 0, 0, 0, 0, 0, 0x40, DW_OP_REG0}), abbreviations, sample.debug_strings)
	expect_error(t, error, "is cut in its attribute 0x2")

	// The abbreviations: a form that the tool does not read, an indirect
	// form of an indirect form, a table with no end, a code two times.
	other := make([dynamic]u8, context.temp_allocator)
	put_abbreviation(&other, 1, DW_TAG_VARIABLE, false, {DW_AT_NAME, 0x1A})
	put_abbreviation(&other, 2, DW_TAG_VARIABLE, false, {DW_AT_NAME, 0x16})
	append(&other, 0)
	_, error = dwarf_entries_read(unit_of({1, 0}), other[:], nil)
	expect_error(t, error, "has the form 0x1a, which the tool does not read")
	_, error = dwarf_entries_read(unit_of({2, 0x16, 0}), other[:], nil)
	expect_error(t, error, "an indirect form of an indirect form")
	// An indirect form of a constant is read.
	indirect, indirect_error := dwarf_entries_read(unit_of({2, DW_FORM_DATA1, 7}), other[:], nil)
	testing.expect(t, indirect_error == "" && len(indirect.values) == 1 && indirect.values[0].number == 7)
	_, error = dwarf_entries_read(unit_of({1, 0}), other[:len(other) - 1], nil)
	expect_error(t, error, ".debug_abbrev is cut")
	_, error = dwarf_abbreviations_read({1, DW_TAG_VARIABLE, 0, DW_AT_NAME}, 0)
	expect_error(t, error, ".debug_abbrev is cut in the abbreviation at 0x0")
	twice := make([dynamic]u8, context.temp_allocator)
	put_abbreviation(&twice, 1, DW_TAG_VARIABLE, false, {})
	put_abbreviation(&twice, 1, DW_TAG_MEMBER, false, {})
	append(&twice, 0)
	_, error = dwarf_abbreviations_read(twice[:], 0)
	expect_error(t, error, "has the code 1 a second time")

	// Entries below one another past the bound: an error, not a deep stack.
	nested := make([dynamic]u8, context.temp_allocator)
	put_abbreviation(&nested, 1, DW_TAG_LEXICAL_BLOCK, true, {})
	append(&nested, 0)
	deep := make([]u8, DWARF_DEPTH_LIMIT + 1, context.temp_allocator)
	slice_fill(deep, 1)
	_, error = dwarf_entries_read(unit_of(deep), nested[:], nil)
	expect_error(t, error, "is below more than")
	// A unit of padding only, and entries that never end, are read.
	padding, padding_error := dwarf_entries_read(unit_of({0, 0, 0, 0}), nested[:], nil)
	testing.expect(t, padding_error == "" && len(padding.entries) == 0)
	open, open_error := dwarf_entries_read(unit_of({1, 1, 1}), nested[:], nil)
	testing.expect(t, open_error == "" && len(open.entries) == 3 && open.entries[0].end == 3 && open.entries[2].end == 3)

	// The lists of addresses.
	unit := Dwarf_Unit{address_size = 8, offset_size = 4, version = 4, base_address = 0x100}
	_, error = dwarf_address_list_read(sample.locations, u64(len(sample.locations)), unit, true, ".debug_loc")
	expect_error(t, error, "outside .debug_loc")
	_, error = dwarf_address_list_read(sample.locations[:len(sample.locations) - 1], 0, unit, true, ".debug_loc")
	expect_error(t, error, ".debug_loc is cut at 0x29, in the list at 0x0")
	_, error = dwarf_address_list_read(sample.locations[:18], 0, unit, true, ".debug_loc")
	expect_error(t, error, "in the expression of the list")
	_, error = dwarf_address_list_read(sample.ranges[:20], 0, unit, false, ".debug_ranges")
	expect_error(t, error, ".debug_ranges is cut at 0x10")
	// A new base, then a pair from it; a pair before it is from the base of the unit.
	based := make([dynamic]u8, context.temp_allocator)
	put_unsigned(&based, 0x10, 8)
	put_unsigned(&based, 0x20, 8)
	put_unsigned(&based, max(u64), 8)
	put_unsigned(&based, 0x5000, 8)
	put_unsigned(&based, 0x10, 8)
	put_unsigned(&based, 0x20, 8)
	put_unsigned(&based, 0, 16)
	list, list_error := dwarf_address_list_read(based[:], 0, unit, false, ".debug_ranges")
	testing.expect(t, list_error == "" && len(list) == 2 && list[0].start == 0x110 && list[0].end == 0x120 && list[1].start == 0x5010 && list[1].end == 0x5020)

	// A variable that names a list outside its section.
	_, error = debug_information_from_dwarf(sample.units, abbreviations, sample.debug_strings, nil, sample.ranges, sample.sections)
	expect_error(t, error, "outside .debug_loc")
	_, error = debug_information_from_dwarf(sample.units, abbreviations, sample.debug_strings, sample.locations, sample.ranges[:8], sample.sections)
	expect_error(t, error, ".debug_ranges is cut")
}

@(private = "file")
slice_fill :: proc(bytes: []u8, value: u8) {
	for &item in bytes {
		item = value
	}
}

// Each byte of the sample changed, one at a time, to four other values:
// the read ends with an error or with tables, and the tables that the
// tool writes from them pass the check or are refused. No read leaves a
// section and no loop runs with no end.
@(test)
a_changed_byte_of_a_section_never_breaks_the_reader :: proc(t: ^testing.T) {
	sample := sample_sections()
	procedures := []Debug_Procedure{{start = 0x1000, size = 0x40, name = "fault::three"}}
	rows := []Debug_Row{{address = 0x1000, path = "programs/fault/main.odin", line = 14}, {address = 0x1040}}
	outcomes: [3]int
	run :: proc(changed: Sample_Sections, procedures_of_run: []Debug_Procedure, rows_of_run: []Debug_Row, counts: ^[3]int) {
		information, error := debug_information_from_dwarf(changed.units, changed.abbreviations, changed.debug_strings, changed.locations, changed.ranges, changed.sections)
		if error != "" {
			counts[0] += 1
			return
		}
		object, encode_error := debug_object_encode(procedures_of_run, rows_of_run, 0x2000, {}, nil, information)
		if encode_error != "" || debug_object.check(object) != .None {
			counts[1] += 1
			return
		}
		counts[2] += 1
	}
	changed_sections := [4][]u8{sample.units, sample.abbreviations, sample.locations, sample.ranges}
	other_values := [4]u8{0x00, 0x7F, 0x80, 0xFF}
	for section in changed_sections {
		for index in 0 ..< len(section) {
			kept := section[index]
			for value in other_values {
				section[index] = value
				run(sample, procedures, rows, &outcomes)
			}
			section[index] = kept
		}
	}
	testing.expect(t, outcomes[0] > 0 && outcomes[2] > 0, "some changes are errors and some are read")
}

// The types of the round trip, by a name of this test, and their places in
// one list of types.
@(private = "file")
Round_Trip_Type :: enum {
	None,
	Word,
	Byte,
	Inner,
	Three_Inner,
	Two_Of_Three_Inner,
	Outer,
	Pointer_To_Outer,
	Alias,
	Unused,
	Word_Again,
}

// round_trip_information gives the same types and variables with the
// types at the given places and the globals and the variables in the
// given order.
@(private = "file")
round_trip_information :: proc(place: [Round_Trip_Type]int, reversed: bool) -> Debug_Information {
	types := make([]Debug_Type, len(Round_Trip_Type), context.temp_allocator)
	types[place[.Word]] = {name = "u32", size = 4, kind = .Unsigned_Integer}
	types[place[.Byte]] = {name = "u8", size = 1, kind = .Unsigned_Integer}
	inner_fields := make([]Debug_Field, 2, context.temp_allocator)
	inner_fields[0] = {name = "a", offset = 0, type = place[.Word]}
	inner_fields[1] = {name = "b", offset = 4, type = place[.Byte]}
	types[place[.Inner]] = {name = "fault::Inner", size = 8, kind = .Record, fields = inner_fields}
	types[place[.Three_Inner]] = {kind = .Array, element = place[.Inner], count = 3, size_from_elements = true}
	types[place[.Two_Of_Three_Inner]] = {kind = .Array, element = place[.Three_Inner], count = 2, size_from_elements = true}
	outer_fields := make([]Debug_Field, 4, context.temp_allocator)
	outer_fields[0] = {name = "inner", offset = 0, type = place[.Inner]}
	outer_fields[1] = {name = "list", offset = 8, type = place[.Three_Inner]}
	outer_fields[2] = {name = "grid", offset = 32, type = place[.Two_Of_Three_Inner]}
	outer_fields[3] = {name = "self", offset = 80, type = place[.Pointer_To_Outer]}
	types[place[.Outer]] = {name = "fault::Outer", size = 88, kind = .Record, fields = outer_fields}
	types[place[.Pointer_To_Outer]] = {size = 8, kind = .Pointer, element = place[.Outer]}
	types[place[.Alias]] = {name = "fault::Alias", alias = true, element = place[.Word]}
	types[place[.Unused]] = {name = "fault::Unused", size = 2, kind = .Record}
	types[place[.Word_Again]] = {name = "u32", size = 4, kind = .Unsigned_Integer}
	globals := make([dynamic]Debug_Global, context.temp_allocator)
	append(&globals, Debug_Global{name = "fault::OUTER", address = 0x3000, type = place[.Outer]})
	append(&globals, Debug_Global{name = "fault::ALIAS", address = 0x3000, type = place[.Alias]})
	append(&globals, Debug_Global{name = "fault::A", address = 0x2000, type = place[.Word_Again]})
	variables := make([dynamic]Debug_Variable, context.temp_allocator)
	append(&variables, Debug_Variable{name = "a", role = .Parameter, location = .Register, register = 5, type = place[.Word], start = 0x1000, end = 0x1010})
	append(&variables, Debug_Variable{name = "b", location = .Frame_Pointer_Offset, register = 6, offset = -8, type = place[.Inner], start = 0x1000, end = 0x1040})
	append(&variables, Debug_Variable{name = "c", location = .Stack_Pointer_Offset, register = 7, offset = 16, type = place[.Pointer_To_Outer], start = 0x1040, end = 0x1060})
	append(&variables, Debug_Variable{name = "d", location = .Register_Offset, register = 2, offset = 4, type = place[.Byte], start = 0x1044, end = 0x1048})
	// Not readable: the register and the offset are not written. The
	// range passes the end of its procedure.
	append(&variables, Debug_Variable{name = "e", location = .Not_Readable, register = 9, offset = 3, type = place[.Word_Again], start = 0x1030, end = 0x1050})
	append(&variables, Debug_Variable{name = "f", location = .Register, register = 1, type = place[.Word], start = 0x5000, end = 0x5010}) // In no procedure.
	append(&variables, Debug_Variable{name = "a", role = .Parameter, location = .Register, register = 5, type = place[.Word], start = 0x1000, end = 0x1010}) // A second time.
	append(&variables, Debug_Variable{name = "g", location = .Register, register = 1, type = place[.Word], start = 0x1010, end = 0x1010}) // No byte.
	if reversed {
		for index in 0 ..< len(globals) / 2 {
			globals[index], globals[len(globals) - 1 - index] = globals[len(globals) - 1 - index], globals[index]
		}
		for index in 0 ..< len(variables) / 2 {
			variables[index], variables[len(variables) - 1 - index] = variables[len(variables) - 1 - index], variables[index]
		}
	}
	return {types = types, globals = globals[:], variables = variables[:]}
}

@(private = "file")
round_trip_object :: proc(information: Debug_Information) -> (object: []u8, error: string) {
	procedures := []Debug_Procedure{{start = 0x1000, size = 0x40, name = "fault::three"}, {start = 0x1040, size = 0x20, name = "fault::two"}}
	rows := []Debug_Row{{address = 0x1000, path = "programs/fault/main.odin", line = 14}, {address = 0x1060}}
	hashes := make(map[string][32]u8, context.temp_allocator)
	hashes["programs/fault/main.odin"] = {0 = 0x5A, 31 = 0xA5}
	return debug_object_encode(procedures, rows, 0x2000, {0 = 1}, hashes, information)
}

@(test)
the_tables_that_the_tool_writes_are_read_back :: proc(t: ^testing.T) {
	place := [Round_Trip_Type]int {
		.None               = 0,
		.Word               = 1,
		.Byte               = 2,
		.Inner              = 3,
		.Three_Inner        = 4,
		.Two_Of_Three_Inner = 5,
		.Outer              = 6,
		.Pointer_To_Outer   = 7,
		.Alias              = 8,
		.Unused             = 9,
		.Word_Again         = 10,
	}
	object, error := round_trip_object(round_trip_information(place, false))
	testing.expect_value(t, error, "")
	testing.expect_value(t, debug_object.check(object), debug_object.Fault.None)
	parts, _ := debug_object.tables(object)
	// Eight types and the type 0: the type that no variable uses is not
	// written, and the two types "u32" are one.
	testing.expect_value(t, len(parts.types), 9)
	testing.expect(t, !strings.contains(string(object), "fault::Unused"))
	testing.expect_value(t, strings.count(string(parts.strings), "u32"), 1)

	// The source file has its hash.
	source, has_source := debug_object.source_line_of(object, 0x1000)
	testing.expect(t, has_source && source.content_hash_known && source.content_hash[0] == 0x5A && source.content_hash[31] == 0xA5)

	// The variables: by their procedure, then their name.
	testing.expect_value(t, len(parts.variables), 5)
	testing.expect_value(t, len(parts.ranges), 5)
	names := [5]string{"a", "b", "e", "c", "d"}
	starts := [5]u32{0x1000, 0x1000, 0x1030, 0x1040, 0x1044}
	for expected_name, index in names {
		variable, _ := debug_object.variable_range_by_index(object, u32(index), 0)
		testing.expectf(t, variable.name == expected_name && variable.start == u64(starts[index]), "the variable %d is %s at %x", index, variable.name, variable.start)
	}
	first_variable, _ := debug_object.variable_range_by_index(object, 0, 0)
	testing.expect(t, first_variable.role == .Parameter && first_variable.location == .Register && first_variable.register == 5 && first_variable.size == 0x10)
	frame_variable, _ := debug_object.variable_by_name_at(object, 0x1020, "b")
	testing.expect(t, frame_variable.location == .Frame_Pointer_Offset && frame_variable.offset == -8)
	// The range that passes the end of its procedure is cut there.
	cut_variable, has_cut := debug_object.variable_by_name_at(object, 0x103F, "e")
	testing.expect(t, has_cut && cut_variable.location == .Not_Readable && cut_variable.register == 0 && cut_variable.offset == 0 && cut_variable.size == 0x10)
	_, has_cut = debug_object.variable_by_name_at(object, 0x1040, "e")
	testing.expect(t, !has_cut)
	stack_variable, _ := debug_object.variable_by_name_at(object, 0x1050, "c")
	testing.expect(t, stack_variable.location == .Stack_Pointer_Offset && stack_variable.offset == 16)
	register_variable, _ := debug_object.variable_by_name_at(object, 0x1045, "d")
	testing.expect(t, register_variable.location == .Register_Offset && register_variable.register == 2 && register_variable.offset == 4)
	// The two types "u32" of the source are one type of the object.
	testing.expect_value(t, cut_variable.type, first_variable.type)

	// The globals: by their address, then their name.
	global_names := [3]string{"fault::A", "fault::ALIAS", "fault::OUTER"}
	for expected_name, index in global_names {
		global, _ := debug_object.global_by_index(object, u32(index))
		testing.expectf(t, global.name == expected_name, "the global %d is %s", index, global.name)
	}
	alias, _ := debug_object.global_by_name(object, "fault::ALIAS")
	alias_type, _ := debug_object.type_by_index(object, alias.type)
	testing.expect(t, alias_type.name == "fault::Alias" && alias_type.kind == .Unsigned_Integer && alias_type.size == 4)

	// The nested record and the arrays, with the sizes of the arrays.
	outer, _ := debug_object.global_by_name(object, "fault::OUTER")
	outer_type, _ := debug_object.type_by_index(object, outer.type)
	testing.expect(t, outer_type.kind == .Record && outer_type.count == 4 && outer_type.size == 88)
	grid, _ := debug_object.field_by_name(object, outer.type, "grid")
	grid_type, _ := debug_object.type_by_index(object, grid.type)
	testing.expect(t, grid.offset == 32 && grid_type.kind == .Array && grid_type.count == 2 && grid_type.size == 48)
	row_type, _ := debug_object.type_by_index(object, grid_type.element)
	testing.expect(t, row_type.kind == .Array && row_type.count == 3 && row_type.size == 24)
	inner_type, _ := debug_object.type_by_index(object, row_type.element)
	testing.expect(t, inner_type.name == "fault::Inner" && inner_type.kind == .Record && inner_type.size == 8)
	inner_b, _ := debug_object.field_by_name(object, row_type.element, "b")
	inner_b_type, _ := debug_object.type_by_index(object, inner_b.type)
	testing.expect(t, inner_b.offset == 4 && inner_b_type.name == "u8")
	list, _ := debug_object.field_by_name(object, outer.type, "list")
	testing.expect_value(t, list.type, grid_type.element)
	self, _ := debug_object.field_by_name(object, outer.type, "self")
	self_type, _ := debug_object.type_by_index(object, self.type)
	testing.expect(t, self_type.kind == .Pointer && self_type.element == outer.type)

	// The fixed order: the same content with the types at other places
	// and the records in the other order gives the same bytes.
	other_place := [Round_Trip_Type]int {
		.None               = 0,
		.Word               = 10,
		.Byte               = 4,
		.Inner              = 9,
		.Three_Inner        = 1,
		.Two_Of_Three_Inner = 7,
		.Outer              = 2,
		.Pointer_To_Outer   = 8,
		.Alias              = 3,
		.Unused             = 6,
		.Word_Again         = 5,
	}
	other, other_error := round_trip_object(round_trip_information(other_place, true))
	testing.expect_value(t, other_error, "")
	testing.expect(t, string(other) == string(object), "two orders of the source give the same bytes")
}

@(test)
a_list_of_types_that_is_wrong_is_an_error :: proc(t: ^testing.T) {
	// A typedef of itself.
	looped := []Debug_Type{{}, {name = "fault::Loop", alias = true, element = 2}, {name = "fault::Back", alias = true, element = 1}}
	_, _, error := debug_types_in_fixed_order(looped, {{name = "x", address = 1, type = 1}}, nil)
	expect_error(t, error, "is another name of itself")
	// A type that the list does not have.
	_, _, error = debug_types_in_fixed_order({{}, {kind = .Pointer, size = 8, element = 5}}, nil, nil)
	expect_error(t, error, "names the type 5")
	_, _, error = debug_types_in_fixed_order({{}}, nil, {{name = "x", type = -1, start = 1, end = 2}})
	expect_error(t, error, "the variable x names the type -1")
	// An array larger than a debug object describes.
	large := []Debug_Type{{}, {name = "u64", kind = .Unsigned_Integer, size = 8}, {kind = .Array, element = 1, count = 1 << 30, size_from_elements = true}}
	_, _, error = debug_types_in_fixed_order(large, {{name = "x", address = 1, type = 2}}, nil)
	expect_error(t, error, "is larger than a debug object describes")
	// Another name of "no type" keeps its name and has no size.
	nothing := []Debug_Type{{}, {name = "fault::Nothing", alias = true}}
	ordered, index_of, nothing_error := debug_types_in_fixed_order(nothing, {{name = "x", address = 1, type = 1}}, nil)
	testing.expect(t, nothing_error == "" && len(ordered) == 2 && index_of[1] == 1 && ordered[1].name == "fault::Nothing" && ordered[1].kind == .Other && ordered[1].size == 0)
	// With no type, the table has the type 0.
	empty, _, empty_error := debug_types_in_fixed_order(nil, nil, nil)
	testing.expect(t, empty_error == "" && len(empty) == 1)
	testing.expect_value(t, debug_host_path("/build/source/programs/fault", "main.odin"), "/build/source/programs/fault/main.odin")
	testing.expect_value(t, debug_host_path("programs/fault", "/nix/store/odin/share/base/runtime/core.odin"), "/nix/store/odin/share/base/runtime/core.odin")
}

// The ranges of the merge rules, in one procedure from 0x1000 to 0x31000.
@(private = "file")
merge_information :: proc(reversed: bool) -> Debug_Information {
	types := make([]Debug_Type, 2, context.temp_allocator)
	types[1] = {name = "u32", size = 4, kind = .Unsigned_Integer}
	variables := make([dynamic]Debug_Variable, context.temp_allocator)
	add :: proc(list: ^[dynamic]Debug_Variable, name: string, location: debug_object.Location_Kind, register: u32, offset: i32, start, end: u64, inlined: bool) {
		append(list, Debug_Variable{name = name, location = location, register = register, offset = offset, type = 1, start = start, end = end, inlined = inlined})
	}
	// m: two ranges that touch and one that overlaps are one range; a gap
	// and another location keep a range apart.
	add(&variables, "m", .Register, 5, 0, 0x1000, 0x1010, false)
	add(&variables, "m", .Register, 5, 0, 0x1010, 0x1020, false)
	add(&variables, "m", .Register, 5, 0, 0x1018, 0x1030, false)
	add(&variables, "m", .Register, 3, 0, 0x1030, 0x1040, false)
	add(&variables, "m", .Register, 5, 0, 0x1041, 0x1050, false)
	// n: readable nowhere, in three ranges: one range.
	add(&variables, "n", .Not_Readable, 0, 0, 0x1000, 0x1010, false)
	add(&variables, "n", .Not_Readable, 0, 0, 0x1020, 0x1030, false)
	add(&variables, "n", .Not_Readable, 0, 0, 0x1010, 0x1018, false)
	// p: readable in a part of its scope.
	add(&variables, "p", .Not_Readable, 0, 0, 0x1000, 0x1080, false)
	add(&variables, "p", .Frame_Pointer_Offset, 6, -8, 0x1010, 0x1020, false)
	// q: one readable range covers where it is visible.
	add(&variables, "q", .Not_Readable, 0, 0, 0x1010, 0x1020, false)
	add(&variables, "q", .Register, 1, 0, 0x1000, 0x1040, false)
	// r: of a procedure put inside this one, two times: its readable
	// ranges only, as one variable.
	add(&variables, "r", .Not_Readable, 0, 0, 0x1000, 0x1080, true)
	add(&variables, "r", .Register, 2, 0, 0x1020, 0x1028, true)
	add(&variables, "r", .Register, 2, 0, 0x1028, 0x1030, true)
	// s: of a procedure put inside this one, readable nowhere: not written.
	add(&variables, "s", .Not_Readable, 0, 0, 0x1000, 0x1080, true)
	// t: a range longer than one record holds.
	add(&variables, "t", .Register, 4, 0, 0x1000, 0x21000, false)
	if reversed {
		for index in 0 ..< len(variables) / 2 {
			variables[index], variables[len(variables) - 1 - index] = variables[len(variables) - 1 - index], variables[index]
		}
	}
	return {types = types, variables = variables[:]}
}

@(private = "file")
merge_object :: proc(reversed: bool) -> (object: []u8, error: string) {
	procedures := []Debug_Procedure{{start = 0x1000, size = 0x30000, name = "fault::long"}}
	rows := []Debug_Row{{address = 0x1000, path = "programs/fault/main.odin", line = 14}, {address = 0x31000}}
	return debug_object_encode(procedures, rows, 0x40000, {}, nil, merge_information(reversed))
}

@(test)
the_ranges_of_a_variable_are_merged :: proc(t: ^testing.T) {
	object, error := merge_object(false)
	testing.expect_value(t, error, "")
	testing.expect_value(t, debug_object.check(object), debug_object.Fault.None)
	parts, _ := debug_object.tables(object)
	testing.expect_value(t, len(parts.variables), 6) // m, n, p, q, r, t.
	testing.expect_value(t, len(parts.ranges), 11)
	Expected :: struct {
		start:    u64,
		size:     u64,
		location: debug_object.Location_Kind,
		register: u32,
	}
	expect_ranges :: proc(t: ^testing.T, object: []u8, index: u32, name: string, expected: []Expected) {
		testing.expectf(t, debug_object.variable_range_count(object, index) == u32(len(expected)), "%s has %d ranges, not %d", name, debug_object.variable_range_count(object, index), len(expected))
		for item, number in expected {
			found, _ := debug_object.variable_range_by_index(object, index, u32(number))
			testing.expectf(t, found.name == name && found.start == item.start && found.size == item.size && found.location == item.location && found.register == item.register, "the range %d of %s is %v", number, name, found)
		}
	}
	// Ranges that touch or overlap, with one location: one range. A gap
	// of one byte and another register: not merged.
	expect_ranges(t, object, 0, "m", {{0x1000, 0x30, .Register, 5}, {0x1030, 0x10, .Register, 3}, {0x1041, 0xF, .Register, 5}})
	_, has_gap := debug_object.variable_by_name_at(object, 0x1040, "m")
	testing.expect(t, !has_gap, "m is not visible in the gap")
	// Readable nowhere: one range, from the first start to the last end.
	expect_ranges(t, object, 1, "n", {{0x1000, 0x30, .Not_Readable, 0}})
	// Readable in a part: where it is visible, then where it is readable.
	expect_ranges(t, object, 2, "p", {{0x1000, 0x80, .Not_Readable, 0}, {0x1010, 0x10, .Frame_Pointer_Offset, 6}})
	readable, _ := debug_object.variable_by_name_at(object, 0x1015, "p")
	testing.expect(t, readable.location == .Frame_Pointer_Offset && readable.offset == -8)
	visible, has_visible := debug_object.variable_by_name_at(object, 0x1050, "p")
	testing.expect(t, has_visible && visible.location == .Not_Readable)
	// A readable range that covers the scope: no second range.
	expect_ranges(t, object, 3, "q", {{0x1000, 0x40, .Register, 1}})
	// Of a procedure put inside this one: the readable ranges, merged.
	expect_ranges(t, object, 4, "r", {{0x1020, 0x10, .Register, 2}})
	_, has_inlined := debug_object.variable_by_name_at(object, 0x1050, "r")
	testing.expect(t, !has_inlined)
	_, has_dropped := debug_object.variable_by_name_at(object, 0x1050, "s")
	testing.expect(t, !has_dropped)
	// A long range: records in a row.
	expect_ranges(t, object, 5, "t", {{0x1000, 0xFFFF, .Register, 4}, {0x10FFF, 0xFFFF, .Register, 4}, {0x20FFE, 2, .Register, 4}})
	last, has_last := debug_object.variable_by_name_at(object, 0x20FFF, "t")
	testing.expect(t, has_last && last.location == .Register && last.register == 4)
	_, has_last = debug_object.variable_by_name_at(object, 0x21000, "t")
	testing.expect(t, !has_last)
	// The other order of the source gives the same bytes.
	other, other_error := merge_object(true)
	testing.expect_value(t, other_error, "")
	testing.expect(t, string(other) == string(object), "two orders of the source give the same bytes")
}
