package remote_service

import "contract:isolated"
import "contract:remote"
import "support:display"
import "support:graphics"
import "support:interface"
import "support:system"

// An answer with an error record: the call ran, and the service gave its
// error as a value. Not the color "failed" (no call failed to run), and not
// the color of a result: the amber that the program log gives to the level
// Warning, the color of a failure that the caller can act on. A refusal by
// remote itself (no call ran) and by the service keep the color "failed".
COLOR_ERROR_RECORD :: graphics.COLOR_BOOT_PROGRAM

// The window follows docs/DESIGN.md: rectangles only, the grid of 8 pixels,
// three cards with a title in the accent of their concept and a caption
// that names their record, names in the dim color, values in the text
// color, the state of a call in the color of a program that runs or in the
// color "failed", with a text that says the same.

WIDTH :: 720
HEIGHT :: 552

// The window is built with the interface package (docs/INTERFACE.md): the
// elements of the rules, the damage by difference, a present of the part
// that changed.

LINE :: graphics.LINE_HEIGHT

records_now, records_before: [512]interface.Draw_Record
text_now, text_before: [8192]u8
drawing: interface.Window_Drawing

// hash_color gives the color of a module from its hash (docs/DESIGN.md:
// a thing with an identity takes its color from it).
hash_color :: proc "contextless" (hash: [32]u8) -> graphics.Color {
	return graphics.mix(graphics.rgb(u32(hash[0]) | 0x40, u32(hash[1]) | 0x40, u32(hash[2]) | 0x40), graphics.COLOR_TEXT, 64)
}

draw :: proc "contextless" (window: ^display.Window) {
	if drawing.now.records == nil {
		drawing = interface.window_drawing_of(records_now[:], records_before[:], text_now[:], text_before[:])
	}
	frame := interface.window_frame_begin(&drawing, window)
	table := frame.table
	interface.background(&frame, {0, 0, WIDTH, HEIGHT})
	buffer: [64]u8
	if weak_seed {
		inside := interface.card(&frame, {8, 8, WIDTH - 16, 100}, "NO KEY", "the random seed of this program is weaker than \"processor\"", graphics.COLOR_FAILED)
		interface.draw_text(table, inside.x, inside.y, "Seed_Too_Weak: this service makes no key, and listens on nothing", graphics.COLOR_FAILED)
		interface.window_frame_end(&drawing, &frame, window)
		return
	}

	// The calls of the host, with the large number of the card.
	inside := interface.card(&frame, {8, 8, WIDTH - 16, 192}, "CALLS FROM THE HOST", "one QUIC stream: remote.Request -> isolated call -> remote.Answer", graphics.COLOR_PROGRAM)
	interface.large_number(&frame, inside.x, inside.y, system.format(buffer[:], counts.calls), graphics.COLOR_PROGRAM)
	interface.draw_text(table, inside.x, inside.y + 56, "calls that ran", graphics.COLOR_DIM)
	COLUMN :: 232
	VALUE :: 456
	Fact :: struct {
		name:  string,
		value: u64,
		unit:  string,
	}
	facts := [?]Fact {
		{"whole requests", counts.requests, ""},
		{"refused by this program", counts.refused, ""},
		{"streams reset", counts.too_large + counts.timeouts, ""},
		{"given up by the host", counts.cancelled, ""},
		{"bytes in", counts.bytes_in, " B"},
		{"bytes out", counts.bytes_out, " B"},
	}
	for item, index in facts {
		color := (item.name == "refused by this program" || item.name == "streams reset") && item.value != 0 ? graphics.Color(graphics.COLOR_FAILED) : graphics.COLOR_TEXT
		interface.label_value_line(&frame, {inside.x + COLUMN, inside.y + index * LINE, VALUE + 64 - COLUMN, LINE}, item.name, system.format(buffer[:], item.value, item.unit), color)
	}
	interface.draw_text(table, inside.x + VALUE + 96, inside.y, "listens on", graphics.COLOR_DIM)
	interface.draw_text(table, inside.x + VALUE + 96, inside.y + LINE, system.format(buffer[:], "UDP ", u64(listen_port)), graphics.COLOR_TEXT)
	interface.draw_text(table, inside.x + VALUE + 96, inside.y + 2 * LINE, "admits", graphics.COLOR_DIM)
	interface.draw_text(table, inside.x + VALUE + 96, inside.y + 3 * LINE, "10.0.2.2 only", graphics.COLOR_TEXT)
	// One bar: the width of each part is its count of requests.
	BAR_Y :: 96
	parts := [3]u64{counts.calls - counts.failed, counts.failed, counts.refused}
	colors := [3]graphics.Color{graphics.COLOR_PROGRAM, COLOR_ERROR_RECORD, graphics.COLOR_FAILED}
	interface.bar_parts(&frame, {inside.x, inside.y + BAR_Y, inside.width, 8}, parts[:], colors[:], max(counts.requests, 1))
	x := interface.draw_text(table, inside.x, inside.y + BAR_Y + 12, system.format(buffer[:], counts.calls - counts.failed, " gave a result"), graphics.COLOR_PROGRAM)
	x = interface.draw_text(table, x + 24, inside.y + BAR_Y + 12, system.format(buffer[:], counts.failed, " gave an error record"), COLOR_ERROR_RECORD)
	interface.draw_text(table, x + 24, inside.y + BAR_Y + 12, system.format(buffer[:], counts.refused, " refused"), graphics.COLOR_FAILED)
	// The key that the host pins: 64 hexadecimal digits.
	key: [64]u8
	at := interface.draw_text(table, inside.x, inside.y + BAR_Y + 12 + LINE + 8, "public key ", graphics.COLOR_DIM)
	interface.draw_text(table, at, inside.y + BAR_Y + 12 + LINE + 8, hex_text(key[:], public_key[:]), graphics.COLOR_TEXT)

	// The connections that the root service made.
	inside = interface.card(&frame, {8, 208, WIDTH - 16, 144}, "CONNECTIONS", "root: Connect, a call ring and a call region of 64 KiB", graphics.COLOR_MEMORY)
	shown := 0
	for &connection in service_connections {
		if connection.name[0] == 0 {
			continue
		}
		y := inside.y + shown * LINE
		interface.mark(&frame, inside.x, y + 2, 12, hash_color(connection.hash))
		interface.draw_text(table, inside.x + 24, y, remote.name_text(&connection.name), graphics.COLOR_TEXT)
		hash: [16]u8
		digits := system.HEX_DIGITS
		for index in 0 ..< 8 {
			hash[2 * index] = digits[connection.hash[index] >> 4]
			hash[2 * index + 1] = digits[connection.hash[index] & 15]
		}
		interface.draw_text(table, inside.x + 160, y, string(hash[:]), hash_color(connection.hash))
		interface.draw_text_right(table, inside.x + VALUE + 64, y, system.format(buffer[:], connection.count, " calls"), graphics.COLOR_TEXT)
		shown += 1
	}
	if shown == 0 {
		interface.draw_text(table, inside.x, inside.y, "none yet: a connection starts at the first call to a service", graphics.COLOR_DIM)
	}

	// The last calls, the last one first.
	inside = interface.card(&frame, {8, 360, WIDTH - 16, 184}, "LAST CALLS", "remote.Answer: status, value, bytes, time in this program", graphics.COLOR_PROGRAM)
	for row in 0 ..< min(recent_count, RECENT_CAPACITY) {
		item := &recent[(recent_count - 1 - row) % RECENT_CAPACITY]
		y := inside.y + int(row) * LINE
		interface.draw_text(table, inside.x, y, item.service[0] != 0 ? remote.name_text(&item.service) : "-", graphics.COLOR_TEXT)
		state, color := "ok", graphics.Color(graphics.COLOR_PROGRAM)
		switch {
		case item.status == .Refused:
			state, color = "refused by remote", graphics.COLOR_FAILED
		case isolated.Status(item.call_status) != .Ok:
			state, color = "refused by the service", graphics.COLOR_FAILED
		case item.error != 0:
			state, color = "error record", COLOR_ERROR_RECORD
		}
		if item.status != .Refused {
			interface.draw_text(table, inside.x + 96, y, system.format(buffer[:], "export ", u64(item.export)), graphics.COLOR_DIM)
		}
		interface.mark(&frame, inside.x + 200, y + 4, 8, color)
		interface.draw_text(table, inside.x + 216, y, state, color)
		if item.text_count != 0 {
			text_place := 216 + interface.text_width({}, state) + 16
			interface.draw_text(table, inside.x + text_place, y, string(item.text[:min(item.text_count, (inside.width - text_place) / graphics.CELL_WIDTH)]), graphics.COLOR_DIM)
		} else {
			interface.draw_text_right(table, inside.x + 488, y, system.format(buffer[:], item.value), graphics.COLOR_TEXT)
			interface.draw_text_right(table, inside.x + 576, y, system.format(buffer[:], item.bytes, " B"), graphics.COLOR_TEXT)
			interface.draw_text_right(table, inside.x + inside.width, y, system.format(buffer[:], item.microseconds, " us"), graphics.COLOR_TEXT)
		}
	}
	if recent_count == 0 {
		interface.draw_text(table, inside.x, inside.y, "none yet: kerneltool call <public key> \"monitor.programs()\" on the host", graphics.COLOR_DIM)
	}
	interface.window_frame_end(&drawing, &frame, window)
}
