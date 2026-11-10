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
//   Record    8 bytes: the offset of the bytes of the record in the call
//             region. The description gives the size. The receiver copies
//             the record to private memory before the call: the caller
//             cannot change it while the export runs.
//   Handle    8 bytes: the handle, as the receiver names it. Before the
//             call, the caller gives a copy of its handle to the receiver
//             through the call ring, with the rights of the description
//             (the kernel operation Handle_Give, with the memory of the call
//             ring as the target). A Handle field of a Record parameter
//             holds such a handle too. The receiver proves each handle
//             (Handle_State) and closes it when the export returns. 0 is
//             "no handle".
//
// An export with a Record result has one more field after the parameters:
// the offset of the place of the result in the call region. The export
// writes the record in private memory of the receiver, and the receiver
// copies it to that place.
//
// An export with a Text result has one more field after the parameters, and
// one more register in the direct call: a buffer, {start, capacity}. The
// caller owns the buffer; the callee writes the text in it and gives the
// count of bytes of the full text as its integer result. For an isolated
// call the buffer is in the call region: the callee writes the result where
// the caller reads it, with no copy between.
//
// The receiver trusts nothing in the call region. It copies the argument
// record to private memory, and it checks each offset and each count
// against the size of the call region (decode).
//
// This package allocates no memory and calls no kernel operation.
package isolated

import module "contract:module"
import "base:intrinsics"

// The roles of the context of a call host.
GRANT_RING :: 0 // Memory: the call ring.
GRANT_REGION :: 1 // Memory: the call region.
VALUE_FILE_ADDRESS :: 0 // Where the caller mapped the file of the module, read-only.
VALUE_FILE_SIZE :: 1 // The size of the file, in bytes.

FILE_ADDRESS :: 0x0000_3000_0000_0000 // Where a caller maps the file of the module in the call host.
REGION_PAGES :: 16

// A service that serves its own exports receives calls in the same form. It
// has one connection for each caller: one call ring and one call region.
// The root service names each connection on the service ring of the
// program, as a command record:
//   kind        a Service_Command
//   values[0]   the handle of the call ring, in the service
//   values[1]   the handle of the call region, in the service
SERVICE_CONNECTION_CAPACITY :: 8 // The callers of one service.

Service_Command :: enum u32 {
	None       = 0,
	Connect    = 1, // The service maps the two memory objects, and serves the calls of the call ring.
	Disconnect = 2, // The service unmaps them and closes the two handles.
}

Status :: enum u32 {
	Ok            = 0,
	Bad_Export    = 1, // The module has no export with this index, or the export has no description.
	Bad_Arguments = 2, // The argument record, or one of its slices, is not in the call region.
	Bad_Handle    = 3, // A handle of the argument record did not come through the call ring, or it lacks a right of the description.
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
	integer: u64, // An Integer. A Handle: the handle, as the receiver names it.
	text:    []u8,
	record:  []u8, // The bytes of a Record: the size of its description.
}

// A handle that the caller lent for a call, as the argument record names
// it. The receiver trusts no part of it before Handle_State.
Lent :: struct {
	handle: u32, // In the receiver.
	rights: u32, // The rights that the description asks: op.Rights.
}

// What decode gives: the registers of the call form, and the private
// memory that they name.
Call :: struct {
	registers:  [module.PARAMETER_CAPACITY]u64, // Register n has the value of parameter n.
	slices:     [module.PARAMETER_CAPACITY]Slice, // slices[n]: the slice record of a Text.
	records:    [module.PARAMETER_CAPACITY][module.RECORD_SIZE_LIMIT / 8]u64, // records[n]: the copy of a Record.
	lent:       [module.HANDLE_CAPACITY]Lent, // The handles to prove before the call, and to close after it.
	lent_count: int,
	result:     Slice, // A Record result: its place in the call region, as offsets.
}

field_size :: proc "contextless" (type: module.Type) -> u64 {
	switch type {
	case .Integer, .Record, .Handle:
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
	#partial switch function.result {
	case .None, .Integer:
	case .Text:
		if function.parameter_count == module.PARAMETER_CAPACITY {
			return 0, false // No register is free for the buffer.
		}
		size += size_of(Slice)
	case .Record:
		if function.parameter_count == module.PARAMETER_CAPACITY {
			return 0, false // No register is free for the address of the result.
		}
		size += 8
	case:
		return 0, false
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
// For a Text result, the buffer is the part of the call region after the
// arguments: `result` names it. For a Record result, `result` names the
// place of the record.
// file is the module of the export: it has the descriptions of the records.
// ok is false when the arguments do not agree with the description, or when
// the call region is too small.
encode :: proc "contextless" (file: []u8, function: module.Function, arguments: []Argument, region: []u8) -> (offset, size: u64, result: Slice, ok: bool) {
	function := function
	size = record_size(function) or_return
	if len(arguments) != int(function.parameter_count) || size > u64(len(region)) {
		return 0, 0, {}, false
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
				return 0, 0, {}, false
			}
			intrinsics.mem_copy_non_overlapping(raw_data(region[next:]), raw_data(text), len(text))
			store(region, field, Slice{start = next, count = u64(len(text))})
			next += u64(len(text))
		case .Record:
			described := module.record_type(file, function.parameter_details[index]) or_return
			bytes := arguments[index].record
			next = (next + 7) &~ 7
			if len(bytes) != int(described.size) || next > u64(len(region)) || u64(len(bytes)) > u64(len(region)) - next {
				return 0, 0, {}, false
			}
			intrinsics.mem_copy_non_overlapping(raw_data(region[next:]), raw_data(bytes), len(bytes))
			store(region, field, next)
			next += u64(len(bytes))
		case .Handle:
			if arguments[index].integer >> 32 != 0 {
				return 0, 0, {}, false
			}
			store(region, field, arguments[index].integer)
		}
		field += field_size(type)
	}
	#partial switch function.result {
	case .Text:
		result = {start = next, count = u64(len(region)) - next}
		store(region, field, result)
	case .Record:
		described := module.record_type(file, function.result_detail) or_return
		next = (next + 7) &~ 7
		if next > u64(len(region)) || u64(described.size) > u64(len(region)) - next {
			return 0, 0, {}, false
		}
		result = {start = next, count = u64(described.size)}
		intrinsics.mem_zero(raw_data(region[next:]), int(described.size))
		store(region, field, next)
	}
	return 0, size, result, true
}

// result_record gives the Record result of a call: the bytes at the place
// that encode named. The caller copies them out of the call region, then
// reads them.
result_record :: proc "contextless" (region: []u8, result: Slice, record: []u8) -> bool {
	if result.start > u64(len(region)) || result.count > u64(len(region)) - result.start || u64(len(record)) < result.count {
		return false
	}
	intrinsics.mem_copy_non_overlapping(raw_data(record), raw_data(region[result.start:]), int(result.count))
	return true
}

// result_text gives the Text result of a call: the bytes that the callee
// wrote in the buffer. `count` is the number that the callee gave: the
// caller does not trust it. complete is false when the text did not fit.
result_text :: proc "contextless" (region: []u8, result: Slice, count: u64) -> (text: []u8, complete: bool) {
	if result.start > u64(len(region)) || result.count > u64(len(region)) - result.start {
		return nil, false
	}
	return region[result.start:][:min(count, result.count)], count <= result.count
}

// decode reads the argument record of a call from the call region, and gives
// the integer registers of the call form (Call).
//   Integer: the register has the value.
//   Text:    the register has the address of call.slices[n]: the address of
//            the bytes in the call region, and their count. The buffer of a
//            Text result is one more Text, after the last parameter.
//   Record:  the register has the address of call.records[n], a copy.
//   Handle:  the register has the handle. call.lent has it, and each
//            handle of each record: the receiver proves them.
//   A Record result: the register after the last parameter has the address
//   of call.records of that place, all zero. After the call, result_store
//   copies it to the call region.
// file is the module of the export. ok is false when a part of the argument
// record is not in the call region. Then the receiver must not call the
// export.
decode :: proc "contextless" (file: []u8, function: module.Function, offset, size: u64, region: []u8, call: ^Call) -> (ok: bool) {
	function := function
	expected := record_size(function) or_return
	limit := u64(len(region))
	if size != expected || offset > limit || size > limit - offset {
		return false
	}
	call.lent_count = 0
	call.result = {}
	lend :: proc "contextless" (call: ^Call, handle: u64, rights: u32) -> bool {
		if handle == 0 {
			return true
		}
		if handle >> 32 != 0 || call.lent_count == len(call.lent) {
			return false
		}
		call.lent[call.lent_count] = {u32(handle), rights}
		call.lent_count += 1
		return true
	}
	// One copy: the other program can change the call region at any time.
	record: [(module.PARAMETER_CAPACITY + 1) * size_of(Slice)]u8
	intrinsics.mem_copy_non_overlapping(&record, raw_data(region[offset:]), int(size))
	field := u64(0)
	for type, index in function.parameters[:function.parameter_count] {
		#partial switch type {
		case .Integer:
			call.registers[index] = load(record[:], field, u64)
		case .Text:
			slice := load(record[:], field, Slice)
			if slice.start > limit || slice.count > limit - slice.start {
				return false
			}
			call.slices[index] = {
				start = u64(uintptr(raw_data(region))) + slice.start,
				count = slice.count,
			}
			call.registers[index] = u64(uintptr(&call.slices[index]))
		case .Record:
			described := module.record_type(file, function.parameter_details[index]) or_return
			start := load(record[:], field, u64)
			if start > limit || u64(described.size) > limit - start {
				return false
			}
			call.records[index] = {}
			intrinsics.mem_copy_non_overlapping(&call.records[index], raw_data(region[start:]), int(described.size))
			for number in 0 ..< described.field_count {
				item := module.field(file, described, number) or_return
				if item.type == .Handle {
					handle := (^u32)(uintptr(&call.records[index]) + uintptr(item.offset))^
					lend(call, u64(handle), item.detail) or_return
				}
			}
			call.registers[index] = u64(uintptr(&call.records[index]))
		case .Handle:
			call.registers[index] = load(record[:], field, u64)
			lend(call, call.registers[index], function.parameter_details[index]) or_return
		}
		field += field_size(type)
	}
	index := function.parameter_count
	#partial switch function.result {
	case .Text:
		slice := load(record[:], field, Slice)
		if slice.start > limit || slice.count > limit - slice.start {
			return false
		}
		call.slices[index] = {
			start = u64(uintptr(raw_data(region))) + slice.start,
			count = slice.count,
		}
		call.registers[index] = u64(uintptr(&call.slices[index]))
	case .Record:
		described := module.record_type(file, function.result_detail) or_return
		start := load(record[:], field, u64)
		if start > limit || u64(described.size) > limit - start {
			return false
		}
		call.records[index] = {}
		call.result = {start = start, count = u64(described.size)}
		call.registers[index] = u64(uintptr(&call.records[index]))
	}
	return true
}

// result_store copies the Record result of a call to its place in the call
// region. Call it after the export returned.
result_store :: proc "contextless" (function: module.Function, call: ^Call, region: []u8) {
	if function.result == .Record {
		intrinsics.mem_copy_non_overlapping(raw_data(region[call.result.start:]), &call.records[function.parameter_count], int(call.result.count))
	}
}
