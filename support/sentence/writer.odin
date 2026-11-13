// Text for a person, with no allocator and no kernel operation: a Writer
// fills a buffer that the caller owns, and the sentences of the error
// records (docs/MODULE_CONTRACT.md, section 8) and of the descriptions of
// the exports are written with it. A program compiles it in through
// support/system; the kernel tool compiles it on the host, so a sentence
// of the host is the sentence of the machine.
package sentence

import "contract:cut_mark"
import op "contract:operation"
import "contract:value_kinds"

// Text without an allocator: a Part is a string or a value with a kind, and
// format writes parts in a buffer.

Hex :: distinct u64
Size :: value_kinds.Size
Duration :: value_kinds.Duration
Hash :: value_kinds.Hash
Module_Name :: value_kinds.Module_Name

// A string is plain text. Each other part is a value with a kind
// (part_kind): an integer and a Hex are numbers, a Size a size, a Duration
// a time, a Hash a version, a Module_Name a module, and a status of the
// kernel a status, written as its number.
Part :: union {
	string,
	u64,
	i64,
	Hex,
	Size,
	Duration,
	Hash,
	Module_Name,
	op.Status,
}

// part_kind gives the value kind of a part: the log keeps it beside the
// text, so that a reader colors each value by what it is.
part_kind :: proc "contextless" (part: Part) -> value_kinds.Value_Kind {
	switch _ in part {
	case string:
		return .None
	case u64, i64, Hex:
		return .Number
	case Size:
		return .Size
	case Duration:
		return .Time
	case Hash:
		return .Version
	case Module_Name:
		return .Module
	case op.Status:
		return .Status
	}
	return .None
}

HEX_DIGITS :: [16]u8{'0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f'}

// A writer fills its buffer, and counts the bytes that the buffer cannot
// hold: written ends the text with the cut mark (contract:cut_mark) when it
// dropped some. A text is never cut in silence (docs/ARCHITECTURE.md).
Writer :: struct {
	buffer:         []u8,
	count:          int,
	dropped:        int, // The bytes that did not fit.
	marked:         bool, // written ended the text with the cut mark.
	mark_start:     int, // When marked: the bytes of the text before the mark.
	mark_missing:   u64, // When marked: the count that the mark says.
	dropped_marked: int, // When marked: dropped when the mark was written.
}

write_bytes :: proc "contextless" (writer: ^Writer, bytes: []u8) {
	// After the mark, each byte is a missing byte: written counts it in the
	// mark again.
	if writer.marked {
		writer.dropped += len(bytes)
		return
	}
	room := max(len(writer.buffer) - writer.count, 0)
	taken := min(room, len(bytes))
	copy(writer.buffer[writer.count:][:taken], bytes[:taken])
	writer.count += taken
	writer.dropped += len(bytes) - taken
}

// writer_reset makes a writer empty, for a new text in the same buffer.
writer_reset :: proc "contextless" (writer: ^Writer) {
	writer^ = {buffer = writer.buffer}
}

write_unsigned :: proc "contextless" (writer: ^Writer, value: u64, minimum_digits := 1, pad: u8 = '0') {
	digits: [20]u8
	count := 0
	rest := value
	for rest != 0 || count == 0 {
		digits[len(digits) - 1 - count] = u8('0' + rest % 10)
		count += 1
		rest /= 10
	}
	for count < min(minimum_digits, len(digits)) {
		digits[len(digits) - 1 - count] = pad
		count += 1
	}
	write_bytes(writer, digits[len(digits) - count:])
}

write_hex :: proc "contextless" (writer: ^Writer, value: u64, digit_count := 16) {
	alphabet := HEX_DIGITS
	for i in 0 ..< digit_count {
		write_bytes(writer, {alphabet[(value >> uint(4 * (digit_count - 1 - i))) & 0xF]})
	}
}

write_part :: proc "contextless" (writer: ^Writer, part: Part) {
	switch value in part {
	case string:
		write_bytes(writer, transmute([]u8)value)
	case u64:
		write_unsigned(writer, value)
	case i64:
		if value < 0 {
			write_bytes(writer, {'-'})
			write_unsigned(writer, u64(-value))
		} else {
			write_unsigned(writer, u64(value))
		}
	case Hex:
		write_hex(writer, u64(value))
	case Size:
		write_unsigned(writer, value.value)
		write_bytes(writer, transmute([]u8)value_kinds.size_unit_text(value.unit))
	case Duration:
		write_unsigned(writer, value.value)
		write_bytes(writer, transmute([]u8)value_kinds.duration_unit_text(value.unit))
	case Hash:
		for byte_value in value.bytes {
			write_hex(writer, u64(byte_value), 2)
		}
	case Module_Name:
		write_bytes(writer, transmute([]u8)value.name)
	case op.Status:
		write_unsigned(writer, u64(value))
	}
}

// written gives the text of a writer. When the buffer dropped bytes, the
// text ends with the cut mark and the count of the missing bytes. The mark
// ends the text: a byte written after it counts as missing, and the next
// call of written writes the mark again with the new count.
written :: proc "contextless" (writer: ^Writer) -> string {
	switch {
	case writer.dropped > 0 && !writer.marked:
		writer.count, writer.mark_start, writer.mark_missing = cut_mark.apply(writer.buffer, writer.count, writer.dropped)
		writer.marked, writer.dropped_marked = true, writer.dropped
	case writer.marked && writer.dropped > writer.dropped_marked:
		more := u64(writer.dropped - writer.dropped_marked)
		writer.count, writer.mark_start, writer.mark_missing = cut_mark.apply(writer.buffer, writer.mark_start, int(writer.mark_missing + more))
		writer.dropped_marked = writer.dropped
	}
	return string(writer.buffer[:writer.count])
}

format :: proc "contextless" (buffer: []u8, parts: ..Part) -> string {
	writer := Writer {
		buffer = buffer,
	}
	for part in parts {
		write_part(&writer, part)
	}
	return written(&writer)
}

// write_number writes a number in hexadecimal with "0x", and no zero before
// the first digit.
write_number :: proc "contextless" (writer: ^Writer, value: u64) {
	digits := 1
	for digits < 16 && value >> uint(4 * digits) != 0 {
		digits += 1
	}
	write_part(writer, "0x")
	write_hex(writer, value, digits)
}
