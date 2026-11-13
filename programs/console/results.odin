package console

import "contract:errors"
import module "contract:module"
import "contract:ring"
import "contract:value_kinds"
import "support:console_results"
import "support:graphics"
import "support:system"
import terminal "support:terminal"

// The result of a line, and how the console draws it.
//
// A command gives a result and never writes to the terminal. The line has
// one result: the value of its expression, or its failure. The console
// draws it by its kind with one drawer for each kind
// (support/console_results): no command has drawing code of its own
// (docs/CONSOLE.md, "Results and their drawers").

RESULT_ROW_LIMIT :: 20 // The most rows of a table that the console draws: the window of the console has 26 rows.
RESULT_ROW_HINT :: ": first(table, count) and skip(table, count) choose the rows"
RESULT_BYTE_LIMIT :: 256 // The most bytes of a Bytes value that the console draws: 16 rows.

Column :: console_results.Column
text_column :: console_results.text_column
integer_column :: console_results.integer_column

// ---- The failure of a line.

FAILURE_SENTENCE_SIZE :: 768
FAILURE_NOTES_SIZE :: 4096
FAILURE_OPERATION_SIZE :: 96

// The failure of the line that runs: its sentence, the error record when a
// call gave one, with the names that the record refers to by number, the
// error details of the call, and the lines that say more (the stop report
// of a program, the errors of a load).
Line_Failure :: struct {
	sentence:        [FAILURE_SENTENCE_SIZE]u8,
	sentence_count:  int,
	has_record:      bool,
	record:          errors.Error_Record,
	operation:       [FAILURE_OPERATION_SIZE]u8,
	operation_count: int,
	argument_names:  [ARGUMENT_CAPACITY]string,
	argument_count:  int,
	details:         [ERROR_DETAILS_CAPACITY]errors.Error_Record,
	details_kept:    int, // The details in `details`.
	detail_count:    u64, // The details of the full answer.
	notes:           [FAILURE_NOTES_SIZE]u8, // Lines, each with a line feed after it.
	notes_writer:    system.Writer,
}

failure: Line_Failure

failure_reset :: proc "contextless" () {
	failure.sentence_count, failure.has_record, failure.operation_count, failure.argument_count = 0, false, 0, 0
	failure.details_kept, failure.detail_count = 0, 0
	failure.notes_writer = {buffer = failure.notes[:]}
}

// fail makes the line fail with a sentence. The first failure ends the
// line: a later one changes nothing. It gives no value.
fail :: proc "contextless" (parts: ..system.Part) -> Value {
	if !failed {
		failed = true
		failure.sentence_count = len(system.format(failure.sentence[:], ..parts))
	}
	return {}
}

// fail_note adds one line to the failure of the line: a fact that the
// sentence does not hold.
fail_note :: proc "contextless" (parts: ..system.Part) {
	for part in parts {
		system.write_part(&failure.notes_writer, part)
	}
	system.write_part(&failure.notes_writer, "\n")
}

// failure_record_set gives the failure of the line its error record: what
// the call that failed wrote, and the names of the operation and of its
// arguments. The caller made the failure with fail just before.
failure_record_set :: proc "contextless" (record: errors.Error_Record, operation: string, argument_names: []string) {
	failure.record, failure.has_record = record, true
	failure.operation_count = copy(failure.operation[:], operation)
	failure.argument_count = copy(failure.argument_names[:], argument_names)
}

// failure_details_set keeps the error details of the call that failed.
// count is the count of the full answer; details holds the places of the
// table of the console.
failure_details_set :: proc "contextless" (details: []errors.Error_Record, count: u64) {
	failure.details_kept = copy(failure.details[:], details[:min(u64(len(details)), count)])
	failure.detail_count = count
}

// fail_root makes the line fail with the refusal of the root service: the
// sentence of its error record, after prefix, and the record.
fail_root :: proc "contextless" (prefix: string, completion: ring.Record) -> Value {
	already := failed
	text: [240]u8
	result := fail(prefix, root_refusal_text(text[:], completion))
	if !already {
		error := errors.completion_record(completion.values)
		operation: [64]u8
		argument_names: [ARGUMENT_CAPACITY]string
		for &argument_name, index in argument_names {
			argument_name = system.root_argument_name(error.operation, i64(index + 1))
		}
		failure_record_set(error, system.format(operation[:], "root.", system.root_command_name(error.operation)), argument_names[:])
	}
	return result
}

// fail_no_answer makes the line fail when the root service gave no answer.
fail_no_answer :: proc "contextless" () -> Value {
	return fail(requests.head == nil ? "the console has no ring to the root service" : "the root service did not answer")
}

// fail_overflow makes the line fail when the result of an operator does
// not fit in an Integer. The record: the left value, the right value in
// `found`, and the largest Integer as the limit.
fail_overflow :: proc "contextless" (operator: string, left, right: i64) -> Value {
	already := failed
	result := fail("\"", operator, "\" of ", left, " and ", right, " does not fit in an Integer: an Integer has 64 bits with a sign")
	if !already {
		failure_record_set(errors.error_make(.Over_Limit, .None, 0, left, max(i64), right), operator, nil)
	}
	return result
}

// failure_draw draws the failure of the line: the drawer of an error, then
// the lines that say more, each after "error: ".
failure_draw :: proc "contextless" () {
	system.lock(&output_lock)
	defer system.unlock(&output_lock)
	sink := result_sink()
	drawn := console_results.Failure {
		sentence       = string(failure.sentence[:failure.sentence_count]),
		operation      = string(failure.operation[:failure.operation_count]),
		argument_names = failure.argument_names[:failure.argument_count],
		details        = failure.details[:failure.details_kept],
		detail_count   = failure.detail_count,
	}
	if failure.has_record {
		drawn.record = &failure.record
	}
	console_results.draw_failure(&sink, drawn)
	notes := system.written(&failure.notes_writer)
	output_continuation = len(console_results.FAILURE_START)
	for len(notes) > 0 {
		end := 0
		for end < len(notes) && notes[end] != '\n' {
			end += 1
		}
		emit(console_results.FAILURE_START, {tone = .Bad})
		emit(notes[:end], {tone = .Bad})
		emit_end()
		notes = notes[min(end + 1, len(notes)):]
	}
	output_continuation = 0
}

// ---- The drawing of a value.

// result_sink gives the sink of the drawers: each part goes to the
// terminal in the color of what it is, and each line to the log. The caller
// holds output_lock.
result_sink :: proc "contextless" () -> console_results.Sink {
	return {write = result_write, end_line = result_end_line}
}

result_write :: proc "contextless" (sink: ^console_results.Sink, text: string, part: console_results.Part) {
	output_continuation = sink.continuation
	emit(text, part_style(part))
}

result_end_line :: proc "contextless" (sink: ^console_results.Sink) {
	emit_end()
}

// part_style gives the style of a part of a drawn result: a value has the
// color of its value kind, the one table of the log window and of the site.
part_style :: proc "contextless" (part: console_results.Part) -> terminal.Style {
	switch part {
	case .Plain:
		return {}
	case .Label, .Note:
		return {tone = .Dim}
	case .Failure:
		return {tone = .Bad}
	case .Number, .Handle, .Type, .Status, .Operation:
	}
	return value_kind_style(console_results.part_value_kind(part))
}

// value_kind_style gives the style of a value of a kind. None is plain.
value_kind_style :: proc "contextless" (kind: value_kinds.Value_Kind) -> terminal.Style {
	if kind == .None {
		return {}
	}
	return {flags = {.Color}, color = u32(graphics.value_kind_color(kind, false))}
}

// value_draw draws the value of a line with the drawer of its kind. A line
// with no value draws nothing.
value_draw :: proc "contextless" (value: Value) {
	system.lock(&output_lock)
	defer system.unlock(&output_lock)
	sink := result_sink()
	switch value.kind {
	case .Integer:
		console_results.draw_integer(&sink, value.integer)
	case .Text:
		console_results.draw_text(&sink, value.text)
	case .Record:
		console_results.draw_record(&sink, value.file, value.detail, value.record)
	case .Table:
		console_results.draw_table(&sink, value.file, value.detail, value.record, RESULT_ROW_LIMIT, RESULT_ROW_HINT)
	case .Handle:
		kind, rights, _ := system.handle_state(system.Handle(value.integer))
		console_results.draw_handle(&sink, u64(value.integer), kind, rights)
	case .Bytes:
		console_results.draw_bytes(&sink, value.record, RESULT_BYTE_LIMIT, u64(value.integer))
	case .None:
	}
	output_continuation = 0
}

// ---- A table that a command of the console makes.

// A table that a command makes: the description of its record, which the
// console writes in the format of the module contract, and its rows, one
// after the other in the memory of the tables of the line.
Made_Table :: struct {
	file:         []u8, // The description.
	size:         int, // The bytes of one row.
	columns:      [console_results.COLUMN_LIMIT]Column,
	column_count: int,
	start:        int, // The first byte of the rows in the memory of the tables.
	rows:         int,
	full:         bool, // A row did not fit.
}

// made_table starts a table of a record with a name and columns. ok is
// false when the line has no room for the description.
made_table :: proc "contextless" (name: string, columns: []Column) -> (table: Made_Table, ok: bool) {
	table.column_count = copy(table.columns[:], columns)
	size: u32
	table.file, size, ok = description_make(name, table.columns[:table.column_count])
	table.size = int(size)
	table.start = (table_used + 7) &~ 7
	return table, ok
}

// made_row adds one row of zero bytes. nil: the line has no room; the
// setters then write nothing, and made_value reports it.
made_row :: proc "contextless" (table: ^Made_Table) -> []u8 {
	place := table.start + table.rows * table.size
	if table.full || table.size == 0 || table.size > len(table_memory) - place {
		table.full = true
		return nil
	}
	table.rows += 1
	table_used = place + table.size
	row := table_memory[place:table_used]
	for &b in row {
		b = 0
	}
	return row
}

made_text :: proc "contextless" (table: ^Made_Table, row: []u8, column: int, text: string) {
	if row != nil {
		console_results.row_text_set(row, table.columns[column], text)
	}
}

made_integer :: proc "contextless" (table: ^Made_Table, row: []u8, column: int, value: i64) {
	if row != nil {
		console_results.row_integer_set(row, table.columns[column], value)
	}
}

// made_value gives the Table value of a made table. command names who made
// it, for the error when a row did not fit.
made_value :: proc "contextless" (table: ^Made_Table, command: string) -> Value {
	if table.full {
		return fail(command, ": the line has no room for more than ", i64(table.rows), " rows")
	}
	return {kind = .Table, record = table_memory[table.start:][:table.rows * table.size], file = table.file, detail = 1}
}

// made_record gives the one row of a made table as a Record value.
made_record :: proc "contextless" (table: ^Made_Table, command: string) -> Value {
	if table.full || table.rows != 1 {
		return fail(command, ": the line has no room for its record")
	}
	return {kind = .Record, record = table_memory[table.start:][:table.size], file = table.file, detail = 1}
}

// hash_head_text writes the head of a hash, its first 8 bytes, as 16
// hexadecimal digits.
hash_head_text :: proc "contextless" (buffer: ^[16]u8, hash: [32]u8) -> string {
	digits := system.HEX_DIGITS
	for index in 0 ..< 8 {
		buffer[2 * index] = digits[hash[index] >> 4]
		buffer[2 * index + 1] = digits[hash[index] & 0xF]
	}
	return string(buffer[:])
}

// module_name_of gives the name of a module in the boot image, by its
// hash, or "".
module_name_of :: proc "contextless" (hash: [32]u8) -> string {
	if entry := system.image_entry_of(image, hash); entry != nil {
		return system.name_of(entry.name[:])
	}
	return ""
}

// record_fields_text writes the fields of a Record value in one line:
// "x = 1, y = 2".
record_fields_text :: proc "contextless" (writer: ^system.Writer, value: Value) {
	described, ok := module.record_type(value.file, value.detail)
	if !ok {
		return
	}
	for number in 0 ..< described.field_count {
		item, found := module.field(value.file, described, number)
		if !found {
			continue
		}
		buffer: [24]u8
		system.write_part(writer, number > 0 ? ", " : "")
		system.write_part(writer, module.string_at(value.file, item.name_offset, item.name_count))
		system.write_part(writer, " = ")
		system.write_part(writer, console_results.cell_of(value.record, item, buffer[:]).text)
	}
}
