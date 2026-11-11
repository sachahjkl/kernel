package information

import module "contract:module"
import "support:system"

// What is wrong in a module file, or in a question.
Problem_Kind :: enum u32 {
	None      = 0,
	No_Module = 1, // The catalog has no module with this name or this hash.
	Header    = 2, // module.header refused the header: `header` says why.
	Table     = 3, // A table of the directory is not inside the file, or the rebase table has records of another size.
	Segment   = 4, // A segment is not inside the file or the memory of the module, its pages are not whole, or it executes and the loader writes it.
	Entry     = 5, // The entry of the header names no export.
	Export    = 6, // An export names a description that the table does not have, or code outside the memory of the module.
	Text      = 7, // A name or a text is not inside the string table.
	Function  = 8, // A description of an export has more than 6 parameters, or a type that does not exist, or names no record.
	Record    = 9, // A record description has a field outside the record, a field of no type, or more than 256 bytes.
	Slot      = 10, // A slot names no import.
	Refused   = 11, // The kernel refused a report: `value` is the status. The machine handle needs the right Inspect.
	Direction = 12, // A direction of a parameter is not Read, Change or Append, or a parameter that is not a Table or Bytes has one.
}

@(rodata)
problem_names := [Problem_Kind]string {
	.None      = "",
	.No_Module = "no module",
	.Header    = "header",
	.Table     = "table",
	.Segment   = "segment",
	.Entry     = "entry",
	.Export    = "export",
	.Text      = "text",
	.Function  = "function",
	.Record    = "record",
	.Slot      = "slot",
	.Refused   = "refused",
	.Direction = "direction",
}

@(rodata)
table_names := [module.Table_Kind]string {
	.None          = "header",
	.Segments      = "Segments",
	.Imports       = "Imports",
	.Slots         = "Slots",
	.Exports       = "Exports",
	.Rebases       = "Rebases",
	.Functions     = "Functions",
	.Strings       = "Strings",
	.Documentation = "Documentation",
	.Records       = "Records",
	.Fields        = "Fields",
}

// An error value with its detail. kind None: no problem.
Problem :: struct {
	kind:   Problem_Kind,
	header: module.Error, // Header: what module.header found.
	table:  module.Table_Kind, // The table of the bad record. None: the header or the directory.
	index:  u32, // The record of that table, from 0.
	offset: u64, // The byte of the file where the bad value is.
	value:  u64, // The bad value.
	limit:  u64, // The rule: the value must be below this limit.
}

// problem_write writes a problem as one sentence for a person:
// "tally: table Functions, record 3, byte 4120: a text is not inside the
// string table: 5000 is not below 4096".
problem_write :: proc "contextless" (writer: ^system.Writer, name: string, problem: Problem) {
	system.write_part(writer, name)
	system.write_part(writer, ": ")
	if problem.kind == .No_Module {
		system.write_part(writer, "the catalog has no such module")
		return
	}
	if problem.kind == .Refused {
		system.write_part(writer, "the kernel refused the report with the status ")
		system.write_part(writer, problem.value)
		system.write_part(writer, ": the machine handle needs the right Inspect")
		return
	}
	system.write_part(writer, problem.table == .None ? "the header" : "table ")
	if problem.table != .None {
		system.write_part(writer, table_names[problem.table])
		system.write_part(writer, ", record ")
		system.write_part(writer, u64(problem.index))
	}
	system.write_part(writer, ", byte ")
	system.write_part(writer, problem.offset)
	system.write_part(writer, ": ")
	system.write_part(writer, problem_texts[problem.kind])
	if problem.limit != 0 {
		system.write_part(writer, ": ")
		system.write_part(writer, problem.value)
		system.write_part(writer, " is not below ")
		system.write_part(writer, problem.limit)
	}
}

@(rodata)
problem_texts := [Problem_Kind]string {
	.None      = "no problem",
	.No_Module = "no such module",
	.Header    = "the header is not a module header of this machine",
	.Table     = "the table is not inside the file",
	.Segment   = "the segment breaks a rule of the loader",
	.Entry     = "the entry names no export",
	.Export    = "the export names a description that the table does not have, or code outside the module",
	.Text      = "a text is not inside the string table",
	.Function  = "the description of the export has a bad count or type",
	.Record    = "the record description has a bad field",
	.Slot      = "the slot names no import",
	.Refused   = "the kernel refused the report",
	.Direction = "a parameter has a direction that its type does not take",
}

// place gives the byte of the file where a field of record `index` of a
// table is.
@(private)
place :: proc "contextless" (file: []u8, kind: module.Table_Kind, index: u32, field: uintptr) -> u64 {
	entry := module.table(file, kind)
	return entry.offset + u64(index) * u64(entry.record_size) + u64(field)
}

// text_inside says if a text of the string table is inside it.
@(private)
text_inside :: proc "contextless" (file: []u8, offset, count: u32) -> (value, limit: u64, ok: bool) {
	strings := module.table(file, .Strings).count
	return u64(offset) + u64(count), u64(strings), u64(offset) + u64(count) <= u64(strings)
}

// check gives the first problem of a module file: the header, the range of
// each table, the segments, the exports, the descriptions of the exports
// and of the records, each name and text, and the slots. kind None: the
// module keeps each of these rules, and the functions of this package read
// it as it is.
check :: proc "contextless" (file: []u8) -> Problem {
	head, error := module.header(file)
	if error != .None {
		return {kind = .Header, header = error}
	}
	for kind in module.Table_Kind {
		if u32(kind) >= head.table_count {
			break
		}
		entry := module.table(file, kind)
		size := u64(entry.count) * u64(entry.record_size)
		directory := u64(head.header_size) + u64(kind) * size_of(module.Table_Entry)
		if entry.offset > u64(len(file)) || size > u64(len(file)) - entry.offset {
			return {kind = .Table, table = .None, index = u32(kind), offset = directory, value = entry.offset + size, limit = u64(len(file))}
		}
		if kind == .Rebases && entry.count != 0 && entry.record_size != module.REBASE_WORD_SIZE {
			return {kind = .Table, table = .None, index = u32(kind), offset = directory + 12}
		}
	}
	if head.memory_size % module.PAGE_SIZE != 0 {
		return {kind = .Segment, offset = u64(offset_of(module.Header, memory_size)), value = head.memory_size}
	}
	for index in 1 ..< module.count(file, .Segments) {
		segment, _ := module.record(file, .Segments, index, module.Segment)
		at := place(file, .Segments, index, 0)
		switch {
		case segment.memory_offset % module.PAGE_SIZE != 0 || segment.memory_size % module.PAGE_SIZE != 0:
			return {kind = .Segment, table = .Segments, index = index, offset = at + u64(offset_of(module.Segment, memory_offset))}
		case segment.memory_offset > head.memory_size || segment.memory_size > head.memory_size - segment.memory_offset:
			return {kind = .Segment, table = .Segments, index = index, offset = at + u64(offset_of(module.Segment, memory_size)), value = segment.memory_offset + segment.memory_size, limit = head.memory_size + 1}
		case segment.file_size > segment.memory_size:
			return {kind = .Segment, table = .Segments, index = index, offset = at + u64(offset_of(module.Segment, file_size)), value = segment.file_size, limit = segment.memory_size + 1}
		case segment.file_offset > u64(len(file)) || segment.file_size > u64(len(file)) - segment.file_offset:
			return {kind = .Segment, table = .Segments, index = index, offset = at + u64(offset_of(module.Segment, file_offset)), value = segment.file_offset + segment.file_size, limit = u64(len(file)) + 1}
		case .Execute in segment.flags && segment.flags & {.Write, .Read_Only_After_Load} != {}:
			return {kind = .Segment, table = .Segments, index = index, offset = at + u64(offset_of(module.Segment, flags))}
		}
	}
	exports := module.count(file, .Exports)
	if head.entry_export >= max(exports, 1) {
		return {kind = .Entry, offset = u64(offset_of(module.Header, entry_export)), value = u64(head.entry_export), limit = u64(max(exports, 1))}
	}
	functions := module.count(file, .Functions)
	for index in 1 ..< exports {
		export, _ := module.record(file, .Exports, index, module.Export)
		at := place(file, .Exports, index, 0)
		if export.function >= max(functions, 1) {
			return {kind = .Export, table = .Exports, index = index, offset = at + u64(offset_of(module.Export, function)), value = u64(export.function), limit = u64(max(functions, 1))}
		}
		if export.code_offset >= head.memory_size {
			return {kind = .Export, table = .Exports, index = index, offset = at, value = export.code_offset, limit = head.memory_size}
		}
	}
	// The records first: a description of an export names them.
	for index in 1 ..< module.count(file, .Records) {
		if problem := record_check(file, index); problem.kind != .None {
			return problem
		}
	}
	for index in 1 ..< functions {
		function, _ := module.record(file, .Functions, index, module.Function)
		if problem := function_check(file, index, function); problem.kind != .None {
			return problem
		}
	}
	documentation, _ := module.record(file, .Documentation, 1, module.Documentation)
	for pair, number in ([2][2]u32{{documentation.about_offset, documentation.about_count}, {documentation.text_offset, documentation.text_count}}) {
		if value, limit, inside := text_inside(file, pair[0], pair[1]); !inside {
			return {kind = .Text, table = .Documentation, index = 1, offset = place(file, .Documentation, 1, uintptr(number * 8)), value = value, limit = limit + 1}
		}
	}
	imports := module.count(file, .Imports)
	for index in 1 ..< module.count(file, .Slots) {
		slot, _ := module.record(file, .Slots, index, module.Slot)
		if slot.import_index == 0 || slot.import_index >= imports {
			return {kind = .Slot, table = .Slots, index = index, offset = place(file, .Slots, index, offset_of(module.Slot, import_index)), value = u64(slot.import_index), limit = u64(max(imports, 1))}
		}
	}
	return {}
}

@(private)
function_check :: proc "contextless" (file: []u8, index: u32, function: module.Function) -> Problem {
	function := function
	at := place(file, .Functions, index, 0)
	texts := [?][3]u32 {
		{function.name_offset, function.name_count, u32(offset_of(module.Function, name_offset))},
		{function.about_offset, function.about_count, u32(offset_of(module.Function, about_offset))},
		{function.text_offset, function.text_count, u32(offset_of(module.Function, text_offset))},
	}
	for item in texts {
		if value, limit, inside := text_inside(file, item[0], item[1]); !inside {
			return {kind = .Text, table = .Functions, index = index, offset = at + u64(item[2]), value = value, limit = limit + 1}
		}
	}
	if function.parameter_count > module.PARAMETER_CAPACITY {
		return {kind = .Function, table = .Functions, index = index, offset = at + u64(offset_of(module.Function, parameter_count)), value = u64(function.parameter_count), limit = module.PARAMETER_CAPACITY + 1}
	}
	for type, number in function.parameters[:function.parameter_count] {
		field := at + u64(offset_of(module.Function, parameters)) + u64(number)
		if value, limit, inside := text_inside(file, function.parameter_names[number], u32(function.parameter_name_counts[number])); !inside {
			return {kind = .Text, table = .Functions, index = index, offset = at + u64(offset_of(module.Function, parameter_names)) + 4 * u64(number), value = value, limit = limit + 1}
		}
		if type == .None || type > .Bytes {
			return {kind = .Function, table = .Functions, index = index, offset = field, value = u64(type), limit = u64(module.Type.Bytes) + 1}
		}
		detail_at := at + u64(offset_of(module.Function, parameter_details)) + 4 * u64(number)
		if type == .Record || type == .Table {
			described, valid := module.record_type(file, function.parameter_details[number])
			if !valid {
				return {kind = .Function, table = .Functions, index = index, offset = detail_at, value = u64(function.parameter_details[number]), limit = u64(max(module.count(file, .Records), 1))}
			}
			// A record of a table has no handle: one call lends at most 16.
			if type == .Table && module.record_has_handle(file, described) {
				return {kind = .Function, table = .Functions, index = index, offset = detail_at, value = u64(function.parameter_details[number])}
			}
		}
		if type == .Bytes && function.parameter_details[number] != 0 {
			return {kind = .Function, table = .Functions, index = index, offset = detail_at, value = u64(function.parameter_details[number]), limit = 1}
		}
		direction := function.parameter_directions[number]
		if direction > max(module.Direction) || direction != .Read && type != .Table && type != .Bytes {
			return {kind = .Direction, table = .Functions, index = index, offset = at + u64(offset_of(module.Function, parameter_directions)) + u64(number), value = u64(direction), limit = type == .Table || type == .Bytes ? u64(max(module.Direction)) + 1 : 1}
		}
	}
	if function.result > .Table { // Bytes (6) is a parameter only.
		return {kind = .Function, table = .Functions, index = index, offset = at + u64(offset_of(module.Function, result)), value = u64(function.result), limit = u64(module.Type.Table) + 1}
	}
	if function.result == .Record || function.result == .Table {
		if _, valid := module.record_type(file, function.result_detail); !valid {
			return {kind = .Function, table = .Functions, index = index, offset = at + u64(offset_of(module.Function, result_detail)), value = u64(function.result_detail), limit = u64(max(module.count(file, .Records), 1))}
		}
	}
	if function.error_record != 0 {
		if _, valid := module.record_type(file, function.error_record); !valid || function.result == .Record {
			return {kind = .Function, table = .Functions, index = index, offset = at + u64(offset_of(module.Function, error_record)), value = u64(function.error_record), limit = u64(max(module.count(file, .Records), 1))}
		}
	}
	return {}
}

@(private)
record_check :: proc "contextless" (file: []u8, index: u32) -> Problem {
	described, _ := module.record(file, .Records, index, module.Record)
	at := place(file, .Records, index, 0)
	if value, limit, inside := text_inside(file, described.name_offset, described.name_count); !inside {
		return {kind = .Text, table = .Records, index = index, offset = at, value = value, limit = limit + 1}
	}
	if described.size > module.RECORD_SIZE_LIMIT {
		return {kind = .Record, table = .Records, index = index, offset = at + u64(offset_of(module.Record, size)), value = u64(described.size), limit = module.RECORD_SIZE_LIMIT + 1}
	}
	fields := module.count(file, .Fields)
	if described.field_count != 0 && (described.first_field == 0 || u64(described.first_field) + u64(described.field_count) > u64(fields)) {
		return {kind = .Record, table = .Records, index = index, offset = at + u64(offset_of(module.Record, first_field)), value = u64(described.first_field) + u64(described.field_count), limit = u64(fields) + 1}
	}
	for number in 0 ..< described.field_count {
		item, _ := module.field(file, described, number)
		field := described.first_field + number
		field_at := place(file, .Fields, field, 0)
		if value, limit, inside := text_inside(file, item.name_offset, item.name_count); !inside {
			return {kind = .Text, table = .Fields, index = field, offset = field_at, value = value, limit = limit + 1}
		}
		size := module.field_size(item.type, item.detail)
		if size == 0 {
			return {kind = .Record, table = .Fields, index = field, offset = field_at + u64(offset_of(module.Field, type)), value = u64(item.type)}
		}
		if u64(item.offset) + u64(size) > u64(described.size) {
			return {kind = .Record, table = .Fields, index = field, offset = field_at + u64(offset_of(module.Field, offset)), value = u64(item.offset) + u64(size), limit = u64(described.size) + 1}
		}
		// An Integer is at a multiple of its size.
		if item.type == .Integer && item.offset % size != 0 {
			return {kind = .Record, table = .Fields, index = field, offset = field_at + u64(offset_of(module.Field, offset)), value = u64(item.offset), limit = u64(size)}
		}
	}
	return {}
}