package console

import module "contract:module"
import "support:system"

// Tables: a value that holds records of one record description, one after
// the other (module.Type.Table). A Table result of an export gives one, and
// a few generic commands combine them. They know no table: each one reads
// the description of the records, as the module contract writes it.
//
//   where(table, field, value)   the rows whose field has the value
//   sort(table, field)           the rows in the order of a field
//   join(left, right, field)     each pair of rows with the same value of a field
//   columns(table, "a b c")      the rows with some fields only
//   first(table, count)          the first rows
//   rows(table)                  the count of rows
//   row(table, number)           one row, as a Record, from 1
//
// join and columns make records with a new description. The console writes
// that description in the format of the module contract: a header, a table
// directory, and the tables Records, Fields and Strings (description_make).
// The description has no second format.

TABLE_ARENA :: 256 * 1024 // The memory of the tables of one line.
TABLE_KEPT :: 32 * 1024 // The bytes of the rows that a variable keeps.
DESCRIPTION_SIZE :: 2048 // The bytes of a description that join or columns makes.
TEXT_COLUMN :: 24 // The widest column of a Text field when a table is printed.
COLUMN_CAPACITY :: 40

table_memory: [TABLE_ARENA]u8
table_used: int

// table_bytes gives zero bytes from the memory of the tables of the line,
// at a multiple of 8. nil: the line has no room.
table_bytes :: proc "contextless" (size: int) -> []u8 {
	start := (table_used + 7) &~ 7
	if size < 0 || size > len(table_memory) - start {
		return nil
	}
	table_used = start + size
	bytes := table_memory[start:table_used]
	for &b in bytes {
		b = 0
	}
	return bytes
}

// in_table_memory says if bytes are in the memory of the tables of the line:
// a variable that keeps them needs a copy.
in_table_memory :: proc "contextless" (bytes: []u8) -> bool {
	start, end := uintptr(&table_memory[0]), uintptr(&table_memory[0]) + TABLE_ARENA
	return len(bytes) > 0 && uintptr(raw_data(bytes)) >= start && uintptr(raw_data(bytes)) < end
}

// A Table value, read with its description.
Table :: struct {
	file:   []u8,
	record: module.Record,
	size:   int,
	rows:   int,
}

table_of :: proc "contextless" (value: Value) -> (table: Table, ok: bool) {
	if value.kind != .Table {
		return {}, false
	}
	table.record = module.record_type(value.file, value.detail) or_return
	table.file, table.size = value.file, int(table.record.size)
	if table.size == 0 {
		return {}, false
	}
	table.rows = len(value.record) / table.size
	return table, true
}

table_row :: proc "contextless" (table: Table, value: Value, index: int) -> []u8 {
	return value.record[index * table.size:][:table.size]
}

table_field :: proc "contextless" (table: Table, name: string) -> (item: module.Field, ok: bool) {
	for number in 0 ..< table.record.field_count {
		item = module.field(table.file, table.record, number) or_return
		if module.string_at(table.file, item.name_offset, item.name_count) == name {
			return item, true
		}
	}
	return {}, false
}

// field_names writes the names of the fields of a table, for an error.
field_names :: proc "contextless" (table: Table) -> string {
	start := scratch_count
	for number in 0 ..< table.record.field_count {
		item, _ := module.field(table.file, table.record, number)
		scratch_text(number > 0 ? ", " : "", module.string_at(table.file, item.name_offset, item.name_count))
	}
	return string(scratch[start:scratch_count])
}

// row_value gives one field of a row as a value: an Integer, a Text or a Handle.
row_value :: proc "contextless" (row: []u8, item: module.Field) -> Value {
	#partial switch item.type {
	case .Integer:
		return {kind = .Integer, integer = module.field_integer(row, item)}
	case .Handle:
		return {kind = .Handle, integer = i64((^u32)(&row[item.offset])^)}
	case .Text:
		return {kind = .Text, text = module.field_text(row, item)}
	}
	return {}
}

// compare gives -1, 0 or 1: Integers by value, Texts byte by byte.
compare :: proc "contextless" (a, b: Value) -> int {
	if a.kind == .Text {
		for i in 0 ..< min(len(a.text), len(b.text)) {
			if a.text[i] != b.text[i] {
				return a.text[i] < b.text[i] ? -1 : 1
			}
		}
		return len(a.text) < len(b.text) ? -1 : len(a.text) > len(b.text) ? 1 : 0
	}
	return a.integer < b.integer ? -1 : a.integer > b.integer ? 1 : 0
}

// table_argument reads the table argument of a command, and one of its
// fields by name.
table_argument :: proc "contextless" (command: string, value: Value, name: string) -> (table: Table, item: module.Field, ok: bool) {
	table, ok = table_of(value)
	if !ok {
		fail(command, ": the table has no valid description")
		return
	}
	if item, ok = table_field(table, name); !ok {
		fail(command, ": the records ", type_text(table.file, .Record, value.detail), " have no field ", name, "; their fields are ", field_names(table))
	}
	return
}

tables_start :: proc "contextless" () {
	command("where", {.Table, .Text, .None}, .Table, "the rows of a table whose field has a value", table_where)
	command("sort", {.Table, .Text}, .Table, "the rows of a table in the order of a field", table_sort)
	command("join", {.Table, .Table, .Text}, .Table, "each pair of rows of two tables with one value of a field", table_join)
	command("columns", {.Table, .Text}, .Table, "the rows with the fields that a text names: \"a b c\"", table_columns)
	command("first", {.Table, .Integer}, .Table, "the first rows of a table", table_first)
	command("rows", {.Table}, .Integer, "the count of rows of a table", table_count)
	command("row", {.Table, .Integer}, .Record, "one row of a table, from 1", table_one)
}

// table_where gives the rows of a table whose field has the value: an
// Integer for an Integer or Handle field, a Text for a Text field.
table_where :: proc "contextless" (arguments: []Value) -> Value {
	table, item, ok := table_argument("where", arguments[0], arguments[1].text)
	if !ok {
		return {}
	}
	wanted := arguments[2]
	expected: Kind = item.type == .Text ? .Text : .Integer
	if wanted.kind != expected {
		return fail("where: the field ", arguments[1].text, " is ", type_text(table.file, Kind(item.type), item.detail), ", the value is ", kind_names[wanted.kind])
	}
	count := 0
	for index in 0 ..< table.rows {
		count += int(compare(row_value(table_row(table, arguments[0], index), item), wanted) == 0)
	}
	bytes := table_bytes(count * table.size)
	if bytes == nil && count > 0 {
		return fail("where: the line has no room for ", i64(count), " rows")
	}
	place := 0
	for index in 0 ..< table.rows {
		row := table_row(table, arguments[0], index)
		if compare(row_value(row, item), wanted) == 0 {
			copy(bytes[place:], row)
			place += table.size
		}
	}
	return {kind = .Table, record = bytes, file = arguments[0].file, detail = arguments[0].detail}
}

// table_sort gives the rows of a table in the increasing order of a field.
// Rows with the same value keep their order.
table_sort :: proc "contextless" (arguments: []Value) -> Value {
	table, item, ok := table_argument("sort", arguments[0], arguments[1].text)
	if !ok {
		return {}
	}
	bytes := table_bytes(len(arguments[0].record))
	if bytes == nil && table.rows > 0 {
		return fail("sort: the line has no room for ", i64(table.rows), " rows")
	}
	copy(bytes, arguments[0].record)
	sorted := Value{kind = .Table, record = bytes, file = arguments[0].file, detail = arguments[0].detail}
	held: [module.RECORD_SIZE_LIMIT]u8
	for index in 1 ..< table.rows {
		copy(held[:], table_row(table, sorted, index))
		key := row_value(held[:table.size], item)
		place := index
		for place > 0 && compare(row_value(table_row(table, sorted, place - 1), item), key) > 0 {
			copy(table_row(table, sorted, place), table_row(table, sorted, place - 1))
			place -= 1
		}
		copy(table_row(table, sorted, place), held[:table.size])
	}
	return sorted
}

// A field of a record that join or columns makes, and where its bytes come
// from: a field of the left table (0) or of the right table (1).
Column :: struct {
	name:   string,
	type:     module.Type,
	detail:   u32,
	unsigned: bool,
	side:     int,
	from:   u32, // The offset of the field in the record of its table.
	offset: u32, // The offset of the field in the new record.
}

// description_make writes the description of one record in the format of
// the module contract, in the memory of the tables of the line, and gives
// the offset of each column and the size of the record.
description_make :: proc "contextless" (name: string, columns: []Column) -> (file: []u8, size: u32, ok: bool) {
	Directory :: [module.TABLE_COUNT]module.Table_Entry
	file = table_bytes(DESCRIPTION_SIZE)
	if file == nil || len(columns) == 0 {
		return nil, 0, false
	}
	alignment := u32(1)
	for &column in columns {
		column_alignment: u32 = column.type == .Text ? 1 : module.field_size(column.type, column.detail)
		size = (size + column_alignment - 1) / column_alignment * column_alignment
		column.offset = size
		size += module.field_size(column.type, column.detail)
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
	record.name_offset = text(file, strings, &text_count, name) or_return
	if int(fields) + (len(columns) + 1) * size_of(module.Field) > len(file) {
		return nil, size, false
	}
	(^module.Record)(&file[records + size_of(module.Record)])^ = record
	for column, index in columns {
		item := module.Field {
			offset     = column.offset,
			type       = column.type,
			detail     = column.detail,
			unsigned   = column.unsigned,
			name_count = u32(len(column.name)),
		}
		item.name_offset = text(file, strings, &text_count, column.name) or_return
		(^module.Field)(&file[fields + u32(index + 1) * size_of(module.Field)])^ = item
	}
	directory[module.Table_Kind.Records] = {offset = u64(records), count = 2, record_size = size_of(module.Record)}
	directory[module.Table_Kind.Fields] = {offset = u64(fields), count = u32(len(columns) + 1), record_size = size_of(module.Field)}
	directory[module.Table_Kind.Strings] = {offset = u64(strings), count = text_count, record_size = 1}
	(^module.Header)(&file[0])^ = {magic = module.MAGIC, version = module.VERSION, header_size = size_of(module.Header), machine = .X86_64, table_count = module.TABLE_COUNT}
	(^Directory)(&file[size_of(module.Header)])^ = directory
	return file[:strings + text_count], size, true
}

// columns_of adds the fields of a table to a list of columns. With skip,
// it leaves out each field whose name the list has.
columns_of :: proc "contextless" (table: Table, side: int, list: ^[COLUMN_CAPACITY]Column, count: ^int, skip: bool) -> bool {
	each: for number in 0 ..< table.record.field_count {
		item, _ := module.field(table.file, table.record, number)
		name := module.string_at(table.file, item.name_offset, item.name_count)
		if skip {
			for column in list[:count^] {
				if column.name == name {
					continue each
				}
			}
		}
		if count^ == COLUMN_CAPACITY {
			return false
		}
		list[count^] = {name = name, type = item.type, detail = item.detail, unsigned = item.unsigned, side = side, from = item.offset}
		count^ += 1
	}
	return true
}

// table_join gives a row for each pair of a row of the left table and a row
// of the right table that have the same value of a field. The new record
// has each field of the left record, then each field of the right record
// whose name the left record does not have.
table_join :: proc "contextless" (arguments: []Value) -> Value {
	name := arguments[2].text
	left, left_item, left_ok := table_argument("join", arguments[0], name)
	if !left_ok {
		return {}
	}
	right, right_item, right_ok := table_argument("join", arguments[1], name)
	if !right_ok {
		return {}
	}
	if (left_item.type == .Text) != (right_item.type == .Text) {
		return fail("join: the field ", name, " is ", type_text(left.file, Kind(left_item.type), left_item.detail), " on the left and ", type_text(right.file, Kind(right_item.type), right_item.detail), " on the right")
	}
	columns: [COLUMN_CAPACITY]Column
	count := 0
	if !columns_of(left, 0, &columns, &count, false) || !columns_of(right, 1, &columns, &count, true) {
		return fail("join: the new record has more than ", i64(COLUMN_CAPACITY), " fields")
	}
	left_name := module.string_at(left.file, left.record.name_offset, left.record.name_count)
	right_name := module.string_at(right.file, right.record.name_offset, right.record.name_count)
	file, size, made := description_make(scratch_text(left_name, "_", right_name), columns[:count])
	if !made {
		return fail("join: the new record has ", u64(size), " bytes, the limit is ", u64(module.RECORD_SIZE_LIMIT), "; choose fewer fields with columns()")
	}
	rows := 0
	for a in 0 ..< left.rows {
		key := row_value(table_row(left, arguments[0], a), left_item)
		for b in 0 ..< right.rows {
			rows += int(compare(key, row_value(table_row(right, arguments[1], b), right_item)) == 0)
		}
	}
	bytes := table_bytes(rows * int(size))
	if bytes == nil && rows > 0 {
		return fail("join: the line has no room for ", i64(rows), " rows")
	}
	place := 0
	for a in 0 ..< left.rows {
		row_left := table_row(left, arguments[0], a)
		key := row_value(row_left, left_item)
		for b in 0 ..< right.rows {
			row_right := table_row(right, arguments[1], b)
			if compare(key, row_value(row_right, right_item)) != 0 {
				continue
			}
			for column in columns[:count] {
				source := column.side == 0 ? row_left : row_right
				width := module.field_size(column.type, column.detail)
				copy(bytes[place + int(column.offset):][:width], source[column.from:][:width])
			}
			place += int(size)
		}
	}
	return {kind = .Table, record = bytes, file = file, detail = 1}
}

// table_columns gives the rows with the fields that a text names, in that
// order. The names are separated by spaces or commas.
table_columns :: proc "contextless" (arguments: []Value) -> Value {
	table, ok := table_of(arguments[0])
	if !ok {
		return fail("columns: the table has no valid description")
	}
	columns: [COLUMN_CAPACITY]Column
	count := 0
	rest := arguments[1].text
	for len(rest) > 0 {
		end := 0
		for end < len(rest) && rest[end] != ' ' && rest[end] != ',' {
			end += 1
		}
		name := rest[:end]
		rest = rest[min(end + 1, len(rest)):]
		if name == "" {
			continue
		}
		item, found := table_field(table, name)
		if !found {
			return fail("columns: the records ", type_text(table.file, .Record, arguments[0].detail), " have no field ", name, "; their fields are ", field_names(table))
		}
		if count == COLUMN_CAPACITY {
			return fail("columns: more than ", i64(COLUMN_CAPACITY), " fields")
		}
		columns[count] = {name = name, type = item.type, detail = item.detail, unsigned = item.unsigned, from = item.offset}
		count += 1
	}
	if count == 0 {
		return fail("columns: the text names no field; the fields are ", field_names(table))
	}
	file, size, made := description_make(module.string_at(table.file, table.record.name_offset, table.record.name_count), columns[:count])
	if !made {
		return fail("columns: no room for the description")
	}
	bytes := table_bytes(table.rows * int(size))
	if bytes == nil && table.rows > 0 {
		return fail("columns: the line has no room for ", i64(table.rows), " rows")
	}
	for index in 0 ..< table.rows {
		row := table_row(table, arguments[0], index)
		for column in columns[:count] {
			width := module.field_size(column.type, column.detail)
			copy(bytes[index * int(size) + int(column.offset):][:width], row[column.from:][:width])
		}
	}
	return {kind = .Table, record = bytes, file = file, detail = 1}
}

table_first :: proc "contextless" (arguments: []Value) -> Value {
	table, ok := table_of(arguments[0])
	if !ok {
		return fail("first: the table has no valid description")
	}
	kept := clamp(int(arguments[1].integer), 0, table.rows)
	result := arguments[0]
	result.record = result.record[:kept * table.size]
	return result
}

table_count :: proc "contextless" (arguments: []Value) -> Value {
	table, ok := table_of(arguments[0])
	if !ok {
		return fail("rows: the table has no valid description")
	}
	return {kind = .Integer, integer = i64(table.rows)}
}

table_one :: proc "contextless" (arguments: []Value) -> Value {
	table, ok := table_of(arguments[0])
	if !ok {
		return fail("row: the table has no valid description")
	}
	number := arguments[1].integer
	if number < 1 || number > i64(table.rows) {
		return fail("row: the table has ", i64(table.rows), " rows, not a row ", number)
	}
	bytes := scratch_bytes(table.size)
	if bytes == nil {
		return fail("the line has too many records")
	}
	copy(bytes, table_row(table, arguments[0], int(number - 1)))
	return {kind = .Record, record = bytes, file = arguments[0].file, detail = arguments[0].detail}
}

// table_print prints a table: a line with the names of the fields, a line
// for each row, and the count of rows. A Text longer than TEXT_COLUMN ends
// with "..".
table_print :: proc "contextless" (value: Value) {
	table, ok := table_of(value)
	if !ok {
		print("a table with no valid description\n")
		return
	}
	field_count := min(int(table.record.field_count), COLUMN_CAPACITY)
	items: [COLUMN_CAPACITY]module.Field
	widths: [COLUMN_CAPACITY]int
	for number in 0 ..< field_count {
		items[number], _ = module.field(table.file, table.record, u32(number))
		widths[number] = int(items[number].name_count)
	}
	for index in 0 ..< table.rows {
		row := table_row(table, value, index)
		for number in 0 ..< field_count {
			widths[number] = max(widths[number], cell_width(row_value(row, items[number])))
		}
	}
	line: [256]u8
	writer := system.Writer {
		buffer = line[:],
	}
	for number in 0 ..< field_count {
		cell_write(&writer, module.string_at(table.file, items[number].name_offset, items[number].name_count), widths[number], number == field_count - 1)
	}
	print(system.written(&writer), "\n")
	for index in 0 ..< table.rows {
		row := table_row(table, value, index)
		writer.count = 0
		for number in 0 ..< field_count {
			cell := row_value(row, items[number])
			text := cell.text
			if cell.kind != .Text {
				buffer: [24]u8
				text = system.format(buffer[:], cell.integer)
				cell_write(&writer, text, widths[number], number == field_count - 1)
				continue
			}
			cell_write(&writer, text, widths[number], number == field_count - 1)
		}
		print(system.written(&writer), "\n")
	}
	print(i64(table.rows), table.rows == 1 ? " row of " : " rows of ", type_text(table.file, .Record, value.detail), "\n")
}

cell_width :: proc "contextless" (cell: Value) -> int {
	if cell.kind == .Text {
		return min(len(cell.text), TEXT_COLUMN)
	}
	buffer: [24]u8
	return len(system.format(buffer[:], cell.integer))
}

// cell_write writes one cell of a table and the space after it.
cell_write :: proc "contextless" (writer: ^system.Writer, text: string, width: int, last: bool) {
	shown := text
	if len(shown) > width {
		shown = shown[:max(width - 2, 0)]
	}
	system.write_part(writer, shown)
	if len(shown) < len(text) {
		system.write_part(writer, "..")
	}
	if last {
		return
	}
	for _ in min(len(text), width) ..< width + 2 {
		system.write_part(writer, " ")
	}
}
// The buffer of a Table result of a direct call: the free part of the
// memory of the tables of the line.
Table_Buffer :: struct {
	slice: struct {
		address:  uintptr,
		capacity: u64, // In records.
	},
	size:  int,
}

table_buffer :: proc "contextless" (file: []u8, detail: u32) -> (buffer: Table_Buffer) {
	described, _ := module.record_type(file, detail)
	buffer.size = int(described.size)
	start := (table_used + 7) &~ 7
	if buffer.size == 0 || start > len(table_memory) {
		return buffer
	}
	buffer.slice = {uintptr(&table_memory[0]) + uintptr(start), u64((len(table_memory) - start) / buffer.size)}
	return buffer
}

// table_take gives the Table value of a direct call: the export wrote the
// records in the buffer, and gave the count of records of the full table.
table_take :: proc "contextless" (item: ^Command, buffer: ^Table_Buffer, count: u64) -> Value {
	if i64(count) < 0 {
		return table_error(item, i64(count))
	}
	if count > buffer.slice.capacity {
		return fail("the result of ", item.name, " has ", count, " records; ", buffer.slice.capacity, " fit in the memory of the line")
	}
	// The records stay where the export wrote them: the line keeps them.
	start := (table_used + 7) &~ 7
	table_used = start + int(count) * buffer.size
	bytes := table_memory[start:table_used]
	return {kind = .Table, record = bytes, file = item.file, detail = item.function.result_detail}
}

// table_error reports the negative count of a Table result: the export had
// no table to give. Its documentation says what each number means.
table_error :: proc "contextless" (item: ^Command, number: i64) -> Value {
	return fail(item.name, " gave no table but the error ", number, ": the documentation of the export says what it means")
}
