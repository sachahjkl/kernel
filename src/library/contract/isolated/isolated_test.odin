#+build !freestanding
package isolated

import module "modus:contract/module"
import "core:math/rand"
import "core:testing"

@(private = "file")
description :: proc(types: ..module.Type) -> (function: module.Function) {
	function.parameter_count = u8(len(types))
	copy(function.parameters[:], types)
	return function
}

// What encode writes, decode reads: the same integers, and for each Text
// the same bytes, at an address in the call region.
@(test)
arguments_round_trip :: proc(t: ^testing.T) {
	region: [256]u8
	function := description(.Integer, .Text, .Integer, .Text, .Text, .Integer)
	first, second := "the first text", "second"
	arguments := [?]Argument{{integer = 7}, {text = transmute([]u8)first}, {integer = max(u64)}, {text = transmute([]u8)second}, {}, {integer = 1 << 40}}
	offset, size, _, _, encoded := encode(nil, function, arguments[:], region[:])
	testing.expect(t, encoded)
	testing.expect_value(t, size, 3 * 8 + 3 * 16)

	call: Call
	testing.expect(t, decode(nil, function, offset, size, region[:], &call))
	testing.expect_value(t, call.registers[0], 7)
	testing.expect_value(t, call.registers[2], max(u64))
	testing.expect_value(t, call.registers[5], 1 << 40)
	// A Text register has the address of a slice record with the layout of a string.
	testing.expect_value(t, (^string)(uintptr(call.registers[1]))^, first)
	testing.expect_value(t, (^string)(uintptr(call.registers[3]))^, second)
	testing.expect_value(t, (^string)(uintptr(call.registers[4]))^, "")
	low, high := uintptr(&region[0]), uintptr(&region[0]) + len(region)
	for index in ([]int{1, 3, 4}) {
		testing.expect(t, uintptr(call.slices[index].start) >= low && uintptr(call.slices[index].start + call.slices[index].count) <= high)
	}
}

@(test)
encode_refuses :: proc(t: ^testing.T) {
	region: [64]u8
	long: [64]u8
	_, _, _, _, ok := encode(nil, description(.Integer), {}, region[:])
	testing.expect(t, !ok, "the argument count differs from the description")
	_, _, _, _, ok = encode(nil, description(.Text), {{text = long[:]}}, region[:])
	testing.expect(t, !ok, "the text does not fit in the call region")
	_, _, _, _, ok = encode(nil, description(.Text), {{text = long[:48]}}, region[:])
	testing.expect(t, ok, "the text fills the call region exactly")
	_, _, _, _, ok = encode(nil, description(module.Type(200)), {{}}, region[:])
	testing.expect(t, !ok, "the description has an unknown type")
	unknown := description(.Integer)
	unknown.parameter_count = module.PARAMETER_CAPACITY + 1
	_, _, _, _, ok = encode(nil, unknown, {{}}, region[:])
	testing.expect(t, !ok, "the description has too many parameters")
}

// decode refuses each argument record that names memory out of the call region.
@(test)
decode_refuses :: proc(t: ^testing.T) {
	region: [128]u8
	call: Call
	function := description(.Integer, .Text)
	SIZE :: 8 + 16

	Case :: struct {
		offset, size: u64,
		slice:        Slice,
		ok:           bool,
		about:        string,
	}
	cases := [?]Case {
		{offset = 0, size = SIZE, slice = {start = 24, count = 104}, ok = true, about = "a slice to the last byte"},
		{offset = 104, size = SIZE, slice = {start = 0, count = 0}, ok = true, about = "a record at the end"},
		{offset = 0, size = SIZE, slice = {start = 128, count = 0}, ok = true, about = "an empty slice at the end"},
		{offset = 0, size = SIZE, slice = {start = 24, count = 105}, about = "a slice one byte too long"},
		{offset = 0, size = SIZE, slice = {start = 129, count = 0}, about = "a slice that starts after the end"},
		{offset = 0, size = SIZE, slice = {start = 8, count = max(u64)}, about = "a count that wraps"},
		{offset = 0, size = SIZE, slice = {start = max(u64), count = 2}, about = "a start that wraps"},
		{offset = 105, size = SIZE, about = "a record that crosses the end"},
		{offset = max(u64), size = SIZE, about = "a record offset that wraps"},
		{offset = 0, size = SIZE - 8, about = "a record that is too small"},
		{offset = 0, size = SIZE + 8, about = "a record that is too large"},
		{offset = 0, size = max(u64), about = "a size that wraps"},
	}
	for item in cases {
		region = {}
		if item.offset <= len(region) - SIZE {
			store(region[:], item.offset + 8, item.slice)
		}
		testing.expectf(t, decode(nil, function, item.offset, item.size, region[:], &call) == item.ok, "%s", item.about)
	}
}

// With random bytes in the call region and random numbers in the command
// record, decode gives only addresses in the call region.
@(test)
decode_random :: proc(t: ^testing.T) {
	region: [512]u8
	low, high := u64(uintptr(&region[0])), u64(uintptr(&region[0])) + len(region)
	accepted := 0
	for _ in 0 ..< 200_000 {
		function: module.Function
		function.parameter_count = u8(rand.int_max(module.PARAMETER_CAPACITY + 2))
		function.result = module.Type(rand.int_max(4))
		for &type in function.parameters {
			type = module.Type(rand.int_max(4))
		}
		for &b in region[:64] {
			b = u8(rand.uint32())
		}
		// Small numbers most of the time, so that many records pass the checks.
		if rand.int_max(4) != 0 {
			for i := 0; i < 64; i += 8 {
				store(region[:], u64(i), u64(rand.int_max(600)))
			}
		}
		size, _ := record_size(function)
		offset := u64(rand.int_max(8)) * 8
		if rand.int_max(8) == 0 {
			size, offset = rand.uint64(), rand.uint64()
		}
		call: Call
		if !decode(nil, function, offset, size, region[:], &call) {
			continue
		}
		accepted += 1
		types := function.parameters
		count := int(function.parameter_count)
		if function.result == .Text {
			// The buffer of the result is one more slice.
			testing.expect(t, count < module.PARAMETER_CAPACITY)
			types[count] = .Text
			count += 1
		}
		for type, index in types[:count] {
			if type != .Text {
				continue
			}
			slice := call.slices[index]
			testing.expect(t, call.registers[index] == u64(uintptr(&call.slices[index])))
			if slice.start < low || slice.start > high || slice.count > high - slice.start {
				testing.expectf(t, false, "a slice is out of the call region: start %x count %x", slice.start, slice.count)
				return
			}
		}
	}
	testing.expect(t, accepted > 1000, "the test must accept many records")
}

// A Text result: the buffer is the rest of the call region. The callee
// writes there; the caller reads the count that the callee gave, and never
// more than the buffer.
@(test)
text_result :: proc(t: ^testing.T) {
	region: [128]u8
	function := description(.Text, .Integer)
	function.result = .Text
	argument := "abc"
	offset, size, result, _, encoded := encode(nil, function, {{text = transmute([]u8)argument}, {integer = 5}}, region[:])
	testing.expect(t, encoded)
	testing.expect_value(t, size, 16 + 8 + 16)
	testing.expect_value(t, result, Slice{start = 43, count = 85})

	call: Call
	testing.expect(t, decode(nil, function, offset, size, region[:], &call))
	buffer := (^[]u8)(uintptr(call.registers[2]))^
	testing.expect_value(t, len(buffer), 85)
	testing.expect(t, raw_data(buffer) == &region[43])
	copy(buffer, "result")

	text, complete := result_text(region[:], result, 6)
	testing.expect_value(t, string(text), "result")
	testing.expect(t, complete)
	text, complete = result_text(region[:], result, 86)
	testing.expect_value(t, len(text), 85)
	testing.expect(t, !complete, "the callee gave a count larger than the buffer")
	text, complete = result_text(region[:], result, max(u64))
	testing.expect(t, len(text) == 85 && !complete)
	_, complete = result_text(region[:], Slice{start = 100, count = 29}, 1)
	testing.expect(t, !complete, "a buffer that is not in the call region")

	full := description(.Integer, .Integer, .Integer, .Integer, .Integer, .Integer)
	full.result = .Text
	_, _, _, _, ok := encode(nil, full, {{}, {}, {}, {}, {}, {}}, region[:])
	testing.expect(t, !ok, "six parameters leave no register for the buffer")
}

// A module file with one record: {handle at 0, integer at 8}, 16 bytes.
@(private = "file")
record_file :: proc(file: ^[512]u8) -> []u8 {
	Directory :: [module.TABLE_COUNT]module.Table_Entry
	directory: Directory
	offset := u64(size_of(module.Header) + size_of(Directory))
	records := [2]module.Record{1 = {size = 16, first_field = 1, field_count = 2}}
	fields := [3]module.Field{1 = {offset = 0, type = .Handle, detail = 6}, 2 = {offset = 8, type = .Integer}}
	directory[module.Table_Kind.Records] = {offset = offset, count = 2, record_size = size_of(module.Record)}
	(^[2]module.Record)(&file[offset])^ = records
	offset += size_of(records)
	directory[module.Table_Kind.Fields] = {offset = offset, count = 3, record_size = size_of(module.Field)}
	(^[3]module.Field)(&file[offset])^ = fields
	offset += size_of(fields)
	(^module.Header)(&file[0])^ = {magic = module.MAGIC, version = module.VERSION, header_size = size_of(module.Header), machine = .X86_64, table_count = module.TABLE_COUNT}
	(^Directory)(&file[size_of(module.Header)])^ = directory
	return file[:offset]
}

// A module file with one record of 24 bytes: {name: Text(16) at 0, integer at 16}.
@(private = "file")
table_file :: proc(file: ^[512]u8) -> []u8 {
	Directory :: [module.TABLE_COUNT]module.Table_Entry
	directory: Directory
	offset := u64(size_of(module.Header) + size_of(Directory))
	records := [2]module.Record{1 = {size = 24, first_field = 1, field_count = 2}}
	fields := [3]module.Field{1 = {offset = 0, type = .Text, detail = 16}, 2 = {offset = 16, type = .Integer}}
	directory[module.Table_Kind.Records] = {offset = offset, count = 2, record_size = size_of(module.Record)}
	(^[2]module.Record)(&file[offset])^ = records
	offset += size_of(records)
	directory[module.Table_Kind.Fields] = {offset = offset, count = 3, record_size = size_of(module.Field)}
	(^[3]module.Field)(&file[offset])^ = fields
	offset += size_of(fields)
	(^module.Header)(&file[0])^ = {magic = module.MAGIC, version = module.VERSION, header_size = size_of(module.Header), machine = .X86_64, table_count = module.TABLE_COUNT}
	(^Directory)(&file[size_of(module.Header)])^ = directory
	return file[:offset]
}

// A Table result: the buffer is the rest of the call region, from a
// multiple of 8, with a capacity in records. The caller reads the count of
// records that the callee gave, and never more than the buffer.
@(test)
table_result :: proc(t: ^testing.T) {
	storage: [512]u8
	file := table_file(&storage)
	described, valid := module.record_type(file, 1)
	testing.expect(t, valid, "a record with a Text field of 16 bytes is valid")
	testing.expect_value(t, described.size, 24)
	region: [128]u8
	function := description(.Text)
	function.result, function.result_detail = .Table, 1
	argument := "abc"
	offset, size, result, _, encoded := encode(file, function, {{text = transmute([]u8)argument}}, region[:])
	testing.expect(t, encoded)
	testing.expect_value(t, size, 16 + 16)
	// The text ends at 35; the records start at 40: 88 bytes, 3 records.
	testing.expect_value(t, result, Slice{start = 40, count = 3})

	Row :: struct {
		name:  [16]u8,
		value: i64,
	}
	call: Call
	testing.expect(t, decode(file, function, offset, size, region[:], &call))
	rows := (^[]Row)(uintptr(call.registers[1]))^
	testing.expect_value(t, len(rows), 3)
	testing.expect(t, rawptr(raw_data(rows)) == rawptr(&region[40]))
	rows[0].value, rows[1].value = 1, 2
	copy(rows[0].name[:], "one")
	copy(rows[1].name[:], "xxxxxxxxxxxxxxxx")

	bytes, complete := result_table(region[:], result, 2, 24)
	testing.expect(t, complete && len(bytes) == 48)
	item, _ := module.field(file, described, 0)
	testing.expect_value(t, module.field_text(bytes[:24], item), "one")
	testing.expect_value(t, module.field_text(bytes[24:48], item), "xxxxxxxxxxxxxxxx")
	bytes, complete = result_table(region[:], result, 5, 24)
	testing.expect(t, !complete && len(bytes) == 72, "the callee gave a count larger than the buffer")
	_, complete = result_table(region[:], Slice{start = 100, count = 2}, 1, 24)
	testing.expect(t, !complete, "a buffer that is not in the call region")
	// An argument record that names a buffer out of the call region: refused.
	(^Slice)(&region[16])^ = Slice{start = 40, count = 4}
	testing.expect(t, !decode(file, function, offset, size, region[:], &call))
	// A Text field of 0 bytes has no description: its detail is its size.
	storage[size_of(module.Header) + module.TABLE_COUNT * size_of(module.Table_Entry) + 2 * size_of(module.Record) + size_of(module.Field) + 16] = 0
	_, valid = module.record_type(file, 1)
	testing.expect(t, !valid, "a Text field of 0 bytes")
}

// A Record goes as its bytes, a Handle as its number. decode gives a
// private copy of the record, and the list of the handles to prove: the
// Handle parameters and the Handle fields.
@(test)
records_and_handles_round_trip :: proc(t: ^testing.T) {
	storage: [512]u8
	file := record_file(&storage)
	region: [256]u8
	function := description(.Record, .Handle, .Integer)
	function.parameter_details = {0 = 1, 1 = 3}
	function.result, function.result_detail = .Record, 1
	sent := [2]u64{0x1_0007, 99}
	arguments := [?]Argument{{record = ([^]u8)(&sent)[:16]}, {integer = 0x2_0009}, {integer = 5}}
	offset, size, place, _, encoded := encode(file, function, arguments[:], region[:])
	testing.expect(t, encoded)
	testing.expect_value(t, size, 4 * 8)
	testing.expect_value(t, place.count, 16)

	call: Call
	testing.expect(t, decode(file, function, offset, size, region[:], &call))
	received := (^[2]u64)(uintptr(call.registers[0]))
	testing.expect_value(t, received^, sent)
	testing.expect_value(t, call.registers[1], 0x2_0009)
	testing.expect_value(t, call.registers[2], 5)
	testing.expect_value(t, call.lent_count, 2)
	testing.expect_value(t, call.lent[0], Lent{0x1_0007, 6})
	testing.expect_value(t, call.lent[1], Lent{0x2_0009, 3})
	// The copy is private: the other program changes the call region, and
	// the export still reads what decode read.
	for &b in region[int(size):] {
		b = 0xEE
	}
	testing.expect_value(t, received^, sent)
	// The result: the export writes in private memory, result_store copies
	// it to the place that the caller named, and the caller copies it out.
	(^[2]u64)(uintptr(call.registers[3]))^ = {11, 22}
	result_store(function, &call, region[:])
	result: [2]u64
	testing.expect(t, result_record(region[:], place, ([^]u8)(&result)[:16]))
	testing.expect_value(t, result, [2]u64{11, 22})

	// A record of another size, a handle of more than 32 bits, and a
	// record that is not in the call region: refused.
	_, _, _, _, encoded = encode(file, function, {{record = ([^]u8)(&sent)[:8]}, {}, {}}, region[:])
	testing.expect(t, !encoded)
	_, _, _, _, encoded = encode(file, function, {{record = ([^]u8)(&sent)[:16]}, {integer = 1 << 32}, {}}, region[:])
	testing.expect(t, !encoded)
	offset, size, _, _, encoded = encode(file, function, arguments[:], region[:])
	(^u64)(&region[offset])^ = u64(len(region)) - 8
	testing.expect(t, encoded && !decode(file, function, offset, size, region[:], &call))
	// A description that names no record of the module: refused.
	function.parameter_details[0] = 2
	testing.expect(t, !decode(file, function, offset, size, region[:], &call))
}

// An export with an error record: one more field after the field of the
// result, and a place of 56 bytes before the buffer of a Text result. The
// export writes the record there, through the register after the buffer.
@(test)
error_record_place :: proc(t: ^testing.T) {
	region: [256]u8
	for &b in region {
		b = 0xEE
	}
	function := description(.Text)
	function.result = .Text
	function.error_record = 1
	argument := "name"
	offset, size, result, error, encoded := encode(nil, function, {{text = transmute([]u8)argument}}, region[:])
	testing.expect(t, encoded)
	testing.expect_value(t, size, 16 + 16 + 8)
	// The text ends at 44; the error record is at 48, the buffer after it.
	testing.expect_value(t, error, Slice{start = 48, count = ERROR_RECORD_SIZE})
	testing.expect_value(t, result.start, 48 + ERROR_RECORD_SIZE)
	for b in region[48:][:ERROR_RECORD_SIZE] {
		testing.expect_value(t, b, 0)
	}
	call: Call
	testing.expect(t, decode(nil, function, offset, size, region[:], &call))
	testing.expect_value(t, call.registers[2], u64(uintptr(&region[48])))
	testing.expect_value(t, call.error, error)
	// A place out of the call region, or not aligned: refused.
	(^u64)(&region[32])^ = u64(len(region)) - 8
	testing.expect(t, !decode(nil, function, offset, size, region[:], &call))
	(^u64)(&region[32])^ = 49
	testing.expect(t, !decode(nil, function, offset, size, region[:], &call))
	// An export with an error record and six registers: no register is free.
	full := description(.Integer, .Integer, .Integer, .Integer, .Integer, .Integer)
	full.error_record = 1
	_, _, _, _, encoded = encode(nil, full, {{}, {}, {}, {}, {}, {}}, region[:])
	testing.expect(t, !encoded)
}

// The grant of a connection: the amount, the principal and the flag each
// keep their own bits, and a number out of the field cannot reach the flag.
@(test)
the_grant_of_a_connection_names_the_principal :: proc(t: ^testing.T) {
	grant := caller_grant_make(4500, 1, false)
	testing.expect_value(t, grant & CALLER_AMOUNT_MASK, 4500)
	testing.expect_value(t, caller_principal(grant), 1)
	testing.expect(t, grant & CALLER_ACTS_FOR_PRINCIPAL == 0)
	acting := caller_grant_make(0, 0, true)
	testing.expect_value(t, caller_principal(acting), 0)
	testing.expect(t, acting & CALLER_ACTS_FOR_PRINCIPAL != 0)
	testing.expect_value(t, acting & CALLER_AMOUNT_MASK, 0)
	largest := caller_grant_make(CALLER_AMOUNT_MASK + 1, CALLER_PRINCIPAL_LIMIT, false)
	testing.expect_value(t, largest, 0)
	testing.expect_value(t, caller_principal(caller_grant_make(0, CALLER_PRINCIPAL_LIMIT - 1, true)), CALLER_PRINCIPAL_LIMIT - 1)
}
