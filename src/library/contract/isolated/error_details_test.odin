#+build !freestanding
package isolated

import "modus:contract/errors"
import module "modus:contract/module"
import "core:testing"

// The tests of the table of error details (docs/MODULE_CONTRACT.md, section
// 8, "The table of error details"): a reader finds it in the description;
// the same call gives the same details and the same count in a direct call
// and in an isolated call (a call host and a service use the same encode,
// decode, counts_store and error_details_return); after a failure only the
// details come back.

// A module file with two records:
//   1 Error_Record {kind, unit, operation, argument, value, limit, found: Integer}, 56 bytes
//   2 Reading      {sensor: Unsigned(4) at 0, level: Integer(4) at 4, value: Integer at 8}, 16 bytes
@(private = "file")
error_and_reading_file :: proc(file: ^[2048]u8) -> []u8 {
	Directory :: [module.TABLE_COUNT]module.Table_Entry
	directory: Directory
	offset := u64(size_of(module.Header) + size_of(Directory))
	records := [3]module.Record{1 = {size = 56, first_field = 1, field_count = 7}, 2 = {size = 16, first_field = 8, field_count = 3}}
	fields := [11]module.Field {
		1  = {offset = 0, type = .Integer},
		2  = {offset = 8, type = .Integer},
		3  = {offset = 16, type = .Integer},
		4  = {offset = 24, type = .Integer},
		5  = {offset = 32, type = .Integer},
		6  = {offset = 40, type = .Integer},
		7  = {offset = 48, type = .Integer},
		8  = {offset = 0, type = .Integer, detail = 4, unsigned = true},
		9  = {offset = 4, type = .Integer, detail = 4},
		10 = {offset = 8, type = .Integer},
	}
	directory[module.Table_Kind.Records] = {offset = offset, count = 3, record_size = size_of(module.Record)}
	(^[3]module.Record)(&file[offset])^ = records
	offset += size_of(records)
	directory[module.Table_Kind.Fields] = {offset = offset, count = 11, record_size = size_of(module.Field)}
	(^[11]module.Field)(&file[offset])^ = fields
	offset += size_of(fields)
	(^module.Header)(&file[0])^ = {magic = module.MAGIC, version = module.VERSION, header_size = size_of(module.Header), machine = .X86_64, table_count = module.TABLE_COUNT}
	(^Directory)(&file[size_of(module.Header)])^ = directory
	return file[:offset]
}

@(private = "file")
Reading_Row :: struct {
	sensor: u32,
	level:  i32,
	value:  i64,
}

// The description of
//   double_and_refuse_odd (readings: Table(Reading, Change), details: Table(Error_Record, Append), error) -> Integer
@(private = "file")
double_and_refuse_odd_description :: proc() -> (function: module.Function) {
	function.parameter_count = 2
	function.parameters[0], function.parameter_details[0], function.parameter_directions[0] = .Table, 2, .Change
	function.parameters[1], function.parameter_details[1], function.parameter_directions[1] = .Table, 1, .Append
	function.error_record = 1
	function.result = .Integer
	return function
}

// The export of the test: it doubles the value of each reading, and refuses
// each reading with an odd sensor: one error detail for each, in the order
// of the rows. Its error record is the first detail. It works on table
// places, as an export does in each way to call.
@(private = "file")
double_and_refuse_odd :: proc(readings: ^module.Table_Place, details: ^module.Table_Place, error: ^errors.Error_Record) -> i64 {
	rows := ([^]Reading_Row)(uintptr(readings.address))[:readings.count]
	written := ([^]errors.Error_Record)(uintptr(details.address))
	problems := 0
	for &row, number in rows {
		row.value *= 2
		if row.sensor % 2 == 1 {
			detail := errors.error_make(.Bad_Value, .None, 1, i64(row.sensor), 0, i64(number + 1))
			if problems == 0 {
				error^ = detail
			}
			problems += 1
			if details.count < details.capacity {
				written[details.count] = detail
			}
			details.count += 1
		}
	}
	return problems == 0 ? i64(len(rows)) : -1
}

@(test)
error_details_parameter_is_found_by_its_form :: proc(t: ^testing.T) {
	storage: [2048]u8
	file := error_and_reading_file(&storage)
	function := double_and_refuse_odd_description()
	index, found := module.error_details_parameter(file, function)
	testing.expect(t, found && index == 1, "the last parameter, Append, of the record of the error record")
	read_only := function
	read_only.parameter_directions[1] = .Read
	_, found = module.error_details_parameter(file, read_only)
	testing.expect(t, !found, "a table to read is not a table of error details")
	no_error_record := function
	no_error_record.error_record = 0
	_, found = module.error_details_parameter(file, no_error_record)
	testing.expect(t, !found, "an export with no error record has no table of error details")
	other_record := function
	other_record.parameter_details[1] = 2
	_, found = module.error_details_parameter(file, other_record)
	testing.expect(t, !found, "an Append table of another record is not a table of error details")
	first_only := function
	first_only.parameter_count = 1
	_, found = module.error_details_parameter(file, first_only)
	testing.expect(t, !found, "the table of error details is the last parameter")
}

// The same call in two ways: the same details, the same count, and the
// same error record. The table has 2 places; the call has 3 details: the
// count says that one did not fit. In the isolated way the Change table
// does not come back, because the call failed; only the details do.
@(test)
error_details_are_the_same_in_each_way :: proc(t: ^testing.T) {
	storage: [2048]u8
	file := error_and_reading_file(&storage)
	function := double_and_refuse_odd_description()
	rows := [4]Reading_Row{{1, 0, 10}, {2, 0, 20}, {3, 0, 30}, {5, 0, 50}}

	// The direct call: the export works in the memory of the caller.
	direct_rows := rows
	direct_details: [3]errors.Error_Record // 2 places, then a guard record.
	direct_details[2] = {kind = 99}
	direct_readings := module.Table_Place{address = u64(uintptr(&direct_rows[0])), count = 4, capacity = 4}
	direct_place := module.Table_Place{address = u64(uintptr(&direct_details[0])), count = 0, capacity = 2}
	direct_error: errors.Error_Record
	direct_result := double_and_refuse_odd(&direct_readings, &direct_place, &direct_error)

	// The isolated call: encode, decode, the export, counts_store, and what
	// the caller copies back after a failure.
	isolated_rows := rows
	isolated_details: [3]errors.Error_Record
	isolated_details[2] = {kind = 99}
	arguments := [2]Argument{{table = {records = bytes_of_memory(&isolated_rows, size_of(isolated_rows)), count = 4}}, {table = {records = bytes_of_memory(&isolated_details, 2 * size_of(errors.Error_Record)), count = 0}}}
	region: [1024]u8
	offset, size, _, error_place, encoded := encode(file, function, arguments[:], region[:])
	testing.expect(t, encoded, "encode")
	testing.expect(t, error_place.count == ERROR_RECORD_SIZE, "the place of the error record")
	call: Call
	testing.expect(t, decode(file, function, offset, size, region[:], &call), "decode")
	isolated_result := double_and_refuse_odd(&call.places[0], &call.places[1], (^errors.Error_Record)(&region[error_place.start]))
	counts_store(function, &call, region[:])
	isolated_error := (^errors.Error_Record)(&region[error_place.start])^
	problem, _ := error_details_return(file, function, arguments[:], region[:], offset)
	testing.expect_value(t, problem, Return_Problem.None)

	testing.expect_value(t, direct_result, -1)
	testing.expect_value(t, isolated_result, -1)
	testing.expect_value(t, direct_place.count, 3)
	testing.expect_value(t, arguments[1].table.count, 3)
	testing.expect(t, direct_details == isolated_details, "the same details, and the guard record after the capacity is not written")
	testing.expect_value(t, direct_details[2].kind, 99)
	testing.expect_value(t, direct_details[1].value, 3)
	testing.expect_value(t, direct_details[1].found, 3)
	testing.expect(t, direct_error == isolated_error, "the same error record")
	testing.expect(t, direct_error == direct_details[0], "the error record is the first detail")
	testing.expect(t, isolated_rows == rows, "a failed isolated call gives back no other table")
	testing.expect_value(t, direct_rows[0].value, 20)
}

// A caller with a table of capacity 0 (the isolated form of "no table")
// learns the count, and no byte of its memory is written.
@(test)
error_details_with_no_place :: proc(t: ^testing.T) {
	storage: [2048]u8
	file := error_and_reading_file(&storage)
	function := double_and_refuse_odd_description()
	rows := [2]Reading_Row{{1, 0, 10}, {3, 0, 30}}
	guard: [1]errors.Error_Record = {{kind = 99}}
	arguments := [2]Argument{{table = {records = bytes_of_memory(&rows, size_of(rows)), count = 2}}, {table = {records = bytes_of_memory(&guard, 0), count = 0}}}
	region: [1024]u8
	offset, size, _, error_place, encoded := encode(file, function, arguments[:], region[:])
	testing.expect(t, encoded, "encode")
	call: Call
	testing.expect(t, decode(file, function, offset, size, region[:], &call), "decode")
	testing.expect_value(t, call.places[1].capacity, 0)
	double_and_refuse_odd(&call.places[0], &call.places[1], (^errors.Error_Record)(&region[error_place.start]))
	counts_store(function, &call, region[:])
	problem, _ := error_details_return(file, function, arguments[:], region[:], offset)
	testing.expect_value(t, problem, Return_Problem.None)
	testing.expect_value(t, arguments[1].table.count, 2)
	testing.expect_value(t, guard[0].kind, 99)
}

@(private = "file")
bytes_of_memory :: proc(memory: rawptr, count: int) -> []u8 {
	return ([^]u8)(memory)[:count]
}
