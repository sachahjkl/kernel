// The storage service: it keeps the private store of each program on the data disk, through a block service. No program sees a shared tree of names.
//
// The root service decides who has a store: it names the store of each connection, and its limit of blocks. A program reaches its own store only: the exports take the name of an object, never the name of a store. The root service names a program that it starts again with the same name, and the program finds its data.
//
// A change is one commit, on the disk when the call returns: the system has no save action. The state of an object before a change is a version: a program reads, compares, restores and clones versions with no code of its own (property 9). The disk always has the state of the last commit, or of the one before: a stop of the machine during a commit never shows a part of it. The checks of the blocks show each change that the service did not make.
//
// The person sees all the stores with stores(), from a program that acts for the person: the console.
package storage_service

import "contract:block"
import "contract:errors"
import "contract:isolated"
import answers "support:storage"
import "base:intrinsics"
import "support:system"

// The store of the caller of the export that runs: the name and the limit
// that the root service gave to its connection.
caller_store :: proc "contextless" () -> (name: string, limit: u64, person: bool) {
	connection := system.service_caller()
	if connection == nil {
		return "", 0, false
	}
	return system.name_of(connection.caller[:]), connection.grant & isolated.CALLER_AMOUNT_MASK, connection.grant & isolated.CALLER_PERSON != 0
}

// write replaces the object with this name in the store of the caller, with the bytes of data, in one commit on the disk. The state before becomes a version. At the limit of the store, the oldest versions of the store are thinned in the same commit. The result is the generation of the commit, or a negative number with an error record.
//
// The error kinds: No_Grant (-1, the caller has no store); Over_Limit (-2, the current objects with the change need more blocks than the limit, with no earlier version kept); Empty, Too_Long or Bad_Byte (-3, the name has 1 to 39 bytes and no zero byte); Too_Long (-4, the data has more than 32 blocks); Full (-5, no place for one more object or store, or no free block); Device (-6, the block service reported an error); Damaged (-8, the table of the store has a wrong check).
@(export, link_name = "write")
write :: proc "c" (name: ^string, data: ^string, error: ^errors.Error_Record) -> i64 {
	store, limit, _ := caller_store()
	return change({store, limit}, name^, .Write, transmute([]u8)data^, {}, error)
}

// read gives the bytes of the object with this name in the store of the caller, or a negative number with an error record.
//
// The error kinds: No_Grant (-1); Empty, Too_Long or Bad_Byte (-3, the name); Device (-6); Absent (-7, the store has no such object); Damaged (-8, a block of the object or of the table of the store has a wrong check: the service does not give its bytes).
@(export, link_name = "read")
read_export :: proc "c" (name: ^string, result: ^[]u8, error: ^errors.Error_Record) -> i64 {
	store, limit, _ := caller_store()
	if limit == 0 {
		return errors.fail(error, ERROR_NO_STORE, .No_Grant, .Store)
	}
	if size := object_state(store, name^, error); size < 0 || size > i64(len(result)) {
		return size // A failure, or a text that does not fit: the caller sees it.
	}
	return read(store, name^, result^, error)
}

// size gives the count of bytes of the object with this name in the store of the caller, or a negative number with an error record.
//
// The error kinds: No_Grant (-1); Empty, Too_Long or Bad_Byte (-3, the name); Absent (-7); Damaged (-8: a block of the object on the disk has a wrong check, and the service does not give its bytes; a write or a remove of the object replaces it).
@(export, link_name = "size")
size :: proc "c" (name: ^string, error: ^errors.Error_Record) -> i64 {
	store, limit, _ := caller_store()
	if limit == 0 {
		return errors.fail(error, ERROR_NO_STORE, .No_Grant, .Store)
	}
	return object_state(store, name^, error)
}

// remove removes the object with this name and all its versions from the store of the caller, in one commit. The result is the generation of the commit, or a negative number with an error record. A damaged object can be removed.
//
// The error kinds: those of write, and Absent (-7, the store has no such object).
@(export, link_name = "remove")
remove :: proc "c" (name: ^string, error: ^errors.Error_Record) -> i64 {
	store, limit, _ := caller_store()
	return change({store, limit}, name^, .Remove, nil, {}, error)
}

// objects gives the objects of the store of the caller: the name, the bytes and the generation of the last change of each one, and the word damaged for an object with a wrong block.
@(export, link_name = "objects")
objects :: proc "c" (result: ^[]u8) -> i64 {
	store, limit, _ := caller_store()
	writer := system.Writer{buffer = result^}
	if limit == 0 {
		system.write_part(&writer, "no store")
		return i64(writer.count)
	}
	index := store_find(store)
	count := 0
	if index >= 0 && store_damaged[index] {
		system.write_part(&writer, "the table of the store has a wrong check: the service does not know its objects")
		return i64(writer.count)
	}
	if index >= 0 {
		for &object, object_index in tables[index].objects {
			if object.name[0] == 0 {
				continue
			}
			if count != 0 {
				system.write_part(&writer, "; ")
			}
			version_count: u64
			if object.versions.block != 0 {
				version_index: Version_Index
				if read_single(object.versions, (^Block)(&version_index)) == .Good {
					version_count = version_index.version_count
				}
			}
			parts := [?]system.Part{system.name_of(object.name[:]), " ", object.size, " bytes, generation ", object.generation}
			for part in parts {
				system.write_part(&writer, part)
			}
			if version_count != 0 {
				system.write_part(&writer, ", versions ")
				system.write_part(&writer, version_count)
			}
			if damaged[index] >> uint(object_index) & 1 != 0 {
				system.write_part(&writer, ", damaged")
			}
			count += 1
		}
	}
	if count == 0 {
		system.write_part(&writer, "no object")
	}
	return i64(writer.count)
}

// stores gives each store of the disk, with its objects, its versions, its blocks (a shared block counted one time), the blocks that two names share, its limit, the count of connections that hold its grant now, and its damage. Only a caller that acts for the person sees them.
@(export, link_name = "stores")
stores :: proc "c" (result: ^[]u8) -> i64 {
	_, _, person := caller_store()
	writer := system.Writer{buffer = result^}
	if !person {
		system.write_part(&writer, "no grant to see the stores")
		return i64(writer.count)
	}
	parts := [?]system.Part{"generation ", root.generation, ", ", opened.in_use_count, " of ", root.disk_blocks, " blocks in use, ", commits, " commits and ", blocks_written, " blocks written since the start"}
	for part in parts {
		system.write_part(&writer, part)
	}
	for &store, index in root.stores {
		if store.name[0] == 0 {
			continue
		}
		object_count: u64
		for &object in tables[index].objects {
			if object.name[0] != 0 {
				object_count += 1
			}
		}
		holders: u64
		for &connection in service.connections {
			if connection.calls.head != nil && system.name_of(connection.caller[:]) == system.name_of(store.name[:]) && connection.grant & isolated.CALLER_AMOUNT_MASK != 0 {
				holders += 1
			}
		}
		line := [?]system.Part{"; ", system.name_of(store.name[:]), ": ", object_count, " objects, ", opened.store_versions[index], " versions, ", store.used, " of ", store.limit, " blocks, ", opened.store_shared[index], " shared, ", holders, holders == 1 ? " connection" : " connections"}
		for part in line {
			system.write_part(&writer, part)
		}
		damaged_count: u64
		for object_index in 0 ..< OBJECT_CAPACITY {
			damaged_count += damaged[index] >> uint(object_index) & 1
		}
		if store_damaged[index] {
			system.write_part(&writer, ", its table has a wrong check")
		} else if damaged_count != 0 {
			tail := [?]system.Part{", ", damaged_count, " damaged"}
			for part in tail {
				system.write_part(&writer, part)
			}
		}
	}
	return i64(writer.count)
}

// store_named gives the store that an export names: the store of the
// caller for an empty text or its own name, else another store, for a
// caller that acts for the person only. The store is argument 1.
store_named :: proc "contextless" (given: string, error: ^errors.Error_Record) -> (store: Store_Of, ok: bool) {
	own, limit, person := caller_store()
	if len(given) == 0 || given == own {
		if limit == 0 {
			errors.fail(error, ERROR_NO_STORE, .No_Grant, .Store)
			return {}, false
		}
		return {own, limit}, true
	}
	if !person {
		errors.fail(error, answers.ERROR_PERSON, .No_Grant, .Person)
		return {}, false
	}
	index := store_find(given)
	if index < 0 {
		errors.fail(error, ERROR_ABSENT, .Absent, .Stores, 1)
		return {}, false
	}
	return {system.name_of(root.stores[index].name[:]), root.stores[index].limit}, true
}

// One row of versions(): one state of an object.
Version :: struct {
	generation: i64, // The commit that made this state.
	time:       i64, // Milliseconds since the format of the disk, at that commit (the time that a machine ran).
	date:       i64, // Seconds since 1970 (UTC) at that commit. 0: the system had no date.
	bytes:      i64,
	own_blocks: i64, // The blocks that only this state holds: what thinning it frees.
	current:    i64, // 1: the current version, the last row.
}

// One row of compare(): bytes that differ between two states.
Byte_Range :: struct {
	first: i64, // The offset of the first byte that differs.
	count: i64,
}

// versions gives the states of an object of a store, the oldest first, and its current version last: the generation, the time since the format of the disk, the date, the bytes, and the blocks that only this state holds. The store is empty for the store of the caller; another store needs a caller that acts for the person. The result is the count of the rows, or a negative number with an error record.
//
// The error kinds: No_Grant (-1, the caller has no store; -10, another store and the caller does not act for the person); Empty, Too_Long or Bad_Byte (-3, the name); Absent (-7, no such store or object); Damaged (-8, the version index of the object has a wrong check); Device (-6).
@(export, link_name = "versions")
versions :: proc "c" (store: ^string, name: ^string, result: ^[]Version, error: ^errors.Error_Record) -> i64 {
	named, ok := store_named(store^, error)
	if !ok {
		return store_refusal(error)
	}
	store_index, object_index, found := object_locate(named.name, name^, error, 2)
	if !found {
		return i64(object_index)
	}
	object := tables[store_index].objects[object_index]
	if count := versions_list(&object, error); count < 0 {
		return count
	}
	rows := listed_count + 1
	// The lists of the states, REGION_BLOCKS at a time: the blocks that only
	// one state holds.
	for first := 0; first < rows; first += REGION_BLOCKS {
		last := min(first + REGION_BLOCKS, rows)
		pointers: [REGION_BLOCKS]Pointer
		for row in first ..< last {
			pointers[row - first] = row < listed_count ? listed[row].list : object.list
		}
		readable: [REGION_BLOCKS]Pointer
		readable_count := 0
		for pointer in pointers[:last - first] {
			if pointer.block != 0 {
				readable[readable_count] = pointer
				readable_count += 1
			}
		}
		if readable_count != 0 {
			if _, outcome := read_checked(readable[:readable_count], 0); outcome == .Device {
				return errors.fail(error, ERROR_DISK, .Device)
			}
		}
		place := 0
		for row in first ..< last {
			entry := row < listed_count ? listed[row] : Version_Entry{generation = object.generation, size = object.size, time = object.time, date = object.date, list = object.list}
			own: u64
			if entry.list.block != 0 {
				list := (^List)(raw_data(slot(u64(place))))
				if check_of(slot(u64(place))) == entry.list.check {
					own = own_blocks(entry.list, entry.size, list)
				}
				place += 1
			}
			if row < len(result) {
				result[row] = {generation = i64(entry.generation), time = i64(entry.time), date = i64(entry.date), bytes = i64(entry.size), own_blocks = i64(own), current = i64(row == listed_count)}
			}
		}
	}
	return i64(rows)
}

// version gives the bytes of an object of a store at a generation: one of its versions, or its current version. The store is empty for the store of the caller; another store needs a caller that acts for the person. The result is the count of bytes, or a negative number with an error record.
//
// The error kinds: those of versions; Absent (-9, the object has no version of this generation); Damaged (-8, a block of this version has a wrong check).
@(export, link_name = "version")
version :: proc "c" (store: ^string, name: ^string, generation: i64, result: ^[]u8, error: ^errors.Error_Record) -> i64 {
	named, ok := store_named(store^, error)
	if !ok {
		return store_refusal(error)
	}
	store_index, object_index, found := object_locate(named.name, name^, error, 2)
	if !found {
		return i64(object_index)
	}
	object := tables[store_index].objects[object_index]
	state, refused := state_at(&object, generation, 3, error)
	if refused < 0 {
		return refused
	}
	if state.size > u64(len(result)) {
		return i64(state.size) // The caller sees that it does not fit.
	}
	return state_bytes(state, result^, error)
}

// restore makes a version of an object of a store its current version again, in one commit: the current version before it becomes a version, so nothing is lost. No block of data is written: the object names the blocks of the version. The store is empty for the store of the caller; another store needs a caller that acts for the person. The result is the generation of the commit, or a negative number with an error record.
//
// The error kinds: those of version, and those of write.
@(export, link_name = "restore")
restore :: proc "c" (store: ^string, name: ^string, generation: i64, error: ^errors.Error_Record) -> i64 {
	named, ok := store_named(store^, error)
	if !ok {
		return store_refusal(error)
	}
	store_index, object_index, found := object_locate(named.name, name^, error, 2)
	if !found {
		return i64(object_index)
	}
	object := tables[store_index].objects[object_index]
	state, refused := state_at(&object, generation, 3, error)
	if refused < 0 {
		return refused
	}
	return change(named, name^, .Restore, nil, state, error, 2)
}

// clone makes the object new_name of a store a copy of the object name: the two name the same blocks until one of them changes. A state of new_name before becomes a version. The store is empty for the store of the caller; another store needs a caller that acts for the person. The result is the generation of the commit, or a negative number with an error record.
//
// The error kinds: those of restore; the name and new_name are arguments 2 and 3.
@(export, link_name = "clone")
clone :: proc "c" (store: ^string, name: ^string, new_name: ^string, error: ^errors.Error_Record) -> i64 {
	named, ok := store_named(store^, error)
	if !ok {
		return store_refusal(error)
	}
	store_index, object_index, found := object_locate(named.name, name^, error, 2)
	if !found {
		return i64(object_index)
	}
	object := tables[store_index].objects[object_index]
	if damaged[store_index] >> uint(object_index) & 1 != 0 {
		return errors.fail(error, ERROR_DAMAGED, .Damaged, .Objects, 2)
	}
	return change(named, new_name^, .Clone, nil, current_state(&object), error, 3)
}

// compare gives the ranges of bytes that differ between two states of an object of a store (two generations: a version or the current version). Two blocks that the two states both name are equal bytes and are not read. The store is empty for the store of the caller; another store needs a caller that acts for the person. The result is the count of the ranges, or a negative number with an error record.
//
// The error kinds: those of version; first and second are arguments 3 and 4.
@(export, link_name = "compare")
compare :: proc "c" (store: ^string, name: ^string, first: i64, second: i64, result: ^[]Byte_Range, error: ^errors.Error_Record) -> i64 {
	named, ok := store_named(store^, error)
	if !ok {
		return store_refusal(error)
	}
	store_index, object_index, found := object_locate(named.name, name^, error, 2)
	if !found {
		return i64(object_index)
	}
	object := tables[store_index].objects[object_index]
	states: [2]State_Of_Object
	for generation, index in ([2]i64{first, second}) {
		state, refused := state_at(&object, generation, 3 + i64(index), error)
		if refused < 0 {
			return refused
		}
		states[index] = state
	}
	lists: [2]List
	for state, index in states {
		if state.list.block == 0 {
			continue
		}
		_, outcome := read_checked({state.list}, 0)
		if outcome != .Good {
			return errors.fail(error, outcome == .Device ? ERROR_DISK : ERROR_DAMAGED, outcome == .Device ? .Device : .Damaged, .Objects, 3 + i64(index))
		}
		intrinsics.mem_copy_non_overlapping(&lists[index], raw_data(slot(0)), BLOCK_SIZE)
	}
	ranges: i64
	open_first: i64 = -1
	close_range :: proc "contextless" (result: []Byte_Range, ranges: ^i64, open_first: ^i64, end: i64) {
		if open_first^ < 0 {
			return
		}
		if ranges^ < i64(len(result)) {
			result[ranges^] = {first = open_first^, count = end - open_first^}
		}
		ranges^ += 1
		open_first^ = -1
	}
	sizes := [2]i64{i64(states[0].size), i64(states[1].size)}
	block_count := max(blocks_of(states[0].size), blocks_of(states[1].size))
	for index in 0 ..< block_count {
		pointers: [2]Pointer
		for side in 0 ..< 2 {
			if index < blocks_of(states[side].size) {
				pointers[side] = lists[side].data[index]
			}
		}
		base := i64(index * BLOCK_SIZE)
		if pointers[0] == pointers[1] && pointers[0].block != 0 {
			close_range(result^, &ranges, &open_first, base)
			continue
		}
		bytes: [2][]u8
		zero: Block
		for side in 0 ..< 2 {
			bytes[side] = zero[:]
			if pointers[side].block == 0 {
				continue
			}
			_, outcome := read_checked({pointers[side]}, u64(side))
			if outcome != .Good {
				return errors.fail(error, outcome == .Device ? ERROR_DISK : ERROR_DAMAGED, outcome == .Device ? .Device : .Damaged, .Objects, 3 + i64(side))
			}
			bytes[side] = slot(u64(side))
		}
		for offset in 0 ..< i64(BLOCK_SIZE) {
			at := base + offset
			if at >= max(sizes[0], sizes[1]) {
				break
			}
			inside := [2]bool{at < sizes[0], at < sizes[1]}
			differs := inside[0] != inside[1] || bytes[0][offset] != bytes[1][offset]
			if differs && open_first < 0 {
				open_first = at
			} else if !differs {
				close_range(result^, &ranges, &open_first, at)
			}
		}
	}
	close_range(result^, &ranges, &open_first, max(sizes[0], sizes[1]))
	return ranges
}

// store_refusal gives the result of a refusal that store_named wrote.
store_refusal :: proc "contextless" (error: ^errors.Error_Record) -> i64 {
	switch {
	case error.kind == i64(errors.Kind.No_Grant) && error.unit == i64(errors.Unit.Person):
		return answers.ERROR_PERSON
	case error.kind == i64(errors.Kind.Absent):
		return ERROR_ABSENT
	}
	return ERROR_NO_STORE
}

service: system.Service

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	ok: bool
	if service, ok = system.service_open(ctx); !ok {
		system.log_in("storage", .Error, "storage: no service ring")
		system.stop(1)
	}
	ring_memory := ctx.handles[block.GRANT_RING]
	status: system.Status
	if blocks, status = system.ring_open(ring_memory); status != .Ok {
		system.log_in("storage", .Error, "storage: no block ring")
		system.stop(1)
	}
	memory, memory_status := system.memory_create(REGION_BLOCKS, 0, {.Contiguous}) // The device reads and writes it.
	address, map_status := system.memory_map(memory, {.Write})
	if memory_status != .Ok || map_status != .Ok {
		system.log_in("storage", .Error, "storage: no data region")
		system.stop(1)
	}
	region = ([^]u8)(address)
	// The block service maps the ring when it starts.
	given: system.Handle
	give_status := system.Status.Bad_Handle
	for attempt := 0; attempt < 2000 && give_status != .Ok; attempt += 1 {
		if given, give_status = system.give(ring_memory, memory, {.Read, .Write}); give_status != .Ok {
			system.sleep(system.time() + 1)
		}
	}
	if give_status != .Ok || block.Status(command(.Attach, {0 = u64(given)}).kind) != .Ok {
		system.log_in("storage", .Error, "storage: the block service refused the data region")
		system.stop(1)
	}
	info := command(.Info)
	start := system.time()
	mounted := mount(info.values[0])
	elapsed := system.time() - start
	switch {
	case mounted.failed:
		system.log_in("storage", .Error, "storage: no valid root on the disk: the service keeps the disk as it is, and serves nothing")
		system.stop(1)
	case mounted.needs_format:
		if mounted.first_cut {
			system.log_in("storage", .Warning, "storage: the first root of the disk has a wrong check and no commit followed it: a format that a stop cut; the service formats again")
		}
		system.log("storage: ok, a new disk: generation 1, ", root.disk_blocks, " blocks")
	case:
		if mounted.cut != 0 {
			system.log_in("storage", .Warning, "storage: the root of generation ", mounted.cut, " has a wrong check: a write that a stop cut; the service uses the root before it")
		}
		if mounted.older {
			system.log_in("storage", .Warning, "storage: the newest root names a block with a wrong check, and the root before it names none: the root before it is used")
		}
		if mounted.wrong != 0 {
			system.log_in("storage", .Warning, "storage: ", mounted.wrong, " blocks have a wrong check: ", mounted.damaged_objects, " objects and ", mounted.damaged_stores, " stores are damaged; the service serves the others, and a write or a remove replaces a damaged object")
		}
		if mounted.damaged_versions != 0 {
			system.log_in("storage", .Warning, "storage: ", mounted.damaged_versions, " versions have a wrong block: a read of them gives Damaged")
		}
		if mounted.named_twice != 0 || mounted.named_by_two_stores != 0 || mounted.stores_with_wrong_count != 0 {
			system.log_in("storage", .Error, "storage: a fault of the engine: ", mounted.named_twice, " blocks of one name named two times, ", mounted.named_by_two_stores, " blocks named from two stores, ", mounted.stores_with_wrong_count, " stores whose count of blocks is not the count of their distinct blocks")
		}
		system.log("storage: ok, generation ", mounted.generation, ": ", mounted.stores, " stores, ", mounted.objects, " objects, ", mounted.versions, " versions, ", opened.in_use_count, " blocks in use, ", mounted.shared, " shared, ", mounted.checked, " blocks checked, ", mounted.wrong, " wrong, in ", elapsed, " ms")
	}
	for {
		wait: system.Wait
		system.service_wait(&wait, &service)
		system.wait_end(&wait)
		system.service_run(&service)
	}
}
