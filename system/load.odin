package system

import info "../boot_info"
import op "../kernel/operation"
import module "../module"

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
// The program stops when the last handle to it closes.
program_start :: proc "contextless" (file: []u8, name: string, grants: [op.CONTEXT_HANDLES]Grant, values: [op.CONTEXT_VALUES]u64, amounts: Budget_Amounts, mappings: []Mapping = nil) -> (program: Handle, status: Status) {
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
	if status = program_fill(program, budget, file, head, grants, values, mappings); status == .Ok {
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
program_fill :: proc "contextless" (program: Handle, budget: Handle, file: []u8, head: module.Header, grants: [op.CONTEXT_HANDLES]Grant, values: [op.CONTEXT_VALUES]u64, mappings: []Mapping) -> Status {
	module_map(file, head, program, op.PROGRAM_BASE, budget) or_return
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

// module_map puts a module in a program at base: copy and rebase here, then
// map each segment in the program with the protection of the segment.
// The caller validates the file first.
@(private)
module_map :: proc "contextless" (file: []u8, head: module.Header, program: Handle, base: u64, budget: Handle) -> Status {
	code := memory_create(head.memory_size / PAGE_SIZE, budget) or_return
	defer close(code)
	{
		address := memory_map(code) or_return
		defer memory_unmap(address)
		memory := ([^]u8)(address)[:head.memory_size]
		module.copy_segments(file, memory)
		if module.rebase(file, memory, uintptr(base)) != .None {
			return .Bad_Operation
		}
	}
	for index in 1 ..< module.count(file, .Segments) {
		segment, _ := module.record(file, .Segments, index, module.Segment)
		flags: op.Map_Flags
		if .Write in segment.flags && .Read_Only_After_Load not_in segment.flags {
			flags += {.Write}
		}
		if .Execute in segment.flags {
			flags += {.Execute}
		}
		memory_map(code, flags, program, base + segment.memory_offset, segment.memory_offset / PAGE_SIZE, segment.memory_size / PAGE_SIZE) or_return
	}
	return .Ok
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

// program_state gives the state of a program, and its code when it stopped.
program_state :: proc "contextless" (program: Handle) -> (state: op.Program_State, code: u32) {
	results, _ := call(.Program_State, u64(program))
	return op.Program_State(results[0]), u32(results[1])
}
