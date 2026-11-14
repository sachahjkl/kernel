#+build !freestanding
package storage_object

import "base:runtime"
import "contract:blake3"
import format "contract:store"
import "core:encoding/hex"
import "core:slice"
import "core:testing"

// A disk in memory, with the count of the names of each block.
@(private = "file")
Test_Disk :: struct {
	source:  Source, // First: a ^Source is a ^Test_Disk.
	counter: Counter,
	blocks:  [dynamic]Block,
	names:   [dynamic]int,
}

@(private = "file")
test_read_node :: proc "contextless" (source: ^Source, pointer: Pointer, into: ^Block) -> Read {
	disk := (^Test_Disk)(source)
	if pointer.block < 2 || pointer.block >= u64(len(disk.blocks)) {
		return .Wrong
	}
	into^ = disk.blocks[pointer.block]
	return format.check(into[:]) == pointer.check ? .Good : .Wrong
}

@(private = "file")
test_read_block :: proc "contextless" (source: ^Source, number: u64, into: ^Block) -> Read {
	disk := (^Test_Disk)(source)
	if number < 2 || number >= u64(len(disk.blocks)) {
		return .Wrong
	}
	into^ = disk.blocks[number]
	return .Good
}

@(private = "file")
test_disk_of :: proc "contextless" (counter: ^Counter) -> ^Test_Disk {
	return (^Test_Disk)(rawptr(uintptr(counter) - offset_of(Test_Disk, counter)))
}

@(private = "file")
test_name :: proc "contextless" (counter: ^Counter, block: u64) {
	disk := test_disk_of(counter)
	disk.names[block] += 1
}

@(private = "file")
test_release :: proc "contextless" (counter: ^Counter, child: Child, level: int) {
	disk := test_disk_of(counter)
	disk.names[child.block] -= 1
	if disk.names[child.block] != 0 || level == 0 {
		return
	}
	node := (^Node)(&disk.blocks[child.block])
	for item in node.children {
		if item.block != 0 {
			test_release(counter, item, level - 1)
		}
	}
}

@(private = "file")
test_put :: proc "contextless" (counter: ^Counter, bytes: ^Block) -> u64 {
	disk := test_disk_of(counter)
	context = runtime.default_context()
	number := u64(len(disk.blocks))
	append(&disk.blocks, bytes^)
	append(&disk.names, 1)
	return number
}

@(private = "file")
test_write_node :: proc "contextless" (counter: ^Counter, bytes: ^Block) -> Pointer {
	number := test_put(counter, bytes)
	return {block = number, check = format.check(bytes[:])}
}

@(private = "file")
test_write_data :: proc "contextless" (counter: ^Counter, bytes: ^Block, check: u64) -> Pointer {
	return {block = test_put(counter, bytes), check = check}
}

@(private = "file")
disk_make :: proc() -> ^Test_Disk {
	disk := new(Test_Disk)
	disk.source = {read_node = test_read_node, read_block = test_read_block}
	disk.counter = {name = test_name, release = test_release, write_node = test_write_node, write_data = test_write_data}
	// Blocks 0 and 1 are the places of the root of a real disk.
	append(&disk.blocks, Block{}, Block{})
	append(&disk.names, 1, 1)
	return disk
}

@(private = "file")
disk_free :: proc(disk: ^Test_Disk) {
	delete(disk.blocks)
	delete(disk.names)
	free(disk)
}

// The blocks that some name holds, but blocks 0 and 1.
@(private = "file")
live_blocks :: proc(disk: ^Test_Disk) -> (count: u64) {
	for names in disk.names[2:] {
		if names > 0 {
			count += 1
		}
	}
	return count
}

// One commit: the state before stays named by its version; the new root is
// named by its entry.
@(private = "file")
commit :: proc(disk: ^Test_Disk, before: State, cut: u64, size: u64, changes: []Change) -> (after: State, finished: Finished, measure: Measure, ok: bool) {
	work := new(Work)
	defer free(work)
	work_begin(work, &disk.source, &disk.counter, before, changes)
	work_cut(work, cut)
	work_resize(work, size)
	for index in 0 ..< len(changes) {
		work_change(work, index)
	}
	finished = work_finish(work)
	if work_failed(work) {
		return {}, {}, {}, false
	}
	if !finished.root_new && finished.root.block != 0 {
		disk.names[finished.root.block] += 1
	}
	return {root = finished.root, size = size}, finished, work.measure, true
}

// release_state takes the name of the root of a state.
@(private = "file")
release_state :: proc(disk: ^Test_Disk, state: State) {
	if state.root.block != 0 {
		test_release(&disk.counter, {block = state.root.block, check = state.root.check}, format.object_levels(state.size))
	}
}

// changes_of gives the changes that make `bytes` the whole object.
@(private = "file")
changes_of :: proc(bytes: []u8) -> []Change {
	count := format.object_blocks(u64(len(bytes)))
	changes := make([]Change, count, context.temp_allocator)
	for &change, index in changes {
		block := new(Block, context.temp_allocator)
		copy(block[:], bytes[index * BLOCK_SIZE:])
		change = {index = u64(index), bytes = block}
	}
	return changes
}

@(private = "file")
read_whole :: proc(disk: ^Test_Disk, state: State) -> (bytes: []u8, ok: bool) {
	bytes = make([]u8, state.size, context.temp_allocator)
	block := new(Block, context.temp_allocator)
	node := new(Node, context.temp_allocator)
	count, outcome := range_read(&disk.source, state, 0, bytes, block, node)
	return bytes, outcome == .Good && count == state.size
}

@(private = "file")
pattern :: proc(size: int) -> []u8 {
	bytes := make([]u8, size, context.temp_allocator)
	for &byte, index in bytes {
		byte = u8(index % 251)
	}
	return bytes
}

// The official vectors of BLAKE3 (src/library/contract/blake3): an object with no hole
// has the BLAKE3 hash of its bytes, whatever its levels.
@(test)
hash_of_known_vectors :: proc(t: ^testing.T) {
	Vector :: struct {
		size: int,
		hash: string,
	}
	vectors := [?]Vector {
		{0, "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262"},
		{1, "2d3adedff11b61f14c886e35afa036736dcd87a74d27b5c1510225d0f592e213"},
		{1024, "42214739f095a406f3fc83deb889744ac00df831c10daa55189b5d121c855af7"},
		{4096, "015094013f57a5277b59d8475c0501042c0b642e531b0a1c8f58d2163229e969"},
		{4097, "9b4052b38f1c5fc8b1f9ff7ac7b27cd242487b3d890d15c96a1c25b8aa0fb995"},
		{5121, "628bd2cb2004694adaab7bbd778a25df25c47b9d4155a55f8fbd79f2fe154cff"},
		{8192, "aae792484c8efe4f19e2ca7d371d8c467ffb10748d8a5a1ae579948f718a2a63"},
		{8193, "bab6c09cb8ce8cf459261398d2e7aef35700bf488116ceb94a36d0f5f1b7bc3b"},
		{16384, "f875d6646de28985646f34ee13be9a576fd515f76b5b0a26bb324735041ddde4"},
		{31744, "62b6960e1a44bcc1eb1a611a8d6235b6b4b78f32e7abc4fb4c6cdcce94895c47"},
		{102400, "bc3e3d41a1146b069abffad3c0d44860cf664390afce4d9661f7902e7943e085"},
	}
	for vector in vectors {
		disk := disk_make()
		defer disk_free(disk)
		bytes := pattern(vector.size)
		_, finished, _, ok := commit(disk, {}, 0, u64(vector.size), changes_of(bytes))
		testing.expectf(t, ok, "size %d: the commit failed", vector.size)
		text := string(hex.encode(finished.hash[:], context.temp_allocator))
		testing.expectf(t, text == vector.hash, "size %d: got %s, want %s", vector.size, text, vector.hash)
	}
	// Past one node of level 1, and past one of level 2: the levels change,
	// the hash does not.
	for size in ([]int{64 * BLOCK_SIZE, 64 * BLOCK_SIZE + 1, 4096 * BLOCK_SIZE + 77}) {
		disk := disk_make()
		defer disk_free(disk)
		bytes := pattern(size)
		state, finished, _, ok := commit(disk, {}, 0, u64(size), changes_of(bytes))
		testing.expectf(t, ok && finished.hash == blake3.hash(bytes), "size %d: the hash of the object is not the BLAKE3 hash of its bytes", size)
		read, read_ok := read_whole(disk, state)
		testing.expectf(t, read_ok && slice.equal(read, bytes), "size %d: the bytes read back differ", size)
		room := new(State_Room, context.temp_allocator)
		hash, outcome := state_hash(&disk.source, state, room)
		testing.expectf(t, outcome == .Good && hash == finished.hash, "size %d: the hash of the state on the disk differs from the hash of the commit", size)
	}
}

// The hash of an object with holes, as its definition says, computed on
// the whole tree of chunks with no block tree: a whole part with no written
// block has the value zero.
@(private = "file")
Reference :: struct {
	size:    u64,
	written: map[u64]^Block,
}

// reference_of gives the reference of the bytes of a whole object.
@(private = "file")
reference_of :: proc(bytes: []u8) -> (reference: Reference) {
	reference.size = u64(len(bytes))
	for index in 0 ..< format.object_blocks(reference.size) {
		block := new(Block, context.temp_allocator)
		copy(block[:], bytes[index * BLOCK_SIZE:])
		reference.written[index] = block
	}
	return reference
}

@(private = "file")
reference_bytes :: proc(reference: ^Reference, index: u64) -> ^Block {
	block, found := reference.written[index]
	if found {
		return block
	}
	return new(Block, context.temp_allocator)
}

@(private = "file")
reference_part :: proc(reference: ^Reference, first: u64, end: u64) -> Value {
	last := (reference.size - 1) / BLOCK_SIZE
	if first >= last * CHUNKS_IN_BLOCK {
		block := reference_bytes(reference, last)
		start := (first - last * CHUNKS_IN_BLOCK) * CHUNK_SIZE
		stop := min((end - last * CHUNKS_IN_BLOCK) * CHUNK_SIZE, reference.size - last * BLOCK_SIZE)
		return blake3.subtree_chaining_value(block[start:stop], first)
	}
	if end <= last * CHUNKS_IN_BLOCK {
		any := false
		for index in reference.written {
			if index >= first / CHUNKS_IN_BLOCK && index < end / CHUNKS_IN_BLOCK && !is_zero(reference.written[index][:]) {
				any = true
			}
		}
		if !any {
			return {}
		}
		if end - first == CHUNKS_IN_BLOCK {
			return block_value(reference_bytes(reference, first / CHUNKS_IN_BLOCK), first / CHUNKS_IN_BLOCK)
		}
		half := (end - first) / 2
		return pair_value(reference_part(reference, first, first + half), reference_part(reference, first + half, end))
	}
	left := left_chunks(end - first)
	return blake3.parent_chaining_value(reference_part(reference, first, first + left), reference_part(reference, first + left, end))
}

@(private = "file")
reference_hash :: proc(reference: ^Reference) -> blake3.Hash {
	if reference.size <= BLOCK_SIZE {
		return blake3.hash(reference_bytes(reference, 0)[:reference.size])
	}
	chunks := (reference.size + CHUNK_SIZE - 1) / CHUNK_SIZE
	left := left_chunks(chunks)
	return blake3.root_of_children(reference_part(reference, 0, left), reference_part(reference, left, chunks))
}

// A sparse object of 8 GiB made by three blocks: it holds a few blocks,
// reads its bytes back and zero bytes in its holes, and its hash is the
// hash of its definition.
@(test)
sparse_object :: proc(t: ^testing.T) {
	disk := disk_make()
	defer disk_free(disk)
	SIZE :: u64(8) << 30
	last := SIZE / BLOCK_SIZE - 1
	places := [3]u64{0, last / 2, last}
	changes: [3]Change
	reference := Reference{size = SIZE}
	defer delete(reference.written)
	for &change, number in changes {
		block := new(Block, context.temp_allocator)
		for &byte, index in block {
			byte = u8(number + 1 + index % 7)
		}
		change = {index = places[number], bytes = block}
		reference.written[places[number]] = block
	}
	state, finished, measure, ok := commit(disk, {}, 0, SIZE, changes[:])
	testing.expect(t, ok, "the commit failed")
	testing.expect_value(t, format.object_levels(SIZE), 4)
	// One root, and for each block its nodes of levels 3, 2 and 1 (the
	// first and the middle share nothing below the root), and the block.
	testing.expect_value(t, finished.blocks, u64(1 + 3 * 3 + 3))
	testing.expect_value(t, live_blocks(disk), finished.blocks)
	testing.expect_value(t, measure.changed, u64(3))
	testing.expect(t, finished.hash == reference_hash(&reference), "the hash of the sparse object is not the hash of its definition")
	block := new(Block, context.temp_allocator)
	node := new(Node, context.temp_allocator)
	for place, number in places {
		testing.expect(t, block_read(&disk.source, state, place, block, node) == .Good && block^ == changes[number].bytes^, "a written block reads back")
	}
	testing.expect(t, block_read(&disk.source, state, 12345, block, node) == .Good && is_zero(block[:]), "a hole reads as zero bytes")
	// A read across the edge of a written block and a hole.
	bytes: [8]u8
	count, outcome := range_read(&disk.source, state, BLOCK_SIZE - 4, bytes[:], block, node)
	testing.expect(t, outcome == .Good && count == 8, "a read across a block edge")
	testing.expect(t, slice.equal(bytes[:4], changes[0].bytes[BLOCK_SIZE - 4:]) && is_zero(bytes[4:]), "the end of the first block, then zero bytes")
	// A read past the end gives no byte.
	count, outcome = range_read(&disk.source, state, SIZE, bytes[:], block, node)
	testing.expect(t, outcome == .Good && count == 0, "a read at the end gives no byte")
	room := new(State_Room, context.temp_allocator)
	hash, hash_outcome := state_hash(&disk.source, state, room)
	testing.expect(t, hash_outcome == .Good && hash == finished.hash, "the hash of the state on the disk")
	// The blocks in order, by the walk and by next_block.
	nodes := new([LEVEL_LIMIT]Node, context.temp_allocator)
	at: u64
	for number in 0 ..< 3 {
		index, _, found, next_outcome := next_block(&disk.source, state, at, nodes)
		testing.expect(t, next_outcome == .Good && found && index == places[number], "next_block finds the written blocks in order")
		at = index + 1
	}
	_, _, found, _ := next_block(&disk.source, state, at, nodes)
	testing.expect(t, !found, "no block after the last")
}

// A change across the edge of two blocks, then across the edge of a level:
// copy on write keeps the state before whole.
@(test)
edges_and_versions :: proc(t: ^testing.T) {
	disk := disk_make()
	defer disk_free(disk)
	first_bytes := pattern(3 * BLOCK_SIZE)
	first, _, _, ok := commit(disk, {}, 0, u64(len(first_bytes)), changes_of(first_bytes))
	testing.expect(t, ok)
	// 10 bytes across the edge of the blocks 0 and 1.
	second_bytes := slice.clone(first_bytes, context.temp_allocator)
	for index in BLOCK_SIZE - 5 ..< BLOCK_SIZE + 5 {
		second_bytes[index] = 0xEE
	}
	changes := [2]Change{{index = 0, bytes = (^Block)(raw_data(second_bytes[0:]))}, {index = 1, bytes = (^Block)(raw_data(second_bytes[BLOCK_SIZE:]))}}
	second, finished, measure, second_ok := commit(disk, first, first.size, first.size, changes[:])
	testing.expect(t, second_ok)
	testing.expect_value(t, measure.changed, u64(2))
	testing.expect_value(t, measure.written, u64(3)) // Two blocks and the root.
	testing.expect(t, finished.hash == blake3.hash(second_bytes), "the hash after a change across a block edge")
	read, _ := read_whole(disk, second)
	testing.expect(t, slice.equal(read, second_bytes), "the new state reads its bytes")
	old, _ := read_whole(disk, first)
	testing.expect(t, slice.equal(old, first_bytes), "the state before reads its old bytes")
	// The two states share the block 2: one name more.
	testing.expect_value(t, live_blocks(disk), u64(4 + 3))

	// Across the edge of a level: the block 64 makes the root a node of
	// level 2, whose first child is the root before.
	third_size := 65 * BLOCK_SIZE
	third_bytes := make([]u8, third_size, context.temp_allocator)
	copy(third_bytes, second_bytes)
	for index in 64 * BLOCK_SIZE ..< third_size {
		third_bytes[index] = u8(index * 7)
	}
	last := [1]Change{{index = 64, bytes = (^Block)(raw_data(third_bytes[64 * BLOCK_SIZE:]))}}
	third, third_finished, _, third_ok := commit(disk, second, second.size, u64(third_size), last[:])
	testing.expect(t, third_ok)
	testing.expect_value(t, format.object_levels(third.size), 2)
	// The blocks 3 to 63 are zero bytes: holes, with the value zero.
	third_reference := reference_of(third_bytes)
	defer delete(third_reference.written)
	testing.expect(t, third_finished.hash == reference_hash(&third_reference), "the hash after a change across a level edge")
	read, _ = read_whole(disk, third)
	testing.expect(t, slice.equal(read, third_bytes), "the bytes after the level edge")
	read, _ = read_whole(disk, second)
	testing.expect(t, slice.equal(read, second_bytes), "the state before the level edge reads its bytes")

	// The release of the first two states frees what only they hold.
	release_state(disk, first)
	release_state(disk, second)
	testing.expect_value(t, live_blocks(disk), third_finished.blocks)
}

// A cut to 10 bytes lowers the levels to 0; an extension gives zero bytes
// after the old end; a block written with zero bytes is a hole.
@(test)
truncate_and_extend :: proc(t: ^testing.T) {
	disk := disk_make()
	defer disk_free(disk)
	size := 70 * BLOCK_SIZE + 9
	bytes := pattern(size)
	before, _, _, ok := commit(disk, {}, 0, u64(size), changes_of(bytes))
	testing.expect(t, ok)
	testing.expect_value(t, format.object_levels(before.size), 2)
	// The cut: the block that holds the new end has zero bytes after it.
	tail := new(Block, context.temp_allocator)
	copy(tail[:10], bytes[:10])
	cut_change := [1]Change{{index = 0, bytes = tail}}
	cut, cut_finished, _, cut_ok := commit(disk, before, 10, 10, cut_change[:])
	testing.expect(t, cut_ok)
	testing.expect_value(t, format.object_levels(cut.size), 0)
	testing.expect_value(t, cut_finished.blocks, u64(1))
	testing.expect(t, cut_finished.hash == blake3.hash(bytes[:10]), "the hash after the cut")
	release_state(disk, before)
	testing.expect_value(t, live_blocks(disk), u64(1))

	// The extension: no change of data, a larger size.
	extended_size := 70000
	extended, extended_finished, measure, extended_ok := commit(disk, cut, cut.size, u64(extended_size), nil)
	testing.expect(t, extended_ok)
	expected := make([]u8, extended_size, context.temp_allocator)
	copy(expected, bytes[:10])
	read, _ := read_whole(disk, extended)
	testing.expect(t, slice.equal(read, expected), "the bytes after the old end are zero bytes")
	reference := Reference{size = u64(extended_size)}
	defer delete(reference.written)
	reference.written[0] = tail
	testing.expect(t, extended_finished.hash == reference_hash(&reference), "the hash after the extension")
	testing.expect(t, measure.changed == 0 && measure.written == 1, "an extension writes the new root only")

	// A block of zero bytes is a hole: the object holds its root only.
	zero := new(Block, context.temp_allocator)
	zero_change := [1]Change{{index = 0, bytes = zero}}
	emptied, emptied_finished, _, emptied_ok := commit(disk, extended, extended.size, extended.size, zero_change[:])
	testing.expect(t, emptied_ok)
	testing.expect(t, emptied.root.block == 0 && emptied_finished.blocks == 0, "an object of zero bytes holds no block")
	read, _ = read_whole(disk, emptied)
	testing.expect(t, is_zero(read), "it reads as zero bytes")
}

// A whole write of the same bytes keeps the blocks of the state before.
@(test)
same_bytes_kept :: proc(t: ^testing.T) {
	disk := disk_make()
	defer disk_free(disk)
	bytes := pattern(5 * BLOCK_SIZE)
	first, _, _, _ := commit(disk, {}, 0, u64(len(bytes)), changes_of(bytes))
	changed := slice.clone(bytes, context.temp_allocator)
	changed[3 * BLOCK_SIZE] ~= 1
	_, finished, measure, ok := commit(disk, first, first.size, first.size, changes_of(changed))
	testing.expect(t, ok)
	testing.expect_value(t, measure.written, u64(2)) // The changed block and the root.
	testing.expect_value(t, measure.hashed_blocks, u64(5 + 1)) // The values of the 5 blocks, and the last block for the hash.
	testing.expect(t, finished.hash == blake3.hash(changed))
}
