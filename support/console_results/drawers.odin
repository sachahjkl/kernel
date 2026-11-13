package console_results

import "contract:errors"
import module "contract:module"
import op "contract:operation"
import "contract:value_kinds"
import "support:sentence"

// What a part of a drawn result is. The caller of a drawer chooses the
// color of each part: a value has the color of its value kind
// (`part_value_kind`), as in the log and on the site of the system.
Part :: enum u8 {
	Plain     = 0, // A text value, and the spaces between two parts.
	Label     = 1, // The name of a field, the head of a column, the place of a row of bytes.
	Note      = 2, // What the drawer says about the result: the count of rows, the rows that are not shown.
	Failure   = 3, // The sentence of an error.
	Number    = 4, // An Integer.
	Handle    = 5, // A handle.
	Type      = 6, // The name of a record, or the kind of an object.
	Status    = 7, // An error kind.
	Operation = 8, // The operation or the export of an error.
}

// part_value_kind gives the value kind of a part. None: the part is not a
// value, and the caller draws it plain, dim or as a failure.
part_value_kind :: proc "contextless" (part: Part) -> value_kinds.Value_Kind {
	switch part {
	case .Number:
		return .Number
	case .Handle:
		return .Handle
	case .Type:
		return .Type
	case .Status:
		return .Status
	case .Operation:
		return .Operation
	case .Plain, .Label, .Note, .Failure:
	}
	return .None
}

// Where a drawer writes. The caller gives the two procedures. A drawer
// calls `write` for each part of a line, then `end_line`. Before the parts
// of a line it sets `continuation`: the column where the rest of the line
// starts when the window of the caller is narrower than the line, so that a
// long value goes on under its own start and is never cut.
Sink :: struct {
	data:         rawptr, // The state of the caller.
	write:        proc "contextless" (sink: ^Sink, text: string, part: Part), // One part of the line.
	end_line:     proc "contextless" (sink: ^Sink), // The line ends.
	continuation: int, // The column where a line that is too long goes on.
}

COLUMN_LIMIT :: 40 // The most columns of a drawn table: the fields of a record that join makes.
CONTINUATION_MOST :: 48 // A line goes on under its last column only when that column starts at or before this one.
COLUMN_GAP :: 2 // The spaces between two columns.
BYTES_IN_A_ROW :: 16 // The bytes of one row of a view of bytes.

BLANKS :: "                                                                "

// blanks writes a count of spaces.
blanks :: proc "contextless" (sink: ^Sink, count: int) {
	blank := BLANKS
	rest := count
	for rest > 0 {
		taken := min(rest, len(blank))
		sink.write(sink, blank[:taken], .Plain)
		rest -= taken
	}
}

// One value of a field, as text.
Cell :: struct {
	text:   string, // The text of the value.
	number: bool, // The value is a number: it is aligned at the right.
	part:   Part, // What the value is.
}

// cell_of gives the text of one field of a record. The text of a number is
// in buffer; the text of a Text field is in the record.
cell_of :: proc "contextless" (row: []u8, item: module.Field, buffer: []u8) -> Cell {
	#partial switch item.type {
	case .Integer:
		value := module.field_integer(row, item)
		if item.unsigned && module.field_size(item.type, item.detail) == 8 {
			return {text = sentence.format(buffer, u64(value)), number = true, part = .Number}
		}
		return {text = sentence.format(buffer, value), number = true, part = .Number}
	case .Handle:
		handle: u64
		if u64(item.offset) <= u64(len(row)) && u64(len(row)) - u64(item.offset) >= 4 {
			for index in 0 ..< u32(4) {
				handle |= u64(row[item.offset + index]) << (8 * index)
			}
		}
		return {text = sentence.format(buffer, handle), number = true, part = .Handle}
	case .Text:
		return {text = module.field_text(row, item), part = .Plain}
	}
	return {}
}

// cell_write writes one cell in a column of a width: a number at the right
// of its column, a text at the left. The last column has no spaces after
// its text.
cell_write :: proc "contextless" (sink: ^Sink, text: string, width: int, number: bool, last: bool, part: Part) {
	if number {
		blanks(sink, width - len(text))
	}
	sink.write(sink, text, part)
	if last {
		return
	}
	if !number {
		blanks(sink, width - len(text))
	}
	blanks(sink, COLUMN_GAP)
}

// draw_integer draws an Integer: its decimal text, in one line.
draw_integer :: proc "contextless" (sink: ^Sink, value: i64) {
	buffer: [24]u8
	sink.continuation = 0
	sink.write(sink, sentence.format(buffer[:], value), .Number)
	sink.end_line(sink)
}

// draw_text draws a Text: its bytes, one line for each line of the text.
// An empty text is one empty line.
draw_text :: proc "contextless" (sink: ^Sink, text: string) {
	sink.continuation = 0
	rest := text
	for {
		end := 0
		for end < len(rest) && rest[end] != '\n' {
			end += 1
		}
		sink.write(sink, rest[:end], .Plain)
		sink.end_line(sink)
		if end >= len(rest) {
			break
		}
		rest = rest[end + 1:]
		// A text that ends with the end of a line has no empty line after it.
		if len(rest) == 0 {
			break
		}
	}
}

// draw_record draws a Record: the name of its record, then one line for
// each field, with the name of the field and its value. file and detail
// name the description of the record; bytes are its bytes.
draw_record :: proc "contextless" (sink: ^Sink, file: []u8, detail: u32, bytes: []u8) {
	sink.continuation = 0
	described, ok := module.record_type(file, detail)
	if !ok || int(described.size) > len(bytes) {
		sink.write(sink, "a record with no valid description", .Note)
		sink.end_line(sink)
		return
	}
	sink.write(sink, module.string_at(file, described.name_offset, described.name_count), .Type)
	sink.end_line(sink)
	width := 0
	for number in 0 ..< described.field_count {
		if item, found := module.field(file, described, number); found {
			width = max(width, int(item.name_count))
		}
	}
	sink.continuation = min(COLUMN_GAP + width + COLUMN_GAP, CONTINUATION_MOST)
	for number in 0 ..< described.field_count {
		item, found := module.field(file, described, number)
		if !found {
			continue
		}
		name := module.string_at(file, item.name_offset, item.name_count)
		buffer: [24]u8
		cell := cell_of(bytes, item, buffer[:])
		blanks(sink, COLUMN_GAP)
		sink.write(sink, name, .Label)
		blanks(sink, width - len(name) + COLUMN_GAP)
		sink.write(sink, cell.text, cell.part)
		sink.end_line(sink)
	}
	sink.continuation = 0
}

// draw_table draws a Table: a line with the names of the fields, a line for
// each row, and the count of rows with the name of the record. Each column
// has the least width that holds its head and its values; a number is at
// the right of its column. No value is cut: a line wider than the window
// goes on under its last column.
//
// row_limit: the most rows that are drawn. When the table has more, one
// line says how many are not shown, with rest_hint after it: how the
// reader gets them.
draw_table :: proc "contextless" (sink: ^Sink, file: []u8, detail: u32, bytes: []u8, row_limit: int, rest_hint: string = "") {
	sink.continuation = 0
	described, ok := module.record_type(file, detail)
	if !ok || described.size == 0 {
		sink.write(sink, "a table with no valid description", .Note)
		sink.end_line(sink)
		return
	}
	size := int(described.size)
	rows := len(bytes) / size
	shown := clamp(row_limit, 0, rows)
	field_count := min(int(described.field_count), COLUMN_LIMIT)
	items: [COLUMN_LIMIT]module.Field
	widths: [COLUMN_LIMIT]int
	for number in 0 ..< field_count {
		items[number], _ = module.field(file, described, u32(number))
		widths[number] = int(items[number].name_count)
	}
	for index in 0 ..< shown {
		row := bytes[index * size:][:size]
		for number in 0 ..< field_count {
			buffer: [24]u8
			widths[number] = max(widths[number], len(cell_of(row, items[number], buffer[:]).text))
		}
	}
	last_start := 0
	for number in 0 ..< field_count - 1 {
		last_start += widths[number] + COLUMN_GAP
	}
	sink.continuation = last_start <= CONTINUATION_MOST ? last_start : COLUMN_GAP
	for number in 0 ..< field_count {
		name := module.string_at(file, items[number].name_offset, items[number].name_count)
		cell_write(sink, name, widths[number], items[number].type != .Text, number == field_count - 1, .Label)
	}
	sink.end_line(sink)
	for index in 0 ..< shown {
		row := bytes[index * size:][:size]
		for number in 0 ..< field_count {
			buffer: [24]u8
			cell := cell_of(row, items[number], buffer[:])
			cell_write(sink, cell.text, widths[number], cell.number, number == field_count - 1, cell.part)
		}
		sink.end_line(sink)
	}
	sink.continuation = 0
	count_text: [24]u8
	if rows > shown {
		sink.write(sink, sentence.format(count_text[:], u64(rows - shown)), .Number)
		sink.write(sink, rows - shown == 1 ? " row more is not shown" : " rows more are not shown", .Note)
		sink.write(sink, rest_hint, .Note)
		sink.end_line(sink)
	}
	sink.write(sink, sentence.format(count_text[:], u64(rows)), .Number)
	sink.write(sink, rows == 1 ? " row of " : " rows of ", .Note)
	sink.write(sink, module.string_at(file, described.name_offset, described.name_count), .Type)
	sink.end_line(sink)
}

// draw_handle draws a Handle: its number, the kind of its object and its
// rights, as the kernel gives them to the caller: "Handle 65541: Memory
// (Give, Read, Write)". A handle that names no object has no rights.
draw_handle :: proc "contextless" (sink: ^Sink, handle: u64, kind: op.Object_Kind, rights: op.Rights) {
	sink.continuation = 0
	buffer: [24]u8
	sink.write(sink, "Handle ", .Plain)
	sink.write(sink, sentence.format(buffer[:], handle), .Handle)
	sink.write(sink, ": ", .Plain)
	sink.write(sink, sentence.object_names[kind], .Type)
	if kind != .None {
		rights_text: [160]u8
		writer := sentence.Writer {
			buffer = rights_text[:],
		}
		sentence.write_rights(&writer, rights, ", ")
		sink.write(sink, " (", .Plain)
		sink.write(sink, sentence.written(&writer), .Plain)
		sink.write(sink, ")", .Plain)
	}
	sink.end_line(sink)
}

// draw_bytes draws Bytes: rows of 16 bytes, each with the place of its
// first byte, the bytes in hexadecimal, and their characters. byte_limit:
// the most bytes that are drawn; one line says how many are not shown. The
// last line is the count of bytes. first_place: the place of the first
// byte in what the bytes come from.
draw_bytes :: proc "contextless" (sink: ^Sink, bytes: []u8, byte_limit: int, first_place: u64 = 0) {
	sink.continuation = 0
	shown := clamp(byte_limit, 0, len(bytes))
	for start := 0; start < shown; start += BYTES_IN_A_ROW {
		row := bytes[start:min(start + BYTES_IN_A_ROW, shown)]
		place_text: [16]u8
		place := sentence.Writer {
			buffer = place_text[:],
		}
		sentence.write_hex(&place, first_place + u64(start), 8)
		sink.write(sink, sentence.written(&place), .Label)
		blanks(sink, COLUMN_GAP)
		digits := sentence.HEX_DIGITS
		for value in row {
			pair := [2]u8{digits[value >> 4], digits[value & 0xF]}
			sink.write(sink, string(pair[:]), .Number)
			blanks(sink, 1)
		}
		blanks(sink, 3 * (BYTES_IN_A_ROW - len(row)) + 1)
		characters: [BYTES_IN_A_ROW]u8
		for value, index in row {
			characters[index] = value >= 32 && value <= 126 ? value : '.'
		}
		sink.write(sink, string(characters[:len(row)]), .Plain)
		sink.end_line(sink)
	}
	count_text: [24]u8
	if len(bytes) > shown {
		sink.write(sink, sentence.format(count_text[:], u64(len(bytes) - shown)), .Number)
		sink.write(sink, len(bytes) - shown == 1 ? " byte more is not shown" : " bytes more are not shown", .Note)
		sink.end_line(sink)
	}
	sink.write(sink, sentence.format(count_text[:], u64(len(bytes))), .Number)
	sink.write(sink, len(bytes) == 1 ? " byte" : " bytes", .Note)
	sink.end_line(sink)
}

// The name of each error kind, as the contract names it.
@(rodata)
ERROR_KIND_NAMES := [errors.Kind]string {
	.None              = "None",
	.Empty             = "Empty",
	.Too_Long          = "Too_Long",
	.Too_Small         = "Too_Small",
	.Bad_Value         = "Bad_Value",
	.Bad_Flags         = "Bad_Flags",
	.Bad_Byte          = "Bad_Byte",
	.Bad_Address       = "Bad_Address",
	.Handle_Absent     = "Handle_Absent",
	.Handle_Ended      = "Handle_Ended",
	.Handle_Kind       = "Handle_Kind",
	.Handle_Rights     = "Handle_Rights",
	.Budget            = "Budget",
	.Budget_Hidden     = "Budget_Hidden",
	.Over_Limit        = "Over_Limit",
	.Full              = "Full",
	.State             = "State",
	.Absent            = "Absent",
	.Damaged           = "Damaged",
	.Device            = "Device",
	.No_Grant          = "No_Grant",
	.Malformed         = "Malformed",
	.No_Target         = "No_Target",
	.Overlap           = "Overlap",
	.Unknown_Operation = "Unknown_Operation",
	.Refused           = "Refused",
	.No_Answer         = "No_Answer",
	.Unsupported       = "Unsupported",
	.Link_Down         = "Link_Down",
	.Busy              = "Busy",
	.Out_Of_Range      = "Out_Of_Range",
	.Reserved          = "Reserved",
	.Not_Payer         = "Not_Payer",
	.Object_Shared     = "Object_Shared",
	.Object_Marked     = "Object_Marked",
	.Whole_Only        = "Whole_Only",
	.Not_Multiple      = "Not_Multiple",
	.Not_Authentic     = "Not_Authentic",
	.Seed_Too_Weak     = "Seed_Too_Weak",
	.Exists            = "Exists",
}

// What a line that failed gives: the sentence of the failure, and the error
// record when a call gave one.
Failure :: struct {
	sentence:       string, // One sentence: what failed, and why.
	record:         ^errors.Error_Record, // nil: the console itself refused the line, and no call gave a record.
	operation:      string, // The name of the operation or of the export of the record.
	argument_names: []string, // The names of its parameters, from 1: the record names an argument by its number.
	details:        []errors.Error_Record, // The error details that the call wrote in the table of the caller.
	detail_count:   u64, // The count of error details of the full answer.
}

FAILURE_START :: "error: " // The start of each line of a failure.
FAILURE_LABEL_WIDTH :: 9 // The longest label of a line of an error record: "operation".

// failure_label writes the label of one line of an error record.
failure_label :: proc "contextless" (sink: ^Sink, label: string) {
	blanks(sink, COLUMN_GAP)
	sink.write(sink, label, .Label)
	blanks(sink, FAILURE_LABEL_WIDTH - len(label) + COLUMN_GAP)
}

// failure_argument_name gives the name of the argument that a record names
// by its number, or "".
failure_argument_name :: proc "contextless" (failure: Failure, record: ^errors.Error_Record) -> string {
	if record.argument >= 1 && record.argument <= i64(len(failure.argument_names)) {
		return failure.argument_names[record.argument - 1]
	}
	return ""
}

// draw_failure draws the error of a line. The first line is "error: " and
// the sentence. With an error record, the lines after it give the record as
// values: its kind, the operation, the argument, and the three values with
// their unit. With more than one error detail, one line for each detail
// follows, then the count of the details that the table did not hold.
draw_failure :: proc "contextless" (sink: ^Sink, failure: Failure) {
	sink.continuation = len(FAILURE_START)
	sink.write(sink, FAILURE_START, .Failure)
	sink.write(sink, failure.sentence, .Failure)
	sink.end_line(sink)
	record := failure.record
	if record == nil || record.kind == 0 {
		sink.continuation = 0
		return
	}
	number: [24]u8
	sink.continuation = COLUMN_GAP + FAILURE_LABEL_WIDTH + COLUMN_GAP
	failure_label(sink, "kind")
	if errors.kind_known(record.kind) {
		sink.write(sink, ERROR_KIND_NAMES[errors.Kind(record.kind)], .Status)
	} else {
		sink.write(sink, "an unknown kind, ", .Note)
		sink.write(sink, sentence.format(number[:], record.kind), .Number)
	}
	sink.end_line(sink)
	if failure.operation != "" {
		failure_label(sink, "operation")
		sink.write(sink, failure.operation, .Operation)
		sink.end_line(sink)
	}
	if record.argument != 0 {
		failure_label(sink, "argument")
		sink.write(sink, sentence.format(number[:], record.argument), .Number)
		if name := failure_argument_name(failure, record); name != "" {
			blanks(sink, 1)
			sink.write(sink, name, .Plain)
		}
		sink.end_line(sink)
	}
	failure_label(sink, "values")
	sink.write(sink, "value ", .Label)
	sink.write(sink, sentence.format(number[:], record.value), .Number)
	sink.write(sink, ", limit ", .Label)
	sink.write(sink, sentence.format(number[:], record.limit), .Number)
	sink.write(sink, ", found ", .Label)
	sink.write(sink, sentence.format(number[:], record.found), .Number)
	if record.unit != 0 {
		sink.write(sink, ", unit ", .Label)
		if errors.unit_known(record.unit) {
			sink.write(sink, errors.UNIT_NAMES[errors.Unit(record.unit)], .Plain)
		} else {
			sink.write(sink, sentence.format(number[:], record.unit), .Number)
		}
	}
	sink.end_line(sink)
	// The error record is the first detail: with one detail, the lines
	// above say all of it.
	sink.continuation = len(FAILURE_START)
	if failure.detail_count >= 2 {
		shown := min(u64(len(failure.details)), failure.detail_count)
		for &detail, index in failure.details[:shown] {
			buffer: [240]u8
			writer := sentence.Writer {
				buffer = buffer[:],
			}
			sentence.error_detail_number_text(&writer, u64(index + 1), failure.detail_count)
			sentence.error_text(&writer, &detail, failure.operation, failure_argument_name(failure, &detail))
			sink.write(sink, FAILURE_START, .Failure)
			sink.write(sink, sentence.written(&writer), .Failure)
			sink.end_line(sink)
		}
		if failure.detail_count > shown {
			buffer: [128]u8
			writer := sentence.Writer {
				buffer = buffer[:],
			}
			sentence.error_details_rest_text(&writer, shown, failure.detail_count)
			sink.write(sink, FAILURE_START, .Failure)
			sink.write(sink, sentence.written(&writer), .Failure)
			sink.end_line(sink)
		}
	}
	sink.continuation = 0
}
