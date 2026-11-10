package system

import info "contract:boot_info"
import op "contract:operation"
import module "contract:module"
import "contract:blake3"
import "base:intrinsics"

// The loader (docs/ARCHITECTURE.md, U3): it builds a program from a module.
// It runs in user space. The kernel only creates the empty program and maps
// memory.

// image_entries gives the entries of the boot image.
image_entries :: proc "contextless" (image: []u8) -> []info.Image_Entry {
	if len(image) < size_of(info.Image_Header) {
		return nil
	}
	header := (^info.Image_Header)(raw_data(image))
	if header.magic != info.IMAGE_MAGIC || size_of(info.Image_Header) + int(header.count) * size_of(info.Image_Entry) > len(image) {
		return nil
	}
	return ([^]info.Image_Entry)(raw_data(image[size_of(info.Image_Header):]))[:header.count]
}

// image_find gives the module file with this name. The result is empty when
// the image has no such module.
image_find :: proc "contextless" (image: []u8, name: string) -> []u8 {
	for &entry in image_entries(image) {
		if name_of(entry.name[:]) == name && entry.offset <= u64(len(image)) && entry.size <= u64(len(image)) - entry.offset {
			return image[entry.offset:][:entry.size]
		}
	}
	return nil
}

// A grant: a handle that a new program receives, and the rights of its copy.
Grant :: struct {
	handle: Handle,
	rights: Rights,
}

// A part of a memory object at an address of a program.
Mapping :: struct {
	memory:     Handle,
	address:    u64,
	first:      u64, // The first page of the memory object.
	page_count: u64, // 0: all pages from first.
	flags:      op.Map_Flags,
}

PREPARED_CAPACITY :: 32

// A prepared module: a memory object that holds a module as the loader
// prepared it, its segments copied from the file and rebased at
// PROGRAM_BASE. Each program that runs the module maps the pages that do
// not change (the code and the constants: the shared code of the module),
// and receives its own copy of the writable pages. The loader writes the
// memory object one time; after that, the table holds it with the rights
// Read and Execute only, so no program writes it.
Prepared :: struct {
	hash:   [32]u8, // The hash of the module file.
	memory: Handle, // 0: the place is free.
	pages:  u64,
}

// The prepared modules of a program that starts programs. The zero value is
// an empty table. The budget of the program that owns the table pays for
// each prepared module. A prepared module stays while a program maps it:
// each start closes the ones that no program maps.
Prepared_Modules :: struct {
	lock:    Lock,
	modules: [PREPARED_CAPACITY]Prepared,
}

// program_start builds and starts a program from a module file.
//   grants:  each handle that is not 0 is copied to the program with the
//            rights of the grant; the context of the program has the copy
//            at the same index.
//            The index CONTEXT_BUDGET must be 0: the program receives its
//            new budget there.
//   values:   copied to the context.
//   amounts:  the budget of the program. It comes from the budget of this
//             program. It pays for the program and for all that the loader
//             creates. When the program stops, what remains returns.
//   mappings: memory that the program has from its start, with no handle to
//             it: the program cannot map it again with other flags.
//   prepared: not nil: the program maps the shared code of its module from
//             this table, and the table keeps the prepared module for the
//             next program of the same module. nil: the program has its own
//             copy of all the module, and its budget pays for it.
// The program stops when the last handle to it closes.
program_start :: proc "contextless" (file: []u8, name: string, grants: [op.CONTEXT_HANDLES]Grant, values: [op.CONTEXT_VALUES]u64, amounts: Budget_Amounts, mappings: []Mapping = nil, prepared: ^Prepared_Modules = nil) -> (program: Handle, status: Status) {
	if len(file) == 0 || module.validate(file) != .None || module.count(file, .Imports) > 1 || grants[op.CONTEXT_BUDGET].handle != 0 {
		return 0, .Bad_Operation
	}
	head, _ := module.header(file)
	entry, has_entry := module.export_address(file, op.PROGRAM_BASE, head.entry_export)
	if !has_entry {
		return 0, .Bad_Operation
	}

	// The program holds the one handle to its budget: when the program
	// stops, the budget ends.
	budget: Handle
	budget, status = budget_create(amounts)
	if status != .Ok {
		return 0, status
	}
	defer close(budget)
	results: [7]u64
	results, status = call(.Program_Create, u64(budget), u64(uintptr(raw_data(name))), u64(len(name)))
	if status != .Ok {
		return 0, status
	}
	program = Handle(results[0])
	if status = program_fill(program, budget, file, head, grants, values, mappings, prepared); status == .Ok {
		_, status = call(.Program_Start, u64(program), u64(entry), op.STACK_TOP, op.CONTEXT_ADDRESS)
	}
	if status != .Ok {
		call(.Program_Stop, u64(program), 0)
		close(program)
		return 0, status
	}
	return program, .Ok
}

@(private)
program_fill :: proc "contextless" (program: Handle, budget: Handle, file: []u8, head: module.Header, grants: [op.CONTEXT_HANDLES]Grant, values: [op.CONTEXT_VALUES]u64, mappings: []Mapping, prepared: ^Prepared_Modules) -> Status {
	module_map(file, head, program, op.PROGRAM_BASE, budget, prepared) or_return
	for mapping in mappings {
		memory_map(mapping.memory, mapping.flags, program, mapping.address, mapping.first, mapping.page_count) or_return
	}

	stack := memory_create(op.STACK_PAGES, budget) or_return
	defer close(stack)
	memory_map(stack, {.Write}, program, op.STACK_TOP - op.STACK_PAGES * PAGE_SIZE) or_return

	record_memory := memory_create(1, budget) or_return
	defer close(record_memory)
	record := (^op.Context)(memory_map(record_memory) or_return)
	defer memory_unmap(record)
	for grant, index in grants {
		if grant.handle != 0 {
			record.handles[index] = give(program, grant.handle, grant.rights) or_return
		}
	}
	record.handles[op.CONTEXT_BUDGET] = give(program, budget, {.Give, .Read, .Spend}) or_return
	record.values = values
	memory_map(record_memory, {.Write}, program, op.CONTEXT_ADDRESS) or_return
	return .Ok
}

// module_map puts a module in a program at base. With a table of prepared
// modules, the program maps the shared code of the module from the table,
// and receives its own copy of each writable segment. With no table, the
// program maps a prepared module of its own, all of it, and its budget pays
// for it. The caller validates the file first.
@(private)
module_map :: proc "contextless" (file: []u8, head: module.Header, program: Handle, base: u64, budget: Handle, prepared: ^Prepared_Modules = nil) -> Status {
	if prepared == nil {
		memory := module_prepare(file, head.memory_size / PAGE_SIZE, base, budget) or_return
		defer close(memory)
		return segments_map(file, memory, program, base, budget, false)
	}
	lock(&prepared.lock)
	defer unlock(&prepared.lock)
	memory := prepared_find(prepared, file, base) or_return
	return segments_map(file, memory, program, base, budget, true)
}

// segment_flags gives the protection of a segment in a program.
@(private)
segment_flags :: proc "contextless" (segment: module.Segment) -> (flags: op.Map_Flags) {
	if .Write in segment.flags && .Read_Only_After_Load not_in segment.flags {
		flags += {.Write}
	}
	if .Execute in segment.flags {
		flags += {.Execute}
	}
	return flags
}

// shared_pages gives the pages of a module up to the end of its last
// segment that does not change after the load: the pages of a prepared
// module in a table.
@(private)
shared_pages :: proc "contextless" (file: []u8) -> (pages: u64) {
	for index in 1 ..< module.count(file, .Segments) {
		segment, _ := module.record(file, .Segments, index, module.Segment)
		if .Write not_in segment_flags(segment) {
			pages = max(pages, (segment.memory_offset + segment.memory_size) / PAGE_SIZE)
		}
	}
	return pages
}

// module_prepare makes a memory object of `pages` pages with the module as
// it runs at base: the segments in these pages copied from the file, and
// rebased. The budget pays for it.
@(private)
module_prepare :: proc "contextless" (file: []u8, pages: u64, base: u64, budget: Handle) -> (memory: Handle, status: Status) {
	memory = memory_create(pages, budget) or_return
	address: rawptr
	if address, status = memory_map(memory); status != .Ok {
		close(memory)
		return 0, status
	}
	size := pages * PAGE_SIZE
	head, _ := module.header(file)
	// The view has the size of the module, so that an offset of the module
	// is an index; only the first `size` bytes are memory.
	view := ([^]u8)(address)[:head.memory_size]
	for index in 1 ..< module.count(file, .Segments) {
		segment, _ := module.record(file, .Segments, index, module.Segment)
		if segment.file_size != 0 && segment.memory_offset + segment.memory_size <= size {
			intrinsics.mem_copy_non_overlapping(&view[segment.memory_offset], &file[segment.file_offset], int(segment.file_size))
		}
	}
	rebased := module.rebase_range(file, view, uintptr(base), 0, size)
	memory_unmap(address)
	if rebased != .None {
		close(memory)
		return 0, .Bad_Operation
	}
	return memory, .Ok
}

// prepared_find gives the prepared module of a file from a table, and
// prepares it if the table does not have it. It closes each prepared module
// that no program maps: the count of the holdings of its handle is 0.
@(private)
prepared_find :: proc "contextless" (table: ^Prepared_Modules, file: []u8, base: u64) -> (memory: Handle, status: Status) {
	hash := blake3.hash(file)
	free: ^Prepared
	for &item in table.modules {
		if item.memory != 0 && item.hash == hash {
			return item.memory, .Ok
		}
		if item.memory != 0 && handle_holdings(item.memory) == 0 {
			close(item.memory)
			item = {}
		}
		if item.memory == 0 && free == nil {
			free = &item
		}
	}
	if free == nil {
		return 0, .No_Slot
	}
	pages := shared_pages(file)
	written := module_prepare(file, pages, base, 0) or_return
	defer close(written)
	// After the preparation, nobody writes the module: the table keeps a
	// handle without Write, and closes the one that wrote.
	memory = give(0, written, {.Read, .Execute}) or_return
	free^ = {hash = hash, memory = memory, pages = pages}
	return memory, .Ok
}

// segments_map maps each segment of a prepared module in a program, with
// the protection of the segment. With copy, a writable segment is a new
// memory object that the budget pays for, with the bytes of the file,
// rebased: the program does not write the prepared module.
@(private)
segments_map :: proc "contextless" (file: []u8, memory: Handle, program: Handle, base: u64, budget: Handle, copy: bool) -> Status {
	for index in 1 ..< module.count(file, .Segments) {
		segment, _ := module.record(file, .Segments, index, module.Segment)
		flags := segment_flags(segment)
		if .Write in flags && copy {
			own := segment_copy(file, segment, base, budget) or_return
			_, status := memory_map(own, flags, program, base + segment.memory_offset)
			close(own)
			if status != .Ok {
				return status
			}
		} else {
			memory_map(memory, flags, program, base + segment.memory_offset, segment.memory_offset / PAGE_SIZE, segment.memory_size / PAGE_SIZE) or_return
		}
	}
	return .Ok
}

// segment_copy makes the memory of one writable segment for one program:
// the bytes of the file, rebased. The pages that the copy does not write
// stay pages on first use.
@(private)
segment_copy :: proc "contextless" (file: []u8, segment: module.Segment, base: u64, budget: Handle) -> (memory: Handle, status: Status) {
	memory = memory_create(segment.memory_size / PAGE_SIZE, budget) or_return
	address: rawptr
	if address, status = memory_map(memory); status != .Ok {
		close(memory)
		return 0, status
	}
	end := segment.memory_offset + segment.memory_size
	// The view starts where the module would start: an offset of the
	// module is an index, and only the segment is memory.
	view := ([^]u8)(uintptr(address) - uintptr(segment.memory_offset))[:end]
	if segment.file_size != 0 {
		intrinsics.mem_copy_non_overlapping(&view[segment.memory_offset], &file[segment.file_offset], int(segment.file_size))
	}
	rebased := module.rebase_range(file, view, uintptr(base), segment.memory_offset, end)
	memory_unmap(address)
	if rebased != .None {
		close(memory)
		return 0, .Bad_Operation
	}
	return memory, .Ok
}

// module_load loads a module with no imports in this program, at base.
// The caller then calls its exports at module.export_address(file, base, n).
// size is the size of the address range that the module uses.
module_load :: proc "contextless" (file: []u8, base: u64) -> (size: u64, status: Status) {
	if len(file) == 0 || module.validate(file) != .None || module.count(file, .Imports) > 1 {
		return 0, .Bad_Operation
	}
	head, _ := module.header(file)
	module_map(file, head, 0, base, 0) or_return
	return head.memory_size, .Ok
}

// module_unload removes from this program a module that module_load put at
// base. The caller calls no export of the module after this.
module_unload :: proc "contextless" (file: []u8, base: u64) {
	for index in 1 ..< module.count(file, .Segments) {
		segment, _ := module.record(file, .Segments, index, module.Segment)
		memory_unmap(rawptr(uintptr(base + segment.memory_offset)))
	}
}

// program_entries gives the count of kernel entries of a program, from its
// start. The handle needs the right Read.
program_entries :: proc "contextless" (program: Handle) -> u64 {
	results, _ := call(.Program_State, u64(program))
	return results[2]
}

// program_state gives the state of a program, and its code when it stopped.
program_state :: proc "contextless" (program: Handle) -> (state: op.Program_State, code: u32) {
	results, _ := call(.Program_State, u64(program))
	return op.Program_State(results[0]), u32(results[1])
}
