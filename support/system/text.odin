package system

import op "contract:operation"
import "support:sentence"

// Text without an allocator: support/sentence. These names stay in this
// library, so a program writes system.Writer and system.format.
Hex :: sentence.Hex
Part :: sentence.Part
Writer :: sentence.Writer
HEX_DIGITS :: sentence.HEX_DIGITS
write_bytes :: sentence.write_bytes
write_unsigned :: sentence.write_unsigned
write_hex :: sentence.write_hex
write_part :: sentence.write_part
written :: sentence.written
format :: sentence.format
write_number :: sentence.write_number
write_rights :: sentence.write_rights
write_type :: sentence.write_type
error_text :: sentence.error_text
kernel_error_text :: sentence.kernel_error_text
export_error_text :: sentence.export_error_text
ring_error_text :: sentence.ring_error_text
wrapper_error_text :: sentence.wrapper_error_text

// log writes one line on the log of the kernel. A program with no handle to
// the log writes nothing.
log :: proc "contextless" (parts: ..Part) {
	log_in("", .Info, ..parts)
}

// log_in writes one text on the log, in a channel and with a level. The
// channel is a short name with no space: at most 16 characters. The kernel
// sets the time, the program and the thread of the record.
log_in :: proc "contextless" (channel: string, level: op.Log_Level, parts: ..Part) {
	handle := context_record().handles[op.CONTEXT_LOG]
	if handle == 0 {
		return
	}
	buffer: [512]u8
	text := format(buffer[:], ..parts)
	name: [op.LOG_CHANNEL_CAPACITY]u8
	copy(name[:], channel)
	packed := transmute([2]u64)name
	call(.Log, u64(handle), u64(uintptr(raw_data(text))), u64(len(text)), u64(level), packed[0], packed[1])
}

// name_of gives the text of a fixed array of bytes that ends with zero bytes.
name_of :: proc "contextless" (bytes: []u8) -> string {
	count := 0
	for count < len(bytes) && bytes[count] != 0 {
		count += 1
	}
	return string(bytes[:count])
}
