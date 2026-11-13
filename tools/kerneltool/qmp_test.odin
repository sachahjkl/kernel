package kerneltool

import "core:testing"

@(private = "file")
EVENTS_START :: "{\"execute\":\"input-send-event\",\"arguments\":{\"events\":["
@(private = "file")
EVENTS_END :: "]}}"
@(private = "file")
KEY_DOWN :: "{\"type\":\"key\",\"data\":{\"down\":true,\"key\":{\"type\":\"qcode\",\"data\":\""
@(private = "file")
KEY_UP :: "{\"type\":\"key\",\"data\":{\"down\":false,\"key\":{\"type\":\"qcode\",\"data\":\""
@(private = "file")
KEY_END :: "\"}}}"

// A line with an upper case letter and symbols gives the names of the
// scenario, and a character with no key is named by its place.
@(test)
key_names_of_a_line_with_upper_case_and_symbols :: proc(t: ^testing.T) {
	names, unknown := key_names_of_a_text("Go(\"a_1\")")
	testing.expect_value(t, unknown, -1)
	expected := []string{"shift-g", "o", "shift-9", "shift-apostrophe", "a", "shift-minus", "1", "shift-apostrophe", "shift-0"}
	testing.expect_value(t, len(names), len(expected))
	for name, index in expected {
		if index < len(names) {
			testing.expect_value(t, names[index], name)
		}
	}
	_, place := key_names_of_a_text("ab~c")
	testing.expect_value(t, place, 2)
	empty, none := key_names_of_a_text("")
	testing.expect_value(t, len(empty), 0)
	testing.expect_value(t, none, -1)
}

// The command of a list of keys presses and releases each one in order:
// a key with shift has shift down first and shift up last.
@(test)
key_events_command_of_a_key_with_shift_and_enter :: proc(t: ^testing.T) {
	expected := EVENTS_START + KEY_DOWN + "shift" + KEY_END + "," + KEY_DOWN + "a" + KEY_END + "," + KEY_UP + "a" + KEY_END + "," + KEY_UP + "shift" + KEY_END + "," + KEY_DOWN + "ret" + KEY_END + "," + KEY_UP + "ret" + KEY_END + EVENTS_END
	testing.expect_value(t, qmp_key_events_command([]string{"shift-a", "ret"}), expected)
	testing.expect_value(t, qmp_key_events_command(nil), EVENTS_START + EVENTS_END)
}

// The other commands, as QEMU takes them.
@(test)
commands_of_the_pointer_the_picture_and_the_monitor :: proc(t: ^testing.T) {
	testing.expect_value(t, qmp_pointer_move_command(40, -7), EVENTS_START + "{\"type\":\"rel\",\"data\":{\"axis\":\"x\",\"value\":40}},{\"type\":\"rel\",\"data\":{\"axis\":\"y\",\"value\":-7}}" + EVENTS_END)
	testing.expect_value(t, qmp_pointer_button_command(true), EVENTS_START + "{\"type\":\"btn\",\"data\":{\"down\":true,\"button\":\"left\"}}" + EVENTS_END)
	testing.expect_value(t, qmp_pointer_button_command(false), EVENTS_START + "{\"type\":\"btn\",\"data\":{\"down\":false,\"button\":\"left\"}}" + EVENTS_END)
	testing.expect_value(t, qmp_screendump_command("build/screen.ppm"), "{\"execute\":\"screendump\",\"arguments\":{\"filename\":\"build/screen.ppm\"}}")
	testing.expect_value(t, qmp_monitor_command("i/b 0x64"), "{\"execute\":\"human-monitor-command\",\"arguments\":{\"command-line\":\"i/b 0x64\"}}")
	// A quote and a backslash of a path are escaped.
	testing.expect_value(t, qmp_screendump_command("a\"b\\c"), "{\"execute\":\"screendump\",\"arguments\":{\"filename\":\"a\\\"b\\\\c\"}}")
}

// The bytes that the virtual keyboard queues for a name: 3 for a key, 5
// for a key with a prefix, the sum for a name of several keys, and 8 for a
// key that the tool does not know.
@(test)
device_bytes_of_a_key_name :: proc(t: ^testing.T) {
	testing.expect_value(t, key_device_bytes("a"), 3)
	testing.expect_value(t, key_device_bytes("ret"), 3)
	testing.expect_value(t, key_device_bytes("shift-a"), 6)
	testing.expect_value(t, key_device_bytes("ctrl-r"), 6)
	testing.expect_value(t, key_device_bytes("pgup"), 5)
	testing.expect_value(t, key_device_bytes("meta_l"), 5)
	testing.expect_value(t, key_device_bytes("pause"), 8)
}

// The parts of a list of keys: each fits in the queue of the virtual
// keyboard, no name is cut, no name is lost, and the order stays.
@(test)
key_chunks_fit_in_the_queue_of_the_keyboard :: proc(t: ^testing.T) {
	// 6, 3, 6 bytes, then 3, 6, 3 bytes.
	names := []string{"shift-g", "o", "shift-9", "1", "shift-0", "ret"}
	chunks := key_chunks(names)
	testing.expect_value(t, len(chunks), 2)
	if len(chunks) == 2 {
		testing.expect_value(t, len(chunks[0]), 3)
		testing.expect_value(t, len(chunks[1]), 3)
		testing.expect_value(t, chunks[0][2], "shift-9")
		testing.expect_value(t, chunks[1][0], "1")
		testing.expect_value(t, chunks[1][2], "ret")
	}
	// Five keys of 3 bytes fit; the sixth starts a part.
	plain := []string{"a", "b", "c", "d", "e", "f"}
	plain_chunks := key_chunks(plain)
	testing.expect_value(t, len(plain_chunks), 2)
	if len(plain_chunks) == 2 {
		testing.expect_value(t, len(plain_chunks[0]), 5)
		testing.expect_value(t, len(plain_chunks[1]), 1)
	}
	// Each part of a long line fits, and the parts hold each name one time.
	line, _ := key_names_of_a_text("start(\"A_Name\") + 12*3 = \"x\"")
	count := 0
	for chunk in key_chunks(line) {
		bytes := 0
		for name in chunk {
			bytes += key_device_bytes(name)
			testing.expect_value(t, name, line[count])
			count += 1
		}
		testing.expect(t, len(chunk) > 0, "no part is empty")
		testing.expect(t, bytes <= DEVICE_QUEUE_BYTES, "a part fits in the queue")
	}
	testing.expect_value(t, count, len(line))
	// A name with more bytes than the room is a part alone.
	small := key_chunks([]string{"a", "shift-a", "b"}, 4)
	testing.expect_value(t, len(small), 3)
	testing.expect_value(t, len(key_chunks(nil)), 0)
}

// The count that the compositor must reach: one record for each press and
// one for each release.
@(test)
key_records_of_a_list_of_names :: proc(t: ^testing.T) {
	testing.expect_value(t, key_record_count([]string{"a"}), 2)
	testing.expect_value(t, key_record_count([]string{"shift-a", "ret"}), 6)
	testing.expect_value(t, key_record_count(nil), 0)
}

// The lines of QEMU: its first line, the reply of a command that is done,
// with its value, a refusal with its description, and an event, which is
// not a reply.
@(test)
reply_of_qemu_is_parsed_by_its_first_name :: proc(t: ^testing.T) {
	kind, text := qmp_reply_parse("{\"QMP\": {\"version\": {\"qemu\": {\"micro\": 4, \"minor\": 2, \"major\": 10}, \"package\": \"\"}, \"capabilities\": [\"oob\"]}}\r")
	testing.expect_value(t, kind, Qmp_Reply_Kind.Greeting)
	kind, text = qmp_reply_parse("{\"return\": {}}\r")
	testing.expect_value(t, kind, Qmp_Reply_Kind.Return)
	testing.expect_value(t, text, "{}")
	kind, text = qmp_reply_parse("{\"return\": \"portb[0x0064] = 0x1c\\r\\n\"}\r")
	testing.expect_value(t, kind, Qmp_Reply_Kind.Return)
	testing.expect_value(t, text, "\"portb[0x0064] = 0x1c\\r\\n\"")
	kind, text = qmp_reply_parse("{\"error\": {\"class\": \"GenericError\", \"desc\": \"Parameter 'data' does not accept value 'nosuchkey'\"}}")
	testing.expect_value(t, kind, Qmp_Reply_Kind.Error)
	testing.expect_value(t, text, "Parameter 'data' does not accept value 'nosuchkey'")
	kind, text = qmp_reply_parse("{\"timestamp\": {\"seconds\": 1794571673, \"microseconds\": 994608}, \"event\": \"RESUME\"}")
	testing.expect_value(t, kind, Qmp_Reply_Kind.Event)
	kind, text = qmp_reply_parse("QEMU 10.2.4 monitor")
	testing.expect_value(t, kind, Qmp_Reply_Kind.Unknown)
	kind, text = qmp_reply_parse("")
	testing.expect_value(t, kind, Qmp_Reply_Kind.Unknown)
}

// The status of the keyboard controller in what the monitor prints, and
// the bit that says that a byte waits for the system.
@(test)
status_of_the_keyboard_controller_is_read :: proc(t: ^testing.T) {
	status, ok := controller_status_parse("\"portb[0x0064] = 0x1d\\r\\n\"")
	testing.expect(t, ok)
	testing.expect_value(t, status, 0x1d)
	testing.expect(t, status & CONTROLLER_OUTPUT_FULL != 0, "a byte waits")
	status, ok = controller_status_parse("\"portb[0x0064] = 0x1c\\r\\n\"")
	testing.expect(t, ok)
	testing.expect(t, status & CONTROLLER_OUTPUT_FULL == 0, "no byte waits")
	_, ok = controller_status_parse("\"unknown command: 'i'\\r\\n\"")
	testing.expect(t, !ok)
	_, ok = controller_status_parse("\"portb[0x0064] = 0x\"")
	testing.expect(t, !ok)
}
