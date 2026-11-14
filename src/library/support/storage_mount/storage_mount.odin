// The open of a data disk (src/library/contract/store): which root to use, the check of
// each block that it names, and the blocks in use. The storage service runs
// it at its start; the kernel tool runs the same code on the host, on each
// image of a disk that a loss of power can leave (tools/kerneltool,
// power_loss.odin). Pure code: no kernel operation, no allocation. The
// blocks come from a Block_Reader that the caller gives.
package storage_mount

import "base:intrinsics"
import format "contract:store"
import block_tree "support:storage_object"
import tree "support:storage_tree"

BLOCK_SIZE :: format.BLOCK_SIZE // The bytes of one block of the disk.
SCRATCH_BLOCKS :: format.OBJECT_FANOUT + 2 // The blocks of data of one object node, read in one request.

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
	// value gives the value of the bytes of a block of data at the block
	// `index` of its object. nil: storage_object.block_value. The kernel
	// tool gives the value that it computed before, as for check.
	value: proc "contextless" (reader: ^Block_Reader, number: u64, index: u64, bytes: ^block_tree.Block) -> format.Block_Value,
	data: rawptr, // The state of the caller.
}

// check_of_block gives the check of the bytes of a block: from the reader
// when it has its own, else the first 8 bytes of their BLAKE3 hash.
check_of_block :: proc "contextless" (reader: ^Block_Reader, number: u64, bytes: []u8) -> u64 {
	return reader.check != nil ? reader.check(reader, number, bytes) : format.check(bytes)
}

// value_of_block gives the value of a block of data at the block `index` of
// its object: from the reader when it has its own, else computed.
value_of_block :: proc "contextless" (reader: ^Block_Reader, number: u64, index: u64, bytes: ^block_tree.Block) -> format.Block_Value {
	return reader.value != nil ? reader.value(reader, number, index, bytes) : block_tree.block_value(bytes, index)
}

// Reader_Source reads the nodes of the trees through a Block_Reader, for
// src/library/support/storage_tree.
Reader_Source :: struct {
	using source: tree.Source,
	reader:       ^Block_Reader, // Where the blocks come from.
	disk_size:    u64, // The blocks of the disk: a Pointer at or past it is Wrong.
}

// reader_source makes the source of the nodes of a disk.
reader_source :: proc "contextless" (reader: ^Block_Reader, disk_size: u64) -> Reader_Source {
	return {source = {read = reader_source_read}, reader = reader, disk_size = disk_size}
}

// reader_source_read reads one node and compares it with the check of its
// Pointer. The blocks 0 and 1 (the roots) and a block past the disk are
// Wrong: no Pointer names them.
reader_source_read :: proc "contextless" (source: ^tree.Source, pointer: format.Pointer, into: ^tree.Block) -> tree.Read {
	from := (^Reader_Source)(source)
	if pointer.block < 2 || pointer.block >= from.disk_size {
		return .Wrong
	}
	numbers := [1]u64{pointer.block}
	if !from.reader.read(from.reader, numbers[:], into[:]) {
		return .Device
	}
	return check_of_block(from.reader, pointer.block, into[:]) == pointer.check ? .Good : .Wrong
}

// Object_Source reads the block trees of objects through a Block_Reader,
// for src/library/support/storage_object: the kernel tool reads the objects of an image
// with it.
Object_Source :: struct {
	using source: block_tree.Source,
	reader:       ^Block_Reader, // Where the blocks come from.
	disk_size:    u64, // The blocks of the disk.
}

// object_source makes the source of the block trees of a disk.
object_source :: proc "contextless" (reader: ^Block_Reader, disk_size: u64) -> Object_Source {
	return {source = {read_node = object_source_read_node, read_block = object_source_read_block, value = object_source_value}, reader = reader, disk_size = disk_size}
}

// object_source_value is the `value` of an object source.
object_source_value :: proc "contextless" (source: ^block_tree.Source, number: u64, index: u64, bytes: ^block_tree.Block) -> format.Block_Value {
	return value_of_block((^Object_Source)(source).reader, number, index, bytes)
}

// object_source_read_node reads one object node and compares it with the
// check of its Pointer.
object_source_read_node :: proc "contextless" (source: ^block_tree.Source, pointer: format.Pointer, into: ^block_tree.Block) -> block_tree.Read {
	from := (^Object_Source)(source)
	if pointer.block < 2 || pointer.block >= from.disk_size {
		return .Wrong
	}
	numbers := [1]u64{pointer.block}
	if !from.reader.read(from.reader, numbers[:], into[:]) {
		return .Device
	}
	return check_of_block(from.reader, pointer.block, into[:]) == pointer.check ? .Good : .Wrong
}

// object_source_read_block reads one block of data with no check: its
// check is its value, which the caller compares.
object_source_read_block :: proc "contextless" (source: ^block_tree.Source, number: u64, into: ^block_tree.Block) -> block_tree.Read {
	from := (^Object_Source)(source)
	if number < 2 || number >= from.disk_size {
		return .Wrong
	}
	numbers := [1]u64{number}
	return from.reader.read(from.reader, numbers[:], into[:]) ? .Good : .Device
}

// The counts of one store, as its store block keeps them and as the walk
// finds them.
Store_Counts :: struct {
	objects:        u64, // `format.Store_Block.objects`.
	trees:          u64, // `format.Store_Block.trees`.
	current_blocks: u64, // `format.Store_Block.current_blocks`.
	node_blocks:    u64, // `format.Store_Block.node_blocks`.
	removing:       u64, // `format.Store_Block.removing`.
}

// store_counts_of gives the counts that a store block keeps.
store_counts_of :: proc "contextless" (block: ^format.Store_Block) -> Store_Counts {
	return {objects = block.objects, trees = block.trees, current_blocks = block.current_blocks, node_blocks = block.node_blocks, removing = block.removing}
}

// What the open knows of a disk. The storage service keeps it while it
// runs; the tool makes one for each image.
State :: struct {
	root:          format.Root, // The root that the open uses.
	root_place:    u64, // 0 or 1: the place of the root on the disk.
	disk_size:     u64, // The blocks of the disk that the service uses.
	// The store block of each store, with the counts that the walk found in
	// place of the counts on the disk: the service starts from them.
	store_blocks:  [format.STORE_CAPACITY]format.Store_Block,
	in_use:        [format.DISK_BLOCKS_LIMIT / 64]u64, // Bit n: block n is named by the root.
	in_use_count:  u64, // The blocks in use.
	// The reference count of each block that the root names: for an object
	// node or a block of data, the object nodes, the entries and the
	// versions that name it; 1 for a store block, a node, an index and a
	// leaf.
	references:    [format.DISK_BLOCKS_LIMIT]u32,
	owner:         [format.DISK_BLOCKS_LIMIT]u8, // The store that names the block, plus 1.
	wrong_blocks:  [format.DISK_BLOCKS_LIMIT / 64]u64, // Bit n: block n was read and has a wrong check, or breaks a rule of the format.
	// Bit n: the block tree under the object node or the block n (n
	// included) has a wrong block. A state whose root has this bit is
	// damaged: a read of it gives Damaged, and its release does not walk
	// under it (its blocks stay in use until the next open counts again).
	damaged_under: [format.DISK_BLOCKS_LIMIT / 64]u64,
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
	store_damaged: [format.STORE_CAPACITY]bool, // Its store block or a node of one of its trees is wrong.
	store_damaged_objects: [format.STORE_CAPACITY]u64, // Objects with a wrong object node or a wrong block of data.
	scratch:       [SCRATCH_BLOCKS * BLOCK_SIZE]u8, // The blocks of one read.
	// One object node for each level of the block tree that the walk is
	// in: a level reads its children into the node of the level below.
	object_nodes:  [format.OBJECT_LEVEL_LIMIT]format.Object_Node,
	// One walk for each level of trees inside trees: a walk holds the nodes
	// of its path, and a tree inside a tree is walked while its entry is read.
	walks:         [format.NESTING_LIMIT + 1]tree.Walk,
	// The walk of the store that the open reads now: the walks of its trees
	// name it, so it lives in the state, not on the stack.
	store_walk:    Store_Walk,
}

// What the open of a disk found: the counts, the damage, which root it
// used, and the faults of the engine. The service writes it on the log at
// its start; the tests of a loss of power check it.
Mount :: struct {
	generation:      u64, // The generation of the root that the open uses.
	stores:          u64, // The stores of the root.
	objects:         u64, // The objects of all the stores.
	trees:           u64, // The trees inside the trees of the stores.
	removing:        u64, // The trees in the removal queues.
	checked:         u64, // Blocks read and compared with their check.
	wrong:           u64, // Blocks with a wrong check, or that break a rule of the format.
	damaged_objects: u64, // Objects with a wrong object node or a wrong block of data.
	damaged_stores:  u64, // Stores whose store block or a node of a tree is wrong.
	needs_format:    bool, // No commit followed the first root: the disk holds no object, the caller formats it.
	first_cut:       bool, // The disk had only a first root with a wrong check: a format that a stop cut.
	older:           bool, // The newest root named a wrong block and the root before it names none: the root before it is used.
	cut:             u64, // Not 0: the generation that a root with a wrong check gives; the open does not use it.
	failed:          bool, // No root is usable, or the device reported an error.
	versions:        u64, // The versions of all the objects.
	damaged_versions: u64, // Versions with a wrong object node or a wrong block of data, or in a wrong leaf.
	shared:          u64, // Blocks with a reference count of 2 or more.
	// Faults of the engine itself, that no stop of the machine can make: a
	// block of one name that the root names two times, a block named from
	// two stores, and a store whose counts are not the counts of what it
	// names (its blocks, its objects, its trees, the entries of a tree).
	named_twice:          u64, // Blocks of one name that the root names two times.
	named_by_two_stores:  u64, // Blocks named from two stores.
	stores_with_wrong_count: u64, // Stores walked whole whose count of blocks, or a count of the store block or of an entry, is wrong.
	reference_overflow:   u64, // Blocks with more names than a count holds.
	stores_recounted:     u64, // Stores whose count in the root differs from the recount: the open takes the recount.
}

// REFERENCE_LIMIT is the most names of one block that a count holds: the
// open and a commit refuse a count past it.
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

// wrong_block says if a block was read and found wrong.
wrong_block :: proc "contextless" (state: ^State, number: u64) -> bool {
	return number < format.DISK_BLOCKS_LIMIT && state.wrong_blocks[number / 64] >> (number % 64) & 1 != 0
}

// wrong_block_set records that a block is wrong.
wrong_block_set :: proc "contextless" (state: ^State, number: u64) {
	if number < format.DISK_BLOCKS_LIMIT {
		state.wrong_blocks[number / 64] |= 1 << (number % 64)
	}
}

// damaged_under says if the block tree under a block has a wrong block.
damaged_under :: proc "contextless" (state: ^State, number: u64) -> bool {
	return number < format.DISK_BLOCKS_LIMIT && state.damaged_under[number / 64] >> (number % 64) & 1 != 0
}

// damaged_under_set records that the block tree under a block has a wrong
// block.
damaged_under_set :: proc "contextless" (state: ^State, number: u64) {
	if number < format.DISK_BLOCKS_LIMIT {
		state.damaged_under[number / 64] |= 1 << (number % 64)
	}
}

// reference_state counts one name of the root of a state of an object (its
// current state or a version) of `size` bytes. At the first name of each
// block under it, the block is read and checked: an object node by its
// check and the rules of its format, a block of data by its value at its
// place. A block that an earlier state named is not read again. It gives
// Wrong when a block under the root is wrong (then, or at its first name),
// and the blocks that the state holds. `named` counts the blocks of the
// store that this name counted first.
reference_state :: proc "contextless" (state: ^State, reader: ^Block_Reader, root: format.Pointer, size: u64, store_index: int, result: ^Mount, named: ^u64) -> (outcome: Read, held: u64) {
	if root.block == 0 {
		return .Good, 0
	}
	if size > format.OBJECT_SIZE_LIMIT {
		// A size that no object has: the engine never walks under it.
		result.wrong += 1
		wrong_block_set(state, root.block)
		damaged_under_set(state, root.block)
		return .Wrong, 0
	}
	levels := format.object_levels(size)
	first: bool
	outcome, first, held, _ = reference_object_child(state, reader, {block = root.block, check = root.check}, levels, 0, size, false, store_index, result, named)
	if first || outcome != .Good || levels == 0 {
		return outcome, levels == 0 ? 1 : held
	}
	// A root that an earlier state named: its blocks are in its node.
	numbers := [1]u64{root.block}
	node := &state.object_nodes[levels - 1]
	if !reader.read(reader, numbers[:], ([^]u8)(node)[:BLOCK_SIZE]) {
		return .Device, 0
	}
	held = 1
	for &child in node.children {
		held += child.blocks
	}
	return .Good, held
}

// reference_object_child counts one name of an object node of `level`, or
// of a block of data at level 0, that covers the blocks from `base`, and
// walks under it at its first name. value_known: the parent holds the
// value of the child, and the walk compares it. It gives the blocks of the
// child and its value.
reference_object_child :: proc "contextless" (state: ^State, reader: ^Block_Reader, child: format.Object_Child, level: int, base: u64, size: u64, value_known: bool, store_index: int, result: ^Mount, named: ^u64) -> (outcome: Read, first: bool, blocks: u64, value: format.Block_Value) {
	if child.block < 2 || child.block >= state.disk_size {
		result.wrong += 1
		return .Wrong, false, child.blocks, child.value
	}
	if !reference(state, child.block, store_index, result) {
		bad := wrong_block(state, child.block) || damaged_under(state, child.block)
		return bad ? .Wrong : .Good, false, child.blocks, child.value
	}
	named^ += 1
	numbers := [1]u64{child.block}
	if level == 0 {
		// The block of a state of one block.
		bytes := (^block_tree.Block)(raw_data(scratch_block(state, 0)))
		if !reader.read(reader, numbers[:], bytes[:]) {
			return .Device, true, 1, {}
		}
		result.checked += 1
		value = value_of_block(reader, child.block, base, bytes)
		if format.value_check(value) != child.check || (value_known && value != child.value) || block_tree.is_zero(bytes[:]) {
			result.wrong += 1
			wrong_block_set(state, child.block)
			damaged_under_set(state, child.block)
			return .Wrong, true, 1, value
		}
		return .Good, true, 1, value
	}
	node := &state.object_nodes[level - 1]
	if !reader.read(reader, numbers[:], ([^]u8)(node)[:BLOCK_SIZE]) {
		return .Device, true, child.blocks, child.value
	}
	result.checked += 1
	if check_of_block(reader, child.block, ([^]u8)(node)[:BLOCK_SIZE]) != child.check || !block_tree.node_valid(node, level, base, size) {
		result.wrong += 1
		wrong_block_set(state, child.block)
		damaged_under_set(state, child.block)
		return .Wrong, true, child.blocks, child.value
	}
	span := format.object_span(level - 1)
	blocks = 1
	damaged := false
	if level == 1 {
		// The blocks of data that no state named before, read in one request;
		// each one is checked by its value at its place.
		unread_numbers: [format.OBJECT_FANOUT]u64
		unread_places: [format.OBJECT_FANOUT]int
		unread_count := 0
		for &item, place in node.children {
			if item.block == 0 {
				continue
			}
			blocks += 1
			if item.block >= state.disk_size {
				result.wrong += 1
				damaged = true
				continue
			}
			if reference(state, item.block, store_index, result) {
				named^ += 1
				unread_numbers[unread_count] = item.block
				unread_places[unread_count] = place
				unread_count += 1
			} else if wrong_block(state, item.block) {
				damaged = true
			}
		}
		if unread_count != 0 {
			if !reader.read(reader, unread_numbers[:unread_count], state.scratch[:unread_count * BLOCK_SIZE]) {
				return .Device, true, blocks, {}
			}
			result.checked += u64(unread_count)
			for number in 0 ..< unread_count {
				item := &node.children[unread_places[number]]
				bytes := (^block_tree.Block)(raw_data(scratch_block(state, number)))
				if value_of_block(reader, item.block, base + u64(unread_places[number]), bytes) != item.value || block_tree.is_zero(bytes[:]) {
					result.wrong += 1
					wrong_block_set(state, item.block)
					damaged_under_set(state, item.block)
					damaged = true
				}
			}
		}
	} else {
		for place in 0 ..< format.OBJECT_FANOUT {
			// A copy: the level below reads into its own node, not this one.
			item := node.children[place]
			if item.block == 0 {
				continue
			}
			child_outcome, child_first, child_blocks, child_value := reference_object_child(state, reader, item, level - 1, base + u64(place) * span, size, true, store_index, result, named)
			if child_outcome == .Device {
				return .Device, true, blocks, {}
			}
			if child_outcome == .Wrong {
				damaged = true
			} else if child_first && (child_blocks != item.blocks || child_value != item.value) {
				// A node that gives another count or another value than what
				// it names: a rule of the format.
				result.wrong += 1
				wrong_block_set(state, item.block)
				damaged_under_set(state, item.block)
				damaged = true
			}
			blocks += item.blocks
		}
	}
	value = block_tree.node_value(node)
	if damaged {
		damaged_under_set(state, child.block)
		return .Wrong, true, blocks, value
	}
	return .Good, true, blocks, value
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

// What a read of blocks gave.
Read :: enum {
	Good, // Each block has its check.
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

// single counts the one name of a block that only one name can have: a
// store block, a version index, a version leaf. It reads and checks it into
// the scratch block 0.
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

// The walk of one store, for the visits of the walks of its trees.
Store_Walk :: struct {
	state:       ^State, // The state of the open.
	reader:      ^Block_Reader, // Where the blocks come from.
	source:      Reader_Source, // The source of the nodes of its trees.
	result:      ^Mount, // The result of the open.
	store_index: int, // The cell of the store in the root.
	named:       u64, // The distinct blocks of the store.
	counts:      Store_Counts, // What the walk counted.
	nesting:     int, // The level of the tree that is walked: 0 for the tree of the store.
	in_removals: bool, // The walk is in the removal queue: its entries are trees to free.
	complete:    bool, // Each block of the store was read: its counts are known.
	device:      bool, // The device reported an error.
	broken:      bool, // A node or an entry breaks a rule: the store is damaged.
	entry_count_wrong: bool, // An entry of a tree gives another count of entries than its tree has.
}

// walk reads each block that a root names, checks it, and counts its
// references: the store blocks, the nodes of each tree, the objects, their
// versions, and each block one time. A wrong object node or a wrong block of data
// does not end the walk: its object, or its version, is damaged. A wrong
// store block or node damages its store: the walk of that store stops. The
// blocks under a wrong block are not known, so they are free. It gives
// false when the device reported an error.
walk :: proc "contextless" (state: ^State, reader: ^Block_Reader, candidate: ^format.Root, result: ^Mount) -> bool {
	state.in_use = {}
	state.in_use_count = 0
	state.references = {}
	state.owner = {}
	state.wrong_blocks = {}
	state.damaged_under = {}
	state.store_versions = {}
	state.store_shared = {}
	state.store_recount = {}
	state.store_faulty = {}
	state.store_damaged = {}
	state.store_damaged_objects = {}
	state.store_blocks = {}
	mark(state, 0, true)
	mark(state, 1, true)
	result.stores, result.objects, result.trees, result.removing = 0, 0, 0, 0
	result.checked, result.wrong = 0, 0
	result.damaged_objects, result.damaged_stores, result.named_twice, result.stores_with_wrong_count = 0, 0, 0, 0
	result.versions, result.damaged_versions, result.shared, result.named_by_two_stores = 0, 0, 0, 0
	result.reference_overflow, result.stores_recounted = 0, 0
	for &store, index in candidate.stores {
		if store.name[0] == 0 {
			continue
		}
		result.stores += 1
		ok := walk_store(state, reader, &store, index, result)
		// The walk of a store names the reader and the result of this call
		// only while it runs.
		state.store_walk = {}
		if !ok {
			return false
		}
	}
	return true
}

// walk_store walks the store of a cell of the root: its store block, its
// tree, its removal queue, the block trees and the versions of its objects.
// It counts each block, and compares the counts with the store block. false:
// the device failed.
walk_store :: proc "contextless" (state: ^State, reader: ^Block_Reader, store: ^format.Store_Entry, index: int, result: ^Mount) -> bool {
	named: u64
	switch single(state, reader, store.store, index, result, &named) {
	case .Device:
		return false
	case .Wrong:
		result.damaged_stores += 1
		state.store_damaged[index] = true
		state.store_recount[index] = named
		return true
	case .Good:
	}
	block := &state.store_blocks[index]
	intrinsics.mem_copy_non_overlapping(block, raw_data(scratch_block(state, 0)), BLOCK_SIZE)
	on_disk := store_counts_of(block)
	walking := &state.store_walk
	walking^ = {
		state       = state,
		reader      = reader,
		source      = reader_source(reader, state.disk_size),
		result      = result,
		store_index = index,
		named       = named,
		complete    = true,
	}
	roots := [2]format.Pointer{block.tree, block.removals}
	for root, which in roots {
		walking.in_removals = which == 1
		walk_one_tree(walking, root, 0)
		if walking.device {
			return false
		}
		if walking.broken {
			break
		}
	}
	if walking.broken {
		result.damaged_stores += 1
		state.store_damaged[index] = true
		walking.complete = false
	}
	state.store_recount[index] = walking.named
	wrong_count := walking.named != store.used || walking.counts != on_disk || walking.entry_count_wrong
	if walking.named != store.used {
		result.stores_recounted += 1
	}
	if wrong_count && walking.complete {
		result.stores_with_wrong_count += 1
	}
	result.objects += walking.counts.objects
	result.trees += walking.counts.trees
	result.removing += walking.counts.removing
	// The service starts from the counts of the walk: the next commit
	// writes them.
	if !walking.broken {
		block.objects = walking.counts.objects
		block.trees = walking.counts.trees
		block.current_blocks = walking.counts.current_blocks
		block.node_blocks = walking.counts.node_blocks
		block.removing = walking.counts.removing
	}
	return true
}

// walk_one_tree walks one tree of a store, and each tree inside it while
// its entry is read. It gives the count of its entries.
walk_one_tree :: proc "contextless" (walking: ^Store_Walk, root: format.Pointer, nesting: int) -> (entries: u64) {
	if nesting > format.NESTING_LIMIT {
		walking.broken = true
		return 0
	}
	state := walking.state
	one := &state.walks[nesting]
	one.source = &walking.source.source
	one.shape = tree.TREE_SHAPE
	one.visit_node = visit_node_of_store
	one.visit_record = visit_entry_of_store
	one.data = walking
	one.nodes, one.records = 0, 0
	before := walking.nesting
	walking.nesting = nesting
	failure := tree.walk_tree(one, root)
	walking.nesting = before
	switch failure {
	case .Device:
		walking.device = true
	case .Wrong, .Damaged, .Full, .Write:
		if one.failed_block != 0 && !wrong_block(state, one.failed_block) {
			wrong_block_set(state, one.failed_block)
			walking.result.wrong += 1
		}
		walking.broken = true
	case .None:
	}
	return one.records
}

visit_node_of_store :: proc "contextless" (one: ^tree.Walk, pointer: format.Pointer) -> bool {
	walking := (^Store_Walk)(one.data)
	if pointer.block < 2 || pointer.block >= walking.state.disk_size {
		return true // The read says that it is wrong.
	}
	if !reference(walking.state, pointer.block, walking.store_index, walking.result) {
		// A node named two times: the walk does not read it again, so a loop
		// of nodes ends.
		walking.result.named_twice += 1
		walking.state.store_faulty[walking.store_index] = true
		return false
	}
	walking.named += 1
	walking.counts.node_blocks += 1
	walking.result.checked += 1
	return true
}

visit_entry_of_store :: proc "contextless" (one: ^tree.Walk, _: []u8, value: []u8) {
	walking := (^Store_Walk)(one.data)
	state := walking.state
	result := walking.result
	index := walking.store_index
	entry := (^format.Entry)(raw_data(value))^
	queued := walking.in_removals && walking.nesting == 0
	if queued {
		if entry.kind != .Tree {
			walking.broken = true
			one.failure = .Damaged
			return
		}
		walking.counts.removing += 1
	}
	switch entry.kind {
	case .Object:
		walking.counts.objects += 1
		outcome, held := reference_state(state, walking.reader, entry.pointer, entry.size, index, result, &walking.named)
		walking.counts.current_blocks += held
		switch outcome {
		case .Device:
			walking.device = true
			one.failure = .Device
			return
		case .Wrong:
			result.damaged_objects += 1
			state.store_damaged_objects[index] += 1
			walking.complete = false
		case .Good:
		}
		if entry.versions.block != 0 && !walk_versions(walking, entry.versions) {
			walking.device = true
			one.failure = .Device
			return
		}
	case .Tree:
		walking.counts.trees += 1
		if entry.versions.block != 0 || entry.hash != {} || entry.pointer.block == 0 && entry.size != 0 {
			walking.broken = true
			one.failure = .Damaged
			return
		}
		if entry.pointer.block != 0 {
			entries := walk_one_tree(walking, entry.pointer, walking.nesting + 1)
			if walking.device {
				one.failure = .Device
				return
			}
			if walking.broken {
				one.failure = .Damaged
				return
			}
			if entries != entry.size {
				walking.entry_count_wrong = true
			}
		}
	case .None:
		walking.broken = true
		one.failure = .Damaged
	case:
		// A kind that the format does not have.
		walking.broken = true
		one.failure = .Damaged
	}
}

// walk_versions counts the version index of an object, its leaves and the
// block tree of each version. It gives false when the device reported an error.
walk_versions :: proc "contextless" (walking: ^Store_Walk, versions: format.Pointer) -> bool {
	state := walking.state
	reader := walking.reader
	result := walking.result
	index := walking.store_index
	switch single(state, reader, versions, index, result, &walking.named) {
	case .Device:
		return false
	case .Wrong:
		result.damaged_versions += 1 // The versions of the object are not known.
		walking.complete = false
		return true
	case .Good:
	}
	version_index := (^format.Version_Index)(raw_data(scratch_block(state, 0)))^
	// A count that the format does not permit is damage, as a wrong check:
	// the engine then never reads past the leaves of an index.
	if version_index.leaf_count > format.VERSION_INDEX_CAPACITY {
		result.wrong += 1
		wrong_block_set(state, versions.block)
		result.damaged_versions += 1
		walking.complete = false
		return true
	}
	for leaf_pointer in version_index.leaves[:version_index.leaf_count] {
		switch single(state, reader, leaf_pointer, index, result, &walking.named) {
		case .Device:
			return false
		case .Wrong:
			result.damaged_versions += 1
			walking.complete = false
			continue
		case .Good:
		}
		leaf := (^format.Version_Leaf)(raw_data(scratch_block(state, 0)))^
		// The engine writes no empty leaf, and no leaf of more entries than
		// it holds.
		if leaf.count == 0 || leaf.count > format.VERSION_LEAF_CAPACITY {
			result.wrong += 1
			wrong_block_set(state, leaf_pointer.block)
			result.damaged_versions += 1
			walking.complete = false
			continue
		}
		for &entry in leaf.entries[:leaf.count] {
			result.versions += 1
			state.store_versions[index] += 1
			outcome, _ := reference_state(state, reader, entry.root, entry.size, index, result, &walking.named)
			switch outcome {
			case .Device:
				return false
			case .Wrong:
				result.damaged_versions += 1
				walking.complete = false
			case .Good:
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
