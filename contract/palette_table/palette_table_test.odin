#+build !freestanding
package palette_table

import "core:testing"

@(private = "file")
table_of_test :: proc(count: int) -> []u8 {
	memory := make([]u8, TABLE_BYTES)
	header := (^Header)(raw_data(memory))
	header^ = {magic = MAGIC, version = VERSION, change_count = 2, entry_count = u32(count)}
	for index in 0 ..< count {
		entry := (^Entry)(&memory[ENTRIES_OFFSET + index * size_of(Entry)])
		entry.name_length = u8(copy(entry.name[:], "time"))
		entry.signature_length = u8(copy(entry.signature[:], "time() -> Integer"))
		entry.about_length = u8(copy(entry.about[:], "the time of the system"))
		entry.result = .Integer
	}
	return memory
}

// A good table gives its entries and its generation; a full table too.
@(test)
a_good_table_is_copied :: proc(t: ^testing.T) {
	snapshot := new(Snapshot)
	defer free(snapshot)
	for count in ([]int{0, 3, ENTRY_CAPACITY}) {
		memory := table_of_test(count)
		defer delete(memory)
		problem, _ := snapshot_take(memory, snapshot)
		testing.expect_value(t, problem, Problem.None)
		testing.expect_value(t, snapshot.entry_count, count)
		testing.expect_value(t, snapshot.generation, 2)
	}
	testing.expect_value(t, snapshot.entries[ENTRY_CAPACITY - 1].result, Value_Kind.Integer)
}

// The copy is checked, not the memory: a problem names its entry, and the
// snapshot then has no entry.
@(test)
a_bad_entry_is_named :: proc(t: ^testing.T) {
	snapshot := new(Snapshot)
	defer free(snapshot)
	memory := table_of_test(5)
	defer delete(memory)
	entry := (^Entry)(&memory[ENTRIES_OFFSET + 4 * size_of(Entry)])
	entry.reserved = 1
	problem, index := snapshot_take(memory, snapshot)
	testing.expect_value(t, problem, Problem.Bad_Kind)
	testing.expect_value(t, index, 4)
	testing.expect_value(t, snapshot.entry_count, 0)
	entry.reserved = 0
	entry.signature_length = 2 // Shorter than the name.
	problem, index = snapshot_take(memory, snapshot)
	testing.expect_value(t, problem, Problem.Bad_Signature)
	// A count past the capacity is refused before any entry is read.
	(^Header)(raw_data(memory)).entry_count = ENTRY_CAPACITY + 1
	problem, _ = snapshot_take(memory, snapshot)
	testing.expect_value(t, problem, Problem.Too_Many_Entries)
	// A table that its writer changes with no end is no table.
	(^Header)(raw_data(memory)).change_count = 9
	problem, _ = snapshot_take(memory, snapshot)
	testing.expect_value(t, problem, Problem.Never_Stable)
	problem, _ = snapshot_take(memory[:TABLE_BYTES - 1], snapshot)
	testing.expect_value(t, problem, Problem.Too_Small)
}

// The runs of a result: what a writer writes is valid; a line or a run
// that does not fit the panel says so and writes no part of it.
@(test)
the_runs_of_a_result :: proc(t: ^testing.T) {
	area: [RESULT_CAPACITY]u8
	writer := Result_Writer{buffer = area[:], fits = true}
	result_run(&writer, .Label, "pages  ")
	result_run(&writer, .Number, "4096")
	result_line_end(&writer)
	result_run(&writer, .Plain, "a \x07 byte")
	result_line_end(&writer)
	testing.expect(t, writer.fits)
	testing.expect_value(t, writer.lines, 2)
	testing.expect(t, result_valid(area[:writer.count]))
	testing.expect_value(t, area[0], u8(Run_Part.Label))
	testing.expect_value(t, string(area[2:9]), "pages  ")
	// A line wider than the panel.
	wide := Result_Writer{buffer = area[:], fits = true}
	for _ in 0 ..< RESULT_COLUMN_CAPACITY / 10 + 1 {
		result_run(&wide, .Plain, "0123456789")
	}
	testing.expect(t, !wide.fits)
	// More lines than the panel shows.
	tall := Result_Writer{buffer = area[:], fits = true}
	for _ in 0 ..< RESULT_LINE_CAPACITY {
		result_run(&tall, .Plain, "x")
		result_line_end(&tall)
	}
	testing.expect(t, tall.fits)
	result_run(&tall, .Plain, "x")
	testing.expect(t, !tall.fits)
	// The copy of an area: a length past the area is refused.
	memory := make([]u8, TABLE_BYTES)
	defer delete(memory)
	copied: [RESULT_CAPACITY]u8
	memory[RESULT_OFFSET] = u8(Run_Part.Number)
	memory[RESULT_OFFSET + 1] = 1
	memory[RESULT_OFFSET + 2] = '7'
	count, ok := result_copy(memory, 3, &copied)
	testing.expect(t, ok && count == 3)
	_, ok = result_copy(memory, RESULT_CAPACITY + 1, &copied)
	testing.expect(t, !ok)
	_, ok = result_copy(memory, 2, &copied) // The run ends past the length.
	testing.expect(t, !ok)
	testing.expect_value(t, name_hash("memory") == name_hash("memorx"), false)
}
