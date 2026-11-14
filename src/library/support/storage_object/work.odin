package storage_object

import "contract:blake3"
import format "contract:store"

// The work of one commit on one object: it starts from a state of the
// disk, cuts it, extends it, changes blocks of data, then computes the
// values and the hash, and writes the new blocks. A change never writes over
// a block of the disk: the first change under an object node copies the node
// into a slot (copy on write), and each node above it is copied too. The new
// state names the nodes and the blocks of the state before that did not
// change.
//
// The order of the calls: work_begin, work_cut, work_resize, work_change for
// each changed block, work_finish.
//
// The names: a node that the work copies names each child of the node that
// it copies (Counter.name); a child that the work replaces in a copy loses
// that name (Counter.release). The name of the root of a state belongs to
// the entry or to the version that holds it: the caller counts it.

NODE_SLOT_CAPACITY :: 1536 // The object nodes that one commit changes: 1000 blocks of data spread over a large object change about 1000 nodes of level 1 and fewer above.

// One block of data that a commit changes: its place, and its 4096 bytes
// after the change, with zero bytes past the size.
Change :: struct {
	index:          u64, // The block of the object, from 0.
	bytes:          ^Block, // Its bytes after the change, in memory of the caller.
	original:       Child, // The child that it replaces: a hole when none.
	original_known: bool, // original has its value: false for the block of a state of one block.
	value:          Value, // Its value after the change, which the work computes.
	kept:           bool, // Its value is the value of the original: the block of the state before stays.
}

// What the work asks of its caller: the names of the blocks, and the
// writes of the new ones.
Counter :: struct {
	// name adds one name to a block of the disk: a copied node names each of
	// its children again.
	name:       proc "contextless" (counter: ^Counter, block: u64),
	// release takes one name of a child: a block of data at level 0, or an
	// object node of its level. The caller frees what no name holds.
	release:    proc "contextless" (counter: ^Counter, child: Child, level: int),
	// write_node and write_data write a new block, named one time by its
	// parent, and give its Pointer; a Pointer with no block when they cannot.
	write_node: proc "contextless" (counter: ^Counter, bytes: ^Block) -> Pointer,
	write_data: proc "contextless" (counter: ^Counter, bytes: ^Block, check: u64) -> Pointer,
	data:       rawptr, // The state of the caller.
}

// Why a work failed. The first failure stays (`work_failed`).
Failure :: enum {
	None, // No failure.
	Device, // A read failed on the device.
	Wrong, // A block of the state before has a wrong check, or breaks a rule.
	Full, // No slot is free.
	Write, // The Counter gave no block.
}

// A copy of an object node that the commit writes.
Slot :: struct {
	node:  Node, // The copy of the node, as the commit changes it.
	// > 0: 1 + the slot of the child node that the commit makes; < 0:
	// -(1 + the change) of the child block of data; 0: the child in node.
	refs:  [FANOUT]i32,
	level: int, // The level of the node, from 1.
	used:  bool, // The slot holds a node of this work.
}

// The measure of one commit: what it hashed and wrote.
Measure :: struct {
	changed:       u64, // Blocks of data that the commit changed.
	hashed_blocks: u64, // Blocks of data whose bytes the commit hashed: the changed blocks, the last block of the hash, the root of a state of one block that grows.
	hashed_nodes:  u64, // Object nodes whose value the commit computed.
	written:       u64, // Blocks that the commit writes: data and object nodes.
}

// The commit of a change of one object: the state before, the changes, and
// the copies of the nodes on their paths. About 6 MiB, which the caller
// keeps. `work_begin` starts it; `work_finish` writes it.
Work :: struct {
	source:         ^Source, // Where the blocks of the state before come from.
	counter:        ^Counter, // The names and the writes of the caller.
	slots:          [NODE_SLOT_CAPACITY]Slot, // The nodes that the commit copies.
	slots_high:     int, // No slot from here is used.
	// The root when root_reference is 0: a block of the disk, or a hole.
	// root_known: its value and its blocks are known.
	root:           Child,
	root_known:     bool,
	root_reference: i32, // As Slot.refs.
	levels:         int, // The levels of the block tree for `size`.
	size_before:    u64, // The size of the state before.
	size:           u64, // The size after the commit.
	changes:        []Change, // The blocks that change, in the order of their indexes.
	failure:        Failure, // The first failure.
	failed_block:   u64, // The block that the failure names.
	measure:        Measure, // What the commit hashed and wrote.
	scratch:        Node, // A node to read into.
	walk:           Work_Hash, // The state of the hash of the new state.
}

// work_failed says if the work failed: its failure stays.
work_failed :: proc "contextless" (work: ^Work) -> bool {
	return work.failure != .None
}

// work_fail records the first failure of the work.
@(private)
work_fail :: proc "contextless" (work: ^Work, failure: Failure, block: u64 = 0) {
	if work.failure == .None {
		work.failure = failure
		work.failed_block = block
	}
}

// fail_of_read records the failure of a read that was not Good.
@(private)
fail_of_read :: proc "contextless" (work: ^Work, outcome: Read, block: u64) {
	work_fail(work, outcome == .Device ? .Device : .Wrong, block)
}

// work_begin starts the work on a state of the disk.
work_begin :: proc "contextless" (work: ^Work, source: ^Source, counter: ^Counter, before: State, changes: []Change) {
	for &slot in work.slots[:work.slots_high] {
		slot.used = false
	}
	work.slots_high = 0
	work.source, work.counter = source, counter
	work.root = {block = before.root.block, check = before.root.check}
	work.root_known = before.root.block == 0
	work.root_reference = 0
	work.levels = format.object_levels(before.size)
	work.size_before = before.size
	work.size = before.size
	work.changes = changes
	work.failure = .None
	work.failed_block = 0
	work.measure = {}
}

// slot_take gives a free slot for a node of a level, or -1 with the
// failure Full.
@(private)
slot_take :: proc "contextless" (work: ^Work, level: int) -> int {
	for index in 0 ..< NODE_SLOT_CAPACITY {
		slot := &work.slots[index]
		if slot.used {
			continue
		}
		slot.used = true
		slot.level = level
		slot.refs = {}
		work.slots_high = max(work.slots_high, index + 1)
		return index
	}
	work_fail(work, .Full)
	return -1
}

// slot_new gives a new node of a level, with no child.
@(private)
slot_new :: proc "contextless" (work: ^Work, level: int) -> int {
	index := slot_take(work, level)
	if index < 0 {
		return -1
	}
	slot := &work.slots[index]
	slot.node = {}
	slot.node.header.level = u32(level)
	slot.node.header.magic = format.OBJECT_NODE_MAGIC
	return index
}

// slot_copy copies a node of the state before into a slot: the copy names
// each child of the node.
@(private)
slot_copy :: proc "contextless" (work: ^Work, child: Child, level: int, base: u64) -> int {
	index := slot_take(work, level)
	if index < 0 {
		return -1
	}
	slot := &work.slots[index]
	if outcome := node_load(work.source, {block = child.block, check = child.check}, level, base, work.size_before, &slot.node); outcome != .Good {
		slot.used = false
		fail_of_read(work, outcome, child.block)
		return -1
	}
	for &named in slot.node.children {
		if named.block != 0 {
			work.counter.name(work.counter, named.block)
		}
	}
	return index
}

// root_slot gives the slot of the root, and copies the root of the state
// before into one at its first change. The levels are at least 1.
@(private)
root_slot :: proc "contextless" (work: ^Work) -> int {
	if work.root_reference > 0 {
		return int(work.root_reference - 1)
	}
	index: int
	if work.root.block != 0 {
		index = slot_copy(work, work.root, work.levels, 0)
	} else {
		index = slot_new(work, work.levels)
	}
	if index >= 0 {
		work.root_reference = i32(index + 1)
		work.root = {}
		work.root_known = true
	}
	return index
}

// reference_drop drops a part that the work made and that a cut removes:
// its copies release the names that they hold.
@(private)
reference_drop :: proc "contextless" (work: ^Work, reference: i32, level: int) {
	if reference <= 0 {
		return // A changed block of data past the cut: the work does not write it.
	}
	index := int(reference - 1)
	for place in 0 ..< FANOUT {
		slot := &work.slots[index]
		child_reference := slot.refs[place]
		if child_reference != 0 {
			reference_drop(work, child_reference, level - 1)
		} else if slot.node.children[place].block != 0 {
			work.counter.release(work.counter, slot.node.children[place], level - 1)
		}
	}
	work.slots[index].used = false
}

// work_cut makes each byte at or past cut_size a hole, and lowers the
// levels to those of cut_size. The caller gives the block that holds
// cut_size, with zero bytes from it, as a change.
work_cut :: proc "contextless" (work: ^Work, cut_size: u64) {
	if work_failed(work) || cut_size >= work.size {
		return
	}
	keep := format.object_blocks(cut_size)
	new_levels := format.object_levels(cut_size)
	work.size = cut_size
	if keep == 0 {
		// The root of the state before belongs to its entry: the caller
		// counts it.
		if work.root_reference != 0 {
			reference_drop(work, work.root_reference, work.levels)
		}
		work.root_reference = 0
		work.root = {}
		work.root_known = true
		work.levels = 0
		return
	}
	if work.levels == 0 {
		return // One block, and it stays.
	}
	root := root_slot(work)
	if root < 0 {
		return
	}
	cut_node(work, root, work.levels, 0, keep)
	for !work_failed(work) && work.levels > new_levels {
		// Each child of the root but the first is a hole now: the first one
		// becomes the root.
		slot := &work.slots[int(work.root_reference - 1)]
		first_reference := slot.refs[0]
		first := slot.node.children[0]
		slot.used = false
		if first_reference != 0 {
			work.root_reference = first_reference
			work.root = {}
		} else {
			work.root_reference = 0
			work.root = first
			work.root_known = true
			if first.block != 0 {
				// The copy that named it goes; the caller names the root.
				work.counter.release(work.counter, first, work.levels - 1)
			}
		}
		work.levels -= 1
	}
}

@(private)
cut_node :: proc "contextless" (work: ^Work, index: int, level: int, base: u64, keep: u64) {
	span := format.object_span(level - 1)
	for place in 0 ..< FANOUT {
		if work_failed(work) {
			return
		}
		start := base + u64(place) * span
		slot := &work.slots[index]
		reference := slot.refs[place]
		child := slot.node.children[place]
		if start >= keep {
			if reference != 0 {
				reference_drop(work, reference, level - 1)
			} else if child.block != 0 {
				work.counter.release(work.counter, child, level - 1)
			}
			slot = &work.slots[index]
			slot.refs[place] = 0
			slot.node.children[place] = {}
			continue
		}
		if start + span <= keep || level == 1 {
			continue
		}
		if reference > 0 {
			cut_node(work, int(reference - 1), level - 1, start, keep)
			continue
		}
		if child.block == 0 {
			continue
		}
		copied := slot_copy(work, child, level - 1, start)
		if copied < 0 {
			return
		}
		work.counter.release(work.counter, child, level - 1)
		slot = &work.slots[index]
		slot.refs[place] = i32(copied + 1)
		slot.node.children[place] = {}
		cut_node(work, copied, level - 1, start, keep)
	}
}

// root_complete gives the root of the state before as a child: its value
// and its blocks. A root of one block of data is read and hashed.
@(private)
root_complete :: proc "contextless" (work: ^Work) -> (child: Child, outcome: Read) {
	child = work.root
	if work.root_known || child.block == 0 {
		return child, .Good
	}
	if work.levels == 0 {
		block: ^Block = (^Block)(&work.scratch)
		value: Value
		value, outcome = block_check(work.source, {block = child.block, check = child.check}, 0, block)
		work.measure.hashed_blocks += 1
		child.value, child.blocks = value, 1
		return child, outcome
	}
	if outcome = node_load(work.source, {block = child.block, check = child.check}, work.levels, 0, work.size_before, &work.scratch); outcome != .Good {
		return child, outcome
	}
	child.blocks = 1
	for &item in work.scratch.children {
		child.blocks += item.blocks
	}
	child.value = node_value(&work.scratch)
	work.measure.hashed_nodes += 1
	return child, .Good
}

// work_resize sets the size of the object after the commit. A larger size
// adds levels above the root: the root of the state before becomes the first
// child of a new root. The bytes past the size before are zero already.
work_resize :: proc "contextless" (work: ^Work, size: u64) {
	if size < work.size {
		work_cut(work, size)
	}
	if work_failed(work) {
		return
	}
	new_levels := format.object_levels(size)
	for work.levels < new_levels {
		level := work.levels + 1
		root_reference := work.root_reference
		root, outcome := root_complete(work)
		if outcome != .Good {
			fail_of_read(work, outcome, root.block)
			return
		}
		index := slot_new(work, level)
		if index < 0 {
			return
		}
		slot := &work.slots[index]
		if root_reference != 0 {
			slot.refs[0] = root_reference
		} else if root.block != 0 {
			slot.node.children[0] = root
			work.counter.name(work.counter, root.block)
		}
		work.root_reference = i32(index + 1)
		work.root = {}
		work.root_known = true
		work.levels = level
	}
	work.size = size
}

// path_slot gives the slot of the node of level 1 that covers the block
// `index`, and the first block that it covers. Each node of the path is
// copied, or made when a hole covers it.
@(private)
path_slot :: proc "contextless" (work: ^Work, index: u64) -> (slot_index: int, base: u64) {
	slot_index = root_slot(work)
	for level := work.levels; level > 1 && slot_index >= 0; level -= 1 {
		span := format.object_span(level - 1)
		place := int((index - base) / span)
		slot := &work.slots[slot_index]
		reference := slot.refs[place]
		next: int
		if reference > 0 {
			next = int(reference - 1)
		} else {
			child := slot.node.children[place]
			if child.block != 0 {
				next = slot_copy(work, child, level - 1, base + u64(place) * span)
				if next >= 0 {
					work.counter.release(work.counter, child, level - 1)
				}
			} else {
				next = slot_new(work, level - 1)
			}
			if next < 0 {
				return -1, 0
			}
			slot = &work.slots[slot_index]
			slot.refs[place] = i32(next + 1)
			slot.node.children[place] = {}
		}
		base += u64(place) * span
		slot_index = next
	}
	return slot_index, base
}

// work_change puts the change `number` of the changes in the tree. A
// change of zero bytes makes a hole. Each block has one change at most.
work_change :: proc "contextless" (work: ^Work, number: int) {
	if work_failed(work) {
		return
	}
	change := &work.changes[number]
	if change.index >= format.object_blocks(work.size) {
		return // Past the size: nothing names it.
	}
	zero := is_zero(change.bytes[:])
	work.measure.changed += 1
	if work.levels == 0 {
		// The root is the block. The root of the state before belongs to its
		// entry: the caller counts it.
		change.original = work.root_reference == 0 ? work.root : Child{}
		change.original_known = false
		work.root_reference = zero ? 0 : -i32(number + 1)
		work.root = {}
		work.root_known = true
		return
	}
	slot_index, base := path_slot(work, change.index)
	if slot_index < 0 {
		return
	}
	slot := &work.slots[slot_index]
	place := int(change.index - base)
	old := slot.node.children[place]
	if slot.refs[place] == 0 && old.block != 0 {
		change.original = old
		change.original_known = true
		work.counter.release(work.counter, old, 0)
	}
	slot.node.children[place] = {}
	slot.refs[place] = zero ? 0 : -i32(number + 1)
}

// values_of computes the value and the blocks of a part that the work made,
// its children first. present is false when each block under it is a
// hole: its slot is free, and its parent names a hole.
@(private)
values_of :: proc "contextless" (work: ^Work, reference: i32, level: int) -> (child: Child, present: bool) {
	if reference < 0 {
		change := &work.changes[-reference - 1]
		change.value = block_value(change.bytes, change.index)
		work.measure.hashed_blocks += 1
		if change.original_known && change.original.block != 0 && change.original.value == change.value {
			// The same bytes at the same place: the block of the state before
			// stays, and the copy names it again.
			change.kept = true
			work.counter.name(work.counter, change.original.block)
			return change.original, true
		}
		return {check = format.value_check(change.value), blocks = 1, value = change.value}, true
	}
	index := int(reference - 1)
	count: u32
	blocks: u64 = 1
	for place in 0 ..< FANOUT {
		child_reference := work.slots[index].refs[place]
		if child_reference != 0 {
			made, has := values_of(work, child_reference, level - 1)
			slot := &work.slots[index]
			if !has {
				slot.refs[place] = 0
				slot.node.children[place] = {}
			} else {
				slot.node.children[place] = made
				if child_reference < 0 && work.changes[-child_reference - 1].kept {
					slot.refs[place] = 0
				}
			}
		}
		slot := &work.slots[index]
		if slot.refs[place] != 0 || slot.node.children[place].block != 0 {
			count += 1
			blocks += slot.node.children[place].blocks
		}
	}
	slot := &work.slots[index]
	if count == 0 {
		slot.used = false
		return {}, false
	}
	slot.node.header.count = count
	slot.node.header.level = u32(level)
	slot.node.header.magic = format.OBJECT_NODE_MAGIC
	work.measure.hashed_nodes += 1
	return {blocks = blocks, value = node_value(&slot.node)}, true
}

// write_of writes a part that the work made, its children first, and gives
// its Pointer.
@(private)
write_of :: proc "contextless" (work: ^Work, reference: i32, level: int) -> Pointer {
	if reference < 0 {
		change := &work.changes[-reference - 1]
		pointer := work.counter.write_data(work.counter, change.bytes, format.value_check(change.value))
		if pointer.block == 0 {
			work_fail(work, .Write)
			return {}
		}
		work.measure.written += 1
		return pointer
	}
	index := int(reference - 1)
	for place in 0 ..< FANOUT {
		child_reference := work.slots[index].refs[place]
		if child_reference == 0 {
			continue
		}
		pointer := write_of(work, child_reference, level - 1)
		if work_failed(work) {
			return {}
		}
		child := &work.slots[index].node.children[place]
		child.block, child.check = pointer.block, pointer.check
	}
	pointer := work.counter.write_node(work.counter, (^Block)(&work.slots[index].node))
	if pointer.block == 0 {
		work_fail(work, .Write)
		return {}
	}
	work.measure.written += 1
	return pointer
}

// The result of a commit on an object.
Finished :: struct {
	root:     Pointer, // The root of the new state.
	root_new: bool, // The work wrote the root: its one name is counted. Else the caller names it.
	blocks:   u64, // The blocks that the new state holds.
	hash:     blake3.Hash,
}

// work_finish computes the values of the parts that the work made, the hash
// of the object, then writes the new blocks, each child before its parent.
work_finish :: proc "contextless" (work: ^Work) -> (result: Finished) {
	if work_failed(work) {
		return
	}
	root := work.root
	if work.root_reference != 0 {
		made, present := values_of(work, work.root_reference, work.levels)
		if !present {
			work.root_reference = 0
			work.root = {}
			work.root_known = true
		} else if work.root_reference < 0 && work.changes[-work.root_reference - 1].kept {
			work.root_reference = 0
			work.root = made
			work.root_known = true
		}
		root = made
	}
	if work.root_reference == 0 {
		root = work.root
		if !work.root_known && root.block != 0 {
			// The root did not change: its blocks are in its node.
			if work.levels == 0 {
				root.blocks = 1
			} else {
				blocks, outcome := state_blocks(work.source, {root = {block = root.block, check = root.check}, size = work.size_before}, &work.scratch)
				if outcome != .Good {
					fail_of_read(work, outcome, root.block)
					return
				}
				root.blocks = blocks
			}
		}
	}
	work.walk = {hash_source = {range_value = work_range_value, last_block = work_last_block}, work = work}
	hash, outcome, last_hashed := object_hash(work.size, &work.walk.hash_source)
	if outcome != .Good {
		fail_of_read(work, outcome, 0)
		return
	}
	if last_hashed {
		work.measure.hashed_blocks += 1
	}
	result.hash = hash
	result.blocks = root.blocks
	if work.root_reference != 0 {
		result.root = write_of(work, work.root_reference, work.levels)
		result.root_new = true
	} else {
		result.root = {block = root.block, check = root.check}
	}
	return result
}

// The hash of the state that the work makes: through the slots, and the
// disk under the parts that did not change.
Work_Hash :: struct {
	using hash_source: Hash_Source,
	work:  ^Work,
	node:  Node,
}

// work_node_at gives the node of `level` of the new state that covers the
// block `index`: found is false when a hole covers it.
@(private)
work_node_at :: proc "contextless" (walk: ^Work_Hash, level: int, index: u64) -> (node: ^Node, base: u64, found: bool, outcome: Read) {
	work := walk.work
	reference := work.root_reference
	child := work.root
	for current := work.levels; current >= level; current -= 1 {
		if reference > 0 {
			node = &work.slots[reference - 1].node
		} else if reference == 0 && child.block != 0 {
			if outcome = node_load(work.source, {block = child.block, check = child.check}, current, base, work.size_before, &walk.node); outcome != .Good {
				return nil, 0, false, outcome
			}
			node = &walk.node
		} else {
			return nil, 0, false, .Good
		}
		if current == level {
			return node, base, true, .Good
		}
		span := format.object_span(current - 1)
		place := int((index - base) / span)
		next := reference > 0 ? work.slots[reference - 1].refs[place] : 0
		child = node.children[place]
		reference = next
		base += u64(place) * span
	}
	return nil, 0, false, .Good
}

@(private)
work_range_value :: proc "contextless" (from: ^Hash_Source, first: u64, count: u64) -> (Value, Read) {
	walk := (^Work_Hash)(from)
	level := unit_level(count, walk.work.levels)
	node, base, found, outcome := work_node_at(walk, level, first)
	if outcome != .Good || !found {
		return {}, outcome
	}
	unit := format.object_span(level - 1)
	return children_value(node, int((first - base) / unit), int(count / unit)), .Good
}

@(private)
work_last_block :: proc "contextless" (from: ^Hash_Source, index: u64, into: ^Block) -> Read {
	walk := (^Work_Hash)(from)
	work := walk.work
	reference := work.root_reference
	child := work.root
	if work.levels > 0 {
		node, base, found, outcome := work_node_at(walk, 1, index)
		if outcome != .Good {
			return outcome
		}
		if !found {
			into^ = {}
			return .Good
		}
		place := int(index - base)
		node_reference := work_node_reference(work, 1, index)
		reference = node_reference > 0 ? work.slots[node_reference - 1].refs[place] : 0
		child = node.children[place]
	}
	if reference < 0 {
		into^ = work.changes[-reference - 1].bytes^
		return .Good
	}
	if child.block == 0 {
		into^ = {}
		return .Good
	}
	_, outcome := block_check(work.source, {block = child.block, check = child.check}, index, into)
	return outcome
}

// work_node_reference gives the reference of the node of `level` on the
// path of the block `index` in the new state: 0 when it is on the disk or a
// hole.
@(private)
work_node_reference :: proc "contextless" (work: ^Work, level: int, index: u64) -> i32 {
	reference := work.root_reference
	base: u64
	for current := work.levels; current > level; current -= 1 {
		if reference <= 0 {
			return 0
		}
		span := format.object_span(current - 1)
		place := int((index - base) / span)
		reference = work.slots[reference - 1].refs[place]
		base += u64(place) * span
	}
	return reference > 0 ? reference : 0
}
