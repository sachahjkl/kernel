// A test of the large objects of a store (docs/STORAGE.md, "Large objects"): an object of 8 GiB made by three range writes holds a few blocks; 1000 small writes at scrambled offsets and one commit hash and write what they touched, not the whole object; a version keeps its bytes; a cut and an extension; the refusals.
//
// The first run (an empty store) checks each case, then makes a loop of range commits (the scenario of a loss of power stops the machine in it). The second run, on the same disk after a new start of the machine, reads back what the first run left. Each case ends with a line "...: as it must", or a line "WRONG". The times and the counts of a commit are measures, printed: a case checks a bound that comes from the blocks changed, never a speed.
//
// **What it is for.** It proves that the cost of a change of a large object follows the bytes changed, not the
// size of the object: a program can keep an object of gigabytes and change a few blocks of it in one commit.
//
// **Start**: the machine test of the large objects starts it from the console with `start("ranges")`; it is not on
// the bar of the desktop. A reader can start it the same way; the second start, after a new start of the machine,
// runs the second run.
//
// **Grants**, as the root service gives them:
//
// - **Store**: its private store, with a limit of 12000 blocks: a commit of 1000 blocks spread over the object of
//   8 GiB holds about 2000 blocks with its version, and the loop of range commits about 4000.
//
// **What a reader sees**: no window. The log has one line for each case, "...: as it must" or "WRONG", the
// measures of the commits, and at the end "ranges: done, N wrong". The program stops with the code 0 when no case
// is wrong, else with the code 2.
//
// The exports that it calls: [write_range](storage.write_range), [set_size](storage.set_size) and
// [commit](storage.commit) of the storage service.
package ranges

import "contract:errors"
import "support:storage"
import "support:system"

GIB :: u64(1) << 30
BLOCK :: 4096
SPARSE_SIZE :: 8 * GIB
SPARSE_BLOCKS :: SPARSE_SIZE / BLOCK
MIDDLE :: 4 * GIB
LAST :: SPARSE_SIZE - BLOCK

// The 1000 small writes: write n goes to the block 1 + (n * STEP mod 1000)
// * 64, at the offset n * 37 mod 4000 in it, 16 bytes. STEP is a prime
// that does not divide 1000, so the order of the blocks is a fixed
// permutation with no random source. Each write is in its own object node
// of level 1.
WRITES :: 1000
STEP :: 677
WRITE_BYTES :: 16

// The object of the cut: 70 blocks, two levels of object nodes.
CUT_BLOCKS :: 70
CUT_SIZE :: 6000
EXTENDED_SIZE :: GIB

// The loop of range commits: 200 commits of 4 writes of 64 bytes in an
// object of 64 MiB.
LOOP_COMMITS :: 200
LOOP_WRITES :: 4
LOOP_SIZE :: u64(64) << 20

client: storage.Client
wrong_cases: int

outcome :: proc "contextless" (good: bool, what: string, parts: ..system.Part) {
	writer_bytes: [480]u8
	writer := system.Writer{buffer = writer_bytes[:]}
	for part in parts {
		system.write_part(&writer, part)
	}
	if good {
		system.log("ranges: ", what, system.written(&writer), ": as it must")
	} else {
		wrong_cases += 1
		system.log_in("ranges", .Error, "ranges: WRONG: ", what, system.written(&writer))
	}
}

refused_with :: proc "contextless" (status: storage.Status, error: ^errors.Error_Record, kind: errors.Kind, unit: errors.Unit) -> bool {
	return status == .Failed && errors.Kind(error.kind) == kind && errors.Unit(error.unit) == unit
}

// The bytes of the block `number` (1, 2 or 3) of the sparse object.
block_bytes :: proc "contextless" (number: int, into: ^[BLOCK]u8) {
	for &byte, index in into {
		byte = u8(index * 7 + number * 31 + 1)
	}
}

// The place and the bytes of the small write n.
small_write :: proc "contextless" (n: int, into: ^[WRITE_BYTES]u8) -> (offset: u64) {
	block := 1 + u64(n * STEP % WRITES) * 64
	for &byte, index in into {
		byte = u8(n + index * 3 + 1)
	}
	return block * BLOCK + u64(n * 37 % 4000)
}

// pattern_byte gives the byte at an offset of the object of the cut and of
// the small object.
pattern_byte :: proc "contextless" (at: u64) -> u8 {
	return u8(at % 251)
}

same_bytes :: proc "contextless" (a, b: []u8) -> bool {
	if len(a) != len(b) {
		return false
	}
	for byte, index in a {
		if byte != b[index] {
			return false
		}
	}
	return true
}

all_zero :: proc "contextless" (bytes: []u8) -> bool {
	for byte in bytes {
		if byte != 0 {
			return false
		}
	}
	return true
}

// The bytes of the three blocks of the sparse object: each one reads back.
sparse_blocks_read :: proc "contextless" () -> bool {
	expected, read: [BLOCK]u8
	places := [3]u64{0, MIDDLE, LAST}
	for place, number in places {
		block_bytes(number + 1, &expected)
		bytes, status := storage.read_range(&client, storage.ROOT, "sparse", place, read[:])
		if status != .Ok || !same_bytes(bytes, expected[:]) {
			return false
		}
	}
	return true
}

// The 1000 small writes: each one reads back.
small_writes_read :: proc "contextless" () -> bool {
	for n in 0 ..< WRITES {
		expected, read: [WRITE_BYTES]u8
		offset := small_write(n, &expected)
		bytes, status := storage.read_range(&client, storage.ROOT, "sparse", offset, read[:])
		if status != .Ok || !same_bytes(bytes, expected[:]) {
			return false
		}
	}
	return true
}

measure_log :: proc "contextless" (what: string, measure: storage.Commit_Measure) {
	system.log("ranges: ", what, u64(measure.changed), " blocks changed of ", u64(measure.object_blocks), ", ", u64(measure.hashed_blocks), " blocks and ", u64(measure.hashed_nodes), " object nodes hashed, ", u64(measure.written), " blocks written, in ", u64(measure.milliseconds), " ms")
}

first_run :: proc "contextless" () {
	// The sparse object: its first block, its middle, its last block.
	start := system.time()
	places := [3]u64{0, MIDDLE, LAST}
	block: [BLOCK]u8
	statuses := true
	for place, number in places {
		block_bytes(number + 1, &block)
		_, status := storage.write_range(&client, storage.ROOT, "sparse", place, block[:])
		statuses &&= status == .Ok
	}
	size, size_status := storage.size(&client, storage.ROOT, "sparse")
	outcome(statuses && size_status == .Ok && u64(size) == SPARSE_SIZE, "three range writes are pending, and the size of the object is ", u64(size), " bytes")
	measure, status := storage.commit(&client, storage.ROOT, "sparse")
	measure_log("the commit of the sparse object: ", measure)
	// The root, and for each block its object nodes of levels 3, 2 and 1
	// (the three blocks share no node under the root), and the block.
	outcome(status == .Ok && measure.object_blocks == i64(SPARSE_BLOCKS) && measure.held_blocks == 1 + 3 * 3 + 3, "a sparse object of 8 GiB from 3 writes and one commit holds ", u64(measure.held_blocks), " blocks")

	// Read back; a hole; a read across the edge of a block and a hole.
	hole: [100]u8
	hole_bytes, hole_status := storage.read_range(&client, storage.ROOT, "sparse", GIB, hole[:])
	edge: [12]u8
	edge_bytes, edge_status := storage.read_range(&client, storage.ROOT, "sparse", BLOCK - 6, edge[:])
	block_bytes(1, &block)
	edge_good := edge_status == .Ok && len(edge_bytes) == 12 && same_bytes(edge_bytes[:6], block[BLOCK - 6:]) && all_zero(edge_bytes[6:])
	outcome(sparse_blocks_read() && hole_status == .Ok && len(hole_bytes) == len(hole) && all_zero(hole_bytes) && edge_good, "its three blocks read back, a hole reads as zero bytes, and a read across a block edge gives the end of a block and zero bytes")

	// 1000 small writes at scrambled offsets, then one commit.
	writes_start := system.time()
	writes_good := true
	for n in 0 ..< WRITES {
		bytes: [WRITE_BYTES]u8
		offset := small_write(n, &bytes)
		_, write_status := storage.write_range(&client, storage.ROOT, "sparse", offset, bytes[:])
		writes_good &&= write_status == .Ok
	}
	system.log("ranges: 1000 range writes at scrambled offsets are pending, in ", system.time() - writes_start, " ms")
	measure, status = storage.commit(&client, storage.ROOT, "sparse")
	measure_log("1000 writes at scrambled offsets, then one commit: ", measure)
	// The bound of the cost: each changed block, the last block of the hash,
	// and at most one object node of each level for each changed block.
	levels: i64 = 4
	bounded := measure.changed == WRITES && measure.hashed_blocks <= measure.changed + 1 && measure.hashed_nodes <= measure.changed * levels && measure.object_written <= measure.hashed_blocks + measure.hashed_nodes
	outcome(writes_good && status == .Ok && bounded, "the commit of 1000 scrambled writes hashed ", u64(measure.hashed_blocks), " blocks and ", u64(measure.hashed_nodes), " object nodes, bounded by the blocks changed, not by the ", u64(measure.object_blocks), " blocks of the object")
	outcome(small_writes_read() && sparse_blocks_read(), "the 1000 writes read back, each one byte for byte, and the three blocks before them")

	// The versions of the sparse object: the state before the 1000 writes
	// shares its blocks with the new state but the path of the first block.
	rows: [4]storage.Version
	versions, total, versions_status := storage.versions(&client, storage.ROOT, "sparse", rows[:])
	own: i64 = len(versions) == 2 ? versions[0].own_blocks : -1
	outcome(versions_status == .Ok && total == 2 && own == 4, "the version before the 1000 writes holds ", own, " blocks of its own: the root and the path of the first block; its other blocks are shared with the new state")

	versions_case()
	cut_case()
	refusals()
	conflict_case()
	system.log("ranges: the cases took ", system.time() - start, " ms")
	loop()
}

// versions_case: a range write over a small object; its old version reads
// its old bytes, and compare gives the one range written.
SMALL_SIZE :: 12000

versions_case :: proc "contextless" () {
	bytes: [SMALL_SIZE]u8
	for &byte, index in bytes {
		byte = pattern_byte(u64(index))
	}
	first, status := storage.write(&client, storage.ROOT, "small", bytes[:])
	changed: [100]u8
	for &byte in changed {
		byte = 0xAA
	}
	_, range_status := storage.write_range(&client, storage.ROOT, "small", 5000, changed[:])
	measure, commit_status := storage.commit(&client, storage.ROOT, "small")
	old: [SMALL_SIZE]u8
	old_bytes, old_status := storage.version(&client, storage.ROOT, "small", first, old[:])
	current: [SMALL_SIZE]u8
	current_bytes, _, _ := storage.read(&client, storage.ROOT, "small", current[:])
	expected := bytes
	copy(expected[5000:], changed[:])
	ranges: [4]storage.Byte_Range
	found, compare_status := storage.compare(&client, storage.ROOT, "small", first, measure.generation, ranges[:])
	good := status == .Ok && range_status == .Ok && commit_status == .Ok && old_status == .Ok && same_bytes(old_bytes, bytes[:]) && same_bytes(current_bytes, expected[:])
	good &&= compare_status == .Ok && len(found) == 1 && found[0].first == 5000 && found[0].count == 100
	outcome(good, "an old version reads its old bytes after a range write, and compare gives the one range written")
}

// cut_case: an object of 70 blocks is cut to 6000 bytes, then extended to
// 1 GiB.
cut_case :: proc "contextless" () {
	chunk: [8 * BLOCK]u8 // Half of the call region: the region holds the other arguments too.
	good := true
	for at: u64 = 0; at < CUT_BLOCKS * BLOCK; at += u64(len(chunk)) {
		part := min(u64(len(chunk)), CUT_BLOCKS * BLOCK - at)
		for index in 0 ..< part {
			chunk[index] = pattern_byte(at + index)
		}
		_, status := storage.write_range(&client, storage.ROOT, "cut", at, chunk[:part])
		good &&= status == .Ok
	}
	_, status := storage.commit(&client, storage.ROOT, "cut")
	good &&= status == .Ok
	cut_status := storage.set_size(&client, storage.ROOT, "cut", CUT_SIZE)
	cut_measure, cut_commit := storage.commit(&client, storage.ROOT, "cut")
	extend_status := storage.set_size(&client, storage.ROOT, "cut", EXTENDED_SIZE)
	extended, extend_commit := storage.commit(&client, storage.ROOT, "cut")
	good &&= cut_status == .Ok && cut_commit == .Ok && extend_status == .Ok && extend_commit == .Ok
	read: [CUT_SIZE + 100]u8
	bytes, read_status := storage.read_range(&client, storage.ROOT, "cut", 0, read[:])
	kept := read_status == .Ok && len(bytes) == len(read)
	for index in 0 ..< CUT_SIZE {
		kept &&= len(bytes) > index && bytes[index] == pattern_byte(u64(index))
	}
	if len(bytes) == len(read) {
		kept &&= all_zero(bytes[CUT_SIZE:])
	}
	// After the cut: a root of level 1 and two blocks. After the extension:
	// two new roots above it.
	outcome(good && kept && cut_measure.held_blocks == 3 && extended.held_blocks == 5, "a cut of an object of 70 blocks to 6000 bytes holds ", u64(cut_measure.held_blocks), " blocks; an extension to 1 GiB holds ", u64(extended.held_blocks), " blocks, and reads zero bytes past the cut")
	// The end, and past the end.
	end: [8]u8
	end_bytes, end_status := storage.read_range(&client, storage.ROOT, "cut", EXTENDED_SIZE, end[:])
	error: errors.Error_Record
	_, past_status := storage.read_range(&client, storage.ROOT, "cut", EXTENDED_SIZE + 1, end[:], &error)
	outcome(end_status == .Ok && len(end_bytes) == 0 && refused_with(past_status, &error, .Out_Of_Range, .Bytes), "a read at the end gives no byte, and a read past the end is refused")
}

// refusals: another store, and a place of no connection.
refusals :: proc "contextless" () {
	error: errors.Error_Record
	_, store_status := storage.open_store(&client, "notes", &error)
	store_refused := refused_with(store_status, &error, .No_Grant, .Acts_For_Principal)
	error = {}
	_, place_status := storage.write_range(&client, storage.Place(0x7_0000_0005), "sparse", 0, transmute([]u8)string("no"), &error)
	place_refused := refused_with(place_status, &error, .Absent, .Places)
	error = {}
	_, commit_status := storage.commit(&client, storage.ROOT, "nothing pending", &error)
	commit_refused := refused_with(commit_status, &error, .Absent, .Pending)
	outcome(store_refused && place_refused && commit_refused, "a place of another store, a place of no connection, and a commit with no pending change are refused")
}

// conflict_case: a write of the whole object comes between a range write
// and its commit: the commit is refused, and the pending change is dropped.
conflict_case :: proc "contextless" () {
	_, range_status := storage.write_range(&client, storage.ROOT, "small", 0, transmute([]u8)string("pending"))
	_, write_status := storage.write(&client, storage.ROOT, "small", transmute([]u8)string("whole"))
	error: errors.Error_Record
	_, commit_status := storage.commit(&client, storage.ROOT, "small", &error)
	read: [16]u8
	bytes, _, _ := storage.read(&client, storage.ROOT, "small", read[:])
	outcome(range_status == .Ok && write_status == .Ok && refused_with(commit_status, &error, .Absent, .Pending) && error.found == 1 && string(bytes) == "whole", "a commit after another change of the object is refused, and its pending changes are dropped")
}

// loop makes commits of range writes, one after the other: the scenario of
// a loss of power stops the machine in it.
loop :: proc "contextless" () {
	start := system.time()
	good := storage.set_size(&client, storage.ROOT, "loop", LOOP_SIZE) == .Ok
	for commit_number in 0 ..< LOOP_COMMITS {
		for write_number in 0 ..< LOOP_WRITES {
			n := commit_number * LOOP_WRITES + write_number
			bytes: [64]u8
			for &byte, index in bytes {
				byte = u8(n + index + 1)
			}
			offset := u64(n * 7919 % int(LOOP_SIZE / BLOCK)) * BLOCK + u64(n * 61 % 4000)
			_, status := storage.write_range(&client, storage.ROOT, "loop", offset, bytes[:])
			good &&= status == .Ok
		}
		_, status := storage.commit(&client, storage.ROOT, "loop")
		good &&= status == .Ok
		if (commit_number + 1) % 50 == 0 {
			system.log("ranges: loop, ", u64(commit_number + 1), " commits of 4 range writes, in ", system.time() - start, " ms")
		}
	}
	outcome(good, "the loop made ", u64(LOOP_COMMITS), " commits of range writes")
}

// second_run checks what the first run left, after a new start of the
// machine: the open of the disk walked each block tree again.
second_run :: proc "contextless" () {
	size, _ := storage.size(&client, storage.ROOT, "sparse")
	outcome(u64(size) == SPARSE_SIZE && sparse_blocks_read() && small_writes_read(), "after the remount: the sparse object of ", u64(size), " bytes reads its 3 blocks and its 1000 writes, byte for byte")
	read: [16]u8
	small, _, _ := storage.read(&client, storage.ROOT, "small", read[:])
	cut_size, _ := storage.size(&client, storage.ROOT, "cut")
	cut_read: [CUT_SIZE]u8
	cut_bytes, _ := storage.read_range(&client, storage.ROOT, "cut", 0, cut_read[:])
	kept := len(cut_bytes) == CUT_SIZE
	for index in 0 ..< len(cut_bytes) {
		kept &&= cut_bytes[index] == pattern_byte(u64(index))
	}
	loop_size, _ := storage.size(&client, storage.ROOT, "loop")
	outcome(string(small) == "whole" && u64(cut_size) == EXTENDED_SIZE && kept && u64(loop_size) == LOOP_SIZE, "after the remount: the small object, the object of the cut and the object of the loop")
}

// The entry of ranges: the first run on an empty store, or the second run on the store that the first run left;
// then it stops.
//
// It opens its private store and reads its usage; with no store or no usage it writes "ranges: WRONG: ..." and
// stops with the code 1. A store with no object gives the first run: each case, then the loop of range commits. A
// store with objects gives the second run: it reads back the small object, the object of the cut and the object
// of the loop. It writes "ranges: done, N wrong" and stops with the code 0, or 2 when a case is wrong.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	ok: bool
	if client, ok = storage.open(ctx); !ok {
		system.log_in("ranges", .Error, "ranges: WRONG: no store")
		system.stop(1)
	}
	counts, status := storage.usage(&client)
	if status != .Ok {
		system.log_in("ranges", .Error, "ranges: WRONG: no usage")
		system.stop(1)
	}
	if counts.objects == 0 {
		system.log("ranges: a new store: the first run")
		first_run()
	} else {
		system.log("ranges: a store with ", counts.objects, " objects: the run after the remount")
		second_run()
	}
	system.log("ranges: done, ", u64(wrong_cases), " wrong")
	system.stop(wrong_cases == 0 ? 0 : 2)
}
