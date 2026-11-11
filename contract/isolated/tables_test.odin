#+build !freestanding
package isolated

import "contract:errors"
import module "contract:module"
import op "contract:operation"
import "core:math/rand"
import "core:testing"

// The tests of tables and bytes as parameters: what the caller writes, the
// receiver reads; what the callee answers, the caller copies back, never
// at or after the capacity; each field of a hostile caller is refused.

// A module file with two records:
//   1 Reading {sensor: Unsigned(4) at 0, level: Integer(4) at 4, value: Integer at 8}, 16 bytes
//   2 Lent    {memory: Handle at 0, value: Integer at 8}, 16 bytes
@(private = "file")
two_records_file :: proc(file: ^[1024]u8) -> []u8 {
	Directory :: [module.TABLE_COUNT]module.Table_Entry
	directory: Directory
	offset := u64(size_of(module.Header) + size_of(Directory))
	records := [3]module.Record{1 = {size = 16, first_field = 1, field_count = 3}, 2 = {size = 16, first_field = 4, field_count = 2}}
	fields := [6]module.Field {
		1 = {offset = 0, type = .Integer, detail = 4, unsigned = true},
		2 = {offset = 4, type = .Integer, detail = 4},
		3 = {offset = 8, type = .Integer},
		4 = {offset = 0, type = .Handle, detail = 6},
		5 = {offset = 8, type = .Integer},
	}
	directory[module.Table_Kind.Records] = {offset = offset, count = 3, record_size = size_of(module.Record)}
	(^[3]module.Record)(&file[offset])^ = records
	offset += size_of(records)
	directory[module.Table_Kind.Fields] = {offset = offset, count = 6, record_size = size_of(module.Field)}
	(^[6]module.Field)(&file[offset])^ = fields
	offset += size_of(fields)
	(^module.Header)(&file[0])^ = {magic = module.MAGIC, version = module.VERSION, header_size = size_of(module.Header), machine = .X86_64, table_count = module.TABLE_COUNT}
	(^Directory)(&file[size_of(module.Header)])^ = directory
	return file[:offset]
}

@(private = "file")
Reading :: struct {
	sensor: u32,
	level:  i32,
	value:  i64,
}

@(private = "file")
table_description_of :: proc(directions: ..module.Direction) -> (function: module.Function) {
	function.parameter_count = u8(len(directions))
	for direction, index in directions {
		function.parameters[index] = .Table
		function.parameter_details[index] = 1
		function.parameter_directions[index] = direction
	}
	return function
}

GUARD :: u8(0xA5)

@(private = "file")
bytes_of :: proc(memory: rawptr, count: int) -> []u8 {
	return ([^]u8)(memory)[:count]
}

@(test)
integer_fields_of_each_size :: proc(t: ^testing.T) {
	storage: [1024]u8
	file := two_records_file(&storage)
	described, ok := module.record_type(file, 1)
	testing.expect(t, ok, "a record with fields of 4 bytes is valid")
	testing.expect_value(t, module.record_alignment(file, described), 8)
	reading := Reading{sensor = 0xFFFF_FFF0, level = -3, value = -5}
	bytes := transmute([16]u8)reading
	sensor, _ := module.field(file, described, 0)
	level, _ := module.field(file, described, 1)
	value, _ := module.field(file, described, 2)
	testing.expect_value(t, module.field_integer(bytes[:], sensor), 0xFFFF_FFF0)
	testing.expect_value(t, module.field_integer(bytes[:], level), -3)
	testing.expect_value(t, module.field_integer(bytes[:], value), -5)
	module.field_integer_set(bytes[:], level, 70000)
	testing.expect_value(t, (transmute(Reading)bytes).level, 70000)
	testing.expect_value(t, (transmute(Reading)bytes).value, -5)
	// An Integer of 4 bytes at an offset that is not a multiple of 4.
	field_place := len(file) - 6 * size_of(module.Field) + 2 * size_of(module.Field) // Field 2: level.
	(^u32)(&file[field_place + int(offset_of(module.Field, offset))])^ = 2
	_, ok = module.record_type(file, 1)
	testing.expect(t, !ok, "an Integer of 4 bytes at offset 2 is refused")
}

// Read: the caller copies the records into the call region; the export
// reads them there; nothing comes back.
@(test)
read_table_round_trip :: proc(t: ^testing.T) {
	storage: [1024]u8
	file := two_records_file(&storage)
	rows := [4]Reading{{1, -1, 10}, {2, -2, 20}, {3, -3, 30}, {}}
	region: [256]u8
	function := table_description_of(.Read)
	function.result = .Integer
	arguments := [1]Argument{{table = {records = bytes_of(&rows, 64), count = 3}}}
	offset, size, _, _, encoded := encode(file, function, arguments[:], region[:])
	testing.expect(t, encoded)
	testing.expect_value(t, size, 32)
	call: Call
	testing.expect(t, decode(file, function, offset, size, region[:], &call))
	place := (^module.Table_Place)(uintptr(call.registers[0]))
	testing.expect(t, place == &call.places[0], "the place is a copy in memory of the receiver")
	testing.expect_value(t, place.count, 3)
	testing.expect_value(t, place.capacity, 3)
	got := ([^]Reading)(uintptr(place.address))[:place.count]
	testing.expect(t, uintptr(place.address) == uintptr(&region[32]), "the records follow the argument record, at a multiple of 8")
	testing.expect_value(t, got[2].value, 30)
	testing.expect_value(t, got[1].level, -2)
	problem, _ := tables_return(file, function, arguments[:], region[:], offset)
	testing.expect_value(t, problem, Return_Problem.None)
	testing.expect_value(t, arguments[0].table.count, 3)
}

// Change: the export changes the records in the call region; the caller
// copies the count records back, and nothing after them.
@(test)
change_table_round_trip :: proc(t: ^testing.T) {
	storage: [1024]u8
	file := two_records_file(&storage)
	memory: [6]Reading
	memory[0], memory[1] = {1, 0, 10}, {2, 0, 20}
	guard := (^[32]u8)(&memory[4])
	for &b in guard {
		b = GUARD
	}
	region: [256]u8
	function := table_description_of(.Change)
	arguments := [1]Argument{{table = {records = bytes_of(&memory, 64), count = 2}}}
	offset, size, _, _, encoded := encode(file, function, arguments[:], region[:])
	testing.expect(t, encoded)
	call: Call
	testing.expect(t, decode(file, function, offset, size, region[:], &call))
	place := (^module.Table_Place)(uintptr(call.registers[0]))
	got := ([^]Reading)(uintptr(place.address))
	got[0].value, got[1].value = 11, 21
	// A hostile export writes the whole call region after the records.
	for &b in region[32 + 32:] {
		b = 0xEE
	}
	counts_store(function, &call, region[:])
	problem, _ := tables_return(file, function, arguments[:], region[:], offset)
	testing.expect_value(t, problem, Return_Problem.None)
	testing.expect_value(t, memory[0].value, 11)
	testing.expect_value(t, memory[1].value, 21)
	testing.expect_value(t, memory[2], Reading{})
	for b in guard {
		testing.expect_value(t, b, GUARD)
	}
}

// Append: the call region holds only the free records; record `count` of
// the place is the first of them. The caller copies back the appended
// records up to the capacity, and keeps the count of the full answer.
@(test)
append_table_round_trip :: proc(t: ^testing.T) {
	storage: [1024]u8
	file := two_records_file(&storage)
	memory: [7]Reading // 5 for the table, then a guard of 2 records.
	memory[0], memory[1] = {1, 0, 10}, {2, 0, 20}
	guard := (^[32]u8)(&memory[5])
	for &b in guard {
		b = GUARD
	}
	for answer in ([]u64{4, 5, 9}) {
		region: [256]u8
		memory[2], memory[3], memory[4] = {}, {}, {}
		function := table_description_of(.Append)
		function.result = .Integer
		arguments := [1]Argument{{table = {records = bytes_of(&memory, 80), count = 2}}}
		offset, size, _, _, encoded := encode(file, function, arguments[:], region[:])
		testing.expect(t, encoded)
		call: Call
		testing.expect(t, decode(file, function, offset, size, region[:], &call))
		place := (^module.Table_Place)(uintptr(call.registers[0]))
		testing.expect_value(t, place.count, 2)
		testing.expect_value(t, place.capacity, 5)
		records := ([^]Reading)(uintptr(place.address))
		testing.expect(t, uintptr(&records[2]) == uintptr(&region[32]), "record count is the first reserved byte")
		for index in place.count ..< min(answer, place.capacity) {
			records[index] = {u32(index + 1), 0, i64(index + 1) * 10}
		}
		place.count = answer
		// A hostile export writes the rest of the call region.
		for &b in region[32 + 3 * 16:] {
			b = 0xEE
		}
		counts_store(function, &call, region[:])
		problem, _ := tables_return(file, function, arguments[:], region[:], offset)
		testing.expect_value(t, problem, Return_Problem.None)
		testing.expect_value(t, arguments[0].table.count, answer)
		testing.expect_value(t, memory[0].value, 10)
		testing.expect_value(t, memory[3].value, 40)
		testing.expectf(t, memory[4].value == (answer >= 5 ? 50 : 0), "answer %d: record 4 is %v", answer, memory[4])
		for b in guard {
			testing.expect_value(t, b, GUARD)
		}
	}
}

// A callee that gives a count smaller than the count on entry: the caller
// keeps its count and copies nothing.
@(test)
append_count_smaller :: proc(t: ^testing.T) {
	storage: [1024]u8
	file := two_records_file(&storage)
	memory: [4]Reading
	region: [256]u8
	function := table_description_of(.Append)
	arguments := [1]Argument{{table = {records = bytes_of(&memory, 64), count = 2}}}
	offset, size, _, _, _ := encode(file, function, arguments[:], region[:])
	call: Call
	testing.expect(t, decode(file, function, offset, size, region[:], &call))
	call.places[0].count = 1
	counts_store(function, &call, region[:])
	problem, parameter := tables_return(file, function, arguments[:], region[:], offset)
	testing.expect_value(t, problem, Return_Problem.Count_Smaller)
	testing.expect_value(t, parameter, 1)
	testing.expect_value(t, arguments[0].table.count, 2)
}

// A capacity of 0: valid; the export writes nothing and gives a count.
@(test)
append_capacity_zero :: proc(t: ^testing.T) {
	storage: [1024]u8
	file := two_records_file(&storage)
	region: [64]u8
	function := table_description_of(.Append)
	arguments := [1]Argument{{table = {}}}
	offset, size, _, _, encoded := encode(file, function, arguments[:], region[:])
	testing.expect(t, encoded)
	call: Call
	testing.expect(t, decode(file, function, offset, size, region[:], &call))
	testing.expect_value(t, call.places[0].capacity, 0)
	call.places[0].count = 7
	counts_store(function, &call, region[:])
	problem, _ := tables_return(file, function, arguments[:], region[:], offset)
	testing.expect_value(t, problem, Return_Problem.None)
	testing.expect_value(t, arguments[0].table.count, 7)
}

// Bytes: a Read range and an Append range in one call.
@(test)
bytes_round_trip :: proc(t: ^testing.T) {
	region: [128]u8
	function: module.Function
	function.parameter_count = 2
	function.parameters[0], function.parameters[1] = .Bytes, .Bytes
	function.parameter_directions[1] = .Append
	text := "hello"
	out: [12]u8
	copy(out[:], "ab")
	for &b in out[8:] {
		b = GUARD
	}
	arguments := [2]Argument{{table = {records = transmute([]u8)text, count = 5}}, {table = {records = out[:8], count = 2}}}
	offset, size, _, _, encoded := encode(nil, function, arguments[:], region[:])
	testing.expect(t, encoded)
	testing.expect_value(t, size, 64)
	call: Call
	testing.expect(t, decode(nil, function, offset, size, region[:], &call))
	read := (^module.Table_Place)(uintptr(call.registers[0]))
	testing.expect_value(t, string(([^]u8)(uintptr(read.address))[:read.count]), "hello")
	appended := (^module.Table_Place)(uintptr(call.registers[1]))
	written := ([^]u8)(uintptr(appended.address))
	copy(written[appended.count:appended.capacity], "cdefghij") // 6 fit.
	appended.count += 8
	counts_store(function, &call, region[:])
	problem, _ := tables_return(nil, function, arguments[:], region[:], offset)
	testing.expect_value(t, problem, Return_Problem.None)
	testing.expect_value(t, string(out[:8]), "abcdefgh")
	testing.expect_value(t, arguments[1].table.count, 10)
	for b in out[8:] {
		testing.expect_value(t, b, GUARD)
	}
}

// A table in a memory object: the field names the lent handle; decode
// lists it to map, with the rights of the direction, and copies nothing.
@(test)
memory_object_table :: proc(t: ^testing.T) {
	storage: [1024]u8
	file := two_records_file(&storage)
	region: [128]u8
	function := table_description_of(.Read, .Change)
	arguments := [2]Argument{{table = {records = make([]u8, 65536 * 16, context.temp_allocator), count = 65536, memory_handle = 0x20005, memory_start = 4096}}, {table = {records = make([]u8, 64, context.temp_allocator), count = 4, memory_handle = 0x20006}}}
	offset, size, _, _, encoded := encode(file, function, arguments[:], region[:])
	testing.expect(t, encoded, "a table of 1 MiB in a memory object needs no room in the call region")
	call: Call
	testing.expect(t, decode(file, function, offset, size, region[:], &call))
	testing.expect_value(t, call.mapping_count, 2)
	testing.expect_value(t, call.mappings[0], Table_Mapping{parameter = 0, handle = 0x20005, start = 4096, size = 65536 * 16, writable = false})
	testing.expect_value(t, call.mappings[1].writable, true)
	testing.expect_value(t, call.lent_count, 2)
	testing.expect_value(t, transmute(op.Rights)call.lent[0].rights, op.Rights{.Read})
	testing.expect_value(t, transmute(op.Rights)call.lent[1].rights, op.Rights{.Read, .Write})
	// Without the memory object, the table does not fit: room_missing says how much.
	arguments[0].table.memory_handle = 0
	_, _, _, _, encoded = encode(file, function, arguments[:], region[:])
	testing.expect(t, !encoded)
	missing := room_missing(file, function, arguments[:], 65536)
	testing.expect_value(t, missing.parameter, 1)
	testing.expect_value(t, missing.needed, 65536 * 16)
	testing.expect_value(t, missing.free, 65536 - 64)
}

// decode refuses each table field of a hostile caller.
@(test)
decode_refuses_tables :: proc(t: ^testing.T) {
	storage: [1024]u8
	file := two_records_file(&storage)
	Case :: struct {
		direction: module.Direction,
		field:     Table_Field,
		detail:    u32,
		ok:        bool,
		about:     string,
	}
	SIZE :: 32
	cases := [?]Case {
		{field = {start = 32, count = 14}, detail = 1, ok = true, about = "14 records to the last byte"},
		{field = {start = 32, count = 15}, detail = 1, about = "a count larger than the call region"},
		{field = {start = 36, count = 1}, detail = 1, about = "a start that is not a multiple of 8"},
		{field = {start = 32, count = max(u64)}, detail = 1, about = "a count that wraps"},
		{field = {start = max(u64) - 7, count = 1}, detail = 1, about = "a start that wraps"},
		{direction = .Append, field = {start = 32, count = 3, capacity = 2}, detail = 1, ok = true, about = "an Append count larger than its capacity: earlier calls did not fit"},
		{direction = .Append, field = {start = 32, count = 0, capacity = 15}, detail = 1, about = "an Append capacity larger than the call region"},
		{direction = .Append, field = {start = 32, count = 10, capacity = 24}, detail = 1, ok = true, about = "an Append table whose free records fit"},
		{field = {start = 32, count = 1}, detail = 2, about = "a record with a Handle field"},
		{field = {start = 32, count = 1}, detail = 7, about = "a record that does not exist"},
		{direction = module.Direction(3), field = {start = 32, count = 1}, detail = 1, about = "a direction out of the enumeration"},
		{field = {start = 32, count = 1, memory_handle = 1 << 32}, detail = 1, about = "a memory handle of more than 32 bits"},
	}
	for item in cases {
		region: [256]u8
		function := table_description_of(item.direction)
		function.parameter_details[0] = item.detail
		store(region[:], 0, item.field)
		call: Call
		testing.expectf(t, decode(file, function, 0, SIZE, region[:], &call) == item.ok, "%s", item.about)
	}
	// A direction on a parameter that is not a Table or Bytes.
	function: module.Function
	function.parameter_count = 1
	function.parameters[0] = .Integer
	function.parameter_directions[0] = .Change
	_, valid := record_size(function)
	testing.expect(t, !valid, "an Integer with the direction Change")
}

// With random fields, decode gives only places inside the call region.
@(test)
decode_random_tables :: proc(t: ^testing.T) {
	storage: [1024]u8
	file := two_records_file(&storage)
	region: [1024]u8
	low, high := u64(uintptr(&region[0])), u64(uintptr(&region[0])) + len(region)
	accepted := 0
	for _ in 0 ..< 100_000 {
		function: module.Function
		function.parameter_count = u8(1 + rand.int_max(3))
		for index in 0 ..< int(function.parameter_count) {
			function.parameters[index] = rand.int_max(2) == 0 ? .Table : .Bytes
			function.parameter_details[index] = function.parameters[index] == .Table ? 1 : 0
			function.parameter_directions[index] = module.Direction(rand.int_max(3))
		}
		for i := 0; i < 96; i += 8 {
			store(region[:], u64(i), rand.int_max(4) == 0 ? rand.uint64() : u64(rand.int_max(80)) * (rand.int_max(2) == 0 ? 8 : 1))
		}
		for index in 0 ..< int(function.parameter_count) {
			store(region[:], u64(index) * 32 + 24, u64(0)) // The call region, not a memory object.
		}
		size, _ := record_size(function)
		call: Call
		if !decode(file, function, 0, size, region[:], &call) {
			continue
		}
		accepted += 1
		for type, index in function.parameters[:function.parameter_count] {
			place := call.places[index]
			record_bytes: u64 = type == .Table ? 16 : 1
			// An Append count can be larger than the capacity (calls before
			// did not fit): the callee then has no free place.
			filled := min(place.count, place.capacity)
			first := place.address + (function.parameter_directions[index] == .Append ? filled * record_bytes : 0)
			reach := function.parameter_directions[index] == .Append ? place.capacity - filled : place.count
			if first < low || first > high || reach * record_bytes > high - first {
				testing.expectf(t, false, "a place is out of the call region: %v", place)
				return
			}
		}
	}
	testing.expect(t, accepted > 1000, "the test must accept many records")
}

// An Append place near 2^64 (finding F1 of the hostile read): 8 free bytes
// at the end of the call region, with a count and a capacity that do not
// fit in TABLE_SPAN. decode refuses it: no count times a size wraps.
@(test)
decode_refuses_counts_near_the_end_of_the_numbers :: proc(t: ^testing.T) {
	region := make([]u8, 65536, context.temp_allocator)
	function: module.Function
	function.parameter_count = 1
	function.parameters[0] = .Bytes
	function.parameter_directions[0] = .Append
	store(region, 0, Table_Field{start = 65528, count = max(u64) - 9, capacity = max(u64) - 1})
	call: Call
	testing.expect(t, !decode(nil, function, 0, 32, region, &call), "a capacity of 2^64 - 1 bytes in the call region")
	function.parameters[0], function.parameter_details[0] = .Table, 1
	storage: [1024]u8
	file := two_records_file(&storage)
	store(region, 0, Table_Field{start = 65520, count = max(u64) / 16, capacity = max(u64) / 16 + 1})
	testing.expect(t, !decode(file, function, 0, 32, region, &call), "a capacity of 2^60 records of 16 bytes in the call region")
	store(region, 0, Table_Field{start = 65520, count = 0, capacity = 1})
	testing.expect(t, decode(file, function, 0, 32, region, &call), "one record at the end of the call region")
}

// Ranges of the call region that overlap, where one of them is written
// (finding W3 of the hostile read): decode refuses them, with an error
// record of the kind Overlap. Two ranges that are only read can overlap.
@(test)
decode_refuses_ranges_that_overlap :: proc(t: ^testing.T) {
	storage: [1024]u8
	file := two_records_file(&storage)
	Case :: struct {
		directions: [2]module.Direction,
		first:      Table_Field,
		second:     Table_Field,
		ok:         bool,
		about:      string,
	}
	cases := [?]Case {
		{{.Read, .Read}, {start = 64, count = 2}, {start = 64, count = 2}, true, "two Read tables on the same bytes"},
		{{.Change, .Change}, {start = 64, count = 2}, {start = 64, count = 2}, false, "two Change tables on the same bytes"},
		{{.Read, .Append}, {start = 80, count = 1}, {start = 64, count = 0, capacity = 3}, false, "a Read table inside an Append table"},
		{{.Change, .Read}, {start = 0, count = 2}, {start = 64, count = 1}, false, "a Change table over the argument record"},
		{{.Change, .Change}, {start = 64, count = 2}, {start = 96, count = 2}, true, "two Change tables side by side"},
	}
	for item in cases {
		region: [256]u8
		function := table_description_of(item.directions[0], item.directions[1])
		store(region[:], 0, item.first)
		store(region[:], 32, item.second)
		call: Call
		refusal: errors.Error_Record
		accepted := decode(file, function, 0, 64, region[:], &call, &refusal)
		testing.expectf(t, accepted == item.ok, "%s", item.about)
		if !item.ok {
			testing.expectf(t, errors.Kind(refusal.kind) == .Overlap, "%s: the kind %v", item.about, refusal.kind)
		}
	}
	// A Change table over the place of the error record.
	region: [256]u8
	function := table_description_of(.Change)
	function.result = .Integer
	function.error_record = 1
	store(region[:], 0, Table_Field{start = 48, count = 2})
	store(region[:], 32, u64(48))
	call: Call
	testing.expect(t, !decode(file, function, 0, 40, region[:], &call), "a Change table over the error record")
}

// A refusal of decode says which argument and why (finding W8).
@(test)
decode_refusal_is_an_error_record :: proc(t: ^testing.T) {
	storage: [1024]u8
	file := two_records_file(&storage)
	region: [256]u8
	function := table_description_of(.Read, .Read)
	store(region[:], 0, Table_Field{start = 64, count = 1})
	store(region[:], 32, Table_Field{start = 64, count = 15})
	call: Call
	refusal: errors.Error_Record
	testing.expect(t, !decode(file, function, 0, 64, region[:], &call, &refusal))
	testing.expect_value(t, errors.Kind(refusal.kind), errors.Kind.Out_Of_Range)
	testing.expect_value(t, refusal.argument, 2)
	testing.expect_value(t, refusal.value, 64 + 15 * 16)
	testing.expect_value(t, refusal.limit, 256)
	store(region[:], 32, Table_Field{start = 68, count = 1})
	refusal = {}
	testing.expect(t, !decode(file, function, 0, 64, region[:], &call, &refusal))
	testing.expect_value(t, refusal.argument, 2)
	testing.expect_value(t, errors.Kind(refusal.kind), errors.Kind.Bad_Value)
}

// A table in a memory object reaches at most TABLE_SPAN less one page: the
// mapping of its pages never enters the span of the next parameter (N2).
@(test)
memory_object_table_stays_in_its_span :: proc(t: ^testing.T) {
	region: [128]u8
	function: module.Function
	function.parameter_count = 1
	function.parameters[0] = .Bytes
	store(region[:], 0, Table_Field{start = 4095, count = TABLE_SPAN - 1, memory_handle = 0x20005})
	call: Call
	testing.expect(t, !decode(nil, function, 0, 32, region[:], &call), "16 GiB less one byte from the last byte of a page")
	store(region[:], 0, Table_Field{start = 4095, count = TABLE_SPAN - module.PAGE_SIZE, memory_handle = 0x20005})
	testing.expect(t, decode(nil, function, 0, 32, region[:], &call), "16 GiB less one page")
}

// A record whose size is not a multiple of its alignment is not valid (N1).
@(test)
record_size_is_a_multiple_of_its_alignment :: proc(t: ^testing.T) {
	storage: [1024]u8
	file := two_records_file(&storage)
	_, valid := module.record_type(file, 1)
	testing.expect(t, valid, "16 bytes, alignment 8")
	directory_place := size_of(module.Header) + int(module.Table_Kind.Records) * size_of(module.Table_Entry)
	records_offset := (^module.Table_Entry)(&file[directory_place]).offset
	(^module.Record)(&file[records_offset + size_of(module.Record)]).size = 20
	_, ok := module.record_type(file, 1)
	testing.expect(t, !ok, "20 bytes, alignment 8")
}

// When the answer of the second table is wrong, the count of the first
// table does not change either (finding W7).
@(test)
tables_return_changes_nothing_on_a_problem :: proc(t: ^testing.T) {
	storage: [1024]u8
	file := two_records_file(&storage)
	first, second: [4]Reading
	region: [512]u8
	function := table_description_of(.Append, .Append)
	arguments := [2]Argument{{table = {records = bytes_of(&first, 64), count = 1}}, {table = {records = bytes_of(&second, 64), count = 2}}}
	offset, size, _, _, encoded := encode(file, function, arguments[:], region[:])
	testing.expect(t, encoded)
	call: Call
	testing.expect(t, decode(file, function, offset, size, region[:], &call))
	call.places[0].count = 3
	call.places[1].count = 1 // Smaller than the count on entry.
	counts_store(function, &call, region[:])
	problem, parameter := tables_return(file, function, arguments[:], region[:], offset)
	testing.expect_value(t, problem, Return_Problem.Count_Smaller)
	testing.expect_value(t, parameter, 2)
	testing.expect_value(t, arguments[0].table.count, 1)
	testing.expect_value(t, arguments[1].table.count, 2)
	// A record description that is not valid is its own problem.
	broken := function
	broken.parameter_details[1] = 9
	problem, parameter = tables_return(file, broken, arguments[:], region[:], offset)
	testing.expect_value(t, problem, Return_Problem.Bad_Description)
}

// A value that an Integer field of its size does not hold (N4 of the
// hostile read): field_integer_fits says so, so that a caller refuses it
// with a sentence and does not cut it (300 in a u8 was 44).
@(test)
field_integer_fits_its_size :: proc(t: ^testing.T) {
	storage: [1024]u8
	file := two_records_file(&storage)
	described, _ := module.record_type(file, 1)
	sensor, _ := module.field(file, described, 0) // Unsigned(4)
	level, _ := module.field(file, described, 1) // Integer(4)
	value, _ := module.field(file, described, 2) // Integer
	testing.expect(t, module.field_integer_fits(sensor, 0xFFFF_FFFF))
	testing.expect(t, !module.field_integer_fits(sensor, 0x1_0000_0000))
	testing.expect(t, !module.field_integer_fits(sensor, -1))
	testing.expect(t, module.field_integer_fits(level, -0x8000_0000))
	testing.expect(t, !module.field_integer_fits(level, 0x8000_0000))
	testing.expect(t, module.field_integer_fits(value, min(i64)))
}

// The Append rule across calls (decision of the coordinator after the
// second hostile read): the same sequence of calls on one table that does
// not fit gives the same counts and the same records in a direct call and
// in an isolated call (a call host and a service use the same encode,
// decode, counts_store and tables_return: the region form). The callee
// appends 3 readings at each call; the table has 4 places; 3 calls.
@(private = "file")
append_three_readings :: proc(place: ^module.Table_Place) {
	records := ([^]Reading)(uintptr(place.address))
	for _ in 0 ..< 3 {
		if place.count < place.capacity {
			records[place.count] = {sensor = u32(place.count + 1), value = i64(place.count + 1) * 10}
		}
		place.count += 1
	}
}

@(test)
append_across_calls_is_the_same_in_each_way :: proc(t: ^testing.T) {
	storage: [1024]u8
	file := two_records_file(&storage)
	function := table_description_of(.Append)
	function.result = .Integer
	direct_memory, isolated_memory: [6]Reading // 4 places, then a guard of 2 records.
	guard_fill(bytes_of(&direct_memory[4], 32))
	guard_fill(bytes_of(&isolated_memory[4], 32))
	direct_place := module.Table_Place{address = u64(uintptr(&direct_memory[0])), count = 0, capacity = 4}
	isolated_argument := [1]Argument{{table = {records = bytes_of(&isolated_memory, 4 * 16), count = 0}}}
	expected_counts := [3]u64{3, 6, 9}
	for call_number in 0 ..< 3 {
		// The direct call: the callee works in the memory of the caller.
		append_three_readings(&direct_place)
		// The isolated call.
		region: [512]u8
		offset, size, _, _, encoded := encode(file, function, isolated_argument[:], region[:])
		testing.expectf(t, encoded, "call %d: encode takes a count of %d over a capacity of 4", call_number + 1, isolated_argument[0].table.count)
		call: Call
		testing.expectf(t, decode(file, function, offset, size, region[:], &call), "call %d: decode", call_number + 1)
		append_three_readings(&call.places[0])
		counts_store(function, &call, region[:])
		problem, _ := tables_return(file, function, isolated_argument[:], region[:], offset)
		testing.expect_value(t, problem, Return_Problem.None)
		testing.expect_value(t, direct_place.count, expected_counts[call_number])
		testing.expect_value(t, isolated_argument[0].table.count, expected_counts[call_number])
	}
	testing.expect(t, (^[4]Reading)(&direct_memory[0])^ == (^[4]Reading)(&isolated_memory[0])^, "the same 4 records in the two ways")
	testing.expect_value(t, isolated_memory[3].value, 40)
	testing.expect(t, guard_holds_bytes(bytes_of(&direct_memory[4], 32)) && guard_holds_bytes(bytes_of(&isolated_memory[4], 32)), "no write at or after the capacity")
}

@(private = "file")
guard_fill :: proc(bytes: []u8) {
	for &b in bytes {
		b = GUARD
	}
}

@(private = "file")
guard_holds_bytes :: proc(bytes: []u8) -> bool {
	for b in bytes {
		if b != GUARD {
			return false
		}
	}
	return true
}
