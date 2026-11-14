package kerneltool

import "base:runtime"
import "contract:blake3"
import debug_object "contract:debug_object"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"

// The debug object of each module (docs/MODULE_CONTRACT.md, "Debug
// information"). The tool reads the linked ELF file of the module: the
// procedure table comes from its symbol table, the line table from the line
// program of DWARF that the compiler wrote with its debug information, the types and the
// variables from the entries of .debug_info (debug_information.odin). The
// tool writes the tables of contract:debug_object, which a program reads
// with no parser of DWARF. The DWARF stays in the linked file, for a
// debugger of the host.

// The debug image: the debug object of each module of the build, in the
// form of a boot image. The tool puts it on each boot volume, beside the
// boot program; the boot program reads it if it is there.
DEBUG_IMAGE :: BUILD_FOLDER + "/debug.image"
DEBUG_IMAGE_VOLUME_PATH :: "DEBUG/OBJECTS.IMG"

debug_object_path :: proc(name: string) -> string {
	return join(module_build_folder, "/", name, ".debug")
}

// One procedure before the encoding: a function symbol of the ELF file.
Debug_Procedure :: struct {
	start: u64,
	size:  u64,
	name:  string,
}

// One row of a line program of DWARF, after the file was named.
Debug_Row :: struct {
	address: u64,
	path:    string, // "": the end of a sequence, or the line 0.
	line:    u32,
	order:   int, // The place of the row in the line program: equal addresses keep the last row.
}

// debug_object_write reads the linked file of a module and writes its
// debug object beside the module file.
debug_object_write :: proc(name: string, elf: []u8, module_file: []u8) -> bool {
	object, error := debug_object_from_elf(elf, blake3.hash(module_file))
	if error != "" {
		fmt.eprintfln("kerneltool: the debug object of %s: %s", name, error)
		return false
	}
	if fault := debug_object.check(object); fault != .None {
		fmt.eprintfln("kerneltool: the debug object of %s that the tool wrote is refused: %s", name, debug_object.fault_sentences[fault])
		return false
	}
	if problem := debug_object_host_path(object); problem != "" {
		fmt.eprintfln("kerneltool: the debug object of %s: %s", name, problem)
		return false
	}
	if err := os.write_entire_file(debug_object_path(name), object); err != nil {
		fmt.eprintfln("kerneltool: cannot write %s: %v", debug_object_path(name), err)
		return false
	}
	return true
}

// debug_object_from_elf makes the debug object of a linked file. error is
// "" on success.
debug_object_from_elf :: proc(elf: []u8, module_hash: [32]u8) -> (object: []u8, error: string) {
	context.allocator = context.temp_allocator
	header, sections, ok := elf_sections(elf)
	if !ok {
		return nil, "the linked file is not a 64-bit ELF file with whole section headers"
	}
	code_start, code_end := elf_code_range(elf, header)
	if code_end <= code_start {
		return nil, "the linked file has no segment of code"
	}
	procedures := elf_function_symbols(elf, sections, code_start, code_end)
	line_rows: []Debug_Row
	host_paths: map[string]string
	information: Debug_Information
	if line_program, has_lines := elf_section_named(elf, header, sections, ".debug_line"); has_lines {
		line_strings, _ := elf_section_named(elf, header, sections, ".debug_line_str")
		debug_strings, _ := elf_section_named(elf, header, sections, ".debug_str")
		// The compilation directory of each unit: the directory 0 of a line
		// program of DWARF 2 to 4 is only there.
		units, _ := elf_section_named(elf, header, sections, ".debug_info")
		abbreviations, _ := elf_section_named(elf, header, sections, ".debug_abbrev")
		string_offsets, _ := elf_section_named(elf, header, sections, ".debug_str_offsets")
		compilation_directories: map[u64]string
		compilation_directories, error = dwarf_compilation_directories(units, abbreviations, debug_strings, line_strings, string_offsets)
		if error != "" {
			return nil, error
		}
		line_rows, host_paths, error = dwarf_line_rows(line_program, line_strings, debug_strings, compilation_directories, code_start, code_end)
		if error != "" {
			return nil, error
		}
		if len(units) > 0 {
			locations, _ := elf_section_named(elf, header, sections, ".debug_loc")
			ranges, _ := elf_section_named(elf, header, sections, ".debug_ranges")
			information, error = debug_information_from_dwarf(units, abbreviations, debug_strings, locations, ranges, sections)
			if error != "" {
				return nil, error
			}
		}
	}
	file_hashes: map[string][32]u8
	file_hashes, error = debug_source_file_hashes(line_rows, host_paths)
	if error != "" {
		return nil, error
	}
	return debug_object_encode(procedures, line_rows, code_end, module_hash, file_hashes, information)
}

// debug_source_file_hashes gives the BLAKE3 hash of the content of each
// source file of the rows, by its path in the debug object. The tool reads
// the file where the compiler read it. A file that the tool cannot read
// is an error: a debug object with no hash for a file lets a reader show
// lines of another version of the source.
debug_source_file_hashes :: proc(line_rows: []Debug_Row, host_paths: map[string]string) -> (hashes: map[string][32]u8, error: string) {
	hashes = make(map[string][32]u8, context.temp_allocator)
	for row in line_rows {
		if row.path == "" || row.path in hashes {
			continue
		}
		host_path, known := host_paths[row.path]
		if !known {
			return nil, fmt.tprintf("the source file %s has no path on the build host", row.path)
		}
		content, read_error := os.read_entire_file(host_path, context.temp_allocator)
		if read_error != nil {
			return nil, fmt.tprintf("cannot read the source file %s to hash it: %v", host_path, read_error)
		}
		hashes[row.path] = blake3.hash(content)
	}
	return hashes, ""
}

// debug_host_path gives the path of a source file on the build host, from
// its directory and its name in a line program: where the tool reads the
// file to hash it. It never reaches the debug object.
debug_host_path :: proc(directory, name: string) -> string {
	if !strings.has_prefix(name, "/") && directory != "" {
		return join(directory, "/", name)
	}
	return name
}

// debug_object_encode writes the tables: one string for each name and each
// path, the files in the order of their first row, each with the hash of
// its content from `file_hashes` (no entry: no hash), then the types, the
// globals and the variables of `information`, each table in a fixed order
// (debug_tables_encode).
debug_object_encode :: proc(procedures: []Debug_Procedure, line_rows: []Debug_Row, code_end: u64, module_hash: [32]u8, file_hashes: map[string][32]u8, information: Debug_Information) -> (object: []u8, error: string) {
	context.allocator = context.temp_allocator
	string_bytes := make([dynamic]u8)
	string_add :: proc(pool: ^[dynamic]u8, value: string) -> (offset: u32) {
		offset = u32(len(pool))
		append(pool, ..transmute([]u8)value)
		return
	}
	procedure_table := make([dynamic]debug_object.Procedure)
	for item in procedures {
		if item.start > u64(max(u32)) || item.size > u64(max(u32)) || len(item.name) > int(max(u16)) {
			return nil, fmt.tprintf("the procedure %s at %x does not fit the procedure table", item.name, item.start)
		}
		package_count := strings.index(item.name, "::")
		append(&procedure_table, debug_object.Procedure{start = u32(item.start), size = u32(item.size), name_offset = string_add(&string_bytes, item.name), name_count = u16(len(item.name)), package_count = u16(max(package_count, 0))})
	}
	file_table := make([dynamic]debug_object.File)
	append(&file_table, debug_object.File{})
	file_numbers := make(map[string]u32)
	line_table := make([dynamic]debug_object.Line)
	for row in line_rows {
		file := u32(0)
		if row.path != "" {
			number, known := file_numbers[row.path]
			if !known {
				number = u32(len(file_table))
				file_numbers[row.path] = number
				append(&file_table, debug_object.File{path_offset = string_add(&string_bytes, row.path), path_count = u32(len(row.path)), content_hash = file_hashes[row.path]})
			}
			file = number
		}
		if row.address > u64(max(u32)) {
			return nil, fmt.tprintf("the row of the line table at %x does not fit the line table", row.address)
		}
		if file >= debug_object.FILE_CAPACITY || row.line >= debug_object.ROW_LINE_LIMIT {
			return nil, fmt.tprintf("the line %d of %s, file %d of the module, is past the bounds of a row (%d files, %d lines)", row.line, row.path, file, debug_object.FILE_CAPACITY - 1, debug_object.ROW_LINE_LIMIT - 1)
		}
		append(&line_table, debug_object.Line{offset = u32(row.address), place = file == 0 ? 0 : debug_object.row_place(file, row.line)})
	}
	// The table ends with a row with no file.
	if len(line_table) == 0 || debug_object.row_file(line_table[len(line_table) - 1]) != 0 {
		append(&line_table, debug_object.Line{offset = u32(min(code_end, u64(max(u32))))})
	}
	parts := debug_object.Encode_Parts {
		module_hash = module_hash,
		procedures  = procedure_table[:],
		files       = file_table[:],
		lines       = line_table[:],
	}
	error = debug_tables_encode(&parts, &string_bytes, information)
	if error != "" {
		return nil, error
	}
	parts.strings = string_bytes[:]
	object = make([]u8, debug_object.encoded_size(parts))
	if !debug_object.encode(parts, object) {
		return nil, fmt.tprintf("%d procedures, %d files, %d rows, %d types, %d fields, %d globals, %d variables, %d ranges of variables and %d bytes of names: a table is over its capacity", len(procedure_table), len(file_table), len(line_table), len(parts.types), len(parts.fields), len(parts.globals), len(parts.variables), len(parts.ranges), len(string_bytes))
	}
	return object, ""
}

// The names of the types, the globals and the variables: each one is in
// the strings once.
Debug_Names :: struct {
	bytes: ^[dynamic]u8,
	known: map[string]u32,
}

debug_name_add :: proc(pool: ^Debug_Names, value: string) -> u32 {
	if value == "" {
		return 0
	}
	if known_offset, known := pool.known[value]; known {
		return known_offset
	}
	offset := u32(len(pool.bytes))
	append(pool.bytes, ..transmute([]u8)value)
	pool.known[value] = offset
	return offset
}

// debug_tables_encode writes the type table, the field table, the
// enumeration value table, the global table, the variable table and the
// variable range table of `information` into the parts, and their names
// into the strings.
//
// Each table has a fixed order, so that two builds of one source give the
// same bytes whatever the order of the entries of DWARF: the types by
// their content (debug_types_in_fixed_order); the globals by their
// address, then their name; the variables by their procedure, then their
// name (debug_variables_encode). Two records with the same content are
// one record. A name is in the strings once.
debug_tables_encode :: proc(parts: ^debug_object.Encode_Parts, string_bytes: ^[dynamic]u8, information: Debug_Information) -> (error: string) {
	context.allocator = context.temp_allocator
	names := Debug_Names{bytes = string_bytes, known = make(map[string]u32)}
	// The ranges that the tables keep: a type that only a dropped range
	// uses is not written.
	kept := debug_variable_ranges_in_procedures(information.variables, parts.procedures)
	types, index_of, order_error := debug_types_in_fixed_order(information.types, information.globals, kept)
	if order_error != "" {
		return order_error
	}
	type_table := make([dynamic]debug_object.Type)
	field_table := make([dynamic]debug_object.Field)
	value_table := make([dynamic]debug_object.Enumeration_Value)
	append(&type_table, debug_object.Type{})
	for type in types[1:] {
		if type.size > u64(max(u32)) || type.count > u64(max(u32)) {
			return fmt.tprintf("the type %s of %d bytes and %d elements does not fit the type table", type.name, type.size, type.count)
		}
		record := debug_object.Type {
			name_offset = debug_name_add(&names, type.name),
			name_count  = u32(len(type.name)),
			size        = u32(type.size),
			kind        = type.kind,
			element     = u32(type.element),
			count       = u32(type.count),
		}
		#partial switch type.kind {
		case .Record, .Union, .Slice, .String:
			record.first = u32(len(field_table))
			record.count = u32(len(type.fields))
			for field in type.fields {
				if field.offset > u64(max(u32)) {
					return fmt.tprintf("the field %s of the type %s, at %d bytes, does not fit the field table", field.name, type.name, field.offset)
				}
				append(&field_table, debug_object.Field{name_offset = debug_name_add(&names, field.name), name_count = u32(len(field.name)), offset = u32(field.offset), type = u32(field.type), bit_shift = field.bit_shift, bit_size = field.bit_size})
			}
		case .Enumeration:
			record.first = u32(len(value_table))
			record.count = u32(len(type.values))
			for named in type.values {
				append(&value_table, debug_object.Enumeration_Value{name_offset = debug_name_add(&names, named.name), name_count = u32(len(named.name)), value_low = u32(named.value & 0xFFFF_FFFF), value_high = u32(named.value >> 32)})
			}
		}
		append(&type_table, record)
	}
	// The globals: by their address, then their name.
	globals := make([]Debug_Global, len(information.globals))
	copy(globals, information.globals)
	for &global in globals {
		global.type = index_of[global.type]
	}
	slice.sort_by(globals, proc(a, b: Debug_Global) -> bool {
		if a.address != b.address {
			return a.address < b.address
		}
		if a.name != b.name {
			return a.name < b.name
		}
		return a.type < b.type
	})
	global_table := make([dynamic]debug_object.Global)
	for global, index in globals {
		if index > 0 && globals[index - 1] == global {
			continue
		}
		if global.address > u64(max(u32)) || global.name == "" {
			return fmt.tprintf("the global %s at %x does not fit the global table", global.name, global.address)
		}
		append(&global_table, debug_object.Global{address = u32(global.address), type = u32(global.type), name_offset = debug_name_add(&names, global.name), name_count = u32(len(global.name))})
	}
	error = debug_variables_encode(parts, &names, kept, index_of)
	if error != "" {
		return error
	}
	parts.types = type_table[:]
	parts.fields = field_table[:]
	parts.values = value_table[:]
	parts.globals = global_table[:]
	return ""
}

// debug_variable_ranges_in_procedures gives the ranges of variables that
// the tables keep, each with its procedure of the procedure table.
//
// - A range is given to the procedure that holds its start, and is cut at
//   the end of that procedure. A range in no procedure (code that the link
//   dropped) and a range with no byte are not kept.
// - A range that is not readable of a variable of a procedure that the
//   compiler put inside another one is not kept. Such variables are most
//   of the variables of a module, at each place where the compiler put a
//   small procedure of a library, and most of them are readable nowhere:
//   a debugger shows such a variable where it has a value.
debug_variable_ranges_in_procedures :: proc(variables: []Debug_Variable, procedures: []debug_object.Procedure) -> []Debug_Variable {
	kept := make([dynamic]Debug_Variable, context.temp_allocator)
	for variable in variables {
		if variable.end <= variable.start || variable.name == "" || (variable.inlined && variable.location == .Not_Readable) {
			continue
		}
		// The last procedure that starts at or before the range.
		low, high := 0, len(procedures)
		for low < high {
			middle := low + (high - low) / 2
			if u64(procedures[middle].start) <= variable.start {
				low = middle + 1
			} else {
				high = middle
			}
		}
		if low == 0 {
			continue
		}
		procedure_end := u64(procedures[low - 1].start) + u64(procedures[low - 1].size)
		if variable.start >= procedure_end {
			continue
		}
		item := variable
		item.procedure = u32(low - 1)
		item.end = min(variable.end, procedure_end)
		append(&kept, item)
	}
	return kept[:]
}

// debug_variables_encode writes the variable table and the variable range
// table from the kept ranges. `index_of` gives the type of the type table
// for each type of the source.
//
// - One variable is one procedure, one name, one role and one type: the
//   ranges of two variables of the source that agree on the four are the
//   ranges of one record.
// - Two ranges of a variable with the same variable location that touch
//   or overlap are one range. A gap between them keeps them apart.
// - The ranges that are not readable of a variable become one range, from
//   the first of their starts to the last of their ends: where the
//   variable is visible. It is not written when one readable range covers
//   it. So a variable that is readable nowhere is one record of a range.
// - A range longer than a record holds is several records in a row.
// - The variables are in the order of their procedure, their name, their
//   role, then their type; the ranges of a variable in the order of their
//   start. Neither order depends on the order of the source.
debug_variables_encode :: proc(parts: ^debug_object.Encode_Parts, names: ^Debug_Names, kept: []Debug_Variable, index_of: []int) -> (error: string) {
	context.allocator = context.temp_allocator
	ordered := make([]Debug_Variable, len(kept))
	copy(ordered, kept)
	for &item in ordered {
		item.type = index_of[item.type]
		// A field that its kind of location does not use is zero.
		if item.location == .Not_Readable {
			item.register = 0
		}
		if item.location == .Not_Readable || item.location == .Register {
			item.offset = 0
		}
	}
	// The ranges of one variable in a row; in it, the ranges that are not
	// readable first, then the ranges of one location in a row, by their start.
	slice.sort_by(ordered, proc(a, b: Debug_Variable) -> bool {
		if a.procedure != b.procedure {
			return a.procedure < b.procedure
		}
		if a.name != b.name {
			return a.name < b.name
		}
		if a.role != b.role {
			return u8(a.role) < u8(b.role)
		}
		if a.type != b.type {
			return a.type < b.type
		}
		if a.location != b.location {
			return u8(a.location) < u8(b.location)
		}
		if a.register != b.register {
			return a.register < b.register
		}
		if a.offset != b.offset {
			return a.offset < b.offset
		}
		if a.start != b.start {
			return a.start < b.start
		}
		return a.end < b.end
	})
	variable_table := make([dynamic]debug_object.Variable)
	range_table := make([dynamic]debug_object.Variable_Range)
	merged := make([dynamic]Debug_Variable)
	at := 0
	for at < len(ordered) {
		first := ordered[at]
		group_end := at
		for group_end < len(ordered) && ordered[group_end].procedure == first.procedure && ordered[group_end].name == first.name && ordered[group_end].role == first.role && ordered[group_end].type == first.type {
			group_end += 1
		}
		clear(&merged)
		visible_start, visible_end := max(u64), u64(0)
		for item in ordered[at:group_end] {
			if item.location == .Not_Readable {
				visible_start = min(visible_start, item.start)
				visible_end = max(visible_end, item.end)
				continue
			}
			if len(merged) > 0 {
				last := &merged[len(merged) - 1]
				if last.location == item.location && last.register == item.register && last.offset == item.offset && item.start <= last.end {
					last.end = max(last.end, item.end)
					continue
				}
			}
			append(&merged, item)
		}
		if visible_end > visible_start {
			covered := false
			for item in merged {
				if item.start <= visible_start && item.end >= visible_end {
					covered = true
				}
			}
			if !covered {
				visible := first
				visible.location = .Not_Readable
				visible.register = 0
				visible.offset = 0
				visible.start = visible_start
				visible.end = visible_end
				append(&merged, visible)
			}
		}
		slice.sort_by(merged[:], proc(a, b: Debug_Variable) -> bool {
			if a.start != b.start {
				return a.start < b.start
			}
			if a.end != b.end {
				return a.end < b.end
			}
			if a.location != b.location {
				return u8(a.location) < u8(b.location)
			}
			if a.register != b.register {
				return a.register < b.register
			}
			return a.offset < b.offset
		})
		if len(first.name) > int(max(u16)) {
			return fmt.tprintf("the name of the variable %s does not fit the variable table", first.name)
		}
		append(&variable_table, debug_object.Variable{name_offset = debug_name_add(names, first.name), name_count = u16(len(first.name)), role = first.role, type = u32(first.type), first_range = u32(len(range_table))})
		for item in merged {
			start := item.start
			for start < item.end {
				size := min(item.end - start, u64(debug_object.VARIABLE_RANGE_SIZE_LIMIT))
				append(&range_table, debug_object.Variable_Range{start = u32(start), offset = item.offset, size = u16(size), location = item.location, register = u8(item.register)})
				start += size
			}
		}
		at = group_end
	}
	parts.variables = variable_table[:]
	parts.ranges = range_table[:]
	return ""
}

elf_sections :: proc(elf: []u8) -> (header: Elf_Header, sections: []Elf_Section_Header, ok: bool) {
	if len(elf) < size_of(Elf_Header) {
		return {}, nil, false
	}
	mem.copy(&header, raw_data(elf), size_of(header))
	if header.magic != ELF_MAGIC || header.class != ELF_CLASS_64 || header.data != ELF_DATA_LITTLE_ENDIAN || header.section_header_size != size_of(Elf_Section_Header) {
		return {}, nil, false
	}
	count := u64(header.section_header_count)
	if header.section_header_offset > u64(len(elf)) || count * size_of(Elf_Section_Header) > u64(len(elf)) - header.section_header_offset {
		return {}, nil, false
	}
	sections = make([]Elf_Section_Header, count, context.temp_allocator)
	if count > 0 {
		mem.copy(raw_data(sections), raw_data(elf[header.section_header_offset:]), int(count) * size_of(Elf_Section_Header))
	}
	return header, sections, true
}

// elf_section_bytes gives the bytes of a section in the file, or false.
elf_section_bytes :: proc(elf: []u8, section: Elf_Section_Header) -> ([]u8, bool) {
	if section.offset > u64(len(elf)) || section.size > u64(len(elf)) - section.offset {
		return nil, false
	}
	return elf[section.offset:][:section.size], true
}

elf_section_named :: proc(elf: []u8, header: Elf_Header, sections: []Elf_Section_Header, name: string) -> ([]u8, bool) {
	if int(header.section_name_section_index) >= len(sections) {
		return nil, false
	}
	names, has_names := elf_section_bytes(elf, sections[header.section_name_section_index])
	if !has_names {
		return nil, false
	}
	for section in sections {
		if text_until_zero(names, u64(section.name)) == name && section.type != ELF_SECTION_NO_BITS {
			return elf_section_bytes(elf, section)
		}
	}
	return nil, false
}

// elf_code_range gives the addresses of the segments with Execute: the
// range where a procedure or a row can be.
elf_code_range :: proc(elf: []u8, header: Elf_Header) -> (start, end: u64) {
	start = max(u64)
	for index in 0 ..< u64(header.program_header_count) {
		at := header.program_header_offset + index * u64(header.program_header_size)
		if at > u64(len(elf)) || size_of(Elf_Program_Header) > u64(len(elf)) - at {
			break
		}
		program: Elf_Program_Header
		mem.copy(&program, raw_data(elf[at:]), size_of(program))
		if program.type == ELF_PROGRAM_LOAD && program.flags & ELF_PROGRAM_EXECUTE != 0 {
			start = min(start, program.address)
			end = max(end, program.address + program.memory_size)
		}
	}
	return start, end
}

// elf_function_symbols gives the function symbols of the symbol table
// inside the code, by their start, one for each start, with no overlap. A
// symbol with no size (an assembler label) reaches the next one. Of two
// names at one start (memcpy is copy_bytes_without_overlap), the longer
// name stays: the name of the system is the long one.
elf_function_symbols :: proc(elf: []u8, sections: []Elf_Section_Header, code_start, code_end: u64) -> []Debug_Procedure {
	list := make([dynamic]Debug_Procedure, context.temp_allocator)
	for section in sections {
		if section.type != ELF_SECTION_SYMBOLS || int(section.link) >= len(sections) {
			continue
		}
		symbols, has_symbols := elf_section_bytes(elf, section)
		names, has_names := elf_section_bytes(elf, sections[section.link])
		if !has_symbols || !has_names {
			continue
		}
		for at := 0; at + size_of(Elf_Symbol) <= len(symbols); at += size_of(Elf_Symbol) {
			symbol: Elf_Symbol
			mem.copy(&symbol, raw_data(symbols[at:]), size_of(symbol))
			if symbol.info & 0xF != ELF_SYMBOL_FUNCTION || symbol.section_index == 0 || symbol.section_index >= 0xFF00 || symbol.value < code_start || symbol.value >= code_end || u64(symbol.name) >= u64(len(names)) {
				continue
			}
			name := text_until_zero(names, u64(symbol.name))
			if name == "" {
				continue
			}
			append(&list, Debug_Procedure{start = symbol.value, size = symbol.size, name = name})
		}
	}
	slice.sort_by(list[:], proc(a, b: Debug_Procedure) -> bool {
		if a.start != b.start {
			return a.start < b.start
		}
		if len(a.name) != len(b.name) {
			return len(a.name) > len(b.name)
		}
		return a.name < b.name
	})
	result := make([dynamic]Debug_Procedure, context.temp_allocator)
	for item in list {
		if len(result) > 0 && result[len(result) - 1].start == item.start {
			continue
		}
		append(&result, item)
	}
	for &item, index in result {
		next := index + 1 < len(result) ? result[index + 1].start : code_end
		if item.size == 0 || item.start + item.size > next {
			item.size = next - item.start
		}
	}
	return result[:]
}

// A reader of the bytes of a section of DWARF. A read past the end sets
// `failed` and gives 0.
Dwarf_Reader :: struct {
	bytes:  []u8,
	at:     int,
	failed: bool,
}

dwarf_bytes :: proc(reader: ^Dwarf_Reader, count: int) -> []u8 {
	if count < 0 || reader.at > len(reader.bytes) || count > len(reader.bytes) - reader.at {
		reader.failed = true
		reader.at = len(reader.bytes)
		return nil
	}
	result := reader.bytes[reader.at:][:count]
	reader.at += count
	return result
}

dwarf_unsigned :: proc(reader: ^Dwarf_Reader, size: int) -> (value: u64) {
	for part, index in dwarf_bytes(reader, size) {
		value |= u64(part) << uint(8 * index)
	}
	return
}

dwarf_leb128 :: proc(reader: ^Dwarf_Reader, signed: bool) -> (value: u64) {
	shift: uint
	for {
		part := dwarf_bytes(reader, 1)
		if part == nil {
			return 0
		}
		if shift < 64 {
			value |= u64(part[0] & 0x7F) << shift
		}
		shift += 7
		if part[0] & 0x80 == 0 {
			if signed && shift < 64 && part[0] & 0x40 != 0 {
				value |= ~u64(0) << shift
			}
			return value
		}
	}
}

dwarf_text :: proc(reader: ^Dwarf_Reader) -> string {
	end := reader.at
	for end < len(reader.bytes) && reader.bytes[end] != 0 {
		end += 1
	}
	if end >= len(reader.bytes) {
		reader.failed = true
		reader.at = len(reader.bytes)
		return ""
	}
	text := string(reader.bytes[reader.at:end])
	reader.at = end + 1
	return text
}

// The forms of an entry of a directory or a file in a line program of
// DWARF 5 (DWARF 5, section 7.5.6), and the content types (section 6.2.4.1).
DW_FORM_BLOCK :: 0x09
DW_FORM_DATA1 :: 0x0B
DW_FORM_DATA2 :: 0x05
DW_FORM_DATA4 :: 0x06
DW_FORM_DATA8 :: 0x07
DW_FORM_DATA16 :: 0x1E
DW_FORM_STRING :: 0x08
DW_FORM_STRP :: 0x0E
DW_FORM_UDATA :: 0x0F
DW_FORM_LINE_STRP :: 0x1F
DW_LNCT_PATH :: 1
DW_LNCT_DIRECTORY_INDEX :: 2

// dwarf_form reads one value of a form: a text, or a number.
dwarf_form :: proc(reader: ^Dwarf_Reader, form: u64, offset_size: int, line_strings, debug_strings: []u8) -> (value_text: string, number: u64, error: string) {
	switch form {
	case DW_FORM_STRING:
		return dwarf_text(reader), 0, ""
	case DW_FORM_STRP, DW_FORM_LINE_STRP:
		offset := dwarf_unsigned(reader, offset_size)
		pool := form == DW_FORM_STRP ? debug_strings : line_strings
		if offset >= u64(len(pool)) {
			return "", 0, "a name of the line program is outside its string section"
		}
		return text_until_zero(pool, offset), 0, ""
	case DW_FORM_DATA1:
		return "", dwarf_unsigned(reader, 1), ""
	case DW_FORM_DATA2:
		return "", dwarf_unsigned(reader, 2), ""
	case DW_FORM_DATA4:
		return "", dwarf_unsigned(reader, 4), ""
	case DW_FORM_DATA8:
		return "", dwarf_unsigned(reader, 8), ""
	case DW_FORM_DATA16:
		dwarf_bytes(reader, 16)
		return "", 0, ""
	case DW_FORM_UDATA:
		return "", dwarf_leb128(reader, false), ""
	case DW_FORM_BLOCK:
		dwarf_bytes(reader, int(min(dwarf_leb128(reader, false), u64(len(reader.bytes)))))
		return "", 0, ""
	}
	return "", 0, fmt.tprintf("the line program has the form 0x%x, which the tool does not read", form)
}

// directory_join gives a directory of a line program as a path: a
// relative directory is under the compilation directory of its unit, and
// an empty one is that directory.
directory_join :: proc(directory, compilation_directory: string) -> string {
	if directory == "" {
		return compilation_directory
	}
	if strings.has_prefix(directory, "/") || compilation_directory == "" {
		return directory
	}
	return join(compilation_directory, "/", directory)
}

// The folder of the Odin installation (`odin root`), read once in a process.
odin_root_folder: string
odin_root_read: bool

odin_root :: proc() -> string {
	if !odin_root_read {
		odin_root_read = true
		command := [?]string{"odin", "root"}
		state, standard_output, _, error := os.process_exec({command = command[:]}, context.temp_allocator)
		if error == nil && state.exited && state.success {
			// Kept for the life of the process, so on the heap: a caller
			// frees the temporary memory between two builds, and the
			// allocator of the context can be the temporary one here.
			odin_root_folder = strings.clone(strings.trim_right(strings.trim_space(string(standard_output)), "/"), runtime.heap_allocator())
		}
	}
	return odin_root_folder
}

// debug_path gives the path of a source file as the debug object keeps it:
// from the root of the repository ("src/programs/fault/main.odin"), or from the
// root of the Odin installation with its library as a prefix
// ("base:runtime/core.odin", "core:..."). A relative path is relative to the
// folder where the compiler ran, the root of the repository. So the debug
// object holds no path of the build host. A path outside the two roots
// stays as it is, and the writer refuses it (debug_object_host_path).
debug_path :: proc(directory, name: string, root: string) -> string {
	path := name
	if !strings.has_prefix(name, "/") && directory != "" {
		path = join(directory, "/", name)
	}
	for strings.has_prefix(path, "./") {
		path = path[2:]
	}
	if root != "" && strings.has_prefix(path, join(root, "/")) {
		return path[len(root) + 1:]
	}
	if compiler := odin_root(); compiler != "" && strings.has_prefix(path, join(compiler, "/")) {
		rest := path[len(compiler) + 1:]
		if slash := strings.index_byte(rest, '/'); slash > 0 {
			return join(rest[:slash], ":", rest[slash + 1:])
		}
		return join("odin:", rest)
	}
	// With no answer of `odin root`: the layout of the installation of the
	// flake, <root>/share/base and <root>/share/core.
	for library in ([]string{"base", "core"}) {
		marker := join("/share/", library, "/")
		if index := strings.last_index(path, marker); index >= 0 {
			return join(library, ":", path[index + len(marker):])
		}
	}
	return path
}

// debug_object_host_path says why a debug object holds a path of the build
// host, or "": an absolute path of a file, or the folder of the build
// anywhere in its bytes. A debug object is an output of the build: the
// same source on another machine, in another folder, gives the same bytes.
debug_object_host_path :: proc(object: []u8) -> string {
	parts, fault := debug_object.tables(object)
	if fault != .None {
		return debug_object.fault_sentences[fault]
	}
	for file in parts.files[min(1, len(parts.files)):] {
		path := debug_object.text_of(parts.strings, file.path_offset, file.path_count)
		if strings.has_prefix(path, "/") {
			return fmt.tprintf("the source file %s has an absolute path: it is in neither the repository nor the Odin installation", path)
		}
		if debug_object.path_has_parent_part(path) {
			return fmt.tprintf("the source file %s has a part \"..\": it leaves the repository, and its path shows the folders of the host", path)
		}
	}
	if root, error := os.get_working_directory(context.temp_allocator); error == nil && len(root) > 1 && strings.contains(string(object), root) {
		return fmt.tprintf("its bytes hold the folder of the build, %s", root)
	}
	return ""
}

// The attributes and the forms of a debugging information entry that
// dwarf_compilation_directories reads (DWARF 5, sections 7.5.4 and 7.5.6).
DW_AT_STMT_LIST :: 0x10
DW_AT_COMP_DIR :: 0x1B
DW_AT_STR_OFFSETS_BASE :: 0x72
DW_FORM_IMPLICIT_CONST :: 0x21

// One attribute of an abbreviation: its name, its form, and the value of
// an implicit constant.
Dwarf_Attribute :: struct {
	name:     u64,
	form:     u64,
	constant: u64,
}

// dwarf_compilation_directories reads the first entry of each unit of
// .debug_info, the compilation unit, and gives its compilation directory
// by the offset of its line program in .debug_line. Each other attribute
// of the entry is skipped by its form.
dwarf_compilation_directories :: proc(units, abbreviations, debug_strings, line_strings, string_offsets: []u8) -> (directories: map[u64]string, error: string) {
	directories = make(map[u64]string, context.temp_allocator)
	reader := Dwarf_Reader{bytes = units}
	for reader.at < len(units) && !reader.failed {
		offset_size := 4
		unit_length := dwarf_unsigned(&reader, 4)
		if unit_length == 0xFFFF_FFFF {
			offset_size = 8
			unit_length = dwarf_unsigned(&reader, 8)
		}
		if unit_length > u64(len(units) - reader.at) {
			return nil, "a unit of .debug_info is longer than its section"
		}
		unit_end := reader.at + int(unit_length)
		unit := Dwarf_Reader{bytes = units[:unit_end], at = reader.at}
		reader.at = unit_end
		version := dwarf_unsigned(&unit, 2)
		abbreviation_offset: u64
		address_size := 8
		if version >= 5 {
			dwarf_unsigned(&unit, 1) // The kind of the unit.
			address_size = int(dwarf_unsigned(&unit, 1))
			abbreviation_offset = dwarf_unsigned(&unit, offset_size)
		} else {
			abbreviation_offset = dwarf_unsigned(&unit, offset_size)
			address_size = int(dwarf_unsigned(&unit, 1))
		}
		code := dwarf_leb128(&unit, false)
		if unit.failed || code == 0 || abbreviation_offset >= u64(len(abbreviations)) {
			continue
		}
		// The abbreviation of the code: its attributes and their forms.
		table := Dwarf_Reader{bytes = abbreviations, at = int(abbreviation_offset)}
		attributes := make([dynamic]Dwarf_Attribute, context.temp_allocator)
		for !table.failed {
			entry_code := dwarf_leb128(&table, false)
			if entry_code == 0 {
				break
			}
			dwarf_leb128(&table, false) // The tag.
			dwarf_unsigned(&table, 1) // Has children.
			clear(&attributes)
			for !table.failed {
				name := dwarf_leb128(&table, false)
				form := dwarf_leb128(&table, false)
				if name == 0 && form == 0 {
					break
				}
				constant := form == DW_FORM_IMPLICIT_CONST ? dwarf_leb128(&table, true) : 0
				append(&attributes, Dwarf_Attribute{name = name, form = form, constant = constant})
			}
			if entry_code == code {
				break
			}
			clear(&attributes)
		}
		// The values of the entry. A string by index (strx) needs the base
		// of the string offsets of the unit, which can come after it.
		line_program_offset := max(u64)
		directory_text := ""
		directory_index := max(u64)
		string_offsets_base := u64(0)
		for attribute in attributes {
			form := attribute.form
			value_text: string
			number: u64
			switch form {
			case 0x01: // An address.
				number = dwarf_unsigned(&unit, address_size)
			case 0x0B, 0x11, 0x25, 0x29: // data1, ref1, strx1, addrx1.
				number = dwarf_unsigned(&unit, 1)
			case 0x05, 0x12, 0x26, 0x2A: // data2, ref2, strx2, addrx2.
				number = dwarf_unsigned(&unit, 2)
			case 0x27, 0x2B: // strx3, addrx3.
				number = dwarf_unsigned(&unit, 3)
			case 0x06, 0x13, 0x1C, 0x28, 0x2C: // data4, ref4, ref_sup4, strx4, addrx4.
				number = dwarf_unsigned(&unit, 4)
			case 0x07, 0x14, 0x20: // data8, ref8, ref_sig8.
				number = dwarf_unsigned(&unit, 8)
			case 0x1E: // data16.
				dwarf_bytes(&unit, 16)
			case 0x0C: // flag.
				number = dwarf_unsigned(&unit, 1)
			case 0x19, DW_FORM_IMPLICIT_CONST: // flag_present, implicit_const.
				number = attribute.constant
			case 0x0D: // sdata.
				number = dwarf_leb128(&unit, true)
			case 0x0F, 0x15, 0x1A, 0x1B, 0x22, 0x23: // udata, ref_udata, strx, addrx, loclistx, rnglistx.
				number = dwarf_leb128(&unit, false)
			case 0x10, 0x17, 0x1D: // ref_addr, sec_offset, strp_sup.
				number = dwarf_unsigned(&unit, offset_size)
			case 0x0E: // strp.
				value_text = text_until_zero(debug_strings, dwarf_unsigned(&unit, offset_size))
			case 0x1F: // line_strp.
				value_text = text_until_zero(line_strings, dwarf_unsigned(&unit, offset_size))
			case 0x08: // string.
				value_text = dwarf_text(&unit)
			case 0x18, 0x09: // exprloc, block.
				dwarf_bytes(&unit, int(min(dwarf_leb128(&unit, false), u64(len(units)))))
			case 0x0A: // block1.
				dwarf_bytes(&unit, int(dwarf_unsigned(&unit, 1)))
			case 0x03: // block2.
				dwarf_bytes(&unit, int(dwarf_unsigned(&unit, 2)))
			case 0x04: // block4.
				dwarf_bytes(&unit, int(dwarf_unsigned(&unit, 4)))
			case:
				return nil, fmt.tprintf("a compilation unit has an attribute of the form 0x%x, which the tool does not read", form)
			}
			switch attribute.name {
			case DW_AT_STMT_LIST:
				line_program_offset = number
			case DW_AT_STR_OFFSETS_BASE:
				string_offsets_base = number
			case DW_AT_COMP_DIR:
				switch form {
				case 0x0E, 0x1F, 0x08:
					directory_text = value_text
				case 0x1A, 0x25, 0x26, 0x27, 0x28:
					directory_index = number
				case:
					return nil, fmt.tprintf("a compilation directory has the form 0x%x, which the tool does not read", form)
				}
			}
		}
		if unit.failed {
			return nil, "a compilation unit of .debug_info is cut"
		}
		if directory_index != max(u64) {
			at := string_offsets_base + directory_index * u64(offset_size)
			if at > u64(len(string_offsets)) || u64(offset_size) > u64(len(string_offsets)) - at {
				return nil, "the compilation directory names a string offset outside .debug_str_offsets"
			}
			offset_reader := Dwarf_Reader{bytes = string_offsets, at = int(at)}
			directory_text = text_until_zero(debug_strings, dwarf_unsigned(&offset_reader, offset_size))
		}
		if line_program_offset != max(u64) {
			directories[line_program_offset] = directory_text
		}
	}
	if reader.failed {
		return nil, "the section .debug_info is cut"
	}
	return directories, ""
}

// dwarf_line_rows runs each line program of .debug_line (DWARF 2 to 5,
// section 6.2 of DWARF 5) and gives its rows inside the code, sorted by
// their address. A sequence whose start is outside the code is a function
// that the link dropped (--gc-sections): its rows go.
dwarf_line_rows :: proc(section, line_strings, debug_strings: []u8, compilation_directories: map[u64]string, code_start, code_end: u64) -> (line_rows: []Debug_Row, host_paths: map[string]string, error: string) {
	root, _ := os.get_working_directory(context.temp_allocator)
	// Where each file of the rows is on the build host, by its path in
	// the debug object: the tool hashes the content of each one.
	host_paths = make(map[string]string, context.temp_allocator)
	all := make([dynamic]Debug_Row, context.temp_allocator)
	sequence := make([dynamic]Debug_Row, context.temp_allocator)
	reader := Dwarf_Reader{bytes = section}
	// The place of each row in the whole section: equal addresses keep the last row.
	order := 0
	for reader.at < len(section) && !reader.failed {
		compilation_directory := compilation_directories[u64(reader.at)]
		offset_size := 4
		unit_length := dwarf_unsigned(&reader, 4)
		if unit_length == 0xFFFF_FFFF {
			offset_size = 8
			unit_length = dwarf_unsigned(&reader, 8)
		}
		if unit_length > u64(len(section) - reader.at) {
			return nil, nil, "a unit of the line program is longer than its section"
		}
		unit_end := reader.at + int(unit_length)
		unit := Dwarf_Reader{bytes = section[:unit_end], at = reader.at}
		reader.at = unit_end
		version := dwarf_unsigned(&unit, 2)
		if version < 2 || version > 5 {
			return nil, nil, fmt.tprintf("a line program has the version %d of DWARF; the tool reads 2 to 5", version)
		}
		address_size := 8
		if version >= 5 {
			address_size = int(dwarf_unsigned(&unit, 1))
			dwarf_unsigned(&unit, 1) // The size of a segment selector.
		}
		header_length := dwarf_unsigned(&unit, offset_size)
		if header_length > u64(unit_end - unit.at) {
			return nil, nil, "the header of a line program is longer than its unit"
		}
		program_start := unit.at + int(header_length)
		minimum_instruction_length := dwarf_unsigned(&unit, 1)
		if version >= 4 {
			dwarf_unsigned(&unit, 1) // The operations of one instruction: 1 on x86-64.
		}
		dwarf_unsigned(&unit, 1) // The statement flag of a new row: each row is kept.
		line_base := i64(i8(dwarf_unsigned(&unit, 1)))
		line_range := dwarf_unsigned(&unit, 1)
		opcode_base := dwarf_unsigned(&unit, 1)
		if line_range == 0 || opcode_base == 0 {
			return nil, nil, "a line program has a line range or an opcode base of 0"
		}
		standard_lengths := dwarf_bytes(&unit, int(opcode_base) - 1)
		directories := make([dynamic]string, context.temp_allocator)
		files := make([dynamic]string, context.temp_allocator)
		if version < 5 {
			// The directory 0 is the compilation directory of the unit,
			// which only .debug_info names; the file 0 is not used.
			append(&directories, compilation_directory)
			for {
				name := dwarf_text(&unit)
				if name == "" || unit.failed {
					break
				}
				append(&directories, directory_join(name, compilation_directory))
			}
			append(&files, "")
			for {
				name := dwarf_text(&unit)
				if name == "" || unit.failed {
					break
				}
				directory := dwarf_leb128(&unit, false)
				dwarf_leb128(&unit, false) // The time of its last change.
				dwarf_leb128(&unit, false) // Its size.
				directory_of_file := directory < u64(len(directories)) ? directories[directory] : ""
				recorded := debug_path(directory_of_file, name, root)
				host_paths[recorded] = debug_host_path(directory_of_file, name)
				append(&files, recorded)
			}
		} else {
			for list in 0 ..< 2 {
				format_count := int(dwarf_unsigned(&unit, 1))
				formats := make([dynamic][2]u64, context.temp_allocator)
				for _ in 0 ..< format_count {
					content := dwarf_leb128(&unit, false)
					form := dwarf_leb128(&unit, false)
					append(&formats, [2]u64{content, form})
				}
				count := dwarf_leb128(&unit, false)
				if count > u64(unit_end) {
					return nil, nil, "a line program names more entries than its bytes hold"
				}
				for _ in 0 ..< count {
					name: string
					directory: u64
					for format in formats {
						form_text, number, form_error := dwarf_form(&unit, format[1], offset_size, line_strings, debug_strings)
						if form_error != "" {
							return nil, nil, form_error
						}
						switch format[0] {
						case DW_LNCT_PATH:
							name = form_text
						case DW_LNCT_DIRECTORY_INDEX:
							directory = number
						}
					}
					if list == 0 {
						// The directory 0 is the compilation directory itself;
						// a relative directory is under it.
						append(&directories, len(directories) == 0 ? directory_join(name, compilation_directory) : directory_join(name, directories[0]))
					} else {
						directory_of_file := directory < u64(len(directories)) ? directories[directory] : ""
						recorded := debug_path(directory_of_file, name, root)
						host_paths[recorded] = debug_host_path(directory_of_file, name)
						append(&files, recorded)
					}
				}
			}
		}
		if unit.failed {
			return nil, nil, "the header of a line program is cut"
		}
		// The state machine of the line program.
		unit.at = program_start
		address: u64
		file: u64 = 1
		line: i64 = 1
		clear(&sequence)
		for unit.at < unit_end && !unit.failed {
			opcode := dwarf_unsigned(&unit, 1)
			switch {
			case opcode >= opcode_base:
				adjusted := opcode - opcode_base
				address += adjusted / line_range * minimum_instruction_length
				line += line_base + i64(adjusted % line_range)
				dwarf_row_emit(&sequence, files[:], address, file, line, &order, false)
			case opcode == 0:
				length := dwarf_leb128(&unit, false)
				if length == 0 || length > u64(unit_end - unit.at) {
					return nil, nil, "an extended operation of a line program is longer than its unit"
				}
				next := unit.at + int(length)
				switch dwarf_unsigned(&unit, 1) {
				case 1: // The end of a sequence.
					dwarf_row_emit(&sequence, files[:], address, file, line, &order, true)
					// A sequence that the link dropped starts at an address
					// outside the code (0, or the value that the linker
					// writes for a dropped section).
					if len(sequence) > 0 && sequence[0].address >= code_start && sequence[0].address < code_end {
						append(&all, ..sequence[:])
					}
					clear(&sequence)
					address, file, line = 0, 1, 1
				case 2: // Set the address.
					address = dwarf_unsigned(&unit, address_size)
				}
				unit.at = next
			case opcode == 1: // Copy.
				dwarf_row_emit(&sequence, files[:], address, file, line, &order, false)
			case opcode == 2: // Advance the address.
				address += dwarf_leb128(&unit, false) * minimum_instruction_length
			case opcode == 3: // Advance the line.
				line += i64(dwarf_leb128(&unit, true))
			case opcode == 4: // Set the file.
				file = dwarf_leb128(&unit, false)
			case opcode == 8: // Add the address of the special operation 255.
				address += (255 - opcode_base) / line_range * minimum_instruction_length
			case opcode == 9: // Advance the address by a fixed size.
				address += dwarf_unsigned(&unit, 2)
			case:
				// An operation with operands that the rows do not need (set the
				// column, negate the statement flag, the prologue, the ISA):
				// its operands are LEB128 numbers, as the header counts them.
				if int(opcode) - 1 < len(standard_lengths) {
					for _ in 0 ..< standard_lengths[opcode - 1] {
						dwarf_leb128(&unit, false)
					}
				}
			}
		}
		if unit.failed {
			return nil, nil, "a line program is cut"
		}
	}
	if reader.failed {
		return nil, nil, "the line section is cut"
	}
	// By address; at one address, the end of a sequence first, then the
	// rows in their order: the last row at an address describes it, and a
	// sequence that starts where another ends replaces its end.
	slice.sort_by(all[:], proc(a, b: Debug_Row) -> bool {
		if a.address != b.address {
			return a.address < b.address
		}
		return a.order < b.order
	})
	kept := make([dynamic]Debug_Row, context.temp_allocator)
	for row in all {
		if len(kept) > 0 && kept[len(kept) - 1].address == row.address {
			// A row with no file never replaces a row with a file at its address.
			if row.path != "" || kept[len(kept) - 1].path == "" {
				kept[len(kept) - 1] = row
			}
			continue
		}
		// Two rows of one place in a row are one row.
		if len(kept) > 0 && kept[len(kept) - 1].path == row.path && kept[len(kept) - 1].line == row.line {
			continue
		}
		append(&kept, row)
	}
	return kept[:], host_paths, ""
}

// dwarf_row_emit adds one row to a sequence: the path of its file, or no
// path for the end of the sequence. A row of the line 0 (an instruction
// that the optimizer merged from two lines, or made with no line) adds
// nothing: its instruction keeps the line of the row before it. Such rows
// split a run of one line into three rows, and a stack trace and a
// breakpoint by line need the line where the run starts, not them.
dwarf_row_emit :: proc(sequence: ^[dynamic]Debug_Row, files: []string, address: u64, file: u64, line: i64, order: ^int, end: bool) {
	if !end && line <= 0 {
		return
	}
	path := ""
	if !end && file < u64(len(files)) {
		path = files[file]
	}
	append(sequence, Debug_Row{address = address, path = path, line = path == "" ? 0 : u32(min(line, i64(max(u32)))), order = order^})
	order^ += 1
}

// text_until_zero gives the bytes from an offset up to the first zero
// byte, inside the slice: "" when the offset is outside it.
text_until_zero :: proc(bytes: []u8, offset: u64) -> string {
	if offset >= u64(len(bytes)) {
		return ""
	}
	end := offset
	for end < u64(len(bytes)) && bytes[end] != 0 {
		end += 1
	}
	return string(bytes[offset:end])
}

// debug_image_write writes the debug image: the debug object of each module
// of the table, in the form of a boot image, each one named after its
// module. It prints its size: the boot program reads it at each start.
debug_image_write :: proc() -> bool {
	files := make([dynamic]Image_File, context.temp_allocator)
	procedures, rows, types, globals, variables, ranges := 0, 0, 0, 0, 0, 0
	for build in module_builds {
		object := read_file(debug_object_path(build.name)) or_return
		parts, fault := debug_object.tables(object)
		if fault != .None {
			fmt.eprintfln("kerneltool: the debug object of %s: %s", build.name, debug_object.fault_sentences[fault])
			return false
		}
		procedures += len(parts.procedures)
		rows += len(parts.lines)
		types += len(parts.types) - min(1, len(parts.types))
		globals += len(parts.globals)
		variables += len(parts.variables)
		ranges += len(parts.ranges)
		append(&files, Image_File{name = build.name, file = object})
	}
	image := boot_image_encode(files[:], len(files))
	if err := os.write_entire_file(DEBUG_IMAGE, image); err != nil {
		fmt.eprintfln("kerneltool: cannot write %s: %v", DEBUG_IMAGE, err)
		return false
	}
	fmt.printfln("kerneltool: the debug image has %d debug objects, %d procedures, %d rows of lines, %d types, %d global variables and %d variables in %d ranges: %d bytes", len(files), procedures, rows, types, globals, variables, ranges, len(image))
	return true
}
