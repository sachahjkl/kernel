package system

import "base:intrinsics"
import "contract:blake3"
import info "contract:boot_info"
import op "contract:operation"
import module "contract:module"

// The loader (docs/ARCHITECTURE.md, U3): it builds a program from a module
// and its imports. It runs in user space. The kernel only creates the empty
// program and maps memory.

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

// image_entry_of gives the entry that names a hash, or nil. The entry is
// what the image says: the caller checks the hash of the file.
image_entry_of :: proc "contextless" (image: []u8, hash: [32]u8) -> ^info.Image_Entry {
	for &entry in image_entries(image) {
		if entry.hash == hash && entry.offset <= u64(len(image)) && entry.size <= u64(len(image)) - entry.offset {
			return &entry
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
	hash:    [32]u8, // The hash of the module file.
	base:    u64, // The address of the module in each program that maps it.
	binding: [32]u8, // What its slots hold (binding_of): zero for a module with no import.
	memory:  Handle, // 0: the place is free.
	pages:   u64,
}

// The prepared modules of a program that starts programs. The zero value is
// an empty table. The budget of the program that owns the table pays for
// each prepared module. A prepared module stays while a program maps it:
// each start closes the ones that no program maps.
Prepared_Modules :: struct {
	lock:    Lock,
	modules: [PREPARED_CAPACITY]Prepared,
}

// The load source: where a loader finds the imports of a module. Nothing
// else: the loader has no search path and no ambient module store
// (property 20).
Load_Source :: struct {
	image: []u8, // The files that the program was granted, in the form of the boot image. A file has the hash that names it, or the loader refuses it.
}

// Why a load failed.
Load_Error :: enum u32 {
	None           = 0,
	Bad_Module     = 1, // The file is not a valid module, or it does not have its hash.
	Missing_Module = 2, // The load source has no file with the hash of an import.
	No_Room        = 3, // The space has no place for one more module.
	Kernel         = 4, // A kernel operation failed: see status.
}

Load_Failure :: struct {
	error:  Load_Error,
	status: Status, // Kernel: the status of the operation.
	hash:   [32]u8, // The module of the failure: the missing one, or the bad one.
}

MODULE_SPACE_CAPACITY :: 16 // The modules of one program.
IMPORT_CAPACITY :: 8 // The imports of one module that this loader binds.

// One module that a loader put in a program: a place of a module space.
Placed :: struct {
	hash:          [32]u8, // The module that is loaded.
	file:          []u8,
	base:          u64,
	users:         u32, // The modules that import it, and each load of it by the caller. 0: the place is free.
	mapped:        bool,
	import_count:  u8,
	import_places: [IMPORT_CAPACITY]u8, // The place of each import.
}

// The modules that a loader put in one program. Each module is in it one
// time: two modules that import a third one call the same copy.
Module_Space :: struct {
	program:     Handle, // 0: this program.
	budget:      Handle, // Pays for the memory of the modules. 0: the budget of this program.
	source:      Load_Source,
	next:        u64, // Where the next module goes.
	modules:     [MODULE_SPACE_CAPACITY]Placed,
	prepared:    ^Prepared_Modules, // Not nil: each module maps its shared code from this table. nil: each module is a copy of its own.
}

// module_space_load loads a module and its imports, each one time, in the
// program of the space. On a failure, the space is as it was before.
module_space_load :: proc "contextless" (space: ^Module_Space, file: []u8) -> (index: int, failure: Load_Failure) {
	if len(file) == 0 || module.validate(file) != .None {
		return -1, {error = .Bad_Module}
	}
	before: [MODULE_SPACE_CAPACITY]u32
	for item, number in space.modules {
		before[number] = item.users
	}
	next := space.next
	index = place(space, blake3.hash(file), file, false, &failure)
	if failure.error == .None {
		return index, {}
	}
	for &item, number in space.modules {
		if before[number] == 0 && item.users != 0 {
			place_remove(space, &item)
		} else {
			item.users = before[number]
		}
	}
	space.next = next
	return -1, failure
}

// module_space_release ends one use of a module. A module with no use leaves
// the program, and its imports lose one use.
module_space_release :: proc "contextless" (space: ^Module_Space, index: int) {
	item := &space.modules[index]
	if item.users == 0 {
		return
	}
	item.users -= 1
	if item.users > 0 {
		return
	}
	imports := item.import_places
	count := item.import_count
	place_remove(space, item)
	for number in 0 ..< count {
		module_space_release(space, int(imports[number]))
	}
}

// source_file gives the file of the source with a hash, after it checked the
// hash and the tables.
@(private)
source_file :: proc "contextless" (source: Load_Source, hash: [32]u8) -> (file: []u8, error: Load_Error) {
	entry := image_entry_of(source.image, hash)
	if entry == nil {
		return nil, .Missing_Module
	}
	file = source.image[entry.offset:][:entry.size]
	if blake3.hash(file) != hash || module.validate(file) != .None {
		return nil, .Bad_Module
	}
	return file, .None
}

// place puts a module in the space, after its imports. hash is the hash
// that the caller or an import names. first is the file of the first module.
@(private)
place :: proc "contextless" (space: ^Module_Space, hash: [32]u8, first: []u8, is_import: bool, failure: ^Load_Failure) -> int {
	free := -1
	for &item, index in space.modules {
		if item.users == 0 {
			free = free < 0 ? index : free
		} else if item.hash == hash {
			item.users += 1
			return index
		}
	}
	if free < 0 {
		failure^ = {error = .No_Room, hash = hash}
		return -1
	}
	file := first
	if is_import {
		error: Load_Error
		if file, error = source_file(space.source, hash); error != .None {
			failure^ = {error = error, hash = hash}
			return -1
		}
	}
	head, _ := module.header(file)
	import_count := int(max(module.count(file, .Imports), 1)) - 1
	if import_count > IMPORT_CAPACITY {
		failure^ = {error = .No_Room, hash = hash}
		return -1
	}
	item := &space.modules[free]
	item^ = {hash = hash, file = file, base = space.next, users = 1}
	// A page with no memory between two modules.
	space.next += head.memory_size + PAGE_SIZE
	imports: [IMPORT_CAPACITY]module.Bound_Import
	for number in 0 ..< import_count {
		record, _ := module.record(file, .Imports, u32(number + 1), module.Import)
		at := place(space, record.hash, nil, true, failure)
		if at < 0 {
			return -1
		}
		item.import_places[number] = u8(at)
		item.import_count += 1
		imports[number] = {file = space.modules[at].file, base = uintptr(space.modules[at].base)}
	}
	place_map(space, item, head, imports[:import_count], failure)
	if failure.error != .None {
		return -1
	}
	return free
}

// place_map puts a module in the program of the space, bound to its
// imports. With a table of prepared modules, the program maps the shared
// code of the module from the table, and receives its own copy of each
// writable segment. With no table, the program maps a prepared module of
// its own, all of it, and the budget of the space pays for it.
@(private)
place_map :: proc "contextless" (space: ^Module_Space, item: ^Placed, head: module.Header, imports: []module.Bound_Import, failure: ^Load_Failure) {
	status: Status
	if space.prepared == nil {
		memory: Handle
		if memory, status = module_prepare(item.file, head.memory_size / PAGE_SIZE, item.base, space.budget, imports); status == .Ok {
			status = segments_map(item.file, memory, space.program, item.base, space.budget, false, imports)
			close(memory)
		}
	} else {
		lock(&space.prepared.lock)
		memory: Handle
		if memory, status = prepared_find(space.prepared, item.file, item.hash, item.base, binding_of(space, item), imports); status == .Ok {
			status = segments_map(item.file, memory, space.program, item.base, space.budget, true, imports)
		}
		unlock(&space.prepared.lock)
	}
	if status != .Ok {
		place_unmap(space, item)
		failure^ = status == .Bad_Operation ? {error = .Bad_Module, hash = item.hash} : {error = .Kernel, status = status, hash = item.hash}
		return
	}
	item.mapped = true
}

// binding_of gives what the slots of a module hold, as one hash: the hash
// and the base of the module of each import. Two programs with the same
// module at the same base and the same binding can map the same pages.
@(private)
binding_of :: proc "contextless" (space: ^Module_Space, item: ^Placed) -> [32]u8 {
	if item.import_count == 0 {
		return {}
	}
	bytes: [IMPORT_CAPACITY * 40]u8
	for number in 0 ..< int(item.import_count) {
		used := &space.modules[item.import_places[number]]
		copy(bytes[number * 40:], used.hash[:])
		base := transmute([8]u8)used.base
		copy(bytes[number * 40 + 32:], base[:])
	}
	return blake3.hash(bytes[:int(item.import_count) * 40])
}

// place_unmap removes each segment of a module that is mapped.
@(private)
place_unmap :: proc "contextless" (space: ^Module_Space, item: ^Placed) {
	for index in 1 ..< module.count(item.file, .Segments) {
		segment, _ := module.record(item.file, .Segments, index, module.Segment)
		memory_unmap(rawptr(uintptr(item.base + segment.memory_offset)), space.program)
	}
}

@(private)
place_remove :: proc "contextless" (space: ^Module_Space, item: ^Placed) {
	if item.mapped {
		place_unmap(space, item)
	}
	item^ = {}
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
// it runs at base: the segments in these pages copied from the file,
// rebased, and the slots in these pages bound to the imports. The budget
// pays for it.
@(private)
module_prepare :: proc "contextless" (file: []u8, pages: u64, base: u64, budget: Handle, imports: []module.Bound_Import) -> (memory: Handle, status: Status) {
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
	if rebased == .None {
		rebased = module.bind(file, view, imports, 0, size)
	}
	memory_unmap(address)
	if rebased != .None {
		close(memory)
		return 0, .Bad_Operation
	}
	return memory, .Ok
}

// prepared_find gives the prepared module of a file from a table, and
// prepares it if the table does not have it. A prepared module is for one
// base and one binding of its slots. It closes each prepared module that no
// program maps: the count of the holdings of its handle is 0. The caller
// checked the hash of the file.
@(private)
prepared_find :: proc "contextless" (table: ^Prepared_Modules, file: []u8, hash: [32]u8, base: u64, binding: [32]u8, imports: []module.Bound_Import) -> (memory: Handle, status: Status) {
	free: ^Prepared
	for &item in table.modules {
		if item.memory != 0 && item.hash == hash && item.base == base && item.binding == binding {
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
	written := module_prepare(file, pages, base, 0, imports) or_return
	defer close(written)
	// After the preparation, nobody writes the module: the table keeps a
	// handle without Write, and closes the one that wrote.
	memory = give(0, written, {.Read, .Execute}) or_return
	free^ = {hash = hash, base = base, binding = binding, memory = memory, pages = pages}
	return memory, .Ok
}

// segments_map maps each segment of a prepared module in a program, with
// the protection of the segment. With copy, a writable segment is a new
// memory object that the budget pays for, with the bytes of the file,
// rebased and bound: the program does not write the prepared module.
@(private)
segments_map :: proc "contextless" (file: []u8, memory: Handle, program: Handle, base: u64, budget: Handle, copy: bool, imports: []module.Bound_Import) -> Status {
	for index in 1 ..< module.count(file, .Segments) {
		segment, _ := module.record(file, .Segments, index, module.Segment)
		flags := segment_flags(segment)
		if .Write in flags && copy {
			own := segment_copy(file, segment, base, budget, imports) or_return
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
// the bytes of the file, rebased and bound. The pages that the copy does
// not write stay pages on first use.
@(private)
segment_copy :: proc "contextless" (file: []u8, segment: module.Segment, base: u64, budget: Handle, imports: []module.Bound_Import) -> (memory: Handle, status: Status) {
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
	if rebased == .None {
		rebased = module.bind(file, view, imports, segment.memory_offset, end)
	}
	memory_unmap(address)
	if rebased != .None {
		close(memory)
		return 0, .Bad_Operation
	}
	return memory, .Ok
}

// source_closure gives the files that a load of a module reads from a load
// source: the module and each import, at each level. files[0] is the
// module. A caller gives these files, and only these, to a program that
// loads the module (a call host). A hash that the load source does not
// have is left out: the loader of the other program reports it.
source_closure :: proc "contextless" (source: Load_Source, file: []u8, files: ^[MODULE_SPACE_CAPACITY + IMPORT_CAPACITY]^info.Image_Entry) -> (count: int) {
	add :: proc "contextless" (files: ^[MODULE_SPACE_CAPACITY + IMPORT_CAPACITY]^info.Image_Entry, count: ^int, entry: ^info.Image_Entry) -> bool {
		if entry == nil {
			return false
		}
		for item in files[:count^] {
			if item == entry {
				return false
			}
		}
		if count^ == len(files) {
			return false
		}
		files[count^] = entry
		count^ += 1
		return true
	}
	first := image_entry_of(source.image, blake3.hash(file))
	if !add(files, &count, first) {
		return
	}
	// Each file that was added is read for its imports one time: the list is
	// the queue of the walk.
	for walked := 0; walked < count; walked += 1 {
		entry := files[walked]
		current := source.image[entry.offset:][:entry.size]
		if module.validate(current) != .None {
			continue
		}
		for number in 1 ..< module.count(current, .Imports) {
			record, _ := module.record(current, .Imports, number, module.Import)
			add(files, &count, image_entry_of(source.image, record.hash))
		}
	}
	return count
}

// program_start builds and starts a program from a module file and its
// imports.
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
//   prepared: not nil: the program maps the shared code of each module from
//             this table, and the table keeps the prepared module for the
//             next program of the same module, base and binding. nil: the
//             program has its own copy of each module, and its budget pays.
//   source:   where the loader finds the imports.
// The module is at PROGRAM_BASE, its imports after it.
// The program stops when the last handle to it closes.
program_start :: proc "contextless" (file: []u8, name: string, grants: [op.CONTEXT_HANDLES]Grant, values: [op.CONTEXT_VALUES]u64, amounts: Budget_Amounts, mappings: []Mapping = nil, prepared: ^Prepared_Modules = nil, source: Load_Source = {}, failure: ^Load_Failure = nil) -> (program: Handle, status: Status) {
	if len(file) == 0 || module.validate(file) != .None || grants[op.CONTEXT_BUDGET].handle != 0 {
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
	space := Module_Space {
		program  = program,
		budget   = budget,
		source   = source,
		next     = op.PROGRAM_BASE,
		prepared = prepared,
	}
	_, loaded := module_space_load(&space, file)
	if failure != nil {
		failure^ = loaded
	}
	status = loaded.error == .None ? .Ok : loaded.error == .Kernel ? loaded.status : .Bad_Operation
	if status == .Ok {
		status = program_fill(program, budget, grants, values, mappings)
	}
	if status == .Ok {
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
program_fill :: proc "contextless" (program: Handle, budget: Handle, grants: [op.CONTEXT_HANDLES]Grant, values: [op.CONTEXT_VALUES]u64, mappings: []Mapping) -> Status {
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

// load_failure_text writes why a load failed, with the names that the image
// gives to the hashes.
load_failure_text :: proc "contextless" (writer: ^Writer, failure: Load_Failure, image: []u8) {
	// A module of the image by its name, another one by its hash.
	module_name :: proc "contextless" (writer: ^Writer, image: []u8, hash: [32]u8) {
		if entry := image_entry_of(image, hash); entry != nil {
			write_part(writer, name_of(entry.name[:]))
		} else {
			write_hash(writer, hash)
		}
	}
	switch failure.error {
	case .None:
	case .Bad_Module:
		write_part(writer, "a file is not a valid module, or not the hash that names it")
	case .Missing_Module:
		write_part(writer, "the module ")
		module_name(writer, image, failure.hash)
		write_part(writer, " is not in what the loader was granted")
	case .No_Room:
		write_part(writer, "no room for one more module")
	case .Kernel:
		write_part(writer, "the kernel refused an operation of the loader")
	}
}

// write_hash writes the first 8 bytes of a hash, in hexadecimal, and "...".
write_hash :: proc "contextless" (writer: ^Writer, value: [32]u8) {
	hash := value
	digits: [16]u8
	alphabet := HEX_DIGITS
	for b, index in hash[:8] {
		digits[2 * index], digits[2 * index + 1] = alphabet[b >> 4], alphabet[b & 0xF]
	}
	write_part(writer, string(digits[:]))
	write_part(writer, "...")
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
