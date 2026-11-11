// The open of a data disk (contract/store): which root to use, the check of
// each block that it names, and the blocks in use. The storage service runs
// it at its start; the kernel tool runs the same code on the host, on each
// image of a disk that a loss of power can leave (tools/kerneltool,
// power_loss.odin). Pure code: no kernel operation, no allocation. The
// blocks come from a Block_Reader that the caller gives.
package storage_mount

import "base:intrinsics"
import format "contract:store"

BLOCK_SIZE :: format.BLOCK_SIZE
SCRATCH_BLOCKS :: format.OBJECT_BLOCKS_LIMIT + 2

// The source of the blocks of a disk: the storage service reads them
// through its block service, the tool from an image in memory.
Block_Reader :: struct {
	// read reads the blocks of `numbers` into `into`, one after the other
	// (len(numbers) * BLOCK_SIZE bytes). false: the device reported an error.
	read: proc "contextless" (reader: ^Block_Reader, numbers: []u64, into: []u8) -> bool,
	// check gives the check of the bytes of a block that read gave. nil:
	// format.check. The kernel tool gives the check that it computed for
	// the same bytes before: its images differ in a few blocks.
	check: proc "contextless" (reader: ^Block_Reader, number: u64, bytes: []u8) -> u64,
	data: rawptr,
}

check_of_block :: proc "contextless" (reader: ^Block_Reader, number: u64, bytes: []u8) -> u64 {
	return reader.check != nil ? reader.check(reader, number, bytes) : format.check(bytes)
}

// What the open knows of a disk. The storage service keeps it while it
// runs; the tool makes one for each image.
State :: struct {
	root:          format.Root,
	root_place:    u64, // 0 or 1: the place of the root on the disk.
	disk_size:     u64, // The blocks of the disk that the service uses.
	tables:        [format.STORE_CAPACITY]format.Table,
	in_use:        [format.DISK_BLOCKS_LIMIT / 64]u64, // Bit n: block n is named by the root.
	in_use_count:  u64,
	// The reference count of each block that the root names: for a block of
	// data, the lists that name it; for a list, the objects and versions that
	// name it; 1 for a table, an index and a leaf.
	references:    [format.DISK_BLOCKS_LIMIT]u32,
	owner:         [format.DISK_BLOCKS_LIMIT]u8, // The store that names the block, plus 1.
	wrong_blocks:  [format.DISK_BLOCKS_LIMIT / 64]u64, // Bit n: block n was read and has a wrong check.
	store_versions: [format.STORE_CAPACITY]u64, // The versions of the objects of each store.
	store_shared:  [format.STORE_CAPACITY]u64, // The blocks of each store with a reference count of 2 or more.
	// The distinct blocks of each store that the walk counted: the count that
	// the store has in memory. The blocks under a block with a wrong check
	// are not counted, and they are free in memory too.
	store_recount: [format.STORE_CAPACITY]u64,
	// The walk found a fault of the engine in the store (a block of one name
	// named two times, a block named from two stores, a count that does not
	// fit its type): its counts are not trusted, and the service makes no
	// change in it.
	store_faulty:  [format.STORE_CAPACITY]bool,
	damaged:       [format.STORE_CAPACITY]u64, // Bit n: the object n of the store has a wrong block.
	store_damaged: [format.STORE_CAPACITY]bool, // The table of the store has a wrong check.
	scratch:       [SCRATCH_BLOCKS * BLOCK_SIZE]u8,
}

Mount :: struct {
	generation:      u64,
	stores:          u64,
	objects:         u64,
	checked:         u64, // Blocks read and compared with their check.
	wrong:           u64,
	damaged_objects: u64,
	damaged_stores:  u64,
	needs_format:    bool, // No commit followed the first root: the disk holds no object, the caller formats it.
	first_cut:       bool, // The disk had only a first root with a wrong check: a format that a stop cut.
	older:           bool, // The newest root named a wrong block and the root before it names none: the root before it is used.
	cut:             u64, // Not 0: the generation that a root with a wrong check gives; the open does not use it.
	failed:          bool, // No root is usable, or the device reported an error.
	versions:        u64, // The versions of all the objects.
	damaged_versions: u64, // Versions with a wrong list or a wrong block of data, or in a wrong leaf.
	shared:          u64, // Blocks with a reference count of 2 or more.
	// Faults of the engine itself, that no stop of the machine can make: a
	// table, an index or a leaf that the root names two times, a block named
	// from two stores, and a store whose count of blocks is not the count of
	// its distinct blocks.
	named_twice:          u64,
	named_by_two_stores:  u64,
	stores_with_wrong_count: u64, // Stores walked whole whose count in the root is not the count of their distinct blocks.
	reference_overflow:   u64, // Blocks with more names than a count holds.
	stores_recounted:     u64, // Stores whose count in the root differs from the recount: the open takes the recount.
}

// REFERENCE_LIMIT is the most names of one block that a count holds. A disk
// that the engine wrote cannot reach it: one store has at most
// OBJECT_CAPACITY objects of VERSIONS_LIMIT versions.
REFERENCE_LIMIT :: u64(max(u32))

// reference counts one more name of a block, from a store. It gives true
// for the first name: the caller reads and checks the block one time.
reference :: proc "contextless" (state: ^State, number: u64, store_index: int, result: ^Mount) -> (first: bool) {
	if number >= format.DISK_BLOCKS_LIMIT {
		return false
	}
	if state.references[number] == 0 {
		state.references[number] = 1
		state.owner[number] = u8(store_index + 1)
		mark(state, number, true)
		return true
	}
	if int(state.owner[number]) != store_index + 1 {
		result.named_by_two_stores += 1
		state.store_faulty[store_index] = true
		if state.owner[number] != 0 {
			state.store_faulty[int(state.owner[number]) - 1] = true
		}
	}
	if u64(state.references[number]) >= REFERENCE_LIMIT {
		result.reference_overflow += 1
		state.store_faulty[store_index] = true
		return false
	}
	state.references[number] += 1
	if state.references[number] == 2 {
		state.store_shared[store_index] += 1
		result.shared += 1
	}
	return false
}

wrong_block :: proc "contextless" (state: ^State, number: u64) -> bool {
	return number < format.DISK_BLOCKS_LIMIT && state.wrong_blocks[number / 64] >> (number % 64) & 1 != 0
}

wrong_block_set :: proc "contextless" (state: ^State, number: u64) {
	if number < format.DISK_BLOCKS_LIMIT {
		state.wrong_blocks[number / 64] |= 1 << (number % 64)
	}
}

// reference_list counts one name of a list of an object or of a version
// of `size` bytes. At its first name the list is read and checked, then
// each block of data that no list named before. It gives Wrong when the
// list or one of its blocks has a wrong check (then, or at its first name).
// `named` counts the blocks of the store that this name counted first.
reference_list :: proc "contextless" (state: ^State, reader: ^Block_Reader, list: format.Pointer, size: u64, store_index: int, result: ^Mount, named: ^u64) -> Read {
	if list.block == 0 {
		return .Good
	}
	count := (size + BLOCK_SIZE - 1) / BLOCK_SIZE
	if !reference(state, list.block, store_index, result) {
		return wrong_block(state, list.block) || count > format.OBJECT_BLOCKS_LIMIT ? .Wrong : .Good
	}
	named^ += 1
	wrong, outcome := read_checked(state, reader, {list}, 0)
	result.checked += 1
	if outcome == .Device {
		return .Device
	}
	if outcome == .Wrong || count > format.OBJECT_BLOCKS_LIMIT {
		result.wrong += max(wrong, 1)
		wrong_block_set(state, list.block)
		return .Wrong
	}
	data := (^format.List)(raw_data(scratch_block(state, 0)))^
	// The blocks that no list named before: each one is read and checked one
	// time, whatever the count of the lists that name it.
	unread: [format.OBJECT_BLOCKS_LIMIT]format.Pointer
	unread_count := 0
	known_wrong := false
	for pointer in data.data[:count] {
		if pointer.block < 2 || pointer.block >= state.disk_size {
			result.wrong += 1
			known_wrong = true
			continue
		}
		if reference(state, pointer.block, store_index, result) {
			named^ += 1
			unread[unread_count] = pointer
			unread_count += 1
		} else if wrong_block(state, pointer.block) {
			known_wrong = true
		}
	}
	if unread_count != 0 {
		wrong, outcome = read_checked(state, reader, unread[:unread_count], 1)
		result.checked += u64(unread_count)
		if outcome == .Device {
			return .Device
		}
		if outcome == .Wrong {
			result.wrong += wrong
			for pointer, index in unread[:unread_count] {
				if check_of_block(reader, pointer.block, scratch_block(state, 1 + index)) != pointer.check {
					wrong_block_set(state, pointer.block)
				}
			}
			known_wrong = true
		}
	}
	return known_wrong ? .Wrong : .Good
}

used :: proc "contextless" (state: ^State, number: u64) -> bool {
	return state.in_use[number / 64] >> (number % 64) & 1 != 0
}

// mark sets or clears the bit of a block. It gives false when the bit had
// the value already.
mark :: proc "contextless" (state: ^State, number: u64, value: bool) -> bool {
	if number >= format.DISK_BLOCKS_LIMIT || used(state, number) == value {
		return false
	}
	if value {
		state.in_use[number / 64] |= 1 << (number % 64)
		state.in_use_count += 1
	} else {
		state.in_use[number / 64] &~= 1 << (number % 64)
		state.in_use_count -= 1
	}
	return true
}

Read :: enum {
	Good,
	Wrong, // A block does not have the check of its Pointer, or a Pointer names no block of the disk.
	Device, // The device reported an error.
}

// read_checked reads blocks into the scratch of the state, from `first_slot`
// on, and compares each one with the check of its Pointer. It gives the
// count of wrong blocks.
read_checked :: proc "contextless" (state: ^State, reader: ^Block_Reader, pointers: []format.Pointer, first_slot: int) -> (wrong: u64, result: Read) {
	numbers: [SCRATCH_BLOCKS]u64
	if first_slot + len(pointers) > SCRATCH_BLOCKS {
		return u64(len(pointers)), .Wrong
	}
	for pointer, index in pointers {
		if pointer.block < 2 || pointer.block >= state.disk_size {
			return u64(len(pointers)), .Wrong
		}
		numbers[index] = pointer.block
	}
	into := state.scratch[first_slot * BLOCK_SIZE:][:len(pointers) * BLOCK_SIZE]
	if !reader.read(reader, numbers[:len(pointers)], into) {
		return 0, .Device
	}
	for pointer, index in pointers {
		if check_of_block(reader, pointer.block, into[index * BLOCK_SIZE:][:BLOCK_SIZE]) != pointer.check {
			wrong += 1
		}
	}
	return wrong, wrong == 0 ? .Good : .Wrong
}

// scratch_block gives one block of the scratch.
scratch_block :: proc "contextless" (state: ^State, index: int) -> []u8 {
	return state.scratch[index * BLOCK_SIZE:][:BLOCK_SIZE]
}

// walk reads each block that a root names, checks it, and counts its
// references: the objects, their versions, and each block one time. A wrong
// block does not end the walk: its object, its version, or its store for a
// table, is damaged. The blocks that a wrong table, index, leaf or list
// named are not known, so they are free. It gives false when the device
// reported an error.
walk :: proc "contextless" (state: ^State, reader: ^Block_Reader, candidate: ^format.Root, result: ^Mount) -> bool {
	state.in_use = {}
	state.in_use_count = 0
	state.references = {}
	state.owner = {}
	state.wrong_blocks = {}
	state.store_versions = {}
	state.store_shared = {}
	state.store_recount = {}
	state.store_faulty = {}
	mark(state, 0, true)
	mark(state, 1, true)
	state.tables = {}
	state.damaged = {}
	state.store_damaged = {}
	result.stores, result.objects, result.checked, result.wrong = 0, 0, 0, 0
	result.damaged_objects, result.damaged_stores, result.named_twice, result.stores_with_wrong_count = 0, 0, 0, 0
	result.versions, result.damaged_versions, result.shared, result.named_by_two_stores = 0, 0, 0, 0
	result.reference_overflow, result.stores_recounted = 0, 0
	// A block that only one name can have: a table, an index, a leaf.
	single :: proc "contextless" (state: ^State, reader: ^Block_Reader, pointer: format.Pointer, store_index: int, result: ^Mount, named: ^u64) -> Read {
		if !reference(state, pointer.block, store_index, result) {
			result.named_twice += 1
			state.store_faulty[store_index] = true
		} else {
			named^ += 1
		}
		wrong, outcome := read_checked(state, reader, {pointer}, 0)
		result.checked += 1
		if outcome == .Wrong {
			result.wrong += wrong
			wrong_block_set(state, pointer.block)
		}
		return outcome
	}
	for &store, index in candidate.stores {
		if store.name[0] == 0 {
			continue
		}
		result.stores += 1
		named: u64 // The distinct blocks of the store: the table, then each block that the store names first.
		outcome := single(state, reader, store.table, index, result, &named)
		if outcome == .Device {
			return false
		}
		if outcome == .Wrong {
			result.damaged_stores += 1
			state.store_damaged[index] = true
			continue
		}
		intrinsics.mem_copy_non_overlapping(&state.tables[index], raw_data(scratch_block(state, 0)), BLOCK_SIZE)
		complete := true // Each block of the store was read: its count of blocks is known.
		for &object, object_index in state.tables[index].objects {
			if object.name[0] == 0 {
				continue
			}
			result.objects += 1
			switch reference_list(state, reader, object.list, object.size, index, result, &named) {
			case .Device:
				return false
			case .Wrong:
				result.damaged_objects += 1
				state.damaged[index] |= 1 << uint(object_index)
				complete = false
			case .Good:
			}
			if object.versions.block == 0 {
				continue
			}
			outcome = single(state, reader, object.versions, index, result, &named)
			if outcome == .Device {
				return false
			}
			if outcome == .Wrong {
				result.damaged_versions += 1 // The versions of the object are not known.
				complete = false
				continue
			}
			version_index := (^format.Version_Index)(raw_data(scratch_block(state, 0)))^
			// A count that the format does not permit is damage, as a wrong
			// check: the engine then never reads past the leaves of an index.
			if version_index.leaf_count > format.VERSION_INDEX_CAPACITY {
				result.wrong += 1
				wrong_block_set(state, object.versions.block)
				result.damaged_versions += 1
				complete = false
				continue
			}
			for leaf_pointer in version_index.leaves[:version_index.leaf_count] {
				outcome = single(state, reader, leaf_pointer, index, result, &named)
				if outcome == .Device {
					return false
				}
				if outcome == .Wrong {
					result.damaged_versions += 1
					complete = false
					continue
				}
				leaf := (^format.Version_Leaf)(raw_data(scratch_block(state, 0)))^
				// The engine writes no empty leaf, and no leaf of more entries
				// than it holds.
				if leaf.count == 0 || leaf.count > format.VERSION_LEAF_CAPACITY {
					result.wrong += 1
					wrong_block_set(state, leaf_pointer.block)
					result.damaged_versions += 1
					complete = false
					continue
				}
				for &entry in leaf.entries[:leaf.count] {
					result.versions += 1
					state.store_versions[index] += 1
					switch reference_list(state, reader, entry.list, entry.size, index, result, &named) {
					case .Device:
						return false
					case .Wrong:
						result.damaged_versions += 1
						complete = false
					case .Good:
					}
				}
			}
		}
		// The count of the store is its recount: the blocks under a wrong
		// block are not counted in memory either, so they are free there and
		// out of the limit of the store. A store walked whole whose root gives
		// another count is a fault of the engine that wrote it.
		state.store_recount[index] = named
		if named != store.used {
			result.stores_recounted += 1
			if complete {
				result.stores_with_wrong_count += 1
			}
		}
	}
	return true
}

// mount finds the root and walks it.
//
// Which root: the valid root with the highest generation, when it names no
// wrong block. If it names one, and the valid root before it names none,
// the root before it: the last commit was not whole on the disk (a device
// that did not keep what a Flush promised). If each valid root names a
// wrong block, the newest one, with its damage: a block that both name was
// changed after its commit, and no root is better.
//
// A disk with no commit (block 0 is zero bytes) needs a format: the caller
// writes the first root (the open writes nothing).
mount :: proc "contextless" (state: ^State, reader: ^Block_Reader, disk_blocks: u64) -> (result: Mount) {
	state.disk_size = min(disk_blocks, format.DISK_BLOCKS_LIMIT)
	numbers := [2]u64{0, 1}
	if !reader.read(reader, numbers[:], state.scratch[:2 * BLOCK_SIZE]) {
		result.failed = true
		return result
	}
	candidates: [2]format.Root
	zero := [2]bool{true, true}
	for index in 0 ..< 2 {
		bytes := scratch_block(state, index)
		for byte in bytes {
			if byte != 0 {
				zero[index] = false
			}
		}
		intrinsics.mem_copy_non_overlapping(&candidates[index], raw_data(bytes), BLOCK_SIZE)
	}
	// The first root goes to block 1, and the first commit to block 0. So
	// block 0 of zero bytes says that no commit followed the first root:
	// the disk holds no object. A first root with a wrong check is then a
	// format that a stop cut.
	if zero[0] && (zero[1] || !format.root_valid(&candidates[1], state.disk_size)) {
		result.needs_format = true
		result.first_cut = !zero[1]
		return result
	}
	// The valid roots, the newest first.
	order := [2]int{0, 1}
	if candidates[1].generation > candidates[0].generation {
		order = {1, 0}
	}
	first, walked := -1, -1
	for index in order {
		if !format.root_valid(&candidates[index], state.disk_size) {
			if candidates[index].magic == format.ROOT_MAGIC {
				result.cut = candidates[index].generation
			}
			continue
		}
		if first < 0 {
			first = index
		}
		if !walk(state, reader, &candidates[index], &result) {
			result.failed = true
			return result
		}
		walked = index
		if result.wrong == 0 {
			break
		}
	}
	if first < 0 {
		result.failed = true
		return result
	}
	if result.wrong != 0 && walked != first {
		if !walk(state, reader, &candidates[first], &result) {
			result.failed = true
			return result
		}
		walked = first
	}
	result.older = walked != first
	state.root = candidates[walked]
	state.root_place = u64(walked)
	result.generation = state.root.generation
	return result
}

// list_bytes reads the bytes of one state of an object (its list and its
// size), checked, into `into`. ok is false when a block is wrong or the
// device reported an error.
list_bytes :: proc "contextless" (state: ^State, reader: ^Block_Reader, list: format.Pointer, size: u64, into: []u8) -> (ok: bool) {
	if list.block == 0 {
		return true
	}
	count := (size + BLOCK_SIZE - 1) / BLOCK_SIZE
	if count > format.OBJECT_BLOCKS_LIMIT || u64(len(into)) < size {
		return false
	}
	if _, outcome := read_checked(state, reader, {list}, 0); outcome != .Good {
		return false
	}
	data := (^format.List)(raw_data(scratch_block(state, 0)))^
	if _, outcome := read_checked(state, reader, data.data[:count], 1); outcome != .Good {
		return false
	}
	intrinsics.mem_copy_non_overlapping(raw_data(into), raw_data(state.scratch[BLOCK_SIZE:]), int(size))
	return true
}

// object_bytes reads the bytes of the current version of an object of a
// store that the open walked, checked, into `into`. ok is false when the
// object is damaged or the device reported an error; size is its count of
// bytes.
object_bytes :: proc "contextless" (state: ^State, reader: ^Block_Reader, store_index: int, object_index: int, into: []u8) -> (size: u64, ok: bool) {
	object := state.tables[store_index].objects[object_index]
	return object.size, list_bytes(state, reader, object.list, object.size, into)
}

// versions_read reads the version entries of an object, the oldest first,
// checked, into `into`. ok is false when the index or a leaf is wrong.
versions_read :: proc "contextless" (state: ^State, reader: ^Block_Reader, versions: format.Pointer, into: []format.Version_Entry) -> (count: int, ok: bool) {
	if versions.block == 0 {
		return 0, true
	}
	if _, outcome := read_checked(state, reader, {versions}, 0); outcome != .Good {
		return 0, false
	}
	version_index := (^format.Version_Index)(raw_data(scratch_block(state, 0)))^
	for leaf_pointer in version_index.leaves[:min(version_index.leaf_count, format.VERSION_INDEX_CAPACITY)] {
		if _, outcome := read_checked(state, reader, {leaf_pointer}, 0); outcome != .Good {
			return count, false
		}
		leaf := (^format.Version_Leaf)(raw_data(scratch_block(state, 0)))
		for entry in leaf.entries[:min(leaf.count, format.VERSION_LEAF_CAPACITY)] {
			if count < len(into) {
				into[count] = entry
			}
			count += 1
		}
	}
	return count, true
}

// version_leaves_full says if an object can take no more version with no
// compaction: its index has its last leaf, and that leaf is full.
version_leaves_full :: proc "contextless" (leaf_count: int, last_leaf_count: u64) -> bool {
	return leaf_count >= format.VERSION_INDEX_CAPACITY && last_leaf_count >= format.VERSION_LEAF_CAPACITY
}

// version_leaves_compact moves the entries of leaves to the first leaves,
// each one full but the last, in their order (the oldest first). The
// retention rule leaves a few entries in each leaf, so with no compaction
// the index fills with nearly empty leaves. It gives the count of the
// leaves that hold an entry; the leaves after them have no entry.
version_leaves_compact :: proc "contextless" (leaves: []format.Version_Leaf) -> (used: int) {
	to_leaf, to_place: int
	for from_leaf in 0 ..< len(leaves) {
		count := int(min(leaves[from_leaf].count, format.VERSION_LEAF_CAPACITY))
		for from_place in 0 ..< count {
			entry := leaves[from_leaf].entries[from_place]
			leaves[to_leaf].entries[to_place] = entry
			to_place += 1
			if to_place == format.VERSION_LEAF_CAPACITY {
				leaves[to_leaf].count = format.VERSION_LEAF_CAPACITY
				to_leaf += 1
				to_place = 0
			}
		}
	}
	// The writes above never pass the place that they read: to_leaf and
	// to_place stay at or before from_leaf and from_place.
	used = to_leaf
	if to_place != 0 {
		leaves[to_leaf].count = u64(to_place)
		for place in to_place ..< format.VERSION_LEAF_CAPACITY {
			leaves[to_leaf].entries[place] = {}
		}
		used += 1
	}
	for index in used ..< len(leaves) {
		leaves[index].count = 0
		leaves[index].entries = {}
	}
	return used
}
