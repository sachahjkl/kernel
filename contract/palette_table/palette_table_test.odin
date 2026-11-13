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

// A Setting entry names a setting and a value that the machine has.
@(test)
a_setting_entry_is_checked :: proc(t: ^testing.T) {
	entry: Entry
	entry.kind = .Setting
	entry.name_length = u8(copy(entry.name[:], "set font to spleen"))
	entry.signature_length = u8(copy(entry.signature[:], "set font to spleen"))
	entry.setting, entry.setting_value = 0, 1
	testing.expect_value(t, entry_problem(&entry), Problem.None)
	entry.setting_value = 2 // The font has two values.
	testing.expect_value(t, entry_problem(&entry), Problem.Bad_Setting)
	entry.setting, entry.setting_value = 200, 0
	testing.expect_value(t, entry_problem(&entry), Problem.Bad_Setting)
	entry.setting, entry.parameter_count = 0, 1
	testing.expect_value(t, entry_problem(&entry), Problem.Bad_Setting)
	entry.kind, entry.parameter_count, entry.setting_value = .Command, 0, 1
	testing.expect_value(t, entry_problem(&entry), Problem.Bad_Setting)
	// The name of a parameter: its length and its bytes.
	entry.setting_value = 0
	entry.parameter_name_lengths[2] = PARAMETER_NAME_CAPACITY + 1
	testing.expect_value(t, entry_problem(&entry), Problem.Bad_Length)
	entry.parameter_name_lengths[2] = 2
	entry.parameter_names[2][1] = 3
	testing.expect_value(t, entry_problem(&entry), Problem.Bad_Byte)
}

// The candidates of a parameter, and the typed values of a choice: each
// one is checked after its copy.
@(test)
candidates_and_arguments_are_checked :: proc(t: ^testing.T) {
	memory := make([]u8, TABLE_BYTES)
	defer delete(memory)
	copied := new([CANDIDATE_CAPACITY]Candidate)
	defer free(copied)
	for index in 0 ..< 3 {
		candidate := (^Candidate)(&memory[CANDIDATES_OFFSET + index * size_of(Candidate)])
		candidate.length = u8(copy(candidate.name[:], "plasma"))
	}
	count, ok := candidates_copy(memory, 3, copied)
	testing.expect(t, ok && count == 3)
	testing.expect_value(t, string(copied[2].name[:copied[2].length]), "plasma")
	_, ok = candidates_copy(memory, CANDIDATE_CAPACITY + 1, copied)
	testing.expect(t, !ok)
	_, ok = candidates_copy(memory, 4, copied) // The fourth one has no name.
	testing.expect(t, !ok)
	(^Candidate)(&memory[CANDIDATES_OFFSET]).length = 200
	_, ok = candidates_copy(memory, 1, copied)
	testing.expect(t, !ok)
	(^Candidate)(&memory[CANDIDATES_OFFSET]).length = 2
	memory[CANDIDATES_OFFSET + 2] = 10
	_, ok = candidates_copy(memory, 1, copied)
	testing.expect(t, !ok)
	// An Integer and a Text go and come back whole.
	parameter, argument, good := argument_unpack(argument_pack(4, .Integer, -42, ""))
	testing.expect(t, good && parameter == 4 && argument.kind == .Integer && argument.integer == -42)
	parameter, argument, good = argument_unpack(argument_pack(1, .Text, 0, "acts_for_principal"))
	testing.expect(t, good && parameter == 1 && string(argument.text[:argument.length]) == "acts_for_principal")
	// What a console refuses: a quote, a byte that the font does not draw,
	// a kind with no typed value, a parameter past the last, a length past
	// the values.
	_, _, good = argument_unpack(argument_pack(0, .Text, 0, "a\"b"))
	testing.expect(t, !good)
	_, _, good = argument_unpack(argument_pack(0, .Text, 0, "a\tb"))
	testing.expect(t, !good)
	_, _, good = argument_unpack(argument_pack(0, .Table, 0, ""))
	testing.expect(t, !good)
	_, _, good = argument_unpack(argument_pack(PARAMETER_CAPACITY, .Integer, 1, ""))
	testing.expect(t, !good)
	_, _, good = argument_unpack({0 = u64(Value_Kind.Text) << 8 | 200 << 16})
	testing.expect(t, !good)
	_, _, good = argument_unpack({0 = u64(Value_Kind.Text) << 8 | 1 << 24})
	testing.expect(t, !good)
}
