#+build !freestanding
package information

import "contract:blake3"
import info "contract:boot_info"
import module "contract:module"
import op "contract:operation"
import "core:math/rand"
import "core:testing"

// A module file that the test writes: two segments, a record, three
// exports (an entry, one with a Record of a handle, one with a Table
// result), and with `imported` one import with one slot.
@(private = "file")
Builder :: struct {
	bytes:   [dynamic]u8,
	strings: [dynamic]u8,
}

@(private = "file")
text :: proc(builder: ^Builder, value: string) -> (offset, count: u32) {
	offset = u32(len(builder.strings))
	append(&builder.strings, value)
	return offset, u32(len(value))
}

@(private = "file")
module_file :: proc(about: string, imported: [32]u8, has_import: bool) -> []u8 {
	builder: Builder
	builder.bytes = make([dynamic]u8, context.temp_allocator)
	builder.strings = make([dynamic]u8, context.temp_allocator)
	append(&builder.strings, 0)
	segments := [3]module.Segment{1 = {file_offset = 0, file_size = 100, memory_offset = 0, memory_size = 4096, flags = {.Read, .Execute}}, 2 = {file_offset = 0, file_size = 40, memory_offset = 4096, memory_size = 8192, flags = {.Read, .Write}}}
	records := [2]module.Record{}
	records[1].name_offset, records[1].name_count = text(&builder, "Span")
	records[1].size, records[1].first_field, records[1].field_count = 16, 1, 2
	fields := [3]module.Field{}
	fields[1].name_offset, fields[1].name_count = text(&builder, "memory")
	fields[1].type, fields[1].detail = .Handle, transmute(u32)op.Rights{.Read, .Write}
	fields[2].name_offset, fields[2].name_count = text(&builder, "count")
	fields[2].offset, fields[2].type = 8, .Integer
	functions := [4]module.Function{}
	functions[1].name_offset, functions[1].name_count = text(&builder, "entry")
	functions[2].name_offset, functions[2].name_count = text(&builder, "fill")
	functions[2].about_offset, functions[2].about_count = text(&builder, "fills the memory of a span")
	functions[2].text_offset, functions[2].text_count = text(&builder, "fill fills the memory of a span. It writes each byte.")
	functions[2].parameter_count, functions[2].parameters[0], functions[2].parameter_details[0], functions[2].result = 1, .Record, 1, .Integer
	functions[2].parameter_names[0], _ = text(&builder, "span")
	functions[2].parameter_name_counts[0] = 4
	functions[3].name_offset, functions[3].name_count = text(&builder, "rows")
	functions[3].about_offset, functions[3].about_count = text(&builder, "gives rows")
	functions[3].result, functions[3].result_detail = .Integer, 0
	exports := [4]module.Export{1 = {code_offset = 0, function = 1}, 2 = {code_offset = 16, function = 2}, 3 = {code_offset = 32, function = 3}}
	documentation := [2]module.Documentation{}
	documentation[1].about_offset, documentation[1].about_count = text(&builder, about)
	imports := [2]module.Import{1 = {hash = imported}}
	slots := [2]module.Slot{1 = {memory_offset = 4096, import_index = 1, export_index = 2}}

	Directory :: [module.TABLE_COUNT]module.Table_Entry
	directory: Directory
	resize(&builder.bytes, size_of(module.Header) + size_of(Directory))
	add :: proc(builder: ^Builder, directory: ^Directory, kind: module.Table_Kind, records: []$T) {
		directory[kind] = {offset = u64(len(builder.bytes)), count = u32(len(records)), record_size = size_of(T)}
		append(&builder.bytes, ..([^]u8)(raw_data(records))[:len(records) * size_of(T)])
	}
	add(&builder, &directory, .Segments, segments[:])
	add(&builder, &directory, .Exports, exports[:])
	add(&builder, &directory, .Functions, functions[:])
	add(&builder, &directory, .Records, records[:])
	add(&builder, &directory, .Fields, fields[:])
	add(&builder, &directory, .Documentation, documentation[:])
	if has_import {
		add(&builder, &directory, .Imports, imports[:])
		add(&builder, &directory, .Slots, slots[:])
	}
	add(&builder, &directory, .Strings, builder.strings[:])
	head := module.Header {
		magic        = module.MAGIC,
		version      = module.VERSION,
		header_size  = size_of(module.Header),
		machine      = .X86_64,
		table_count  = module.TABLE_COUNT,
		memory_size  = 3 * 4096,
		entry_export = 1,
	}
	copy(builder.bytes[:], ([^]u8)(&head)[:size_of(head)])
	copy(builder.bytes[size_of(head):], ([^]u8)(&directory)[:size_of(directory)])
	return builder.bytes[:]
}

// A boot image with the files, in the order of the names.
@(private = "file")
image_of :: proc(names: []string, files: [][]u8) -> []u8 {
	image := make([dynamic]u8, context.temp_allocator)
	resize(&image, size_of(info.Image_Header) + len(files) * size_of(info.Image_Entry))
	header := info.Image_Header{magic = info.IMAGE_MAGIC, count = u32(len(files))}
	copy(image[:], ([^]u8)(&header)[:size_of(header)])
	for file, index in files {
		resize(&image, (len(image) + 4095) &~ 4095)
		entry := info.Image_Entry{hash = blake3.hash(file), offset = u64(len(image)), size = u64(len(file))}
		copy(entry.name[:], names[index])
		copy(image[size_of(info.Image_Header) + index * size_of(info.Image_Entry):], ([^]u8)(&entry)[:size_of(entry)])
		append(&image, ..file)
	}
	return image[:]
}

@(private = "file")
field :: proc(bytes: []u8) -> string {
	count := 0
	for count < len(bytes) && bytes[count] != 0 {
		count += 1
	}
	return string(bytes[:count])
}

@(test)
rows_of_a_catalog :: proc(t: ^testing.T) {
	library := module_file("a library", {}, false)
	user := module_file("a user of the library", blake3.hash(library), true)
	catalog := Catalog{image = image_of({"library", "user"}, {library, user})}

	rows: [4]Module
	testing.expect_value(t, modules(catalog, rows[:1]), 2) // The count is the full count.
	testing.expect_value(t, modules(catalog, rows[:]), 2)
	testing.expect_value(t, field(rows[0].name[:]), "library")
	testing.expect_value(t, rows[0].code, 4096)
	testing.expect_value(t, rows[0].data, 40)
	testing.expect_value(t, rows[0].zero, 8192 - 40)
	testing.expect_value(t, rows[0].entry, 1)
	testing.expect_value(t, rows[0].exports, 2)
	testing.expect_value(t, rows[0].imports, 0)
	testing.expect_value(t, rows[1].imports, 1)
	testing.expect_value(t, rows[0].records, 1)
	testing.expect_value(t, field(rows[0].problem[:]), "")
	hash, parsed := hash_parse(string(rows[0].hash[:]))
	testing.expect(t, parsed && hash == blake3.hash(library), "the hash of a row is the hash of the file")

	export_rows: [8]Export
	count, problem := exports(catalog, "library", export_rows[:])
	testing.expect_value(t, problem.kind, Problem_Kind.None)
	testing.expect_value(t, count, 2)
	testing.expect_value(t, field(export_rows[0].signature[:]), "fill(span: Span) -> Integer")
	testing.expect_value(t, field(export_rows[0].rights[:]), "Read Write")
	testing.expect_value(t, export_rows[0].number, 2)
	count, _ = exports(catalog, "", export_rows[:])
	testing.expect_value(t, count, 4)
	_, problem = exports(catalog, "nothing", export_rows[:])
	testing.expect_value(t, problem.kind, Problem_Kind.No_Module)
	testing.expect_value(t, exporters(catalog, "rows", export_rows[:]), 2)
	testing.expect_value(t, described(catalog, "each byte", export_rows[:]), 2)
	testing.expect_value(t, handles(catalog, .Write, export_rows[:]), 2)
	testing.expect_value(t, handles(catalog, .Control, export_rows[:]), 0)

	import_rows: [4]Import
	testing.expect_value(t, importers(catalog, blake3.hash(library), import_rows[:]), 1)
	testing.expect_value(t, field(import_rows[0].module[:]), "user")
	testing.expect_value(t, field(import_rows[0].name[:]), "library")
	testing.expect_value(t, import_rows[0].slots, 1)
	testing.expect_value(t, importers(catalog, blake3.hash(user), import_rows[:]), 0)
	// A module by its hash: 64 digits.
	count, problem = imports(catalog, string(rows[1].hash[:]), import_rows[:])
	testing.expect(t, count == 1 && problem.kind == .None)

	slot_rows: [2]Slot
	count, _ = slots(catalog, "user", slot_rows[:])
	testing.expect_value(t, count, 1)
	testing.expect_value(t, field(slot_rows[0].target[:]), "library")
	testing.expect_value(t, field(slot_rows[0].name[:]), "fill")
	segment_rows: [4]Segment
	count, _ = segments(catalog, "user", segment_rows[:])
	testing.expect_value(t, count, 2)
	testing.expect_value(t, field(segment_rows[0].kind[:]), "code")
	testing.expect_value(t, field(segment_rows[1].kind[:]), "data")
}

// A replacement of the machine: where user imports library, a loader
// gives fixed. The import keeps the hash that the file names, and says the
// replacement; who imports fixed: user, through the replacement.
@(test)
rows_with_a_replacement :: proc(t: ^testing.T) {
	library := module_file("a library", {}, false)
	fixed := module_file("a library with a correction", {}, false)
	user := module_file("a user of the library", blake3.hash(library), true)
	table := [1]module.Replacement{{from = blake3.hash(library), to = blake3.hash(fixed)}}
	catalog := Catalog{image_of({"library", "fixed", "user"}, {library, fixed, user}), table[:]}

	import_rows: [4]Import
	count, problem := imports(catalog, "user", import_rows[:])
	testing.expect(t, count == 1 && problem.kind == .None)
	testing.expect_value(t, field(import_rows[0].name[:]), "library")
	testing.expect_value(t, field(import_rows[0].replacement[:]), "fixed")
	testing.expect_value(t, importers(catalog, blake3.hash(fixed), import_rows[:]), 1)
	testing.expect_value(t, field(import_rows[0].module[:]), "user")
	testing.expect_value(t, importers(catalog, blake3.hash(library), import_rows[:]), 1)

	replacement_rows: [2]Replacement
	testing.expect_value(t, replacements(catalog, replacement_rows[:]), 1)
	testing.expect_value(t, field(replacement_rows[0].from[:]), "library")
	testing.expect_value(t, field(replacement_rows[0].to[:]), "fixed")
}

// The edges of the programs that run, from module records as a loader
// writes them: a program whose module imports library directly; a program
// where a replacement gave fixed in place of library; a program that holds
// library by its name and fixed through the replacement; and a record of a
// module that the catalog does not have.
@(test)
edges_of_a_program :: proc(t: ^testing.T) {
	library := module_file("a library", {}, false)
	fixed := module_file("a library with a correction", {}, false)
	user := module_file("a user of the library", blake3.hash(library), true)
	catalog := Catalog{image = image_of({"library", "fixed", "user"}, {library, fixed, user})}

	// No replacement: user is the module of the program, library its import.
	direct := [2]op.Module_Record{{size = 4096, hash = blake3.hash(user)}, {size = 4096, hash = blake3.hash(library)}}
	rows: [8]Edge
	count := program_edges(catalog, "user", 3, direct[:], rows[:], 0)
	testing.expect_value(t, count, 2)
	testing.expect_value(t, field(rows[0].program[:]), "user")
	testing.expect_value(t, rows[0].slot, 3)
	testing.expect_value(t, field(rows[0].module[:]), "user")
	testing.expect_value(t, field(rows[0].imported_by[:]), "")
	testing.expect_value(t, field(rows[1].module[:]), "library")
	testing.expect_value(t, field(rows[1].imported_by[:]), "user")
	testing.expect_value(t, field(rows[1].replaces[:]), "")
	hash, parsed := hash_parse(string(rows[1].hash[:]))
	testing.expect(t, parsed && hash == blake3.hash(library), "the hash of an edge is the hash of the module that runs")

	// A replacement: fixed runs in place of library, and user imports it.
	replaced := [2]op.Module_Record{{size = 4096, hash = blake3.hash(user)}, {size = 4096, hash = blake3.hash(fixed), replaces = blake3.hash(library)}}
	count = program_edges(catalog, "user", 4, replaced[:], rows[:], 0)
	testing.expect_value(t, count, 2)
	testing.expect_value(t, field(rows[1].module[:]), "fixed")
	testing.expect_value(t, field(rows[1].imported_by[:]), "user")
	testing.expect_value(t, field(rows[1].replaces[:]), "library")

	// library loaded by its name next to its replacement: the import of user
	// goes to fixed, and library has no importer.
	both := [3]op.Module_Record{{size = 4096, hash = blake3.hash(user)}, {size = 4096, hash = blake3.hash(fixed), replaces = blake3.hash(library)}, {size = 4096, hash = blake3.hash(library)}}
	count = program_edges(catalog, "console", 5, both[:], rows[:], 0)
	testing.expect_value(t, count, 3)
	testing.expect_value(t, field(rows[1].module[:]), "fixed")
	testing.expect_value(t, field(rows[1].imported_by[:]), "user")
	testing.expect_value(t, field(rows[2].module[:]), "library")
	testing.expect_value(t, field(rows[2].imported_by[:]), "")

	// A module that the catalog does not have is named by its hash; a
	// record of size 0 is no module. The count is the full count.
	unknown_hash := blake3.hash(transmute([]u8)string("a module of no catalog"))
	unknown := [2]op.Module_Record{{size = 4096, hash = unknown_hash}, {}}
	count = program_edges(catalog, "stranger", 6, unknown[:], rows[:1], 0)
	testing.expect_value(t, count, 1)
	digits: [64]u8
	hash_text(unknown_hash, &digits)
	testing.expect_value(t, field(rows[0].module[:]), string(digits[:16]))
	testing.expect_value(t, program_edges(catalog, "user", 3, direct[:], rows[:0], 0), 2)
}

// A malformed module gives a problem with its place: the table, the
// record, and the byte of the file. No function faults on it.
@(test)
malformed_modules :: proc(t: ^testing.T) {
	good := module_file("a module", {}, false)
	Case :: struct {
		about:  string,
		change: proc(file: []u8),
		kind:   Problem_Kind,
		table:  module.Table_Kind,
		index:  u32,
	}
	directory :: proc(file: []u8, kind: module.Table_Kind) -> ^module.Table_Entry {
		return (^module.Table_Entry)(&file[size_of(module.Header) + int(kind) * size_of(module.Table_Entry)])
	}
	record :: proc(file: []u8, kind: module.Table_Kind, index: int, $T: typeid) -> ^T {
		return (^T)(&file[int(directory(file, kind).offset) + index * size_of(T)])
	}
	cases := [?]Case {
		{"a bad magic number", proc(file: []u8) {file[0] = 'X'}, .Header, .None, 0},
		{"a table out of the file", proc(file: []u8) {directory(file, .Functions).count = 1000}, .Table, .None, u32(module.Table_Kind.Functions)},
		{"a segment larger than the module", proc(file: []u8) {record(file, .Segments, 2, module.Segment).memory_size = 64 * 4096}, .Segment, .Segments, 2},
		{"a segment that executes and that the loader writes", proc(file: []u8) {record(file, .Segments, 1, module.Segment).flags += {.Write}}, .Segment, .Segments, 1},
		{"an export with no description", proc(file: []u8) {record(file, .Exports, 2, module.Export).function = 9}, .Export, .Exports, 2},
		{"a name out of the string table", proc(file: []u8) {record(file, .Functions, 2, module.Function).name_offset = 60000}, .Text, .Functions, 2},
		{"seven parameters", proc(file: []u8) {record(file, .Functions, 2, module.Function).parameter_count = 7}, .Function, .Functions, 2},
		{"a type that does not exist", proc(file: []u8) {record(file, .Functions, 2, module.Function).parameters[0] = module.Type(9)}, .Function, .Functions, 2},
		{"a parameter that names no record", proc(file: []u8) {record(file, .Functions, 2, module.Function).parameter_details[0] = 5}, .Function, .Functions, 2},
		{"a field out of its record", proc(file: []u8) {record(file, .Fields, 2, module.Field).offset = 12}, .Record, .Fields, 2},
		{"a record of 300 bytes", proc(file: []u8) {record(file, .Records, 1, module.Record).size = 300}, .Record, .Records, 1},
		{"an entry that names no export", proc(file: []u8) {(^module.Header)(&file[0]).entry_export = 7}, .Entry, .None, 0},
	}
	scratch := make([]u8, len(good), context.temp_allocator)
	for item in cases {
		copy(scratch, good)
		item.change(scratch)
		problem := check(scratch)
		testing.expectf(t, problem.kind == item.kind && problem.table == item.table && problem.index == item.index, "%s: %v", item.about, problem)
		catalog := Catalog{image = image_of({"bad"}, {scratch})}
		rows: [2]Module
		testing.expect_value(t, modules(catalog, rows[:]), 1)
		testing.expectf(t, field(rows[0].problem[:]) == problem_names[item.kind] && rows[0].offset == i64(problem.offset), "%s: the row has the problem", item.about)
		export_rows: [4]Export
		count, found := exports(catalog, "bad", export_rows[:])
		testing.expectf(t, count == 0 && found == problem, "%s: exports gives the problem", item.about)
	}
	// The place in the file: the name of export 2 is at the start of its record.
	copy(scratch, good)
	record(scratch, .Functions, 2, module.Function).name_offset = 60000
	problem := check(scratch)
	testing.expect_value(t, problem.offset, directory(scratch, .Functions).offset + 2 * size_of(module.Function))
}

// Random bytes in a module file: each function gives an answer, and no
// read leaves the file. The test build checks each index.
@(test)
random_damage :: proc(t: ^testing.T) {
	library := module_file("a library", {}, false)
	user := module_file("a user", blake3.hash(library), true)
	image := image_of({"library", "user"}, {library, user})
	work := make([]u8, len(image), context.temp_allocator)
	entry := (^info.Image_Entry)(&image[size_of(info.Image_Header) + size_of(info.Image_Entry)])
	damaged := work[entry.offset:][:entry.size]
	catalog := Catalog{image = work}
	records := [2]op.Module_Record{{size = 4096, hash = blake3.hash(user)}, {size = 4096, hash = blake3.hash(library)}}
	problems := 0
	for _ in 0 ..< 20_000 {
		copy(work, image)
		for _ in 0 ..< 1 + rand.int_max(4) {
			damaged[rand.int_max(len(damaged))] = u8(rand.int_max(256))
		}
		module_rows: [4]Module
		export_rows: [8]Export
		import_rows: [4]Import
		slot_rows: [4]Slot
		segment_rows: [4]Segment
		modules(catalog, module_rows[:])
		exports(catalog, "user", export_rows[:])
		exports(catalog, "", export_rows[:])
		imports(catalog, "", import_rows[:])
		importers(catalog, blake3.hash(library), import_rows[:])
		slots(catalog, "user", slot_rows[:])
		segments(catalog, "user", segment_rows[:])
		described(catalog, "byte", export_rows[:])
		handles(catalog, .Read, export_rows[:])
		edge_rows: [4]Edge
		program_edges(catalog, "user", 1, records[:], edge_rows[:], 0)
		problems += int(check(damaged).kind != .None)
	}
	testing.expect(t, problems > 1000, "the damage must break rules often")
}