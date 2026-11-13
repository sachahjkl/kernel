#+build !freestanding
package console_results

import "contract:errors"
import module "contract:module"
import "core:strings"
import "core:testing"

// What the drawers of a test wrote: the text, with a line feed at each end
// of a line, and the parts of each kind.
Drawn :: struct {
	text:         [8192]u8,
	count:        int,
	parts:        [Part]int, // The bytes of each kind of part.
	continuation: [64]int, // The continuation of each line, when it ended.
	lines:        int,
}

drawn_write :: proc "contextless" (sink: ^Sink, text: string, part: Part) {
	drawn := (^Drawn)(sink.data)
	drawn.count += copy(drawn.text[drawn.count:], text)
	drawn.parts[part] += len(text)
}

drawn_end_line :: proc "contextless" (sink: ^Sink) {
	drawn := (^Drawn)(sink.data)
	drawn.count += copy(drawn.text[drawn.count:], "\n")
	if drawn.lines < len(drawn.continuation) {
		drawn.continuation[drawn.lines] = sink.continuation
	}
	drawn.lines += 1
}

drawn_sink :: proc(drawn: ^Drawn) -> Sink {
	return {data = drawn, write = drawn_write, end_line = drawn_end_line}
}

drawn_text :: proc(drawn: ^Drawn) -> string {
	return string(drawn.text[:drawn.count])
}

// The record of the tests: a number, a name of 12 bytes, a count.
Test_Table :: struct {
	description: [1024]u8,
	file:        []u8,
	columns:     [3]Column,
	size:        int,
	rows:        [16 * 32]u8,
	row_count:   int,
}

test_table_make :: proc(t: ^testing.T, table: ^Test_Table) {
	table.columns = {integer_column("slot"), text_column("name", 12), integer_column("pages")}
	size: u32
	ok: bool
	table.file, size, ok = description_write(table.description[:], "Program", table.columns[:])
	testing.expect(t, ok, "the description is written")
	testing.expect_value(t, size, 32)
	table.size = int(size)
}

test_table_add :: proc(table: ^Test_Table, slot: i64, name: string, pages: i64) {
	row := table.rows[table.row_count * table.size:][:table.size]
	row_integer_set(row, table.columns[0], slot)
	row_text_set(row, table.columns[1], name)
	row_integer_set(row, table.columns[2], pages)
	table.row_count += 1
}

test_table_bytes :: proc(table: ^Test_Table) -> []u8 {
	return table.rows[:table.row_count * table.size]
}

// A description that the console writes is a description of the module
// contract: the readers of the contract read its record and its fields.
@(test)
description_is_read_by_the_contract :: proc(t: ^testing.T) {
	table := new(Test_Table, context.temp_allocator)
	test_table_make(t, table)
	described, ok := module.record_type(table.file, 1)
	testing.expect(t, ok, "the record is found")
	testing.expect_value(t, described.field_count, 3)
	testing.expect_value(t, module.string_at(table.file, described.name_offset, described.name_count), "Program")
	item, found := module.field(table.file, described, 1)
	testing.expect(t, found && item.type == .Text && item.detail == 12 && item.offset == 8)
	testing.expect_value(t, module.string_at(table.file, item.name_offset, item.name_count), "name")
	// No column, a record that is too large, and a buffer that is too small.
	_, _, ok = description_write(table.description[:], "Empty", nil)
	testing.expect(t, !ok)
	wide := [2]Column{text_column("a", 200), text_column("b", 200)}
	size: u32
	_, size, ok = description_write(table.description[:], "Wide", wide[:])
	testing.expect(t, !ok && size == 400)
	one := [1]Column{integer_column("a")}
	_, _, ok = description_write(table.description[:64], "Small", one[:])
	testing.expect(t, !ok)
}

// A text longer than its column ends with the cut mark: it is not cut in
// silence.
@(test)
long_text_has_the_cut_mark :: proc(t: ^testing.T) {
	table := new(Test_Table, context.temp_allocator)
	test_table_make(t, table)
	table.columns[1] = text_column("name", 24)
	table.file, _, _ = description_write(table.description[:], "Program", table.columns[:])
	row: [64]u8
	row_text_set(row[:], table.columns[1], "a name that is longer than twenty-four bytes")
	text := module.field_text(row[:], column_field(table.columns[1]))
	testing.expectf(t, strings.contains(text, "... and ") && strings.has_suffix(text, " bytes more"), "the text is %q", text)
}

@(test)
integer_and_text :: proc(t: ^testing.T) {
	drawn := new(Drawn, context.temp_allocator)
	sink := drawn_sink(drawn)
	draw_integer(&sink, -42)
	testing.expect_value(t, drawn_text(drawn), "-42\n")
	testing.expect_value(t, drawn.parts[Part.Number], 3)
	drawn^ = {}
	draw_text(&sink, "one\ntwo\n")
	testing.expect_value(t, drawn_text(drawn), "one\ntwo\n")
	drawn^ = {}
	draw_text(&sink, "")
	testing.expect_value(t, drawn_text(drawn), "\n")
	drawn^ = {}
	draw_text(&sink, "a\n\nb")
	testing.expect_value(t, drawn_text(drawn), "a\n\nb\n")
}

// Each column has the least width of its head and its values; a number is
// at the right of its column, a text at the left; the last column has no
// spaces after it.
@(test)
table_columns :: proc(t: ^testing.T) {
	table := new(Test_Table, context.temp_allocator)
	test_table_make(t, table)
	test_table_add(table, 3, "console", 120)
	test_table_add(table, 12, "log", 7)
	drawn := new(Drawn, context.temp_allocator)
	sink := drawn_sink(drawn)
	draw_table(&sink, table.file, 1, test_table_bytes(table), 20)
	expected := "slot  name     pages\n" + "   3  console    120\n" + "  12  log          7\n" + "2 rows of Program\n"
	testing.expect_value(t, drawn_text(drawn), expected)
	// A row that is too long goes on under the last column.
	testing.expect_value(t, drawn.continuation[1], 15)
	testing.expect(t, drawn.parts[Part.Label] == len("slot") + len("name") + len("pages"))
}

// A table with more rows than the limit: the first rows, then how many are
// not shown. The widths are those of the rows that are shown.
@(test)
table_cut_at_the_row_limit :: proc(t: ^testing.T) {
	table := new(Test_Table, context.temp_allocator)
	test_table_make(t, table)
	for index in 0 ..< 5 {
		test_table_add(table, i64(index + 1), index == 4 ? "a_long_name" : "x", 1)
	}
	drawn := new(Drawn, context.temp_allocator)
	sink := drawn_sink(drawn)
	draw_table(&sink, table.file, 1, test_table_bytes(table), 2, ": skip(table, 2) gives them")
	expected := "slot  name  pages\n" + "   1  x         1\n" + "   2  x         1\n" + "3 rows more are not shown: skip(table, 2) gives them\n" + "5 rows of Program\n"
	testing.expect_value(t, drawn_text(drawn), expected)
	// One row, and no row.
	drawn^ = {}
	draw_table(&sink, table.file, 1, test_table_bytes(table)[:table.size], 20)
	testing.expect(t, strings.has_suffix(drawn_text(drawn), "1 row of Program\n"))
	drawn^ = {}
	draw_table(&sink, table.file, 1, nil, 20)
	testing.expect_value(t, drawn_text(drawn), "slot  name  pages\n0 rows of Program\n")
	// A description that is not one.
	drawn^ = {}
	draw_table(&sink, table.file, 9, test_table_bytes(table), 20)
	testing.expect_value(t, drawn_text(drawn), "a table with no valid description\n")
}

@(test)
record_fields :: proc(t: ^testing.T) {
	table := new(Test_Table, context.temp_allocator)
	test_table_make(t, table)
	test_table_add(table, 3, "console", 120)
	drawn := new(Drawn, context.temp_allocator)
	sink := drawn_sink(drawn)
	draw_record(&sink, table.file, 1, test_table_bytes(table))
	expected := "Program\n" + "  slot   3\n" + "  name   console\n" + "  pages  120\n"
	testing.expect_value(t, drawn_text(drawn), expected)
	testing.expect_value(t, drawn.parts[Part.Type], len("Program"))
	testing.expect_value(t, drawn.continuation[1], 9)
	// Bytes that are fewer than the record.
	drawn^ = {}
	draw_record(&sink, table.file, 1, test_table_bytes(table)[:8])
	testing.expect_value(t, drawn_text(drawn), "a record with no valid description\n")
}

@(test)
handle_kind_and_rights :: proc(t: ^testing.T) {
	drawn := new(Drawn, context.temp_allocator)
	sink := drawn_sink(drawn)
	draw_handle(&sink, 65541, .Memory, {.Give, .Read, .Write})
	testing.expect_value(t, drawn_text(drawn), "Handle 65541: Memory (Give, Read, Write)\n")
	drawn^ = {}
	draw_handle(&sink, 7, .None, {})
	testing.expect_value(t, drawn_text(drawn), "Handle 7: no object\n")
}

@(test)
bytes_view :: proc(t: ^testing.T) {
	bytes: [20]u8
	for &value, index in bytes {
		value = u8('A' + index)
	}
	bytes[1] = 0
	drawn := new(Drawn, context.temp_allocator)
	sink := drawn_sink(drawn)
	draw_bytes(&sink, bytes[:], 256)
	expected := "00000000  41 00 43 44 45 46 47 48 49 4a 4b 4c 4d 4e 4f 50  A.CDEFGHIJKLMNOP\n" + "00000010  51 52 53 54                                      QRST\n" + "20 bytes\n"
	testing.expect_value(t, drawn_text(drawn), expected)
	// The bound: whole bytes only, then how many are not shown.
	drawn^ = {}
	draw_bytes(&sink, bytes[:], 2, 0x1000)
	testing.expect_value(t, drawn_text(drawn), "00001000  41 00                                            A.\n18 bytes more are not shown\n20 bytes\n")
	drawn^ = {}
	draw_bytes(&sink, nil, 256)
	testing.expect_value(t, drawn_text(drawn), "0 bytes\n")
}

// An error of the console itself is its sentence. An error record adds its
// values; its details follow when there is more than one.
@(test)
failure_lines :: proc(t: ^testing.T) {
	drawn := new(Drawn, context.temp_allocator)
	sink := drawn_sink(drawn)
	draw_failure(&sink, {sentence = "no variable has the name x"})
	testing.expect_value(t, drawn_text(drawn), "error: no variable has the name x\n")

	drawn^ = {}
	record := errors.error_make(.Too_Long, .Bytes, 2, 40, 36)
	names := [2]string{"amount", "note"}
	draw_failure(&sink, {sentence = "add: the argument note has 40 bytes; it can have at most 36 bytes (-1)", record = &record, operation = "add", argument_names = names[:]})
	expected := "error: add: the argument note has 40 bytes; it can have at most 36 bytes (-1)\n" + "  kind       Too_Long\n" + "  operation  add\n" + "  argument   2 note\n" + "  values     value 40, limit 36, found 0, unit bytes\n"
	testing.expect_value(t, drawn_text(drawn), expected)
	testing.expect_value(t, drawn.parts[Part.Status], len("Too_Long"))

	// A kind that the contract does not have, from another program.
	drawn^ = {}
	record = {kind = 9999}
	draw_failure(&sink, {sentence = "x", record = &record})
	testing.expect(t, strings.contains(drawn_text(drawn), "  kind       an unknown kind, 9999\n"), drawn_text(drawn))

	// Three details, two in the table of the caller.
	drawn^ = {}
	record = errors.error_make(.Absent, .None, 1, 0, 0, 1)
	details := [2]errors.Error_Record{record, errors.error_make(.Absent, .None, 1, 0, 0, 3)}
	one_name := [1]string{"names"}
	draw_failure(&sink, {sentence = "s", record = &record, operation = "monitor.counts_named", argument_names = one_name[:], details = details[:], detail_count = 3})
	text := drawn_text(drawn)
	testing.expect(t, strings.contains(text, "error: detail 1 of 3: monitor.counts_named: "), text)
	testing.expect(t, strings.contains(text, "error: detail 2 of 3: monitor.counts_named: "), text)
	testing.expect(t, strings.contains(text, "error: 1 more error detail did not fit in the table of error details\n"), text)
}
