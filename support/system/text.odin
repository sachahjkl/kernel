package system

import "contract:cut_mark"
import op "contract:operation"
import "contract:value_kinds"
import "support:sentence"

// Text without an allocator: support/sentence. These names stay in this
// library, so a program writes system.Writer and system.format.
Hex :: sentence.Hex
Size :: sentence.Size
Duration :: sentence.Duration
Hash :: sentence.Hash
Module_Name :: sentence.Module_Name
Part :: sentence.Part
part_kind :: sentence.part_kind
Writer :: sentence.Writer
HEX_DIGITS :: sentence.HEX_DIGITS
write_bytes :: sentence.write_bytes
write_unsigned :: sentence.write_unsigned
write_hex :: sentence.write_hex
write_part :: sentence.write_part
written :: sentence.written
writer_reset :: sentence.writer_reset
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
//
// The line has the level `Info` and no channel. Each part is a text or a
// value: a number, a `Hex`, a `Size`, a `Duration`, a `Hash`, a
// `Module_Name` or a status; a reader of the log shows each value in the
// color of its kind.
//
// ```odin
// system.log("console: loaded ", system.Module_Name{"manual"}, " in ", system.Duration{spent, .Microseconds})
// ```
log :: proc "contextless" (parts: ..Part) {
	log_in("", .Info, ..parts)
}

// The bytes of the buffer of `log_in`: the longest line that it gives to
// the kernel in one `Log` call.
LOG_PART_SIZE :: 512

// log_in writes one text on the log, in a channel and with a level. The
// channel is a short name with no space: at most 16 characters. The kernel
// sets the time, the program and the thread of the record. A text of any
// length goes whole: the parts are written in a buffer of LOG_PART_SIZE
// bytes, and each time the buffer is full it goes to the kernel as one line
// of the log, ended after a whole character; the text continues on the next
// line. Nothing is cut.
//
// Each part that is a value (part_kind) goes with its value run, so that the
// log record keeps its kind. A line with more than LOG_CALL_RUN_LIMIT values
// keeps the runs of its first values; the text is the same either way.
//
// A control byte of a part becomes "?" (`log_control_bytes_replace`). A
// program with no log handle writes nothing; the kernel refuses a line above
// the log limit of the budget, and the line is lost: `budget_used` counts
// the lines that the kernel refused.
//
// ```odin
// system.log_in("storage", .Warning, "storage: the block ", block, " has a wrong check")
// ```
log_in :: proc "contextless" (channel: string, level: op.Log_Level, parts: ..Part) {
	handle := context_record().handles[op.CONTEXT_LOG]
	if handle == 0 {
		return
	}
	name: [op.LOG_CHANNEL_CAPACITY]u8
	copy(name[:], channel)
	packed := transmute([2]u64)name
	buffer: [LOG_PART_SIZE]u8
	count := 0
	runs: [op.LOG_CALL_RUN_LIMIT]value_kinds.Value_Run_In_Call
	run_count := 0
	for part in parts {
		// The widest value is a hash of 32 bytes: 64 digits.
		number: [96]u8
		bytes: []u8
		kind := part_kind(part)
		switch value in part {
		case string:
			bytes = transmute([]u8)value
		case Module_Name:
			bytes = transmute([]u8)value.name
		case u64, i64, Hex, Size, Duration, Hash, op.Status:
			bytes = transmute([]u8)format(number[:], part)
		}
		part_start := count
		for len(bytes) > 0 {
			taken := copy(buffer[count:], bytes)
			log_control_bytes_replace(buffer[count:][:taken])
			count += taken
			bytes = bytes[taken:]
			if count == len(buffer) && len(bytes) > 0 {
				// A full buffer and more to come: one line, ended after a
				// whole character; the bytes of a cut character go first on
				// the next line. The run of this part ends with the line,
				// and goes on in the next one.
				line := cut_mark.complete_characters(buffer[:count])
				if line == 0 {
					line = count
				}
				sent := runs
				sent_count := value_kinds.value_runs_cut(sent[:], run_count, line)
				if part_start < line {
					value_kinds.value_run_add(sent[:], &sent_count, part_start, line, kind)
				}
				log_send(handle, buffer[:line], sent[:sent_count], level, packed)
				run_count = value_kinds.value_runs_after(runs[:], run_count, line)
				part_start = max(part_start - line, 0)
				count = copy(buffer[:], buffer[line:count])
			}
		}
		value_kinds.value_run_add(runs[:], &run_count, part_start, count, kind)
	}
	log_send(handle, buffer[:count], runs[:run_count], level, packed)
}

// log_send gives one line to the kernel: its text, then its value runs right
// after it, as the operation Log takes them.
@(private = "file")
log_send :: proc "contextless" (handle: Handle, text: []u8, runs: []value_kinds.Value_Run_In_Call, level: op.Log_Level, packed: [2]u64) {
	RUN_SIZE :: size_of(value_kinds.Value_Run_In_Call)
	area: [LOG_PART_SIZE + op.LOG_CALL_RUN_LIMIT * RUN_SIZE]u8
	count := copy(area[:], text)
	run_count := min(len(runs), op.LOG_CALL_RUN_LIMIT)
	if run_count > 0 {
		copy(area[count:], ([^]u8)(raw_data(runs))[:run_count * RUN_SIZE])
	}
	call(.Log, u64(handle), u64(uintptr(&area[0])), u64(count), u64(level), packed[0], packed[1], u64(run_count))
}

// log_control_bytes_replace writes "?" in place of each control byte of ASCII
// (below 0x20, and 0x7F) of a text that goes to the log. The kernel writes
// a line of the log to the serial port as it is, and a terminal of the host
// acts on a carriage return or an escape sequence: a text that a program
// took from data (a name of a debug object, a name of a file) could forge or
// hide a line of the log. The kernel ends each line itself, so a line feed
// in a text is replaced too.
log_control_bytes_replace :: proc "contextless" (bytes: []u8) {
	for &value in bytes {
		if value < 0x20 || value == 0x7F {
			value = '?'
		}
	}
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
		// A line of the log ends after a whole character.
		if len(part) < len(rest) {
			whole := cut_mark.complete_characters(transmute([]u8)part)
			part = part[:whole > 0 ? whole : len(part)]
		}
		rest = rest[len(part):]
		// A copy: the bytes of the caller are not changed.
		copied: [LOG_CALL_LIMIT]u8
		count := copy(copied[:], part)
		log_control_bytes_replace(copied[:count])
		call(.Log, u64(handle), u64(uintptr(raw_data(copied[:]))), u64(count), u64(op.Log_Level.Info), 0, 0)
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
