// The results of the console: the description of a record that the console
// makes itself, and one drawer for each kind of result.
//
// A command of the console gives a result and never prints (docs/CONSOLE.md,
// "Results and their drawers"). The console draws the result by its kind:
// an Integer, a Text, a Record, a Table, a Handle, Bytes or an error. A
// drawer knows no command: it reads the description of the records, as the
// module contract writes it, so one drawer serves each table of each
// service.
//
// The package has no state, calls no allocator and makes no kernel call. A
// drawer writes parts of text to a `Sink` of the caller, each with what it
// is (`Part`): the caller chooses the color. Host tests draw each kind into
// a text.
//
// The parts:
//
// - `Column`, `description_write`, `row_text_set`, `row_integer_set`: a
//   record description in the format of the module contract, and its rows.
// - `Sink`, `Part`: where a drawer writes.
// - `draw_integer`, `draw_text`, `draw_record`, `draw_table`, `draw_handle`,
//   `draw_bytes`, `draw_failure`: the drawers.
package console_results

import module "modus:contract/module"
import "modus:support/sentence"

// A field of a record that the console describes: a column of a table that
// a command makes, or a field that `join` or `columns` takes from a table.
Column :: struct {
	name:     string, // The name of the field.
	type:     module.Type, // Integer, Handle or Text.
	detail:   u32, // An Integer: its size in bytes. A Text: its size in bytes.
	unsigned: bool, // An Integer: true for an unsigned integer.
	side:     int, // For join: the field comes from the left table (0) or from the right table (1).
	from:     u32, // For join and columns: the offset of the field in the record of its table.
	offset:   u32, // The offset of the field in the new record: description_write gives it.
}

// text_column gives a Text column of a size in bytes.
text_column :: proc "contextless" (name: string, size: u32) -> Column {
	return {name = name, type = .Text, detail = size}
}

// integer_column gives an Integer column of 8 bytes with a sign.
integer_column :: proc "contextless" (name: string) -> Column {
	return {name = name, type = .Integer, detail = 8}
}

// description_write writes the description of one record in the format of
// the module contract: a header, a table directory, and the tables Records,
// Fields and Strings. The description has no second format: a reader reads
// it as it reads the description of a module. It gives the offset of each
// column and the size of the record. buffer is zero bytes of the caller;
// file is the part of it that the description takes. ok is false when the
// buffer is too small, when there is no column, or when the record is
// larger than a record can be (size then says how large).
description_write :: proc "contextless" (buffer: []u8, name: string, columns: []Column) -> (file: []u8, size: u32, ok: bool) {
	Directory :: [module.TABLE_COUNT]module.Table_Entry
	if len(columns) == 0 {
		return nil, 0, false
	}
	alignment := u32(1)
	for &column in columns {
		width := module.field_size(column.type, column.detail)
		if width == 0 {
			return nil, 0, false
		}
		column_alignment: u32 = column.type == .Text ? 1 : width
		size = (size + column_alignment - 1) / column_alignment * column_alignment
		column.offset = size
		size += width
		alignment = max(alignment, column_alignment)
	}
	size = (size + alignment - 1) / alignment * alignment
	if size > module.RECORD_SIZE_LIMIT {
		return nil, size, false
	}
	directory: Directory
	place := u32(size_of(module.Header) + size_of(Directory))
	records := place
	place += 2 * size_of(module.Record)
	fields := place
	place += u32(len(columns) + 1) * size_of(module.Field)
	strings := place
	if int(strings) + 1 > len(buffer) {
		return nil, size, false
	}
	text_count := u32(1) // Byte 0 of the string table is zero.
	text :: proc "contextless" (file: []u8, strings: u32, count: ^u32, value: string) -> (offset: u32, ok: bool) {
		if int(strings + count^) + len(value) > len(file) {
			return 0, false
		}
		copy(file[strings + count^:], value)
		offset = count^
		count^ += u32(len(value))
		return offset, true
	}
	record := module.Record {
		size        = size,
		first_field = 1,
		field_count = u32(len(columns)),
		name_count  = u32(len(name)),
	}
	name_offset, name_fits := text(buffer, strings, &text_count, name)
	if !name_fits {
		return nil, size, false
	}
	record.name_offset = name_offset
	(^module.Record)(&buffer[records + size_of(module.Record)])^ = record
	for column, index in columns {
		item := module.Field {
			offset     = column.offset,
			type       = column.type,
			detail     = column.detail,
			unsigned   = column.unsigned,
			name_count = u32(len(column.name)),
		}
		field_name, field_fits := text(buffer, strings, &text_count, column.name)
		if !field_fits {
			return nil, size, false
		}
		item.name_offset = field_name
		(^module.Field)(&buffer[fields + u32(index + 1) * size_of(module.Field)])^ = item
	}
	directory[module.Table_Kind.Records] = {offset = u64(records), count = 2, record_size = size_of(module.Record)}
	directory[module.Table_Kind.Fields] = {offset = u64(fields), count = u32(len(columns) + 1), record_size = size_of(module.Field)}
	directory[module.Table_Kind.Strings] = {offset = u64(strings), count = text_count, record_size = 1}
	(^module.Header)(&buffer[0])^ = {magic = module.MAGIC, version = module.VERSION, header_size = size_of(module.Header), machine = .X86_64, table_count = module.TABLE_COUNT}
	(^Directory)(&buffer[size_of(module.Header)])^ = directory
	return buffer[:strings + text_count], size, true
}

// column_field gives the field of a column, as a reader of the description
// finds it.
column_field :: proc "contextless" (column: Column) -> module.Field {
	return {offset = column.offset, type = column.type, detail = column.detail, unsigned = column.unsigned}
}

// row_text_set writes a text in a Text column of a row. A text longer than
// the column ends with the cut mark and the count of the missing bytes: a
// text is never cut in silence.
row_text_set :: proc "contextless" (row: []u8, column: Column, text: string) {
	if column.type != .Text || u64(column.offset) > u64(len(row)) || u64(column.detail) > u64(len(row)) - u64(column.offset) {
		return
	}
	writer := sentence.Writer {
		buffer = row[column.offset:][:column.detail],
	}
	sentence.write_part(&writer, text)
	sentence.written(&writer)
}

// row_integer_set writes a value in an Integer column of a row.
row_integer_set :: proc "contextless" (row: []u8, column: Column, value: i64) {
	module.field_integer_set(row, column_field(column), value)
}
