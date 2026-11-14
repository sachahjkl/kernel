#+build !freestanding
package sentence

import op "contract:operation"
import "contract:value_kinds"
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

// A value with a kind writes the same bytes as the parts that a line of the
// log had before the kinds: the serial port and the machine tests read the
// same text.
@(test)
a_value_with_a_kind_writes_the_same_text :: proc(t: ^testing.T) {
	first, second: [96]u8
	testing.expect_value(t, format(first[:], Size{2013, .Mebibytes}), format(second[:], u64(2013), " MiB"))
	testing.expect_value(t, format(first[:], Size{832, .Bytes}), format(second[:], u64(832), " bytes"))
	testing.expect_value(t, format(first[:], Size{7, .Kibibytes}), format(second[:], u64(7), " KiB"))
	testing.expect_value(t, format(first[:], Size{2048, .Pages}), format(second[:], u64(2048), " pages"))
	testing.expect_value(t, format(first[:], Size{4, .Blocks}), format(second[:], u64(4), " blocks"))
	testing.expect_value(t, format(first[:], Duration{820, .Microseconds}), format(second[:], u64(820), " us"))
	testing.expect_value(t, format(first[:], Duration{12, .Milliseconds}), format(second[:], u64(12), " ms"))
	testing.expect_value(t, format(first[:], Duration{5, .Nanoseconds}), format(second[:], u64(5), " ns"))
	testing.expect_value(t, format(first[:], Duration{3, .Seconds}), format(second[:], u64(3), " s"))
	testing.expect_value(t, format(first[:], Module_Name{"storage"}), "storage")
	testing.expect_value(t, format(first[:], op.Status.No_Budget), format(second[:], u64(8)))
	// The head of a hash: the hexadecimal of a Hex of its first 8 bytes,
	// as the kernel wrote it.
	hash := [32]u8{0 = 0x0A, 1 = 0x1B, 2 = 0x2C, 3 = 0x3D, 4 = 0x4E, 5 = 0x5F, 6 = 0x60, 7 = 0xF7}
	testing.expect_value(t, format(first[:], Hash{hash[:8]}), format(second[:], Hex(0x0A1B2C3D4E5F60F7)))
}

// Each part has the kind of what it is; a text has none.
@(test)
each_part_has_its_kind :: proc(t: ^testing.T) {
	testing.expect_value(t, part_kind("text"), value_kinds.Value_Kind.None)
	testing.expect_value(t, part_kind(u64(1)), value_kinds.Value_Kind.Number)
	testing.expect_value(t, part_kind(i64(-1)), value_kinds.Value_Kind.Number)
	testing.expect_value(t, part_kind(Hex(1)), value_kinds.Value_Kind.Number)
	testing.expect_value(t, part_kind(Size{1, .Pages}), value_kinds.Value_Kind.Size)
	testing.expect_value(t, part_kind(Duration{1, .Seconds}), value_kinds.Value_Kind.Time)
	testing.expect_value(t, part_kind(Hash{}), value_kinds.Value_Kind.Version)
	testing.expect_value(t, part_kind(Module_Name{"root"}), value_kinds.Value_Kind.Module)
	testing.expect_value(t, part_kind(op.Status.Ok), value_kinds.Value_Kind.Status)
}
