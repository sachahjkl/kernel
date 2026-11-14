// A test of the trees of a store (docs/STORAGE.md): many entries in trees inside trees, a listing in pages, a rename, the removal of a tree, and a handle on a part of the store that reaches nothing outside it.
//
// The first run (an empty store) makes 100 trees of 10 trees of 100 objects, one commit for each 100 entries, and checks each case. The second run, on the same disk after a new start of the machine, checks the counts and the contents that the first run left. Each case ends with a line "...: as it must", or a line "WRONG". The times are measures: no case checks a speed.
//
// **What it is for.** It checks that a [store](term:store) holds a large
// [tree](term:tree) of entries across a restart of the machine, and that a
// handle on a part of the store reaches nothing outside that part. A
// program sees only its [private store](term:private-store); inside it, a
// tree is the unit that a program lends to a part of itself.
//
// **What a reader sees.** It has no window and no menu line: the machine
// test starts it with `start("hierarchy")` on a machine with a data disk,
// two times. Each case writes one log line, `hierarchy: <case>: as it
// must`, or `hierarchy: WRONG: <case>` at the level error. The first run
// writes `hierarchy: a new store: the first run`, and the time to make the
// 100 000 objects.
//
// **Its grant**: **Store**, its private store in the storage service.
package hierarchy

import "modus:contract/errors"
import "modus:support/storage"
import "modus:support/system"

TOP_TREES :: 100
PARTS :: 10
OBJECTS_IN_PART :: 100
MADE_OBJECTS :: TOP_TREES * PARTS * OBJECTS_IN_PART // 100000
PAGE_ROWS :: 16

// The names that go into one tree in a scrambled order: enough leaves for
// the branches to split, and for the root to be a branch of branches.
SCRAMBLED_NAMES :: 6000
// The order of the adds: the name of the number (n * ADD_STEP + 17) mod
// SCRAMBLED_NAMES for n from 0. The order of the removes: (n * REMOVE_STEP)
// mod SCRAMBLED_NAMES, the even numbers only. Each step is a prime that does
// not divide SCRAMBLED_NAMES, so each order names each number once, with no
// random source: a run is the same at each start.
ADD_STEP :: 4099
REMOVE_STEP :: 1777
SCRAMBLED_LEFT :: SCRAMBLED_NAMES / 2

// What the first run leaves: the objects made, one object "content" in
// each top tree, one object written through a share, less the tree
// "tree_002" with its 10 trees, its 1000 objects and its content; and the
// tree "scrambled" with the odd half of its names.
OBJECTS_LEFT :: MADE_OBJECTS + TOP_TREES + 1 - (PARTS * OBJECTS_IN_PART + 1) + SCRAMBLED_LEFT
TREES_LEFT :: TOP_TREES + TOP_TREES * PARTS - (1 + PARTS) + 1

client: storage.Client
wrong_cases: int

// number_name writes a name of a prefix and a number of three digits, so
// that the order of the names is the order of the numbers.
number_name :: proc "contextless" (buffer: []u8, prefix: string, number: int) -> string {
	count := copy(buffer[:], prefix)
	buffer[count] = u8('0' + number / 100 % 10)
	buffer[count + 1] = u8('0' + number / 10 % 10)
	buffer[count + 2] = u8('0' + number % 10)
	return string(buffer[:count + 3])
}

// scrambled_name writes the name of a number of five digits.
scrambled_name :: proc "contextless" (buffer: []u8, number: int) -> string {
	count := copy(buffer[:], "s_")
	divisor := 10000
	for _ in 0 ..< 5 {
		buffer[count] = u8('0' + number / divisor % 10)
		count += 1
		divisor /= 10
	}
	return string(buffer[:count])
}

outcome :: proc "contextless" (good: bool, what: string, parts: ..system.Part) {
	writer_bytes: [480]u8
	writer := system.Writer{buffer = writer_bytes[:]}
	for part in parts {
		system.write_part(&writer, part)
	}
	if good {
		system.log("hierarchy: ", what, system.written(&writer), ": as it must")
	} else {
		wrong_cases += 1
		system.log_in("hierarchy", .Error, "hierarchy: WRONG: ", what, system.written(&writer))
	}
}

// refused_with says if a call failed with an error kind, and writes its
// sentence.
refused_with :: proc "contextless" (status: storage.Status, error: ^errors.Error_Record, kind: errors.Kind) -> bool {
	return status == .Failed && errors.Kind(error.kind) == kind
}

// count_entries counts the entries of the tree of a place, page by page,
// and checks that each page continues the order of the one before.
count_entries :: proc "contextless" (connection: ^storage.Client, place: storage.Place) -> (objects: int, trees: int, in_order: bool, status: storage.Status) {
	rows: [PAGE_ROWS]storage.Listed
	names: [PAGE_ROWS * 64]u8
	last: [64]u8
	last_count := 0
	in_order = true
	for {
		page: []storage.Listed
		page, status = storage.list(connection, place, string(last[:last_count]), rows[:], names[:])
		if status != .Ok {
			return
		}
		if len(page) == 0 {
			return
		}
		for row in page {
			name := names[row.name_offset:][:row.name_count]
			if last_count != 0 && !name_after(name, last[:last_count]) {
				in_order = false
			}
			last_count = copy(last[:], name)
			if row.kind == storage.ENTRY_TREE {
				trees += 1
			} else {
				objects += 1
			}
		}
	}
}

name_after :: proc "contextless" (name, before: []u8) -> bool {
	for index in 0 ..< min(len(name), len(before)) {
		if name[index] != before[index] {
			return name[index] > before[index]
		}
	}
	return len(name) > len(before)
}

// add_names makes entries of one kind under a place, in one commit.
add_names :: proc "contextless" (place: storage.Place, prefix: string, count: int, kind: i64) -> (storage.Status, i64) {
	rows: [OBJECTS_IN_PART]storage.Add_Row
	names: [OBJECTS_IN_PART * 16]u8
	used := 0
	for number in 0 ..< count {
		buffer: [16]u8
		name := number_name(buffer[:], prefix, number)
		rows[number] = {name_offset = i64(used), name_count = i64(len(name)), kind = kind}
		used += copy(names[used:], name)
	}
	error: errors.Error_Record
	generation, status := storage.add(&client, place, rows[:count], names[:used], &error)
	return status, generation
}

first_run :: proc "contextless" () {
	start := system.time()
	if status, _ := add_names(storage.ROOT, "tree_", TOP_TREES, storage.ENTRY_TREE); status != .Ok {
		outcome(false, "the top trees: ", "status ", u64(status))
		return
	}
	commits: u64 = 1
	for top in 0 ..< TOP_TREES {
		buffer: [16]u8
		top_place, status := storage.open_tree(&client, storage.ROOT, number_name(buffer[:], "tree_", top))
		if status != .Ok {
			outcome(false, "open a top tree: ", "status ", u64(status))
			return
		}
		add_names(top_place, "part_", PARTS, storage.ENTRY_TREE)
		commits += 1
		for part in 0 ..< PARTS {
			part_buffer: [16]u8
			part_place, part_status := storage.open_tree(&client, top_place, number_name(part_buffer[:], "part_", part))
			if part_status != .Ok {
				outcome(false, "open a part: ", "status ", u64(part_status))
				return
			}
			if add_status, _ := add_names(part_place, "object_", OBJECTS_IN_PART, storage.ENTRY_OBJECT); add_status != .Ok {
				outcome(false, "add the objects of a part: ", "status ", u64(add_status))
				return
			}
			commits += 1
			storage.close_tree(&client, part_place)
		}
		content_name: [32]u8
		content: [32]u8
		text := number_name(content_name[:], "content of tree_", top)
		count := copy(content[:], text)
		storage.write(&client, top_place, "content", content[:count])
		commits += 1
		storage.close_tree(&client, top_place)
		if (top + 1) % 10 == 0 {
			system.log("hierarchy: ", i64((top + 1) * PARTS * OBJECTS_IN_PART), " objects made in ", commits, " commits, in ", system.time() - start, " ms")
		}
	}
	counts, _ := storage.usage(&client)
	outcome(counts.objects == MADE_OBJECTS + TOP_TREES && counts.trees == TOP_TREES + TOP_TREES * PARTS, "made ", counts.objects, " objects and ", counts.trees, " trees in ", commits, " commits, in ", system.time() - start, " ms, ", counts.blocks, " blocks")

	// The listing: the root in pages, one part, then every part.
	listing_start := system.time()
	objects, trees, in_order, status := count_entries(&client, storage.ROOT)
	outcome(status == .Ok && trees == TOP_TREES && objects == 0 && in_order, "the root in pages of 16: ", i64(trees), " trees, in order")
	all_objects := 0
	all_in_order := true
	for top in 0 ..< TOP_TREES {
		buffer: [16]u8
		top_place, _ := storage.open_tree(&client, storage.ROOT, number_name(buffer[:], "tree_", top))
		for part in 0 ..< PARTS {
			part_buffer: [16]u8
			part_place, _ := storage.open_tree(&client, top_place, number_name(part_buffer[:], "part_", part))
			part_objects, _, part_in_order, _ := count_entries(&client, part_place)
			all_objects += part_objects
			all_in_order &&= part_in_order
			storage.close_tree(&client, part_place)
		}
		storage.close_tree(&client, top_place)
	}
	outcome(all_objects == MADE_OBJECTS && all_in_order, "listed ", i64(all_objects), " objects in ", i64(TOP_TREES * PARTS), " trees in pages of 16, each page after the one before, in ", system.time() - listing_start, " ms")

	// Rename: an object up two trees, and a tree with all under it.
	tree_0, _ := storage.open_tree(&client, storage.ROOT, "tree_000")
	part_0, _ := storage.open_tree(&client, tree_0, "part_000")
	error: errors.Error_Record
	_, status = storage.rename(&client, part_0, "object_000", storage.ROOT, "moved", &error)
	moved_objects, _, _, _ := count_entries(&client, part_0)
	_, found_moved, _ := storage.read(&client, storage.ROOT, "moved", nil)
	outcome(status == .Ok && moved_objects == OBJECTS_IN_PART - 1 && found_moved, "rename of an object to the root: the part has ", i64(moved_objects), " objects")
	_, status = storage.rename(&client, storage.ROOT, "tree_001", tree_0, "tree_001_moved", &error)
	moved_tree, tree_status := storage.open_tree(&client, tree_0, "tree_001_moved")
	_, moved_parts, _, _ := count_entries(&client, moved_tree)
	outcome(status == .Ok && tree_status == .Ok && moved_parts == PARTS, "rename of a tree of ", i64(PARTS), " trees and ", i64(PARTS * OBJECTS_IN_PART), " objects: one commit")
	storage.close_tree(&client, moved_tree)
	error = {}
	_, status = storage.rename(&client, storage.ROOT, "tree_000", part_0, "inside", &error)
	outcome(refused_with(status, &error, .Bad_Value), "a tree cannot move inside itself")
	error = {}
	_, status = storage.rename(&client, storage.ROOT, "moved", storage.ROOT, "tree_003", &error)
	outcome(refused_with(status, &error, .Exists), "a rename onto a name that exists is refused")
	storage.close_tree(&client, part_0)
	storage.close_tree(&client, tree_0)

	// The removal of a tree: one commit, then steps while no call waits.
	before, _ := storage.usage(&client)
	removal_start := system.time()
	_, status = storage.remove(&client, storage.ROOT, "tree_002", &error)
	after, _ := storage.usage(&client)
	_, top_trees, _, _ := count_entries(&client, storage.ROOT)
	outcome(status == .Ok && top_trees == TOP_TREES - 2, "remove of a tree: the name is gone at its commit; ", after.removing, " trees wait to be freed")
	for {
		counts, _ = storage.usage(&client)
		if counts.removing == 0 || system.time() - removal_start > system.TEST_HANG_BOUND_MILLISECONDS {
			break
		}
		system.sleep(system.time() + 1)
	}
	outcome(counts.removing == 0 && counts.objects == before.objects - (PARTS * OBJECTS_IN_PART + 1) && counts.trees == before.trees - (1 + PARTS) && counts.blocks < before.blocks, "the removal freed ", before.objects - counts.objects, " objects, ", before.trees - counts.trees, " trees and ", before.blocks - counts.blocks, " blocks, in ", system.time() - removal_start, " ms")

	scrambled_case()
	confinement()
	counts, _ = storage.usage(&client)
	outcome(counts.objects == OBJECTS_LEFT && counts.trees == TREES_LEFT, "the first run leaves ", counts.objects, " objects and ", counts.trees, " trees")
}

// scrambled_case adds names to one tree in an order that is not the order
// of the names, so that leaves and branches split in their middle and the
// root splits; reads each one back; then removes half of them in another
// order, so that leaves and branches merge and take records from their
// siblings.
scrambled_case :: proc "contextless" () {
	start := system.time()
	tree_row := [1]storage.Add_Row{{name_offset = 0, name_count = 9, kind = storage.ENTRY_TREE}}
	tree_name := "scrambled"
	_, status := storage.add(&client, storage.ROOT, tree_row[:], transmute([]u8)tree_name)
	place, open_status := storage.open_tree(&client, storage.ROOT, "scrambled")
	if status != .Ok || open_status != .Ok {
		outcome(false, "the tree scrambled: ", "status ", u64(status), " ", u64(open_status))
		return
	}
	rows: [250]storage.Add_Row
	names: [250 * 8]u8
	commits: u64
	for first := 0; first < SCRAMBLED_NAMES; first += len(rows) {
		used := 0
		count := min(len(rows), SCRAMBLED_NAMES - first)
		for row in 0 ..< count {
			buffer: [8]u8
			name := scrambled_name(buffer[:], ((first + row) * ADD_STEP + 17) % SCRAMBLED_NAMES)
			rows[row] = {name_offset = i64(used), name_count = i64(len(name)), kind = storage.ENTRY_OBJECT}
			used += copy(names[used:], name)
		}
		if _, add_status := storage.add(&client, place, rows[:count], names[:used]); add_status != .Ok {
			outcome(false, "the scrambled adds: ", "status ", u64(add_status))
			return
		}
		commits += 1
	}
	objects, _, in_order, _ := count_entries(&client, place)
	found_all := true
	for number in 0 ..< SCRAMBLED_NAMES {
		buffer: [8]u8
		_, found, _ := storage.read(&client, place, scrambled_name(buffer[:], number), nil)
		found_all &&= found
	}
	removed := 0
	for step in 0 ..< SCRAMBLED_NAMES {
		number := step * REMOVE_STEP % SCRAMBLED_NAMES
		if number % 2 != 0 {
			continue
		}
		buffer: [8]u8
		if _, remove_status := storage.remove(&client, place, scrambled_name(buffer[:], number)); remove_status == .Ok {
			removed += 1
		}
	}
	left, _, left_in_order, _ := count_entries(&client, place)
	even_buffer, odd_buffer: [8]u8
	_, even_found, _ := storage.read(&client, place, scrambled_name(even_buffer[:], 2), nil)
	_, odd_found, _ := storage.read(&client, place, scrambled_name(odd_buffer[:], 3), nil)
	storage.close_tree(&client, place)
	outcome(objects == SCRAMBLED_NAMES && in_order && found_all && removed == SCRAMBLED_LEFT && left == SCRAMBLED_LEFT && left_in_order && !even_found && odd_found, "added ", i64(objects), " names in a scrambled order in ", commits, " commits, listed in order, each read back; removed ", i64(removed), " in another order, ", i64(left), " left in order, in ", system.time() - start, " ms")
}

// confinement: a share reaches the tree of its place and nothing outside
// it; a read-only share changes nothing; unshare ends it.
confinement :: proc "contextless" () {
	tree_3, _ := storage.open_tree(&client, storage.ROOT, "tree_003")
	tree_4, _ := storage.open_tree(&client, storage.ROOT, "tree_004")
	shared, number, status := storage.share(&client, tree_3, true)
	outcome(status == .Ok, "a read-only share of tree_003")
	if status != .Ok {
		return
	}
	_, parts, _, _ := count_entries(&shared, storage.ROOT)
	outcome(parts == PARTS, "the share lists the ", i64(parts), " trees of tree_003 only")
	for name in ([]string{"..", ".", "/tree_004", "part_000/../..", "../tree_004"}) {
		error: errors.Error_Record
		_, _, read_status := storage.read(&shared, storage.ROOT, name, nil, &error)
		outcome(refused_with(read_status, &error, .Bad_Byte), "the name \"", name, "\" is refused")
	}
	error: errors.Error_Record
	_, _, read_status := storage.read(&shared, tree_4, "content", nil, &error)
	outcome(refused_with(read_status, &error, .Absent) && errors.Unit(error.unit) == .Places, "a place of another connection names nothing on the share")
	// Another store: a share does not act for a principal.
	error = {}
	_, store_status := storage.open_store(&shared, "notes", &error)
	outcome(refused_with(store_status, &error, .No_Grant) && errors.Unit(error.unit) == .Acts_For_Principal, "a name of another store is refused")
	error = {}
	_, write_status := storage.write(&shared, storage.ROOT, "written", transmute([]u8)string("no"), &error)
	outcome(refused_with(write_status, &error, .No_Grant) && errors.Unit(error.unit) == .Changes, "the read-only share cannot write")
	error = {}
	_, remove_status := storage.remove(&shared, storage.ROOT, "part_000", &error)
	outcome(refused_with(remove_status, &error, .No_Grant), "the read-only share cannot remove")
	storage.unshare(&client, number)
	_, _, ended_status := storage.read(&shared, storage.ROOT, "content", nil)
	outcome(ended_status == .Gone, "after unshare, the handles of the share are revoked: a call gives Gone")

	tree_5, _ := storage.open_tree(&client, storage.ROOT, "tree_005")
	writable, writable_number, writable_status := storage.share(&client, tree_5, false)
	_, written_status := storage.write(&writable, storage.ROOT, "written_through_a_share", transmute([]u8)string("kept"))
	text: [8]u8
	bytes, found, _ := storage.read(&client, tree_5, "written_through_a_share", text[:])
	outcome(writable_status == .Ok && written_status == .Ok && found && string(bytes) == "kept", "a writable share writes in tree_005, and the maker reads it")
	storage.unshare(&client, writable_number)
	storage.close_tree(&client, tree_3)
	storage.close_tree(&client, tree_4)
	storage.close_tree(&client, tree_5)
}

// second_run checks what the first run left, after a new start of the
// machine: the open of the disk read every tree again.
second_run :: proc "contextless" (counts: storage.Usage) {
	start := system.time()
	outcome(counts.objects == OBJECTS_LEFT && counts.trees == TREES_LEFT && counts.removing == 0, "after the remount: ", counts.objects, " objects and ", counts.trees, " trees")
	total_objects := 0
	contents_good := 0
	for top in 0 ..< TOP_TREES {
		buffer: [16]u8
		top_place, status := storage.open_tree(&client, storage.ROOT, number_name(buffer[:], "tree_", top))
		if status != .Ok {
			continue
		}
		for part in 0 ..< PARTS {
			part_buffer: [16]u8
			part_place, part_status := storage.open_tree(&client, top_place, number_name(part_buffer[:], "part_", part))
			if part_status != .Ok {
				continue
			}
			part_objects, _, _, _ := count_entries(&client, part_place)
			total_objects += part_objects
			storage.close_tree(&client, part_place)
		}
		content: [32]u8
		bytes, found, _ := storage.read(&client, top_place, "content", content[:])
		expected_buffer: [32]u8
		if found && string(bytes) == number_name(expected_buffer[:], "content of tree_", top) {
			contents_good += 1
		}
		storage.close_tree(&client, top_place)
	}
	// The odd half of the scrambled names, in order.
	scrambled, _ := storage.open_tree(&client, storage.ROOT, "scrambled")
	scrambled_left, _, scrambled_in_order, _ := count_entries(&client, scrambled)
	outcome(scrambled_left == SCRAMBLED_LEFT && scrambled_in_order, "after the remount: ", i64(scrambled_left), " scrambled names left, in order")
	// tree_001 is inside tree_000 now, with its parts.
	tree_0, _ := storage.open_tree(&client, storage.ROOT, "tree_000")
	moved, _ := storage.open_tree(&client, tree_0, "tree_001_moved")
	_, moved_parts, _, _ := count_entries(&client, moved)
	_, found_moved, _ := storage.read(&client, storage.ROOT, "moved", nil)
	// The parts of the 98 top trees, less the object that moved to the root.
	expected := (TOP_TREES - 2) * PARTS * OBJECTS_IN_PART - 1
	outcome(total_objects == expected && contents_good == TOP_TREES - 2 && moved_parts == PARTS && found_moved, "after the remount: ", i64(total_objects), " objects listed in the parts, ", i64(contents_good), " contents byte for byte, the renamed tree and object in their places, in ", system.time() - start, " ms")
}

// entry connects to the private store and reads its usage. On an empty
// store it runs the first run: it makes the trees, then checks each case.
// On a store that the first run filled it runs the second run: it checks
// the counts and the contents. Each case writes its line on the log. The
// program then stops with the code 0 when each case held, else 2. With no
// store or no usage, it writes `hierarchy: WRONG: no store` (or `no usage`)
// at the level error, and stops with the code 1.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	ok: bool
	if client, ok = storage.open(ctx); !ok {
		system.log_in("hierarchy", .Error, "hierarchy: WRONG: no store")
		system.stop(1)
	}
	counts, status := storage.usage(&client)
	if status != .Ok {
		system.log_in("hierarchy", .Error, "hierarchy: WRONG: no usage")
		system.stop(1)
	}
	if counts.objects == 0 {
		system.log("hierarchy: a new store: the first run")
		first_run()
	} else {
		system.log("hierarchy: a store with ", counts.objects, " objects: the run after the remount")
		second_run(counts)
	}
	system.log("hierarchy: done, ", u64(wrong_cases), " wrong")
	system.stop(wrong_cases == 0 ? 0 : 2)
}
