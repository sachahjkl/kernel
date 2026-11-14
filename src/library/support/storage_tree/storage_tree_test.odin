#+build !freestanding
package storage_tree

import "base:runtime"
import format "modus:contract/store"
import "core:fmt"
import "core:math/rand"
import "core:strconv"
import "core:slice"
import "core:testing"

// A disk in memory: a block is written one time, and never written again,
// as copy on write needs.
Test_Disk :: struct {
	using source: Source,
	writer:       Writer,
	blocks:       [dynamic]Block,
	reads:        int,
}

test_read :: proc "contextless" (source: ^Source, pointer: Pointer, into: ^Block) -> Read {
	disk := (^Test_Disk)(source)
	if pointer.block < 2 || int(pointer.block) >= len(disk.blocks) {
		return .Wrong
	}
	into^ = disk.blocks[pointer.block]
	disk.reads += 1
	return format.check(into[:]) == pointer.check ? .Good : .Wrong
}

test_write :: proc "contextless" (writer: ^Writer, bytes: ^Block) -> Pointer {
	disk := (^Test_Disk)(writer.data)
	context = runtime.default_context()
	number := len(disk.blocks)
	append(&disk.blocks, bytes^)
	return {block = u64(number), check = format.check(bytes[:])}
}

disk_make :: proc() -> ^Test_Disk {
	disk := new(Test_Disk)
	disk.source = {read = test_read}
	disk.writer = {write = test_write, data = disk}
	disk.blocks = make([dynamic]Block)
	append(&disk.blocks, Block{}, Block{}) // The two places of the root.
	return disk
}

disk_free :: proc(disk: ^Test_Disk) {
	delete(disk.blocks)
	free(disk)
}

// The name of the number n: its decimal digits, 8 of them, so that the
// order of the names is the order of the numbers.
name_of_number :: proc(number: u64) -> format.Entry_Name {
	return format.entry_name(fmt.tprintf("k%08d", number))
}

number_of_name :: proc(key: []u8) -> u64 {
	name := (^format.Entry_Name)(raw_data(key))
	number, _ := strconv.parse_u64(format.name_of(name)[1:])
	return number
}

entry_of_number :: proc(number: u64) -> (value: format.Entry) {
	value.kind = .Object
	value.size = number * 3
	value.generation = number
	return value
}

// The records of a whole tree, in the order of the walk.
Walked :: struct {
	keys:       [dynamic]u64,
	bad_values: int,
}

walk_record_entry :: proc "contextless" (walk: ^Walk, key: []u8, value: []u8) {
	context = runtime.default_context()
	walked := (^Walked)(walk.data)
	number := number_of_name(key)
	entry := (^format.Entry)(raw_data(value))
	if entry.size != number * 3 {
		walked.bad_values += 1
	}
	append(&walked.keys, number)
}

walk_all :: proc(disk: ^Test_Disk, root: Pointer) -> (keys: [dynamic]u64, nodes: u64, failure: Failure, bad_values: int) {
	walked := Walked{keys = make([dynamic]u64)}
	walk := new(Walk)
	defer free(walk)
	walk.source = &disk.source
	walk.shape = TREE_SHAPE
	walk.visit_record = walk_record_entry
	walk.data = &walked
	failure = walk_tree(walk, root)
	return walked.keys, walk.nodes, failure, walked.bad_values
}

@(test)
the_sizes_of_the_format :: proc(t: ^testing.T) {
	testing.expect_value(t, format.LEAF_CAPACITY, 24)
	testing.expect_value(t, format.BRANCH_CAPACITY, 50)
	testing.expect_value(t, record_size(TREE_SHAPE, 0), 168)
	testing.expect_value(t, record_size(TREE_SHAPE, 1), 80)
	testing.expect(t, HEADER_SIZE + TREE_SHAPE.leaf_capacity * record_size(TREE_SHAPE, 0) <= BLOCK_SIZE)
	testing.expect(t, HEADER_SIZE + TREE_SHAPE.branch_capacity * record_size(TREE_SHAPE, 1) <= BLOCK_SIZE)
	testing.expect_value(t, size_of(format.Store_Block), BLOCK_SIZE)
	testing.expect_value(t, size_of(format.Root), BLOCK_SIZE)
	// The removal queue is in the order of the removes.
	first := format.removal_name(255)
	second := format.removal_name(256)
	testing.expect(t, compare(first[:], second[:]) < 0)
}

// Inserts in a random order split leaves and branches; the walk gives each
// key once, in order, and each value; a search finds each one.
@(test)
insert_split_and_order :: proc(t: ^testing.T) {
	disk := disk_make()
	defer disk_free(disk)
	pool := new(Pool)
	defer free(pool)
	pool_reset(pool)
	work := Work{pool = pool, source = &disk.source, shape = TREE_SHAPE}
	COUNT :: 20000
	order := make([]u64, COUNT)
	defer delete(order)
	for &identifier, index in order {
		identifier = u64(index) + 16
	}
	generator := rand.create(20261112)
	rand.shuffle(order, rand.default_random_generator(&generator))
	// Commits of 100 inserts: the pool holds the dirty nodes of one commit.
	for first := 0; first < COUNT; first += 100 {
		for identifier in order[first:][:100] {
			key := name_of_number(identifier)
			value := entry_of_number(identifier)
			existed := put(&work, key[:], ([^]u8)(&value)[:size_of(value)], false)
			testing.expect(t, !existed)
		}
		testing.expect_value(t, pool.failure, Failure.None)
		finish(&work, &disk.writer)
		pool_reset(pool)
	}
	keys, nodes, failure, bad := walk_all(disk, work.root)
	defer delete(keys)
	testing.expect_value(t, failure, Failure.None)
	testing.expect_value(t, len(keys), COUNT)
	testing.expect_value(t, bad, 0)
	testing.expect(t, slice.is_sorted(keys[:]))
	// Each node at least a third full: at most COUNT / 8 leaves, and the
	// branches above them.
	testing.expect(t, nodes <= COUNT / 8 + 100)
	for identifier in ([]u64{16, 17, 9000, COUNT + 15}) {
		key := name_of_number(identifier)
		value: format.Entry
		testing.expect(t, get(&work, key[:], ([^]u8)(&value)[:size_of(value)]))
		testing.expect_value(t, value.size, identifier * 3)
	}
	missing := name_of_number(COUNT + 16)
	value: format.Entry
	testing.expect(t, !get(&work, missing[:], ([^]u8)(&value)[:size_of(value)]))
	// A key that exists is not put again without replace.
	key := name_of_number(100)
	other := entry_of_number(7)
	testing.expect(t, put(&work, key[:], ([^]u8)(&other)[:size_of(other)], false))
	testing.expect(t, !is_reference(work.root))
}

// Removes in a random order merge and rebalance nodes; the keys left are
// in order, and a tree of no key has no root.
@(test)
remove_merge_and_empty :: proc(t: ^testing.T) {
	disk := disk_make()
	defer disk_free(disk)
	pool := new(Pool)
	defer free(pool)
	pool_reset(pool)
	work := Work{pool = pool, source = &disk.source, shape = TREE_SHAPE}
	COUNT :: 6000
	for identifier in 16 ..< u64(16 + COUNT) {
		key := name_of_number(identifier)
		value := entry_of_number(identifier)
		put(&work, key[:], ([^]u8)(&value)[:size_of(value)], false)
		if identifier % 100 == 0 {
			finish(&work, &disk.writer)
			pool_reset(pool)
		}
	}
	finish(&work, &disk.writer)
	pool_reset(pool)
	_, full_nodes, _, _ := walk_all(disk, work.root)
	order := make([]u64, COUNT)
	defer delete(order)
	for &identifier, index in order {
		identifier = u64(index) + 16
	}
	generator := rand.create(7)
	rand.shuffle(order, rand.default_random_generator(&generator))
	// Remove nine keys of ten.
	removed := COUNT - COUNT / 10
	for first := 0; first < removed; first += 50 {
		for identifier in order[first:][:min(50, removed - first)] {
			key := name_of_number(identifier)
			testing.expect(t, remove(&work, key[:]))
		}
		testing.expect_value(t, pool.failure, Failure.None)
		finish(&work, &disk.writer)
		pool_reset(pool)
	}
	keys, nodes, failure, bad := walk_all(disk, work.root)
	testing.expect_value(t, failure, Failure.None)
	testing.expect_value(t, len(keys), COUNT / 10)
	testing.expect_value(t, bad, 0)
	testing.expect(t, slice.is_sorted(keys[:]))
	// The merges keep the nodes at least a third full.
	testing.expect(t, nodes < full_nodes / 3)
	expected := slice.clone(order[removed:])
	defer delete(expected)
	slice.sort(expected)
	testing.expect(t, slice.equal(keys[:], expected))
	delete(keys)
	// A key that is not there.
	key := name_of_number(order[0])
	testing.expect(t, !remove(&work, key[:]))
	for identifier in order[removed:] {
		key = name_of_number(identifier)
		testing.expect(t, remove(&work, key[:]))
	}
	finish(&work, &disk.writer)
	testing.expect(t, is_empty(work.root))
}

// Copy on write: a commit never writes a node of the tree before it, so the
// root before it still reads the keys before it; the nodes that the commit
// released are the ones that the new tree no longer names.
@(test)
copy_on_write_keeps_the_tree_before :: proc(t: ^testing.T) {
	disk := disk_make()
	defer disk_free(disk)
	pool := new(Pool)
	defer free(pool)
	pool_reset(pool)
	work := Work{pool = pool, source = &disk.source, shape = TREE_SHAPE}
	for identifier in 16 ..< u64(2016) {
		key := name_of_number(identifier)
		value := entry_of_number(identifier)
		put(&work, key[:], ([^]u8)(&value)[:size_of(value)], false)
		if identifier % 64 == 0 {
			finish(&work, &disk.writer)
			pool_reset(pool)
		}
	}
	before := finish(&work, &disk.writer)
	pool_reset(pool)
	blocks_before := len(disk.blocks)
	key := name_of_number(1000)
	remove(&work, key[:])
	key = name_of_number(5000)
	value := entry_of_number(5000)
	put(&work, key[:], ([^]u8)(&value)[:size_of(value)], false)
	after := finish(&work, &disk.writer)
	released := pool.released[:pool.released_count]
	// Only new blocks were written.
	testing.expect(t, pool.written == len(disk.blocks) - blocks_before)
	old_keys, _, old_failure, _ := walk_all(disk, before)
	defer delete(old_keys)
	testing.expect_value(t, old_failure, Failure.None)
	testing.expect_value(t, len(old_keys), 2000)
	new_keys, _, new_failure, _ := walk_all(disk, after)
	defer delete(new_keys)
	testing.expect_value(t, new_failure, Failure.None)
	testing.expect_value(t, len(new_keys), 2000)
	testing.expect(t, !slice.contains(new_keys[:], 1000) && slice.contains(new_keys[:], 5000))
	// Each released block was a node of the tree before, and is not a node
	// of the new tree.
	Named :: struct {
		blocks: [dynamic]u64,
	}
	named_new := Named{blocks = make([dynamic]u64)}
	defer delete(named_new.blocks)
	walk := new(Walk)
	defer free(walk)
	walk.source = &disk.source
	walk.shape = TREE_SHAPE
	walk.data = &named_new
	walk.visit_node = proc "contextless" (walk: ^Walk, pointer: Pointer) -> bool {
		context = runtime.default_context()
		append(&(^Named)(walk.data).blocks, pointer.block)
		return true
	}
	walk_tree(walk, after)
	testing.expect(t, len(released) > 0)
	for pointer in released {
		testing.expect(t, int(pointer.block) < blocks_before)
		testing.expect(t, !slice.contains(named_new.blocks[:], pointer.block))
	}
}

// The entries of a tree are in the order of the bytes of their names; a
// listing gives them in pages, each page after the last name of the page
// before, as the export list does.
@(test)
names_in_order_and_in_pages :: proc(t: ^testing.T) {
	disk := disk_make()
	defer disk_free(disk)
	pool := new(Pool)
	defer free(pool)
	pool_reset(pool)
	work := Work{pool = pool, source = &disk.source, shape = TREE_SHAPE}
	names := []string{"b", "ab", "a", "abc", "z", "B", "é"}
	for name, index in names {
		key := format.entry_name(name)
		value := format.Entry{kind = .Object, size = u64(index)}
		put(&work, key[:], ([^]u8)(&value)[:size_of(value)], false)
	}
	finish(&work, &disk.writer)
	pool_reset(pool)
	listed := make([dynamic]string, context.temp_allocator)
	cursor: format.Entry_Name
	after := false
	for {
		key_out: format.Entry_Name
		value_out: format.Entry
		if !first_from(&work, cursor[:], after, key_out[:], ([^]u8)(&value_out)[:size_of(value_out)]) {
			break
		}
		append(&listed, fmt.tprint(format.name_of(&key_out)))
		cursor = key_out
		after = true
	}
	expected := []string{"B", "a", "ab", "abc", "b", "z", "é"}
	testing.expect_value(t, len(listed), len(expected))
	for name, index in expected {
		testing.expect_value(t, listed[index], name)
	}
	// Pages over many leaves: each name once, in order.
	for number in 0 ..< u64(3000) {
		key := name_of_number(number)
		value := entry_of_number(number)
		put(&work, key[:], ([^]u8)(&value)[:size_of(value)], false)
		if number % 200 == 0 {
			finish(&work, &disk.writer)
			pool_reset(pool)
		}
	}
	finish(&work, &disk.writer)
	pool_reset(pool)
	start := name_of_number(0)
	cursor = start
	after = false
	count: u64
	for {
		key_out: format.Entry_Name
		value_out: format.Entry
		if !first_from(&work, cursor[:], after, key_out[:], ([^]u8)(&value_out)[:size_of(value_out)]) {
			break
		}
		if key_out[0] != 'k' {
			break
		}
		testing.expect_value(t, number_of_name(key_out[:]), count)
		count += 1
		cursor = key_out
		after = true
	}
	testing.expect_value(t, count, 3000)
}

@(test)
names_that_are_refused :: proc(t: ^testing.T) {
	Case :: struct {
		name:    string,
		refusal: format.Name_Refusal,
		offset:  int,
	}
	long: [format.ENTRY_NAME_CAPACITY + 1]u8
	for &byte in long {
		byte = 'x'
	}
	cases := []Case {
		{"", .Empty, 0},
		{".", .Bad_Byte, 0},
		{"..", .Bad_Byte, 0},
		{"/etc", .Bad_Byte, 0},
		{"a/../b", .Bad_Byte, 1},
		{"a\x00b", .Bad_Byte, 1},
		{string(long[:]), .Too_Long, 0},
		{string(long[:format.ENTRY_NAME_CAPACITY]), .None, 0},
		{"...", .None, 0},
		{".hidden", .None, 0},
	}
	for item in cases {
		refusal, offset, _ := format.name_refusal(item.name)
		testing.expectf(t, refusal == item.refusal && offset == item.offset, "%q: %v at %d", item.name, refusal, offset)
	}
}

// A block of another kind, or a node with keys out of order, is damage: the walk
// and the search stop on it.
@(test)
a_damaged_node_is_found :: proc(t: ^testing.T) {
	disk := disk_make()
	defer disk_free(disk)
	pool := new(Pool)
	defer free(pool)
	pool_reset(pool)
	work := Work{pool = pool, source = &disk.source, shape = TREE_SHAPE}
	for identifier in 16 ..< u64(30) {
		key := name_of_number(identifier)
		value := entry_of_number(identifier)
		put(&work, key[:], ([^]u8)(&value)[:size_of(value)], false)
	}
	root := finish(&work, &disk.writer)
	// The same bytes with another magic: a block of another kind.
	wrong := disk.blocks[root.block]
	header(&wrong).magic = 0
	pointer := test_write(&disk.writer, &wrong)
	_, _, failure, _ := walk_all(disk, pointer)
	testing.expect_value(t, failure, Failure.Damaged)
	// Two keys out of order.
	swapped := disk.blocks[root.block]
	first := slice.clone(key_at(&swapped, TREE_SHAPE, 0))
	defer delete(first)
	copy(key_at(&swapped, TREE_SHAPE, 0), key_at(&swapped, TREE_SHAPE, 1))
	copy(key_at(&swapped, TREE_SHAPE, 1), first)
	pointer = test_write(&disk.writer, &swapped)
	pool_reset(pool)
	work.root = pointer
	key := name_of_number(20)
	value: format.Entry
	testing.expect(t, !get(&work, key[:], ([^]u8)(&value)[:size_of(value)]))
	testing.expect_value(t, pool.failure, Failure.Damaged)
	// A wrong check.
	pool_reset(pool)
	work.root = {block = root.block, check = root.check ~ 1}
	testing.expect(t, !get(&work, key[:], ([^]u8)(&value)[:size_of(value)]))
	testing.expect_value(t, pool.failure, Failure.Wrong)
}

// A branch whose record 0 has a stale name: the names first go in from
// 1000 up, so the root branch takes the name of its first leaf then; the
// names below 1000 that come after go into the child 0, which splits, and
// the new separator at the record 1 is smaller than the name of the record
// 0. That branch is valid: the search never reads the name of the record 0.
@(test)
a_stale_name_at_the_record_0_of_a_branch :: proc(t: ^testing.T) {
	disk := disk_make()
	defer disk_free(disk)
	pool := new(Pool)
	defer free(pool)
	pool_reset(pool)
	work := Work{pool = pool, source = &disk.source, shape = TREE_SHAPE}
	for number in u64(1000) ..< 1100 {
		key := name_of_number(number)
		value := entry_of_number(number)
		put(&work, key[:], ([^]u8)(&value)[:size_of(value)], false)
	}
	finish(&work, &disk.writer)
	pool_reset(pool)
	for number in u64(0) ..< 100 {
		key := name_of_number(number)
		value := entry_of_number(number)
		put(&work, key[:], ([^]u8)(&value)[:size_of(value)], false)
	}
	testing.expect_value(t, pool.failure, Failure.None)
	finish(&work, &disk.writer)
	pool_reset(pool)
	root_node := disk.blocks[work.root.block]
	testing.expect(t, header(&root_node).level > 0)
	testing.expect(t, compare(key_at(&root_node, TREE_SHAPE, 0), key_at(&root_node, TREE_SHAPE, 1)) > 0)
	testing.expect(t, node_valid(&root_node, TREE_SHAPE))
	keys, _, failure, bad := walk_all(disk, work.root)
	defer delete(keys)
	testing.expect_value(t, failure, Failure.None)
	testing.expect_value(t, len(keys), 200)
	testing.expect_value(t, bad, 0)
	for number in ([]u64{0, 99, 1000, 1099}) {
		key := name_of_number(number)
		value: format.Entry
		testing.expect(t, get(&work, key[:], ([^]u8)(&value)[:size_of(value)]))
	}
}
