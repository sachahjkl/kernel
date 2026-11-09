package system

import info "../boot_info"
import op "../kernel/operation"
import module "../module"
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

// program_start builds and starts a program from a module file.
//   handles: the grants. Each handle that is not 0 is copied to the program;
//            the context of the program has the copy at the same index.
//   values, text: copied to the context.
program_start :: proc "contextless" (file: []u8, name: string, handles: [op.CONTEXT_HANDLES]Handle, values: [op.CONTEXT_VALUES]u64, text: string) -> (program: Handle, status: Status) {
	if len(file) == 0 || module.validate(file) != .None || module.count(file, .Imports) > 1 {
		return 0, .Bad_Operation
	}
	head, _ := module.header(file)
	entry, has_entry := module.export_address(file, op.PROGRAM_BASE, head.entry_export)
	if !has_entry {
		return 0, .Bad_Operation
	}

	results: [7]u64
	results, status = call(.Program_Create, u64(uintptr(raw_data(name))), u64(len(name)))
	if status != .Ok {
		return 0, status
	}
	program = Handle(results[0])
	if status = program_fill(program, file, head, handles, values, text); status == .Ok {
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
program_fill :: proc "contextless" (program: Handle, file: []u8, head: module.Header, handles: [op.CONTEXT_HANDLES]Handle, values: [op.CONTEXT_VALUES]u64, text: string) -> Status {
	// The module: copy and rebase here, then map each segment in the program.
	code := memory_create(head.memory_size / PAGE_SIZE) or_return
	defer close(code)
	{
		address := memory_map(code) or_return
		defer memory_unmap(address)
		memory := ([^]u8)(address)[:head.memory_size]
		module.copy_segments(file, memory)
		if module.rebase(file, memory, op.PROGRAM_BASE) != .None {
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
		memory_map(code, flags, program, op.PROGRAM_BASE + segment.memory_offset, segment.memory_offset / PAGE_SIZE, segment.memory_size / PAGE_SIZE) or_return
	}

	stack := memory_create(op.STACK_PAGES) or_return
	defer close(stack)
	memory_map(stack, {.Write}, program, op.STACK_TOP - op.STACK_PAGES * PAGE_SIZE) or_return

	record_memory := memory_create(1) or_return
	defer close(record_memory)
	record := (^op.Context)(memory_map(record_memory) or_return)
	defer memory_unmap(record)
	for handle, index in handles {
		if handle != 0 {
			record.handles[index] = give(program, handle) or_return
		}
	}
	record.values = values
	record.text_count = u64(min(len(text), op.CONTEXT_TEXT))
	intrinsics.mem_copy_non_overlapping(&record.text, raw_data(text), int(record.text_count))
	memory_map(record_memory, {.Write}, program, op.CONTEXT_ADDRESS) or_return
	return .Ok
}

// program_state gives the state of a program, and its code when it stopped.
program_state :: proc "contextless" (program: Handle) -> (state: op.Program_State, code: u32) {
	results, _ := call(.Program_State, u64(program))
	return op.Program_State(results[0]), u32(results[1])
}
