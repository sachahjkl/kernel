package kerneltool

import debug_object "modus:contract/debug_object"
import "core:fmt"
import "core:slice"
import "core:strings"

// The types and the variables of a debug object (docs/MODULE_CONTRACT.md,
// "The types and the variables"). The tool reads the entries of
// `.debug_info` of the linked file of a module, with `.debug_abbrev`,
// `.debug_str`, `.debug_loc` and `.debug_ranges`, in the versions 2 to 4 of
// DWARF: the compiler of the build writes the version 4. Each read has a
// bound: a section that is cut or wrong is an error with its offset, never
// a read outside the section and never a loop with no end.

// The tags of the entries that the tool reads (DWARF 4, section 7.5.4).
DW_TAG_ARRAY_TYPE :: 0x01
DW_TAG_ENUMERATION_TYPE :: 0x04
DW_TAG_FORMAL_PARAMETER :: 0x05
DW_TAG_LEXICAL_BLOCK :: 0x0B
DW_TAG_MEMBER :: 0x0D
DW_TAG_POINTER_TYPE :: 0x0F
DW_TAG_COMPILE_UNIT :: 0x11
DW_TAG_STRUCTURE_TYPE :: 0x13
DW_TAG_SUBROUTINE_TYPE :: 0x15
DW_TAG_TYPEDEF :: 0x16
DW_TAG_UNION_TYPE :: 0x17
DW_TAG_INLINED_SUBROUTINE :: 0x1D
DW_TAG_SUBRANGE_TYPE :: 0x21
DW_TAG_BASE_TYPE :: 0x24
DW_TAG_CONST_TYPE :: 0x26
DW_TAG_ENUMERATOR :: 0x28
DW_TAG_SUBPROGRAM :: 0x2E
DW_TAG_VARIABLE :: 0x34
DW_TAG_VOLATILE_TYPE :: 0x35
DW_TAG_RESTRICT_TYPE :: 0x37

// The attributes that the tool reads.
DW_AT_LOCATION :: 0x02
DW_AT_NAME :: 0x03
DW_AT_BYTE_SIZE :: 0x0B
DW_AT_BIT_OFFSET :: 0x0C
DW_AT_BIT_SIZE :: 0x0D
DW_AT_LOW_PC :: 0x11
DW_AT_HIGH_PC :: 0x12
DW_AT_CONST_VALUE :: 0x1C
DW_AT_UPPER_BOUND :: 0x2F
DW_AT_ABSTRACT_ORIGIN :: 0x31
DW_AT_COUNT :: 0x37
DW_AT_DATA_MEMBER_LOCATION :: 0x38
DW_AT_ENCODING :: 0x3E
DW_AT_FRAME_BASE :: 0x40
DW_AT_SPECIFICATION :: 0x47
DW_AT_TYPE :: 0x49
DW_AT_RANGES :: 0x55
DW_AT_DATA_BIT_OFFSET :: 0x6B

// The encodings of a base type.
DW_ATE_BOOLEAN :: 0x02
DW_ATE_FLOAT :: 0x04
DW_ATE_SIGNED :: 0x05
DW_ATE_SIGNED_CHAR :: 0x06
DW_ATE_UNSIGNED :: 0x07
DW_ATE_UNSIGNED_CHAR :: 0x08
DW_ATE_UTF :: 0x10

// The operations of a location expression that give a variable location
// of the debug object. Each other operation makes it not readable.
DW_OP_ADDR :: 0x03
DW_OP_PLUS_UCONST :: 0x23
DW_OP_REG0 :: 0x50
DW_OP_REG31 :: 0x6F
DW_OP_BREG0 :: 0x70
DW_OP_BREG31 :: 0x8F
DW_OP_REGX :: 0x90
DW_OP_FBREG :: 0x91
DW_OP_BREGX :: 0x92

// The entries below one another that the tool follows: a deeper tree is
// not the output of a compiler.
DWARF_DEPTH_LIMIT :: 256
// The entries of one linked file that the tool keeps.
DWARF_ENTRY_LIMIT :: 1 << 24
// The entries that the tool follows from one to the next: a type that is
// another type, a variable that names its declaration.
DWARF_CHAIN_LIMIT :: 32

// The register of the processor of each register number of DWARF for
// x86-64 (the System V ABI, figure 3.36), in the order of
// operation.Thread_Registers: rax, rdx, rcx, rbx, rsi, rdi, rbp, rsp, then
// r8 to r15. A larger number of DWARF is a vector register or a register
// that the register image does not have.
@(rodata)
dwarf_register_order := [16]u32{0, 3, 2, 1, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15}

// What kind of value an attribute holds.
Dwarf_Value_Class :: enum {
	Number, // A constant.
	Address, // An address of the linked file.
	Text, // A name.
	Block, // Bytes: a location expression.
	Reference, // Another entry: `number` is its offset in .debug_info.
	Section_Offset, // An offset in another section: a location list, a range list.
	Flag, // True or false.
	Signature, // A type by its signature, which the tool does not follow.
}

// One attribute of an entry, read.
Dwarf_Value :: struct {
	name:   u64,
	form:   u64,
	class:  Dwarf_Value_Class,
	number: u64,
	text:   string,
	block:  []u8,
}

// One unit of .debug_info.
Dwarf_Unit :: struct {
	start:        u64, // The offset of its header.
	version:      u64,
	address_size: int,
	offset_size:  int,
	base_address: u64, // The low address of its compile unit entry: the base of its location lists and range lists.
}

// One debugging information entry. The entries are in the order of the
// section: the children of an entry come after it, up to `end`.
Dwarf_Entry :: struct {
	offset:      u64, // In .debug_info.
	tag:         u64,
	parent:      int, // -1: the entry of a unit.
	end:         int, // The index after its last descendant.
	unit:        int,
	first_value: int,
	value_count: int,
}

// The entries of .debug_info of one linked file.
Dwarf_Entries :: struct {
	entries:   [dynamic]Dwarf_Entry,
	values:    [dynamic]Dwarf_Value,
	by_offset: map[u64]int,
	units:     [dynamic]Dwarf_Unit,
}

// One abbreviation: the tag and the attributes of each entry with its code.
Dwarf_Abbreviation :: struct {
	tag:          u64,
	has_children: bool,
	attributes:   []Dwarf_Attribute,
}

// dwarf_abbreviations_read reads the abbreviation table of one unit, from
// its offset in .debug_abbrev up to the code 0.
dwarf_abbreviations_read :: proc(abbreviations: []u8, offset: u64) -> (table: map[u64]Dwarf_Abbreviation, error: string) {
	if offset >= u64(len(abbreviations)) {
		return nil, fmt.tprintf("a unit names the abbreviation table at 0x%x, outside .debug_abbrev", offset)
	}
	table = make(map[u64]Dwarf_Abbreviation, context.temp_allocator)
	reader := Dwarf_Reader{bytes = abbreviations, at = int(offset)}
	for {
		at := reader.at
		code := dwarf_leb128(&reader, false)
		if reader.failed {
			return nil, fmt.tprintf(".debug_abbrev is cut at 0x%x, in the table at 0x%x", at, offset)
		}
		if code == 0 {
			return table, ""
		}
		tag := dwarf_leb128(&reader, false)
		has_children := dwarf_unsigned(&reader, 1) != 0
		attributes := make([dynamic]Dwarf_Attribute, context.temp_allocator)
		for {
			name := dwarf_leb128(&reader, false)
			form := dwarf_leb128(&reader, false)
			if reader.failed {
				return nil, fmt.tprintf(".debug_abbrev is cut in the abbreviation at 0x%x", at)
			}
			if name == 0 && form == 0 {
				break
			}
			constant := form == DW_FORM_IMPLICIT_CONST ? dwarf_leb128(&reader, true) : 0
			append(&attributes, Dwarf_Attribute{name = name, form = form, constant = constant})
		}
		if code in table {
			return nil, fmt.tprintf("the abbreviation at 0x%x of .debug_abbrev has the code %d a second time", at, code)
		}
		table[code] = Dwarf_Abbreviation{tag = tag, has_children = has_children, attributes = attributes[:]}
	}
}

// dwarf_value_read reads the value of one attribute of an entry, by its
// form (DWARF 4, section 7.5.4). A form of another version of DWARF, or of
// one vendor, is an error: the tool cannot know its size, so it cannot
// read the entry after it.
dwarf_value_read :: proc(reader: ^Dwarf_Reader, attribute: Dwarf_Attribute, unit: Dwarf_Unit, debug_strings: []u8) -> (value: Dwarf_Value, error: string) {
	value.name = attribute.name
	form := attribute.form
	at := reader.at
	if form == 0x16 {
		// An indirect form: the form itself is in the entry.
		form = dwarf_leb128(reader, false)
		if form == 0x16 {
			return {}, fmt.tprintf("the attribute at 0x%x of .debug_info has an indirect form of an indirect form", at)
		}
	}
	value.form = form
	block_size := max(u64)
	switch form {
	case 0x01:
		value.class = .Address
		value.number = dwarf_unsigned(reader, unit.address_size)
	case 0x0B:
		value.number = dwarf_unsigned(reader, 1)
	case 0x05:
		value.number = dwarf_unsigned(reader, 2)
	case 0x06:
		value.number = dwarf_unsigned(reader, 4)
	case 0x07:
		value.number = dwarf_unsigned(reader, 8)
	case 0x0D:
		value.number = dwarf_leb128(reader, true)
	case 0x0F:
		value.number = dwarf_leb128(reader, false)
	case 0x08:
		value.class = .Text
		value.text = dwarf_text(reader)
	case 0x0E:
		value.class = .Text
		offset := dwarf_unsigned(reader, unit.offset_size)
		if !reader.failed && offset >= u64(len(debug_strings)) {
			return {}, fmt.tprintf("the attribute at 0x%x of .debug_info names the text at 0x%x, outside .debug_str", at, offset)
		}
		value.text = text_until_zero(debug_strings, offset)
	case 0x0C:
		value.class = .Flag
		value.number = dwarf_unsigned(reader, 1)
	case 0x19:
		value.class = .Flag
		value.number = 1
	case 0x11:
		value.class = .Reference
		value.number = unit.start + dwarf_unsigned(reader, 1)
	case 0x12:
		value.class = .Reference
		value.number = unit.start + dwarf_unsigned(reader, 2)
	case 0x13:
		value.class = .Reference
		value.number = unit.start + dwarf_unsigned(reader, 4)
	case 0x14:
		value.class = .Reference
		value.number = unit.start + dwarf_unsigned(reader, 8)
	case 0x15:
		value.class = .Reference
		value.number = unit.start + dwarf_leb128(reader, false)
	case 0x10:
		// A reference by an offset of the section. The version 2 gives it
		// the size of an address.
		value.class = .Reference
		value.number = dwarf_unsigned(reader, unit.version == 2 ? unit.address_size : unit.offset_size)
	case 0x17:
		value.class = .Section_Offset
		value.number = dwarf_unsigned(reader, unit.offset_size)
	case 0x20:
		value.class = .Signature
		value.number = dwarf_unsigned(reader, 8)
	case 0x0A:
		block_size = dwarf_unsigned(reader, 1)
	case 0x03:
		block_size = dwarf_unsigned(reader, 2)
	case 0x04:
		block_size = dwarf_unsigned(reader, 4)
	case 0x09, 0x18:
		block_size = dwarf_leb128(reader, false)
	case:
		return {}, fmt.tprintf("the attribute 0x%x at 0x%x of .debug_info has the form 0x%x, which the tool does not read", attribute.name, at, form)
	}
	if block_size != max(u64) {
		value.class = .Block
		// A size past the section fails the read.
		value.block = dwarf_bytes(reader, int(min(block_size, u64(len(reader.bytes)) + 1)))
	}
	return value, ""
}

// dwarf_entries_read reads each entry of each unit of .debug_info.
dwarf_entries_read :: proc(section, abbreviations, debug_strings: []u8) -> (information: Dwarf_Entries, error: string) {
	information.entries = make([dynamic]Dwarf_Entry, context.temp_allocator)
	information.values = make([dynamic]Dwarf_Value, context.temp_allocator)
	information.by_offset = make(map[u64]int, context.temp_allocator)
	information.units = make([dynamic]Dwarf_Unit, context.temp_allocator)
	open := make([dynamic]int, context.temp_allocator)
	reader := Dwarf_Reader{bytes = section}
	for reader.at < len(section) {
		unit_start := reader.at
		offset_size := 4
		unit_length := dwarf_unsigned(&reader, 4)
		if unit_length == 0xFFFF_FFFF {
			offset_size = 8
			unit_length = dwarf_unsigned(&reader, 8)
		}
		if reader.failed || unit_length > u64(len(section) - reader.at) {
			return {}, fmt.tprintf("the unit at 0x%x of .debug_info is longer than its section", unit_start)
		}
		unit_end := reader.at + int(unit_length)
		unit_reader := Dwarf_Reader{bytes = section[:unit_end], at = reader.at}
		reader.at = unit_end
		version := dwarf_unsigned(&unit_reader, 2)
		if !unit_reader.failed && (version < 2 || version > 4) {
			return {}, fmt.tprintf("the unit at 0x%x of .debug_info has the version %d of DWARF; the tool reads the entries of the versions 2 to 4", unit_start, version)
		}
		abbreviation_offset := dwarf_unsigned(&unit_reader, offset_size)
		address_size := int(dwarf_unsigned(&unit_reader, 1))
		if unit_reader.failed {
			return {}, fmt.tprintf("the header of the unit at 0x%x of .debug_info is cut", unit_start)
		}
		if address_size != 4 && address_size != 8 {
			return {}, fmt.tprintf("the unit at 0x%x of .debug_info has addresses of %d bytes", unit_start, address_size)
		}
		table, table_error := dwarf_abbreviations_read(abbreviations, abbreviation_offset)
		if table_error != "" {
			return {}, table_error
		}
		unit := Dwarf_Unit{start = u64(unit_start), version = version, address_size = address_size, offset_size = offset_size}
		unit_index := len(information.units)
		first_entry := len(information.entries)
		clear(&open)
		for unit_reader.at < unit_end {
			entry_offset := unit_reader.at
			code := dwarf_leb128(&unit_reader, false)
			if unit_reader.failed {
				return {}, fmt.tprintf(".debug_info is cut at 0x%x", entry_offset)
			}
			if code == 0 {
				// The end of the children of the last open entry.
				if len(open) > 0 {
					information.entries[pop(&open)].end = len(information.entries)
				}
				continue
			}
			abbreviation, known := table[code]
			if !known {
				return {}, fmt.tprintf("the entry at 0x%x of .debug_info has the code %d, which its abbreviation table does not have", entry_offset, code)
			}
			if len(information.entries) >= DWARF_ENTRY_LIMIT {
				return {}, fmt.tprintf(".debug_info has more than %d entries", DWARF_ENTRY_LIMIT)
			}
			entry := Dwarf_Entry {
				offset      = u64(entry_offset),
				tag         = abbreviation.tag,
				parent      = len(open) > 0 ? open[len(open) - 1] : -1,
				unit        = unit_index,
				first_value = len(information.values),
			}
			for attribute in abbreviation.attributes {
				value, value_error := dwarf_value_read(&unit_reader, attribute, unit, debug_strings)
				if value_error != "" {
					return {}, value_error
				}
				if unit_reader.failed {
					return {}, fmt.tprintf("the entry at 0x%x of .debug_info is cut in its attribute 0x%x", entry_offset, attribute.name)
				}
				append(&information.values, value)
			}
			entry.value_count = len(information.values) - entry.first_value
			index := len(information.entries)
			entry.end = index + 1
			append(&information.entries, entry)
			information.by_offset[entry.offset] = index
			if abbreviation.has_children {
				if len(open) >= DWARF_DEPTH_LIMIT {
					return {}, fmt.tprintf("the entry at 0x%x of .debug_info is below more than %d entries", entry_offset, DWARF_DEPTH_LIMIT)
				}
				append(&open, index)
			}
		}
		// A unit that ends with open entries: they end with it.
		for len(open) > 0 {
			information.entries[pop(&open)].end = len(information.entries)
		}
		append(&information.units, unit)
		if first_entry < len(information.entries) && information.entries[first_entry].tag == DW_TAG_COMPILE_UNIT {
			if low, has_low := dwarf_value_of(&information, first_entry, DW_AT_LOW_PC); has_low && low.class == .Address {
				information.units[unit_index].base_address = low.number
			}
		}
	}
	return information, ""
}

// dwarf_value_of gives one attribute of an entry.
dwarf_value_of :: proc(information: ^Dwarf_Entries, entry_index: int, name: u64) -> (value: Dwarf_Value, found: bool) {
	entry := information.entries[entry_index]
	for item in information.values[entry.first_value:][:entry.value_count] {
		if item.name == name {
			return item, true
		}
	}
	return {}, false
}

// dwarf_number_of gives an attribute that is a constant.
dwarf_number_of :: proc(information: ^Dwarf_Entries, entry_index: int, name: u64) -> (number: u64, found: bool) {
	value, has_value := dwarf_value_of(information, entry_index, name)
	if !has_value || value.class != .Number {
		return 0, false
	}
	return value.number, true
}

// dwarf_text_of gives an attribute that is a text, or "".
dwarf_text_of :: proc(information: ^Dwarf_Entries, entry_index: int, name: u64) -> string {
	value, has_value := dwarf_value_of(information, entry_index, name)
	return has_value && value.class == .Text ? value.text : ""
}

// dwarf_referenced_entry gives the entry that an attribute names.
dwarf_referenced_entry :: proc(information: ^Dwarf_Entries, entry_index: int, name: u64) -> (referenced: int, found: bool) {
	value, has_value := dwarf_value_of(information, entry_index, name)
	if !has_value || value.class != .Reference {
		return 0, false
	}
	referenced, found = information.by_offset[value.number]
	return
}

// dwarf_declaration_of gives the entry that holds an attribute of a
// variable or a parameter: the entry itself, or the declaration that it
// names (the abstract instance of a procedure that the compiler put
// inside another one). -1: no entry of the chain has the attribute.
dwarf_declaration_of :: proc(information: ^Dwarf_Entries, entry_index: int, name: u64) -> int {
	current := entry_index
	for _ in 0 ..< DWARF_CHAIN_LIMIT {
		if _, has_value := dwarf_value_of(information, current, name); has_value {
			return current
		}
		next, has_origin := dwarf_referenced_entry(information, current, DW_AT_ABSTRACT_ORIGIN)
		if !has_origin {
			next, has_origin = dwarf_referenced_entry(information, current, DW_AT_SPECIFICATION)
		}
		if !has_origin {
			return -1
		}
		current = next
	}
	return -1
}

// One type before the encoding. The references are indices of the list of
// types that holds it; the type 0 of a list is "no type".
Debug_Type :: struct {
	name:               string,
	size:               u64,
	kind:               debug_object.Type_Kind,
	element:            int,
	count:              u64, // The elements of an array. The encoder counts the fields and the values itself.
	fields:             []Debug_Field,
	values:             []Debug_Enumeration_Value,
	// The type is another type with another name (a typedef): `element`
	// is that type. The encoder writes a copy of it with this name.
	alias:              bool,
	size_from_elements: bool, // An array with no size of its own: the count times the size of the element.
}

Debug_Field :: struct {
	name:      string,
	offset:    u64,
	type:      int,
	bit_shift: u16,
	bit_size:  u16,
}

Debug_Enumeration_Value :: struct {
	name:  string,
	value: u64,
}

// One global variable before the encoding.
Debug_Global :: struct {
	name:    string,
	address: u64,
	type:    int,
}

// One variable of a procedure in one range of addresses, before the encoding.
Debug_Variable :: struct {
	name:     string,
	role:     debug_object.Variable_Role,
	location: debug_object.Location_Kind,
	register: u32,
	offset:   i32,
	type:     int,
	start:    u64,
	end:      u64, // The address after the range.
	// The variable is of a procedure that the compiler put inside another
	// one: the encoder keeps only its readable ranges.
	inlined:   bool,
	procedure: u32, // In the procedure table. The encoder sets it.
}

// The types and the variables of one linked file.
Debug_Information :: struct {
	types:     []Debug_Type, // With the type 0.
	globals:   []Debug_Global,
	variables: []Debug_Variable,
}

// The variable location that a location expression gives.
Debug_Variable_Location :: struct {
	location:   debug_object.Location_Kind,
	register:   u32,
	offset:     i32,
	is_address: bool, // The expression is one fixed address: a global variable.
	address:    u64,
}

// dwarf_location_of_expression gives the variable location of a location
// expression of DWARF. Only an expression of one operation is a variable
// location of the debug object: a register, a register plus a constant,
// the frame base of DWARF plus a constant, or
// a fixed address. Each other expression (a value that the compiler
// computes, a variable in several pieces, the value of a register at the
// entry of the procedure) is not readable: the tool runs no expression and
// guesses no location.
dwarf_location_of_expression :: proc(expression: []u8, address_size: int, frame_base_is_frame_pointer: bool) -> (found: Debug_Variable_Location) {
	if len(expression) == 0 {
		return {}
	}
	reader := Dwarf_Reader{bytes = expression, at = 1}
	operation := expression[0]
	in_memory := false
	number := u64(0)
	offset := i64(0)
	switch {
	case operation == DW_OP_ADDR:
		address := dwarf_unsigned(&reader, address_size)
		if reader.failed || reader.at != len(expression) {
			return {}
		}
		return {is_address = true, address = address}
	case operation >= DW_OP_REG0 && operation <= DW_OP_REG31:
		number = u64(operation - DW_OP_REG0)
	case operation == DW_OP_REGX:
		number = dwarf_leb128(&reader, false)
	case operation >= DW_OP_BREG0 && operation <= DW_OP_BREG31:
		in_memory = true
		number = u64(operation - DW_OP_BREG0)
		offset = i64(dwarf_leb128(&reader, true))
	case operation == DW_OP_BREGX:
		in_memory = true
		number = dwarf_leb128(&reader, false)
		offset = i64(dwarf_leb128(&reader, true))
	case operation == DW_OP_FBREG:
		if !frame_base_is_frame_pointer {
			return {}
		}
		in_memory = true
		number = 6
		offset = i64(dwarf_leb128(&reader, true))
	case:
		return {}
	}
	// One operation only: a second one changes the meaning of the first.
	if reader.failed || reader.at != len(expression) || number >= u64(len(dwarf_register_order)) || offset < i64(min(i32)) || offset > i64(max(i32)) {
		return {}
	}
	found.register = dwarf_register_order[number]
	found.offset = i32(offset)
	switch {
	case !in_memory:
		found.location = .Register
	case found.register == debug_object.FRAME_POINTER_REGISTER:
		found.location = .Frame_Pointer_Offset
	case found.register == debug_object.STACK_POINTER_REGISTER:
		found.location = .Stack_Pointer_Offset
	case:
		found.location = .Register_Offset
	}
	return found
}

// One entry of a location list: a range of addresses and its expression.
Dwarf_Address_Range :: struct {
	start:      u64,
	end:        u64,
	expression: []u8,
}

// dwarf_address_list_read reads a location list of .debug_loc
// (`with_expressions`) or a range list of .debug_ranges, of DWARF 2 to 4:
// pairs of addresses from the base address of the unit, up to a pair of
// zeros. A pair whose first address is the largest address gives a new
// base.
dwarf_address_list_read :: proc(section: []u8, offset: u64, unit: Dwarf_Unit, with_expressions: bool, section_name: string) -> (list: []Dwarf_Address_Range, error: string) {
	if offset >= u64(len(section)) {
		return nil, fmt.tprintf("an entry names the list at 0x%x, outside %s", offset, section_name)
	}
	result := make([dynamic]Dwarf_Address_Range, context.temp_allocator)
	reader := Dwarf_Reader{bytes = section, at = int(offset)}
	base := unit.base_address
	largest := unit.address_size == 8 ? max(u64) : u64(max(u32))
	for {
		at := reader.at
		start := dwarf_unsigned(&reader, unit.address_size)
		end := dwarf_unsigned(&reader, unit.address_size)
		if reader.failed {
			return nil, fmt.tprintf("%s is cut at 0x%x, in the list at 0x%x", section_name, at, offset)
		}
		if start == 0 && end == 0 {
			return result[:], ""
		}
		if start == largest {
			base = end
			continue
		}
		item := Dwarf_Address_Range{start = base + start, end = base + end}
		if with_expressions {
			item.expression = dwarf_bytes(&reader, int(dwarf_unsigned(&reader, 2)))
			if reader.failed {
				return nil, fmt.tprintf("%s is cut at 0x%x, in the expression of the list at 0x%x", section_name, at, offset)
			}
		}
		append(&result, item)
	}
}

// The state of the extraction of the types and the variables of one
// linked file.
Debug_Extraction :: struct {
	information:   ^Dwarf_Entries,
	locations:     []u8, // .debug_loc
	ranges:        []u8, // .debug_ranges
	types:         [dynamic]Debug_Type,
	type_of_entry: map[int]int,
	globals:       [dynamic]Debug_Global,
	variables:     [dynamic]Debug_Variable,
}

// dwarf_value_is_list says if an attribute names a list of another
// section. The versions 2 and 3 of DWARF give such an offset the form of a
// constant of 4 or 8 bytes.
dwarf_value_is_list :: proc(value: Dwarf_Value, unit: Dwarf_Unit) -> bool {
	return value.class == .Section_Offset || (unit.version < 4 && value.class == .Number && (value.form == DW_FORM_DATA4 || value.form == DW_FORM_DATA8))
}

// debug_type_of_reference gives the type that an entry names with its
// attribute of the type, or 0.
debug_type_of_reference :: proc(state: ^Debug_Extraction, entry_index: int, depth: int) -> int {
	holder := dwarf_declaration_of(state.information, entry_index, DW_AT_TYPE)
	if holder < 0 {
		return 0
	}
	target, found := dwarf_referenced_entry(state.information, holder, DW_AT_TYPE)
	if !found {
		return 0
	}
	return debug_type_of_entry(state, target, depth + 1)
}

// dwarf_entry_is_signed_integer says if a type entry is a signed integer,
// through its typedefs.
dwarf_entry_is_signed_integer :: proc(information: ^Dwarf_Entries, entry_index: int) -> bool {
	current := entry_index
	for _ in 0 ..< DWARF_CHAIN_LIMIT {
		if information.entries[current].tag == DW_TAG_BASE_TYPE {
			encoding, _ := dwarf_number_of(information, current, DW_AT_ENCODING)
			return encoding == DW_ATE_SIGNED || encoding == DW_ATE_SIGNED_CHAR
		}
		next, found := dwarf_referenced_entry(information, current, DW_AT_TYPE)
		if !found {
			return false
		}
		current = next
	}
	return false
}

// debug_type_of_entry gives the type of a type entry, and makes it at its
// first use. The type has its index before the tool reads what it names:
// a record that names itself through a pointer ends.
debug_type_of_entry :: proc(state: ^Debug_Extraction, entry_index: int, depth: int) -> int {
	if known, is_known := state.type_of_entry[entry_index]; is_known {
		return known
	}
	if depth > DWARF_DEPTH_LIMIT {
		return 0
	}
	information := state.information
	index := len(state.types)
	append(&state.types, Debug_Type{})
	state.type_of_entry[entry_index] = index
	entry := information.entries[entry_index]
	unit := information.units[entry.unit]
	byte_size, has_byte_size := dwarf_number_of(information, entry_index, DW_AT_BYTE_SIZE)
	result := Debug_Type {
		name = dwarf_text_of(information, entry_index, DW_AT_NAME),
		size = byte_size,
		kind = .Other,
	}
	switch entry.tag {
	case DW_TAG_BASE_TYPE:
		encoding, _ := dwarf_number_of(information, entry_index, DW_AT_ENCODING)
		switch encoding {
		case DW_ATE_BOOLEAN:
			result.kind = .Boolean
		case DW_ATE_FLOAT:
			result.kind = .Float
		case DW_ATE_SIGNED, DW_ATE_SIGNED_CHAR:
			result.kind = .Signed_Integer
		case DW_ATE_UNSIGNED, DW_ATE_UNSIGNED_CHAR, DW_ATE_UTF:
			result.kind = .Unsigned_Integer
		}
	case DW_TAG_POINTER_TYPE:
		if !has_byte_size {
			result.size = u64(unit.address_size)
		}
		target, has_target := dwarf_referenced_entry(information, entry_index, DW_AT_TYPE)
		if has_target && information.entries[target].tag == DW_TAG_SUBROUTINE_TYPE {
			result.kind = .Procedure_Address
		} else {
			result.kind = .Pointer
			result.element = has_target ? debug_type_of_entry(state, target, depth + 1) : 0
		}
	case DW_TAG_TYPEDEF, DW_TAG_CONST_TYPE, DW_TAG_VOLATILE_TYPE, DW_TAG_RESTRICT_TYPE:
		result.alias = true
		result.element = debug_type_of_reference(state, entry_index, depth)
	case DW_TAG_STRUCTURE_TYPE, DW_TAG_UNION_TYPE:
		result.kind = entry.tag == DW_TAG_UNION_TYPE ? debug_object.Type_Kind.Union : debug_object.Type_Kind.Record
		fields := make([dynamic]Debug_Field, context.temp_allocator)
		for child := entry_index + 1; child < entry.end; child = information.entries[child].end {
			if information.entries[child].tag != DW_TAG_MEMBER {
				continue
			}
			field := Debug_Field {
				name = dwarf_text_of(information, child, DW_AT_NAME),
				type = debug_type_of_reference(state, child, depth),
			}
			member_offset, has_member_offset := dwarf_value_of(information, child, DW_AT_DATA_MEMBER_LOCATION)
			switch {
			case !has_member_offset:
			case member_offset.class == .Number:
				field.offset = member_offset.number
			case member_offset.class == .Block && len(member_offset.block) > 1 && member_offset.block[0] == DW_OP_PLUS_UCONST:
				// The versions 2 and 3: the offset as an expression.
				block_reader := Dwarf_Reader{bytes = member_offset.block, at = 1}
				field.offset = dwarf_leb128(&block_reader, false)
				if block_reader.failed || block_reader.at != len(member_offset.block) {
					result.kind = .Other
				}
			case:
				// An offset that the tool cannot know: the record keeps
				// its name and its size only.
				result.kind = .Other
			}
			if bit_size, has_bits := dwarf_number_of(information, child, DW_AT_BIT_SIZE); has_bits {
				bit_offset, has_bit_offset := dwarf_number_of(information, child, DW_AT_DATA_BIT_OFFSET)
				_, has_old_bit_offset := dwarf_value_of(information, child, DW_AT_BIT_OFFSET)
				if has_old_bit_offset || bit_size == 0 || bit_size > u64(max(u16)) {
					result.kind = .Other
				} else {
					if has_bit_offset {
						field.offset += bit_offset / 8
						field.bit_shift = u16(bit_offset % 8)
					}
					field.bit_size = u16(bit_size)
				}
			}
			append(&fields, field)
		}
		if result.kind != .Other {
			result.fields = fields[:]
		}
		// The two built types that the compiler writes as records.
		has_data_and_count := len(fields) == 2 && fields[0].name == "data" && fields[1].name == "len"
		if result.kind == .Record && has_data_and_count && result.name == "string" {
			result.kind = .String
		} else if result.kind == .Record && has_data_and_count && strings.has_prefix(result.name, "[]") {
			result.kind = .Slice
		}
	case DW_TAG_ENUMERATION_TYPE:
		result.kind = .Enumeration
		result.element = debug_type_of_reference(state, entry_index, depth)
		base, has_base := dwarf_referenced_entry(information, entry_index, DW_AT_TYPE)
		is_signed := has_base && dwarf_entry_is_signed_integer(information, base)
		values := make([dynamic]Debug_Enumeration_Value, context.temp_allocator)
		for child := entry_index + 1; child < entry.end; child = information.entries[child].end {
			if information.entries[child].tag != DW_TAG_ENUMERATOR {
				continue
			}
			constant, has_constant := dwarf_value_of(information, child, DW_AT_CONST_VALUE)
			number := has_constant && constant.class == .Number ? constant.number : 0
			// A constant of a fixed size has no sign of its own.
			if is_signed {
				switch constant.form {
				case DW_FORM_DATA1:
					number = u64(i64(i8(number)))
				case DW_FORM_DATA2:
					number = u64(i64(i16(number)))
				case DW_FORM_DATA4:
					number = u64(i64(i32(number)))
				}
			}
			append(&values, Debug_Enumeration_Value{name = dwarf_text_of(information, child, DW_AT_NAME), value = number})
		}
		result.values = values[:]
	case DW_TAG_ARRAY_TYPE:
		result.kind = .Array
		result.element = debug_type_of_reference(state, entry_index, depth)
		result.size_from_elements = !has_byte_size
		// An array of several dimensions is the product of their counts
		// of elements of its type.
		result.count = 1
		dimensions := 0
		for child := entry_index + 1; child < entry.end; child = information.entries[child].end {
			if information.entries[child].tag != DW_TAG_SUBRANGE_TYPE {
				continue
			}
			dimensions += 1
			count, has_count := dwarf_number_of(information, child, DW_AT_COUNT)
			if !has_count {
				upper, has_upper := dwarf_number_of(information, child, DW_AT_UPPER_BOUND)
				count, has_count = upper + 1, has_upper && upper != max(u64)
			}
			if !has_count || (count != 0 && result.count > u64(max(u32)) / count) {
				// A count that the entry does not give, or that no array holds.
				result.kind = .Other
				result.count = 0
				result.size_from_elements = false
				break
			}
			result.count *= count
		}
		if dimensions == 0 && result.kind == .Array {
			result.kind = .Other
			result.count = 0
			result.size_from_elements = false
		}
		if result.kind == .Other {
			result.element = 0
		}
	}
	state.types[index] = result
	return index
}

// dwarf_scope_ranges gives the ranges of addresses of the scope that holds
// a variable: its lexical block, the procedure that the compiler put
// inside another one, or its procedure. A block with no range of its own
// has the ranges of the scope around it. `in_procedure` is false for a
// variable that no procedure holds (a variable of the unit, a parameter
// of a procedure type).
dwarf_scope_ranges :: proc(state: ^Debug_Extraction, entry_index: int) -> (ranges: []Dwarf_Address_Range, in_procedure: bool, error: string) {
	information := state.information
	current := information.entries[entry_index].parent
	for _ in 0 ..< DWARF_DEPTH_LIMIT {
		if current < 0 {
			return nil, false, ""
		}
		scope := information.entries[current]
		if scope.tag != DW_TAG_SUBPROGRAM && scope.tag != DW_TAG_INLINED_SUBROUTINE && scope.tag != DW_TAG_LEXICAL_BLOCK {
			return nil, false, ""
		}
		unit := information.units[scope.unit]
		if low, has_low := dwarf_value_of(information, current, DW_AT_LOW_PC); has_low && low.class == .Address {
			high, has_high := dwarf_value_of(information, current, DW_AT_HIGH_PC)
			end := low.number
			if has_high && high.class == .Address {
				end = high.number
			} else if has_high && high.class == .Number {
				end = low.number + high.number
			}
			one := make([]Dwarf_Address_Range, 1, context.temp_allocator)
			one[0] = {start = low.number, end = end}
			return one, true, ""
		}
		if list, has_list := dwarf_value_of(information, current, DW_AT_RANGES); has_list && dwarf_value_is_list(list, unit) {
			ranges, error = dwarf_address_list_read(state.ranges, list.number, unit, false, ".debug_ranges")
			return ranges, true, error
		}
		if scope.tag != DW_TAG_LEXICAL_BLOCK {
			// A procedure with no address: a declaration, or the abstract
			// instance of a procedure that the compiler put inside others.
			return nil, true, ""
		}
		current = scope.parent
	}
	return nil, false, ""
}

// dwarf_frame_base_is_frame_pointer says if the procedure that holds an
// entry gives the register rbp as its frame base: then a location "frame base
// plus a constant" is rbp plus that constant.
dwarf_frame_base_is_frame_pointer :: proc(information: ^Dwarf_Entries, entry_index: int) -> bool {
	current := information.entries[entry_index].parent
	for _ in 0 ..< DWARF_DEPTH_LIMIT {
		if current < 0 {
			return false
		}
		if information.entries[current].tag == DW_TAG_SUBPROGRAM {
			base, has_base := dwarf_value_of(information, current, DW_AT_FRAME_BASE)
			return has_base && base.class == .Block && len(base.block) == 1 && base.block[0] == DW_OP_REG0 + 6
		}
		current = information.entries[current].parent
	}
	return false
}

// dwarf_entry_is_at_inline_site says if a variable is of a procedure that
// the compiler put inside another one: the scope around its blocks is an
// inline site, not a procedure.
dwarf_entry_is_at_inline_site :: proc(information: ^Dwarf_Entries, entry_index: int) -> bool {
	current := information.entries[entry_index].parent
	for _ in 0 ..< DWARF_DEPTH_LIMIT {
		if current < 0 {
			return false
		}
		if information.entries[current].tag != DW_TAG_LEXICAL_BLOCK {
			return information.entries[current].tag == DW_TAG_INLINED_SUBROUTINE
		}
		current = information.entries[current].parent
	}
	return false
}

// elf_address_is_in_memory says if an address is in a section that the
// module keeps in memory. A variable that the link dropped has the address
// 0 or another address outside each section.
elf_address_is_in_memory :: proc(sections: []Elf_Section_Header, address: u64) -> bool {
	for section in sections {
		if section.flags & ELF_SECTION_FLAG_ALLOCATED != 0 && section.address != 0 && address >= section.address && address - section.address < section.size {
			return true
		}
	}
	return false
}

// debug_information_from_dwarf gives the types, the global variables and
// the variables of the procedures of a linked file, from its sections of
// DWARF. `sections` are the section headers of the file: a global is kept
// when its address is in the memory of the module.
debug_information_from_dwarf :: proc(units, abbreviations, debug_strings, locations, ranges: []u8, sections: []Elf_Section_Header) -> (result: Debug_Information, error: string) {
	context.allocator = context.temp_allocator
	information, entries_error := dwarf_entries_read(units, abbreviations, debug_strings)
	if entries_error != "" {
		return {}, entries_error
	}
	state := Debug_Extraction {
		information   = &information,
		locations     = locations,
		ranges        = ranges,
		types         = make([dynamic]Debug_Type),
		type_of_entry = make(map[int]int),
		globals       = make([dynamic]Debug_Global),
		variables     = make([dynamic]Debug_Variable),
	}
	append(&state.types, Debug_Type{}) // The type 0.
	for entry, entry_index in information.entries {
		if entry.tag != DW_TAG_VARIABLE && entry.tag != DW_TAG_FORMAL_PARAMETER {
			continue
		}
		unit := information.units[entry.unit]
		name_holder := dwarf_declaration_of(&information, entry_index, DW_AT_NAME)
		name := name_holder >= 0 ? dwarf_text_of(&information, name_holder, DW_AT_NAME) : ""
		if name == "" {
			continue
		}
		location_value, has_location := dwarf_value_of(&information, entry_index, DW_AT_LOCATION)
		found: Debug_Variable_Location
		if has_location && location_value.class == .Block {
			found = dwarf_location_of_expression(location_value.block, unit.address_size, dwarf_frame_base_is_frame_pointer(&information, entry_index))
			if found.is_address {
				// One address for the whole run: a global variable, or a
				// static variable of a procedure.
				if elf_address_is_in_memory(sections, found.address) {
					append(&state.globals, Debug_Global{name = name, address = found.address, type = debug_type_of_reference(&state, entry_index, 0)})
				}
				continue
			}
		}
		scope_ranges, in_procedure, scope_error := dwarf_scope_ranges(&state, entry_index)
		if scope_error != "" {
			return {}, scope_error
		}
		if !in_procedure {
			continue
		}
		variable := Debug_Variable {
			name = name,
			role = entry.tag == DW_TAG_FORMAL_PARAMETER ? debug_object.Variable_Role.Parameter : debug_object.Variable_Role.Local,
			type = debug_type_of_reference(&state, entry_index, 0),
			inlined = dwarf_entry_is_at_inline_site(&information, entry_index),
		}
		if has_location && dwarf_value_is_list(location_value, unit) {
			// A location for each range of the list.
			list, list_error := dwarf_address_list_read(locations, location_value.number, unit, true, ".debug_loc")
			if list_error != "" {
				return {}, list_error
			}
			frame_base_is_frame_pointer := dwarf_frame_base_is_frame_pointer(&information, entry_index)
			for item in list {
				item_location := dwarf_location_of_expression(item.expression, unit.address_size, frame_base_is_frame_pointer)
				if item_location.is_address {
					item_location = {}
				}
				variable.location, variable.register, variable.offset = item_location.location, item_location.register, item_location.offset
				variable.start, variable.end = item.start, item.end
				append(&state.variables, variable)
			}
			// Where the variable is visible: its scope, with no location.
			variable.location = .Not_Readable
			variable.register = 0
			variable.offset = 0
			for scope_range in scope_ranges {
				variable.start, variable.end = scope_range.start, scope_range.end
				append(&state.variables, variable)
			}
			continue
		}
		// One location, or none, for the whole scope.
		variable.location, variable.register, variable.offset = found.location, found.register, found.offset
		for scope_range in scope_ranges {
			variable.start, variable.end = scope_range.start, scope_range.end
			append(&state.variables, variable)
		}
	}
	return {types = state.types[:], globals = state.globals[:], variables = state.variables[:]}, ""
}

// debug_type_key writes the text that names a type in the order of the
// type table: its kind, its size, its count and its name. A type with no
// name (a pointer, an array) has the key of its element inside its own.
debug_type_key :: proc(builder: ^strings.Builder, types: []Debug_Type, index: int, depth: int) {
	if index == 0 {
		strings.write_string(builder, "none")
		return
	}
	type := types[index]
	fmt.sbprintf(builder, "%d:%d:%d:%s", int(type.kind), type.size, type.count, type.name)
	if type.name == "" && depth < DWARF_CHAIN_LIMIT {
		strings.write_string(builder, "(")
		debug_type_key(builder, types, type.element, depth + 1)
		strings.write_string(builder, ")")
	}
}

// debug_type_whole_key gives the text that orders a type and tells it from
// each other type: its key, the key of its element, each field with its
// offset and the key of its type, and each named value.
debug_type_whole_key :: proc(types: []Debug_Type, index: int) -> string {
	builder := strings.builder_make(context.temp_allocator)
	debug_type_key(&builder, types, index, 0)
	type := types[index]
	strings.write_string(&builder, " of ")
	debug_type_key(&builder, types, type.element, 0)
	for field in type.fields {
		fmt.sbprintf(&builder, " field %s at %d bits %d %d is ", field.name, field.offset, field.bit_shift, field.bit_size)
		debug_type_key(&builder, types, field.type, 0)
	}
	for named in type.values {
		fmt.sbprintf(&builder, " value %s is %d", named.name, named.value)
	}
	return strings.to_string(builder)
}

// debug_types_in_fixed_order gives the types that the globals and the
// variables use, in the order of the type table, and the index of each
// type of the source in that order (0: the type is not used).
//
// The order does not depend on the order of the entries of DWARF: the
// types are sorted by a text made of their content, and two types with
// the same text are one type. So two builds give the same table. A
// typedef becomes a copy of its type with its own name, and an array with
// no size takes the size of its elements.
debug_types_in_fixed_order :: proc(source: []Debug_Type, globals: []Debug_Global, variables: []Debug_Variable) -> (ordered: []Debug_Type, index_of: []int, error: string) {
	context.allocator = context.temp_allocator
	count := max(len(source), 1)
	types := make([]Debug_Type, count)
	copy(types, source)
	types[0] = {}
	index_of = make([]int, count)
	reference_is_valid :: proc(reference: int, limit: int) -> bool {
		return reference >= 0 && reference < limit
	}
	for type, index in types {
		if !reference_is_valid(type.element, count) {
			return nil, nil, fmt.tprintf("the type %d (%s) names the type %d, which the list does not have", index, type.name, type.element)
		}
		for field in type.fields {
			if !reference_is_valid(field.type, count) {
				return nil, nil, fmt.tprintf("the field %s of the type %d (%s) names the type %d, which the list does not have", field.name, index, type.name, field.type)
			}
		}
	}
	// A typedef becomes a copy of the type at the end of its chain.
	resolved := make([]Debug_Type, count)
	for type, index in types {
		if !type.alias {
			resolved[index] = type
			continue
		}
		target := type.element
		hops := 0
		for types[target].alias {
			target = types[target].element
			hops += 1
			if hops > DWARF_CHAIN_LIMIT {
				return nil, nil, fmt.tprintf("the type %d (%s) is another name of itself", index, type.name)
			}
		}
		if target == 0 {
			// Another name of "no type".
			resolved[index] = {name = type.name, kind = .Other}
		} else {
			resolved[index] = types[target]
			if type.name != "" {
				resolved[index].name = type.name
			}
		}
	}
	// A slice names its element through the pointer of its first field.
	for &type in resolved {
		if type.kind == .Slice && type.element == 0 && len(type.fields) > 0 && resolved[type.fields[0].type].kind == .Pointer {
			type.element = resolved[type.fields[0].type].element
		}
	}
	// The size of an array with no size of its own. An array of arrays
	// needs the size of the inner one first: one pass for each level.
	for _ in 0 ..< DWARF_CHAIN_LIMIT {
		changed := false
		for &type in resolved {
			if type.kind != .Array || !type.size_from_elements || resolved[type.element].size_from_elements {
				continue
			}
			element_size := resolved[type.element].size
			if element_size != 0 && type.count > u64(max(u32)) / element_size {
				return nil, nil, fmt.tprintf("the array %s of %d elements of %d bytes is larger than a debug object describes", type.name, type.count, element_size)
			}
			type.size = type.count * element_size
			type.size_from_elements = false
			changed = true
		}
		if !changed {
			break
		}
	}
	// The types that a global or a variable uses, and those that they name.
	used := make([]bool, count)
	pending := make([dynamic]int)
	for global in globals {
		if !reference_is_valid(global.type, count) {
			return nil, nil, fmt.tprintf("the global %s names the type %d, which the list does not have", global.name, global.type)
		}
		append(&pending, global.type)
	}
	for variable in variables {
		if !reference_is_valid(variable.type, count) {
			return nil, nil, fmt.tprintf("the variable %s names the type %d, which the list does not have", variable.name, variable.type)
		}
		append(&pending, variable.type)
	}
	for len(pending) > 0 {
		index := pop(&pending)
		if index == 0 || used[index] {
			continue
		}
		used[index] = true
		append(&pending, resolved[index].element)
		for field in resolved[index].fields {
			append(&pending, field.type)
		}
	}
	Keyed :: struct {
		key:   string,
		index: int,
	}
	keyed := make([dynamic]Keyed)
	for index in 1 ..< count {
		if used[index] {
			append(&keyed, Keyed{key = debug_type_whole_key(resolved, index), index = index})
		}
	}
	slice.sort_by(keyed[:], proc(a, b: Keyed) -> bool {
		return a.key < b.key
	})
	result := make([dynamic]Debug_Type)
	append(&result, Debug_Type{})
	for item, position in keyed {
		if position == 0 || keyed[position - 1].key != item.key {
			append(&result, resolved[item.index])
		}
		index_of[item.index] = len(result) - 1
	}
	// The references, in the new order. The fields are copied: two types
	// of the source can share them.
	for &type in result[1:] {
		type.element = index_of[type.element]
		fields := make([]Debug_Field, len(type.fields))
		for field, number in type.fields {
			fields[number] = field
			fields[number].type = index_of[field.type]
		}
		type.fields = fields
	}
	return result[:], index_of, ""
}
