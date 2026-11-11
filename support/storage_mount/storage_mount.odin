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
	data: rawptr,
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
	// Faults of the engine itself, that no stop of the machine can make: a
	// block that the root names two times, and a store whose count of
	// blocks is not the count that its table names.
	named_twice:          u64,
	stores_with_wrong_count: u64,
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
		if format.check(into[index * BLOCK_SIZE:][:BLOCK_SIZE]) != pointer.check {
			wrong += 1
		}
	}
	return wrong, wrong == 0 ? .Good : .Wrong
}

// scratch_block gives one block of the scratch.
scratch_block :: proc "contextless" (state: ^State, index: int) -> []u8 {
	return state.scratch[index * BLOCK_SIZE:][:BLOCK_SIZE]
}

// walk reads each block that a root names, checks it, and marks it in use.
// A wrong block does not end the walk: its object, or its store for a
// table, is damaged. The blocks that a wrong table or a wrong list named
// are not known, so they are free. It gives false when the device reported
// an error.
walk :: proc "contextless" (state: ^State, reader: ^Block_Reader, candidate: ^format.Root, result: ^Mount) -> bool {
	state.in_use = {}
	state.in_use_count = 0
	mark(state, 0, true)
	mark(state, 1, true)
	state.tables = {}
	state.damaged = {}
	state.store_damaged = {}
	result.stores, result.objects, result.checked, result.wrong = 0, 0, 0, 0
	result.damaged_objects, result.damaged_stores, result.named_twice, result.stores_with_wrong_count = 0, 0, 0, 0
	for &store, index in candidate.stores {
		if store.name[0] == 0 {
			continue
		}
		result.stores += 1
		named: u64 = 1 // The table, then each list and each block of data.
		wrong, outcome := read_checked(state, reader, {store.table}, 0)
		result.checked += 1
		if outcome == .Device {
			return false
		}
		if !mark(state, store.table.block, true) {
			result.named_twice += 1
		}
		if outcome == .Wrong {
			result.wrong += wrong
			result.damaged_stores += 1
			state.store_damaged[index] = true
			continue
		}
		intrinsics.mem_copy_non_overlapping(&state.tables[index], raw_data(scratch_block(state, 0)), BLOCK_SIZE)
		complete := true // Each list of the store was read: its count of blocks is known.
		for &object, object_index in state.tables[index].objects {
			if object.name[0] == 0 {
				continue
			}
			result.objects += 1
			if object.list.block == 0 {
				continue
			}
			wrong, outcome = read_checked(state, reader, {object.list}, 0)
			result.checked += 1
			if outcome == .Device {
				return false
			}
			if !mark(state, object.list.block, true) {
				result.named_twice += 1
			}
			named += 1
			count := (object.size + BLOCK_SIZE - 1) / BLOCK_SIZE
			if outcome == .Wrong || count > format.OBJECT_BLOCKS_LIMIT {
				result.wrong += max(wrong, 1)
				result.damaged_objects += 1
				state.damaged[index] |= 1 << uint(object_index)
				complete = false
				continue
			}
			list := (^format.List)(raw_data(scratch_block(state, 0)))^
			part := list.data[:count]
			wrong, outcome = read_checked(state, reader, part, 1)
			result.checked += count
			if outcome == .Device {
				return false
			}
			if outcome == .Wrong {
				result.wrong += wrong
				result.damaged_objects += 1
				state.damaged[index] |= 1 << uint(object_index)
			}
			for pointer in part {
				if !mark(state, pointer.block, true) {
					result.named_twice += 1
				}
			}
			named += count
		}
		if complete && named != store.used {
			result.stores_with_wrong_count += 1
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

// object_bytes reads the bytes of an object of a store that the open
// walked, checked, into `into`. ok is false when the object is damaged or
// the device reported an error; size is its count of bytes.
object_bytes :: proc "contextless" (state: ^State, reader: ^Block_Reader, store_index: int, object_index: int, into: []u8) -> (size: u64, ok: bool) {
	object := state.tables[store_index].objects[object_index]
	if object.list.block == 0 {
		return 0, true
	}
	count := (object.size + BLOCK_SIZE - 1) / BLOCK_SIZE
	if count > format.OBJECT_BLOCKS_LIMIT || u64(len(into)) < object.size {
		return object.size, false
	}
	if _, outcome := read_checked(state, reader, {object.list}, 0); outcome != .Good {
		return object.size, false
	}
	list := (^format.List)(raw_data(scratch_block(state, 0)))^
	if _, outcome := read_checked(state, reader, list.data[:count], 1); outcome != .Good {
		return object.size, false
	}
	intrinsics.mem_copy_non_overlapping(raw_data(into), raw_data(state.scratch[BLOCK_SIZE:]), int(object.size))
	return object.size, true
}
