// The B+ tree of one tree of a store (contract/store, docs/STORAGE.md):
// search, insert, replace, remove, and the walk in the order of the names,
// with copy on write. Pure code: no kernel operation, no allocation.
// The storage service, the open of a disk and the kernel tool use it; the
// blocks come from a Source that the caller gives, and a commit writes the
// changed nodes through a Writer.
//
// A change never writes over a node that the disk has: the first change of
// a node in a commit copies it into a slot of the Pool (it becomes dirty),
// and each node above it becomes dirty too, so that its parent can name
// the copy. A parent names a dirty node with a reference to its slot: a
// Pointer with no block. finish writes the dirty nodes, the children
// before their parent, and gives the new root. The blocks that the tree
// stops naming are in Pool.released: the caller frees them with its
// commit, or forgets them when it drops the commit.
//
// One Work is one tree; the trees of one commit share one Pool. A tree
// inside a tree is the Pointer in an entry: the caller finishes the inner
// tree first, and puts its new root in the entry of the outer one.
package storage_tree

import format "contract:store"

BLOCK_SIZE :: format.BLOCK_SIZE
HEADER_SIZE :: format.TREE_HEADER_SIZE
DEPTH_LIMIT :: format.TREE_DEPTH_LIMIT
Block :: [BLOCK_SIZE]u8
Pointer :: format.Pointer

// The size of the keys and of the values of a tree. The disk has one
// shape; the host tests use it too.
Shape :: struct {
	key_size:        int,
	value_size:      int,
	leaf_capacity:   int,
	branch_capacity: int,
}

TREE_SHAPE :: Shape{size_of(format.Entry_Name), size_of(format.Entry), format.LEAF_CAPACITY, format.BRANCH_CAPACITY}
KEY_SIZE_LIMIT :: size_of(format.Entry_Name)

Read :: enum {
	Good,
	Wrong, // The block does not have the check of its Pointer, or the Pointer names no block of the disk.
	Device, // The device reported an error.
}

// The source of the nodes: it reads one block and compares it with the
// check of its Pointer.
Source :: struct {
	read: proc "contextless" (source: ^Source, pointer: Pointer, into: ^Block) -> Read,
	data: rawptr,
}

// The writer of a commit: it writes one block to a free block and gives
// its Pointer, or a Pointer with no block when it cannot.
Writer :: struct {
	write: proc "contextless" (writer: ^Writer, bytes: ^Block) -> Pointer,
	data:  rawptr,
}

Failure :: enum {
	None,
	Device, // A read failed on the device.
	Wrong, // A node has a wrong check: `failed_block` names it.
	Damaged, // A node breaks a rule of the format (its magic, its level, its count, the order of its keys): `failed_block` names it.
	Full, // The pool has no free slot, or a tree would pass DEPTH_LIMIT levels.
	Write, // The writer gave no block.
}

Slot_State :: enum u8 {
	Free,
	Clean, // A copy of a node of the disk, for reading.
	Dirty, // A node that the commit writes.
}

Slot :: struct {
	bytes:    Block,
	original: Pointer, // The node of the disk that it copies. No block: a new node.
	state:    Slot_State,
}

// The slots of the nodes of one commit, for the trees of one store. A
// commit of one change needs about 2 * DEPTH_LIMIT slots; the largest step
// of the service, a part of a remove of 64 entries, about 200.
POOL_CAPACITY :: 512

Pool :: struct {
	slots:          [POOL_CAPACITY]Slot,
	released:       [POOL_CAPACITY]Pointer, // Nodes of the disk that the trees stop naming.
	released_count: int,
	written:        int, // The nodes that finish wrote.
	failure:        Failure,
	failed_block:   u64,
}

// One tree of a commit: its shape and its root, a Pointer of the disk or a
// reference to a dirty slot. A root with no block and a check of 0: the
// tree is empty.
Work :: struct {
	pool:   ^Pool,
	source: ^Source,
	shape:  Shape,
	root:   Pointer,
}

pool_reset :: proc "contextless" (pool: ^Pool) {
	for &slot in pool.slots {
		slot.state = .Free
	}
	pool.released_count = 0
	pool.written = 0
	pool.failure = .None
	pool.failed_block = 0
}

// pool_trim frees the clean slots: no parent names one by its slot, so
// each operation can read its nodes again.
pool_trim :: proc "contextless" (pool: ^Pool) {
	for &slot in pool.slots {
		if slot.state == .Clean {
			slot.state = .Free
		}
	}
}

failed :: proc "contextless" (work: ^Work) -> bool {
	return work.pool.failure != .None
}

fail :: proc "contextless" (work: ^Work, failure: Failure, block: u64 = 0) {
	if work.pool.failure == .None {
		work.pool.failure = failure
		work.pool.failed_block = block
	}
}

// ---------------------------------------------------------------------
// The layout of a node.

header :: #force_inline proc "contextless" (bytes: ^Block) -> ^format.Tree_Header {
	return (^format.Tree_Header)(bytes)
}

record_size :: #force_inline proc "contextless" (shape: Shape, level: u32) -> int {
	return shape.key_size + (level == 0 ? shape.value_size : size_of(Pointer))
}

capacity_of :: #force_inline proc "contextless" (shape: Shape, level: u32) -> int {
	return level == 0 ? shape.leaf_capacity : shape.branch_capacity
}

record_at :: #force_inline proc "contextless" (bytes: ^Block, shape: Shape, index: int) -> []u8 {
	size := record_size(shape, header(bytes).level)
	return bytes[HEADER_SIZE + index * size:][:size]
}

key_at :: #force_inline proc "contextless" (bytes: ^Block, shape: Shape, index: int) -> []u8 {
	return record_at(bytes, shape, index)[:shape.key_size]
}

value_at :: #force_inline proc "contextless" (bytes: ^Block, shape: Shape, index: int) -> []u8 {
	return record_at(bytes, shape, index)[shape.key_size:]
}

// child_at gives the Pointer of the child n of a branch. A record has a
// size that is a multiple of 8, and starts after a header of 32 bytes: the
// Pointer is aligned.
child_at :: #force_inline proc "contextless" (bytes: ^Block, shape: Shape, index: int) -> ^Pointer {
	return (^Pointer)(raw_data(record_at(bytes, shape, index)[shape.key_size:]))
}

// compare orders two keys byte by byte: -1, 0 or 1.
compare :: proc "contextless" (a, b: []u8) -> int {
	for index in 0 ..< min(len(a), len(b)) {
		if a[index] != b[index] {
			return a[index] < b[index] ? -1 : 1
		}
	}
	return len(a) < len(b) ? -1 : len(a) > len(b) ? 1 : 0
}

copy_bytes :: #force_inline proc "contextless" (to, from: []u8) {
	copy(to, from)
}

// node_valid checks the rules of the format for a node: its magic, its
// level, its count, and the order of its keys.
node_valid :: proc "contextless" (bytes: ^Block, shape: Shape) -> bool {
	head := header(bytes)
	if head.magic != format.NODE_MAGIC || head.level >= DEPTH_LIMIT || head.count == 0 || int(head.count) > capacity_of(shape, head.level) {
		return false
	}
	// In a branch, the key of the record 0 is a bound only: the order starts
	// at the record 1. It is still at most the key of the record 1.
	for index in 1 ..< int(head.count) {
		if compare(key_at(bytes, shape, index - 1), key_at(bytes, shape, index)) >= 0 {
			return false
		}
	}
	return true
}

// ---------------------------------------------------------------------
// Slots.

reference :: #force_inline proc "contextless" (slot: int) -> Pointer {
	return {block = 0, check = u64(slot) + 1}
}

is_reference :: #force_inline proc "contextless" (pointer: Pointer) -> bool {
	return pointer.block == 0 && pointer.check != 0
}

is_empty :: #force_inline proc "contextless" (pointer: Pointer) -> bool {
	return pointer.block == 0 && pointer.check == 0
}

slot_take :: proc "contextless" (work: ^Work) -> int {
	for &slot, index in work.pool.slots {
		if slot.state == .Free {
			return index
		}
	}
	fail(work, .Full)
	return -1
}

// load gives the slot of a node that a parent or a root names, or -1. A
// node read from the disk is checked against the format: `level` is the
// level that its parent expects (-1 for a root).
load :: proc "contextless" (work: ^Work, pointer: Pointer, level: int) -> int {
	if failed(work) {
		return -1
	}
	if is_reference(pointer) {
		index := int(pointer.check - 1)
		if index >= POOL_CAPACITY || work.pool.slots[index].state != .Dirty {
			fail(work, .Damaged)
			return -1
		}
		return index
	}
	index := slot_take(work)
	if index < 0 {
		return -1
	}
	slot := &work.pool.slots[index]
	switch work.source.read(work.source, pointer, &slot.bytes) {
	case .Device:
		fail(work, .Device, pointer.block)
		return -1
	case .Wrong:
		fail(work, .Wrong, pointer.block)
		return -1
	case .Good:
	}
	if !node_valid(&slot.bytes, work.shape) || level >= 0 && int(header(&slot.bytes).level) != level {
		fail(work, .Damaged, pointer.block)
		return -1
	}
	slot.original = pointer
	slot.state = .Clean
	return index
}

// dirty makes a slot a node that the commit writes: the node of the disk
// that it copies is released.
dirty :: proc "contextless" (work: ^Work, index: int) {
	slot := &work.pool.slots[index]
	if slot.state == .Dirty {
		return
	}
	if slot.original.block != 0 {
		work.pool.released[work.pool.released_count] = slot.original
		work.pool.released_count += 1
	}
	slot.original = {}
	slot.state = .Dirty
}

// slot_new gives a new dirty node of a level, with no record.
slot_new :: proc "contextless" (work: ^Work, level: u32) -> int {
	index := slot_take(work)
	if index < 0 {
		return -1
	}
	slot := &work.pool.slots[index]
	slot.bytes = {}
	slot.original = {}
	slot.state = .Dirty
	head := header(&slot.bytes)
	head.level = level
	head.magic = format.NODE_MAGIC
	return index
}

// slot_free drops a dirty node that a merge emptied: its node of the disk
// was released when it became dirty.
slot_free :: proc "contextless" (work: ^Work, index: int) {
	work.pool.slots[index].state = .Free
}

bytes_of :: #force_inline proc "contextless" (work: ^Work, index: int) -> ^Block {
	return &work.pool.slots[index].bytes
}

// ---------------------------------------------------------------------
// The path from the root to a leaf.

Path :: struct {
	slots:     [DEPTH_LIMIT]int, // slots[0]: the root.
	positions: [DEPTH_LIMIT]int, // In a branch: the child taken. In the leaf: the place of the key.
	depth:     int, // The count of nodes; the leaf is slots[depth - 1].
	found:     bool, // The leaf has the key at its place.
}

// branch_position gives the child of a branch to take for a key: the last
// record whose key is at most the key, and the record 0 when none is.
branch_position :: proc "contextless" (bytes: ^Block, shape: Shape, key: []u8) -> int {
	low, high := 1, int(header(bytes).count) // The answer is in [low - 1, high - 1].
	for low < high {
		middle := (low + high) / 2
		if compare(key_at(bytes, shape, middle), key) <= 0 {
			low = middle + 1
		} else {
			high = middle
		}
	}
	return low - 1
}

// leaf_position gives the place of the first record whose key is at least
// the key, and if that key is the key.
leaf_position :: proc "contextless" (bytes: ^Block, shape: Shape, key: []u8) -> (position: int, found: bool) {
	low, high := 0, int(header(bytes).count)
	for low < high {
		middle := (low + high) / 2
		if compare(key_at(bytes, shape, middle), key) < 0 {
			low = middle + 1
		} else {
			high = middle
		}
	}
	return low, low < int(header(bytes).count) && compare(key_at(bytes, shape, low), key) == 0
}

// descend finds the leaf of a key. ok is false for an empty tree or a
// failure.
descend :: proc "contextless" (work: ^Work, key: []u8) -> (path: Path, ok: bool) {
	if is_empty(work.root) {
		return path, false
	}
	index := load(work, work.root, -1)
	for index >= 0 {
		if path.depth >= DEPTH_LIMIT {
			fail(work, .Damaged)
			return path, false
		}
		path.slots[path.depth] = index
		bytes := bytes_of(work, index)
		level := header(bytes).level
		if level == 0 {
			path.positions[path.depth], path.found = leaf_position(bytes, work.shape, key)
			path.depth += 1
			return path, true
		}
		position := branch_position(bytes, work.shape, key)
		path.positions[path.depth] = position
		path.depth += 1
		index = load(work, child_at(bytes, work.shape, position)^, int(level) - 1)
	}
	return path, false
}

// path_dirty makes each node of a path dirty, the root first, and makes
// each parent name its child by its slot.
path_dirty :: proc "contextless" (work: ^Work, path: ^Path) {
	for depth in 0 ..< path.depth {
		dirty(work, path.slots[depth])
		if depth == 0 {
			work.root = reference(path.slots[0])
		} else {
			parent := bytes_of(work, path.slots[depth - 1])
			child_at(parent, work.shape, path.positions[depth - 1])^ = reference(path.slots[depth])
		}
	}
}

// ---------------------------------------------------------------------
// Reads.

// get copies the value of a key into `value`. found is false when the tree
// does not have the key, or on a failure (see failed).
get :: proc "contextless" (work: ^Work, key: []u8, value: []u8) -> (found: bool) {
	pool_trim(work.pool)
	path, ok := descend(work, key)
	if !ok || !path.found {
		return false
	}
	leaf := bytes_of(work, path.slots[path.depth - 1])
	copy_bytes(value, value_at(leaf, work.shape, path.positions[path.depth - 1]))
	return true
}

// first_from copies the first record whose key is at least `key` (after
// `key` when `after`) into key_out and value_out. found is false at the
// end of the tree, or on a failure.
first_from :: proc "contextless" (work: ^Work, key: []u8, after: bool, key_out: []u8, value_out: []u8) -> (found: bool) {
	pool_trim(work.pool)
	path, ok := descend(work, key)
	if !ok {
		return false
	}
	leaf := bytes_of(work, path.slots[path.depth - 1])
	position := path.positions[path.depth - 1]
	if after && path.found {
		position += 1
	}
	if position < int(header(leaf).count) {
		copy_bytes(key_out, key_at(leaf, work.shape, position))
		copy_bytes(value_out, value_at(leaf, work.shape, position))
		return true
	}
	// The next leaf: up to the first branch with a child after the one
	// taken, then down its leftmost children.
	for depth := path.depth - 2; depth >= 0; depth -= 1 {
		branch := bytes_of(work, path.slots[depth])
		next := path.positions[depth] + 1
		if next >= int(header(branch).count) {
			continue
		}
		level := int(header(branch).level)
		index := load(work, child_at(branch, work.shape, next)^, level - 1)
		for index >= 0 && header(bytes_of(work, index)).level != 0 {
			node := bytes_of(work, index)
			index = load(work, child_at(node, work.shape, 0)^, int(header(node).level) - 1)
		}
		if index < 0 {
			return false
		}
		node := bytes_of(work, index)
		copy_bytes(key_out, key_at(node, work.shape, 0))
		copy_bytes(value_out, value_at(node, work.shape, 0))
		return true
	}
	return false
}

// ---------------------------------------------------------------------
// Changes.

// record_insert puts a record at a place of a node that has room.
record_insert :: proc "contextless" (bytes: ^Block, shape: Shape, position: int, key: []u8, payload: []u8) {
	head := header(bytes)
	size := record_size(shape, head.level)
	count := int(head.count)
	start := HEADER_SIZE + position * size
	copy(bytes[start + size:HEADER_SIZE + (count + 1) * size], bytes[start:HEADER_SIZE + count * size])
	copy(bytes[start:][:shape.key_size], key)
	copy(bytes[start + shape.key_size:][:size - shape.key_size], payload)
	head.count += 1
}

// record_remove removes the record at a place, and clears the last place.
record_remove :: proc "contextless" (bytes: ^Block, shape: Shape, position: int) {
	head := header(bytes)
	size := record_size(shape, head.level)
	count := int(head.count)
	start := HEADER_SIZE + position * size
	copy(bytes[start:HEADER_SIZE + (count - 1) * size], bytes[start + size:HEADER_SIZE + count * size])
	for &byte in bytes[HEADER_SIZE + (count - 1) * size:][:size] {
		byte = 0
	}
	head.count -= 1
}

// records_move moves `count` records of `from`, from its place `first`, to
// the place `at` of `to`, which has room; the records of `to` from `at`
// move after them. Both nodes have one level.
records_move :: proc "contextless" (to: ^Block, at: int, from: ^Block, first: int, count: int, shape: Shape) {
	if count == 0 {
		return
	}
	size := record_size(shape, header(to).level)
	to_count := int(header(to).count)
	from_count := int(header(from).count)
	copy(to[HEADER_SIZE + (at + count) * size:HEADER_SIZE + (to_count + count) * size], to[HEADER_SIZE + at * size:HEADER_SIZE + to_count * size])
	copy(to[HEADER_SIZE + at * size:][:count * size], from[HEADER_SIZE + first * size:][:count * size])
	header(to).count += u32(count)
	copy(from[HEADER_SIZE + first * size:HEADER_SIZE + (from_count - count) * size], from[HEADER_SIZE + (first + count) * size:HEADER_SIZE + from_count * size])
	for &byte in from[HEADER_SIZE + (from_count - count) * size:][:count * size] {
		byte = 0
	}
	header(from).count -= u32(count)
}

// node_insert puts a record at a place of the node at `depth` of a dirty
// path; a full node splits, and its new right half goes into its parent.
node_insert :: proc "contextless" (work: ^Work, path: ^Path, depth: int, position: int, key: []u8, payload: []u8) {
	shape := work.shape
	index := path.slots[depth]
	bytes := bytes_of(work, index)
	level := header(bytes).level
	if int(header(bytes).count) < capacity_of(shape, level) {
		record_insert(bytes, shape, position, key, payload)
		return
	}
	if depth == 0 && int(level) + 1 >= DEPTH_LIMIT {
		fail(work, .Full)
		return
	}
	right := slot_new(work, level)
	if right < 0 {
		return
	}
	right_bytes := bytes_of(work, right)
	count := int(header(bytes).count)
	half := count / 2
	records_move(right_bytes, 0, bytes, half, count - half, shape)
	if position <= half {
		record_insert(bytes, shape, position, key, payload)
	} else {
		record_insert(right_bytes, shape, position - half, key, payload)
	}
	separator: [KEY_SIZE_LIMIT]u8
	copy(separator[:], key_at(right_bytes, shape, 0))
	pointer := reference(right)
	pointer_bytes := ([^]u8)(&pointer)[:size_of(Pointer)]
	if depth == 0 {
		// A new root above the two halves.
		root := slot_new(work, level + 1)
		if root < 0 {
			return
		}
		root_bytes := bytes_of(work, root)
		left := reference(index)
		record_insert(root_bytes, shape, 0, key_at(bytes, shape, 0), ([^]u8)(&left)[:size_of(Pointer)])
		record_insert(root_bytes, shape, 1, separator[:shape.key_size], pointer_bytes)
		work.root = reference(root)
		return
	}
	node_insert(work, path, depth - 1, path.positions[depth - 1] + 1, separator[:shape.key_size], pointer_bytes)
}

// put writes a record: a new key, or a new value for a key that the tree
// has (only when `replace`). existed says if the tree had the key; a key
// that exists with no `replace` changes nothing.
put :: proc "contextless" (work: ^Work, key: []u8, value: []u8, replace: bool) -> (existed: bool) {
	pool_trim(work.pool)
	if failed(work) {
		return false
	}
	if is_empty(work.root) {
		leaf := slot_new(work, 0)
		if leaf < 0 {
			return false
		}
		record_insert(bytes_of(work, leaf), work.shape, 0, key, value)
		work.root = reference(leaf)
		return false
	}
	path, ok := descend(work, key)
	if !ok {
		return false
	}
	if path.found && !replace {
		return true
	}
	path_dirty(work, &path)
	leaf := bytes_of(work, path.slots[path.depth - 1])
	position := path.positions[path.depth - 1]
	if path.found {
		copy_bytes(value_at(leaf, work.shape, position), value)
		return true
	}
	node_insert(work, &path, path.depth - 1, position, key, value)
	return false
}

// remove removes a key. existed says if the tree had it.
remove :: proc "contextless" (work: ^Work, key: []u8) -> (existed: bool) {
	pool_trim(work.pool)
	path, ok := descend(work, key)
	if !ok || !path.found {
		return false
	}
	path_dirty(work, &path)
	leaf := bytes_of(work, path.slots[path.depth - 1])
	record_remove(leaf, work.shape, path.positions[path.depth - 1])
	rebalance(work, &path, path.depth - 1)
	return true
}

// The least count of a node that does not take records from a sibling. A
// third of the capacity: a merge of two nodes at this count leaves room
// for a third of a node of inserts before the next split.
minimum_count :: proc "contextless" (shape: Shape, level: u32) -> int {
	return max(capacity_of(shape, level) / 3, 1)
}

// rebalance repairs the node at `depth` of a dirty path after a remove: a
// root branch of one child gives its place to the child; an empty root
// leaf empties the tree; a node under its minimum takes records from a
// sibling, or merges with it.
rebalance :: proc "contextless" (work: ^Work, path: ^Path, depth: int) {
	if failed(work) {
		return
	}
	shape := work.shape
	index := path.slots[depth]
	bytes := bytes_of(work, index)
	level := header(bytes).level
	count := int(header(bytes).count)
	if depth == 0 {
		if count == 0 {
			slot_free(work, index)
			work.root = {}
		} else if level > 0 && count == 1 {
			work.root = child_at(bytes, shape, 0)^
			slot_free(work, index)
		}
		return
	}
	if count >= minimum_count(shape, level) {
		return
	}
	parent_index := path.slots[depth - 1]
	parent := bytes_of(work, parent_index)
	position := path.positions[depth - 1]
	// The pair: the node and its right sibling, or its left sibling and the
	// node when it is the last child.
	left_position := position
	if position + 1 >= int(header(parent).count) {
		left_position = position - 1
	}
	if left_position < 0 {
		// A branch with one child that is not the root: the format does not
		// make one (a merge leaves at least one record in a branch that is
		// not the root, and a root of one child gives its place).
		if count == 0 {
			fail(work, .Damaged)
		}
		return
	}
	left := load(work, child_at(parent, shape, left_position)^, int(level))
	right := load(work, child_at(parent, shape, left_position + 1)^, int(level))
	if left < 0 || right < 0 {
		return
	}
	dirty(work, left)
	dirty(work, right)
	child_at(parent, shape, left_position)^ = reference(left)
	child_at(parent, shape, left_position + 1)^ = reference(right)
	left_bytes := bytes_of(work, left)
	right_bytes := bytes_of(work, right)
	// In a branch, the key of the record 0 of the right node becomes the
	// key of the parent for it: the exact bound, before records move past it.
	if level > 0 {
		copy(key_at(right_bytes, shape, 0), key_at(parent, shape, left_position + 1))
	}
	left_count := int(header(left_bytes).count)
	right_count := int(header(right_bytes).count)
	if left_count + right_count <= capacity_of(shape, level) {
		records_move(left_bytes, left_count, right_bytes, 0, right_count, shape)
		slot_free(work, right)
		record_remove(parent, shape, left_position + 1)
		rebalance(work, path, depth - 1)
		return
	}
	// Records move from the larger node to the smaller one, until each has
	// half of them.
	total := left_count + right_count
	if left_count < right_count {
		records_move(left_bytes, left_count, right_bytes, 0, total / 2 - left_count, shape)
	} else {
		records_move(right_bytes, 0, left_bytes, total - total / 2, left_count - (total - total / 2), shape)
	}
	copy(key_at(parent, shape, left_position + 1), key_at(right_bytes, shape, 0))
}

// ---------------------------------------------------------------------
// The commit.

// finish writes the dirty nodes of a tree, each child before its parent,
// and gives the Pointer of the root on the disk. The root is unchanged
// when no node of the tree is dirty.
finish :: proc "contextless" (work: ^Work, writer: ^Writer) -> Pointer {
	if failed(work) || !is_reference(work.root) {
		return work.root
	}
	write_node :: proc "contextless" (work: ^Work, writer: ^Writer, index: int, depth: int) -> Pointer {
		if depth >= DEPTH_LIMIT {
			fail(work, .Damaged)
			return {}
		}
		bytes := bytes_of(work, index)
		if header(bytes).level > 0 {
			for child in 0 ..< int(header(bytes).count) {
				pointer := child_at(bytes, work.shape, child)
				if is_reference(pointer^) {
					pointer^ = write_node(work, writer, int(pointer.check - 1), depth + 1)
					if failed(work) {
						return {}
					}
				}
			}
		}
		written := writer.write(writer, bytes)
		if written.block == 0 {
			fail(work, .Write)
			return {}
		}
		work.pool.written += 1
		return written
	}
	root := write_node(work, writer, int(work.root.check - 1), 0)
	if !failed(work) {
		work.root = root
	}
	return work.root
}

// ---------------------------------------------------------------------
// The walk of a whole tree, for the open of a disk: each node one time,
// in the order of the keys. visit_node is called for each node with its
// Pointer before its records are read; visit_record for each record of
// each leaf. A node that visit_node refuses is not read.

Walk :: struct {
	source:       ^Source,
	shape:        Shape,
	stack:        [DEPTH_LIMIT]Block,
	visit_node:   proc "contextless" (walk: ^Walk, pointer: Pointer) -> bool,
	visit_record: proc "contextless" (walk: ^Walk, key: []u8, value: []u8),
	data:         rawptr,
	failure:      Failure,
	failed_block: u64,
	nodes:        u64,
	records:      u64,
	// The last key that the walk saw: the keys of the whole tree are in
	// order, each one once, else the tree is damaged.
	last_key:     [KEY_SIZE_LIMIT]u8,
	has_last:     bool,
}

walk_tree :: proc "contextless" (walk: ^Walk, root: Pointer) -> Failure {
	walk.failure = .None
	walk.has_last = false
	if root.block == 0 {
		return .None
	}
	walk_node(walk, root, 0, -1)
	return walk.failure
}

@(private)
walk_node :: proc "contextless" (walk: ^Walk, pointer: Pointer, depth: int, level: int) {
	if walk.failure != .None {
		return
	}
	if depth >= DEPTH_LIMIT {
		walk.failure, walk.failed_block = .Damaged, pointer.block
		return
	}
	if walk.visit_node != nil && !walk.visit_node(walk, pointer) {
		return
	}
	bytes := &walk.stack[depth]
	switch walk.source.read(walk.source, pointer, bytes) {
	case .Device:
		walk.failure, walk.failed_block = .Device, pointer.block
		return
	case .Wrong:
		walk.failure, walk.failed_block = .Wrong, pointer.block
		return
	case .Good:
	}
	if !node_valid(bytes, walk.shape) || level >= 0 && int(header(bytes).level) != level {
		walk.failure, walk.failed_block = .Damaged, pointer.block
		return
	}
	walk.nodes += 1
	head := header(bytes)
	for index in 0 ..< int(head.count) {
		if head.level == 0 {
			key := key_at(bytes, walk.shape, index)
			if walk.has_last && compare(walk.last_key[:walk.shape.key_size], key) >= 0 {
				walk.failure, walk.failed_block = .Damaged, pointer.block
				return
			}
			copy(walk.last_key[:], key)
			walk.has_last = true
			walk.records += 1
			if walk.visit_record != nil {
				walk.visit_record(walk, key, value_at(bytes, walk.shape, index))
			}
		} else {
			walk_node(walk, child_at(bytes, walk.shape, index)^, depth + 1, int(head.level) - 1)
		}
		if walk.failure != .None {
			return
		}
	}
}
