// The isolated call: a program calls an export of a module that runs in
// another program (property 19; docs/MODULE_CONTRACT.md, sections 4 and 5).
//
// The caller starts a call host: a program that loads one module and serves
// its exports. The call host receives two memory objects:
//
//   the call ring     a ring (package ring). One command record is one call.
//   the call region   memory that the two programs share. The caller writes
//                     the argument record and the bytes of its slices in it.
//
// The command record:
//   kind        the index of the export
//   tag         a number that the caller chooses; the completion record has it
//   values[0]   the offset of the argument record in the call region
//   values[1]   the size of the argument record, in bytes
//
// The completion record:
//   kind        a Status
//   values[0], values[1]   the integer results
//   values[2], values[3]   the float results
//
// The argument record is derived from the description of the export
// (module.Function). It has one field per parameter, in order:
//   Integer   8 bytes: the value.
//   Text      16 bytes: a Slice. In a direct call the register holds the
//             address of a slice record. An address has no meaning in another
//             program, so the field holds the slice record itself, and the
//             slice holds an offset in the call region.
//
// The receiver trusts nothing in the call region. It copies the argument
// record to private memory, and it checks each offset and each count
// against the size of the call region (decode).
//
// This package allocates no memory and calls no kernel operation.
package isolated

import module "../module"
import "base:intrinsics"

// The roles of the context of a call host.
GRANT_RING :: 0 // Memory: the call ring.
GRANT_REGION :: 1 // Memory: the call region.
VALUE_FILE_ADDRESS :: 0 // Where the caller mapped the file of the module, read-only.
VALUE_FILE_SIZE :: 1 // The size of the file, in bytes.

FILE_ADDRESS :: 0x0000_3000_0000_0000 // Where a caller maps the file of the module in the call host.
REGION_PAGES :: 16

Status :: enum u32 {
	Ok            = 0,
	Bad_Export    = 1, // The module has no export with this index, or the export has no description.
	Bad_Arguments = 2, // The argument record, or one of its slices, is not in the call region.
}

// In the call region, `start` is an offset. In a program, it is an address.
Slice :: struct {
	start: u64,
	count: u64,
}
#assert(size_of(Slice) == 16)

// One argument of a call, before it is encoded. The type of the parameter
// says which field has the value.
Argument :: struct {
	integer: u64,
	text:    []u8,
}

field_size :: proc "contextless" (type: module.Type) -> u64 {
	switch type {
	case .Integer:
		return 8
	case .Text:
		return size_of(Slice)
	case .None:
	}
	return 0
}

// record_size gives the size of the argument record of an export.
// ok is false when the description has a type that this code does not know.
record_size :: proc "contextless" (function: module.Function) -> (size: u64, ok: bool) {
	function := function
	if function.parameter_count > module.PARAMETER_CAPACITY {
		return 0, false
	}
	for type in function.parameters[:function.parameter_count] {
		field := field_size(type)
		if field == 0 {
			return 0, false
		}
		size += field
	}
	return size, true
}

@(private)
store :: proc "contextless" (region: []u8, offset: u64, value: $T) {
	value := value
	intrinsics.mem_copy_non_overlapping(raw_data(region[offset:]), &value, size_of(T))
}

@(private)
load :: proc "contextless" (region: []u8, offset: u64, $T: typeid) -> (value: T) {
	intrinsics.mem_copy_non_overlapping(&value, raw_data(region[offset:]), size_of(T))
	return value
}

// encode writes the argument record of a call at the start of the call
// region, and the bytes of each Text after it. The caller owns the call
// region: one call uses it at a time.
// ok is false when the arguments do not agree with the description, or when
// the call region is too small.
encode :: proc "contextless" (function: module.Function, arguments: []Argument, region: []u8) -> (offset, size: u64, ok: bool) {
	function := function
	size = record_size(function) or_return
	if len(arguments) != int(function.parameter_count) || size > u64(len(region)) {
		return 0, 0, false
	}
	field := u64(0)
	next := size // Where the bytes of the next Text go.
	for type, index in function.parameters[:function.parameter_count] {
		#partial switch type {
		case .Integer:
			store(region, field, arguments[index].integer)
		case .Text:
			text := arguments[index].text
			if u64(len(text)) > u64(len(region)) - next {
				return 0, 0, false
			}
			intrinsics.mem_copy_non_overlapping(raw_data(region[next:]), raw_data(text), len(text))
			store(region, field, Slice{start = next, count = u64(len(text))})
			next += u64(len(text))
		}
		field += field_size(type)
	}
	return 0, size, true
}

// decode reads the argument record of a call from the call region, and gives
// the integer registers of the call form.
//   registers: register n has the value of parameter n. For a Text, it has
//              the address of slices[n].
//   slices:    slices[n] is the slice record of a Text parameter: the address
//              of its bytes in the call region, and their count.
// ok is false when a part of the argument record is not in the call region.
// Then the receiver must not call the export.
decode :: proc "contextless" (
	function: module.Function,
	offset, size: u64,
	region: []u8,
	registers: ^[module.PARAMETER_CAPACITY]u64,
	slices: ^[module.PARAMETER_CAPACITY]Slice,
) -> (
	ok: bool,
) {
	function := function
	expected := record_size(function) or_return
	limit := u64(len(region))
	if size != expected || offset > limit || size > limit - offset {
		return false
	}
	// One copy: the other program can change the call region at any time.
	record: [module.PARAMETER_CAPACITY * size_of(Slice)]u8
	intrinsics.mem_copy_non_overlapping(&record, raw_data(region[offset:]), int(size))
	field := u64(0)
	for type, index in function.parameters[:function.parameter_count] {
		#partial switch type {
		case .Integer:
			registers[index] = load(record[:], field, u64)
		case .Text:
			slice := load(record[:], field, Slice)
			if slice.start > limit || slice.count > limit - slice.start {
				return false
			}
			slices[index] = {
				start = u64(uintptr(raw_data(region))) + slice.start,
				count = slice.count,
			}
			registers[index] = u64(uintptr(&slices[index]))
		}
		field += field_size(type)
	}
	return true
}
