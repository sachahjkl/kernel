package quic_echo

// The window: the public key of the server (a client pins it), its
// connections with their counts, and what the server refused.

import "support:display"
import "support:graphics"
import "support:interface"
import "support:quic"

WIDTH :: 960
HEIGHT :: 640
LINE :: interface.TABLE_LINE

records_now, records_before: [768]interface.Draw_Record
text_now, text_before: [16384]u8
drawing: interface.Window_Drawing

drawing_prepare :: proc "contextless" () {
	drawing = interface.window_drawing_of(records_now[:], records_before[:], text_now[:], text_before[:])
}

state_text :: proc "contextless" (connection: ^quic.Connection) -> string {
	switch connection.state {
	case .Idle:
		return "idle"
	case .Handshake:
		return "handshake"
	case .Connected:
		return connection.handshake_confirmed ? "connected" : "connected, not confirmed"
	case .Closing:
		return "closing"
	case .Draining:
		return "draining"
	case .Closed:
		return "closed"
	}
	return ""
}

number_text :: proc "contextless" (builder: ^interface.Text_Builder, value: u64, unit: string) -> string {
	builder.count = 0
	interface.text_put_number(builder, value)
	interface.text_put(builder, unit)
	return interface.text_of(builder)
}

draw :: proc "contextless" (window: ^display.Window) {
	frame := interface.window_frame_begin(&drawing, window)
	interface.background(&frame, {0, 0, WIDTH, HEIGHT})
	builder: interface.Text_Builder
	if weak_seed {
		content := interface.card(&frame, {8, 8, WIDTH - 16, 100}, "NO KEY", "the random seed of this program is weaker than \"processor\"", graphics.COLOR_FAILED)
		column := interface.column_of(content)
		interface.label_value_line(&frame, interface.column_take(&column, LINE), "error", "Seed_Too_Weak: this server makes no key, and listens on nothing", graphics.COLOR_FAILED, 120)
		interface.window_frame_end(&drawing, &frame, window)
		return
	}
	content := interface.card(&frame, {8, 8, WIDTH - 16, 100}, "THE SERVER", "QUIC in this program, over a listen grant of UDP", graphics.COLOR_PROGRAM)
	column := interface.column_of(content)
	key: [64]u8
	interface.label_value_line(&frame, interface.column_take(&column, LINE), "public key", hex_text(key[:], public_key[:]), graphics.COLOR_TEXT, 120)
	interface.label_value_line(&frame, interface.column_take(&column, LINE), "UDP port", number_text(&builder, u64(listen_port), ", Ed25519, a raw public key that a client pins"), graphics.COLOR_TEXT, 120)

	content = interface.card(&frame, {8, 116, WIDTH - 16, 340}, "THE CONNECTIONS", "one stream each: each byte goes back", graphics.COLOR_MACHINE)
	column = interface.column_of(content)
	cells: [5]interface.Area
	sizes := [5]interface.Size{interface.characters(24), interface.characters(24), interface.share(), interface.share(), interface.characters(12)}
	interface.row_split(interface.column_take(&column, LINE), sizes[:], cells[:], 16)
	interface.table_header(&frame, cells[:], {"remote", "state", "in", "out", "srtt"}, {.Left, .Left, .Right, .Right, .Right})
	row := 0
	for record, place in records {
		if !record.in_use {
			continue
		}
		connection := &connections[place]
		line := interface.column_take(&column, LINE)
		interface.table_band(&frame, {line.x - 8, line.y, line.width + 16, line.height}, row)
		row += 1
		interface.row_split(line, sizes[:], cells[:], 16)
		remote_text: [40]u8
		interface.cell_text(&frame, cells[0], address_text(remote_text[:], record.remote), graphics.COLOR_TEXT)
		interface.cell_text(&frame, cells[1], state_text(connection), graphics.COLOR_DIM)
		interface.cell_text(&frame, cells[2], number_text(&builder, connection.stream.read_offset, " bytes"), graphics.COLOR_TEXT, .Right)
		interface.cell_text(&frame, cells[3], number_text(&builder, connection.stream.send_length, " bytes"), graphics.COLOR_TEXT, .Right)
		interface.cell_text(&frame, cells[4], number_text(&builder, connection.smoothed_round_trip, " us"), graphics.COLOR_TEXT, .Right)
	}

	content = interface.card(&frame, {8, 464, WIDTH - 16, HEIGHT - 472}, "WHAT THE SERVER COUNTED", "since its start", graphics.COLOR_KERNEL)
	column = interface.column_of(content)
	counters := server.counters
	interface.label_value_line(&frame, interface.column_take(&column, LINE), "accepted", number_text(&builder, counters.accepted, " connections, each with an authentic Initial"), graphics.COLOR_TEXT, 200)
	interface.label_value_line(&frame, interface.column_take(&column, LINE), "ended", number_text(&builder, counters.ended, " connections"), graphics.COLOR_TEXT, 200)
	interface.label_value_line(&frame, interface.column_take(&column, LINE), "not authentic", number_text(&builder, counters.not_authentic, " Initials that no key opens: no record touched"), graphics.COLOR_TEXT, 200)
	interface.label_value_line(&frame, interface.column_take(&column, LINE), "refused by a limit", number_text(&builder, counters.refused_remote_limit + counters.refused_handshake_limit + counters.refused_full, " Initials: one address, the handshakes, a full table"), graphics.COLOR_TEXT, 200)
	interface.label_value_line(&frame, interface.column_take(&column, LINE), "datagrams", number_text(&builder, counters.datagrams, " received"), graphics.COLOR_TEXT, 200)
	interface.window_frame_end(&drawing, &frame, window)
}
