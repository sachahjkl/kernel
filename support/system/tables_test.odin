#+build !freestanding
package system

import "core:testing"

// bytes_append never writes at or after the capacity, also when the count
// is near 2^64 (finding F1 of the hostile read).
@(test)
bytes_append_near_the_end_of_the_numbers :: proc(t: ^testing.T) {
	memory: [32]u8
	for &b in memory {
		b = 0xA5
	}
	place := Bytes_To_Append{bytes = &memory[0], count = max(u64) - 9, capacity = max(u64) - 1}
	// The place says that 8 bytes are free from bytes + count; in this test
	// the bytes start at memory[0] - count, so that a wrong index lands in memory.
	place.bytes = ([^]u8)(uintptr(&memory[0]) - uintptr(place.count))
	bytes_append(&place, transmute([]u8)string("twenty bytes, twenty"))
	for b, index in memory[8:] {
		testing.expectf(t, b == 0xA5, "byte %d after the capacity was written", index + 8)
	}
	testing.expect_value(t, place.count, max(u64)) // The count does not wrap: it stays larger than the capacity.
}

@(test)
bytes_append_counts_what_did_not_fit :: proc(t: ^testing.T) {
	memory: [8]u8
	place := Bytes_To_Append{bytes = &memory[0], count = 2, capacity = 4}
	start := bytes_append(&place, transmute([]u8)string("abcdef"))
	testing.expect_value(t, start, 2)
	testing.expect_value(t, place.count, 8)
	testing.expect_value(t, string(memory[:6]), "\x00\x00ab\x00\x00")
}
