package kerneltool

import "contract:blake3"
import module "contract:module"
import "core:fmt"
import "core:mem"
import "core:slice"
import "core:strings"

// An import of the module that convert writes: the file of the imported module.
Import_File :: struct {
	name: string,
	file: []u8,
}

@(private = "file")
Segment_Image :: struct {
	record: module.Segment,
	data:   []u8, // The bytes of the segment from its memory_offset.
}

// The description of an export: what module.Function holds.
Export_Description :: struct {
	name:       string,
	parameters: []module.Type,
	names:      []string, // The name of each parameter.
	result:     module.Type,
	about:      string,
	text:       string, // The documentation text that the module carries: the full comment, in its Markdown.
	markdown:   string, // The full comment, as its author wrote it: the site renders it.
	// What the type of each parameter needs (module.Function.parameter_details):
	// a Record: the number of the record, from 1, in Module_Description.records;
	// a Handle: the rights that the callee needs.
	details:       []u32,
	directions:    []module.Direction, // The direction of each Table or Bytes parameter (module.Function.parameter_directions).
	result_detail: u32,
	error_record:  u32, // Not 0: the export gives an error record, with this record (module.Function.error_record).
	// Where the source declares it: the site links each export to its line.
	file:          string,
	line:          int,
}

// The description of a record: what module.Record and its fields hold.
Record_Description :: struct {
	name:   string,
	size:   u32,
	fields: []Field_Description,
}

Field_Description :: struct {
	name:   string,
	offset: u32,
	type:     module.Type,
	detail:   u32, // An Integer: its size, 0 for 8. A Handle: the rights that the callee needs. A Text: its size in bytes.
	unsigned: bool, // An unsigned Integer.
}

// The description of a module: what its source says to a reader, and its exports.
Module_Description :: struct {
	about:    string, // One line: the first sentence of the comment of the package.
	text:     string, // The documentation text that the module carries: the comment of the package, in its Markdown.
	markdown: string, // The comment of the package, as its author wrote it: the site renders it.
	exports:  []Export_Description,
	records:  []Record_Description, // The records that the exports use. Record n + 1 of the module is records[n].
}

// convert writes a module from a shared object that lld linked.
//   exports: the descriptions of the exports. Export n + 1 is exports[n].
//   imports: the modules that the undefined symbols of the object come from.
// The module binds each import by (import index, export index). The names
// are used here only, at build time.
convert :: proc(name: string, elf: []u8, description: Module_Description, imports: []Import_File) -> (result: []u8, ok: bool) {
	exports := description.exports
	fail :: proc(name: string, format: string, args: ..any) -> ([]u8, bool) {
		fmt.eprintf("kerneltool: convert %s: ", name)
		fmt.eprintfln(format, ..args)
		return nil, false
	}
	at :: proc(elf: []u8, offset: u64, $T: typeid) -> (value: T, ok: bool) {
		if offset > u64(len(elf)) || size_of(T) > u64(len(elf)) - offset {
			return {}, false
		}
		mem.copy(&value, raw_data(elf[offset:]), size_of(T))
		return value, true
	}
	text :: proc(elf: []u8, table: Elf_Section_Header, offset: u32) -> string {
		start := table.offset + u64(offset)
		if start >= u64(len(elf)) {
			return ""
		}
		return string(cstring(raw_data(elf[start:])))
	}

	head, head_ok := at(elf, 0, Elf_Header)
	if !head_ok || head.magic != ELF_MAGIC || head.class != ELF_CLASS_64 || head.data != ELF_DATA_LITTLE_ENDIAN {
		return fail(name, "the input is not a 64-bit little-endian ELF file")
	}
	if head.type != ELF_TYPE_SHARED || head.machine != ELF_MACHINE_X86_64 {
		return fail(name, "the input is not a position-independent x86-64 object")
	}

	programs := make([dynamic]Elf_Program_Header, context.temp_allocator)
	for i in 0 ..< u64(head.program_header_count) {
		program := at(elf, head.program_header_offset + i * u64(head.program_header_size), Elf_Program_Header) or_return
		append(&programs, program)
	}
	sections := make([dynamic]Elf_Section_Header, context.temp_allocator)
	for i in 0 ..< u64(head.section_header_count) {
		section := at(elf, head.section_header_offset + i * u64(head.section_header_size), Elf_Section_Header) or_return
		append(&sections, section)
	}
	if int(head.section_name_section_index) >= len(sections) {
		return fail(name, "the input has no section names")
	}
	section_names := sections[head.section_name_section_index]

	// Segments. A module segment is one loadable segment of the input, on its
	// own pages. Its data starts as zero; only program data is copied, so that
	// no ELF structure reaches the module.
	images := make([dynamic]Segment_Image, context.temp_allocator)
	relro_start, relro_end: u64
	for program in programs {
		switch program.type {
		case ELF_PROGRAM_TLS:
			if program.memory_size != 0 {
				return fail(name, "thread-local data is not in the module contract")
			}
		case ELF_PROGRAM_RELRO:
			relro_start, relro_end = program.address, program.address + program.memory_size
		}
	}
	memory_size: u64
	for program in programs {
		if program.type != ELF_PROGRAM_LOAD {
			continue
		}
		start := mem.align_backward_uint(uint(program.address), module.PAGE_SIZE)
		end := mem.align_forward_uint(uint(program.address + program.memory_size), module.PAGE_SIZE)
		if u64(start) < memory_size {
			return fail(name, "two segments of the input share a page")
		}
		memory_size = u64(end)
		image := Segment_Image {
			record = {memory_offset = u64(start), memory_size = u64(end - start)},
			data = make([]u8, program.address - u64(start) + program.file_size, context.temp_allocator),
		}
		if program.flags & ELF_PROGRAM_READ != 0 {image.record.flags += {.Read}}
		if program.flags & ELF_PROGRAM_WRITE != 0 {image.record.flags += {.Write}}
		if program.flags & ELF_PROGRAM_EXECUTE != 0 {image.record.flags += {.Execute}}
		if .Write in image.record.flags && program.address >= relro_start && program.address + program.memory_size <= relro_end {
			image.record.flags += {.Read_Only_After_Load}
		}
		if image.record.flags & {.Write, .Execute} == {.Write, .Execute} {
			return fail(name, "a segment of the input is writable and executable")
		}
		append(&images, image)
	}

	// write_word writes 8 bytes at a memory offset, in a writable segment.
	write_word :: proc(images: []Segment_Image, memory_offset: u64, value: u64) -> bool {
		for image in images {
			if memory_offset < image.record.memory_offset || memory_offset - image.record.memory_offset + 8 > u64(len(image.data)) {
				continue
			}
			if .Write not_in image.record.flags || memory_offset % 8 != 0 {
				return false
			}
			word := value
			mem.copy(raw_data(image.data[memory_offset - image.record.memory_offset:]), &word, 8)
			return true
		}
		return false
	}

	dynamic_symbols: Elf_Section_Header
	for section in sections {
		section_name := text(elf, section_names, section.name)
		switch section.type {
		case ELF_SECTION_INIT_ARRAY, ELF_SECTION_FINI_ARRAY, ELF_SECTION_PREINIT_ARRAY:
			return fail(name, "section %s holds code that runs before the entry; a module has none", section_name)
		case ELF_SECTION_DYNAMIC_SYMBOLS:
			dynamic_symbols = section
		case ELF_SECTION_PROGRAM_DATA:
			if section.flags & ELF_SECTION_FLAG_ALLOCATED == 0 || strings.has_prefix(section_name, ".eh_frame") {
				continue
			}
			if section.offset > u64(len(elf)) || section.size > u64(len(elf)) - section.offset {
				return fail(name, "section %s is outside the input", section_name)
			}
			copied := false
			for image in images {
				if section.address >= image.record.memory_offset && section.address - image.record.memory_offset + section.size <= u64(len(image.data)) {
					copy(image.data[section.address - image.record.memory_offset:], elf[section.offset:][:section.size])
					copied = true
				}
			}
			if !copied {
				return fail(name, "section %s is in no segment", section_name)
			}
		}
	}
	if int(dynamic_symbols.link) >= len(sections) {
		return fail(name, "the input has no dynamic symbols")
	}
	symbol_names := sections[dynamic_symbols.link]
	symbol_count := dynamic_symbols.size / size_of(Elf_Symbol)

	// Exports.
	export_records := make([dynamic]module.Export, context.temp_allocator)
	function_records := make([dynamic]module.Function, context.temp_allocator)
	string_bytes := make([dynamic]u8, context.temp_allocator)
	append(&export_records, module.Export{})
	append(&function_records, module.Function{})
	append(&string_bytes, 0)
	entry_export: u32
	for description, index in exports {
		export_name := description.name
		// The buffer of a Text result takes one register.
		if len(description.parameters) + int(description.result == .Text || description.result == .Record) > module.PARAMETER_CAPACITY {
			return fail(name, "export %s has more than %d parameters", export_name, module.PARAMETER_CAPACITY)
		}
		found := false
		for i in 0 ..< symbol_count {
			symbol := at(elf, dynamic_symbols.offset + i * size_of(Elf_Symbol), Elf_Symbol) or_return
			if symbol.section_index == 0 || symbol.info & 0xF != ELF_SYMBOL_FUNCTION || text(elf, symbol_names, symbol.name) != export_name {
				continue
			}
			append(&export_records, module.Export{code_offset = symbol.value, function = u32(len(function_records))})
			function := module.Function {
				name_offset     = u32(len(string_bytes)),
				name_count      = u32(len(export_name)),
				about_offset    = u32(len(string_bytes) + len(export_name)),
				about_count     = u32(len(description.about)),
				parameter_count = u8(len(description.parameters)),
				result          = description.result,
			}
			copy(function.parameters[:], description.parameters)
			copy(function.parameter_details[:], description.details)
			copy(function.parameter_directions[:], description.directions)
			function.result_detail = description.result_detail
			function.error_record = description.error_record
			append(&string_bytes, export_name)
			append(&string_bytes, description.about)
			function.text_offset = u32(len(string_bytes))
			function.text_count = u32(len(description.text))
			append(&string_bytes, description.text)
			for parameter_name, parameter in description.names {
				function.parameter_names[parameter] = u32(len(string_bytes))
				function.parameter_name_counts[parameter] = u8(len(parameter_name))
				append(&string_bytes, parameter_name)
			}
			append(&function_records, function)
			found = true
			break
		}
		if !found {
			return fail(name, "export %s is not a function of the input", export_name)
		}
		if export_name == "entry" {
			entry_export = u32(index + 1)
		}
	}

	// Imports.
	import_records := make([dynamic]module.Import, context.temp_allocator)
	append(&import_records, module.Import{})
	for item in imports {
		append(&import_records, module.Import{hash = blake3.hash(item.file)})
	}

	// Relocations: each one becomes a rebase or a slot.
	rebases := make([dynamic]u64, context.temp_allocator)
	slot_records := make([dynamic]module.Slot, context.temp_allocator)
	append(&slot_records, module.Slot{})
	for section in sections {
		if section.type != ELF_SECTION_RELA || section.flags & ELF_SECTION_FLAG_ALLOCATED == 0 {
			continue
		}
		for i in 0 ..< section.size / size_of(Elf_Rela) {
			relocation := at(elf, section.offset + i * size_of(Elf_Rela), Elf_Rela) or_return
			type := u32(relocation.info)
			symbol := at(elf, dynamic_symbols.offset + (relocation.info >> 32) * size_of(Elf_Symbol), Elf_Symbol) or_return
			symbol_name := text(elf, symbol_names, symbol.name)
			value: u64
			switch type {
			case ELF_RELOCATION_RELATIVE:
				value = u64(relocation.addend)
			case ELF_RELOCATION_64, ELF_RELOCATION_GLOBAL_DATA, ELF_RELOCATION_JUMP_SLOT:
				if symbol.section_index == 0 {
					slot := module.Slot{memory_offset = relocation.offset}
					find: for item, import_index in imports {
						for export_index in 1 ..< module.count(item.file, .Exports) {
							if module_export_name(item.file, export_index) == symbol_name {
								slot.import_index = u32(import_index + 1)
								slot.export_index = export_index
								break find
							}
						}
					}
					if slot.import_index == 0 {
						return fail(name, "%s is not defined, and no import exports it", symbol_name)
					}
					if !write_word(images[:], relocation.offset, 0) {
						return fail(name, "the slot of %s is not in writable data", symbol_name)
					}
					append(&slot_records, slot)
					continue
				}
				value = symbol.value
				if type == ELF_RELOCATION_64 {
					value += u64(relocation.addend)
				}
			case:
				return fail(name, "relocation type %d (symbol %s) has no form in a module", type, symbol_name)
			}
			if !write_word(images[:], relocation.offset, value) {
				return fail(name, "a rebase at offset %x is not in writable data", relocation.offset)
			}
			append(&rebases, relocation.offset)
		}
	}
	// A segment that the loader writes nowhere is only read. The linker puts
	// its own table there, which is not copied, so such a segment is often
	// empty: every program that has the module can then share its pages.
	for &image in images {
		if .Read_Only_After_Load not_in image.record.flags {
			continue
		}
		written := false
		first, end := image.record.memory_offset, image.record.memory_offset + image.record.memory_size
		for offset in rebases {
			written ||= offset >= first && offset < end
		}
		for slot in slot_records[1:] {
			written ||= slot.memory_offset >= first && slot.memory_offset < end
		}
		if !written {
			image.record.flags -= {.Write, .Read_Only_After_Load}
		}
	}
	rebase_words := encode_rebases(rebases[:])

	// Layout: header, directory, tables, then the data of each segment.
	output := make([dynamic]u8)
	directory: [module.TABLE_COUNT]module.Table_Entry
	resize(&output, size_of(module.Header) + size_of(directory))
	add_table :: proc(output: ^[dynamic]u8, directory: ^[module.TABLE_COUNT]module.Table_Entry, kind: module.Table_Kind, records: []$T) {
		resize(output, mem.align_forward_int(len(output), 8))
		directory[kind] = {offset = u64(len(output)), count = u32(len(records)), record_size = size_of(T)}
		append(output, ..slice.to_bytes(records))
	}
	segment_records := make([dynamic]module.Segment, context.temp_allocator)
	append(&segment_records, module.Segment{})
	for image in images {
		append(&segment_records, image.record)
	}
	add_table(&output, &directory, .Segments, segment_records[:])
	segment_table_offset := directory[module.Table_Kind.Segments].offset
	add_table(&output, &directory, .Imports, import_records[:])
	add_table(&output, &directory, .Slots, slot_records[:])
	add_table(&output, &directory, .Exports, export_records[:])
	add_table(&output, &directory, .Rebases, rebase_words)
	add_table(&output, &directory, .Functions, function_records[:])
	documentation_records := [2]module.Documentation{}
	documentation_records[1] = {
		about_offset = u32(len(string_bytes)),
		about_count  = u32(len(description.about)),
		text_offset  = u32(len(string_bytes) + len(description.about)),
		text_count   = u32(len(description.text)),
	}
	append(&string_bytes, description.about)
	append(&string_bytes, description.text)
	// The records, and the fields of each record one after the other.
	record_records := make([dynamic]module.Record, context.temp_allocator)
	field_records := make([dynamic]module.Field, context.temp_allocator)
	append(&record_records, module.Record{})
	append(&field_records, module.Field{})
	for item in description.records {
		append(&record_records, module.Record{name_offset = u32(len(string_bytes)), name_count = u32(len(item.name)), size = item.size, first_field = u32(len(field_records)), field_count = u32(len(item.fields))})
		append(&string_bytes, item.name)
		for field in item.fields {
			append(&field_records, module.Field{name_offset = u32(len(string_bytes)), name_count = u32(len(field.name)), offset = field.offset, type = field.type, detail = field.detail, unsigned = field.unsigned})
			append(&string_bytes, field.name)
		}
	}
	add_table(&output, &directory, .Records, record_records[:])
	add_table(&output, &directory, .Fields, field_records[:])
	add_table(&output, &directory, .Strings, string_bytes[:])
	add_table(&output, &directory, .Documentation, documentation_records[:])
	for image, index in images {
		// The zero bytes at the end of a segment are not stored.
		data := image.data
		for len(data) > 0 && data[len(data) - 1] == 0 {
			data = data[:len(data) - 1]
		}
		resize(&output, mem.align_forward_int(len(output), module.PAGE_SIZE))
		record := image.record
		record.file_offset = u64(len(output))
		record.file_size = u64(len(data))
		append(&output, ..data)
		mem.copy(&output[int(segment_table_offset) + (index + 1) * size_of(module.Segment)], &record, size_of(record))
	}
	header := module.Header {
		magic        = module.MAGIC,
		version      = module.VERSION,
		header_size  = size_of(module.Header),
		machine      = .X86_64,
		table_count  = module.TABLE_COUNT,
		memory_size  = memory_size,
		entry_export = entry_export,
	}
	mem.copy(&output[0], &header, size_of(header))
	mem.copy(&output[size_of(header)], &directory, size_of(directory))

	if error := module.validate(output[:]); error != .None {
		return fail(name, "the module that was written is not valid: %v", error)
	}
	return output[:], true
}

// module_export_name gives the name of an export of a module file.
module_export_name :: proc(file: []u8, export_index: u32) -> string {
	function, _ := module.function(file, export_index)
	return module.string_at(file, function.name_offset, function.name_count)
}

// encode_rebases writes memory offsets in the RELR form (module/format.odin).
encode_rebases :: proc(memory_offsets: []u64, allocator := context.temp_allocator) -> []u64 {
	slice.sort(memory_offsets)
	words := make([dynamic]u64, allocator)
	i := 0
	for i < len(memory_offsets) {
		append(&words, memory_offsets[i])
		cursor := memory_offsets[i] + 8
		i += 1
		for {
			bitmap: u64
			for i < len(memory_offsets) {
				distance := memory_offsets[i] - cursor
				if distance >= 8 * module.REBASE_BITMAP_LOCATIONS || distance % 8 != 0 {
					break
				}
				bitmap |= 1 << (distance / 8 + 1)
				i += 1
			}
			if bitmap == 0 {
				break
			}
			append(&words, bitmap | 1)
			cursor += 8 * module.REBASE_BITMAP_LOCATIONS
		}
	}
	return words[:]
}
