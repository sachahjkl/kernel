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
write_parameter_type :: sentence.write_parameter_type
write_field_type :: sentence.write_field_type
direction_name :: sentence.direction_name
error_text :: sentence.error_text
kernel_error_text :: sentence.kernel_error_text
export_error_text :: sentence.export_error_text
ring_error_text :: sentence.ring_error_text
wrapper_error_text :: sentence.wrapper_error_text
error_detail_number_text :: sentence.error_detail_number_text
export_error_detail_text :: sentence.export_error_detail_text
error_details_rest_text :: sentence.error_details_rest_text

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

// LOG_CALL_LIMIT is the bytes of text that the kernel takes in one Log call:
// it writes them as one line, in as many log records as they need.
LOG_CALL_LIMIT :: 4096

// log_text writes a text on the log as it is, with no format and no buffer
// of its own: a text of any length goes whole, as one line when it has at
// most LOG_CALL_LIMIT bytes, and as several lines of that size when it is
// longer. Nothing is cut.
log_text :: proc "contextless" (text: string) {
	handle := context_record().handles[op.CONTEXT_LOG]
	if handle == 0 {
		return
	}
	rest := text
	for {
		part := rest[:min(len(rest), LOG_CALL_LIMIT)]
		rest = rest[len(part):]
		call(.Log, u64(handle), u64(uintptr(raw_data(part))), u64(len(part)), u64(op.Log_Level.Info), 0, 0)
		if len(rest) == 0 {
			break
		}
	}
}

// name_of gives the text of a fixed array of bytes that ends with zero bytes.
name_of :: proc "contextless" (bytes: []u8) -> string {
	count := 0
	for count < len(bytes) && bytes[count] != 0 {
		count += 1
	}
	return string(bytes[:count])
}
