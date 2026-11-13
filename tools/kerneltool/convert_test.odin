package kerneltool

import module "contract:module"
import "core:testing"

// The rebase table that encode_rebases writes must make module.rebase add
// the base to exactly the given locations.
@(test)
rebases_round_trip :: proc(t: ^testing.T) {
	SIZE :: 3 * module.PAGE_SIZE
	offsets := [?]u64{0, 8, 16, 64, 504, 512, 520, 4096, 4104, 8184}

	file: [dynamic]u8
	defer delete(file)
	directory: [module.TABLE_COUNT]module.Table_Entry
	segments := [?]module.Segment{{}, {memory_size = SIZE, flags = {.Read, .Write}}}
	sorted := offsets
	words := encode_rebases(sorted[:])
	resize(&file, size_of(module.Header) + size_of(directory))
	directory[module.Table_Kind.Segments] = {offset = u64(len(file)), count = len(segments), record_size = size_of(module.Segment)}
	append(&file, ..([^]u8)(&segments)[:size_of(segments)])
	directory[module.Table_Kind.Rebases] = {offset = u64(len(file)), count = u32(len(words)), record_size = 8}
	append(&file, ..([^]u8)(raw_data(words))[:len(words) * 8])
	header := module.Header{magic = module.MAGIC, version = module.VERSION, header_size = size_of(module.Header), machine = .X86_64, table_count = module.TABLE_COUNT, memory_size = SIZE}
	(^module.Header)(&file[0])^ = header
	(^[module.TABLE_COUNT]module.Table_Entry)(&file[size_of(module.Header)])^ = directory

	testing.expect_value(t, module.validate(file[:]), module.Error.None)
	memory := make([]u64, SIZE / 8)
	defer delete(memory)
	BASE :: 0x1000_0000
	testing.expect_value(t, module.rebase(file[:], ([^]u8)(raw_data(memory))[:SIZE], BASE), module.Error.None)
	for word, index in memory {
		expected: u64
		for offset in offsets {
			if offset == u64(index * 8) {
				expected = BASE
			}
		}
		testing.expect_value(t, word, expected)
	}
	testing.expect(t, len(words) < len(offsets), "the bitmap form is shorter than one word per location")
}

// A segment that is read-only after the load and that no loader writes (no
// rebase and no slot in its pages) becomes a constant segment; with a
// rebase or with a slot it keeps its flags. A location at the first byte
// after the segment is not in it, and a segment of another kind never
// changes.
@(test)
a_segment_that_no_loader_writes_is_only_read :: proc(t: ^testing.T) {
	after_load := module.Segment_Flags{.Read, .Write, .Read_Only_After_Load}
	segment := module.Segment{memory_offset = 2 * module.PAGE_SIZE, memory_size = module.PAGE_SIZE, flags = after_load}
	outside := [?]u64{0, 2 * module.PAGE_SIZE - 8, 3 * module.PAGE_SIZE}
	slots_outside := [?]module.Slot{{memory_offset = 3 * module.PAGE_SIZE, import_index = 1, export_index = 1}}
	// No rebase and no slot at all, then some in the other segments only.
	testing.expect_value(t, segment_flags_after_the_relocations(segment, nil, nil), module.Segment_Flags{.Read})
	testing.expect_value(t, segment_flags_after_the_relocations(segment, outside[:], slots_outside[:]), module.Segment_Flags{.Read})
	// A rebase at its first word, and at its last word.
	first := [?]u64{2 * module.PAGE_SIZE}
	last := [?]u64{3 * module.PAGE_SIZE - 8}
	testing.expect_value(t, segment_flags_after_the_relocations(segment, first[:], nil), after_load)
	testing.expect_value(t, segment_flags_after_the_relocations(segment, last[:], nil), after_load)
	// A slot.
	slots_inside := [?]module.Slot{{memory_offset = 2 * module.PAGE_SIZE + 16, import_index = 1, export_index = 1}}
	testing.expect_value(t, segment_flags_after_the_relocations(segment, outside[:], slots_inside[:]), after_load)
	// The data and the code of a module keep their flags with no rebase.
	data := module.Segment{memory_offset = 2 * module.PAGE_SIZE, memory_size = module.PAGE_SIZE, flags = {.Read, .Write}}
	code := module.Segment{memory_size = module.PAGE_SIZE, flags = {.Read, .Execute}}
	testing.expect_value(t, segment_flags_after_the_relocations(data, nil, nil), module.Segment_Flags{.Read, .Write})
	testing.expect_value(t, segment_flags_after_the_relocations(code, nil, nil), module.Segment_Flags{.Read, .Execute})
}
