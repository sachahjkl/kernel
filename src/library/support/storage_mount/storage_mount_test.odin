#+build !freestanding
package storage_mount

import format "modus:contract/store"
import block_tree "modus:support/storage_object"
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

// disk_root writes the root of one store "s" in block 0.
disk_root :: proc(disk: ^Test_Disk, store_block: format.Pointer, used: u64) {
	root := format.Root{magic = format.ROOT_MAGIC, generation = 2, disk_blocks = u64(len(disk.bytes) / BLOCK_SIZE)}
	root.stores[0].name[0] = 's'
	root.stores[0].limit = 1 << 20
	root.stores[0].used = used
	root.stores[0].store = store_block
	root.check = format.root_check(&root)
	copy(disk.bytes[:BLOCK_SIZE], ([^]u8)(&root)[:BLOCK_SIZE])
}

// One object "a" of 10 bytes: one block of data, the root of its block
// tree. size: its size in the entry.
Object_Blocks :: struct {
	root: format.Pointer,
	data: format.Pointer,
	size: u64,
}

// disk_data writes a block of data of an object, at the block `index` of
// it: its check is its value at that place.
disk_data :: proc(disk: ^Test_Disk, bytes: ^block_tree.Block, index: u64) -> (pointer: format.Pointer, value: format.Block_Value) {
	value = block_tree.block_value(bytes, index)
	pointer = disk_put(disk, bytes)
	pointer.check = format.value_check(value)
	return pointer, value
}

disk_object :: proc(disk: ^Test_Disk) -> (blocks: Object_Blocks) {
	data: block_tree.Block
	copy(data[:], "ten bytes!")
	blocks.data, _ = disk_data(disk, &data, 0)
	blocks.root = blocks.data
	blocks.size = 10
	return blocks
}

// disk_large_object writes an object of two blocks: an object node of
// level 1 and its two blocks of data.
disk_large_object :: proc(disk: ^Test_Disk) -> (blocks: Object_Blocks) {
	node: format.Object_Node
	node.header = {level = 1, count = 2, magic = format.OBJECT_NODE_MAGIC}
	for index in 0 ..< 2 {
		data: block_tree.Block
		for &byte, place in data {
			byte = u8(index + 1 + place % 13)
		}
		pointer, value := disk_data(disk, &data, u64(index))
		node.children[index] = {block = pointer.block, check = pointer.check, blocks = 1, value = value}
		if index == 0 {
			blocks.data = pointer
		}
	}
	blocks.root = disk_put(disk, &node)
	blocks.size = BLOCK_SIZE + 100
	return blocks
}

Named_Entry :: struct {
	name:  string,
	entry: format.Entry,
}

// disk_leaf writes a leaf of a tree with these entries, in their order.
disk_leaf :: proc(disk: ^Test_Disk, entries: []Named_Entry) -> format.Pointer {
	node: [BLOCK_SIZE]u8
	header := (^format.Tree_Header)(&node)
	header.magic = format.NODE_MAGIC
	header.count = u32(len(entries))
	size := size_of(format.Entry_Name) + size_of(format.Entry)
	for item, index in entries {
		place := node[format.TREE_HEADER_SIZE + index * size:]
		copy(place, item.name)
		entry := item.entry
		copy(place[size_of(format.Entry_Name):], ([^]u8)(&entry)[:size_of(format.Entry)])
	}
	return disk_put(disk, &node)
}

object_entry :: proc(object: Object_Blocks, versions: format.Pointer) -> format.Entry {
	return {kind = .Object, size = object.size, pointer = object.root, versions = versions}
}

// disk_store writes a leaf with the one object "a", and the store block
// that names it, with the counts of that store.
disk_store :: proc(disk: ^Test_Disk, object: Object_Blocks, versions: format.Pointer) -> format.Pointer {
	entries := []Named_Entry{{"a", object_entry(object, versions)}}
	leaf := disk_leaf(disk, entries)
	block: format.Store_Block
	block.tree = leaf
	block.objects = 1
	block.current_blocks = 1
	block.node_blocks = 1
	return disk_put(disk, &block)
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
	table := disk_store(&disk, object, index_pointer)
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
		disk_root(&disk, disk_store(&disk, object, index_pointer), 5)
		state := new(State)
		defer free(state)
		result := mount(state, &disk, 16)
		testing.expectf(t, result.damaged_versions == 1 && wrong_block(state, leaf_pointer.block), "a leaf of %d entries: %d damaged versions", count, result.damaged_versions)
		testing.expect_value(t, result.versions, 0)
	}
}

// A version whose size passes the size of an object is damage: its root is
// marked wrong, so the engine never releases the blocks under it.
@(test)
a_version_too_large :: proc(t: ^testing.T) {
	disk := disk_make(16)
	defer delete(disk.bytes)
	object := disk_object(&disk)
	other := disk_large_object(&disk)
	leaf: format.Version_Leaf
	leaf.count = 1
	leaf.entries[0] = {generation = 1, size = format.OBJECT_SIZE_LIMIT + 1, root = other.root}
	leaf_pointer := disk_put(&disk, &leaf)
	index: format.Version_Index
	index.leaf_count = 1
	index.leaves[0] = leaf_pointer
	index_pointer := disk_put(&disk, &index)
	disk_root(&disk, disk_store(&disk, object, index_pointer), 8)
	state := new(State)
	defer free(state)
	result := mount(state, &disk, 32)
	testing.expect_value(t, result.damaged_versions, 1)
	testing.expect(t, wrong_block(state, other.root.block))
	testing.expect_value(t, state.references[other.data.block], 0)
}

// The count of a store in the root that is not its distinct blocks: the open
// takes the recount, and says that the engine wrote a wrong count.
@(test)
the_recount_of_a_store :: proc(t: ^testing.T) {
	disk := disk_make(16)
	defer delete(disk.bytes)
	object := disk_object(&disk)
	disk_root(&disk, disk_store(&disk, object, {}), 99)
	state := new(State)
	defer free(state)
	result := mount(state, &disk, 16)
	testing.expect_value(t, state.store_recount[0], 3) // The store block, the leaf, the block of data.
	testing.expect_value(t, result.stores_recounted, 1)
	testing.expect_value(t, result.stores_with_wrong_count, 1)
	testing.expect(t, !state.store_faulty[0])
}

// A store with a damaged object: the recount does not count the blocks under
// the wrong object node, and it is no fault of the engine.
@(test)
the_recount_of_a_damaged_store :: proc(t: ^testing.T) {
	disk := disk_make(16)
	defer delete(disk.bytes)
	object := disk_large_object(&disk)
	disk.bytes[object.root.block * BLOCK_SIZE + 40] ~= 1 // The object node no longer has its check.
	disk_root(&disk, disk_store(&disk, object, {}), 4)
	state := new(State)
	defer free(state)
	result := mount(state, &disk, 16)
	testing.expect_value(t, result.damaged_objects, 1)
	testing.expect_value(t, state.store_damaged_objects[0], 1)
	testing.expect_value(t, state.store_recount[0], 3) // The store block, the leaf and the wrong object node; not the blocks of data.
	testing.expect_value(t, result.stores_with_wrong_count, 0)
	testing.expect(t, !used(state, object.data.block))
	testing.expect(t, damaged_under(state, object.root.block))
	testing.expect(t, !state.store_damaged[0])
}

// A block of data whose bytes changed on the disk: its value at its place
// is not the value that its node holds. Its object is damaged; the node is
// read and counted.
@(test)
a_changed_block_of_data :: proc(t: ^testing.T) {
	disk := disk_make(16)
	defer delete(disk.bytes)
	object := disk_large_object(&disk)
	disk.bytes[object.data.block * BLOCK_SIZE + 7] ~= 0x40
	disk_root(&disk, disk_store(&disk, object, {}), 6)
	state := new(State)
	defer free(state)
	result := mount(state, &disk, 16)
	testing.expect_value(t, result.damaged_objects, 1)
	testing.expect_value(t, result.wrong, 1)
	testing.expect(t, wrong_block(state, object.data.block))
	testing.expect(t, damaged_under(state, object.root.block))
	testing.expect_value(t, state.store_recount[0], 5) // The store block, the leaf, the node, its two blocks.
}

// An object of two blocks and a version that shares its root: the blocks
// are read one time, each named once by the node, and the root twice.
@(test)
a_shared_block_tree :: proc(t: ^testing.T) {
	disk := disk_make(16)
	defer delete(disk.bytes)
	object := disk_large_object(&disk)
	leaf: format.Version_Leaf
	leaf.count = 1
	leaf.entries[0] = {generation = 1, size = object.size, root = object.root}
	leaf_pointer := disk_put(&disk, &leaf)
	index: format.Version_Index
	index.leaf_count = 1
	index.version_count = 1
	index.leaves[0] = leaf_pointer
	index_pointer := disk_put(&disk, &index)
	entries := []Named_Entry{{"a", object_entry(object, index_pointer)}}
	block: format.Store_Block
	block.tree = disk_leaf(&disk, entries)
	block.objects = 1
	block.current_blocks = 3
	block.node_blocks = 1
	disk_root(&disk, disk_put(&disk, &block), 7)
	state := new(State)
	defer free(state)
	result := mount(state, &disk, 16)
	testing.expect_value(t, result.wrong, 0)
	testing.expect_value(t, state.references[object.root.block], 2)
	testing.expect_value(t, state.references[object.data.block], 1)
	testing.expect_value(t, result.stores_with_wrong_count, 0)
	testing.expect_value(t, state.store_blocks[0].current_blocks, 3)
}

// A store whose counts are right: no fault, and the open keeps them.
@(test)
a_store_with_its_counts :: proc(t: ^testing.T) {
	disk := disk_make(16)
	defer delete(disk.bytes)
	object := disk_object(&disk)
	disk_root(&disk, disk_store(&disk, object, {}), 3)
	state := new(State)
	defer free(state)
	result := mount(state, &disk, 16)
	testing.expect_value(t, result.stores_with_wrong_count, 0)
	testing.expect_value(t, result.stores_recounted, 0)
	testing.expect_value(t, result.objects, 1)
	testing.expect_value(t, state.store_blocks[0].current_blocks, 1)
}

// A tree inside a tree: its nodes and its entries are walked and counted;
// an entry that gives another count of entries than its tree has is a
// fault of the engine.
@(test)
a_tree_inside_a_tree :: proc(t: ^testing.T) {
	for given_count in ([]u64{2, 3}) {
		disk := disk_make(16)
		defer delete(disk.bytes)
		first := disk_object(&disk)
		second := disk_object(&disk)
		inner := disk_leaf(&disk, {{"x", object_entry(first, {})}, {"y", object_entry(second, {})}})
		outer := disk_leaf(&disk, {{"inner", {kind = .Tree, size = given_count, pointer = inner}}})
		block: format.Store_Block
		block.tree = outer
		block.objects = 2
		block.trees = 1
		block.current_blocks = 2
		block.node_blocks = 2
		disk_root(&disk, disk_put(&disk, &block), 5)
		state := new(State)
		defer free(state)
		result := mount(state, &disk, 16)
		testing.expect_value(t, result.objects, 2)
		testing.expect_value(t, result.trees, 1)
		testing.expect_value(t, result.wrong, 0)
		testing.expect_value(t, state.store_recount[0], 5)
		testing.expect_value(t, result.stores_with_wrong_count, given_count == 2 ? 0 : 1)
	}
}

// A leaf whose names are out of order breaks a rule of the format: its
// store is damaged, as with a wrong check.
@(test)
a_leaf_out_of_order :: proc(t: ^testing.T) {
	disk := disk_make(16)
	defer delete(disk.bytes)
	first := disk_object(&disk)
	second := disk_object(&disk)
	leaf := disk_leaf(&disk, {{"b", object_entry(first, {})}, {"a", object_entry(second, {})}})
	block: format.Store_Block
	block.tree = leaf
	disk_root(&disk, disk_put(&disk, &block), 6)
	state := new(State)
	defer free(state)
	result := mount(state, &disk, 16)
	testing.expect(t, !result.failed)
	testing.expect(t, state.store_damaged[0])
	testing.expect_value(t, result.damaged_stores, 1)
	testing.expect(t, wrong_block(state, leaf.block))
}

// More than 65535 names of one block: four objects with full version
// indexes, each version the same root. The count holds them all.
@(test)
a_count_above_sixteen_bits :: proc(t: ^testing.T) {
	OBJECTS :: 4
	blocks := 8 + OBJECTS * (format.VERSION_INDEX_CAPACITY + 1)
	disk := disk_make(blocks)
	defer delete(disk.bytes)
	object := disk_object(&disk)
	leaf: format.Version_Leaf
	leaf.count = format.VERSION_LEAF_CAPACITY
	for &entry, place in leaf.entries {
		entry = {generation = u64(place + 1), size = 10, root = object.root}
	}
	entries: [OBJECTS]Named_Entry
	names := [OBJECTS]string{"a", "b", "c", "d"}
	for object_index in 0 ..< OBJECTS {
		index: format.Version_Index
		index.leaf_count = format.VERSION_INDEX_CAPACITY
		index.version_count = format.VERSIONS_LIMIT
		for &pointer in index.leaves {
			pointer = disk_put(&disk, &leaf)
		}
		entries[object_index] = {names[object_index], object_entry(object, disk_put(&disk, &index))}
	}
	block: format.Store_Block
	block.tree = disk_leaf(&disk, entries[:])
	block.objects = OBJECTS
	block.current_blocks = OBJECTS
	block.node_blocks = 1
	store_block := disk_put(&disk, &block)
	disk_root(&disk, store_block, disk.next - 2)
	state := new(State)
	defer free(state)
	result := mount(state, &disk, u64(blocks))
	references := u64(OBJECTS) * (1 + format.VERSIONS_LIMIT)
	testing.expect(t, references > 65535)
	testing.expect_value(t, u64(state.references[object.root.block]), references)
	testing.expect_value(t, result.reference_overflow, 0)
	testing.expect_value(t, result.stores_with_wrong_count, 0)
	testing.expect(t, !state.store_faulty[0])
	testing.expect_value(t, result.versions, u64(OBJECTS) * format.VERSIONS_LIMIT)
}

// A store block named from two stores: a fault of the engine, and each of
// the two stores is faulty.
@(test)
a_block_named_from_two_stores :: proc(t: ^testing.T) {
	disk := disk_make(16)
	defer delete(disk.bytes)
	object := disk_object(&disk)
	store_block := disk_store(&disk, object, {})
	root := format.Root{magic = format.ROOT_MAGIC, generation = 2, disk_blocks = 16}
	for index in 0 ..< 2 {
		root.stores[index].name[0] = u8('s' + index)
		root.stores[index].limit = 64
		root.stores[index].used = 4
		root.stores[index].store = store_block
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
// (src/programs/storage/engine.odin, version_add): at the limit of the versions
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
