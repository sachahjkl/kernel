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
	base := u64(load_address)
	cursor: u64
	for index in 0 ..< count(file, .Rebases) {
		word, _ := record(file, .Rebases, index, u64)
		if word & 1 == 0 {
			rebase_location(file, memory, word, base) or_return
			cursor = word + 8
			continue
		}
		for bit in u64(1) ..= REBASE_BITMAP_LOCATIONS {
			if word >> bit & 1 != 0 {
				rebase_location(file, memory, cursor + 8 * (bit - 1), base) or_return
			}
		}
		cursor += 8 * REBASE_BITMAP_LOCATIONS
	}
	return .None
}

@(private)
rebase_location :: proc "contextless" (file: []u8, memory: []u8, memory_offset: u64, base: u64) -> Error {
	if !writable(file, memory_offset) {
		return .Bad_Rebase
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

// bind writes, in each slot, the address of its export. import_files and
// import_bases give the file and the load address of each import, in the
// order of the import table; their index 0 is import 1.
bind :: proc "contextless" (file: []u8, memory: []u8, import_files: [][]u8, import_bases: []uintptr) -> Error {
	imports := count(file, .Imports)
	if imports > 1 && (len(import_files) != int(imports) - 1 || len(import_bases) != int(imports) - 1) {
		return .Bad_Import
	}
	for index in 1 ..< count(file, .Slots) {
		slot, _ := record(file, .Slots, index, Slot)
		if slot.import_index == 0 || slot.import_index >= imports {
			return .Bad_Slot
		}
		if !writable(file, slot.memory_offset) {
			return .Bad_Slot
		}
		address, ok := export_address(import_files[slot.import_index - 1], import_bases[slot.import_index - 1], slot.export_index)
		if !ok {
			return .Bad_Slot
		}
		intrinsics.unaligned_store((^u64)(raw_data(memory[slot.memory_offset:])), u64(address))
	}
	return .None
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

// documentation gives the documentation of a module: one line, and the text.
// A module with no documentation gives two empty texts.
documentation :: proc "contextless" (file: []u8) -> (about, text: string) {
	value, _ := record(file, .Documentation, 1, Documentation)
	return string_at(file, value.about_offset, value.about_count), string_at(file, value.text_offset, value.text_count)
}
