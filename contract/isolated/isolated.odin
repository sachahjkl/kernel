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
//   Table, Bytes  32 bytes: a Table_Field (tables.odin): the records in the
//             call region, or in a lent memory object.
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
// An export with a Table result has one more field after the parameters,
// and one more register in the direct call: a buffer, {start, capacity},
// where the capacity is a count of records. In an isolated call the buffer
// is the rest of the call region, from a multiple of 8 bytes. The callee
// gives the count of records of the full table as its integer result.
//
// An export with an error record (module.Function.error_record) has one
// more field, after all the others: the offset of the place of the record in
// the call region (contract/errors, 56 bytes). In the direct call it is one
// more register, after the buffer of a result. The receiver gives the export
// the address of that place: the export only writes it, when it fails.
//
// The receiver trusts nothing in the call region. It copies the argument
// record to private memory, and it checks each offset and each count
// against the size of the call region (decode).
//
// This package allocates no memory and calls no kernel operation.
package isolated

import "contract:errors"
import module "contract:module"
import "base:intrinsics"

// The roles of the context of a call host.
GRANT_RING :: 0 // Memory: the call ring.
GRANT_REGION :: 1 // Memory: the call region.
// The files of a call host: the caller maps them read-only at FILE_ADDRESS,
// in the form of the boot image. Entry 1 is the module; the other entries
// are its imports, and the modules of the replacements that apply to them.
// The replacement records (module.Replacement) are on the first page, after
// the entries.
VALUE_FILE_ADDRESS :: 0 // Where the caller mapped the files.
VALUE_FILE_SIZE :: 1 // The size of the files, in bytes, from FILE_ADDRESS.
VALUE_REPLACEMENT_OFFSET :: 2 // The offset of the replacement records, from FILE_ADDRESS.
VALUE_REPLACEMENT_COUNT :: 3

FILE_ADDRESS :: 0x0000_3000_0000_0000 // Where a caller maps the files of the module in the call host.
// Where a receiver maps the memory object of table parameter n for the
// time of one export: TABLE_ADDRESS + n * TABLE_SPAN. The same addresses at
// each call: the kernel gives a new address to each mapping that does not
// choose one, and each new range of addresses costs page tables.
TABLE_ADDRESS :: 0x0000_3800_0000_0000
TABLE_SPAN :: u64(16) << 30 // The most bytes of one table in a memory object: 16 GiB.
REGION_PAGES :: 16

// A service that serves its own exports receives calls in the same form. It
// has one connection for each caller: one call ring and one call region.
// The root service names each connection on the service ring of the
// program, as a command record:
//   kind        a Service_Command
//   values[0]   the handle of the call ring, in the service
//   values[1]   the handle of the call region, in the service
//   values[2..5] Connect: the name of the caller, as the root service names
//               it: 32 bytes, zero bytes after the name. A program that the
//               root service starts again has the same name.
//   values[6]   Connect and Grant: what the root service grants to the
//               caller in this service. The bits of CALLER_AMOUNT_MASK are
//               an amount: the service gives it a meaning, for example a
//               limit of blocks. CALLER_PERSON: the caller acts for the
//               person, and can see what the service holds for all callers.
//               0: no grant. The caller cannot change it.
SERVICE_CONNECTION_CAPACITY :: 8 // The callers of one service.
CALLER_AMOUNT_MASK :: u64(1) << 48 - 1
CALLER_PERSON :: u64(1) << 63

Service_Command :: enum u32 {
	None       = 0,
	Connect    = 1, // The service maps the two memory objects, and serves the calls of the call ring.
	Disconnect = 2, // The service unmaps them and closes the two handles.
	Grant      = 3, // The grant of the connection of the call ring changes to values[6]: a revocation, for example.
}

Status :: enum u32 {
	Ok            = 0,
	Bad_Export    = 1, // The module has no export with this index, or the export has no description.
	Bad_Arguments = 2, // The argument record, or one of its slices, is not in the call region.
	Bad_Handle    = 3, // A handle of the argument record did not come through the call ring, or it lacks a right of the description.
	// The first completion of a call host has the tag 0: Ok when it loaded
	// its module, or Load_Failed. With Load_Failed, the call region starts
	// with a module.Load_Error record, and the call host stops.
	Load_Failed   = 4,
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
	table:   Table_Argument, // A Table or Bytes.
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
	error:      Slice, // The place of the error record in the call region, as offsets. count 0: the export has none.
	places:        [module.PARAMETER_CAPACITY]module.Table_Place, // places[n]: the table place of a Table or Bytes, in memory of the receiver.
	count_offsets: [module.PARAMETER_CAPACITY]u64, // An Append place: the offset of its count in the call region.
	mappings:      [module.PARAMETER_CAPACITY]Table_Mapping, // The memory objects to map before the call.
	mapping_count: int,
}

// The largest argument record: 6 table fields, a buffer and an error record.
ARGUMENT_RECORD_LIMIT :: module.PARAMETER_CAPACITY * size_of(Table_Field) + size_of(Slice) + 8

ERROR_RECORD_SIZE :: 56 // contract/errors: Error_Record.

field_size :: proc "contextless" (type: module.Type) -> u64 {
	switch type {
	case .Integer, .Record, .Handle:
		return 8
	case .Text:
		return size_of(Slice)
	case .Table, .Bytes:
		return size_of(Table_Field)
	case .None:
	}
	return 0
}

// record_size gives the size of the argument record of an export.
// ok is false when the description has a type that this code does not know.
record_size :: proc "contextless" (function: module.Function) -> (size: u64, ok: bool) {
	function := function
	if function.parameter_count > module.PARAMETER_CAPACITY || !directions_valid(function) {
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
	case .Text, .Table:
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
	if function.error_record != 0 {
		registers := u64(function.parameter_count) + u64(function.result == .Text || function.result == .Table || function.result == .Record)
		if registers >= module.PARAMETER_CAPACITY || function.result == .Record {
			return 0, false
		}
		size += 8
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
// For an export with an error record, `error` names its place, after the
// result: encode writes zero bytes there. The caller reads it when the
// integer result is negative.
// A Table or Bytes argument: see table_encode. encode writes region_start
// in the argument: keep the arguments for tables_return.
encode :: proc "contextless" (file: []u8, function: module.Function, arguments: []Argument, region: []u8) -> (offset, size: u64, result: Slice, error: Slice, ok: bool) {
	function := function
	size = record_size(function) or_return
	if len(arguments) != int(function.parameter_count) || size > u64(len(region)) {
		return 0, 0, {}, {}, false
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
				return 0, 0, {}, {}, false
			}
			intrinsics.mem_copy_non_overlapping(raw_data(region[next:]), raw_data(text), len(text))
			store(region, field, Slice{start = next, count = u64(len(text))})
			next += u64(len(text))
		case .Record:
			described := module.record_type(file, function.parameter_details[index]) or_return
			bytes := arguments[index].record
			next = (next + 7) &~ 7
			if len(bytes) != int(described.size) || next > u64(len(region)) || u64(len(bytes)) > u64(len(region)) - next {
				return 0, 0, {}, {}, false
			}
			intrinsics.mem_copy_non_overlapping(raw_data(region[next:]), raw_data(bytes), len(bytes))
			store(region, field, next)
			next += u64(len(bytes))
		case .Handle:
			if arguments[index].integer >> 32 != 0 {
				return 0, 0, {}, {}, false
			}
			store(region, field, arguments[index].integer)
		case .Table, .Bytes:
			next = table_encode(file, type, function.parameter_details[index], function.parameter_directions[index], &arguments[index].table, region, field, next) or_return
		}
		field += field_size(type)
	}
	// The place of the error record: after the bytes of the arguments, and
	// before the buffer of a result, which is the rest of the region.
	if function.error_record != 0 {
		next = (next + 7) &~ 7
		if next > u64(len(region)) || ERROR_RECORD_SIZE > u64(len(region)) - next {
			return 0, 0, {}, {}, false
		}
		error = {start = next, count = ERROR_RECORD_SIZE}
		intrinsics.mem_zero(raw_data(region[next:]), ERROR_RECORD_SIZE)
		next += ERROR_RECORD_SIZE
	}
	#partial switch function.result {
	case .Text:
		result = {start = next, count = u64(len(region)) - next}
		store(region, field, result)
		field += size_of(Slice)
	case .Table:
		described := module.record_type(file, function.result_detail) or_return
		next = (next + 7) &~ 7
		if next > u64(len(region)) || described.size == 0 {
			return 0, 0, {}, {}, false
		}
		result = {start = next, count = (u64(len(region)) - next) / u64(described.size)}
		store(region, field, result)
		field += size_of(Slice)
	case .Record:
		described := module.record_type(file, function.result_detail) or_return
		next = (next + 7) &~ 7
		if next > u64(len(region)) || u64(described.size) > u64(len(region)) - next {
			return 0, 0, {}, {}, false
		}
		result = {start = next, count = u64(described.size)}
		intrinsics.mem_zero(raw_data(region[next:]), int(described.size))
		store(region, field, next)
		field += 8
	}
	if function.error_record != 0 {
		store(region, field, error.start)
	}
	return 0, size, result, error, true
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

// result_table gives the Table result of a call: the records that the
// callee wrote in the buffer, as bytes. `count` is the number that the
// callee gave, and `size` the size of a record of the description: the
// caller trusts neither the count nor the buffer that the region holds.
// complete is false when the table did not fit.
result_table :: proc "contextless" (region: []u8, result: Slice, count: u64, size: u64) -> (records: []u8, complete: bool) {
	if size == 0 || result.start > u64(len(region)) || result.count > (u64(len(region)) - result.start) / size {
		return nil, false
	}
	kept := min(count, result.count)
	return region[result.start:][:kept * size], count <= result.count
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
// record is not in the call region, or when two ranges of the call region
// overlap and one of them is written. Then the receiver must not call the
// export, and `refusal` (it can be nil) has an error record that says which
// argument and why (finding W8 of the hostile read): the receiver gives it
// to the caller in the completion record.
decode :: proc "contextless" (file: []u8, function: module.Function, offset, size: u64, region: []u8, call: ^Call, refusal: ^errors.Error_Record = nil) -> (ok: bool) {
	function := function
	expected, described := record_size(function)
	if !described {
		return refuse(refusal, .Bad_Value, .None, 0, 0, 0)
	}
	limit := u64(len(region))
	if size != expected {
		return refuse(refusal, .Bad_Value, .Bytes, 0, size, expected)
	}
	if offset > limit || size > limit - offset {
		return refuse(refusal, .Out_Of_Range, .Bytes, 0, offset + min(size, limit), limit)
	}
	call.lent_count = 0
	call.mapping_count = 0
	call.result = {}
	ranges: Region_Ranges
	// The receiver writes the counts of Append places back into the
	// argument record: no table of the call region overlaps it.
	region_range_add(&ranges, {offset, offset + size, true, 0}, refusal) or_return
	// One copy: the other program can change the call region at any time.
	record: [ARGUMENT_RECORD_LIMIT]u8
	intrinsics.mem_copy_non_overlapping(&record, raw_data(region[offset:]), int(size))
	field := u64(0)
	for type, index in function.parameters[:function.parameter_count] {
		argument := i64(index + 1)
		#partial switch type {
		case .Integer:
			call.registers[index] = load(record[:], field, u64)
		case .Text:
			slice := load(record[:], field, Slice)
			if slice.start > limit || slice.count > limit - slice.start {
				return refuse(refusal, .Out_Of_Range, .Bytes, argument, slice.start + min(slice.count, limit), limit)
			}
			region_range_add(&ranges, {slice.start, slice.start + slice.count, false, argument}, refusal) or_return
			call.slices[index] = {
				start = u64(uintptr(raw_data(region))) + slice.start,
				count = slice.count,
			}
			call.registers[index] = u64(uintptr(&call.slices[index]))
		case .Record:
			described_record, valid := module.record_type(file, function.parameter_details[index])
			if !valid {
				return refuse(refusal, .Bad_Value, .None, argument, u64(function.parameter_details[index]), 0)
			}
			start := load(record[:], field, u64)
			if start > limit || u64(described_record.size) > limit - start {
				return refuse(refusal, .Out_Of_Range, .Bytes, argument, start + min(u64(described_record.size), limit), limit)
			}
			call.records[index] = {}
			intrinsics.mem_copy_non_overlapping(&call.records[index], raw_data(region[start:]), int(described_record.size))
			for number in 0 ..< described_record.field_count {
				item, has_field := module.field(file, described_record, number)
				if has_field && item.type == .Handle {
					handle := (^u32)(uintptr(&call.records[index]) + uintptr(item.offset))^
					if !lent_handle_add(call, u64(handle), item.detail) {
						return refuse(refusal, .Full, .Handles, argument, 0, len(call.lent))
					}
				}
			}
			call.registers[index] = u64(uintptr(&call.records[index]))
		case .Handle:
			call.registers[index] = load(record[:], field, u64)
			if !lent_handle_add(call, call.registers[index], function.parameter_details[index]) {
				return refuse(refusal, call.registers[index] >> 32 != 0 ? .Handle_Absent : .Full, .Handles, argument, call.registers[index], len(call.lent))
			}
		case .Table, .Bytes:
			table_decode(file, type, function.parameter_details[index], function.parameter_directions[index], index, load(record[:], field, Table_Field), offset + field, region, call, &ranges, refusal) or_return
		}
		field += field_size(type)
	}
	index := function.parameter_count
	#partial switch function.result {
	case .Text:
		slice := load(record[:], field, Slice)
		if slice.start > limit || slice.count > limit - slice.start {
			return refuse(refusal, .Out_Of_Range, .Bytes, 0, slice.start + min(slice.count, limit), limit)
		}
		region_range_add(&ranges, {slice.start, slice.start + slice.count, true, 0}, refusal) or_return
		call.slices[index] = {
			start = u64(uintptr(raw_data(region))) + slice.start,
			count = slice.count,
		}
		call.registers[index] = u64(uintptr(&call.slices[index]))
	case .Table:
		described_record, valid := module.record_type(file, function.result_detail)
		slice := load(record[:], field, Slice)
		if !valid || described_record.size == 0 {
			return refuse(refusal, .Bad_Value, .None, 0, u64(function.result_detail), 0)
		}
		if slice.start > limit || slice.count > (limit - slice.start) / u64(described_record.size) {
			return refuse(refusal, .Out_Of_Range, .Records, 0, slice.count, (limit - min(slice.start, limit)) / u64(described_record.size))
		}
		region_range_add(&ranges, {slice.start, slice.start + slice.count * u64(described_record.size), true, 0}, refusal) or_return
		call.slices[index] = {
			start = u64(uintptr(raw_data(region))) + slice.start,
			count = slice.count,
		}
		call.registers[index] = u64(uintptr(&call.slices[index]))
	case .Record:
		described_record, valid := module.record_type(file, function.result_detail)
		if !valid {
			return refuse(refusal, .Bad_Value, .None, 0, u64(function.result_detail), 0)
		}
		start := load(record[:], field, u64)
		if start > limit || u64(described_record.size) > limit - start {
			return refuse(refusal, .Out_Of_Range, .Bytes, 0, start + min(u64(described_record.size), limit), limit)
		}
		region_range_add(&ranges, {start, start + u64(described_record.size), true, 0}, refusal) or_return
		call.records[index] = {}
		call.result = {start = start, count = u64(described_record.size)}
		call.registers[index] = u64(uintptr(&call.records[index]))
	}
	// The error record: the export writes it in the call region, at a place
	// that the caller chose and the receiver checked. The receiver does not
	// read it.
	call.error = {}
	if function.error_record != 0 {
		field += function.result == .Text || function.result == .Table ? size_of(Slice) : 0
		start := load(record[:], field, u64)
		if start > limit || ERROR_RECORD_SIZE > limit - start || start % 8 != 0 {
			return refuse(refusal, .Out_Of_Range, .Bytes, 0, start + min(u64(ERROR_RECORD_SIZE), limit), limit)
		}
		region_range_add(&ranges, {start, start + ERROR_RECORD_SIZE, true, 0}, refusal) or_return
		call.error = {start = start, count = ERROR_RECORD_SIZE}
		registers := u64(function.parameter_count) + u64(function.result == .Text || function.result == .Table)
		call.registers[registers] = u64(uintptr(raw_data(region))) + start
	}
	return true
}

// lent_handle_add adds a handle of the argument record to the handles
// that the receiver proves before the call and closes after it.
@(private)
lent_handle_add :: proc "contextless" (call: ^Call, handle: u64, rights: u32) -> bool {
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

// result_store copies the Record result of a call to its place in the call
// region. Call it after the export returned.
result_store :: proc "contextless" (function: module.Function, call: ^Call, region: []u8) {
	if function.result == .Record {
		intrinsics.mem_copy_non_overlapping(raw_data(region[call.result.start:]), &call.records[function.parameter_count], int(call.result.count))
	}
}
