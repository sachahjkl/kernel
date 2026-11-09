package kerneltool

import module "../../module"
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
