package storage_service

import "base:intrinsics"
import "contract:block"
import "contract:errors"
import "contract:ring"
import format "contract:store"
import answers "support:storage"
import "support:storage_mount"
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
				if good {
					// The first refusal of this batch goes on the log, with the
					// sentence of its error record.
					error := errors.completion_record(completion.values)
					text: [240]u8
					writer := system.Writer{buffer = text[:]}
					system.ring_error_text(&writer, &error, "block", block.command_name(error.operation), block.argument_name(error.operation, error.argument))
					system.log_in("disk", .Error, "storage: the block service refused a request: ", system.written(&writer))
				}
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

Mount :: storage_mount.Mount

// The open of the disk: the same code as the check of the kernel tool on
// the host (support/storage_mount). The service keeps a copy of what it
// found in its own tables.
opened: storage_mount.State

// read_through_block_service reads blocks for the open: through the data
// region, REGION_BLOCKS at a time.
read_through_block_service :: proc "contextless" (reader: ^storage_mount.Block_Reader, numbers: []u64, into: []u8) -> bool {
	for first := 0; first < len(numbers); first += REGION_BLOCKS {
		part := numbers[first:min(first + REGION_BLOCKS, len(numbers))]
		requests: [REGION_BLOCKS]Request
		for number, index in part {
			requests[index] = {number = number, slot = u64(index)}
		}
		if !transfer(.Read, requests[:len(part)]) {
			return false
		}
		intrinsics.mem_copy_non_overlapping(raw_data(into[first * BLOCK_SIZE:]), region, len(part) * BLOCK_SIZE)
	}
	return true
}

// mount opens the disk (storage_mount.mount), and formats a disk that has
// never had a commit: the first root goes to block 1.
mount :: proc "contextless" (disk_blocks: u64) -> (result: Mount) {
	reader := storage_mount.Block_Reader{read = read_through_block_service}
	result = storage_mount.mount(&opened, &reader, disk_blocks)
	disk_size = opened.disk_size
	if result.failed {
		return result
	}
	if result.needs_format {
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
		return result
	}
	root = opened.root
	root_place = opened.root_place
	tables = opened.tables
	in_use = opened.in_use
	in_use_count = opened.in_use_count
	damaged = opened.damaged
	store_damaged = opened.store_damaged
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
// of an object is free. The name is argument 1 of each export. It writes
// the error record of a refusal.
name_keep :: proc "contextless" (given: string, error: ^errors.Error_Record) -> (kept: Object_Name, ok: bool) {
	if len(given) == 0 {
		errors.fail(error, ERROR_NAME, .Empty, .Bytes, 1, 0, OBJECT_NAME_CAPACITY - 1)
		return {}, false
	}
	if len(given) >= OBJECT_NAME_CAPACITY {
		errors.fail(error, ERROR_NAME, .Too_Long, .Bytes, 1, i64(len(given)), OBJECT_NAME_CAPACITY - 1)
		return {}, false
	}
	kept.count = copy(kept.bytes[:], given)
	for byte, offset in kept.bytes[:kept.count] {
		if byte == 0 {
			errors.fail(error, ERROR_NAME, .Bad_Byte, .Bytes, 1, i64(offset), 0, 0)
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
change :: proc "contextless" (store_name: string, limit: u64, given: string, data: []u8, remove: bool, error: ^errors.Error_Record) -> i64 {
	if len(store_name) == 0 || limit == 0 {
		return errors.fail(error, ERROR_NO_STORE, .No_Grant, .Store)
	}
	if broken {
		return errors.fail(error, ERROR_DISK, .Device, .None, 0, 0, 0, 1)
	}
	kept, name_ok := name_keep(given, error)
	if !name_ok {
		return ERROR_NAME
	}
	name := string(kept.bytes[:kept.count])
	count := (u64(len(data)) + BLOCK_SIZE - 1) / BLOCK_SIZE
	if count > OBJECT_BLOCKS_LIMIT {
		return errors.fail(error, ERROR_TOO_LARGE, .Too_Long, .Bytes, 2, i64(len(data)), OBJECT_BLOCKS_LIMIT * BLOCK_SIZE)
	}
	store_index := store_find(store_name)
	next := root
	table: Table
	if store_index >= 0 {
		if store_damaged[store_index] {
			return errors.fail(error, ERROR_DAMAGED, .Damaged, .Stores)
		}
		table = tables[store_index]
	} else {
		if remove {
			return errors.fail(error, ERROR_ABSENT, .Absent, .Objects, 1)
		}
		for &store, index in root.stores {
			if store.name[0] == 0 {
				store_index = index
				break
			}
		}
		if store_index < 0 {
			return errors.fail(error, ERROR_FULL, .Full) // The disk: a fact of all the stores, with no number (P20).
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
		return errors.fail(error, ERROR_ABSENT, .Absent, .Objects, 1)
	} else {
		for &object, index in table.objects {
			if object.name[0] == 0 {
				object_index = index
				break
			}
		}
		if object_index < 0 {
			return errors.fail(error, ERROR_FULL, .Full, .Objects, 0, 0, OBJECT_CAPACITY)
		}
	}
	old_count := min((old.size + BLOCK_SIZE - 1) / BLOCK_SIZE, OBJECT_BLOCKS_LIMIT)
	old_blocks := old.list.block != 0 ? 1 + old_count : 0
	new_blocks := count != 0 ? 1 + count : 0
	if entry.used - old_blocks + new_blocks > limit && new_blocks > old_blocks {
		return errors.fail(error, ERROR_NO_BUDGET, .Over_Limit, .Blocks, 2, i64(entry.used - old_blocks + new_blocks), i64(limit))
	}
	// The old list names the old data: read it before the change. With a
	// wrong list the old data is not known: the next start finds it free.
	old_list: List
	old_list_known := false
	if old.list.block != 0 {
		_, state := read_checked({old.list}, 0)
		if state == .Device {
			return errors.fail(error, ERROR_DISK, .Device)
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
			return errors.fail(error, ERROR_FULL, .Full) // The disk: a fact of all the stores, with no number (P20).
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
				return errors.fail(error, ERROR_FULL, .Full) // The disk: a fact of all the stores, with no number (P20).
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
		return errors.fail(error, ERROR_FULL, .Full) // The disk: a fact of all the stores, with no number (P20).
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
		return errors.fail(error, ERROR_DISK, .Device)
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
		return errors.fail(error, ERROR_DISK, .Device)
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

// object_state gives the size of an object in bytes, or ERROR_NAME,
// ERROR_ABSENT, ERROR_DAMAGED.
object_state :: proc "contextless" (store_name: string, given: string, error: ^errors.Error_Record) -> i64 {
	kept, name_ok := name_keep(given, error)
	if !name_ok {
		return ERROR_NAME
	}
	store_index := store_find(store_name)
	if store_index < 0 {
		return errors.fail(error, ERROR_ABSENT, .Absent, .Objects, 1)
	}
	if store_damaged[store_index] {
		return errors.fail(error, ERROR_DAMAGED, .Damaged, .Stores)
	}
	object_index := object_find(&tables[store_index], string(kept.bytes[:kept.count]))
	if object_index < 0 {
		return errors.fail(error, ERROR_ABSENT, .Absent, .Objects, 1)
	}
	if damaged[store_index] >> uint(object_index) & 1 != 0 {
		return errors.fail(error, ERROR_DAMAGED, .Damaged, .Objects, 1)
	}
	return i64(tables[store_index].objects[object_index].size)
}

// read gives the bytes of an object, checked, in result. It gives the size
// of the object, or ERROR_ABSENT, ERROR_DISK, ERROR_DAMAGED. Each read
// checks the blocks again: an object is damaged as long as a read finds a
// wrong block.
read :: proc "contextless" (store_name: string, given: string, result: []u8, error: ^errors.Error_Record) -> i64 {
	kept, name_ok := name_keep(given, error)
	if !name_ok {
		return ERROR_NAME
	}
	store_index := store_find(store_name)
	if store_index < 0 {
		return errors.fail(error, ERROR_ABSENT, .Absent, .Objects, 1)
	}
	if store_damaged[store_index] {
		return errors.fail(error, ERROR_DAMAGED, .Damaged, .Stores)
	}
	object_index := object_find(&tables[store_index], string(kept.bytes[:kept.count]))
	if object_index < 0 {
		return errors.fail(error, ERROR_ABSENT, .Absent, .Objects, 1)
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
		return errors.fail(error, ERROR_DISK, .Device)
	case .Wrong:
		damaged[store_index] |= bit
		return errors.fail(error, ERROR_DAMAGED, .Damaged, .Objects, 1)
	case .Good:
		damaged[store_index] &~= bit
	}
	copy(result, region[BLOCK_SIZE:][:object.size])
	return i64(object.size)
}
