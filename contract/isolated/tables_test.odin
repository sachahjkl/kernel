#+build !freestanding
package isolated

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
table_of :: proc(directions: ..module.Direction) -> (function: module.Function) {
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
	function := table_of(.Read)
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
	function := table_of(.Change)
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
		function := table_of(.Append)
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
	function := table_of(.Append)
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
	function := table_of(.Append)
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
	function := table_of(.Read, .Change)
	arguments := [2]Argument{{table = {records = make([]u8, 65536 * 16, context.temp_allocator), count = 65536, memory = 0x20005, memory_start = 4096}}, {table = {records = make([]u8, 64, context.temp_allocator), count = 4, memory = 0x20006}}}
	offset, size, _, _, encoded := encode(file, function, arguments[:], region[:])
	testing.expect(t, encoded, "a table of 1 MiB in a memory object needs no room in the call region")
	call: Call
	testing.expect(t, decode(file, function, offset, size, region[:], &call))
	testing.expect_value(t, call.mapping_count, 2)
	testing.expect_value(t, call.mappings[0], Table_Mapping{parameter = 0, handle = 0x20005, start = 4096, size = 65536 * 16, write = false})
	testing.expect_value(t, call.mappings[1].write, true)
	testing.expect_value(t, call.lent_count, 2)
	testing.expect_value(t, transmute(op.Rights)call.lent[0].rights, op.Rights{.Read})
	testing.expect_value(t, transmute(op.Rights)call.lent[1].rights, op.Rights{.Read, .Write})
	// Without the memory object, the table does not fit: room_missing says how much.
	arguments[0].table.memory = 0
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
		{direction = .Append, field = {start = 32, count = 3, capacity = 2}, detail = 1, about = "an Append count larger than its capacity"},
		{direction = .Append, field = {start = 32, count = 0, capacity = 15}, detail = 1, about = "an Append capacity larger than the call region"},
		{direction = .Append, field = {start = 32, count = 10, capacity = 24}, detail = 1, ok = true, about = "an Append table whose free records fit"},
		{field = {start = 32, count = 1}, detail = 2, about = "a record with a Handle field"},
		{field = {start = 32, count = 1}, detail = 7, about = "a record that does not exist"},
		{direction = module.Direction(3), field = {start = 32, count = 1}, detail = 1, about = "a direction out of the enumeration"},
		{field = {start = 32, count = 1, memory = 1 << 32}, detail = 1, about = "a memory handle of more than 32 bits"},
	}
	for item in cases {
		region: [256]u8
		function := table_of(item.direction)
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
			first := place.address + (function.parameter_directions[index] == .Append ? place.count * record_bytes : 0)
			reach := function.parameter_directions[index] == .Append ? place.capacity - place.count : place.count
			if first < low || first > high || reach * record_bytes > high - first {
				testing.expectf(t, false, "a place is out of the call region: %v", place)
				return
			}
		}
	}
	testing.expect(t, accepted > 1000, "the test must accept many records")
}
