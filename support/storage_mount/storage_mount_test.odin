#+build !freestanding
package storage_mount

import format "contract:store"
import "core:testing"

// A disk built in memory, block by block, and read through a Block_Reader.
Test_Disk :: struct {
	using reader: Block_Reader,
	bytes:        []u8,
	next:         u64, // The next free block; 0 and 1 are the roots.
}

test_read :: proc "contextless" (reader: ^Block_Reader, numbers: []u64, into: []u8) -> bool {
	disk := (^Test_Disk)(reader)
	for number, index in numbers {
		if (number + 1) * BLOCK_SIZE > u64(len(disk.bytes)) {
			return false
		}
		copy(into[index * BLOCK_SIZE:][:BLOCK_SIZE], disk.bytes[number * BLOCK_SIZE:][:BLOCK_SIZE])
	}
	return true
}

disk_make :: proc(blocks: int) -> (disk: Test_Disk) {
	disk.reader = {read = test_read}
	disk.bytes = make([]u8, blocks * BLOCK_SIZE)
	disk.next = 2
	return disk
}

// disk_put writes a value in the next free block and gives its Pointer.
disk_put :: proc(disk: ^Test_Disk, value: ^$T) -> format.Pointer where size_of(T) == BLOCK_SIZE {
	number := disk.next
	disk.next += 1
	block := disk.bytes[number * BLOCK_SIZE:][:BLOCK_SIZE]
	copy(block, ([^]u8)(value)[:BLOCK_SIZE])
	return {block = number, check = format.check(block)}
}

// disk_root writes the root of one store "s" with one table in block 0.
disk_root :: proc(disk: ^Test_Disk, table: format.Pointer, used: u64) {
	root := format.Root{magic = format.ROOT_MAGIC, generation = 2, disk_blocks = u64(len(disk.bytes) / BLOCK_SIZE)}
	root.stores[0].name[0] = 's'
	root.stores[0].limit = 1 << 20
	root.stores[0].used = used
	root.stores[0].table = table
	root.check = format.root_check(&root)
	copy(disk.bytes[:BLOCK_SIZE], ([^]u8)(&root)[:BLOCK_SIZE])
}

// One object "a" of 10 bytes: a block of data and its list.
Object_Blocks :: struct {
	list: format.Pointer,
	data: format.Pointer,
}

disk_object :: proc(disk: ^Test_Disk) -> (blocks: Object_Blocks) {
	data: [BLOCK_SIZE]u8
	copy(data[:], "ten bytes!")
	blocks.data = disk_put(disk, &data)
	list: format.List
	list.data[0] = blocks.data
	blocks.list = disk_put(disk, &list)
	return blocks
}

disk_table :: proc(disk: ^Test_Disk, object: Object_Blocks, versions: format.Pointer) -> format.Pointer {
	table: format.Table
	table.objects[0].name[0] = 'a'
	table.objects[0].size = 10
	table.objects[0].list = object.list
	table.objects[0].versions = versions
	return disk_put(disk, &table)
}

// An index that names more leaves than an index holds is damage: the open
// marks it wrong, and does not read past its leaves.
@(test)
an_index_with_too_many_leaves :: proc(t: ^testing.T) {
	disk := disk_make(16)
	defer delete(disk.bytes)
	object := disk_object(&disk)
	index: format.Version_Index
	index.leaf_count = 300
	index_pointer := disk_put(&disk, &index)
	table := disk_table(&disk, object, index_pointer)
	disk_root(&disk, table, 4)
	state := new(State)
	defer free(state)
	result := mount(state, &disk, 16)
	testing.expect(t, !result.failed)
	testing.expect_value(t, result.damaged_versions, 1)
	testing.expect_value(t, result.wrong, 1)
	testing.expect(t, wrong_block(state, index_pointer.block))
	testing.expect_value(t, result.objects, 1)
	testing.expect_value(t, result.damaged_objects, 0)
}

// A leaf with no entry, and a leaf with more entries than it holds, are
// damage.
@(test)
leaves_with_a_wrong_count :: proc(t: ^testing.T) {
	for count in ([]u64{0, format.VERSION_LEAF_CAPACITY + 1}) {
		disk := disk_make(16)
		defer delete(disk.bytes)
		object := disk_object(&disk)
		leaf: format.Version_Leaf
		leaf.count = count
		leaf_pointer := disk_put(&disk, &leaf)
		index: format.Version_Index
		index.leaf_count = 1
		index.leaves[0] = leaf_pointer
		index_pointer := disk_put(&disk, &index)
		disk_root(&disk, disk_table(&disk, object, index_pointer), 5)
		state := new(State)
		defer free(state)
		result := mount(state, &disk, 16)
		testing.expectf(t, result.damaged_versions == 1 && wrong_block(state, leaf_pointer.block), "a leaf of %d entries: %d damaged versions", count, result.damaged_versions)
		testing.expect_value(t, result.versions, 0)
	}
}

// A version whose size needs more blocks than an object has is damage: its
// list is marked wrong, so the engine never releases its blocks of data.
@(test)
a_version_too_large :: proc(t: ^testing.T) {
	disk := disk_make(16)
	defer delete(disk.bytes)
	object := disk_object(&disk)
	other := disk_object(&disk)
	leaf: format.Version_Leaf
	leaf.count = 1
	leaf.entries[0] = {generation = 1, size = (format.OBJECT_BLOCKS_LIMIT + 1) * BLOCK_SIZE, list = other.list}
	leaf_pointer := disk_put(&disk, &leaf)
	index: format.Version_Index
	index.leaf_count = 1
	index.leaves[0] = leaf_pointer
	index_pointer := disk_put(&disk, &index)
	disk_root(&disk, disk_table(&disk, object, index_pointer), 6)
	state := new(State)
	defer free(state)
	result := mount(state, &disk, 32)
	testing.expect_value(t, result.damaged_versions, 1)
	testing.expect(t, wrong_block(state, other.list.block))
	testing.expect_value(t, state.references[other.data.block], 0)
}

// The count of a store in the root that is not its distinct blocks: the open
// takes the recount, and says that the engine wrote a wrong count.
@(test)
the_recount_of_a_store :: proc(t: ^testing.T) {
	disk := disk_make(16)
	defer delete(disk.bytes)
	object := disk_object(&disk)
	disk_root(&disk, disk_table(&disk, object, {}), 99)
	state := new(State)
	defer free(state)
	result := mount(state, &disk, 16)
	testing.expect_value(t, state.store_recount[0], 3) // The table, the list, the block of data.
	testing.expect_value(t, result.stores_recounted, 1)
	testing.expect_value(t, result.stores_with_wrong_count, 1)
	testing.expect(t, !state.store_faulty[0])
}

// A store with a damaged object: the recount does not count the blocks under
// the wrong list, and it is no fault of the engine.
@(test)
the_recount_of_a_damaged_store :: proc(t: ^testing.T) {
	disk := disk_make(16)
	defer delete(disk.bytes)
	object := disk_object(&disk)
	disk.bytes[object.list.block * BLOCK_SIZE] ~= 1 // The list no longer has its check.
	disk_root(&disk, disk_table(&disk, object, {}), 3)
	state := new(State)
	defer free(state)
	result := mount(state, &disk, 16)
	testing.expect_value(t, result.damaged_objects, 1)
	testing.expect_value(t, state.store_recount[0], 2) // The table and the wrong list; not the block of data.
	testing.expect_value(t, result.stores_with_wrong_count, 0)
	testing.expect(t, !used(state, object.data.block))
}

// More than 65535 names of one list: four objects with full version indexes,
// each version the same list. The count holds them all.
@(test)
a_count_above_sixteen_bits :: proc(t: ^testing.T) {
	OBJECTS :: 4
	blocks := 8 + OBJECTS * (format.VERSION_INDEX_CAPACITY + 1)
	disk := disk_make(blocks)
	defer delete(disk.bytes)
	object := disk_object(&disk)
	table: format.Table
	leaf: format.Version_Leaf
	leaf.count = format.VERSION_LEAF_CAPACITY
	for &entry, place in leaf.entries {
		entry = {generation = u64(place + 1), size = 10, list = object.list}
	}
	for object_index in 0 ..< OBJECTS {
		index: format.Version_Index
		index.leaf_count = format.VERSION_INDEX_CAPACITY
		index.version_count = format.VERSIONS_LIMIT
		for &pointer in index.leaves {
			pointer = disk_put(&disk, &leaf)
		}
		table.objects[object_index].name[0] = u8('a' + object_index)
		table.objects[object_index].size = 10
		table.objects[object_index].list = object.list
		table.objects[object_index].versions = disk_put(&disk, &index)
	}
	table_pointer := disk_put(&disk, &table)
	disk_root(&disk, table_pointer, disk.next - 2)
	state := new(State)
	defer free(state)
	result := mount(state, &disk, u64(blocks))
	names := u64(OBJECTS) * (1 + format.VERSIONS_LIMIT)
	testing.expect(t, names > 65535)
	testing.expect_value(t, u64(state.references[object.list.block]), names)
	testing.expect_value(t, result.reference_overflow, 0)
	testing.expect_value(t, result.stores_with_wrong_count, 0)
	testing.expect(t, !state.store_faulty[0])
	testing.expect_value(t, result.versions, u64(OBJECTS) * format.VERSIONS_LIMIT)
}

// A block of a table named from two stores: a fault of the engine, and each
// of the two stores is faulty.
@(test)
a_block_named_from_two_stores :: proc(t: ^testing.T) {
	disk := disk_make(16)
	defer delete(disk.bytes)
	object := disk_object(&disk)
	table := disk_table(&disk, object, {})
	root := format.Root{magic = format.ROOT_MAGIC, generation = 2, disk_blocks = 16}
	for index in 0 ..< 2 {
		root.stores[index].name[0] = u8('s' + index)
		root.stores[index].limit = 64
		root.stores[index].used = 3
		root.stores[index].table = table
	}
	root.check = format.root_check(&root)
	copy(disk.bytes[:BLOCK_SIZE], ([^]u8)(&root)[:BLOCK_SIZE])
	state := new(State)
	defer free(state)
	result := mount(state, &disk, 16)
	testing.expect(t, result.named_by_two_stores > 0)
	testing.expect(t, state.store_faulty[0] && state.store_faulty[1])
}

entry_of :: proc(generation: u64) -> format.Version_Entry {
	return {generation = generation, size = 1}
}

// Leaves with one entry each, as the retention rule leaves them: the
// compaction fills the first leaves, in the order of the entries.
@(test)
compaction_of_sparse_leaves :: proc(t: ^testing.T) {
	leaves := new([format.VERSION_INDEX_CAPACITY]format.Version_Leaf)
	defer free(leaves)
	for &leaf, index in leaves[:] {
		leaf.count = 1
		leaf.entries[0] = entry_of(u64(index + 1))
	}
	testing.expect(t, version_leaves_full(format.VERSION_INDEX_CAPACITY, 85) && !version_leaves_full(format.VERSION_INDEX_CAPACITY, 1))
	used := version_leaves_compact(leaves[:])
	testing.expect_value(t, used, 3) // 254 entries: 85, 85, 84.
	testing.expect_value(t, leaves[0].count, 85)
	testing.expect_value(t, leaves[1].count, 85)
	testing.expect_value(t, leaves[2].count, 84)
	testing.expect_value(t, leaves[3].count, 0)
	generation: u64 = 1
	for &leaf in leaves[:used] {
		for entry in leaf.entries[:leaf.count] {
			testing.expect_value(t, entry.generation, generation)
			generation += 1
		}
	}
	testing.expect_value(t, leaves[2].entries[84], format.Version_Entry{})
}

// A model of the version index of one object, with the rule of the engine
// (programs/storage/engine.odin, version_add): at the limit of the versions
// the oldest goes; when the last leaf of a full index is full, the leaves
// are compacted. A long run where the retention rule keeps one version in
// each leaf, then many writes, and 30000 restores in a row: no add fails,
// and the versions stay in their order.
Index_Model :: struct {
	leaves:     [format.VERSION_INDEX_CAPACITY]format.Version_Leaf,
	leaf_count: int,
	versions:   u64,
	compactions: int,
}

model_remove_first :: proc(model: ^Index_Model) {
	for &leaf in model.leaves[:model.leaf_count] {
		if leaf.count != 0 {
			copy(leaf.entries[:leaf.count - 1], leaf.entries[1:leaf.count])
			leaf.count -= 1
			leaf.entries[leaf.count] = {}
			model.versions -= 1
			return
		}
	}
}

model_add :: proc(model: ^Index_Model, entry: format.Version_Entry) -> bool {
	if model.versions >= format.VERSIONS_LIMIT {
		model_remove_first(model)
	}
	if model.leaf_count > 0 && version_leaves_full(model.leaf_count, model.leaves[model.leaf_count - 1].count) {
		model.leaf_count = version_leaves_compact(model.leaves[:model.leaf_count])
		model.compactions += 1
	}
	if model.leaf_count == 0 || model.leaves[model.leaf_count - 1].count >= format.VERSION_LEAF_CAPACITY {
		if model.leaf_count >= format.VERSION_INDEX_CAPACITY {
			return false
		}
		model.leaves[model.leaf_count] = {}
		model.leaf_count += 1
	}
	leaf := &model.leaves[model.leaf_count - 1]
	leaf.entries[leaf.count] = entry
	leaf.count += 1
	model.versions += 1
	return true
}

model_in_order :: proc(model: ^Index_Model) -> bool {
	last: u64
	for &leaf in model.leaves[:model.leaf_count] {
		for entry in leaf.entries[:leaf.count] {
			if entry.generation <= last {
				return false
			}
			last = entry.generation
		}
	}
	return true
}

@(test)
a_long_run_of_versions :: proc(t: ^testing.T) {
	model := new(Index_Model)
	defer free(model)
	generation: u64
	// The index fills; then a thinning keeps one version in each leaf.
	for _ in 0 ..< format.VERSIONS_LIMIT {
		generation += 1
		testing.expect(t, model_add(model, entry_of(generation)))
	}
	for &leaf in model.leaves[:model.leaf_count] {
		last := leaf.entries[leaf.count - 1]
		leaf.entries = {}
		leaf.entries[0] = last
		leaf.count = 1
	}
	model.versions = u64(model.leaf_count)
	testing.expect_value(t, model.leaf_count, format.VERSION_INDEX_CAPACITY)
	// Writes go on: with no compaction the index has no room after 84 more.
	for _ in 0 ..< 10_000 {
		generation += 1
		if !model_add(model, entry_of(generation)) {
			testing.expectf(t, false, "the add of the generation %d failed", generation)
			return
		}
	}
	testing.expect(t, model.compactions >= 1)
	testing.expect(t, model_in_order(model))
	// Restores in a row: each one adds a version; at the limit the oldest
	// goes.
	for _ in 0 ..< 30_000 {
		generation += 1
		if !model_add(model, entry_of(generation)) {
			testing.expectf(t, false, "the restore of the generation %d failed", generation)
			return
		}
	}
	testing.expect_value(t, model.versions, u64(format.VERSIONS_LIMIT))
	testing.expect(t, model_in_order(model))
}
