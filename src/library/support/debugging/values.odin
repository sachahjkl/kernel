package debugging

import debug_object "modus:contract/debug_object"
import "modus:support/sentence"

// The bounds of the text of one value.
VALUE_DEPTH_LIMIT :: 3 // A record in a record in a record: a deeper one is written "{...}". A type can name itself.
ARRAY_ELEMENTS_SHOWN :: 8 // The elements of an array in the text of one value.
RECORD_FIELDS_SHOWN :: 8 // The fields of a record in the text of one value.
STRING_BYTES_SHOWN :: 64 // The bytes of a string that a second read of memory takes.
ENUMERATION_VALUES_SEARCHED :: 4096 // The named values of one enumeration that a search reads.

// Names an address of the debugged program: the procedure or the global
// that holds it. `write` adds nothing when it knows no name.
Address_Namer :: struct {
	write: proc "contextless" (state: rawptr, writer: ^sentence.Writer, address: u64),
	state: rawptr,
}

// What the text of a value needs: the debug object of the types, the
// memory of the program, and the names of its addresses.
Value_Context :: struct {
	object: []u8, // The debug object of the module of the type, after its check.
	reader: Memory_Reader,
	namer:  Address_Namer, // Its `write` can be nil.
}

// located_bytes reads the first bytes of a value: from memory, or from the
// bytes of its register (8 at most).
located_bytes :: proc "contextless" (ctx: ^Value_Context, located: Located, into: []u8) -> bool {
	if located.in_memory {
		return memory_read(ctx.reader, located.address, into)
	}
	if len(into) > len(located.bytes) {
		return false
	}
	bytes := located.bytes
	copy(into, bytes[:len(into)])
	return true
}

// located_integer reads a value of 1, 2, 4 or 8 bytes as a number, with
// the bits of a field of bits taken out. `signed` extends its sign.
located_integer :: proc "contextless" (ctx: ^Value_Context, located: Located, size: u32, signed: bool) -> (value: u64, ok: bool) {
	if size == 0 || size > 8 {
		return 0, false
	}
	bytes: [8]u8
	if !located_bytes(ctx, located, bytes[:size]) {
		return 0, false
	}
	value = integer_of_bytes(bytes[:size])
	bits := uint(size) * 8
	if located.bit_size != 0 && uint(located.bit_size) < 64 && uint(located.bit_shift) < 64 {
		bits = uint(located.bit_size)
		value = value >> uint(located.bit_shift) & (u64(1) << bits - 1)
	}
	if signed && bits < 64 && value & (u64(1) << (bits - 1)) != 0 {
		value |= ~u64(0) << bits
	}
	return value, true
}

// type_name_write writes the name of a type: its own name, or its form
// from the type that it names ("^fault::Pair", "[4]u64", "[]u8").
type_name_write :: proc "contextless" (writer: ^sentence.Writer, object: []u8, type_index: u32, depth := 0) {
	type, found := debug_object.type_by_index(object, type_index)
	if !found {
		sentence.write_part(writer, "no type")
		return
	}
	if type.name != "" {
		sentence.write_part(writer, type.name)
		return
	}
	if depth >= VALUE_DEPTH_LIMIT {
		sentence.write_part(writer, "...")
		return
	}
	#partial switch type.kind {
	case .Pointer:
		if type.element == 0 {
			sentence.write_part(writer, "rawptr")
			return
		}
		sentence.write_part(writer, "^")
		type_name_write(writer, object, type.element, depth + 1)
	case .Array:
		sentence.write_part(writer, "[")
		sentence.write_part(writer, u64(type.count))
		sentence.write_part(writer, "]")
		type_name_write(writer, object, type.element, depth + 1)
	case .Slice:
		sentence.write_part(writer, "[]")
		type_name_write(writer, object, type.element, depth + 1)
	case .String:
		sentence.write_part(writer, "string")
	case .Record:
		sentence.write_part(writer, "struct")
	case .Union:
		sentence.write_part(writer, "union")
	case .Enumeration:
		sentence.write_part(writer, "enum")
	case .Procedure_Address:
		sentence.write_part(writer, "proc")
	case:
		sentence.write_part(writer, u64(type.size))
		sentence.write_part(writer, " bytes")
	}
}

// address_write writes an address as "0x" and 16 digits, then the name
// that the namer gives it, in parentheses.
address_write :: proc "contextless" (writer: ^sentence.Writer, ctx: ^Value_Context, address: u64) {
	sentence.write_part(writer, "0x")
	sentence.write_hex(writer, address)
	if ctx.namer.write == nil {
		return
	}
	before := writer.count
	sentence.write_part(writer, " (")
	named := writer.count
	ctx.namer.write(ctx.namer.state, writer, address)
	if writer.count == named && writer.dropped == 0 {
		sentence.writer_take_back(writer, before) // No name: the parenthesis leaves.
		return
	}
	sentence.write_part(writer, ")")
}

// The two words of a slice or of a string: the address of its first
// element and the count of its elements.
@(private)
slice_words :: proc "contextless" (ctx: ^Value_Context, located: Located) -> (address: u64, count: u64, ok: bool) {
	if !located.in_memory {
		return 0, 0, false
	}
	// The field table gives the two fields: the address is the field of a
	// pointer type, the count the other one.
	address_offset, count_offset := u64(0), u64(8)
	for number in 0 ..< u32(2) {
		field, found := debug_object.field_of_type(ctx.object, located.type, number)
		if !found {
			break
		}
		field_type, _ := debug_object.type_by_index(ctx.object, field.type)
		if field_type.kind == .Pointer {
			address_offset = u64(field.offset)
		} else {
			count_offset = u64(field.offset)
		}
	}
	address = memory_word(ctx.reader, located.address + address_offset) or_return
	count = memory_word(ctx.reader, located.address + count_offset) or_return
	return address, count, true
}

// value_write writes the text of a value by the kind of its type:
//
// - an integer in decimal, with its sign; a boolean as `true` or `false`;
// - a float as its bits in hexadecimal ("float bits 0x..."): the system
//   has no code that writes a float in decimal;
// - a pointer and the address of a procedure as an address, with the
//   procedure or the global that holds it; a pointer of 0 as `nil`. It
//   does not follow the pointer;
// - an enumeration by the name of its value, or its number with "(no
//   name)";
// - a record as `{field = value, ...}`, at most RECORD_FIELDS_SHOWN fields
//   and VALUE_DEPTH_LIMIT records deep;
// - an array as `[value, ...]`, at most ARRAY_ELEMENTS_SHOWN elements, then
//   its count;
// - a string by a second read of memory, at most STRING_BYTES_SHOWN bytes,
//   in quotes, with "." for a byte that is not printable;
// - a slice as its count and its address;
// - each other type as its size.
//
// A value whose bytes the program does not map is "not readable".
value_write :: proc "contextless" (writer: ^sentence.Writer, ctx: ^Value_Context, located: Located, depth := 0) {
	type, found := debug_object.type_by_index(ctx.object, located.type)
	if !found {
		sentence.write_part(writer, "no type")
		return
	}
	#partial switch type.kind {
	case .Signed_Integer:
		value, ok := located_integer(ctx, located, type.size, true)
		if !ok {
			unreadable_write(writer, type.size)
			return
		}
		sentence.write_part(writer, i64(value))
	case .Unsigned_Integer:
		value, ok := located_integer(ctx, located, type.size, false)
		if !ok {
			unreadable_write(writer, type.size)
			return
		}
		sentence.write_part(writer, value)
	case .Boolean:
		value, ok := located_integer(ctx, located, type.size, false)
		if !ok {
			unreadable_write(writer, type.size)
			return
		}
		text: string = value != 0 ? "true" : "false"
		sentence.write_part(writer, text)
	case .Float:
		value, ok := located_integer(ctx, located, type.size, false)
		if !ok {
			unreadable_write(writer, type.size)
			return
		}
		sentence.write_part(writer, "float bits 0x")
		sentence.write_hex(writer, value, int(type.size) * 2)
	case .Pointer, .Procedure_Address:
		value, ok := located_integer(ctx, located, 8, false)
		if !ok || type.size != 8 {
			unreadable_write(writer, type.size)
			return
		}
		if value == 0 {
			sentence.write_part(writer, "nil")
			return
		}
		address_write(writer, ctx, value)
	case .Enumeration:
		backing, _ := debug_object.type_by_index(ctx.object, type.element)
		value, ok := located_integer(ctx, located, type.size, backing.kind == .Signed_Integer)
		if !ok {
			unreadable_write(writer, type.size)
			return
		}
		for number in 0 ..< min(type.count, ENUMERATION_VALUES_SEARCHED) {
			name, named_value, has := debug_object.enumeration_value_of_type(ctx.object, located.type, number)
			if !has {
				break
			}
			if named_value == value {
				sentence.write_part(writer, name)
				return
			}
		}
		if backing.kind == .Signed_Integer {
			sentence.write_part(writer, i64(value))
		} else {
			sentence.write_part(writer, value)
		}
		sentence.write_part(writer, " (no name)")
	case .Record:
		if depth >= VALUE_DEPTH_LIMIT {
			sentence.write_part(writer, "{...}")
			return
		}
		sentence.write_part(writer, "{")
		for number in 0 ..< type.count {
			if number == RECORD_FIELDS_SHOWN {
				sentence.write_part(writer, ", ... ")
				sentence.write_part(writer, u64(type.count))
				sentence.write_part(writer, " fields")
				break
			}
			part, name, has := record_field(ctx, located, number)
			if !has {
				break
			}
			if number > 0 {
				sentence.write_part(writer, ", ")
			}
			sentence.write_part(writer, name)
			sentence.write_part(writer, " = ")
			value_write(writer, ctx, part, depth + 1)
		}
		sentence.write_part(writer, "}")
	case .Array:
		if depth >= VALUE_DEPTH_LIMIT {
			sentence.write_part(writer, "[...]")
			return
		}
		sentence.write_part(writer, "[")
		for number in 0 ..< type.count {
			if number == ARRAY_ELEMENTS_SHOWN {
				sentence.write_part(writer, ", ... ")
				sentence.write_part(writer, u64(type.count))
				sentence.write_part(writer, " elements")
				break
			}
			part, has := array_element(ctx, located, type, u64(number))
			if !has {
				break
			}
			if number > 0 {
				sentence.write_part(writer, ", ")
			}
			value_write(writer, ctx, part, depth + 1)
		}
		sentence.write_part(writer, "]")
	case .String:
		address, count, ok := slice_words(ctx, located)
		if !ok {
			unreadable_write(writer, type.size)
			return
		}
		bytes: [STRING_BYTES_SHOWN]u8
		shown := int(min(count, STRING_BYTES_SHOWN))
		if !memory_read(ctx.reader, address, bytes[:shown]) {
			sentence.write_part(writer, "a string of ")
			sentence.write_part(writer, count)
			sentence.write_part(writer, " bytes at 0x")
			sentence.write_hex(writer, address)
			sentence.write_part(writer, ", not readable")
			return
		}
		for &b in bytes[:shown] {
			if b < 0x20 || b > 0x7E {
				b = '.'
			}
		}
		sentence.write_part(writer, "\"")
		sentence.write_part(writer, string(bytes[:shown]))
		sentence.write_part(writer, "\"")
		if count > u64(shown) {
			sentence.write_part(writer, " (the first ")
			sentence.write_part(writer, u64(shown))
			sentence.write_part(writer, " of ")
			sentence.write_part(writer, count)
			sentence.write_part(writer, " bytes)")
		}
	case .Slice:
		address, count, ok := slice_words(ctx, located)
		if !ok {
			unreadable_write(writer, type.size)
			return
		}
		sentence.write_part(writer, count)
		sentence.write_part(writer, " elements at 0x")
		sentence.write_hex(writer, address)
	case:
		what: string = type.kind == .Union ? "a union of " : "a value of "
		sentence.write_part(writer, what)
		sentence.write_part(writer, u64(type.size))
		sentence.write_part(writer, " bytes")
	}
}

@(private)
unreadable_write :: proc "contextless" (writer: ^sentence.Writer, size: u32) {
	sentence.write_part(writer, "not readable")
	if size != 1 && size != 2 && size != 4 && size != 8 {
		sentence.write_part(writer, " (")
		sentence.write_part(writer, u64(size))
		sentence.write_part(writer, " bytes)")
	}
}

// record_field gives the field `number` of a record value, with its name.
// A value in a register gives only a field inside its 8 bytes.
record_field :: proc "contextless" (ctx: ^Value_Context, located: Located, number: u32) -> (part: Located, name: string, found: bool) {
	field := debug_object.field_of_type(ctx.object, located.type, number) or_return
	part = {type = field.type, bit_shift = field.bit_shift, bit_size = field.bit_size}
	if located.in_memory {
		part.in_memory = true
		part.address = located.address + u64(field.offset)
		return part, field.name, true
	}
	if field.offset >= 8 {
		return {}, "", false
	}
	bytes := located.bytes
	copy(part.bytes[:], bytes[field.offset:])
	return part, field.name, true
}

// array_element gives the element `number` of an array value in memory.
@(private)
array_element :: proc "contextless" (ctx: ^Value_Context, located: Located, type: debug_object.Type_Description, number: u64) -> (part: Located, found: bool) {
	element, has := debug_object.type_by_index(ctx.object, type.element)
	if !has || !located.in_memory || number >= u64(type.count) {
		return {}, false
	}
	return {type = type.element, in_memory = true, address = located.address + number * u64(element.size)}, true
}

// Why a path names no value.
Resolve_Problem :: enum {
	None           = 0,
	No_Field       = 1, // The record has no field with the name of the step.
	Not_A_Record   = 2, // A field of a value that is not a record, a union, a slice or a string.
	Not_Indexable  = 3, // An index of a value that is not an array or a slice.
	Index_Past_End = 4, // An index that is not below the count of the elements.
	Not_A_Pointer  = 5, // A `^` after a value that is not a pointer, or after a pointer with no type.
	Nil_Pointer    = 6, // A step through a pointer of 0.
	Not_Readable   = 7, // The program does not map the bytes that a step reads.
}

// pointer_target gives the value that a pointer value points to.
@(private)
pointer_target :: proc "contextless" (ctx: ^Value_Context, located: Located, type: debug_object.Type_Description) -> (target: Located, problem: Resolve_Problem) {
	if type.kind != .Pointer || type.element == 0 {
		return {}, .Not_A_Pointer
	}
	address, read := located_integer(ctx, located, 8, false)
	if !read {
		return {}, .Not_Readable
	}
	if address == 0 {
		return {}, .Nil_Pointer
	}
	return {type = type.element, in_memory = true, address = address}, .None
}

// path_resolve follows the steps of a path from a value: the value of the
// variable or of the global that the path names. `step` is the number of
// the step, from 0, where a problem was found.
path_resolve :: proc "contextless" (ctx: ^Value_Context, start: Located, path: ^Path) -> (located: Located, problem: Resolve_Problem, step: int) {
	located = start
	for number in 0 ..< path.step_count {
		item := path.steps[number]
		type, has_type := debug_object.type_by_index(ctx.object, located.type)
		switch item.kind {
		case .Dereference:
			if !has_type {
				return {}, .Not_A_Pointer, number
			}
			located, problem = pointer_target(ctx, located, type)
			if problem != .None {
				return {}, problem, number
			}
		case .Field:
			// As in the language, the field of a pointer to a record is
			// the field of the record.
			if has_type && type.kind == .Pointer {
				located, problem = pointer_target(ctx, located, type)
				if problem != .None {
					return {}, problem, number
				}
				type, has_type = debug_object.type_by_index(ctx.object, located.type)
			}
			if !has_type || type.kind != .Record && type.kind != .Union && type.kind != .Slice && type.kind != .String {
				return {}, .Not_A_Record, number
			}
			found := false
			for field_number in 0 ..< type.count {
				part, name, has := record_field(ctx, located, field_number)
				if !has {
					break
				}
				if name == item.name {
					located, found = part, true
					break
				}
			}
			if !found {
				return {}, .No_Field, number
			}
		case .Index:
			if !has_type {
				return {}, .Not_Indexable, number
			}
			#partial switch type.kind {
			case .Array:
				part, has := array_element(ctx, located, type, item.index)
				if !has {
					return {}, located.in_memory ? .Index_Past_End : .Not_Indexable, number
				}
				located = part
			case .Slice:
				address, count, read := slice_words(ctx, located)
				element, has_element := debug_object.type_by_index(ctx.object, type.element)
				if !read {
					return {}, .Not_Readable, number
				}
				if !has_element {
					return {}, .Not_Indexable, number
				}
				if item.index >= count {
					return {}, .Index_Past_End, number
				}
				located = {type = type.element, in_memory = true, address = address + item.index * u64(element.size)}
			case:
				return {}, .Not_Indexable, number
			}
		}
	}
	return located, .None, 0
}

// The parts of one value that `value_part` gives, at most: the fields of a
// record, the elements of an array or of a slice.
VALUE_PART_LIMIT :: 64

// value_part gives the part `number` (from 0) of a value, with its name:
// the field of a record or of a union by its name, the element of an array
// or of a slice as "[number]". A value of another kind has one part,
// itself, with an empty name. `found` is false past the last part and
// past VALUE_PART_LIMIT parts. The name of an element is written in
// `name_buffer`.
value_part :: proc "contextless" (ctx: ^Value_Context, located: Located, number: u32, name_buffer: []u8) -> (part: Located, name: string, found: bool) {
	if number >= VALUE_PART_LIMIT {
		return {}, "", false
	}
	type, has_type := debug_object.type_by_index(ctx.object, located.type)
	if !has_type {
		return located, "", number == 0
	}
	element_name :: proc "contextless" (buffer: []u8, number: u32) -> string {
		writer := sentence.Writer{buffer = buffer}
		sentence.write_part(&writer, "[")
		sentence.write_part(&writer, u64(number))
		sentence.write_part(&writer, "]")
		return string(buffer[:writer.count])
	}
	#partial switch type.kind {
	case .Record, .Union:
		return record_field(ctx, located, number)
	case .Array:
		part, found = array_element(ctx, located, type, u64(number))
		return part, element_name(name_buffer, number), found
	case .Slice:
		address, count, read := slice_words(ctx, located)
		element, has_element := debug_object.type_by_index(ctx.object, type.element)
		if !read || !has_element || u64(number) >= count {
			return {}, "", false
		}
		return {type = type.element, in_memory = true, address = address + u64(number) * u64(element.size)}, element_name(name_buffer, number), true
	}
	return located, "", number == 0
}
