package isolated

import "contract:errors"
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
	start:         u64, // The offset of the records: in the call region, or in the memory object.
	count:         u64,
	capacity:      u64,
	memory_handle: u64, // 0: the call region. Else: a lent memory object, as the receiver names it.
}
#assert(size_of(Table_Field) == 32)

// One table argument, on the side of the caller.
Table_Argument :: struct {
	// The memory of the caller: capacity records (bytes for Bytes). For a
	// Read or Change table, the first count records are the table.
	records:      []u8,
	count:        u64, // In records. After tables_return: the count that the callee gave, for an Append table.
	memory_handle: u64, // Not 0: the records are in this memory object, as the receiver names it (system.lend writes it), from memory_start.
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
	writable:  bool, // Change and Append.
}

// is_table says if a parameter type is a Table or Bytes parameter.
is_table_or_bytes :: proc "contextless" (type: module.Type) -> bool {
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
		if direction > max(module.Direction) || direction != .Read && !is_table_or_bytes(type) {
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
	// An Append count can be over the capacity: earlier calls did not fit
	// (docs/MODULE_CONTRACT.md, "Did not fit, across calls"). A Read or
	// Change table holds its count. No count passes TABLE_SPAN: decode
	// refuses it, so encode does too.
	if direction != .Append && argument.count > capacity || argument.count > TABLE_SPAN / size {
		return 0, false
	}
	if argument.memory_handle != 0 {
		if argument.memory_handle >> 32 != 0 {
			return 0, false
		}
		store(region, field, Table_Field{start = argument.memory_start, count = argument.count, capacity = capacity, memory_handle = argument.memory_handle})
		return next, true
	}
	start := (next + 7) &~ 7
	records_in_region := direction == .Append ? capacity - min(argument.count, capacity) : argument.count
	if start > u64(len(region)) || records_in_region > (u64(len(region)) - start) / size {
		return 0, false
	}
	if direction != .Append {
		intrinsics.mem_copy_non_overlapping(raw_data(region[start:]), raw_data(argument.records), int(records_in_region * size))
	}
	argument.region_start = start
	store(region, field, Table_Field{start = start, count = argument.count, capacity = capacity})
	return start + records_in_region * size, true
}

// The ranges of the call region that one call reads or writes: decode
// refuses two ranges that overlap when one of them is written (finding W3
// of the hostile read): a Change table over another table, over the error
// record, or over the argument record whose counts the receiver writes back.
Region_Range :: struct {
	start, end: u64, // end is not in the range.
	written:    bool,
	argument:   i64, // The number of the parameter, from 1; 0: a result, the error record or the argument record.
}
REGION_RANGE_CAPACITY :: module.PARAMETER_CAPACITY + 3 // The parameters, the argument record, a result and the error record.

Region_Ranges :: struct {
	ranges: [REGION_RANGE_CAPACITY]Region_Range,
	count:  int,
}

// region_range_add adds a range, and gives false with an error record of
// the kind Overlap when it overlaps a range before it and one of the two
// is written. An empty range overlaps nothing.
@(private)
region_range_add :: proc "contextless" (ranges: ^Region_Ranges, item: Region_Range, refusal: ^errors.Error_Record) -> bool {
	if item.start == item.end {
		return true
	}
	for other in ranges.ranges[:ranges.count] {
		if (item.written || other.written) && item.start < other.end && other.start < item.end {
			return refuse(refusal, .Overlap, .Region, item.argument, item.start, item.end - item.start)
		}
	}
	if ranges.count == len(ranges.ranges) {
		return refuse(refusal, .Full, .None, item.argument, 0, REGION_RANGE_CAPACITY)
	}
	ranges.ranges[ranges.count] = item
	ranges.count += 1
	return true
}

// refuse writes the error record of a refusal of decode, and gives false.
// refusal can be nil.
@(private)
refuse :: proc "contextless" (refusal: ^errors.Error_Record, kind: errors.Kind, unit: errors.Unit, argument: i64, value: u64, limit: u64) -> bool {
	if refusal != nil {
		refusal^ = errors.error_make(kind, unit, argument, i64(min(value, u64(max(i64)))), i64(min(limit, u64(max(i64)))))
	}
	return false
}

// table_decode reads the field of one table argument, checks it against
// the call region, and gives the table place of the export. A table in a
// memory object is listed in call.mappings: the receiver maps it, and sets
// the address of the place. A refusal writes its error record.
@(private)
table_decode :: proc "contextless" (file: []u8, type: module.Type, detail: u32, direction: module.Direction, index: int, field: Table_Field, field_offset: u64, region: []u8, call: ^Call, ranges: ^Region_Ranges, refusal: ^errors.Error_Record) -> (ok: bool) {
	argument := i64(index + 1)
	size, alignment, described := table_record(file, type, detail)
	if !described {
		return refuse(refusal, .Bad_Value, .None, argument, u64(detail), 0)
	}
	limit := u64(len(region))
	// A Read or Change table: the records 0 ..< count, so count <= capacity
	// by the form (the place has capacity = count). An Append count can be
	// over the capacity (across calls).
	// No count and no capacity times a size passes TABLE_SPAN, in each
	// form: no product and no sum below wraps (finding F1 of the hostile read).
	if field.count > TABLE_SPAN / size || field.capacity > TABLE_SPAN / size {
		return refuse(refusal, .Too_Long, .Records, argument, max(field.count, field.capacity), TABLE_SPAN / size)
	}
	reachable_records := direction == .Append ? field.capacity : field.count
	place := &call.places[index]
	place^ = {count = field.count, capacity = direction == .Append ? field.capacity : field.count}
	if field.memory_handle != 0 {
		if field.memory_handle >> 32 != 0 {
			return refuse(refusal, .Handle_Absent, .None, argument, field.memory_handle, 0)
		}
		if field.start % alignment != 0 {
			return refuse(refusal, .Bad_Value, .Bytes, argument, field.start, 0)
		}
		// The pages of the records stay in the span of this parameter (N2).
		if reachable_records * size > TABLE_SPAN - module.PAGE_SIZE {
			return refuse(refusal, .Too_Long, .Bytes, argument, reachable_records * size, TABLE_SPAN - module.PAGE_SIZE)
		}
		if call.mapping_count == len(call.mappings) {
			return refuse(refusal, .Full, .None, argument, 0, len(call.mappings))
		}
		call.mappings[call.mapping_count] = {parameter = index, handle = u32(field.memory_handle), start = field.start, size = reachable_records * size, writable = direction != .Read}
		call.mapping_count += 1
		if !lent_handle_add(call, field.memory_handle, transmute(u32)direction_rights(direction)) {
			return refuse(refusal, .Full, .Handles, argument, 0, len(call.lent))
		}
	} else {
		// The region holds the records 0 ..< count of a Read or Change
		// table, and the records count ..< capacity of an Append table.
		records_in_region := direction == .Append ? field.capacity - min(field.count, field.capacity) : field.count
		if field.start % 8 != 0 {
			return refuse(refusal, .Bad_Value, .Bytes, argument, field.start, 0)
		}
		if field.start > limit || records_in_region > (limit - field.start) / size {
			return refuse(refusal, .Out_Of_Range, .Bytes, argument, field.start + records_in_region * size, limit)
		}
		region_range_add(ranges, {field.start, field.start + records_in_region * size, direction != .Read, argument}, refusal) or_return
		address := u64(uintptr(raw_data(region))) + field.start
		if direction == .Append {
			// Record min(count, capacity) is the first reserved byte: the
			// records before it are not in the call. Both numbers are at most
			// TABLE_SPAN / size (checked above): no product wraps.
			address -= min(field.count, field.capacity) * size
		}
		place.address = address
	}
	if direction == .Append {
		call.count_offsets[index] = field_offset + u64(offset_of(Table_Field, count))
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
		if is_table_or_bytes(type) && function.parameter_directions[index] == .Append {
			offset := call.count_offsets[index]
			if offset <= u64(len(region)) && 8 <= u64(len(region)) - offset {
				store(region, offset, call.places[index].count)
			}
		}
	}
}

// Return_Problem: what tables_return found wrong in the answer of the callee.
Return_Problem :: enum u32 {
	None            = 0,
	Count_Smaller   = 1, // An Append table: the callee gave a count smaller than the count on entry.
	Bad_Region      = 2, // The argument record is not in the call region.
	Bad_Description = 3, // The record of a table parameter has no valid description.
}

// tables_return copies the answer of the callee back into the memory of
// the caller: the records 0 ..< count of a Change table, and the records
// count ..< min(new count, capacity) of an Append table, whose count it
// sets to the new count. The caller never writes its memory at or after
// the capacity. offset is the offset of the argument record that encode
// gave. A memory object needs no copy: the callee wrote the memory of the
// caller. It checks each answer first, then copies: on a problem, parameter
// is its number, from 1, and no count and no record of the caller changes
// (finding W7 of the hostile read).
tables_return :: proc "contextless" (file: []u8, function: module.Function, arguments: []Argument, region: []u8, offset: u64) -> (problem: Return_Problem, parameter: int) {
	return tables_return_of(file, function, arguments, region, offset, 0)
}

// error_details_return copies back the table of error details of an export
// that failed (docs/MODULE_CONTRACT.md, section 8, "The table of error
// details"), and no other table: the error record and the details are one
// answer, and the other tables of a failed call stay as they were. It has
// the checks of tables_return. An export with no table of error details:
// nothing to do.
error_details_return :: proc "contextless" (file: []u8, function: module.Function, arguments: []Argument, region: []u8, offset: u64) -> (problem: Return_Problem, parameter: int) {
	index, has_details := module.error_details_parameter(file, function)
	if !has_details {
		return .None, 0
	}
	return tables_return_of(file, function, arguments, region, offset, index + 1)
}

// tables_return_of is tables_return for each table (only_parameter 0), or
// for the parameter only_parameter only, from 1.
@(private)
tables_return_of :: proc "contextless" (file: []u8, function: module.Function, arguments: []Argument, region: []u8, offset: u64, only_parameter: int) -> (problem: Return_Problem, parameter: int) {
	function := function
	count_given_by_callee: [module.PARAMETER_CAPACITY]u64
	for pass in 0 ..< 2 {
		field := offset
		for type, index in function.parameters[:min(int(function.parameter_count), len(arguments))] {
			defer field += field_size(type)
			direction := function.parameter_directions[index]
			if !is_table_or_bytes(type) || direction == .Read || (only_parameter != 0 && index + 1 != only_parameter) {
				continue
			}
			argument := &arguments[index].table
			size, _, ok := table_record(file, type, function.parameter_details[index])
			if !ok {
				return .Bad_Description, index + 1
			}
			capacity := u64(len(argument.records)) / size
			if pass == 0 {
				if direction == .Append {
					count_offset := field + u64(offset_of(Table_Field, count))
					if count_offset > u64(len(region)) || 8 > u64(len(region)) - count_offset {
						return .Bad_Region, index + 1
					}
					count_given_by_callee[index] = load(region, count_offset, u64)
					if count_given_by_callee[index] < argument.count {
						return .Count_Smaller, index + 1
					}
				}
				continue
			}
			if direction == .Change {
				if argument.memory_handle == 0 {
					intrinsics.mem_copy_non_overlapping(raw_data(argument.records), raw_data(region[argument.region_start:]), int(argument.count * size))
				}
				continue
			}
			if argument.memory_handle == 0 {
				// The records that came: from min(count on entry, capacity) to
				// min(new count, capacity); none when the count on entry was
				// at or over the capacity.
				first_record := min(argument.count, capacity)
				kept_records := min(count_given_by_callee[index], capacity)
				intrinsics.mem_copy_non_overlapping(raw_data(argument.records[first_record * size:]), raw_data(region[argument.region_start:]), int((kept_records - first_record) * size))
			}
			argument.count = count_given_by_callee[index]
		}
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
			if argument.memory_handle != 0 {
				continue
			}
			size, _, ok := table_record(file, type, function.parameter_details[index])
			if !ok {
				continue
			}
			direction := function.parameter_directions[index]
			capacity := u64(len(argument.records)) / size
			records_in_region := direction == .Append ? capacity - min(argument.count, capacity) : argument.count
			next = (next + 7) &~ 7
			free := next < region_size ? region_size - next : 0
			if records_in_region > free / size {
				return {parameter = index + 1, needed = records_in_region * size, free = free}
			}
			next += records_in_region * size
		}
	}
	return {}
}
