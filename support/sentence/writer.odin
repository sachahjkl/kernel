// Text for a person, with no allocator and no kernel operation: a Writer
// fills a buffer that the caller owns, and the sentences of the error
// records (docs/MODULE_CONTRACT.md, section 8) and of the descriptions of
// the exports are written with it. A program compiles it in through
// support/system; the kernel tool compiles it on the host, so a sentence
// of the host is the sentence of the machine.
package sentence

// Text without an allocator: a Part is a string or a number, and format
// writes parts in a buffer.

Hex :: distinct u64

Part :: union {
	string,
	u64,
	i64,
	Hex,
}

HEX_DIGITS :: [16]u8{'0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f'}

Writer :: struct {
	buffer: []u8,
	count:  int,
}

write_bytes :: proc "contextless" (writer: ^Writer, bytes: []u8) {
	for b in bytes {
		if writer.count < len(writer.buffer) {
			writer.buffer[writer.count] = b
			writer.count += 1
		}
	}
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
	}
}

written :: proc "contextless" (writer: ^Writer) -> string {
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
