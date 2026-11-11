package module

import "base:intrinsics"

Error :: enum u32 {
	None            = 0,
	Too_Small       = 1,
	Bad_Magic       = 2,
	Unknown_Version = 3,
	Unknown_Feature = 4,
	Unknown_Machine = 5,
	Bad_Table       = 6,
	Bad_Segment     = 7,
	Bad_Rebase      = 8,
	Bad_Slot        = 9,
	Bad_Import      = 10,
	Bad_Export      = 11,
}

// read copies a T from file at offset. It gives zero when the range is not in file.
@(private)
read :: proc "contextless" (file: []u8, offset: u64, $T: typeid, size := u64(size_of(T))) -> (value: T, ok: bool) {
	count := min(size, size_of(T))
	if offset > u64(len(file)) || count > u64(len(file)) - offset {
		return {}, false
	}
	intrinsics.mem_copy_non_overlapping(&value, raw_data(file[offset:]), int(count))
	return value, true
}

header :: proc "contextless" (file: []u8) -> (value: Header, error: Error) {
	ok: bool
	value, ok = read(file, 0, Header)
	switch {
	case !ok:
		return {}, .Too_Small
	case value.magic != MAGIC:
		return {}, .Bad_Magic
	case value.version != VERSION:
		return {}, .Unknown_Version
	case value.must_understand & ~UNDERSTOOD_FEATURES != 0:
		return {}, .Unknown_Feature
	case value.machine != .X86_64:
		return {}, .Unknown_Machine
	}
	return value, .None
}

// table gives the directory entry of a table. A table that the file does not
// have is empty.
table :: proc "contextless" (file: []u8, kind: Table_Kind) -> Table_Entry {
	head, error := header(file)
	if error != .None || u32(kind) >= head.table_count {
		return {}
	}
	entry, _ := read(file, u64(head.header_size) + u64(kind) * size_of(Table_Entry), Table_Entry)
	return entry
}

count :: proc "contextless" (file: []u8, kind: Table_Kind) -> u32 {
	return table(file, kind).count
}

// record gives record index of a table. It gives the zero record when the
// table does not have this index.
record :: proc "contextless" (file: []u8, kind: Table_Kind, index: u32, $T: typeid) -> (value: T, ok: bool) {
	entry := table(file, kind)
	if index >= entry.count {
		return {}, false
	}
	return read(file, entry.offset + u64(index) * u64(entry.record_size), T, u64(entry.record_size))
}

// validate checks all that a loader relies on before it maps a module:
// the header, the range of each table, and the range of each segment.
validate :: proc "contextless" (file: []u8) -> Error {
	head, error := header(file)
	if error != .None {
		return error
	}
	if head.memory_size % PAGE_SIZE != 0 {
		return .Bad_Segment
	}
	for kind in Table_Kind {
		entry := table(file, kind)
		size := u64(entry.count) * u64(entry.record_size)
		if entry.offset > u64(len(file)) || size > u64(len(file)) - entry.offset {
			return .Bad_Table
		}
	}
	if table(file, .Rebases).count != 0 && table(file, .Rebases).record_size != REBASE_WORD_SIZE {
		return .Bad_Table
	}
	for index in 1 ..< count(file, .Segments) {
		segment, _ := record(file, .Segments, index, Segment)
		switch {
		case segment.memory_offset % PAGE_SIZE != 0 || segment.memory_size % PAGE_SIZE != 0:
			return .Bad_Segment
		case segment.memory_offset > head.memory_size || segment.memory_size > head.memory_size - segment.memory_offset:
			return .Bad_Segment
		case segment.file_size > segment.memory_size:
			return .Bad_Segment
		case segment.file_offset > u64(len(file)) || segment.file_size > u64(len(file)) - segment.file_offset:
			return .Bad_Segment
		case .Execute in segment.flags && segment.flags & {.Write, .Read_Only_After_Load} != {}:
			return .Bad_Segment // The loader never writes to code.
		}
	}
	if head.entry_export >= max(count(file, .Exports), 1) {
		return .Bad_Export
	}
	return .None
}

// copy_segments copies the data of each segment into memory. The caller gives
// memory that is zero, of Header.memory_size bytes, and calls validate first.
copy_segments :: proc "contextless" (file: []u8, memory: []u8) {
	for index in 1 ..< count(file, .Segments) {
		segment, _ := record(file, .Segments, index, Segment)
		intrinsics.mem_copy_non_overlapping(
			raw_data(memory[segment.memory_offset:]),
			raw_data(file[segment.file_offset:]),
			int(segment.file_size),
		)
	}
}

// writable says if the loader can write 8 bytes at memory_offset: the
// location is in a segment that has Write and not Execute.
@(private)
writable :: proc "contextless" (file: []u8, memory_offset: u64) -> bool {
	for index in 1 ..< count(file, .Segments) {
		segment, _ := record(file, .Segments, index, Segment)
		if memory_offset >= segment.memory_offset && memory_offset - segment.memory_offset + 8 <= segment.memory_size {
			return .Write in segment.flags && .Execute not_in segment.flags
		}
	}
	return false
}

// rebase adds base to each location of the rebase table. base is the address
// where the module runs. It differs from the address of memory when a loader
// prepares a module for another address space.
rebase :: proc "contextless" (file: []u8, memory: []u8, load_address: uintptr) -> Error {
	return rebase_range(file, memory, load_address, 0, u64(len(memory)))
}

// rebase_range does the work of rebase for the locations from offset first
// to offset end only: a loader that writes one segment at a time rebases
// each one alone. It checks each location of the table.
rebase_range :: proc "contextless" (file: []u8, memory: []u8, load_address: uintptr, first, end: u64) -> Error {
	base := u64(load_address)
	cursor: u64
	for index in 0 ..< count(file, .Rebases) {
		word, _ := record(file, .Rebases, index, u64)
		if word & 1 == 0 {
			rebase_location(file, memory, word, base, first, end) or_return
			cursor = word + 8
			continue
		}
		for bit in u64(1) ..= REBASE_BITMAP_LOCATIONS {
			if word >> bit & 1 != 0 {
				rebase_location(file, memory, cursor + 8 * (bit - 1), base, first, end) or_return
			}
		}
		cursor += 8 * REBASE_BITMAP_LOCATIONS
	}
	return .None
}

@(private)
rebase_location :: proc "contextless" (file: []u8, memory: []u8, memory_offset: u64, base: u64, first, end: u64) -> Error {
	if !writable(file, memory_offset) {
		return .Bad_Rebase
	}
	if memory_offset < first || memory_offset >= end {
		return .None
	}
	location := (^u64)(raw_data(memory[memory_offset:]))
	intrinsics.unaligned_store(location, intrinsics.unaligned_load(location) + base)
	return .None
}

// export_address gives the address of an export of a module that is loaded at base.
export_address :: proc "contextless" (file: []u8, base: uintptr, export_index: u32) -> (address: uintptr, ok: bool) {
	if export_index == 0 {
		return 0, false
	}
	export := record(file, .Exports, export_index, Export) or_return
	head, _ := header(file)
	if export.code_offset >= head.memory_size {
		return 0, false
	}
	return base + uintptr(export.code_offset), true
}

// An import as a loader resolved it: the module that is loaded for it, and
// where. When a replacement applies, `named` is the file of the module that
// the import names: a slot names an export by its index in that file.
Bound_Import :: struct {
	file:  []u8,
	base:  uintptr,
	named: []u8, // nil: `file` is the module that the import names.
}

// A replacement: where a module imports the module `from`, the loader loads
// the module `to` (docs/MODULE_CONTRACT.md, "Replacement of an import").
Replacement :: struct {
	from: [HASH_SIZE]u8,
	to:   [HASH_SIZE]u8,
}
#assert(size_of(Replacement) == 64)

// bind writes, in each slot, the address of its export. imports gives each
// import, in the order of the import table: its index 0 is import 1.
// A replaced import binds by name, one time: the loader finds in the
// replacement the export with the name of the export of the slot, and the
// two descriptions must be equal. If not, or if a slot is not valid, bind
// fills the stage, the export, the slot and the difference of error, and
// the module must not run. The loader fills the modules of the record.
// It checks each slot, and writes the slots from offset first to offset end
// only: a loader that writes one segment at a time binds each one alone.
bind :: proc "contextless" (file: []u8, memory: []u8, imports: []Bound_Import, error: ^Load_Error, first: u64 = 0, end: u64 = max(u64)) -> bool {
	count_of_imports := count(file, .Imports)
	if count_of_imports > 1 && len(imports) != int(count_of_imports) - 1 {
		error.stage = .Bind
		return false
	}
	for index in 1 ..< count(file, .Slots) {
		slot, _ := record(file, .Slots, index, Slot)
		error.slot = index
		if slot.import_index == 0 || slot.import_index >= count_of_imports || !writable(file, slot.memory_offset) {
			error.stage = .Bind
			return false
		}
		item := imports[slot.import_index - 1]
		named_file := item.named != nil ? item.named : item.file
		if named, has_function := function(named_file, slot.export_index); has_function {
			name_set(&error.export, string_at(named_file, named.name_offset, named.name_count))
		} else {
			error.export = {}
		}
		export_index := slot.export_index
		if item.named != nil {
			export_index = export_find(item.file, name_get(&error.export))
			if error.export == {} {
				error.stage = .Bind
				return false
			}
			if export_index == 0 {
				error.stage, error.difference = .Check, .Missing_Export
				return false
			}
			error.difference, error.parameter, error.expected, error.found = functions_compare(item.named, slot.export_index, item.file, export_index)
			if error.difference != .None {
				error.stage = .Check
				return false
			}
		}
		address, ok := export_address(item.file, item.base, export_index)
		if !ok {
			error.stage = .Bind
			return false
		}
		if slot.memory_offset >= first && slot.memory_offset < end {
			intrinsics.unaligned_store((^u64)(raw_data(memory[slot.memory_offset:])), u64(address))
		}
	}
	error.slot, error.export = 0, {}
	return true
}

// export_find gives the index of the export with a name. 0: no export has it.
export_find :: proc "contextless" (file: []u8, name: string) -> u32 {
	for index in 1 ..< count(file, .Exports) {
		if value, ok := function(file, index); ok && string_at(file, value.name_offset, value.name_count) == name {
			return index
		}
	}
	return 0
}

// string_at gives bytes of the string table. Call validate first.
string_at :: proc "contextless" (file: []u8, offset, count: u32) -> string {
	entry := table(file, .Strings)
	if offset > entry.count || count > entry.count - offset {
		return ""
	}
	return string(file[entry.offset + u64(offset):][:count])
}

// function gives the description of an export.
function :: proc "contextless" (file: []u8, export_index: u32) -> (value: Function, ok: bool) {
	if export_index == 0 {
		return {}, false
	}
	export := record(file, .Exports, export_index, Export) or_return
	return record(file, .Functions, export.function, Function)
}

// record_type gives the description of a record, by its index in the
// record table, after it checked the description: the size is in the
// limit, and each field is of a known type and inside the record.
record_type :: proc "contextless" (file: []u8, index: u32) -> (value: Record, ok: bool) {
	if index == 0 {
		return {}, false
	}
	value = record(file, .Records, index, Record) or_return
	if value.size > RECORD_SIZE_LIMIT || value.field_count > RECORD_SIZE_LIMIT / 4 {
		return {}, false
	}
	for number in 0 ..< value.field_count {
		item := field(file, value, number) or_return
		size := field_size(item.type, item.detail)
		if size == 0 || item.offset > value.size || size > value.size - item.offset {
			return {}, false
		}
		if item.type == .Integer && item.offset % size != 0 {
			return {}, false
		}
	}
	// The size is a multiple of the alignment: a record that follows
	// another in a table keeps the alignment of its fields (N1 of the
	// hostile read).
	if value.size % record_alignment(file, value) != 0 {
		return {}, false
	}
	return value, true
}

// record_has_handle says if a record has a Handle field: a record of a
// table, and a record of a result, has none.
record_has_handle :: proc "contextless" (file: []u8, of: Record) -> bool {
	for number in 0 ..< of.field_count {
		if item, ok := field(file, of, number); ok && item.type == .Handle {
			return true
		}
	}
	return false
}

// record_alignment gives the alignment of a record: the largest size of
// its Integer and Handle fields, at least 1.
record_alignment :: proc "contextless" (file: []u8, of: Record) -> (alignment: u32) {
	alignment = 1
	for number in 0 ..< of.field_count {
		if item, ok := field(file, of, number); ok && item.type != .Text {
			alignment = max(alignment, field_size(item.type, item.detail))
		}
	}
	return alignment
}

// records_equal says if two descriptions of a record are equal: the same
// name, the same size, and the same fields at the same places. The two
// records can be in two modules: a record has no identity but its
// description.
records_equal :: proc "contextless" (file: []u8, index: u32, other_file: []u8, other_index: u32) -> bool {
	first := record_type(file, index) or_return
	second := record_type(other_file, other_index) or_return
	if first.size != second.size || first.field_count != second.field_count || string_at(file, first.name_offset, first.name_count) != string_at(other_file, second.name_offset, second.name_count) {
		return false
	}
	for number in 0 ..< first.field_count {
		a := field(file, first, number) or_return
		b := field(other_file, second, number) or_return
		if a.offset != b.offset || a.type != b.type || a.detail != b.detail || string_at(file, a.name_offset, a.name_count) != string_at(other_file, b.name_offset, b.name_count) {
			return false
		}
	}
	return true
}

// field gives field `number` of a record, from 0.
field :: proc "contextless" (file: []u8, of: Record, number: u32) -> (value: Field, ok: bool) {
	if number >= of.field_count || of.first_field == 0 {
		return {}, false
	}
	return record(file, .Fields, of.first_field + number, Field)
}

// field_size gives the bytes of a field of a record, from its type and its
// detail. 0: a record cannot have such a field.
field_size :: proc "contextless" (type: Type, detail: u32) -> u32 {
	#partial switch type {
	case .Integer:
		switch detail {
		case 0:
			return 8
		case 1, 2, 4, 8:
			return detail
		}
		return 0
	case .Handle:
		return 4
	case .Text:
		return detail <= RECORD_SIZE_LIMIT ? detail : 0
	}
	return 0
}

// field_integer gives the value of an Integer field of a record, as an
// i64: an unsigned field of 8 bytes is its bits. record has the size of
// the description. 0 for another field.
field_integer :: proc "contextless" (record: []u8, item: Field) -> i64 {
	size := field_size(item.type, item.detail)
	if item.type != .Integer || u64(item.offset) > u64(len(record)) || u64(size) > u64(len(record)) - u64(item.offset) {
		return 0
	}
	bits: u64
	for index in 0 ..< size {
		bits |= u64(record[item.offset + index]) << (8 * index)
	}
	if !item.unsigned && size < 8 && bits >> (8 * size - 1) & 1 != 0 {
		bits |= ~u64(0) << (8 * size) // The sign.
	}
	return i64(bits)
}

// field_integer_fits says if an Integer field holds a value: a signed field
// of n bytes holds -2^(8n-1) ..< 2^(8n-1), an unsigned one 0 ..< 2^(8n). An
// unsigned field of 8 bytes holds each value as its bits. A caller that
// writes a value of a person refuses one that does not fit.
field_integer_fits :: proc "contextless" (item: Field, value: i64) -> bool {
	size := field_size(item.type, item.detail)
	if item.type != .Integer || size == 0 || size == 8 {
		return item.type == .Integer && size == 8
	}
	bits := 8 * u64(size)
	if item.unsigned {
		return value >= 0 && u64(value) < u64(1) << bits
	}
	return value >= -(i64(1) << (bits - 1)) && value < i64(1) << (bits - 1)
}

// field_integer_set writes the low bytes of a value in an Integer field
// of a record.
field_integer_set :: proc "contextless" (record: []u8, item: Field, value: i64) {
	size := field_size(item.type, item.detail)
	if item.type != .Integer || u64(item.offset) > u64(len(record)) || u64(size) > u64(len(record)) - u64(item.offset) {
		return
	}
	for index in 0 ..< size {
		record[item.offset + index] = u8(u64(value) >> (8 * index))
	}
}

// field_text gives the text of a Text field of a record: the bytes before
// the first zero byte. record has the size of the description.
field_text :: proc "contextless" (record: []u8, item: Field) -> string {
	if item.type != .Text || u64(item.offset) > u64(len(record)) || u64(item.detail) > u64(len(record)) - u64(item.offset) {
		return ""
	}
	bytes := record[item.offset:][:item.detail]
	count := 0
	for count < len(bytes) && bytes[count] != 0 {
		count += 1
	}
	return string(bytes[:count])
}

// documentation gives the documentation of a module: one line, and the text.
// A module with no documentation gives two empty texts.
documentation :: proc "contextless" (file: []u8) -> (about, text: string) {
	value, _ := record(file, .Documentation, 1, Documentation)
	return string_at(file, value.about_offset, value.about_count), string_at(file, value.text_offset, value.text_count)
}
