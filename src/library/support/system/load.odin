package system

import "base:intrinsics"
import "modus:contract/blake3"
import info "modus:contract/boot_info"
import "modus:contract/fixed_addresses"
import op "modus:contract/operation"
import module "modus:contract/module"

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

// image_resources gives the entries of the resources of the boot image:
// the table after the table of the modules.
image_resources :: proc "contextless" (image: []u8) -> []info.Image_Entry {
	modules := image_entries(image)
	if modules == nil {
		return nil
	}
	header := (^info.Image_Header)(raw_data(image))
	first := size_of(info.Image_Header) + len(modules) * size_of(info.Image_Entry)
	if first + int(header.resource_count) * size_of(info.Image_Entry) > len(image) {
		return nil
	}
	return ([^]info.Image_Entry)(raw_data(image[first:]))[:header.resource_count]
}

// image_resource_find gives the entry of the resource with this name, or
// nil. The entry is inside the image and starts on a page. The caller
// checks the hash of the bytes.
image_resource_find :: proc "contextless" (image: []u8, name: string) -> ^info.Image_Entry {
	for &entry in image_resources(image) {
		if name_of(entry.name[:]) == name && entry.offset % PAGE_SIZE == 0 && entry.offset <= u64(len(image)) && entry.size <= u64(len(image)) - entry.offset {
			return &entry
		}
	}
	return nil
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
//
// `program_start` gives each grant with `give` at its index of the context;
// a zero handle is no grant. Example, in the root service:
// `grants[system.GRANT_MACHINE] = {machine, {.Inspect, .Stop}}`.
Grant :: struct {
	handle: Handle, // A handle of the starter. 0: no grant at this index.
	rights: Rights, // The rights of the copy: at most the rights of `handle`.
}

// A part of a memory object at an address of a program.
//
// `program_start` maps each one in the new program before its start: a
// starter gives a fixed range this way.
Mapping :: struct {
	memory:     Handle, // The memory object, with the rights of `flags`.
	address:    u64, // The address in the new program.
	first:      u64, // The first page of the memory object.
	page_count: u64, // 0: all pages from first.
	flags:      op.Map_Flags, // The access of the pages.
}

PREPARED_CAPACITY :: 64 // Two parts for each module: the code, and the fixed part for one base.

// The parts of a module for a loader (Module_Part).
//   Code:  the segments with no Write: the code and the constants. The
//          loader never writes them (a rebase or a slot is in a segment
//          with Write), so their pages are the same at each base, with
//          each binding: one copy for all the programs of the table.
//   Fixed: the segments that are read-only after the load: the loader
//          writes their rebases and their slots, so their pages are for
//          one base and one binding.
//   All:   each segment: the copy of a module that has no table.
Module_Part :: enum u8 {
	All, // Each segment, for one program.
	Code, // The segments with no Write, shared by every program.
	Fixed, // The segments read-only after the load, for one base and one binding.
}

// A prepared module: a memory object that holds one part of a module as the
// loader prepared it, its segments copied from the file, and for the part
// Fixed rebased at base and bound. Each program that runs the module maps
// the pages that do not change (the shared code of the module), and
// receives its own copy of the writable pages. The loader writes the
// memory object one time; after that, the table holds it with the rights
// Read and Execute only, so no program writes it.
Prepared :: struct {
	hash:    [32]u8, // The hash of the module file.
	part:    Module_Part, // Which segments the memory object holds.
	base:    u64, // Fixed: the address of the module in each program that maps it.
	binding: [32]u8, // Fixed: what its slots hold (binding_of): zero for a module with no import.
	first:   u64, // The offset in the module of the first page of the memory object.
	memory:  Handle, // 0: the place is free.
	pages:   u64, // The pages of the memory object.
}

// The prepared modules of a program that starts programs. The zero value is
// an empty table. The budget of the program that owns the table pays for
// each prepared module. A prepared module stays while a program maps it:
// each start closes the ones that no program maps.
Prepared_Modules :: struct {
	lock:    Lock, // The threads of the owner that start programs take it.
	modules: [PREPARED_CAPACITY]Prepared,
}

// The load source: where a loader finds the imports of a module. Nothing
// else: the loader has no search path and no ambient module store, so a
// program reaches only the modules that it was granted.
Load_Source :: struct {
	image:        []u8, // The files that the program was granted, in the form of the boot image. A file has the hash that names it, or the loader refuses it.
	replacements: []module.Replacement, // From the party that starts the program. The program cannot change them.
}

MODULE_SPACE_CAPACITY :: op.PROGRAM_MODULE_CAPACITY // The modules of one space: the module records that the kernel keeps for one program.
IMPORT_CAPACITY :: 8 // The imports of one module that this loader binds.

// One module that a loader put in a program: a place of a module space.
Placed :: struct {
	hash:          [32]u8, // The module that is loaded.
	replaces:      [32]u8, // Zero, or the hash of the import that a replacement changed to this module.
	file:          []u8, // The file of the module, in the load source.
	original:      []u8, // The file of the module that this one replaces: the names of the exports that a slot uses.
	base:          u64, // The address of the module in the program.
	users:         u32, // The modules that import it, and each load of it by the caller. 0: the place is free.
	loading:       bool, // Its imports are not all loaded: a module that imports it now makes a cycle.
	mapped:        bool, // Its segments are mapped in the program.
	import_count:  u8, // The entries of `import_places` in use.
	import_places: [IMPORT_CAPACITY]u8, // The place of each import.
}

// The modules that a loader put in one program. Each module is in it one
// time: two modules that import a third one call the same copy.
Module_Space :: struct {
	program:     Handle, // 0: this program.
	budget:      Handle, // Pays for the memory of the modules. 0: the budget of this program.
	source:      Load_Source, // Where the imports come from.
	next:        u64, // Where the next module goes.
	modules:     [MODULE_SPACE_CAPACITY]Placed,
	prepared:    ^Prepared_Modules, // Not nil: each module maps its shared code from this table. nil: each module is a copy of its own.
}

// cycles gives the cycle counter of the processor (`rdtsc`), with no kernel
// entry. `nanoseconds` turns it into a time.
cycles :: #force_inline proc "contextless" () -> u64 {
	return u64(intrinsics.read_cycle_counter())
}

// module_space_load loads a module and its imports, each one time, in the
// program of the space. A replacement of the load source applies to each
// import, and not to the module that the caller names. On a failure, the
// space is as it was before, and error has the stage and the modules of the
// failure: the caller owns the record.
//
// details: an optional table of error details (docs/MODULE_CONTRACT.md,
// section 8, "The table of error details"). When the load fails because a
// file of the load source is missing or is not the file of its hash, the
// loader appends one load error for each such import of the whole graph,
// not only the first (load_source_problems).
module_space_load :: proc "contextless" (space: ^Module_Space, file: []u8, error: ^module.Load_Error, details: ^Table_To_Append(module.Load_Error) = nil) -> (index: int, ok: bool) {
	error^ = {}
	hash := blake3.hash(file)
	if file_error := module.validate(file); len(file) == 0 || file_error != .None {
		error^ = {stage = .Read, file_error = file_error, module = named_of(space.source, hash)}
		if details != nil {
			table_append(details, error^)
		}
		return -1, false
	}
	defer if !ok && details != nil && (error.stage == .Find || error.stage == .Read) {
		load_source_problems(space.source, file, details)
	}
	before: [MODULE_SPACE_CAPACITY]u32
	for item, number in space.modules {
		before[number] = item.users
	}
	next := space.next
	index = place(space, hash, file, nil, error)
	if index >= 0 {
		return index, true
	}
	for &item, number in space.modules {
		if before[number] == 0 && item.users != 0 {
			place_remove(space, &item)
		} else {
			item.users = before[number]
			item.loading = false
		}
	}
	space.next = next
	return -1, false
}

// module_space_release ends one use of a module. A module with no use leaves
// the program, and its imports lose one use. If the kernel refuses to
// remove a module, error has the stage Unmap and the module: the space
// forgets the module, and its memory stays in the program.
module_space_release :: proc "contextless" (space: ^Module_Space, index: int, error: ^module.Load_Error) -> bool {
	item := &space.modules[index]
	if item.users == 0 {
		return true
	}
	item.users -= 1
	if item.users > 0 {
		return true
	}
	imports := item.import_places
	count := item.import_count
	if status := place_remove(space, item); status != .Ok && error.stage == .None {
		error^ = {stage = .Unmap, status = u32(status), module = named_of(space.source, item.hash)}
	}
	for number in 0 ..< count {
		module_space_release(space, int(imports[number]), error)
	}
	return error.stage == .None
}

// load_source_problems appends one load error for each import of the graph
// of a module that the load source does not have (the stage Find), or has
// with another hash or with tables that are not valid (Read), in the order
// in which a load meets them: the order of the imports, depth first. So the
// first of them is the load error of a load that failed at such an import.
// Each module of the graph is read one time. It loads nothing and calls no
// kernel operation.
load_source_problems :: proc "contextless" (source: Load_Source, file: []u8, details: ^Table_To_Append(module.Load_Error)) {
	visited: Visited_Modules
	import_problems(source, blake3.hash(file), file, {}, {}, details, &visited)
}

// The modules that load_source_problems read: a module that two modules
// import is read one time, and a cycle of replacements ends.
@(private = "file")
Visited_Modules :: struct {
	hashes: [MODULE_SPACE_CAPACITY][32]u8,
	count:  int,
}

// import_problems appends the problems of the imports of one module, then
// of their imports. replaced and replacement: the nearest replacement on
// the path from the first module, as a load error names it.
@(private = "file")
import_problems :: proc "contextless" (source: Load_Source, importer: [32]u8, file: []u8, replaced, replacement: module.Named, details: ^Table_To_Append(module.Load_Error), visited: ^Visited_Modules) {
	for hash in visited.hashes[:visited.count] {
		if hash == importer {
			return
		}
	}
	// The space of a program holds no more modules: the walk ends there too.
	if visited.count == len(visited.hashes) {
		return
	}
	visited.hashes[visited.count] = importer
	visited.count += 1
	import_count := int(max(module.count(file, .Imports), 1)) - 1
	for number in 0 ..< min(import_count, IMPORT_CAPACITY) {
		record, _ := module.record(file, .Imports, u32(number + 1), module.Import)
		hash := record.hash
		nearest_replaced, nearest_replacement := replaced, replacement
		replaces: [32]u8
		for item in source.replacements {
			if item.from == record.hash {
				hash, replaces = item.to, record.hash
				nearest_replaced, nearest_replacement = named_of(source, record.hash), named_of(source, item.to)
				break
			}
		}
		problem := module.Load_Error {
			module      = named_of(source, importer),
			imported    = named_of(source, record.hash),
			replaced    = nearest_replaced,
			replacement = nearest_replacement,
		}
		imported_file, stage, file_error := source_file(source, hash)
		if stage != .None {
			problem.stage, problem.file_error = stage, file_error
			table_append(details, problem)
			continue
		}
		// The names of the exports that the slots use are in the module that
		// the import names: the load reads it too.
		if replaces != {} {
			if _, original_stage, original_error := source_file(source, replaces); original_stage != .None {
				problem.stage, problem.file_error = original_stage, original_error
				table_append(details, problem)
				continue
			}
		}
		import_problems(source, hash, imported_file, nearest_replaced, nearest_replacement, details, visited)
	}
}

// named_of gives a hash with the name that the load source gives to it.
named_of :: proc "contextless" (source: Load_Source, hash: [32]u8) -> (value: module.Named) {
	value.hash = hash
	if entry := image_entry_of(source.image, hash); entry != nil {
		module.name_set(&value.name, name_of(entry.name[:]))
	}
	return value
}

// source_file gives the file of the load source with a hash, after it
// checked the hash and the tables.
@(private)
source_file :: proc "contextless" (source: Load_Source, hash: [32]u8) -> (file: []u8, stage: module.Load_Stage, file_error: module.Error) {
	entry := image_entry_of(source.image, hash)
	if entry == nil {
		return nil, .Find, .None
	}
	file = source.image[entry.offset:][:entry.size]
	if file_error = module.validate(file); file_error != .None || blake3.hash(file) != hash {
		return nil, .Read, file_error
	}
	return file, .None, .None
}

// module_fits_below_band says if a module of memory_size bytes at the
// address next, with the page with no memory after it, ends at or before
// the end of the addresses of the modules: the band of the fixed ranges,
// where the system maps the settings page, the glyph caches and the files
// of the modules, starts there. No sum wraps: the size is compared first.
module_fits_below_band :: proc "contextless" (next, memory_size: u64) -> bool {
	if memory_size > fixed_addresses.MODULES_END - PAGE_SIZE {
		return false
	}
	return next <= fixed_addresses.MODULES_END - PAGE_SIZE - memory_size
}

// place puts a module in the space, after its imports. named is the hash
// that the caller or an import of importer names. first is the file of the
// first module.
@(private)
place :: proc "contextless" (space: ^Module_Space, named: [32]u8, first: []u8, importer: ^Placed, error: ^module.Load_Error) -> (result: int) {
	hash := named
	replaces: [32]u8
	if importer != nil {
		for item in space.source.replacements {
			if item.from == named {
				hash, replaces = item.to, named
				break
			}
		}
	}
	// A failure here concerns this module, as the import of importer.
	fail :: proc "contextless" (space: ^Module_Space, error: ^module.Load_Error, stage: module.Load_Stage, importer: ^Placed, named: [32]u8, hash: [32]u8) -> int {
		error.stage = stage
		if importer != nil {
			error.module = named_of(space.source, importer.hash)
			error.imported = named_of(space.source, named)
		} else {
			error.module = named_of(space.source, hash)
		}
		return -1
	}
	// A failure on the path of a replaced import says which replacement
	// the loader applied, if no replacement nearer to the failure says it.
	defer if result < 0 && replaces != {} && error.replaced.hash == {} {
		error.replaced = named_of(space.source, replaces)
		error.replacement = named_of(space.source, hash)
	}
	free := -1
	for &item, index in space.modules {
		if item.users == 0 {
			free = free < 0 ? index : free
		} else if item.hash == hash {
			if item.loading {
				return fail(space, error, .Cycle, importer, named, hash)
			}
			item.users += 1
			return index
		}
	}
	if free < 0 {
		return fail(space, error, .Room, importer, named, hash)
	}
	file := first
	original: []u8
	stage: module.Load_Stage
	if importer != nil {
		if file, stage, error.file_error = source_file(space.source, hash); stage != .None {
			return fail(space, error, stage, importer, named, hash)
		}
	}
	if replaces != {} {
		// The names of the exports that the slots use are in the module of the import.
		if original, stage, error.file_error = source_file(space.source, replaces); stage != .None {
			return fail(space, error, stage, importer, named, hash)
		}
	}
	// Each file here was validated (module_space_load, source_file); a
	// header that is not valid still stops the load at once, before its
	// size is used.
	head, header_error := module.header(file)
	if header_error != .None {
		error.file_error = header_error
		return fail(space, error, .Read, importer, named, hash)
	}
	import_count := int(max(module.count(file, .Imports), 1)) - 1
	if import_count > IMPORT_CAPACITY {
		return fail(space, error, .Room, importer, named, hash)
	}
	if !module_fits_below_band(space.next, head.memory_size) {
		return fail(space, error, .Room, importer, named, hash)
	}
	item := &space.modules[free]
	item^ = {hash = hash, replaces = replaces, file = file, original = original, base = space.next, users = 1, loading = true}
	// A page with no memory between two modules.
	space.next += head.memory_size + PAGE_SIZE
	imports: [IMPORT_CAPACITY]module.Bound_Import
	for number in 0 ..< import_count {
		record, _ := module.record(file, .Imports, u32(number + 1), module.Import)
		at := place(space, record.hash, nil, item, error)
		if at < 0 {
			return -1
		}
		item.import_places[number] = u8(at)
		item.import_count += 1
		used := &space.modules[at]
		imports[number] = {file = used.file, base = uintptr(used.base)}
		if used.hash != record.hash {
			// A replacement: the slots name exports of the module of the import.
			imports[number].named = used.replaces == record.hash ? used.original : nil
			if imports[number].named == nil {
				if imports[number].named, stage, error.file_error = source_file(space.source, record.hash); stage != .None {
					return fail(space, error, stage, item, record.hash, used.hash)
				}
			}
		}
	}
	if !place_map(space, item, head, imports[:import_count], error) {
		return -1
	}
	item.loading = false
	return free
}

// place_map puts a module in the program of the space, bound to its
// imports, and writes its module record. With a table of prepared modules,
// the program maps the shared code of the module from the table, and
// receives its own copy of each writable segment. With no table, the
// program maps a prepared module of its own, all of it, and the budget of
// the space pays for it.
@(private)
place_map :: proc "contextless" (space: ^Module_Space, item: ^Placed, head: module.Header, imports: []module.Bound_Import, error: ^module.Load_Error) -> bool {
	status: Status
	if space.prepared == nil {
		own: Prepared
		if own, status = module_prepare(item.file, .All, item.base, space.budget, imports, error); status == .Ok {
			status = segments_map(item.file, &own, &own, space.program, item.base, space.budget, imports, error)
			close(own.memory)
		}
	} else {
		// The code from the table at any base; the fixed part for this base
		// and this binding; the writable segments of this program.
		lock(&space.prepared.lock)
		prepared_sweep(space.prepared)
		code, fixed: ^Prepared
		if code, status = prepared_find(space.prepared, item.file, item.hash, .Code, 0, {}, nil, error); status == .Ok {
			if fixed, status = prepared_find(space.prepared, item.file, item.hash, .Fixed, item.base, binding_of(space, item), imports, error); status == .Ok {
				status = segments_map(item.file, code, fixed, space.program, item.base, space.budget, imports, error)
			}
		}
		unlock(&space.prepared.lock)
	}
	if status != .Ok {
		place_unmap(space, item)
		#partial switch error.stage {
		case .Check, .Bind:
			// The import of the slot, and its replacement if the loader applied one.
			error.module = named_of(space.source, item.hash)
			slot, _ := module.record(item.file, .Slots, error.slot, module.Slot)
			if record, has_import := module.record(item.file, .Imports, slot.import_index, module.Import); has_import && slot.import_index != 0 {
				error.imported = named_of(space.source, record.hash)
				if used := &space.modules[item.import_places[slot.import_index - 1]]; used.hash != record.hash {
					error.replaced = error.imported
					error.replacement = named_of(space.source, used.hash)
				}
			}
		case .Read, .Room:
			error.module = named_of(space.source, item.hash)
		case:
			error^ = {stage = .Map, status = u32(status), module = named_of(space.source, item.hash)}
		}
		return false
	}
	item.mapped = true
	record := op.Module_Record {
		base     = item.base,
		size     = head.memory_size,
		hash     = item.hash,
		replaces = item.replaces,
	}
	if _, status = call(.Program_Module, u64(space.program), u64(uintptr(&record))); status != .Ok {
		error^ = {stage = .Map, status = u32(status), module = named_of(space.source, item.hash)}
		return false
	}
	return true
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

// place_unmap removes each segment of a module that is mapped. It gives the
// first status that is not Ok.
@(private)
place_unmap :: proc "contextless" (space: ^Module_Space, item: ^Placed) -> (result: Status) {
	for index in 1 ..< module.count(item.file, .Segments) {
		segment, _ := module.record(item.file, .Segments, index, module.Segment)
		if status := memory_unmap(rawptr(uintptr(item.base + segment.memory_offset)), space.program); status != .Ok && result == .Ok {
			result = status
		}
	}
	return result
}

@(private)
place_remove :: proc "contextless" (space: ^Module_Space, item: ^Placed) -> (status: Status) {
	if item.mapped {
		status = place_unmap(space, item)
		record := op.Module_Record {
			base = item.base,
		}
		if _, removed := call(.Program_Module, u64(space.program), u64(uintptr(&record))); removed != .Ok && status == .Ok {
			status = removed
		}
	}
	item^ = {}
	return status
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

// in_part says if a segment is in a part of a module.
@(private)
in_part :: proc "contextless" (segment: module.Segment, part: Module_Part) -> bool {
	switch part {
	case .All:
		return true
	case .Code:
		return .Write not_in segment.flags
	case .Fixed:
		return .Write in segment.flags && .Read_Only_After_Load in segment.flags
	}
	return false
}

// part_range gives the offsets of the first and of the end of the pages of
// a part of a module. end is 0 when the part has no segment.
@(private)
part_range :: proc "contextless" (file: []u8, part: Module_Part) -> (first, end: u64) {
	first = max(u64)
	for index in 1 ..< module.count(file, .Segments) {
		segment, _ := module.record(file, .Segments, index, module.Segment)
		if in_part(segment, part) {
			first = min(first, segment.memory_offset)
			end = max(end, segment.memory_offset + segment.memory_size)
		}
	}
	return end == 0 ? 0 : first, end
}

// module_prepare makes a memory object with one part of the module as it
// runs at base: the segments of the part copied from the file; for the
// parts Fixed and All, rebased and bound to the imports. Its first page is
// the page of the module at offset `first`. The budget pays for it.
@(private)
module_prepare :: proc "contextless" (file: []u8, part: Module_Part, base: u64, budget: Handle, imports: []module.Bound_Import, error: ^module.Load_Error) -> (prepared: Prepared, status: Status) {
	first, end := part_range(file, part)
	if end == 0 {
		return {part = part}, .Ok
	}
	memory := memory_create((end - first) / PAGE_SIZE, budget) or_return
	address: rawptr
	if address, status = memory_map(memory); status != .Ok {
		close(memory)
		return {}, status
	}
	// The view starts where the module would start: an offset of the
	// module is an index, and only the part is memory.
	view := ([^]u8)(uintptr(address) - uintptr(first))[:end]
	for index in 1 ..< module.count(file, .Segments) {
		segment, _ := module.record(file, .Segments, index, module.Segment)
		if in_part(segment, part) && segment.file_size != 0 {
			intrinsics.mem_copy_non_overlapping(&view[segment.memory_offset], &file[segment.file_offset], int(segment.file_size))
		}
	}
	// The part Code has no rebase and no slot: the file checks it (rebase
	// and bind refuse a location in a segment with no Write).
	ok := part == .Code || code_ready(file, view, base, imports, error, first, end)
	memory_unmap(address)
	if !ok {
		close(memory)
		return {}, .Bad_Operation
	}
	return {part = part, base = base, first = first, memory = memory, pages = (end - first) / PAGE_SIZE}, .Ok
}

// code_ready rebases and binds the locations of a module from offset first
// to offset end. A failure fills the stage of error: Read for a rebase,
// Check or Bind for a slot.
@(private)
code_ready :: proc "contextless" (file: []u8, view: []u8, base: u64, imports: []module.Bound_Import, error: ^module.Load_Error, first, end: u64) -> bool {
	if rebased := module.rebase_range(file, view, uintptr(base), first, end); rebased != .None {
		error.stage, error.file_error = .Read, rebased
		return false
	}
	return module.bind(file, view, imports, error, first, end)
}

// prepared_sweep closes each prepared module of a table that no program
// maps: the count of the holdings of its handle is 0. The caller holds the
// lock of the table, and sweeps before it finds the parts of one module.
@(private)
prepared_sweep :: proc "contextless" (table: ^Prepared_Modules) {
	for &item in table.modules {
		if item.memory != 0 && handle_holdings(item.memory) == 0 {
			close(item.memory)
			item = {}
		}
	}
}

// prepared_find gives one part of the prepared module of a file from a
// table, and prepares it if the table does not have it. The part Code is
// for each base and each binding; the part Fixed is for one base and one
// binding of its slots. The caller checked the hash of the file. A part
// with no segment has no memory object.
@(private)
prepared_find :: proc "contextless" (table: ^Prepared_Modules, file: []u8, hash: [32]u8, part: Module_Part, base: u64, binding: [32]u8, imports: []module.Bound_Import, error: ^module.Load_Error) -> (found: ^Prepared, status: Status) {
	free: ^Prepared
	for &item in table.modules {
		if item.memory != 0 && item.hash == hash && item.part == part && item.base == base && item.binding == binding {
			return &item, .Ok
		}
		if item.memory == 0 && free == nil {
			free = &item
		}
	}
	if free == nil {
		error.stage = .Room
		return nil, .No_Slot
	}
	written := module_prepare(file, part, base, 0, imports, error) or_return
	if written.memory == 0 {
		free^ = {} // No segment: nothing to keep, and the place stays free.
		return free, .Ok
	}
	defer close(written.memory)
	// After the preparation, nobody writes the module: the table keeps a
	// handle without Write, and closes the one that wrote.
	free^ = written
	free.hash, free.binding = hash, binding
	free.memory = give(0, written.memory, {.Read, .Execute}) or_return
	return free, .Ok
}

// segments_map maps each segment of a module in a program, with the
// protection of the segment: a segment of the part Code from code, a
// segment of the part Fixed from fixed, and a writable segment from a new
// memory object that the budget pays for, with the bytes of the file,
// rebased and bound, when code is not the part All. A program does not
// write a prepared module.
@(private)
segments_map :: proc "contextless" (file: []u8, code, fixed: ^Prepared, program: Handle, base: u64, budget: Handle, imports: []module.Bound_Import, error: ^module.Load_Error) -> Status {
	for index in 1 ..< module.count(file, .Segments) {
		segment, _ := module.record(file, .Segments, index, module.Segment)
		flags := segment_flags(segment)
		from := code
		if code.part != .All && .Write in flags {
			own := segment_copy(file, segment, base, budget, imports, error) or_return
			_, status := memory_map(own, flags, program, base + segment.memory_offset)
			close(own)
			if status != .Ok {
				return status
			}
			continue
		}
		if code.part != .All && in_part(segment, .Fixed) {
			from = fixed
		}
		memory_map(from.memory, flags, program, base + segment.memory_offset, (segment.memory_offset - from.first) / PAGE_SIZE, segment.memory_size / PAGE_SIZE) or_return
	}
	return .Ok
}

// segment_copy makes the memory of one writable segment for one program:
// the bytes of the file, rebased and bound. The pages that the copy does
// not write stay pages on first use.
@(private)
segment_copy :: proc "contextless" (file: []u8, segment: module.Segment, base: u64, budget: Handle, imports: []module.Bound_Import, error: ^module.Load_Error) -> (memory: Handle, status: Status) {
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
	ok := code_ready(file, view, base, imports, error, segment.memory_offset, end)
	memory_unmap(address)
	if !ok {
		close(memory)
		return 0, .Bad_Operation
	}
	return memory, .Ok
}

// source_closure gives the files that a load of a module reads from a load
// source: the module and each import, at each level, and for a replaced
// import both the module that the import names and the module of the
// replacement. files[0] is the module. A caller gives these files, and only
// these, to a program that loads the module (a call host). A hash that the
// load source does not have is left out: the loader of the other program
// reports it.
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
			for item in source.replacements {
				if item.from == record.hash {
					add(files, &count, image_entry_of(source.image, item.to))
				}
			}
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
//   source:   where the loader finds the imports, and the replacements that
//             the caller gives to the program.
//   error:    when the load fails, the record of the failure.
// The module is at PROGRAM_BASE, its imports after it.
// The program stops when the last handle to it closes.
program_start :: proc "contextless" (file: []u8, name: string, grants: [op.CONTEXT_HANDLES]Grant, values: [op.CONTEXT_VALUES]u64, amounts: Budget_Amounts, mappings: []Mapping = nil, prepared: ^Prepared_Modules = nil, source: Load_Source = {}, error: ^module.Load_Error = nil) -> (program: Handle, status: Status) {
	if len(file) == 0 || module.validate(file) != .None || grants[op.CONTEXT_BUDGET].handle != 0 {
		return 0, .Bad_Operation
	}
	// Each program has a random seed from its starter (docs/RANDOMNESS.md):
	// a starter that forgot it does not start a program with no seed.
	seed_given: u64
	for index in 0 ..< op.CONTEXT_VALUE_SEED_COUNT {
		seed_given |= values[op.CONTEXT_VALUE_SEED + index]
	}
	if seed_given == 0 {
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
	loaded: module.Load_Error
	if _, ok := module_space_load(&space, file, &loaded); !ok {
		status = loaded.stage == .Map ? Status(loaded.status) : .Bad_Operation
	}
	if error != nil {
		error^ = loaded
	}
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

@(rodata)
file_error_names := [module.Error]string {
	.None            = "no error",
	.Too_Small       = "the file is smaller than a header",
	.Bad_Magic       = "it does not start with the bytes of a module",
	.Unknown_Version = "its format version is not known",
	.Unknown_Feature = "it needs a feature that this loader does not know",
	.Unknown_Machine = "it is for another machine",
	.Bad_Table       = "a table is outside the file",
	.Bad_Segment     = "a segment is not valid",
	.Bad_Rebase      = "a rebase is not in writable data",
	.Bad_Slot        = "a slot is not valid",
	.Bad_Import      = "an import is not valid",
	.Bad_Export      = "an export is not valid",
}

// load_error_text writes a load error for a reader: one line or more, each
// one ended by a line feed. The record has the names: the text needs no
// other data.
load_error_text :: proc "contextless" (writer: ^Writer, error: ^module.Load_Error) {
	name :: proc "contextless" (writer: ^Writer, value: ^module.Named) {
		if value.name[0] != 0 {
			write_part(writer, module.name_get(&value.name))
		} else {
			write_hash(writer, value.hash)
		}
	}
	described :: proc "contextless" (writer: ^Writer, value: ^module.Described) {
		#partial switch value.type {
		case .None:
			write_part(writer, "nothing")
		case .Record:
			write_part(writer, "the record ")
			write_part(writer, module.name_get(&value.record))
		case .Table:
			write_part(writer, "Table(")
			write_part(writer, module.name_get(&value.record))
			write_part(writer, ", ")
			write_part(writer, direction_name(value.direction))
			write_part(writer, ")")
		case:
			write_parameter_type(writer, nil, value.type, value.detail, value.direction)
		}
	}
	// The module that the stage concerns: the import, or the module itself.
	subject := error.imported.hash != {} ? &error.imported : &error.module
	switch error.stage {
	case .None:
		return
	case .Find:
		if error.imported.hash != {} {
			name(writer, &error.module)
			write_part(writer, " imports ")
			name(writer, &error.imported)
			write_part(writer, ", and the load source has no file with its hash\n")
		} else {
			write_part(writer, "the load source has no file with the hash of ")
			name(writer, &error.module)
			write_part(writer, "\n")
		}
	case .Read:
		write_part(writer, "the file of ")
		name(writer, subject)
		write_part(writer, error.file_error == .None ? " does not have the hash that names it\n" : " is not a valid module: ")
		if error.file_error != .None {
			// The record can come from another program: a value out of the enumeration is a value.
			write_part(writer, error.file_error <= max(module.Error) ? file_error_names[error.file_error] : "an error that this program does not know")
			write_part(writer, "\n")
		}
	case .Cycle:
		write_part(writer, "an import cycle: ")
		name(writer, &error.module)
		write_part(writer, " imports ")
		name(writer, &error.imported)
		write_part(writer, ", and ")
		name(writer, error.replacement.hash != {} ? &error.replacement : &error.imported)
		write_part(writer, " still loads its imports\n")
	case .Check:
		name(writer, &error.module)
		write_part(writer, " imports ")
		name(writer, &error.imported)
		write_part(writer, ", and its replacement ")
		name(writer, &error.replacement)
		write_part(writer, " fails the check\n")
		write_part(writer, "export ")
		write_part(writer, module.name_get(&error.export))
		write_part(writer, " of ")
		name(writer, &error.replacement)
		write_part(writer, ": ")
		switch error.difference {
		case .None:
		case .Missing_Export:
			write_part(writer, "no export has this name")
		case .Parameter_Count:
			write_part(writer, u64(error.found.detail))
			write_part(writer, " parameters, ")
			name(writer, &error.imported)
			write_part(writer, " has ")
			write_part(writer, u64(error.expected.detail))
		case .Parameter_Type, .Parameter_Detail, .Parameter_Direction:
			write_part(writer, "parameter ")
			write_part(writer, u64(error.parameter))
			write_part(writer, " is ")
			described(writer, &error.found)
			write_part(writer, ", ")
			name(writer, &error.imported)
			write_part(writer, " has ")
			described(writer, &error.expected)
		case .Result_Type, .Result_Detail:
			write_part(writer, "the result is ")
			described(writer, &error.found)
			write_part(writer, ", ")
			name(writer, &error.imported)
			write_part(writer, " has ")
			described(writer, &error.expected)
		case .Error_Record:
			write_part(writer, "the error record is ")
			described(writer, &error.found)
			write_part(writer, ", ")
			name(writer, &error.imported)
			write_part(writer, " has ")
			described(writer, &error.expected)
		}
		write_part(writer, "\n")
		return // The first line names the replacement.
	case .Bind:
		write_part(writer, "slot ")
		write_part(writer, u64(error.slot))
		write_part(writer, " of ")
		name(writer, &error.module)
		write_part(writer, " cannot be bound")
		if error.export != {} {
			write_part(writer, ": export ")
			write_part(writer, module.name_get(&error.export))
			write_part(writer, " of ")
			name(writer, &error.imported)
		}
		write_part(writer, "\n")
	case .Map, .Unmap:
		write_part(writer, error.stage == .Map ? "the kernel refused to map " : "the kernel refused to remove ")
		name(writer, &error.module)
		write_part(writer, ": status ")
		write_part(writer, u64(error.status))
		write_part(writer, "\n")
	case .Room:
		write_part(writer, "no room for ")
		name(writer, subject)
		write_part(writer, ": a program has 16 modules at most, a module 8 imports, a table of prepared modules 64 parts, and its modules fit below the fixed ranges of the system\n")
	}
	if error.replaced.hash != {} && error.stage != .Cycle {
		write_part(writer, "on the path of the load, the replacement table gives ")
		name(writer, &error.replacement)
		write_part(writer, " in place of ")
		name(writer, &error.replaced)
		write_part(writer, "\n")
	} else if error.stage == .Cycle && error.replaced.hash != {} {
		write_part(writer, "the replacement table gives ")
		name(writer, &error.replacement)
		write_part(writer, " in place of ")
		name(writer, &error.replaced)
		write_part(writer, ": that makes the cycle\n")
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

// program_stop_report gives where a program stopped on a fault, and the
// module of the instruction. The handle needs the right Read.
program_stop_report :: proc "contextless" (program: Handle) -> (report: op.Stop_Report) {
	call(.Program_State, u64(program), u64(uintptr(&report)))
	return report
}
