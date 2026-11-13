package kerneltool

import "core:fmt"
import "core:strings"

// The commands of the tool to QEMU, on the machine protocol of QEMU (QMP):
// one line of JSON for a command, one line of JSON for its reply. The tool
// sends the keys and the moves of the pointer as events of the virtual
// keyboard and of the virtual mouse, several in one command, and each
// command has a reply: the tool knows when QEMU did it. This file holds
// the part with no socket: the text of each command, the parse of a reply,
// and the cut of a list of keys into commands that the virtual keyboard
// can hold (docs/TOOLS.md, "How the tool sends input and waits").

// The bytes that the queue of the virtual keyboard holds, and the queue of
// the virtual mouse: QEMU drops, with no error, each byte that comes when
// the queue is full. The tool never sends more than this before the system
// read the bytes before.
DEVICE_QUEUE_BYTES :: 16
// The bytes of one packet of the virtual mouse: a move or a change of a
// button.
POINTER_PACKET_BYTES :: 3
// Bit 0 of the status of the keyboard controller: the controller holds a
// byte that the system has not read.
CONTROLLER_OUTPUT_FULL :: 0x01

// The keys whose press has a prefix byte: 2 bytes for the press and 3 for
// the release.
@(private = "file", rodata)
keys_with_a_prefix := [?]string{"up", "down", "left", "right", "pgup", "pgdn", "home", "end", "insert", "delete", "meta_l", "meta_r", "ctrl_r", "alt_r", "kp_enter", "kp_divide"}

// The keys with a name of several letters whose press is 1 byte and whose
// release is 2.
@(private = "file", rodata)
keys_of_one_byte := [?]string{"shift", "shift_r", "ctrl", "alt", "spc", "ret", "tab", "esc", "backspace", "minus", "equal", "comma", "dot", "slash", "apostrophe", "semicolon", "backslash", "bracket_left", "bracket_right", "grave_accent", "caps_lock", "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11", "f12"}

// key_parts gives the keys of a name of the scenario: "shift-a" is the key
// shift, then the key a.
key_parts :: proc(name: string) -> []string {
	return strings.split(name, "-", context.temp_allocator)
}

// key_device_bytes gives the bytes that the virtual keyboard queues for the
// press and the release of a name. A key that this file does not know
// counts 8 bytes, the most that one key gives: a count that is too high
// only makes a command shorter.
key_device_bytes :: proc(name: string) -> int {
	bytes := 0
	for part in key_parts(name) {
		size := len(part) == 1 ? 3 : 8
		for key in keys_of_one_byte {
			if part == key {
				size = 3
			}
		}
		for key in keys_with_a_prefix {
			if part == key {
				size = 5
			}
		}
		bytes += size
	}
	return bytes
}

// key_record_count gives the key records that the input service sends for
// a list of names: one for each press and one for each release.
key_record_count :: proc(names: []string) -> i64 {
	count: i64
	for name in names {
		count += 2 * i64(len(key_parts(name)))
	}
	return count
}

// key_names_of_a_text gives the name of the key of each character of a
// text. unknown is the place of the first character with no key, or -1.
key_names_of_a_text :: proc(text: string) -> (names: []string, unknown: int) {
	list := make([dynamic]string, 0, len(text) + 1, context.temp_allocator)
	for index in 0 ..< len(text) {
		name := key_name(text[index])
		if name == "" {
			return list[:], index
		}
		append(&list, name)
	}
	return list[:], -1
}

// key_chunks cuts a list of names into the parts that go in one command
// each: the bytes of a part fit in the queue of the virtual keyboard. A
// name is never cut: a name with more bytes than the queue is a part alone.
key_chunks :: proc(names: []string, room := DEVICE_QUEUE_BYTES) -> [][]string {
	chunks := make([dynamic][]string, context.temp_allocator)
	start, bytes := 0, 0
	for name, index in names {
		size := key_device_bytes(name)
		if index > start && bytes + size > room {
			append(&chunks, names[start:index])
			start, bytes = index, 0
		}
		bytes += size
	}
	if start < len(names) {
		append(&chunks, names[start:])
	}
	return chunks[:]
}

// json_text_write writes a text as a JSON string, with its quotes.
json_text_write :: proc(builder: ^strings.Builder, text: string) {
	strings.write_byte(builder, '"')
	for index in 0 ..< len(text) {
		character := text[index]
		switch {
		case character == '"' || character == '\\':
			strings.write_byte(builder, '\\')
			strings.write_byte(builder, character)
		case character < 0x20:
			fmt.sbprintf(builder, "\\u%04x", int(character))
		case:
			strings.write_byte(builder, character)
		}
	}
	strings.write_byte(builder, '"')
}

@(private = "file")
key_event_write :: proc(builder: ^strings.Builder, key: string, down: bool, first: ^bool) {
	if !first^ {
		strings.write_byte(builder, ',')
	}
	first^ = false
	strings.write_string(builder, "{\"type\":\"key\",\"data\":{\"down\":")
	strings.write_string(builder, down ? "true" : "false")
	strings.write_string(builder, ",\"key\":{\"type\":\"qcode\",\"data\":")
	json_text_write(builder, key)
	strings.write_string(builder, "}}}")
}

// qmp_key_events_command gives the command that presses and releases each
// name of a list, in order, with no time between two events: for a name of
// several keys, each key goes down in order, then each goes up in the
// other order ("shift-a": shift down, a down, a up, shift up).
qmp_key_events_command :: proc(names: []string) -> string {
	builder := strings.builder_make(context.temp_allocator)
	strings.write_string(&builder, "{\"execute\":\"input-send-event\",\"arguments\":{\"events\":[")
	first := true
	for name in names {
		parts := key_parts(name)
		for part in parts {
			key_event_write(&builder, part, true, &first)
		}
		#reverse for part in parts {
			key_event_write(&builder, part, false, &first)
		}
	}
	strings.write_string(&builder, "]}}")
	return strings.to_string(builder)
}

// qmp_pointer_move_command gives the command of one relative move of the
// virtual mouse.
qmp_pointer_move_command :: proc(x, y: int) -> string {
	builder := strings.builder_make(context.temp_allocator)
	strings.write_string(&builder, "{\"execute\":\"input-send-event\",\"arguments\":{\"events\":[{\"type\":\"rel\",\"data\":{\"axis\":\"x\",\"value\":")
	strings.write_int(&builder, x)
	strings.write_string(&builder, "}},{\"type\":\"rel\",\"data\":{\"axis\":\"y\",\"value\":")
	strings.write_int(&builder, y)
	strings.write_string(&builder, "}}]}}")
	return strings.to_string(builder)
}

// qmp_pointer_button_command gives the command that presses or releases
// the left button of the virtual mouse.
qmp_pointer_button_command :: proc(down: bool) -> string {
	builder := strings.builder_make(context.temp_allocator)
	strings.write_string(&builder, "{\"execute\":\"input-send-event\",\"arguments\":{\"events\":[{\"type\":\"btn\",\"data\":{\"down\":")
	strings.write_string(&builder, down ? "true" : "false")
	strings.write_string(&builder, ",\"button\":\"left\"}}]}}")
	return strings.to_string(builder)
}

// qmp_screendump_command gives the command that writes the screen in a
// file: its reply comes when the file is whole.
qmp_screendump_command :: proc(path: string) -> string {
	builder := strings.builder_make(context.temp_allocator)
	strings.write_string(&builder, "{\"execute\":\"screendump\",\"arguments\":{\"filename\":")
	json_text_write(&builder, path)
	strings.write_string(&builder, "}}")
	return strings.to_string(builder)
}

// qmp_monitor_command gives the command that runs one line of the other
// monitor of QEMU, the one for a reader: the reply holds what it prints.
qmp_monitor_command :: proc(line: string) -> string {
	builder := strings.builder_make(context.temp_allocator)
	strings.write_string(&builder, "{\"execute\":\"human-monitor-command\",\"arguments\":{\"command-line\":")
	json_text_write(&builder, line)
	strings.write_string(&builder, "}}")
	return strings.to_string(builder)
}

// The line of the monitor that reads the status of the keyboard controller
// with no effect on it.
CONTROLLER_STATUS_LINE :: "i/b 0x64"

Qmp_Reply_Kind :: enum {
	Unknown, // Not a line of the protocol.
	Return, // The command is done.
	Error, // The command is refused.
	Greeting, // The first line of QEMU.
	Event, // A line that QEMU sends by itself: not a reply.
}

// qmp_reply_parse says what one line of QEMU is, by its first name. text
// is the value of a Return as QEMU wrote it, or the description of an
// Error.
qmp_reply_parse :: proc(line: string) -> (kind: Qmp_Reply_Kind, text: string) {
	rest := strings.trim_space(line)
	if !strings.has_prefix(rest, "{") {
		return .Unknown, ""
	}
	rest = strings.trim_left_space(rest[1:])
	if !strings.has_prefix(rest, "\"") {
		return .Unknown, ""
	}
	rest = rest[1:]
	end := strings.index_byte(rest, '"')
	if end < 0 {
		return .Unknown, ""
	}
	name := rest[:end]
	rest = strings.trim_left_space(rest[end + 1:])
	rest = strings.trim_left_space(strings.trim_prefix(rest, ":"))
	switch name {
	case "return":
		// The value goes to the brace that closes the line.
		return .Return, strings.trim_space(strings.trim_suffix(rest, "}"))
	case "error":
		MARK :: "\"desc\":"
		at := strings.index(rest, MARK)
		if at < 0 {
			return .Error, rest
		}
		description := strings.trim_left_space(rest[at + len(MARK):])
		description = strings.trim_prefix(description, "\"")
		// To the first quote with no backslash before it.
		for index in 0 ..< len(description) {
			if description[index] == '"' && (index == 0 || description[index - 1] != '\\') {
				return .Error, description[:index]
			}
		}
		return .Error, description
	case "QMP":
		return .Greeting, ""
	case "timestamp", "event":
		return .Event, ""
	}
	return .Unknown, ""
}

// controller_status_parse reads the status of the keyboard controller in
// what the monitor prints for CONTROLLER_STATUS_LINE: the number in
// hexadecimal after "= 0x".
controller_status_parse :: proc(text: string) -> (status: u8, ok: bool) {
	MARK :: "= 0x"
	at := strings.index(text, MARK)
	if at < 0 {
		return 0, false
	}
	digits := 0
	value := 0
	for index in at + len(MARK) ..< len(text) {
		character := text[index]
		digit: int
		switch character {
		case '0' ..= '9':
			digit = int(character - '0')
		case 'a' ..= 'f':
			digit = int(character - 'a') + 10
		case 'A' ..= 'F':
			digit = int(character - 'A') + 10
		case:
			digit = -1
		}
		if digit < 0 {
			break
		}
		value = value * 16 + digit
		digits += 1
		if digits > 2 {
			return 0, false
		}
	}
	return u8(value), digits > 0
}
