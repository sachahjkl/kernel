package storage_service

import "base:intrinsics"
import "contract:block"
import "contract:ring"
import format "contract:store"
import answers "support:storage"
import "support:system"

// The format of the disk, and the one rule that keeps it whole (copy on
// write), are in contract/store.

BLOCK_SIZE :: format.BLOCK_SIZE
ROOT_MAGIC :: format.ROOT_MAGIC
STORE_CAPACITY :: format.STORE_CAPACITY
OBJECT_CAPACITY :: format.OBJECT_CAPACITY
LIST_CAPACITY :: format.LIST_CAPACITY
NAME_CAPACITY :: format.NAME_CAPACITY
OBJECT_NAME_CAPACITY :: format.OBJECT_NAME_CAPACITY
DISK_BLOCKS_LIMIT :: format.DISK_BLOCKS_LIMIT
OBJECT_BLOCKS_LIMIT :: format.OBJECT_BLOCKS_LIMIT
REGION_BLOCKS :: 64 // The data region that the block service reads and writes.

Pointer :: format.Pointer
Store_Entry :: format.Store_Entry
Root :: format.Root
Object_Entry :: format.Object_Entry
Table :: format.Table
List :: format.List

#assert(BLOCK_SIZE == block.BLOCK_SIZE)

// What the service knows of the disk. The tables of all stores stay in
// memory; lists and data are read when a caller asks.
root: Root
root_place: u64 // 0 or 1: the place of the root on the disk.
tables: [STORE_CAPACITY]Table
in_use: [DISK_BLOCKS_LIMIT / 64]u64 // Bit n: block n is named by the root on the disk, or by the commit in progress.
in_use_count: u64
next_free: u64

// The block service.
blocks: ring.Ring
region: [^]u8
disk_tag: u32
disk_errors: u64
disk_size: u64 // The blocks of the disk that the service uses.
broken: bool // A write of a root failed: the service does not know which root the disk has, and makes no change.

check_of :: format.check
root_check :: format.root_check

// Damage: a block that a valid root names has a wrong check. The service
// does not use the block. An object with such a list or such data is
// damaged: a read of it gives ERROR_DAMAGED, and a write or a remove
// replaces it. A store with such a table is damaged: the service does not
// know its objects, and refuses each call for it. The other objects and
// the other stores are served.
damaged: [STORE_CAPACITY]u64 // Bit n: the object n of the store is damaged.
store_damaged: [STORE_CAPACITY]bool

slot :: #force_inline proc "contextless" (index: u64) -> []u8 {
	return region[index * BLOCK_SIZE:][:BLOCK_SIZE]
}

used :: proc "contextless" (number: u64) -> bool {
	return in_use[number / 64] >> (number % 64) & 1 != 0
}

mark :: proc "contextless" (number: u64, value: bool) {
	if number >= DISK_BLOCKS_LIMIT || used(number) == value {
		return
	}
	if value {
		in_use[number / 64] |= 1 << (number % 64)
		in_use_count += 1
	} else {
		in_use[number / 64] &~= 1 << (number % 64)
		in_use_count -= 1
	}
}

// allocate gives a free block and marks it, or 0 when the disk is full.
allocate :: proc "contextless" () -> u64 {
	for _ in 0 ..< root.disk_blocks {
		if next_free < 2 || next_free >= root.disk_blocks {
			next_free = 2
		}
		number := next_free
		next_free += 1
		if !used(number) {
			mark(number, true)
			return number
		}
	}
	return 0
}

// A request to the block service: one block, to or from one slot of the region.
Request :: struct {
	number: u64,
	slot:   u64,
}

// transfer reads or writes blocks: all are in flight at the same time.
transfer :: proc "contextless" (command: block.Command, requests: []Request) -> bool {
	first := disk_tag
	sent := 0
	done := 0
	good := true
	for done < len(requests) {
		for sent < len(requests) {
			request := requests[sent]
			record := ring.Record{kind = u32(command), tag = first + u32(sent), values = {0 = request.number, 1 = 1, 2 = request.slot * BLOCK_SIZE}}
			if !ring.push(&blocks.commands, record) {
				break
			}
			sent += 1
		}
		system.wake_reader(&blocks.commands)
		for {
			completion, ok := system.receive(&blocks.completions)
			if !ok {
				break
			}
			done += 1
			if block.Status(completion.kind) != .Ok {
				good = false
			}
		}
		if done < len(requests) {
			wait: system.Wait
			system.wait_records(&wait, &blocks.completions)
			if sent < len(requests) {
				system.wait_room(&wait, &blocks.commands)
			}
			if !system.wait_spin(&wait) {
				system.wait_end(&wait)
			}
		}
	}
	disk_tag += u32(len(requests))
	if !good {
		disk_errors += 1
	}
	return good
}

// command sends one command with no data and waits for its completion.
command :: proc "contextless" (kind: block.Command, values: [7]u64 = {}) -> ring.Record {
	disk_tag += 1
	tag := disk_tag
	for !system.send(&blocks.commands, ring.Record{kind = u32(kind), tag = tag, values = values}) {
		wait: system.Wait
		system.wait_room(&wait, &blocks.commands)
		system.wait_end(&wait)
	}
	for {
		for {
			completion, ok := system.receive(&blocks.completions)
			if !ok {
				break
			}
			if completion.tag == tag {
				return completion
			}
		}
		wait: system.Wait
		system.wait_records(&wait, &blocks.completions)
		if !system.wait_spin(&wait) {
			system.wait_end(&wait)
		}
	}
}

flush :: proc "contextless" () -> bool {
	return block.Status(command(.Flush).kind) == .Ok
}

Read :: enum {
	Good,
	Wrong, // A block does not have the check of its Pointer, or a Pointer names no block of the disk.
	Device, // The block service reported an error: the service knows nothing of the blocks.
}

// read_checked reads blocks and compares each one with the check of its
// Pointer. It gives the count of wrong blocks.
read_checked :: proc "contextless" (pointers: []Pointer, first_slot: u64) -> (wrong: u64, state: Read) {
	requests: [REGION_BLOCKS]Request
	for pointer, index in pointers {
		if pointer.block < 2 || pointer.block >= disk_size {
			return u64(len(pointers)), .Wrong
		}
		requests[index] = {number = pointer.block, slot = first_slot + u64(index)}
	}
	if !transfer(.Read, requests[:len(pointers)]) {
		return 0, .Device
	}
	for pointer, index in pointers {
		if check_of(slot(first_slot + u64(index))) != pointer.check {
			wrong += 1
		}
	}
	return wrong, wrong == 0 ? .Good : .Wrong
}

Mount :: struct {
	generation:      u64,
	stores:          u64,
	objects:         u64,
	checked:         u64, // Blocks read and compared with their check.
	wrong:           u64,
	damaged_objects: u64,
	damaged_stores:  u64,
	formatted:       bool,
	first_cut:       bool, // The disk had only a first root with a wrong check: a format that a stop cut.
	older:           bool, // The newest root named a wrong block and the root before it names none: the root before it is used.
	cut:             u64, // Not 0: the generation that a root with a wrong check gives; the service does not use it.
	failed:          bool, // No root is usable, or the block service reported an error: the service does not serve.
}

// walk reads each block that a root names, checks it, and marks it in use.
// A wrong block does not end the walk: its object, or its store for a
// table, is damaged. The blocks that a wrong table or a wrong list named
// are not known, so they are free. It gives false when the block service
// reported an error.
walk :: proc "contextless" (candidate: ^Root, result: ^Mount) -> bool {
	in_use = {}
	in_use_count = 0
	mark(0, true)
	mark(1, true)
	tables = {}
	damaged = {}
	store_damaged = {}
	result.stores, result.objects, result.checked, result.wrong = 0, 0, 0, 0
	result.damaged_objects, result.damaged_stores = 0, 0
	for &store, index in candidate.stores {
		if store.name[0] == 0 {
			continue
		}
		result.stores += 1
		wrong, state := read_checked({store.table}, 0)
		result.checked += 1
		if state == .Device {
			return false
		}
		mark(store.table.block, true)
		if state == .Wrong {
			result.wrong += wrong
			result.damaged_stores += 1
			store_damaged[index] = true
			continue
		}
		intrinsics.mem_copy_non_overlapping(&tables[index], raw_data(slot(0)), BLOCK_SIZE)
		for &object, object_index in tables[index].objects {
			if object.name[0] == 0 {
				continue
			}
			result.objects += 1
			if object.list.block == 0 {
				continue
			}
			wrong, state = read_checked({object.list}, 0)
			result.checked += 1
			if state == .Device {
				return false
			}
			mark(object.list.block, true)
			count := (object.size + BLOCK_SIZE - 1) / BLOCK_SIZE
			if state == .Wrong || count > OBJECT_BLOCKS_LIMIT {
				result.wrong += max(wrong, 1)
				result.damaged_objects += 1
				damaged[index] |= 1 << uint(object_index)
				continue
			}
			list := (^List)(raw_data(slot(0)))^
			part := list.data[:count]
			wrong, state = read_checked(part, 1)
			result.checked += count
			if state == .Device {
				return false
			}
			if state == .Wrong {
				result.wrong += wrong
				result.damaged_objects += 1
				damaged[index] |= 1 << uint(object_index)
			}
			for pointer in part {
				mark(pointer.block, true)
			}
		}
	}
	return true
}

// mount finds the root, reads and checks each block that it names, and
// formats a disk that has never had a commit.
//
// Which root: the valid root with the highest generation, when it names no
// wrong block. If it names one, and the valid root before it names none,
// the root before it: the last commit was not whole on the disk (a device
// that did not keep what a Flush promised). If each valid root names a
// wrong block, the newest one, with its damage: a block that both name was
// changed after its commit, and no root is better.
mount :: proc "contextless" (disk_blocks: u64) -> (result: Mount) {
	disk_size = min(disk_blocks, DISK_BLOCKS_LIMIT)
	candidates: [2]Root
	requests := [2]Request{{0, 0}, {1, 1}}
	if !transfer(.Read, requests[:]) {
		result.failed = true
		return result
	}
	zero := [2]bool{true, true}
	for index in 0 ..< 2 {
		bytes := slot(u64(index))
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
	// format that a stop cut, and the service formats again.
	if zero[0] && (zero[1] || !format.root_valid(&candidates[1], disk_size)) {
		root = {magic = ROOT_MAGIC, generation = 1, disk_blocks = disk_size}
		root.check = root_check(&root)
		intrinsics.mem_copy_non_overlapping(raw_data(slot(0)), &root, BLOCK_SIZE)
		root_place = 1
		if !transfer(.Write, {{number = 1, slot = 0}}) || !flush() {
			result.failed = true
			return result
		}
		in_use = {}
		in_use_count = 0
		mark(0, true)
		mark(1, true)
		result.generation = 1
		result.formatted = true
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
		if !format.root_valid(&candidates[index], disk_size) {
			if candidates[index].magic == ROOT_MAGIC {
				result.cut = candidates[index].generation
			}
			continue
		}
		if first < 0 {
			first = index
		}
		if !walk(&candidates[index], &result) {
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
		if !walk(&candidates[first], &result) {
			result.failed = true
			return result
		}
		walked = first
	}
	result.older = walked != first
	root = candidates[walked]
	root_place = u64(walked)
	result.generation = root.generation
	return result
}

// The ERROR_ numbers are in support/storage: the client reads them too.
ERROR_NO_STORE :: answers.ERROR_NO_STORE
ERROR_NO_BUDGET :: answers.ERROR_NO_BUDGET
ERROR_NAME :: answers.ERROR_NAME
ERROR_TOO_LARGE :: answers.ERROR_TOO_LARGE
ERROR_FULL :: answers.ERROR_FULL
ERROR_DISK :: answers.ERROR_DISK
ERROR_ABSENT :: answers.ERROR_ABSENT
ERROR_DAMAGED :: answers.ERROR_DAMAGED

store_find :: proc "contextless" (name: string) -> int {
	for &store, index in root.stores {
		if store.name[0] != 0 && system.name_of(store.name[:]) == name {
			return index
		}
	}
	return -1
}

object_find :: proc "contextless" (table: ^Table, name: string) -> int {
	for &object, index in table.objects {
		if object.name[0] != 0 && system.name_of(object.name[:]) == name {
			return index
		}
	}
	return -1
}

// The name of an object, as the service keeps it for one call. The bytes
// of a name that a caller gives are in the call region, and the caller can
// change them at any time: the service copies them one time, then checks
// and uses the copy only.
Object_Name :: struct {
	bytes: [OBJECT_NAME_CAPACITY]u8,
	count: int,
}

// name_keep copies a name. It refuses an empty name, a name that does not
// fit with one zero byte after it, and a name with a zero byte: a zero
// byte ends a name on the disk, and a first zero byte says that the place
// of an object is free.
name_keep :: proc "contextless" (given: string) -> (kept: Object_Name, ok: bool) {
	if len(given) == 0 || len(given) >= OBJECT_NAME_CAPACITY {
		return {}, false
	}
	kept.count = copy(kept.bytes[:], given)
	for byte in kept.bytes[:kept.count] {
		if byte == 0 {
			return {}, false
		}
	}
	return kept, true
}

// change replaces one object of a store with bytes, or removes it (data
// nil and remove), in one commit. The store is made at its first change.
// It gives the generation of the commit, or an ERROR_ number. It does not
// need the old blocks of the object: a damaged object can be replaced and
// removed.
change :: proc "contextless" (store_name: string, limit: u64, given: string, data: []u8, remove: bool) -> i64 {
	if len(store_name) == 0 || limit == 0 {
		return ERROR_NO_STORE
	}
	if broken {
		return ERROR_DISK
	}
	kept, name_ok := name_keep(given)
	if !name_ok {
		return ERROR_NAME
	}
	name := string(kept.bytes[:kept.count])
	count := (u64(len(data)) + BLOCK_SIZE - 1) / BLOCK_SIZE
	if count > OBJECT_BLOCKS_LIMIT {
		return ERROR_TOO_LARGE
	}
	store_index := store_find(store_name)
	next := root
	table: Table
	if store_index >= 0 {
		if store_damaged[store_index] {
			return ERROR_DAMAGED
		}
		table = tables[store_index]
	} else {
		if remove {
			return ERROR_ABSENT
		}
		for &store, index in root.stores {
			if store.name[0] == 0 {
				store_index = index
				break
			}
		}
		if store_index < 0 {
			return ERROR_FULL
		}
		next.stores[store_index] = {used = 1}
		copy(next.stores[store_index].name[:NAME_CAPACITY - 1], store_name)
	}
	entry := &next.stores[store_index]
	entry.limit = limit
	object_index := object_find(&table, name)
	old: Object_Entry
	if object_index >= 0 {
		old = table.objects[object_index]
	} else if remove {
		return ERROR_ABSENT
	} else {
		for &object, index in table.objects {
			if object.name[0] == 0 {
				object_index = index
				break
			}
		}
		if object_index < 0 {
			return ERROR_FULL
		}
	}
	old_count := min((old.size + BLOCK_SIZE - 1) / BLOCK_SIZE, OBJECT_BLOCKS_LIMIT)
	old_blocks := old.list.block != 0 ? 1 + old_count : 0
	new_blocks := count != 0 ? 1 + count : 0
	if entry.used - old_blocks + new_blocks > limit && new_blocks > old_blocks {
		return ERROR_NO_BUDGET
	}
	// The old list names the old data: read it before the change. With a
	// wrong list the old data is not known: the next start finds it free.
	old_list: List
	old_list_known := false
	if old.list.block != 0 {
		_, state := read_checked({old.list}, 0)
		if state == .Device {
			return ERROR_DISK
		}
		if state == .Good {
			old_list = (^List)(raw_data(slot(0)))^
			old_list_known = true
		}
	}

	// New blocks: the data, the list, the table. Slot 0 is the root, slot 1
	// the table, slot 2 the list, then the data.
	taken: [OBJECT_BLOCKS_LIMIT + 2]u64
	taken_count := 0
	undo :: proc "contextless" (taken: []u64) {
		for number in taken {
			mark(number, false)
		}
	}
	requests: [OBJECT_BLOCKS_LIMIT + 2]Request
	list: List
	for index in 0 ..< count {
		number := allocate()
		if number == 0 {
			undo(taken[:taken_count])
			return ERROR_FULL
		}
		taken[taken_count] = number
		taken_count += 1
		bytes := slot(3 + index)
		part := data[index * BLOCK_SIZE:]
		copy(bytes, part[:min(len(part), BLOCK_SIZE)])
		if len(part) < BLOCK_SIZE {
			intrinsics.mem_zero(raw_data(bytes[len(part):]), BLOCK_SIZE - len(part))
		}
		list.data[index] = {block = number, check = check_of(bytes)}
		requests[index] = {number = number, slot = 3 + index}
	}
	request_count := int(count)
	if remove {
		table.objects[object_index] = {}
	} else {
		object := &table.objects[object_index]
		object^ = {size = u64(len(data)), generation = root.generation + 1}
		copy(object.name[:OBJECT_NAME_CAPACITY - 1], name)
		if count != 0 {
			number := allocate()
			if number == 0 {
				undo(taken[:taken_count])
				return ERROR_FULL
			}
			taken[taken_count] = number
			taken_count += 1
			intrinsics.mem_copy_non_overlapping(raw_data(slot(2)), &list, BLOCK_SIZE)
			object.list = {block = number, check = check_of(slot(2))}
			requests[request_count] = {number = number, slot = 2}
			request_count += 1
		}
	}
	table_number := allocate()
	if table_number == 0 {
		undo(taken[:taken_count])
		return ERROR_FULL
	}
	taken[taken_count] = table_number
	taken_count += 1
	intrinsics.mem_copy_non_overlapping(raw_data(slot(1)), &table, BLOCK_SIZE)
	old_table := entry.table
	entry.table = {block = table_number, check = check_of(slot(1))}
	entry.used = entry.used - old_blocks + new_blocks
	requests[request_count] = {number = table_number, slot = 1}
	request_count += 1

	// The blocks, then the root. Each one is on the disk before the next step.
	if !transfer(.Write, requests[:request_count]) || !flush() {
		undo(taken[:taken_count])
		return ERROR_DISK
	}
	next.generation = root.generation + 1
	next.check = root_check(&next)
	intrinsics.mem_copy_non_overlapping(raw_data(slot(0)), &next, BLOCK_SIZE)
	place := 1 - root_place
	if !transfer(.Write, {{number = place, slot = 0}}) || !flush() {
		// The root on the disk is the old one, or the new one: the service
		// cannot know. It stops serving changes.
		undo(taken[:taken_count])
		broken = true
		return ERROR_DISK
	}
	// The commit is on the disk. What the old root named and the new one
	// does not is free for the next commit.
	root = next
	root_place = place
	tables[store_index] = table
	damaged[store_index] &~= 1 << uint(object_index)
	mark(old_table.block, false)
	if old.list.block != 0 {
		mark(old.list.block, false)
		if old_list_known {
			for pointer in old_list.data[:old_count] {
				mark(pointer.block, false)
			}
		}
	}
	return i64(root.generation)
}

// object_state gives the size of an object in bytes, or ERROR_ABSENT,
// ERROR_DAMAGED.
object_state :: proc "contextless" (store_name: string, given: string) -> i64 {
	kept, name_ok := name_keep(given)
	store_index := store_find(store_name)
	if !name_ok || store_index < 0 {
		return ERROR_ABSENT
	}
	if store_damaged[store_index] {
		return ERROR_DAMAGED
	}
	object_index := object_find(&tables[store_index], string(kept.bytes[:kept.count]))
	if object_index < 0 {
		return ERROR_ABSENT
	}
	if damaged[store_index] >> uint(object_index) & 1 != 0 {
		return ERROR_DAMAGED
	}
	return i64(tables[store_index].objects[object_index].size)
}

// read gives the bytes of an object, checked, in result. It gives the size
// of the object, or ERROR_ABSENT, ERROR_DISK, ERROR_DAMAGED. Each read
// checks the blocks again: an object is damaged as long as a read finds a
// wrong block.
read :: proc "contextless" (store_name: string, given: string, result: []u8) -> i64 {
	kept, name_ok := name_keep(given)
	store_index := store_find(store_name)
	if !name_ok || store_index < 0 {
		return ERROR_ABSENT
	}
	if store_damaged[store_index] {
		return ERROR_DAMAGED
	}
	object_index := object_find(&tables[store_index], string(kept.bytes[:kept.count]))
	if object_index < 0 {
		return ERROR_ABSENT
	}
	object := tables[store_index].objects[object_index]
	if object.list.block == 0 {
		return 0
	}
	bit := u64(1) << uint(object_index)
	count := (object.size + BLOCK_SIZE - 1) / BLOCK_SIZE
	_, state := read_checked({object.list}, 0)
	if state == .Good && count <= OBJECT_BLOCKS_LIMIT {
		list := (^List)(raw_data(slot(0)))^
		_, state = read_checked(list.data[:count], 1)
	} else if state == .Good {
		state = .Wrong
	}
	switch state {
	case .Device:
		return ERROR_DISK
	case .Wrong:
		damaged[store_index] |= bit
		return ERROR_DAMAGED
	case .Good:
		damaged[store_index] &~= bit
	}
	copy(result, region[BLOCK_SIZE:][:object.size])
	return i64(object.size)
}
