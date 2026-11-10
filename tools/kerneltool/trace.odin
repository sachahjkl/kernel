package kerneltool

import "core:fmt"
import "core:mem"
import "core:strconv"
import "core:strings"

// The names of the functions of a stack trace. The system gives a frame as
// "module + offset" (docs/MODULE_CONTRACT.md, section 8): the module names
// its exports only, and the names of its other functions are debug
// information. The tool has that information: the linked file of the
// module, where the offset of the module is the address.

ELF_SECTION_SYMBOLS :: 2

// function_at gives the name of the function of a linked file that holds an
// address. "" when no function symbol holds it.
function_at :: proc(elf: []u8, address: u64) -> string {
	if len(elf) < size_of(Elf_Header) {
		return ""
	}
	header: Elf_Header
	mem.copy(&header, raw_data(elf), size_of(header))
	section :: proc(elf: []u8, header: Elf_Header, index: u64) -> (item: Elf_Section_Header, ok: bool) {
		at := header.section_header_offset + index * size_of(Elf_Section_Header)
		if index >= u64(header.section_header_count) || at + size_of(Elf_Section_Header) > u64(len(elf)) {
			return {}, false
		}
		mem.copy(&item, raw_data(elf[at:]), size_of(item))
		return item, true
	}
	for index in 0 ..< u64(header.section_header_count) {
		symbols, ok := section(elf, header, index)
		if !ok || symbols.type != ELF_SECTION_SYMBOLS || symbols.offset + symbols.size > u64(len(elf)) {
			continue
		}
		names, has_names := section(elf, header, u64(symbols.link))
		if !has_names || names.offset + names.size > u64(len(elf)) {
			continue
		}
		for at := symbols.offset; at + size_of(Elf_Symbol) <= symbols.offset + symbols.size; at += size_of(Elf_Symbol) {
			symbol: Elf_Symbol
			mem.copy(&symbol, raw_data(elf[at:]), size_of(symbol))
			if symbol.info & 0xF != ELF_SYMBOL_FUNCTION || address < symbol.value || address - symbol.value >= max(symbol.size, 1) || u64(symbol.name) >= names.size {
				continue
			}
			text := elf[names.offset + u64(symbol.name):names.offset + names.size]
			end := 0
			for end < len(text) && text[end] != 0 {
				end += 1
			}
			return string(text[:end])
		}
	}
	return ""
}

// trace_check reads a stack trace on a line of the log, after `text`:
// frames "module + 0xOFFSET" separated by ", ". It names the function of
// each frame from the linked file of the module, and compares the names
// with `names` (separated by spaces), from frame 0. A return address is the
// instruction after the call: the tool names the address before it.
trace_check :: proc(line: string, names: string) -> (found: string, ok: bool) {
	context.allocator = context.temp_allocator
	list := make([dynamic]string)
	frames := strings.split(strings.trim_space(line), ", ")
	for frame, number in frames {
		parts := strings.split(frame, " + 0x")
		if len(parts) != 2 {
			return fmt.tprintf("the frame \"%s\" has no form \"module + 0xOFFSET\"", frame), false
		}
		offset, parsed := strconv.parse_u64_of_base(parts[1], 16)
		if !parsed {
			return fmt.tprintf("the frame \"%s\" has no offset", frame), false
		}
		elf, read := read_file(join(MODULE_BUILD_FOLDER, "/", parts[0], "/linked.elf"))
		if !read {
			return fmt.tprintf("no linked file of the module %s", parts[0]), false
		}
		name := function_at(elf, number == 0 ? offset : offset - 1)
		append(&list, name == "" ? "?" : name)
	}
	found = strings.join(list[:], " ")
	return found, strings.has_prefix(found, names)
}
