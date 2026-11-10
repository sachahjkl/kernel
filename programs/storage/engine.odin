package storage_service

import "base:intrinsics"
import "contract:blake3"
import "contract:block"
import "contract:ring"
import "support:system"

// The format of the disk, and the one rule that keeps it whole.
//
// The disk is a row of blocks of 4096 bytes. Blocks 0 and 1 are the two
// places of the root block. Each other block is free, or it is a table, a
// list or a block of data. A block names another block with a Pointer: its
// number and the first 8 bytes of the BLAKE3 hash of its 4096 bytes.
//
//   root     the generation, and one Store_Entry for each private store
//   table    one for each store: one Object_Entry for each object
//   list     one for each object that has bytes: the Pointers of its data
//   data     the bytes of the object
//
// The rule (copy on write): a commit never writes a block that the root on
// the disk names. It writes each changed block to a free block, then the
// parents up to a new root, then the root in the place of the older of the
// two roots. Between these writes it asks the disk to keep what it wrote
// (Flush), so the blocks are on the disk before the root that names them.
// The root has its own check; at the start the service takes the valid root
// with the highest generation. A root that a stop of the machine cut is not
// valid: the root before it names blocks that no commit changed. So a store
// shows the state of one commit, never a part of one. Each block that a
// root names has its check in its Pointer: the start reads each one, and a
// change on the disk outside the service is found, not used.

BLOCK_SIZE :: block.BLOCK_SIZE
ROOT_MAGIC :: u64(0x31454741524F5453) // The bytes "STORAGE1".
STORE_CAPACITY :: 60
OBJECT_CAPACITY :: 48
LIST_CAPACITY :: 255
NAME_CAPACITY :: 32 // A name of a store: the name that the root service gives, with zero bytes after it.
OBJECT_NAME_CAPACITY :: 40
DISK_BLOCKS_LIMIT :: 1 << 18 // 1 GiB: the service uses no block after this.
OBJECT_BLOCKS_LIMIT :: 32 // The bytes of one object: 128 KiB.
REGION_BLOCKS :: 64 // The data region that the block service reads and writes.

Pointer :: struct {
	block: u64, // 0: no block.
	check: u64,
}

Store_Entry :: struct {
	name:  [NAME_CAPACITY]u8, // All zero: the place is free.
	limit: u64, // The most blocks of the store, as the last grant gave it.
	used:  u64, // The blocks of the store: its table, its lists, its data.
	table: Pointer,
}

Root :: struct {
	magic:       u64,
	generation:  u64,
	disk_blocks: u64,
	reserved:    [5]u64,
	stores:      [STORE_CAPACITY]Store_Entry,
	padding:     [BLOCK_SIZE - 64 - STORE_CAPACITY * size_of(Store_Entry) - 8]u8,
	check:       u64, // The hash of the bytes before it.
}

Object_Entry :: struct {
	name:       [OBJECT_NAME_CAPACITY]u8, // All zero: the place is free.
	size:       u64, // Bytes.
	generation: u64, // The commit of its last change.
	list:       Pointer, // No block for an object with no bytes.
}

Table :: struct {
	objects: [OBJECT_CAPACITY]Object_Entry,
	padding: [BLOCK_SIZE - OBJECT_CAPACITY * size_of(Object_Entry)]u8,
}

List :: struct {
	data:    [LIST_CAPACITY]Pointer,
	padding: [BLOCK_SIZE - LIST_CAPACITY * size_of(Pointer)]u8,
}

#assert(size_of(Root) == BLOCK_SIZE)
#assert(size_of(Table) == BLOCK_SIZE)
#assert(size_of(List) == BLOCK_SIZE)

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

check_of :: proc "contextless" (bytes: []u8) -> u64 {
	hash := blake3.hash(bytes)
	return intrinsics.unaligned_load((^u64)(&hash[0]))
}

root_check :: proc "contextless" (value: ^Root) -> u64 {
	return check_of(([^]u8)(value)[:offset_of(Root, check)])
}

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

// read_checked reads blocks and compares each one with the check of its
// Pointer. It gives the count of wrong blocks.
read_checked :: proc "contextless" (pointers: []Pointer, first_slot: u64) -> (wrong: u64, ok: bool) {
	requests: [REGION_BLOCKS]Request
	for pointer, index in pointers {
		requests[index] = {number = pointer.block, slot = first_slot + u64(index)}
		if pointer.block < 2 || pointer.block >= disk_size {
			return u64(len(pointers)), false
		}
	}
	if !transfer(.Read, requests[:len(pointers)]) {
		return u64(len(pointers)), false
	}
	for pointer, index in pointers {
		if check_of(slot(first_slot + u64(index))) != pointer.check {
			wrong += 1
		}
	}
	return wrong, wrong == 0
}

Mount :: struct {
	generation: u64,
	stores:     u64,
	objects:    u64,
	checked:    u64, // Blocks read and compared with their check.
	wrong:      u64,
	formatted:  bool,
	older:      bool, // The newest root named a wrong block: the root before it is used.
	cut:        u64, // Not 0: the generation that a root with a wrong check gives; the service does not use it.
	failed:     bool, // No root is usable: the service does not serve.
}

// walk reads each block that a root names, checks it, and marks it in use.
walk :: proc "contextless" (candidate: ^Root, result: ^Mount) -> bool {
	in_use = {}
	in_use_count = 0
	mark(0, true)
	mark(1, true)
	result.stores, result.objects, result.checked, result.wrong = 0, 0, 0, 0
	for &store, index in candidate.stores {
		if store.name[0] == 0 {
			continue
		}
		result.stores += 1
		wrong, _ := read_checked({store.table}, 0)
		result.checked += 1
		if wrong != 0 {
			result.wrong += wrong
			return false
		}
		intrinsics.mem_copy_non_overlapping(&tables[index], raw_data(slot(0)), BLOCK_SIZE)
		mark(store.table.block, true)
		for &object in tables[index].objects {
			if object.name[0] == 0 {
				continue
			}
			result.objects += 1
			if object.list.block == 0 {
				continue
			}
			wrong, _ = read_checked({object.list}, 0)
			result.checked += 1
			if wrong != 0 {
				result.wrong += wrong
				return false
			}
			list := (^List)(raw_data(slot(0)))^
			mark(object.list.block, true)
			count := (object.size + BLOCK_SIZE - 1) / BLOCK_SIZE
			if count > LIST_CAPACITY {
				result.wrong += 1
				return false
			}
			for start := u64(0); start < count; start += REGION_BLOCKS - 1 {
				part := list.data[start:min(count, start + REGION_BLOCKS - 1)]
				wrong, _ = read_checked(part, 1)
				result.checked += u64(len(part))
				if wrong != 0 {
					result.wrong += wrong
					return false
				}
				for pointer in part {
					mark(pointer.block, true)
				}
			}
		}
	}
	return true
}

// mount finds the root, reads and checks each block that it names, and
// formats a disk that has never had a root.
mount :: proc "contextless" (disk_blocks: u64) -> (result: Mount) {
	disk_size = min(disk_blocks, DISK_BLOCKS_LIMIT)
	candidates: [2]Root
	requests := [2]Request{{0, 0}, {1, 1}}
	if !transfer(.Read, requests[:]) {
		result.failed = true
		return result
	}
	empty := true
	for index in 0 ..< 2 {
		bytes := slot(u64(index))
		for byte in bytes {
			if byte != 0 {
				empty = false
			}
		}
		intrinsics.mem_copy_non_overlapping(&candidates[index], raw_data(bytes), BLOCK_SIZE)
	}
	valid :: proc "contextless" (candidate: ^Root) -> bool {
		return candidate.magic == ROOT_MAGIC && candidate.check == root_check(candidate) && candidate.disk_blocks >= 2 && candidate.disk_blocks <= disk_size
	}
	if empty {
		// A new disk: the first root, with no store.
		root = {magic = ROOT_MAGIC, generation = 1, disk_blocks = min(disk_blocks, DISK_BLOCKS_LIMIT)}
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
		return result
	}
	// The valid roots, the newest first.
	order := [2]int{0, 1}
	if candidates[1].generation > candidates[0].generation {
		order = {1, 0}
	}
	tried := 0
	for index in order {
		if !valid(&candidates[index]) {
			if candidates[index].magic == ROOT_MAGIC {
				result.cut = candidates[index].generation
			}
			continue
		}
		if tried == 1 {
			result.older = true
		}
		tried += 1
		if walk(&candidates[index], &result) {
			root = candidates[index]
			root_place = u64(index)
			result.generation = root.generation
			return result
		}
	}
	result.failed = true
	return result
}

// The result of a change, as the exports give it: a generation, or one of
// these numbers.
ERROR_NO_STORE :: -1 // The caller has no grant of a store.
ERROR_NO_BUDGET :: -2 // The store would have more blocks than its limit.
ERROR_NAME :: -3 // The name of the object is empty, or too long.
ERROR_TOO_LARGE :: -4 // The object would have more than OBJECT_BLOCKS_LIMIT blocks.
ERROR_FULL :: -5 // No place for one more object or store, or no free block on the disk.
ERROR_DISK :: -6 // The block service reported an error.
ERROR_ABSENT :: -7 // The store has no object with this name.

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

// change replaces one object of a store with bytes, or removes it (data
// nil and remove), in one commit. The store is made at its first change.
// It gives the generation of the commit, or an ERROR_ number.
change :: proc "contextless" (store_name: string, limit: u64, name: string, data: []u8, remove: bool) -> i64 {
	if len(store_name) == 0 || limit == 0 {
		return ERROR_NO_STORE
	}
	if broken {
		return ERROR_DISK
	}
	if len(name) == 0 || len(name) >= OBJECT_NAME_CAPACITY {
		return ERROR_NAME
	}
	count := (u64(len(data)) + BLOCK_SIZE - 1) / BLOCK_SIZE
	if count > OBJECT_BLOCKS_LIMIT {
		return ERROR_TOO_LARGE
	}
	store_index := store_find(store_name)
	next := root
	table: Table
	if store_index >= 0 {
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
	old_blocks := old.list.block != 0 ? 1 + (old.size + BLOCK_SIZE - 1) / BLOCK_SIZE : 0
	new_blocks := count != 0 ? 1 + count : 0
	if entry.used - old_blocks + new_blocks > limit && new_blocks > old_blocks {
		return ERROR_NO_BUDGET
	}
	// The old list names the old data: read it before the change.
	old_list: List
	if old.list.block != 0 {
		if wrong, ok := read_checked({old.list}, 0); !ok || wrong != 0 {
			return ERROR_DISK
		}
		old_list = (^List)(raw_data(slot(0)))^
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
	mark(old_table.block, false)
	if old.list.block != 0 {
		mark(old.list.block, false)
		for pointer in old_list.data[:(old.size + BLOCK_SIZE - 1) / BLOCK_SIZE] {
			mark(pointer.block, false)
		}
	}
	return i64(root.generation)
}

// read gives the bytes of an object, checked, in result. It gives the size
// of the object, or ERROR_ABSENT, ERROR_DISK.
read :: proc "contextless" (store_name: string, name: string, result: []u8) -> i64 {
	store_index := store_find(store_name)
	if store_index < 0 {
		return ERROR_ABSENT
	}
	object_index := object_find(&tables[store_index], name)
	if object_index < 0 {
		return ERROR_ABSENT
	}
	object := tables[store_index].objects[object_index]
	if object.list.block == 0 {
		return 0
	}
	if wrong, ok := read_checked({object.list}, 0); !ok || wrong != 0 {
		return ERROR_DISK
	}
	list := (^List)(raw_data(slot(0)))^
	count := (object.size + BLOCK_SIZE - 1) / BLOCK_SIZE
	if count > OBJECT_BLOCKS_LIMIT {
		return ERROR_DISK
	}
	if wrong, ok := read_checked(list.data[:count], 1); !ok || wrong != 0 {
		return ERROR_DISK
	}
	copy(result, region[BLOCK_SIZE:][:object.size])
	return i64(object.size)
}
