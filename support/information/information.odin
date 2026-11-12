package information

import "contract:cut_mark"
import module "contract:module"
import op "contract:operation"
import "support:system"

// The modules that a program can see, and the replacements of the
// machine. Today: the boot image that the program was granted
// (system.GRANT_IMAGE), and the records of the replacement table
// (system.GRANT_REPLACEMENTS, system.replacements_read). A module store
// gives the same functions another source later. The zero value is a
// catalog with no module and no replacement.
Catalog :: struct {
	image:        []u8,
	replacements: []module.Replacement,
}

// replacement_of gives the module that a loader gives in place of an
// import that names a hash, on this machine. ok is false: no replacement.
replacement_of :: proc "contextless" (catalog: Catalog, hash: [32]u8) -> (to: [32]u8, ok: bool) {
	for item in catalog.replacements {
		if item.from == hash {
			return item.to, true
		}
	}
	return {}, false
}

// An item of the catalog: a name, a hash, and the file. The file is empty
// when the catalog names bytes outside itself.
Item :: struct {
	name: string,
	hash: [32]u8,
	file: []u8,
}

// item gives item `index` of the catalog, from 0. ok is false after the
// last one.
item :: proc "contextless" (catalog: Catalog, index: int) -> (found: Item, ok: bool) {
	entries := system.image_entries(catalog.image)
	if index < 0 || index >= len(entries) {
		return {}, false
	}
	entry := &entries[index]
	found = {name = system.name_of(entry.name[:]), hash = entry.hash}
	if entry.offset <= u64(len(catalog.image)) && entry.size <= u64(len(catalog.image)) - entry.offset {
		found.file = catalog.image[entry.offset:][:entry.size]
	}
	return found, true
}

// find gives the module of the catalog with a name. The name can also be
// the hash of the module, in hexadecimal: 64 digits. problem: No_Module, or
// what check found in the file.
find :: proc "contextless" (catalog: Catalog, name: string) -> (found: Item, problem: Problem) {
	hash, is_hash := hash_parse(name)
	for index := 0; ; index += 1 {
		candidate, ok := item(catalog, index)
		if !ok {
			return {}, {kind = .No_Module}
		}
		if is_hash ? candidate.hash == hash : candidate.name == name {
			return candidate, check(candidate.file)
		}
	}
}

// find_hash gives the module of the catalog with a hash. ok is false when
// the catalog has none.
find_hash :: proc "contextless" (catalog: Catalog, hash: [32]u8) -> (found: Item, ok: bool) {
	for index := 0; ; index += 1 {
		found = item(catalog, index) or_return
		if found.hash == hash {
			return found, true
		}
	}
}

// hash_parse reads a hash in hexadecimal: 64 digits, small letters.
hash_parse :: proc "contextless" (text: string) -> (hash: [32]u8, ok: bool) {
	if len(text) != 64 {
		return {}, false
	}
	for i in 0 ..< 64 {
		c := text[i]
		digit: u8
		switch c {
		case '0' ..= '9':
			digit = c - '0'
		case 'a' ..= 'f':
			digit = c - 'a' + 10
		case:
			return {}, false
		}
		hash[i / 2] |= i % 2 == 0 ? digit << 4 : digit
	}
	return hash, true
}

// hash_text writes a hash in hexadecimal: 64 digits.
hash_text :: proc "contextless" (hash: [32]u8, into: ^[64]u8) {
	digits := system.HEX_DIGITS
	for b, index in hash {
		into[2 * index], into[2 * index + 1] = digits[b >> 4], digits[b & 0xF]
	}
}

// text_put writes a text in a Text field. A text longer than the field
// ends with the cut mark and the count of the missing bytes, after a whole
// character (contract:cut_mark); the bytes after it are zero.
text_put :: proc "contextless" (field: []u8, text: string) {
	for &b in field {
		b = 0
	}
	count := copy(field, text)
	_, _, _ = cut_mark.apply(field, count, len(text) - count)
}

// described_export says if export `index` has a description that a person
// can call: each export but the entry, with a name.
described_export :: proc "contextless" (file: []u8, index: u32) -> (function: module.Function, ok: bool) {
	head, _ := module.header(file)
	function = module.function(file, index) or_return
	return function, index != head.entry_export && function.name_count != 0
}

// modules fills one row for each module of the catalog: its name, its
// hash, its sizes, what it has, and its first problem. A malformed module
// has a row too: the fields `problem`, `place`, `index` and `offset` say
// where it breaks a rule, and its counts are 0.
// count is the count of modules: the rows that fit are written.
modules :: proc "contextless" (catalog: Catalog, rows: []Module) -> (count: int) {
	for index := 0; ; index += 1 {
		found := item(catalog, index) or_break
		if count < len(rows) {
			module_row(found, &rows[count])
		}
		count += 1
	}
	return count
}

// module_row fills the row of one module.
module_row :: proc "contextless" (found: Item, row: ^Module) {
	row^ = {}
	text_put(row.name[:], found.name)
	hash_text(found.hash, &row.hash)
	row.file = i64(len(found.file))
	problem := check(found.file)
	if problem.kind != .None {
		text_put(row.problem[:], problem_names[problem.kind])
		text_put(row.place[:], table_names[problem.table])
		row.index, row.offset = i64(problem.index), i64(problem.offset)
		return
	}
	file := found.file
	head, _ := module.header(file)
	for index in 1 ..< module.count(file, .Segments) {
		segment, _ := module.record(file, .Segments, index, module.Segment)
		switch {
		case .Execute in segment.flags:
			row.code += i64(segment.memory_size)
		case .Write not_in segment.flags || .Read_Only_After_Load in segment.flags:
			row.constants += i64(segment.memory_size)
		case:
			row.data += i64(segment.file_size)
			row.zero += i64(segment.memory_size - segment.file_size)
		}
	}
	row.entry = i64(head.entry_export != 0)
	for index in 1 ..< module.count(file, .Exports) {
		_, described := described_export(file, index)
		row.exports += i64(described)
	}
	row.imports = i64(max(module.count(file, .Imports), 1) - 1)
	row.records = i64(max(module.count(file, .Records), 1) - 1)
}

// exports fills one row for each export with a description of a module,
// by name or by hash. With the name "", it fills the rows of each module of
// the catalog that has no problem. problem: the named module is not in the
// catalog, or is malformed; then count is 0.
exports :: proc "contextless" (catalog: Catalog, name: string, rows: []Export) -> (count: int, problem: Problem) {
	return export_rows(catalog, name, {}, rows)
}

// exporters fills the rows of the exports, in each module of the catalog,
// that have a name. The answer to "which modules export this function".
exporters :: proc "contextless" (catalog: Catalog, export: string, rows: []Export) -> (count: int) {
	count, _ = export_rows(catalog, "", {name = export}, rows)
	return count
}

// described fills the rows of the exports, in each module of the catalog,
// whose help or documentation text holds a text: "which modules export a
// function that does this". The comparison is exact, byte by byte.
described :: proc "contextless" (catalog: Catalog, words: string, rows: []Export) -> (count: int) {
	count, _ = export_rows(catalog, "", {words = words}, rows)
	return count
}

// handles fills the rows of the exports, in each module of the catalog,
// that take a handle with a right: in a Handle parameter, or in a Handle
// field of a Record parameter. No export gives a handle: a result has no
// Handle (docs/MODULE_CONTRACT.md, section 4).
handles :: proc "contextless" (catalog: Catalog, right: op.Right, rows: []Export) -> (count: int) {
	count, _ = export_rows(catalog, "", {right = right, by_right = true}, rows)
	return count
}

// What an export must have to be a row.
@(private)
Export_Filter :: struct {
	name:     string,
	words:    string,
	right:    op.Right,
	by_right: bool,
}

@(private)
export_rows :: proc "contextless" (catalog: Catalog, name: string, filter: Export_Filter, rows: []Export) -> (count: int, problem: Problem) {
	if name != "" {
		found: Item
		found, problem = find(catalog, name)
		if problem.kind != .None {
			return 0, problem
		}
		return module_exports(found, filter, rows, 0), {}
	}
	for index := 0; ; index += 1 {
		found := item(catalog, index) or_break
		if check(found.file).kind == .None {
			count = module_exports(found, filter, rows, count)
		}
	}
	return count, {}
}

// module_exports adds the rows of the exports of one module that pass the
// filter, after `count` rows. It gives the new count.
@(private)
module_exports :: proc "contextless" (found: Item, filter: Export_Filter, rows: []Export, count: int) -> int {
	count := count
	file := found.file
	for index in 1 ..< module.count(file, .Exports) {
		function := described_export(file, index) or_continue
		if filter.name != "" && module.string_at(file, function.name_offset, function.name_count) != filter.name {
			continue
		}
		if filter.words != "" && !contains(module.string_at(file, function.about_offset, function.about_count), filter.words) && !contains(module.string_at(file, function.text_offset, function.text_count), filter.words) {
			continue
		}
		rights := rights_of(file, function)
		if filter.by_right && filter.right not_in rights {
			continue
		}
		if count < len(rows) {
			export_row(found, index, function, rights, &rows[count])
		}
		count += 1
	}
	return count
}

// rights_of gives the rights that an export asks of the handles that it
// takes: each Handle parameter, and each Handle field of a Record parameter.
rights_of :: proc "contextless" (file: []u8, function: module.Function) -> (rights: op.Rights) {
	function := function
	for type, number in function.parameters[:min(int(function.parameter_count), module.PARAMETER_CAPACITY)] {
		#partial switch type {
		case .Handle:
			rights += transmute(op.Rights)function.parameter_details[number]
		case .Record:
			described := module.record_type(file, function.parameter_details[number]) or_continue
			for field in 0 ..< described.field_count {
				item := module.field(file, described, field) or_continue
				if item.type == .Handle {
					rights += transmute(op.Rights)item.detail
				}
			}
		}
	}
	return rights
}

@(rodata)
result_names := [module.Type]string {
	.None    = "",
	.Integer = "Integer",
	.Text    = "Text",
	.Record  = "Record",
	.Handle  = "Handle",
	.Table   = "Table",
	.Bytes   = "Bytes",
}

@(private)
export_row :: proc "contextless" (found: Item, index: u32, function: module.Function, rights: op.Rights, row: ^Export) {
	row^ = {}
	file := found.file
	text_put(row.module[:], found.name)
	text_put(row.name[:], module.string_at(file, function.name_offset, function.name_count))
	row.number = i64(index)
	row.parameters = i64(function.parameter_count)
	text_put(row.result[:], result_names[function.result])
	buffer: [256]u8
	writer := system.Writer {
		buffer = buffer[:],
	}
	system.write_rights(&writer, rights, " ")
	text_put(row.rights[:], system.written(&writer))
	system.writer_reset(&writer)
	signature_write(&writer, file, function)
	text_put(row.signature[:], system.written(&writer))
}

// signature_write writes the description of an export as one line:
// "name(parameter: Type, ...) -> Type".
signature_write :: proc "contextless" (writer: ^system.Writer, file: []u8, function: module.Function) {
	function := function
	system.write_part(writer, module.string_at(file, function.name_offset, function.name_count))
	system.write_part(writer, "(")
	for type, parameter in function.parameters[:min(int(function.parameter_count), module.PARAMETER_CAPACITY)] {
		system.write_part(writer, parameter > 0 ? ", " : "")
		system.write_part(writer, module.string_at(file, function.parameter_names[parameter], u32(function.parameter_name_counts[parameter])))
		system.write_part(writer, ": ")
		system.write_parameter_type(writer, file, type, function.parameter_details[parameter], function.parameter_directions[parameter])
	}
	system.write_part(writer, ")")
	if function.result != .None {
		system.write_part(writer, " -> ")
		system.write_type(writer, file, function.result, function.result_detail)
	}
}

// export_text gives the documentation text of an export: bytes of the file,
// with no copy. It is empty when the export has no description.
export_text :: proc "contextless" (file: []u8, index: u32) -> string {
	function, ok := described_export(file, index)
	if !ok {
		return ""
	}
	return module.string_at(file, function.text_offset, function.text_count)
}

// imports fills one row for each import of a module, by name or by hash.
// With the name "", it fills the rows of each module of the catalog that
// has no problem.
imports :: proc "contextless" (catalog: Catalog, name: string, rows: []Import) -> (count: int, problem: Problem) {
	if name != "" {
		found: Item
		found, problem = find(catalog, name)
		if problem.kind != .None {
			return 0, problem
		}
		return module_imports(catalog, found, false, {}, rows, 0), {}
	}
	for index := 0; ; index += 1 {
		found := item(catalog, index) or_break
		if check(found.file).kind == .None {
			count = module_imports(catalog, found, false, {}, rows, count)
		}
	}
	return count, {}
}

// importers fills the rows of the imports, in each module of the catalog,
// that name a hash, or that a replacement of the machine changes to that
// hash: "who imports this module". A module that imports it two times has
// two rows. The field `replacement` of a row says which imports a
// replacement gives.
importers :: proc "contextless" (catalog: Catalog, hash: [32]u8, rows: []Import) -> (count: int) {
	for index := 0; ; index += 1 {
		found := item(catalog, index) or_break
		if check(found.file).kind == .None {
			count = module_imports(catalog, found, true, hash, rows, count)
		}
	}
	return count
}

@(private)
module_imports :: proc "contextless" (catalog: Catalog, found: Item, by_hash: bool, hash: [32]u8, rows: []Import, count: int) -> int {
	count := count
	file := found.file
	for index in 1 ..< module.count(file, .Imports) {
		imported, _ := module.record(file, .Imports, index, module.Import)
		replaced, has_replacement := replacement_of(catalog, imported.hash)
		if by_hash && imported.hash != hash && !(has_replacement && replaced == hash) {
			continue
		}
		if count < len(rows) {
			row := &rows[count]
			row^ = {number = i64(index)}
			text_put(row.module[:], found.name)
			hash_text(imported.hash, &row.hash)
			if target, known := find_hash(catalog, imported.hash); known {
				text_put(row.name[:], target.name)
			}
			if has_replacement {
				text_put(row.replacement[:], name_of_hash(catalog, replaced))
			}
			for slot_index in 1 ..< module.count(file, .Slots) {
				slot, _ := module.record(file, .Slots, slot_index, module.Slot)
				row.slots += i64(slot.import_index == index)
			}
		}
		count += 1
	}
	return count
}

// slots fills one row for each slot of a module, by name or by hash: the
// export of an import that the slot receives. The name of the export comes
// from the imported module, when the catalog has it.
slots :: proc "contextless" (catalog: Catalog, name: string, rows: []Slot) -> (count: int, problem: Problem) {
	found: Item
	found, problem = find(catalog, name)
	if problem.kind != .None {
		return 0, problem
	}
	file := found.file
	for index in 1 ..< module.count(file, .Slots) {
		slot, _ := module.record(file, .Slots, index, module.Slot)
		if count < len(rows) {
			row := &rows[count]
			row^ = {number = i64(index), import_index = i64(slot.import_index), export_index = i64(slot.export_index)}
			text_put(row.module[:], found.name)
			imported, _ := module.record(file, .Imports, slot.import_index, module.Import)
			if target, known := find_hash(catalog, imported.hash); known && check(target.file).kind == .None {
				text_put(row.target[:], target.name)
				if function, described := module.function(target.file, slot.export_index); described {
					text_put(row.name[:], module.string_at(target.file, function.name_offset, function.name_count))
				}
			}
		}
		count += 1
	}
	return count, {}
}

@(rodata)
segment_kinds := [4]string{"code", "constants", "constants after load", "data"}

// segments fills one row for each segment of a module, by name or by hash.
segments :: proc "contextless" (catalog: Catalog, name: string, rows: []Segment) -> (count: int, problem: Problem) {
	found: Item
	found, problem = find(catalog, name)
	if problem.kind != .None {
		return 0, problem
	}
	file := found.file
	for index in 1 ..< module.count(file, .Segments) {
		segment, _ := module.record(file, .Segments, index, module.Segment)
		if count < len(rows) {
			row := &rows[count]
			row^ = {number = i64(index), memory_offset = i64(segment.memory_offset), memory_size = i64(segment.memory_size), file_offset = i64(segment.file_offset), file_size = i64(segment.file_size)}
			text_put(row.module[:], found.name)
			kind := 3
			switch {
			case .Execute in segment.flags:
				kind = 0
			case .Read_Only_After_Load in segment.flags:
				kind = 2
			case .Write not_in segment.flags:
				kind = 1
			}
			text_put(row.kind[:], segment_kinds[kind])
		}
		count += 1
	}
	return count, {}
}

// running fills one row for each module that runs in a program: the
// module records that each loader gave to the kernel (operation
// Program_Module), with the hash that a replacement changed. The kernel
// gives them to a holder of the machine with the right Inspect: a program
// sees what runs only with that grant, because a program sees no other
// program. The kernel has the
// records of each program, also of programs that the root service did not
// start. problem: Refused, with the status of the kernel.
running :: proc "contextless" (machine: system.Handle, catalog: Catalog, rows: []Running) -> (count: int, problem: Problem) {
	report: op.System_Report
	if _, status := system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.System), 0, u64(uintptr(&report)), size_of(report)); status != .Ok {
		return 0, {kind = .Refused, value = u64(status)}
	}
	for slot in 1 ..< report.program_slots {
		program: op.Program_Report
		system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.Program), slot, u64(uintptr(&program)), size_of(program))
		if program.state == .None || program.state == .Stopped {
			continue
		}
		modules: op.Module_Report
		if _, status := system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.Modules), slot, u64(uintptr(&modules)), size_of(modules)); status != .Ok {
			return count, {kind = .Refused, value = u64(status)}
		}
		for record in modules.modules[:min(modules.count, op.PROGRAM_MODULE_CAPACITY)] {
			if count < len(rows) {
				row := &rows[count]
				row^ = {slot = i64(slot), base = i64(record.base), size = i64(record.size)}
				text_put(row.program[:], system.name_of(program.name[:]))
				if found, known := find_hash(catalog, record.hash); known {
					text_put(row.module[:], found.name)
				}
				hash_text(record.hash, &row.hash)
				if record.replaces != {} {
					hash_text(record.replaces, &row.replaces)
				}
			}
			count += 1
		}
	}
	return count, {}
}

// replacements fills one row for each record of the replacement table of
// the catalog: where an import names `from`, a loader gives `to`.
replacements :: proc "contextless" (catalog: Catalog, rows: []Replacement) -> (count: int) {
	for item in catalog.replacements {
		if count < len(rows) {
			row := &rows[count]
			row^ = {}
			text_put(row.from[:], name_of_hash(catalog, item.from))
			hash_text(item.from, &row.from_hash)
			text_put(row.to[:], name_of_hash(catalog, item.to))
			hash_text(item.to, &row.to_hash)
		}
		count += 1
	}
	return count
}

// name_of_hash gives the name of a module of the catalog, or "" when the
// catalog has no module with this hash.
name_of_hash :: proc "contextless" (catalog: Catalog, hash: [32]u8) -> string {
	found, known := find_hash(catalog, hash)
	return known ? found.name : ""
}

// contains says if a text holds another text.
contains :: proc "contextless" (text, part: string) -> bool {
	if len(part) > len(text) {
		return false
	}
	for start in 0 ..= len(text) - len(part) {
		if text[start:][:len(part)] == part {
			return true
		}
	}
	return false
}