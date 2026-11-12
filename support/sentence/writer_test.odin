#+build !freestanding
package sentence

import "core:testing"

// A writer counts the bytes that its buffer does not hold, and its text
// ends with the cut mark: never a text cut in silence.
@(test)
writer_counts_what_it_drops :: proc(t: ^testing.T) {
	buffer: [16]u8
	writer := Writer {
		buffer = buffer[:],
	}
	write_part(&writer, "sixteen bytes ok")
	testing.expect_value(t, writer.dropped, 0)
	testing.expect_value(t, written(&writer), "sixteen bytes ok")

	writer_reset(&writer)
	write_part(&writer, "seventeen bytes!!")
	testing.expect_value(t, writer.dropped, 1)
	// No room for a whole mark of 20 bytes: as much of it as fits.
	testing.expect_value(t, written(&writer), "... and 17 bytes")

	big: [64]u8
	writer = Writer {
		buffer = big[:],
	}
	write_part(&writer, "the error record of the export says: ")
	write_part(&writer, u64(1234567890))
	write_part(&writer, " and the rest of a long sentence")
	testing.expect_value(t, writer.dropped, 37 + 10 + 32 - 64)
	text := written(&writer)
	testing.expect_value(t, text, "the error record of the export says: 123456... and 36 bytes more")
	testing.expect_value(t, written(&writer), text) // A second call: the same text.
}

// A byte written after the mark is one more missing byte.
@(test)
writer_after_its_mark :: proc(t: ^testing.T) {
	buffer: [40]u8
	writer := Writer {
		buffer = buffer[:],
	}
	write_part(&writer, "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG")
	first := written(&writer)
	testing.expect_value(t, first, "abcdefghijklmnopqrs... and 24 bytes more")
	write_part(&writer, "seven!!")
	testing.expect_value(t, written(&writer), "abcdefghijklmnopqrs... and 31 bytes more")
}

@(test)
format_marks_a_long_text :: proc(t: ^testing.T) {
	buffer: [32]u8
	testing.expect_value(t, format(buffer[:], "short"), "short")
	testing.expect_value(t, format(buffer[:], "a text of forty bytes, eight too many!!!"), "a text of f... and 29 bytes more")
}
