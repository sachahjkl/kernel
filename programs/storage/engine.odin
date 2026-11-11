package storage_service

import "base:intrinsics"
import "contract:block"
import "contract:errors"
import "contract:ring"
import format "contract:store"
import answers "support:storage"
import "support:storage_mount"
import "support:storage_retention"
import "support:system"

// The format of the disk, and the one rule that keeps it whole (copy on
// write), are in contract/store. The versions: docs/ARCHITECTURE.md, U5,
// "Versions".

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
RETENTION_INTERVAL :: 60 * 1000 // The retention rule runs on an object at most one time in this many milliseconds.

Pointer :: format.Pointer
Store_Entry :: format.Store_Entry
Root :: format.Root
Object_Entry :: format.Object_Entry
Table :: format.Table
List :: format.List
Version_Entry :: format.Version_Entry
Version_Leaf :: format.Version_Leaf
Version_Index :: format.Version_Index
Block :: [BLOCK_SIZE]u8

#assert(BLOCK_SIZE == block.BLOCK_SIZE)

// What the service knows of the disk. The tables of all stores stay in
// memory; lists, versions and data are read when a caller asks. The blocks
// in use and the reference count of each one are in `opened`, the state of
// the open (support/storage_mount), which the service keeps up to date.
root: Root
root_place: u64 // 0 or 1: the place of the root on the disk.
tables: [STORE_CAPACITY]Table
next_free: u64
time_at_start: u64 // The time since the format at the start of the service (the time of its root).
service_started: u64 // system.time() at the start of the service.

// The counts that stores() gives.
commits: u64
blocks_written: u64

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

// time_now gives the time since the format of the disk, in milliseconds:
// the time of the root at the start, and the time that the service ran
// since. The time while no machine ran is not counted: the date counts it.
time_now :: proc "contextless" () -> u64 {
	return time_at_start + (system.time() - service_started)
}

// date_now gives the date in seconds since 1970 (UTC), or 0 when the
// system has no date.
date_now :: proc "contextless" () -> u64 {
	return 0
}

slot :: #force_inline proc "contextless" (index: u64) -> []u8 {
	return region[index * BLOCK_SIZE:][:BLOCK_SIZE]
}

used :: proc "contextless" (number: u64) -> bool {
	return storage_mount.used(&opened, number)
}

mark :: proc "contextless" (number: u64, value: bool) {
	storage_mount.mark(&opened, number, value)
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

// read_checked reads blocks to the region, from `first_slot` on, and
// compares each one with the check of its Pointer. It gives the count of
// wrong blocks.
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

// The blocks that one name holds (a version index, a leaf) that the service
// wrote or read last: a commit that adds a version to an object reads
// nothing. An entry is found by its number and its check, so a block that
// was freed and written again is never taken for the old one.
Cached_Block :: struct {
	number: u64,
	check:  u64,
	used:   u64, // The count of reads at its last use.
	bytes:  Block,
}
block_cache: [16]Cached_Block
cache_reads: u64

cache_put :: proc "contextless" (pointer: Pointer, bytes: ^Block) {
	oldest := 0
	for &entry, index in block_cache {
		if entry.number == pointer.block {
			oldest = index
			break
		}
		if entry.used < block_cache[oldest].used {
			oldest = index
		}
	}
	cache_reads += 1
	block_cache[oldest] = {number = pointer.block, check = pointer.check, used = cache_reads}
	block_cache[oldest].bytes = bytes^
}

// read_single reads one block, checked, through the cache.
read_single :: proc "contextless" (pointer: Pointer, into: ^Block) -> Read {
	cache_reads += 1
	for &entry in block_cache {
		if entry.number == pointer.block && entry.check == pointer.check && pointer.block != 0 {
			entry.used = cache_reads
			into^ = entry.bytes
			return .Good
		}
	}
	_, state := read_checked({pointer}, 0)
	if state == .Good {
		intrinsics.mem_copy_non_overlapping(into, raw_data(slot(0)), BLOCK_SIZE)
		cache_put(pointer, into)
	}
	return state
}

Mount :: storage_mount.Mount

// The open of the disk: the same code as the check of the kernel tool on
// the host (support/storage_mount). The service keeps the blocks in use and
// their reference counts there.
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
	service_started = system.time()
	if result.failed {
		return result
	}
	if result.needs_format {
		root = {magic = ROOT_MAGIC, generation = 1, disk_blocks = disk_size, date = date_now()}
		root.check = root_check(&root)
		intrinsics.mem_copy_non_overlapping(raw_data(slot(0)), &root, BLOCK_SIZE)
		root_place = 1
		if !transfer(.Write, {{number = 1, slot = 0}}) || !flush() {
			result.failed = true
			return result
		}
		opened.in_use = {}
		opened.in_use_count = 0
		opened.references = {}
		opened.owner = {}
		opened.store_versions = {}
		mark(0, true)
		mark(1, true)
		result.generation = 1
		return result
	}
	root = opened.root
	root_place = opened.root_place
	tables = opened.tables
	damaged = opened.damaged
	store_damaged = opened.store_damaged
	time_at_start = root.time
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
ERROR_NO_VERSION :: answers.ERROR_NO_VERSION

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
// of an object is free. It writes the error record of a refusal; argument
// is the number of the argument of the name in the export.
name_keep :: proc "contextless" (given: string, error: ^errors.Error_Record, argument: i64 = 1) -> (kept: Object_Name, ok: bool) {
	if len(given) == 0 {
		errors.fail(error, ERROR_NAME, .Empty, .Bytes, argument, 0, OBJECT_NAME_CAPACITY - 1)
		return {}, false
	}
	if len(given) >= OBJECT_NAME_CAPACITY {
		errors.fail(error, ERROR_NAME, .Too_Long, .Bytes, argument, i64(len(given)), OBJECT_NAME_CAPACITY - 1)
		return {}, false
	}
	kept.count = copy(kept.bytes[:], given)
	for byte, offset in kept.bytes[:kept.count] {
		if byte == 0 {
			errors.fail(error, ERROR_NAME, .Bad_Byte, .Bytes, argument, i64(offset), 0, 0)
			return {}, false
		}
	}
	return kept, true
}

blocks_of :: proc "contextless" (size: u64) -> u64 {
	return (size + BLOCK_SIZE - 1) / BLOCK_SIZE
}

// ---------------------------------------------------------------------
// The plan of one commit. A commit is planned in memory: the blocks to
// write, the blocks it takes, the change of the reference count of each
// block that it names or stops naming, and the version work of each
// object. Nothing of the state of the service changes before the root is
// on the disk; a refusal or a failure drops the plan.

DELTA_CAPACITY :: 16384 // Power of 2: the blocks whose count one commit changes.
WRITE_CAPACITY :: 320
LEAF_WORK_CAPACITY :: 300

Write :: struct {
	number: u64,
	bytes:  ^Block,
}

Index_Work :: struct {
	loaded:   bool,
	touched:  bool,
	original: Pointer,
	index:    Version_Index,
}

Leaf_Work :: struct {
	object:   int,
	position: int, // In the leaves of the index as the commit found them; a new leaf after them.
	original: Pointer, // No block: a new leaf.
	changed:  bool,
	leaf:     Version_Leaf,
}

// A list that the commit stops naming one time, with the size of its state.
Release :: struct {
	list: Pointer,
	size: u64,
}

Plan :: struct {
	store_index: int,
	next:        Root,
	table:       Table,
	writes:      [WRITE_CAPACITY]Write,
	write_count: int,
	taken:       [WRITE_CAPACITY]u64, // Blocks that the plan allocated.
	taken_count: int,
	// The change of the reference counts: an open table of blocks.
	delta_blocks: [DELTA_CAPACITY]u64,
	delta_values: [DELTA_CAPACITY]i32,
	delta_places: [DELTA_CAPACITY]u32, // The places in use, for the walk and the reset.
	delta_count:  int,
	used_change:  i64, // The change of the distinct blocks of the store.
	full:         bool, // A table of the plan had no room: the commit is refused.
	device:       bool, // A read of the plan failed on the device.
	index_work:   [OBJECT_CAPACITY]Index_Work,
	leaf_work:    [LEAF_WORK_CAPACITY]Leaf_Work,
	leaf_count:   int,
	versions_change: i64,
	thinned:      u64, // Versions that the plan removes.
	// Staging of the blocks that the plan writes, other than leaves.
	data:         [OBJECT_BLOCKS_LIMIT]Block,
	list:         Block,
	table_block:  Block,
	index_blocks: [OBJECT_CAPACITY]Block,
	list_read:    Block,
}

plan: Plan

plan_reset :: proc "contextless" (store_index: int) {
	for place in plan.delta_places[:plan.delta_count] {
		plan.delta_blocks[place] = 0
		plan.delta_values[place] = 0
	}
	for &work in plan.index_work {
		work.loaded, work.touched = false, false
	}
	plan.delta_count = 0
	plan.write_count = 0
	plan.taken_count = 0
	plan.used_change = 0
	plan.full, plan.device = false, false
	plan.leaf_count = 0
	plan.versions_change = 0
	plan.thinned = 0
	plan.store_index = store_index
	later_count = 0
	plan.next = root
	plan.table = store_index >= 0 ? tables[store_index] : {}
}

// plan_drop frees the blocks that the plan allocated.
plan_drop :: proc "contextless" () {
	for number in plan.taken[:plan.taken_count] {
		mark(number, false)
	}
	plan.taken_count = 0
}

delta_place :: proc "contextless" (number: u64) -> (place: u32, found: bool) {
	mask := u64(DELTA_CAPACITY - 1)
	at := (number * 0x9E3779B97F4A7C15 >> 40) & mask
	for _ in 0 ..< DELTA_CAPACITY {
		if plan.delta_blocks[at] == number {
			return u32(at), true
		}
		if plan.delta_blocks[at] == 0 {
			return u32(at), false
		}
		at = (at + 1) & mask
	}
	return 0, false
}

delta_of :: proc "contextless" (number: u64) -> i64 {
	place, found := delta_place(number)
	return found ? i64(plan.delta_values[place]) : 0
}

// count_after gives the reference count of a block after the plan.
count_after :: proc "contextless" (number: u64) -> i64 {
	return i64(opened.references[number]) + delta_of(number)
}

// delta_add changes the reference count of a block in the plan, and the
// count of the distinct blocks of the store.
delta_add :: proc "contextless" (number: u64, change: i64) {
	if number < 2 || number >= DISK_BLOCKS_LIMIT {
		return
	}
	place, found := delta_place(number)
	if !found {
		if plan.delta_count >= DELTA_CAPACITY / 2 || plan.delta_blocks[place] != 0 {
			plan.full = true
			return
		}
		plan.delta_blocks[place] = number
		plan.delta_places[plan.delta_count] = place
		plan.delta_count += 1
	}
	before := i64(opened.references[number]) + i64(plan.delta_values[place])
	plan.delta_values[place] += i32(change)
	after := before + change
	plan.used_change += i64(after > 0) - i64(before > 0)
}

plan_allocate :: proc "contextless" () -> u64 {
	if plan.taken_count >= WRITE_CAPACITY {
		plan.full = true
		return 0
	}
	number := allocate()
	if number == 0 {
		plan.full = true
		return 0
	}
	plan.taken[plan.taken_count] = number
	plan.taken_count += 1
	delta_add(number, 1)
	return number
}

// plan_write writes a block of the plan to a new block, and gives its Pointer.
plan_write :: proc "contextless" (bytes: ^Block) -> Pointer {
	number := plan_allocate()
	if number == 0 || plan.write_count >= WRITE_CAPACITY {
		plan.full = true
		return {}
	}
	plan.writes[plan.write_count] = {number = number, bytes = bytes}
	plan.write_count += 1
	return {block = number, check = check_of(bytes[:])}
}

// list_name counts one more name of a list (a current version or a version).
list_name :: proc "contextless" (list: Pointer) {
	if list.block != 0 {
		delta_add(list.block, 1)
	}
}

// list_release counts one name less of a list of a state of `size` bytes.
// When no name is left, its blocks of data lose one name each: the list is
// read for that. A list with a wrong check gives its blocks no change: the
// next start finds them free.
list_release :: proc "contextless" (list: Pointer, size: u64) {
	if list.block == 0 {
		return
	}
	delta_add(list.block, -1)
	if count_after(list.block) != 0 {
		return
	}
	count := min(blocks_of(size), OBJECT_BLOCKS_LIMIT)
	switch read_single(list, &plan.list_read) {
	case .Device:
		plan.device = true
	case .Wrong:
	case .Good:
		data := (^List)(&plan.list_read)
		for pointer in data.data[:count] {
			delta_add(pointer.block, -1)
		}
	}
}

// index_load gives the version work of an object of the plan.
index_load :: proc "contextless" (object_index: int) -> ^Index_Work {
	work := &plan.index_work[object_index]
	if work.loaded {
		return work
	}
	work.loaded = true
	work.touched = false
	work.original = plan.table.objects[object_index].versions
	work.index = {}
	if work.original.block != 0 {
		switch read_single(work.original, (^Block)(&work.index)) {
		case .Device:
			plan.device = true
		case .Wrong:
			plan.full = true // The versions of the object are not known: no change of them.
		case .Good:
		}
	}
	return work
}

// leaf_load gives a leaf of the version work of an object.
leaf_load :: proc "contextless" (object_index: int, position: int) -> ^Leaf_Work {
	for &work in plan.leaf_work[:plan.leaf_count] {
		if work.object == object_index && work.position == position {
			return &work
		}
	}
	if plan.leaf_count >= LEAF_WORK_CAPACITY {
		plan.full = true
		return nil
	}
	index := index_load(object_index)
	work := &plan.leaf_work[plan.leaf_count]
	plan.leaf_count += 1
	work^ = {object = object_index, position = position}
	if position < int(index.index.leaf_count) && index.index.leaves[position].block != 0 {
		work.original = index.index.leaves[position]
		switch read_single(work.original, (^Block)(&work.leaf)) {
		case .Device:
			plan.device = true
		case .Wrong:
			plan.full = true
		case .Good:
		}
	}
	return work
}

// version_add adds a version at the end of the versions of an object.
version_add :: proc "contextless" (object_index: int, entry: Version_Entry) {
	index := index_load(object_index)
	if index.index.version_count >= format.VERSIONS_LIMIT {
		version_remove_first(object_index)
	}
	index.touched = true
	position := int(index.index.leaf_count) - 1
	leaf: ^Leaf_Work
	if position >= 0 {
		leaf = leaf_load(object_index, position)
	}
	if leaf == nil || leaf.leaf.count >= format.VERSION_LEAF_CAPACITY {
		if index.index.leaf_count >= format.VERSION_INDEX_CAPACITY {
			plan.full = true
			return
		}
		position = int(index.index.leaf_count)
		index.index.leaves[position] = {}
		index.index.leaf_count += 1
		leaf = leaf_load(object_index, position)
		if leaf == nil {
			return
		}
	}
	leaf.leaf.entries[leaf.leaf.count] = entry
	leaf.leaf.count += 1
	leaf.changed = true
	index.index.version_count += 1
	plan.versions_change += 1
}

// version_first gives the oldest version of an object in the plan.
version_first :: proc "contextless" (object_index: int) -> (leaf: ^Leaf_Work, found: bool) {
	index := index_load(object_index)
	for position in 0 ..< int(index.index.leaf_count) {
		work := leaf_load(object_index, position)
		if work == nil {
			return nil, false
		}
		if work.leaf.count != 0 {
			return work, true
		}
	}
	return nil, false
}

// version_remove_first thins the oldest version of an object.
version_remove_first :: proc "contextless" (object_index: int) {
	leaf, found := version_first(object_index)
	if !found {
		return
	}
	entry := leaf.leaf.entries[0]
	copy(leaf.leaf.entries[:leaf.leaf.count - 1], leaf.leaf.entries[1:leaf.leaf.count])
	leaf.leaf.count -= 1
	leaf.leaf.entries[leaf.leaf.count] = {}
	leaf.changed = true
	index := index_load(object_index)
	index.touched = true
	index.index.version_count -= 1
	plan.versions_change -= 1
	plan.thinned += 1
	list_release(entry.list, entry.size)
}

// versions_release removes all the versions of an object (its remove).
versions_release :: proc "contextless" (object_index: int) {
	index := index_load(object_index)
	for position in 0 ..< int(index.index.leaf_count) {
		leaf := leaf_load(object_index, position)
		if leaf == nil {
			return
		}
		for entry in leaf.leaf.entries[:leaf.leaf.count] {
			list_release(entry.list, entry.size)
		}
		plan.versions_change -= i64(leaf.leaf.count)
		leaf.leaf.count = 0
		leaf.changed = true
	}
	index.index.version_count = 0
	index.touched = true
}

// The times of the versions of one object, and what the rule keeps.
times: [format.VERSIONS_LIMIT]u64
keep: [format.VERSIONS_LIMIT]bool

// retention applies the retention rule to the versions of an object, when
// it did not run in the last minute.
retention :: proc "contextless" (object_index: int, now: u64) {
	index := index_load(object_index)
	if index.original.block == 0 || now < index.index.retention_time + RETENTION_INTERVAL {
		return
	}
	index.touched = true
	index.index.retention_time = now
	count := 0
	for position in 0 ..< int(index.index.leaf_count) {
		leaf := leaf_load(object_index, position)
		if leaf == nil {
			return
		}
		for entry in leaf.leaf.entries[:leaf.leaf.count] {
			times[count] = entry.time
			count += 1
		}
	}
	if storage_retention.keeps(times[:count], now, keep[:count]) == 0 {
		return
	}
	at := 0
	for position in 0 ..< int(index.index.leaf_count) {
		leaf := leaf_load(object_index, position)
		kept: u64
		for entry in leaf.leaf.entries[:leaf.leaf.count] {
			if keep[at] {
				leaf.leaf.entries[kept] = entry
				kept += 1
			} else {
				list_release(entry.list, entry.size)
				plan.thinned += 1
				plan.versions_change -= 1
				index.index.version_count -= 1
			}
			at += 1
		}
		if kept != leaf.leaf.count {
			for place in kept ..< leaf.leaf.count {
				leaf.leaf.entries[place] = {}
			}
			leaf.leaf.count = kept
			leaf.changed = true
		}
	}
}

// projected gives the distinct blocks of the store after the plan, with the
// leaves and the indexes that the plan still has to write.
projected :: proc "contextless" () -> i64 {
	change := plan.used_change
	for &index, object_index in plan.index_work {
		if !index.loaded || !index.touched {
			continue
		}
		left := 0
		for position in 0 ..< int(index.index.leaf_count) {
			leaf: ^Leaf_Work
			for &work in plan.leaf_work[:plan.leaf_count] {
				if work.object == object_index && work.position == position {
					leaf = &work
				}
			}
			original := position < len(index.index.leaves) ? index.index.leaves[position] : Pointer{}
			count := leaf != nil ? leaf.leaf.count : 1
			if count != 0 {
				left += 1
			}
			if original.block == 0 && count != 0 {
				change += 1
			} else if original.block != 0 && count == 0 {
				change -= 1
			}
		}
		if index.original.block == 0 && left != 0 {
			change += 1
		} else if index.original.block != 0 && left == 0 {
			change -= 1
		}
	}
	return i64(plan.next.stores[plan.store_index].used) + change
}

// oldest_object gives the object of the store with the oldest version.
oldest_object :: proc "contextless" () -> (object_index: int, found: bool) {
	best := max(u64)
	for &object, index in plan.table.objects {
		if object.name[0] == 0 || object.versions.block == 0 && !plan.index_work[index].touched {
			continue
		}
		leaf, has := version_first(index)
		if has && leaf.leaf.entries[0].generation < best {
			best = leaf.leaf.entries[0].generation
			object_index, found = index, true
		}
	}
	return object_index, found
}

// plan_finish writes the leaves and the indexes that changed, then the
// table; the plan names them and stops naming the blocks they replace.
plan_finish :: proc "contextless" () {
	for &index, object_index in plan.index_work {
		if !index.loaded || !index.touched {
			continue
		}
		next := index.index
		next.leaf_count = 0
		for position in 0 ..< int(index.index.leaf_count) {
			leaf: ^Leaf_Work
			for &work in plan.leaf_work[:plan.leaf_count] {
				if work.object == object_index && work.position == position {
					leaf = &work
				}
			}
			original := index.index.leaves[position]
			pointer := original
			if leaf != nil && leaf.changed {
				if original.block != 0 {
					delta_add(original.block, -1)
				}
				if leaf.leaf.count == 0 {
					continue
				}
				pointer = plan_write((^Block)(&leaf.leaf))
				if pointer.block != 0 {
					cache_later(pointer, (^Block)(&leaf.leaf))
				}
			}
			next.leaves[next.leaf_count] = pointer
			next.leaf_count += 1
		}
		for place in next.leaf_count ..< format.VERSION_INDEX_CAPACITY {
			next.leaves[place] = {}
		}
		if index.original.block != 0 {
			delta_add(index.original.block, -1)
		}
		object := &plan.table.objects[object_index]
		if next.leaf_count == 0 || object.name[0] == 0 {
			object.versions = {}
			continue
		}
		block_bytes := &plan.index_blocks[object_index]
		intrinsics.mem_copy_non_overlapping(block_bytes, &next, BLOCK_SIZE)
		object.versions = plan_write(block_bytes)
		if object.versions.block != 0 {
			cache_later(object.versions, block_bytes)
		}
	}
	entry := &plan.next.stores[plan.store_index]
	if entry.table.block != 0 {
		delta_add(entry.table.block, -1)
	}
	intrinsics.mem_copy_non_overlapping(&plan.table_block, &plan.table, BLOCK_SIZE)
	entry.table = plan_write(&plan.table_block)
}

// The leaves and indexes that the commit writes go to the cache after it.
later: [64]struct {
	pointer: Pointer,
	bytes:   ^Block,
}
later_count: int

cache_later :: proc "contextless" (pointer: Pointer, bytes: ^Block) {
	if later_count < len(later) {
		later[later_count] = {pointer, bytes}
		later_count += 1
	}
}

// plan_commit writes the blocks of the plan, then the root, and gives the
// new state to the service. It gives the generation, or an ERROR_ number
// with the record.
plan_commit :: proc "contextless" (error: ^errors.Error_Record) -> i64 {
	if plan.device {
		plan_drop()
		return errors.fail(error, ERROR_DISK, .Device)
	}
	if plan.full {
		plan_drop()
		return errors.fail(error, ERROR_FULL, .Full) // The disk, or a table of the commit: no number (P20).
	}
	entry := &plan.next.stores[plan.store_index]
	entry.used = u64(i64(entry.used) + plan.used_change)
	// The blocks, REGION_BLOCKS at a time, then the root. Each one is on the
	// disk before the next step.
	for first := 0; first < plan.write_count; first += REGION_BLOCKS {
		part := plan.writes[first:min(first + REGION_BLOCKS, plan.write_count)]
		requests: [REGION_BLOCKS]Request
		for write, index in part {
			intrinsics.mem_copy_non_overlapping(raw_data(slot(u64(index))), write.bytes, BLOCK_SIZE)
			requests[index] = {number = write.number, slot = u64(index)}
		}
		if !transfer(.Write, requests[:len(part)]) {
			plan_drop()
			return errors.fail(error, ERROR_DISK, .Device)
		}
	}
	if !flush() {
		plan_drop()
		return errors.fail(error, ERROR_DISK, .Device)
	}
	plan.next.generation = root.generation + 1
	plan.next.time = time_now()
	plan.next.date = date_now()
	plan.next.check = root_check(&plan.next)
	intrinsics.mem_copy_non_overlapping(raw_data(slot(0)), &plan.next, BLOCK_SIZE)
	place := 1 - root_place
	if !transfer(.Write, {{number = place, slot = 0}}) || !flush() {
		// The root on the disk is the old one, or the new one: the service
		// cannot know. It stops serving changes.
		plan_drop()
		broken = true
		return errors.fail(error, ERROR_DISK, .Device)
	}
	// The commit is on the disk: the service takes its state.
	root = plan.next
	root_place = place
	tables[plan.store_index] = plan.table
	commits += 1
	blocks_written += u64(plan.write_count) + 1
	opened.store_versions[plan.store_index] = u64(i64(opened.store_versions[plan.store_index]) + plan.versions_change)
	owner := u8(plan.store_index + 1)
	for place in plan.delta_places[:plan.delta_count] {
		number := plan.delta_blocks[place]
		before := i64(opened.references[number])
		after := max(before + i64(plan.delta_values[place]), 0)
		opened.references[number] = u16(min(after, i64(max(u16))))
		if before < 2 && after >= 2 {
			opened.store_shared[plan.store_index] += 1
		} else if before >= 2 && after < 2 {
			opened.store_shared[plan.store_index] -= 1
		}
		if after == 0 {
			mark(number, false)
			opened.owner[number] = 0
		} else {
			opened.owner[number] = owner
		}
	}
	for item in later[:later_count] {
		cache_put(item.pointer, item.bytes)
	}
	later_count = 0
	plan.taken_count = 0
	return i64(root.generation)
}

// ---------------------------------------------------------------------
// The operations.

// The store of a call: its index, or -1 when it has none yet, and its
// limit (the last grant).
Store_Of :: struct {
	name:  string,
	limit: u64,
}

// State_Of_Object is one state of an object: its current version or a
// version.
State_Of_Object :: struct {
	generation: u64,
	size:       u64,
	time:       u64,
	date:       u64,
	list:       Pointer,
	current:    bool,
}

// minimum gives the blocks that the current objects of the plan need, with
// no version: the table, and for each object its list and its data. A
// block that two objects share is counted two times.
minimum :: proc "contextless" () -> u64 {
	count: u64 = 1
	for &object in plan.table.objects {
		if object.name[0] != 0 && object.size != 0 {
			count += 1 + blocks_of(object.size)
		}
	}
	return count
}

Change_Kind :: enum {
	Write, // New bytes.
	Remove,
	Restore, // The state of a version.
	Clone, // The state of another object.
}

// change makes one commit that changes one object of a store: new bytes,
// its remove, the state of one of its versions, or the state of another
// object (a clone). The state before becomes a version. It gives the
// generation of the commit, or an ERROR_ number with the error record.
// `name_argument` is the argument of the name in the export.
change :: proc "contextless" (store: Store_Of, given: string, kind: Change_Kind, data: []u8, source: State_Of_Object, error: ^errors.Error_Record, name_argument: i64 = 1) -> i64 {
	if len(store.name) == 0 || store.limit == 0 {
		return errors.fail(error, ERROR_NO_STORE, .No_Grant, .Store)
	}
	if broken {
		return errors.fail(error, ERROR_DISK, .Device, .None, 0, 0, 0, 1)
	}
	kept, name_ok := name_keep(given, error, name_argument)
	if !name_ok {
		return ERROR_NAME
	}
	name := string(kept.bytes[:kept.count])
	count := blocks_of(u64(len(data)))
	if kind == .Write && count > OBJECT_BLOCKS_LIMIT {
		return errors.fail(error, ERROR_TOO_LARGE, .Too_Long, .Bytes, 2, i64(len(data)), OBJECT_BLOCKS_LIMIT * BLOCK_SIZE)
	}
	store_index := store_find(store.name)
	if store_index >= 0 && store_damaged[store_index] {
		return errors.fail(error, ERROR_DAMAGED, .Damaged, .Stores)
	}
	if store_index < 0 {
		if kind != .Write {
			return errors.fail(error, ERROR_ABSENT, .Absent, .Objects, name_argument)
		}
		for &entry, index in root.stores {
			if entry.name[0] == 0 {
				store_index = index
				break
			}
		}
		if store_index < 0 {
			return errors.fail(error, ERROR_FULL, .Full) // The disk: a fact of all the stores, with no number (P20).
		}
		plan_reset(store_index)
		plan.next.stores[store_index] = {}
		copy(plan.next.stores[store_index].name[:NAME_CAPACITY - 1], store.name)
	} else {
		plan_reset(store_index)
	}
	entry := &plan.next.stores[store_index]
	entry.limit = store.limit
	object_index := object_find(&plan.table, name)
	old: Object_Entry
	existed := object_index >= 0
	if existed {
		old = plan.table.objects[object_index]
	} else if kind == .Remove || kind == .Restore {
		return errors.fail(error, ERROR_ABSENT, .Absent, .Objects, name_argument)
	} else {
		for &object, index in plan.table.objects {
			if object.name[0] == 0 {
				object_index = index
				break
			}
		}
		if object_index < 0 {
			return errors.fail(error, ERROR_FULL, .Full, .Objects, 0, 0, OBJECT_CAPACITY)
		}
	}
	now := time_now()
	object := &plan.table.objects[object_index]
	if kind == .Remove {
		list_release(old.list, old.size)
		versions_release(object_index)
		plan_finish_object_removed(object_index)
		generation := plan_commit(error)
		if generation > 0 {
			damaged[store_index] &~= 1 << uint(object_index)
		}
		return generation
	}
	// The new current state.
	next := Object_Entry{generation = root.generation + 1, time = now, date = date_now(), versions = old.versions}
	copy(next.name[:OBJECT_NAME_CAPACITY - 1], name)
	switch kind {
	case .Write:
		next.size = u64(len(data))
	case .Restore, .Clone:
		next.size = source.size
		next.list = source.list
	case .Remove:
	}
	object^ = next
	// The current objects alone must fit: else the change is refused, and no
	// version is thinned.
	if needed := minimum(); needed > store.limit {
		return errors.fail(error, ERROR_NO_BUDGET, .Over_Limit, .Blocks, 2, i64(needed), i64(store.limit))
	}
	if kind == .Write && count != 0 {
		// The old list names the old data: a block whose bytes did not change
		// is named again, not written again.
		old_list: ^List
		if old.list.block != 0 && read_single(old.list, &plan.list_read) == .Good {
			old_list = (^List)(&plan.list_read)
		}
		new_list: List
		old_count := min(blocks_of(old.size), OBJECT_BLOCKS_LIMIT)
		for index in 0 ..< count {
			bytes := &plan.data[index]
			part := data[index * BLOCK_SIZE:]
			copy(bytes[:], part[:min(len(part), BLOCK_SIZE)])
			if len(part) < BLOCK_SIZE {
				intrinsics.mem_zero(raw_data(bytes[len(part):]), BLOCK_SIZE - len(part))
			}
			check := check_of(bytes[:])
			if old_list != nil && index < old_count && old_list.data[index].check == check && same_bytes(old_list.data[index], bytes) {
				new_list.data[index] = old_list.data[index]
				delta_add(new_list.data[index].block, 1)
				continue
			}
			new_list.data[index] = plan_write(bytes)
		}
		intrinsics.mem_copy_non_overlapping(&plan.list, &new_list, BLOCK_SIZE)
		object.list = plan_write(&plan.list)
	} else if kind != .Write {
		list_name(object.list)
	}
	// The state before becomes a version. A damaged state (a block with a
	// wrong check) is not kept: the change replaces it, and its blocks lose
	// this name.
	if existed && damaged[store_index] >> uint(object_index) & 1 != 0 {
		list_release(old.list, old.size)
	} else if existed {
		version_add(object_index, {generation = old.generation, size = old.size, time = old.time, date = old.date, list = old.list})
		retention(object_index, now)
	}
	// At the limit: the oldest versions of the store go, in this commit.
	thinned_before := plan.thinned
	for !plan.full && !plan.device && projected() > i64(store.limit) {
		oldest, found := oldest_object()
		if !found {
			break
		}
		version_remove_first(oldest)
	}
	at_limit := plan.thinned - thinned_before
	plan_finish()
	if !plan.full && !plan.device && i64(entry.used) + plan.used_change > i64(store.limit) {
		plan_drop()
		return errors.fail(error, ERROR_NO_BUDGET, .Over_Limit, .Blocks, 2, i64(entry.used) + plan.used_change, i64(store.limit))
	}
	generation := plan_commit(error)
	if generation > 0 {
		damaged[store_index] &~= 1 << uint(object_index)
		if at_limit != 0 && !limit_reached[store_index] {
			// One line for each store and each start of the service: the
			// later commits at the limit thin the same way.
			limit_reached[store_index] = true
			system.log("storage: the store ", store.name, " is at its limit of ", store.limit, " blocks: the commit of generation ", generation, " thinned ", at_limit, at_limit == 1 ? " version" : " versions", ", the oldest of the store first")
		}
	}
	return generation
}

limit_reached: [STORE_CAPACITY]bool

// plan_finish_object_removed frees the place of a removed object and
// writes the rest of the plan.
plan_finish_object_removed :: proc "contextless" (object_index: int) {
	plan.table.objects[object_index] = {}
	plan_finish()
}

// same_bytes says if a block on the disk has these bytes.
same_bytes :: proc "contextless" (pointer: Pointer, bytes: ^Block) -> bool {
	_, state := read_checked({pointer}, 0)
	if state != .Good {
		return false
	}
	for byte, index in slot(0) {
		if byte != bytes[index] {
			return false
		}
	}
	return true
}

// object_state gives the size of an object in bytes, or ERROR_NAME,
// ERROR_ABSENT, ERROR_DAMAGED.
object_state :: proc "contextless" (store_name: string, given: string, error: ^errors.Error_Record) -> i64 {
	store_index, object_index, found := object_locate(store_name, given, error)
	if !found {
		return i64(object_index)
	}
	if damaged[store_index] >> uint(object_index) & 1 != 0 {
		return errors.fail(error, ERROR_DAMAGED, .Damaged, .Objects, 1)
	}
	return i64(tables[store_index].objects[object_index].size)
}

// object_locate finds an object. When it is not found, object_index is the
// ERROR_ number, with the record.
object_locate :: proc "contextless" (store_name: string, given: string, error: ^errors.Error_Record, argument: i64 = 1) -> (store_index: int, object_index: int, found: bool) {
	kept, name_ok := name_keep(given, error, argument)
	if !name_ok {
		return -1, ERROR_NAME, false
	}
	store_index = store_find(store_name)
	if store_index < 0 {
		return -1, int(errors.fail(error, ERROR_ABSENT, .Absent, .Objects, argument)), false
	}
	if store_damaged[store_index] {
		return -1, int(errors.fail(error, ERROR_DAMAGED, .Damaged, .Stores)), false
	}
	object_index = object_find(&tables[store_index], string(kept.bytes[:kept.count]))
	if object_index < 0 {
		return -1, int(errors.fail(error, ERROR_ABSENT, .Absent, .Objects, argument)), false
	}
	return store_index, object_index, true
}

// state_bytes reads the bytes of one state of an object, checked, into
// result. It gives the size, or ERROR_DISK, ERROR_DAMAGED.
state_bytes :: proc "contextless" (state: State_Of_Object, result: []u8, error: ^errors.Error_Record) -> i64 {
	if state.list.block == 0 {
		return 0
	}
	count := blocks_of(state.size)
	outcome := Read.Wrong
	if count <= OBJECT_BLOCKS_LIMIT {
		_, outcome = read_checked({state.list}, 0)
		if outcome == .Good {
			list := (^List)(raw_data(slot(0)))^
			_, outcome = read_checked(list.data[:count], 1)
		}
	}
	switch outcome {
	case .Device:
		return errors.fail(error, ERROR_DISK, .Device)
	case .Wrong:
		return errors.fail(error, ERROR_DAMAGED, .Damaged, .Objects, 1)
	case .Good:
	}
	copy(result, region[BLOCK_SIZE:][:state.size])
	return i64(state.size)
}

// read gives the bytes of the current version of an object, checked, in
// result. It gives the size of the object, or ERROR_ABSENT, ERROR_DISK,
// ERROR_DAMAGED. Each read checks the blocks again: an object is damaged as
// long as a read finds a wrong block.
read :: proc "contextless" (store_name: string, given: string, result: []u8, error: ^errors.Error_Record) -> i64 {
	store_index, object_index, found := object_locate(store_name, given, error)
	if !found {
		return i64(object_index)
	}
	object := tables[store_index].objects[object_index]
	bit := u64(1) << uint(object_index)
	size := state_bytes(current_state(&object), result, error)
	if size == ERROR_DAMAGED {
		damaged[store_index] |= bit
	} else if size >= 0 {
		damaged[store_index] &~= bit
	}
	return size
}

current_state :: proc "contextless" (object: ^Object_Entry) -> State_Of_Object {
	return {generation = object.generation, size = object.size, time = object.time, date = object.date, list = object.list, current = true}
}

// The versions of one object, read for one call, the oldest first.
listed: [format.VERSIONS_LIMIT]Version_Entry
listed_count: int

// versions_list reads the versions of an object into `listed`.
versions_list :: proc "contextless" (object: ^Object_Entry, error: ^errors.Error_Record) -> i64 {
	listed_count = 0
	if object.versions.block == 0 {
		return 0
	}
	index: Version_Index
	switch read_single(object.versions, (^Block)(&index)) {
	case .Device:
		return errors.fail(error, ERROR_DISK, .Device)
	case .Wrong:
		return errors.fail(error, ERROR_DAMAGED, .Damaged, .Objects, 1)
	case .Good:
	}
	leaf: Version_Leaf
	leaves := index.leaves[:min(index.leaf_count, format.VERSION_INDEX_CAPACITY)]
	// The leaves, REGION_BLOCKS at a time: the cache holds the last ones.
	for first := 0; first < len(leaves); first += REGION_BLOCKS {
		part := leaves[first:min(first + REGION_BLOCKS, len(leaves))]
		_, outcome := read_checked(part, 0)
		switch outcome {
		case .Device:
			return errors.fail(error, ERROR_DISK, .Device)
		case .Wrong:
			return errors.fail(error, ERROR_DAMAGED, .Damaged, .Objects, 1)
		case .Good:
		}
		for place in 0 ..< len(part) {
			intrinsics.mem_copy_non_overlapping(&leaf, raw_data(slot(u64(place))), BLOCK_SIZE)
			for entry in leaf.entries[:min(leaf.count, format.VERSION_LEAF_CAPACITY)] {
				if listed_count < len(listed) {
					listed[listed_count] = entry
					listed_count += 1
				}
			}
		}
	}
	return i64(listed_count)
}

// state_at gives the state of an object at a generation: its current
// version, or the version with that generation.
state_at :: proc "contextless" (object: ^Object_Entry, generation: i64, argument: i64, error: ^errors.Error_Record) -> (state: State_Of_Object, result: i64) {
	if generation == i64(object.generation) {
		return current_state(object), 0
	}
	if count := versions_list(object, error); count < 0 {
		return {}, count
	}
	for entry in listed[:listed_count] {
		if i64(entry.generation) == generation {
			return {generation = entry.generation, size = entry.size, time = entry.time, date = entry.date, list = entry.list}, 0
		}
	}
	return {}, errors.fail(error, ERROR_NO_VERSION, .Absent, .Versions, argument, generation)
}

// own_blocks gives the blocks that only one state holds: its list, when no
// other state names it, and each of its blocks of data that no other list
// names.
own_blocks :: proc "contextless" (list: Pointer, size: u64, data: ^List) -> u64 {
	if list.block == 0 || opened.references[list.block] != 1 {
		return 0
	}
	count: u64 = 1
	for pointer in data.data[:min(blocks_of(size), OBJECT_BLOCKS_LIMIT)] {
		if pointer.block < DISK_BLOCKS_LIMIT && opened.references[pointer.block] == 1 {
			count += 1
		}
	}
	return count
}
