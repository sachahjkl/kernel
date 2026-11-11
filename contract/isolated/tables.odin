package isolated

import module "contract:module"
import op "contract:operation"
import "base:intrinsics"

// Tables and bytes as parameters in an isolated call
// (docs/MODULE_CONTRACT.md, "Tables and bytes as parameters").
//
// The field of the argument record of a Table or Bytes parameter is a
// Table_Field. With memory 0 the records are in the call region: the caller
// copies the records 0 ..< count of a Read or Change table there, and
// reserves the records count ..< capacity of an Append table. Else memory is
// a memory object that the caller lent with the rights of the direction,
// and the records are in it from `start`: nothing is copied.
//
// The receiver gives the export a table place (module.Table_Place) in its
// own memory. After the export, it writes the count of each Append place
// back into the count of the field in the call region (counts_store). The
// caller reads it, trusts it only up to the capacity, and copies the
// records back into its own memory (tables_return).

Table_Field :: struct {
	start:    u64, // The offset of the records: in the call region, or in the memory object.
	count:    u64,
	capacity: u64,
	memory:   u64, // 0: the call region. Else: a lent memory object, as the receiver names it.
}
#assert(size_of(Table_Field) == 32)

// One table argument, on the side of the caller.
Table_Argument :: struct {
	// The memory of the caller: capacity records (bytes for Bytes). For a
	// Read or Change table, the first count records are the table.
	records:      []u8,
	count:        u64, // In records. After tables_return: the count that the callee gave, for an Append table.
	memory:       u64, // Not 0: the records are in this memory object, as the receiver names it (system.lend writes it), from memory_start.
	memory_start: u64,
	region_start: u64, // Written by encode: the offset of the copy in the call region.
}

// A memory object of a table argument that the receiver maps for the time
// of the export: see export_serve of support/system.
Table_Mapping :: struct {
	parameter: int,
	handle:    u32,
	start:     u64, // The offset of the records in the object.
	size:      u64, // The bytes of the records that the export can reach: the capacity, or the count of a Read or Change table.
	write:     bool, // Change and Append.
}

// is_table says if a parameter type is a Table or Bytes parameter.
is_table :: proc "contextless" (type: module.Type) -> bool {
	return type == .Table || type == .Bytes
}

// direction_rights gives the rights of a lent memory object for a
// direction: Read, or Read and Write (property 20: the rights are the
// direction).
direction_rights :: proc "contextless" (direction: module.Direction) -> op.Rights {
	return direction == .Read ? {.Read} : {.Read, .Write}
}

// table_record gives the size and the alignment of one record of a Table
// or Bytes parameter, from the description of the module. ok is false when
// the record is not valid, or has a Handle field.
table_record :: proc "contextless" (file: []u8, type: module.Type, detail: u32) -> (size, alignment: u64, ok: bool) {
	if type == .Bytes {
		return 1, 1, detail == 0
	}
	described := module.record_type(file, detail) or_return
	if described.size == 0 || module.record_has_handle(file, described) {
		return 0, 0, false
	}
	return u64(described.size), u64(module.record_alignment(file, described)), true
}

// directions_valid says if each direction of a description is in the
// enumeration, and Read for each parameter that is not a Table or Bytes.
directions_valid :: proc "contextless" (function: module.Function) -> bool {
	function := function
	for type, index in function.parameters[:min(int(function.parameter_count), module.PARAMETER_CAPACITY)] {
		direction := function.parameter_directions[index]
		if direction > max(module.Direction) || direction != .Read && !is_table(type) {
			return false
		}
	}
	return true
}

// table_encode writes the field of one table argument, and copies its
// records into the call region at `next` when it has no memory object.
// It gives the offset after the copy.
@(private)
table_encode :: proc "contextless" (file: []u8, type: module.Type, detail: u32, direction: module.Direction, argument: ^Table_Argument, region: []u8, field: u64, next: u64) -> (after: u64, ok: bool) {
	size, _ := table_record(file, type, detail) or_return
	capacity := u64(len(argument.records)) / size
	if argument.count > capacity {
		return 0, false
	}
	if argument.memory != 0 {
		if argument.memory >> 32 != 0 {
			return 0, false
		}
		store(region, field, Table_Field{start = argument.memory_start, count = argument.count, capacity = capacity, memory = argument.memory})
		return next, true
	}
	start := (next + 7) &~ 7
	carried := direction == .Append ? capacity - argument.count : argument.count
	if start > u64(len(region)) || carried > (u64(len(region)) - start) / size {
		return 0, false
	}
	if direction != .Append {
		intrinsics.mem_copy_non_overlapping(raw_data(region[start:]), raw_data(argument.records), int(carried * size))
	}
	argument.region_start = start
	store(region, field, Table_Field{start = start, count = argument.count, capacity = capacity})
	return start + carried * size, true
}

// table_decode reads the field of one table argument, checks it against
// the call region, and gives the table place of the export. A table in a
// memory object is listed in call.mappings: the receiver maps it, and sets
// the address of the place.
@(private)
table_decode :: proc "contextless" (file: []u8, type: module.Type, detail: u32, direction: module.Direction, index: int, field: Table_Field, field_offset: u64, region: []u8, call: ^Call) -> (ok: bool) {
	size, alignment := table_record(file, type, detail) or_return
	limit := u64(len(region))
	if field.count > field.capacity && direction == .Append {
		return false
	}
	// No count and no capacity times a size passes TABLE_SPAN, in each
	// form: no product and no sum below wraps (finding F1 of the hostile read).
	if field.count > TABLE_SPAN / size || field.capacity > TABLE_SPAN / size {
		return false
	}
	// The records that the export can reach.
	reached := direction == .Append ? field.capacity : field.count
	place := &call.places[index]
	place^ = {count = field.count, capacity = direction == .Append ? field.capacity : field.count}
	if field.memory != 0 {
		if field.memory >> 32 != 0 || call.mapping_count == len(call.mappings) || field.start % alignment != 0 || reached > TABLE_SPAN / size - 1 {
			return false
		}
		call.mappings[call.mapping_count] = {parameter = index, handle = u32(field.memory), start = field.start, size = reached * size, write = direction != .Read}
		call.mapping_count += 1
		lend(call, field.memory, transmute(u32)direction_rights(direction)) or_return
	} else {
		// The region holds the records 0 ..< count of a Read or Change
		// table, and the records count ..< capacity of an Append table.
		carried := direction == .Append ? field.capacity - field.count : field.count
		if field.start % 8 != 0 || field.start > limit || carried > (limit - field.start) / size {
			return false
		}
		address := u64(uintptr(raw_data(region))) + field.start
		if direction == .Append {
			// Record `count` is the first reserved byte: the records before
			// it are not in the call.
			address -= field.count * size
		}
		place.address = address
	}
	if direction == .Append {
		call.count_places[index] = field_offset + u64(offset_of(Table_Field, count))
	}
	call.registers[index] = u64(uintptr(place))
	return true
}

// counts_store writes the count of each Append place back into its field
// of the argument record, in the call region. Call it after the export
// returned.
counts_store :: proc "contextless" (function: module.Function, call: ^Call, region: []u8) {
	function := function
	for type, index in function.parameters[:function.parameter_count] {
		if is_table(type) && function.parameter_directions[index] == .Append {
			offset := call.count_places[index]
			if offset <= u64(len(region)) && 8 <= u64(len(region)) - offset {
				store(region, offset, call.places[index].count)
			}
		}
	}
}

// Return_Problem: what tables_return found wrong in the answer of the callee.
Return_Problem :: enum u32 {
	None          = 0,
	Count_Smaller = 1, // An Append table: the callee gave a count smaller than the count on entry.
	Bad_Region    = 2, // The argument record is not in the call region.
}

// tables_return copies the answer of the callee back into the memory of
// the caller: the records 0 ..< count of a Change table, and the records
// count ..< min(new count, capacity) of an Append table, whose count it
// sets to the new count. The caller never writes its memory at or after
// the capacity. offset is the offset of the argument record that encode
// gave. A memory object needs no copy: the callee wrote the memory of the
// caller. On a problem, parameter is its number, from 1, and the counts of
// the arguments do not change.
tables_return :: proc "contextless" (file: []u8, function: module.Function, arguments: []Argument, region: []u8, offset: u64) -> (problem: Return_Problem, parameter: int) {
	function := function
	field := offset
	for type, index in function.parameters[:min(int(function.parameter_count), len(arguments))] {
		defer field += field_size(type)
		if !is_table(type) {
			continue
		}
		direction := function.parameter_directions[index]
		if direction == .Read {
			continue
		}
		argument := &arguments[index].table
		size, _, ok := table_record(file, type, function.parameter_details[index])
		if !ok {
			return .Bad_Region, index + 1
		}
		capacity := u64(len(argument.records)) / size
		if direction == .Change {
			if argument.memory == 0 {
				intrinsics.mem_copy_non_overlapping(raw_data(argument.records), raw_data(region[argument.region_start:]), int(argument.count * size))
			}
			continue
		}
		place := field + u64(offset_of(Table_Field, count))
		if place > u64(len(region)) || 8 > u64(len(region)) - place {
			return .Bad_Region, index + 1
		}
		answer := load(region, place, u64)
		if answer < argument.count {
			return .Count_Smaller, index + 1
		}
		if argument.memory == 0 {
			kept := min(answer, capacity)
			intrinsics.mem_copy_non_overlapping(raw_data(argument.records[argument.count * size:]), raw_data(region[argument.region_start:]), int((kept - argument.count) * size))
		}
		argument.count = answer
	}
	return .None, 0
}

// Missing_Room: the table argument that does not fit in the call region, for
// the sentence of the caller.
Missing_Room :: struct {
	parameter: int, // From 1. 0: each table fits.
	needed:    u64, // The bytes that its records need.
	free:      u64, // The bytes of the call region that were free for it.
}

// room_missing gives the first table argument that does not fit in a call
// region of `region_size` bytes, after the argument record and the
// arguments before it. Call it when encode refused, to say why.
room_missing :: proc "contextless" (file: []u8, function: module.Function, arguments: []Argument, region_size: u64) -> (missing: Missing_Room) {
	function := function
	next := record_size(function) or_else 0
	for type, index in function.parameters[:min(int(function.parameter_count), len(arguments))] {
		#partial switch type {
		case .Text:
			next += u64(len(arguments[index].text))
		case .Record:
			next = (next + 7) &~ 7 + u64(len(arguments[index].record))
		case .Table, .Bytes:
			argument := arguments[index].table
			if argument.memory != 0 {
				continue
			}
			size, _, ok := table_record(file, type, function.parameter_details[index])
			if !ok {
				continue
			}
			direction := function.parameter_directions[index]
			capacity := u64(len(argument.records)) / size
			carried := direction == .Append ? capacity - min(argument.count, capacity) : argument.count
			next = (next + 7) &~ 7
			free := next < region_size ? region_size - next : 0
			if carried > free / size {
				return {parameter = index + 1, needed = carried * size, free = free}
			}
			next += carried * size
		}
	}
	return {}
}
