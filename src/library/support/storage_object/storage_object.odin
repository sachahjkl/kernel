// The block tree of one state of an object (src/library/contract/store,
// docs/STORAGE.md "Large objects"): reads of blocks and of ranges, the hash
// of an object, and the work of a commit that changes some blocks, cuts or
// extends the object, by copy on write. Pure code: no kernel operation, no
// allocation. The storage service, the open of a disk, the kernel tool and
// the host tests use it; the blocks come from a Source that the caller
// gives, and a commit counts the names of the blocks and writes its blocks
// through a Counter.
//
// The value of a part of an object is the BLAKE3 chaining value of its
// bytes as a subtree of the BLAKE3 tree of the whole object, zero bytes
// past the size included. The value of a block of data is its check; the
// value of a child of an object node is in the node. A part whose bytes
// are all zero is a hole: its value is zero, and nothing names it. So the
// hash of the object comes from the values of the parts before its last
// block and from the bytes of its last block: a commit hashes the blocks
// that it changed, the nodes above them, and the path of the last block.
package storage_object

import "base:intrinsics"
import "modus:contract/blake3"
import format "modus:contract/store"

// The names of the format of the disk and of BLAKE3 that this package uses.
BLOCK_SIZE :: format.BLOCK_SIZE
FANOUT :: format.OBJECT_FANOUT
LEVEL_LIMIT :: format.OBJECT_LEVEL_LIMIT
CHUNK_SIZE :: blake3.CHUNK_SIZE // The bytes of one chunk of BLAKE3: 1024.
CHUNKS_IN_BLOCK :: BLOCK_SIZE / CHUNK_SIZE // 4: a block is a whole subtree of four chunks.

Block :: [BLOCK_SIZE]u8 // One block: a block of data, or an object node.
Value :: format.Block_Value
Child :: format.Object_Child
Pointer :: format.Pointer
Node :: format.Object_Node

#assert(size_of(Node) == BLOCK_SIZE)

// What a read of a block, or of a value, gave.
Read :: enum {
	Good, // The block is there and has its check.
	Wrong, // A block does not have the check that names it, or breaks a rule of the format.
	Device, // The device reported an error.
}

// ---------------------------------------------------------------------
// Values.

// block_value gives the value of the block `index` of an object: the
// chaining value of its 4096 bytes, its 4 chunks counted from 4 * index.
block_value :: proc "contextless" (bytes: ^Block, index: u64) -> Value {
	return blake3.subtree_chaining_value(bytes[:], index * CHUNKS_IN_BLOCK)
}

// pair_value gives the value of two halves of a whole part: zero when both
// are holes, else the BLAKE3 parent of the two.
pair_value :: proc "contextless" (left, right: Value) -> Value {
	if left == (Value{}) && right == (Value{}) {
		return {}
	}
	return blake3.parent_chaining_value(left, right)
}

// values_join joins a power of two of values two by two, as BLAKE3 joins
// the chunks of a whole subtree. It changes `values`.
values_join :: proc "contextless" (values: []Value) -> Value {
	count := len(values)
	for count > 1 {
		for index in 0 ..< count / 2 {
			values[index] = pair_value(values[2 * index], values[2 * index + 1])
		}
		count /= 2
	}
	return count == 1 ? values[0] : Value{}
}

// children_value gives the value of `count` children of a node from the
// child `first`: count is a power of two, and first a multiple of it.
children_value :: proc "contextless" (node: ^Node, first: int, count: int) -> Value {
	values: [FANOUT]Value
	for index in 0 ..< count {
		values[index] = node.children[first + index].value
	}
	return values_join(values[:count])
}

// node_value gives the value of the whole part that a node covers.
node_value :: proc "contextless" (node: ^Node) -> Value {
	return children_value(node, 0, FANOUT)
}

// is_zero says if each byte is zero.
is_zero :: proc "contextless" (bytes: []u8) -> bool {
	words := len(bytes) / 8
	for index in 0 ..< words {
		if intrinsics.unaligned_load((^u64)(&bytes[index * 8])) != 0 {
			return false
		}
	}
	for index in words * 8 ..< len(bytes) {
		if bytes[index] != 0 {
			return false
		}
	}
	return true
}

// ---------------------------------------------------------------------
// The hash of an object (docs/STORAGE.md, "The hash of an object").

// Hash_Source gives what the hash of an object needs: the value of a whole
// part before the last block, and the bytes of the last block.
Hash_Source :: struct {
	// range_value gives the value of `count` blocks from the block `first`:
	// count is a power of two, first a multiple of it, and each block is
	// before the last block.
	range_value: proc "contextless" (source: ^Hash_Source, first: u64, count: u64) -> (value: Value, outcome: Read),
	// last_block gives the bytes of the block `index`: zero bytes for a hole.
	last_block:  proc "contextless" (source: ^Hash_Source, index: u64, into: ^Block) -> Read,
	data:        rawptr, // The state of the caller.
}

// The state of `object_hash` while it joins the values.
@(private)
Hash_Walk :: struct {
	source:     ^Hash_Source, // Where the values and the last block come from.
	size:       u64, // The bytes of the object.
	last_index: u64, // The index of its last block.
	last:       Block, // The bytes of the last block, once loaded.
	loaded:     bool, // `last` holds them.
	outcome:    Read, // The first read that was not Good.
	last_hashed: bool, // The bytes of the last block were hashed.
}

// left_chunks gives the chunks of the left subtree of `count` chunks (at
// least 2): the largest power of two that is less than count.
left_chunks :: proc "contextless" (count: u64) -> u64 {
	power: u64 = 1
	for power * 2 < count {
		power *= 2
	}
	return power
}

// object_hash gives the hash of an object of `size` bytes. It is the BLAKE3
// hash of the bytes when no block before the last one is a hole; a hole
// counts with the value zero in place of its chaining value, because the
// chaining value of zero bytes depends on their place and costs as much as
// their size. last_hashed says that the bytes of the last block were read
// and hashed.
object_hash :: proc "contextless" (size: u64, source: ^Hash_Source) -> (hash: blake3.Hash, outcome: Read, last_hashed: bool) {
	walk := Hash_Walk{source = source, size = size, outcome = .Good}
	if size <= BLOCK_SIZE {
		if size > 0 {
			if outcome = source.last_block(source, 0, &walk.last); outcome != .Good {
				return {}, outcome, false
			}
		}
		return blake3.hash(walk.last[:size]), .Good, size > 0
	}
	chunks := (size + CHUNK_SIZE - 1) / CHUNK_SIZE
	walk.last_index = (size - 1) / BLOCK_SIZE
	left := left_chunks(chunks)
	left_value := hash_part(&walk, 0, left)
	right_value := hash_part(&walk, left, chunks)
	if walk.outcome != .Good {
		return {}, walk.outcome, false
	}
	return blake3.root_of_children(left_value, right_value), .Good, walk.last_hashed
}

// hash_part gives the value of the chunks [first, end) of the tree of the
// object, a subtree that is not the root.
@(private)
hash_part :: proc "contextless" (walk: ^Hash_Walk, first: u64, end: u64) -> Value {
	if walk.outcome != .Good {
		return {}
	}
	last_first_chunk := walk.last_index * CHUNKS_IN_BLOCK
	if first >= last_first_chunk {
		// Inside the last block: from its bytes, up to the size.
		if !walk.loaded {
			walk.outcome = walk.source.last_block(walk.source, walk.last_index, &walk.last)
			if walk.outcome != .Good {
				return {}
			}
			walk.loaded = true
			walk.last_hashed = true
		}
		start := (first - last_first_chunk) * CHUNK_SIZE
		stop := min((end - last_first_chunk) * CHUNK_SIZE, walk.size - walk.last_index * BLOCK_SIZE)
		return blake3.subtree_chaining_value(walk.last[start:stop], first)
	}
	if end <= last_first_chunk {
		// A whole part before the last block: first and end are multiples
		// of 4 chunks, and its blocks are a power of two.
		value, outcome := walk.source.range_value(walk.source, first / CHUNKS_IN_BLOCK, (end - first) / CHUNKS_IN_BLOCK)
		if outcome != .Good {
			walk.outcome = outcome
		}
		return value
	}
	left := left_chunks(end - first)
	left_value := hash_part(walk, first, first + left)
	right_value := hash_part(walk, first + left, end)
	return blake3.parent_chaining_value(left_value, right_value)
}

// ---------------------------------------------------------------------
// Reads of the block tree of one state on the disk.

// The source of the blocks of the block trees.
Source :: struct {
	// read_node reads an object node and compares it with the check of its
	// Pointer (the hash of its block).
	read_node:  proc "contextless" (source: ^Source, pointer: Pointer, into: ^Block) -> Read,
	// read_block reads a block with no check: Good or Device, and Wrong for
	// a number that names no block of the disk.
	read_block: proc "contextless" (source: ^Source, number: u64, into: ^Block) -> Read,
	// value gives the value of a block of data that read_block gave, at the
	// block `index` of its object. nil: block_value. The kernel tool gives
	// the value that it computed before for the same bytes.
	value:      proc "contextless" (source: ^Source, number: u64, index: u64, bytes: ^Block) -> Value,
	data:       rawptr, // The state of the caller.
}

// One state of an object: the root of its block tree and its size. An entry
// names its current state; a version entry names an older one.
State :: struct {
	root: Pointer, // The root of the block tree: an object node, the one block of data, or no block when each byte is zero.
	size: u64, // The bytes of the object.
}

// node_valid checks the rules of the format for an object node of `level`
// that covers the blocks from `base`, in a state of `size` bytes.
node_valid :: proc "contextless" (node: ^Node, level: int, base: u64, size: u64) -> bool {
	head := &node.header
	if head.magic != format.OBJECT_NODE_MAGIC || int(head.level) != level || level < 1 || level > LEVEL_LIMIT {
		return false
	}
	span := format.object_span(level - 1)
	count := format.object_blocks(size)
	present: u32
	for &child, index in node.children {
		if child.block == 0 {
			if child.check != 0 || child.blocks != 0 || child.value != (Value{}) {
				return false
			}
			continue
		}
		if base + u64(index) * span >= count || child.block < 2 || child.blocks == 0 || (level == 1 && child.blocks != 1) || (level > 1 && child.blocks < 2) {
			return false
		}
		if level == 1 && child.check != format.value_check(child.value) {
			return false
		}
		present += 1
	}
	return present != 0 && present == head.count
}

// node_load reads an object node and checks it.
node_load :: proc "contextless" (source: ^Source, pointer: Pointer, level: int, base: u64, size: u64, into: ^Node) -> Read {
	outcome := source.read_node(source, pointer, (^Block)(into))
	if outcome == .Good && !node_valid(into, level, base, size) {
		return .Wrong
	}
	return outcome
}

// block_check reads a block of data and checks it: its value at its place
// has the check of its Pointer, and it is not a hole.
block_check :: proc "contextless" (source: ^Source, pointer: Pointer, index: u64, into: ^Block) -> (value: Value, outcome: Read) {
	outcome = source.read_block(source, pointer.block, into)
	if outcome != .Good {
		return {}, outcome
	}
	value = source.value != nil ? source.value(source, pointer.block, index, into) : block_value(into, index)
	if format.value_check(value) != pointer.check || is_zero(into[:]) {
		return value, .Wrong
	}
	return value, .Good
}

// block_child gives the Pointer of the block `index` of a state: no block
// for a hole. node is the room of the descent.
block_child :: proc "contextless" (source: ^Source, state: State, index: u64, node: ^Node) -> (pointer: Pointer, outcome: Read) {
	if state.root.block == 0 || index >= format.object_blocks(state.size) {
		return {}, .Good
	}
	levels := format.object_levels(state.size)
	if levels == 0 {
		return state.root, .Good
	}
	pointer = state.root
	base: u64
	for level := levels; level >= 1; level -= 1 {
		if outcome = node_load(source, pointer, level, base, state.size, node); outcome != .Good {
			return {}, outcome
		}
		span := format.object_span(level - 1)
		place := (index - base) / span
		child := node.children[place]
		if child.block == 0 {
			return {}, .Good
		}
		pointer = {block = child.block, check = child.check}
		base += place * span
	}
	return pointer, .Good
}

// block_read reads the block `index` of a state, checked: zero bytes for a
// hole and past the size.
block_read :: proc "contextless" (source: ^Source, state: State, index: u64, into: ^Block, node: ^Node) -> Read {
	pointer, outcome := block_child(source, state, index, node)
	if outcome != .Good {
		return outcome
	}
	if pointer.block == 0 {
		into^ = {}
		return .Good
	}
	_, outcome = block_check(source, pointer, index, into)
	return outcome
}

// range_read reads the bytes from `offset` of a state into `into`, up to
// the size. It gives the count of bytes read.
range_read :: proc "contextless" (source: ^Source, state: State, offset: u64, into: []u8, block: ^Block, node: ^Node) -> (count: u64, outcome: Read) {
	if offset >= state.size {
		return 0, .Good
	}
	end := offset + min(u64(len(into)), state.size - offset)
	for at := offset; at < end; {
		index := at / BLOCK_SIZE
		inside := at % BLOCK_SIZE
		part := min(BLOCK_SIZE - inside, end - at)
		if outcome = block_read(source, state, index, block, node); outcome != .Good {
			return count, outcome
		}
		copy(into[at - offset:][:part], block[inside:][:part])
		at += part
		count += part
	}
	return count, .Good
}

// node_at gives the node of `level` that covers the block `index`: found is
// false when a hole covers it.
@(private)
node_at :: proc "contextless" (source: ^Source, state: State, level: int, index: u64, node: ^Node) -> (base: u64, found: bool, outcome: Read) {
	levels := format.object_levels(state.size)
	if state.root.block == 0 || level > levels || level < 1 {
		return 0, false, .Good
	}
	pointer := state.root
	for current := levels; current >= level; current -= 1 {
		if outcome = node_load(source, pointer, current, base, state.size, node); outcome != .Good {
			return 0, false, outcome
		}
		if current == level {
			return base, true, .Good
		}
		span := format.object_span(current - 1)
		place := (index - base) / span
		child := node.children[place]
		if child.block == 0 {
			return 0, false, .Good
		}
		pointer = {block = child.block, check = child.check}
		base += place * span
	}
	return 0, false, .Good
}

// unit_level gives the level of the node whose children are the units of
// a whole part of `count` blocks: the largest level m + 1 with 64^m at most
// count, and at most `levels`.
unit_level :: proc "contextless" (count: u64, levels: int) -> int {
	level := 1
	for level < levels && format.object_span(level) <= count {
		level += 1
	}
	return level
}

// range_value gives the value of a whole part of a state: count blocks
// from first, count a power of two and first a multiple of it.
range_value :: proc "contextless" (source: ^Source, state: State, first: u64, count: u64, node: ^Node) -> (value: Value, outcome: Read) {
	level := unit_level(count, format.object_levels(state.size))
	base, found, read := node_at(source, state, level, first, node)
	if read != .Good || !found {
		return {}, read
	}
	unit := format.object_span(level - 1)
	return children_value(node, int((first - base) / unit), int(count / unit)), .Good
}

// The walk of the hash of a state on the disk.
State_Hash :: struct {
	using hash_source: Hash_Source,
	source:      ^Source, // Where the blocks come from.
	state:       State, // The state whose hash is computed.
	node:        Node, // A node that the walk reads into.
}

// state_range_value is the `range_value` of a state on the disk.
@(private)
state_range_value :: proc "contextless" (from: ^Hash_Source, first: u64, count: u64) -> (Value, Read) {
	walk := (^State_Hash)(from)
	return range_value(walk.source, walk.state, first, count, &walk.node)
}

// state_last_block is the `last_block` of a state on the disk.
@(private)
state_last_block :: proc "contextless" (from: ^Hash_Source, index: u64, into: ^Block) -> Read {
	walk := (^State_Hash)(from)
	return block_read(walk.source, walk.state, index, into, &walk.node)
}

// state_hash gives the hash of a state on the disk: the path of its last
// block, and the values of the nodes on it.
state_hash :: proc "contextless" (source: ^Source, state: State, room: ^State_Room) -> (hash: blake3.Hash, outcome: Read) {
	room.walk = {hash_source = {range_value = state_range_value, last_block = state_last_block}, source = source, state = state}
	hash, outcome, _ = object_hash(state.size, &room.walk.hash_source)
	return hash, outcome
}

// The room of state_hash: a node and a block, out of the stack.
State_Room :: struct {
	walk: State_Hash,
}

// state_blocks gives the blocks that a state holds: its nodes and its
// blocks of data.
state_blocks :: proc "contextless" (source: ^Source, state: State, node: ^Node) -> (blocks: u64, outcome: Read) {
	if state.root.block == 0 {
		return 0, .Good
	}
	levels := format.object_levels(state.size)
	if levels == 0 {
		return 1, .Good
	}
	if outcome = node_load(source, state.root, levels, 0, state.size, node); outcome != .Good {
		return 0, outcome
	}
	blocks = 1
	for &child in node.children {
		blocks += child.blocks
	}
	return blocks, .Good
}

// next_block gives the first block at or after `from` that is not a hole,
// with its Pointer. found is false when no such block is left.
next_block :: proc "contextless" (source: ^Source, state: State, from: u64, nodes: ^[LEVEL_LIMIT]Node) -> (index: u64, pointer: Pointer, found: bool, outcome: Read) {
	count := format.object_blocks(state.size)
	if state.root.block == 0 || from >= count {
		return 0, {}, false, .Good
	}
	levels := format.object_levels(state.size)
	if levels == 0 {
		return 0, state.root, from == 0, .Good
	}
	return next_under(source, state, state.root, levels, 0, from, nodes)
}

// next_under finds, under one node, the first block of data at or after
// the block `from`.
@(private)
next_under :: proc "contextless" (source: ^Source, state: State, pointer: Pointer, level: int, base: u64, from: u64, nodes: ^[LEVEL_LIMIT]Node) -> (index: u64, found_pointer: Pointer, found: bool, outcome: Read) {
	node := &nodes[level - 1]
	if outcome = node_load(source, pointer, level, base, state.size, node); outcome != .Good {
		return 0, {}, false, outcome
	}
	span := format.object_span(level - 1)
	first := from > base ? int((from - base) / span) : 0
	for place in first ..< FANOUT {
		child := node.children[place]
		if child.block == 0 {
			continue
		}
		child_base := base + u64(place) * span
		if level == 1 {
			return child_base, {block = child.block, check = child.check}, true, .Good
		}
		// The level below reads into its own node: this one stays.
		index, found_pointer, found, outcome = next_under(source, state, {block = child.block, check = child.check}, level - 1, child_base, max(from, child_base), nodes)
		if outcome != .Good || found {
			return
		}
	}
	return 0, {}, false, .Good
}

// Visit of each block of data of a state, in the order of the blocks.
Block_Visit :: proc "contextless" (data: rawptr, index: u64, pointer: Pointer, value: Value)

// walk_blocks calls visit for each block of data of a state, with the
// value that its node holds (zero for the block of a state of one block).
walk_blocks :: proc "contextless" (source: ^Source, state: State, visit: Block_Visit, data: rawptr, nodes: ^[LEVEL_LIMIT]Node) -> Read {
	if state.root.block == 0 {
		return .Good
	}
	levels := format.object_levels(state.size)
	if levels == 0 {
		visit(data, 0, state.root, {})
		return .Good
	}
	return walk_under(source, state, state.root, levels, 0, visit, data, nodes)
}

// walk_under visits each block under one node, the node first.
@(private)
walk_under :: proc "contextless" (source: ^Source, state: State, pointer: Pointer, level: int, base: u64, visit: Block_Visit, data: rawptr, nodes: ^[LEVEL_LIMIT]Node) -> Read {
	node := &nodes[level - 1]
	if outcome := node_load(source, pointer, level, base, state.size, node); outcome != .Good {
		return outcome
	}
	span := format.object_span(level - 1)
	for place in 0 ..< FANOUT {
		child := node.children[place]
		if child.block == 0 {
			continue
		}
		child_base := base + u64(place) * span
		if level == 1 {
			visit(data, child_base, {block = child.block, check = child.check}, child.value)
			continue
		}
		if outcome := walk_under(source, state, {block = child.block, check = child.check}, level - 1, child_base, visit, data, nodes); outcome != .Good {
			return outcome
		}
	}
	return .Good
}
