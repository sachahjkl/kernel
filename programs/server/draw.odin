package server

// The window, by the rules of docs/DESIGN.md: rectangles only, the grid of
// 8 pixels, a card for each subject with a caption that names its record,
// the colors of the concepts. Each value is a field of a record of the
// connection table (tcp.Table, tcp.Connection) or a count of this program.

import "support:display"
import "support:graphics"
import "support:network"
import "support:system"
import "support:tcp"
import "support:web"

WIDTH :: 976
HEIGHT :: 672

// The colors of the concepts (support/graphics/rules.odin, docs/DESIGN.md
// section 4) that this window uses for TCP:
//   boot program  a connection that starts: the handshake.
//   program       a connection that runs.
//   kernel        the end of a connection: the FIN states and TIME-WAIT.
//   memory        bytes and windows.
//   machine       the remote machines and the link.
//   not usable    a connection that ended.

CARD_TITLE :: graphics.CARD_TITLE
CARD_MARGIN :: graphics.CARD_MARGIN
LINE :: 24

// bar draws the full part of a bar: 120 % of its color at the top, 78 % at the bottom.
bar :: proc "contextless" (canvas: graphics.Canvas, x, y, width, height: int, color: graphics.Color) {
	graphics.block(canvas, x, y, width, height, graphics.shade(color, 120), graphics.shade(color, 78))
}

write_large :: proc "contextless" (canvas: graphics.Canvas, x, y: int, characters: string, scale: int, color: graphics.Color) -> int {
	return graphics.text_scaled(canvas, x, y, characters, color, scale)
}

// card draws the frame of one subject and gives the canvas of its content.
card :: proc "contextless" (canvas: graphics.Canvas, x, y, width, height: int, title, caption: string, accent: graphics.Color) -> graphics.Canvas {
	graphics.block(canvas, x, y, width, height, graphics.shade(accent, 28), graphics.shade(accent, 14))
	graphics.block(canvas, x + 1, y + 1, width - 2, height - 2, graphics.COLOR_CARD_TOP, graphics.COLOR_CARD_BOTTOM)
	graphics.block(canvas, x + CARD_MARGIN, y + 12, 4, 16, graphics.shade(accent, 130), accent)
	after := graphics.text(canvas, x + CARD_MARGIN + 12, y + 12, title, accent)
	graphics.text(canvas, after + 16, y + 12, caption, graphics.COLOR_DIM)
	return graphics.view(canvas, x + CARD_MARGIN, y + CARD_TITLE, width - 2 * CARD_MARGIN, height - CARD_TITLE - 8)
}

// right draws a text that ends at x.
right :: proc "contextless" (canvas: graphics.Canvas, x, y: int, text: string, color: graphics.Color) {
	graphics.text(canvas, x - graphics.text_width(text), y, text, color)
}

// fact draws "name   value" on one line of a card.
// A name and its value. The value starts at value_column: one character of
// 8 pixels after the longest name of its card.
fact :: proc "contextless" (canvas: graphics.Canvas, y: int, name: string, value: string, color: graphics.Color = graphics.COLOR_TEXT, value_column := 120) {
	graphics.text(canvas, 0, y, name, graphics.COLOR_DIM)
	graphics.text(canvas, value_column, y, value, value == "" ? graphics.COLOR_DIM : color)
}

size_text :: proc "contextless" (buffer: []u8, bytes: u64) -> string {
	switch {
	case bytes < 1 << 10:
		return system.format(buffer, bytes, " B")
	case bytes < 1 << 20:
		return system.format(buffer, bytes >> 10, ".", (bytes & 1023) * 10 >> 10, " KiB")
	}
	return system.format(buffer, bytes >> 20, ".", (bytes & (1 << 20 - 1)) * 10 >> 20, " MiB")
}

time_text :: proc "contextless" (buffer: []u8, microseconds: u64) -> string {
	switch {
	case microseconds == 0:
		return "not known yet"
	case microseconds < 10_000:
		return system.format(buffer, microseconds, " us")
	case microseconds < 1_000_000:
		return system.format(buffer, microseconds / 1000, ".", microseconds % 1000 / 100, " ms")
	}
	return system.format(buffer, microseconds / 1_000_000, ".", microseconds % 1_000_000 / 100_000, " s")
}

@(rodata)
state_names := [tcp.State]string {
	.Closed       = "CLOSED",
	.Syn_Sent     = "SYN-SENT",
	.Syn_Received = "SYN-RECEIVED",
	.Established  = "ESTABLISHED",
	.Fin_Wait_1   = "FIN-WAIT-1",
	.Fin_Wait_2   = "FIN-WAIT-2",
	.Closing      = "CLOSING",
	.Time_Wait    = "TIME-WAIT",
	.Close_Wait   = "CLOSE-WAIT",
	.Last_Ack     = "LAST-ACK",
}

state_color :: proc "contextless" (state: tcp.State) -> graphics.Color {
	#partial switch state {
	case .Syn_Sent, .Syn_Received:
		return graphics.COLOR_BOOT_PROGRAM
	case .Established, .Close_Wait:
		return graphics.COLOR_PROGRAM
	case .Closed:
		return graphics.COLOR_NOT_USABLE
	}
	return graphics.COLOR_KERNEL // FIN states and TIME-WAIT: the end of a connection.
}

// The columns of the table of connections (a card 536 pixels wide).
COLUMN_STATE :: 120
// "new connections", the longest name of MEASURES, has 15 characters.
MEASURES_VALUE_COLUMN :: 136
COLUMN_IN :: 288 // Right edges.
COLUMN_OUT :: 368
COLUMN_RTT :: 440
COLUMN_WINDOW :: 448 // A bar of WINDOW_BAR pixels for 64 KiB.
WINDOW_BAR :: 56

// The columns of the table of the last requests (a card 424 pixels wide).
ACCESS_TARGET :: 48
ACCESS_STATUS :: 184
ACCESS_BYTES :: 296 // Right edges.
ACCESS_TIME :: 368
ACCESS_PORT :: 384

connection_row_draw :: proc "contextless" (canvas: graphics.Canvas, y: int, connection: ^tcp.Connection, how: string, band: bool) {
	if band {
		graphics.fill(canvas, -8, y - 4, canvas.width + 16, LINE, graphics.COLOR_TRACK)
	}
	ended := how != ""
	text_color := graphics.Color(ended ? graphics.COLOR_DIM : graphics.COLOR_TEXT)
	buffer: [48]u8
	writer := system.Writer{buffer = buffer[:]}
	network.address_write(&writer, connection.remote_address)
	system.write_bytes(&writer, {':'})
	system.write_unsigned(&writer, u64(connection.remote_port))
	graphics.text(canvas, 0, y, system.written(&writer), ended ? graphics.COLOR_DIM : graphics.COLOR_MACHINE)
	if ended {
		graphics.text(canvas, COLUMN_STATE, y, how, how == "reset" || how == "timed out" || how == "aborted" ? graphics.COLOR_FAILED : graphics.COLOR_NOT_USABLE)
	} else {
		graphics.text(canvas, COLUMN_STATE, y, state_names[connection.state], state_color(connection.state))
	}
	right(canvas, COLUMN_IN, y, size_text(buffer[:], connection.bytes_received), text_color)
	right(canvas, COLUMN_OUT, y, size_text(buffer[:], connection.bytes_sent), text_color)
	right(canvas, COLUMN_RTT, y, connection.rtt_samples == 0 ? "-" : time_text(buffer[:], connection.smoothed_rtt), text_color)
	// The congestion window: its width is its size, against the window limit of 64 KiB.
	graphics.fill(canvas, COLUMN_WINDOW, y + 4, WINDOW_BAR, 8, graphics.COLOR_TRACK)
	window := min(u64(connection.congestion_window), u64(tcp.WINDOW_LIMIT))
	filled := int(window * WINDOW_BAR / tcp.WINDOW_LIMIT)
	if filled > 0 {
		bar(canvas, COLUMN_WINDOW, y + 4, filled, 8, ended ? graphics.COLOR_NOT_USABLE : graphics.COLOR_MEMORY)
	}
}

status_color :: proc "contextless" (status: int) -> graphics.Color {
	switch {
	case status < 300:
		return graphics.COLOR_PROGRAM
	case status < 500:
		return graphics.COLOR_BOOT_PROGRAM
	}
	return graphics.COLOR_FAILED
}

access_row_draw :: proc "contextless" (canvas: graphics.Canvas, y: int, record: ^Access_Record, band: bool) {
	if band {
		graphics.fill(canvas, -8, y - 4, canvas.width + 16, LINE, graphics.COLOR_TRACK)
	}
	buffer: [32]u8
	method := web.request_method_name(record.method)
	graphics.text(canvas, 0, y, method == "" ? "-" : method, graphics.COLOR_DIM)
	target := string(record.target[:min(record.target_length, 16)])
	graphics.text(canvas, ACCESS_TARGET, y, target, graphics.COLOR_TEXT)
	graphics.text(canvas, ACCESS_STATUS, y, system.format(buffer[:], u64(record.status)), status_color(record.status))
	right(canvas, ACCESS_BYTES, y, size_text(buffer[:], record.bytes), graphics.COLOR_TEXT)
	right(canvas, ACCESS_TIME, y, time_text(buffer[:], max(record.time, 1)), graphics.COLOR_MACHINE)
	graphics.text(canvas, ACCESS_PORT, y, system.format(buffer[:], u64(record.remote_port)), graphics.COLOR_DIM)
}

draw :: proc "contextless" (window: ^display.Window) {
	started := system.nanoseconds()
	canvas := window.canvas
	graphics.clear(canvas, graphics.COLOR_BACKGROUND)
	for y := 12; y < HEIGHT; y += graphics.POINT_STEP {
		for x := 12; x < WIDTH; x += graphics.POINT_STEP {
			graphics.fill(canvas, x, y, graphics.POINT_SIZE, graphics.POINT_SIZE, graphics.COLOR_POINT)
		}
	}
	buffer: [64]u8
	other: [64]u8
	open := tcp_open_count()

	// The listen grant and the table.
	inside := card(canvas, 8, 8, 256, 160, "LISTEN", "tcp.Table", graphics.COLOR_PROGRAM)
	after := write_large(inside, 0, 0, system.format(buffer[:], u64(open)), 3, graphics.COLOR_PROGRAM)
	graphics.text(inside, after + 8, 24, open == 1 ? "connection" : "connections", graphics.COLOR_DIM)
	fact(inside, 56, "port", system.format(buffer[:], u64(listen_port), ", any host"))
	fact(inside, 76, "most at once", system.format(buffer[:], u64(most_open), " of ", u64(CAPACITY)))
	fact(inside, 96, "accepted", system.format(buffer[:], accepted, ", ", aborted_count, " ended"))

	// The answers by class of status.
	inside = card(canvas, 272, 8, 232, 160, "ANSWERS", "web.Request", graphics.COLOR_MEMORY)
	after = write_large(inside, 0, 0, system.format(buffer[:], requests_answered), 3, graphics.COLOR_MEMORY)
	graphics.text(inside, after + 8, 24, "requests", graphics.COLOR_DIM)
	total := max(requests_answered, 1)
	classes := [3]int{2, 4, 5}
	names := [3]string{"2xx", "4xx", "5xx"}
	colors := [3]graphics.Color{graphics.COLOR_PROGRAM, graphics.COLOR_BOOT_PROGRAM, graphics.COLOR_FAILED}
	for class, row in classes {
		y := 56 + row * 20
		graphics.text(inside, 0, y, names[row], graphics.COLOR_DIM)
		graphics.fill(inside, 40, y + 4, 96, 8, graphics.COLOR_TRACK)
		filled := int(status_classes[class] * 96 / total)
		if filled > 0 {
			bar(inside, 40, y + 4, filled, 8, colors[row])
		}
		graphics.text(inside, 144, y, system.format(buffer[:], status_classes[class]), graphics.COLOR_TEXT)
	}

	// The measures, with the cycle counter.
	inside = card(canvas, 512, 8, 456, 160, "MEASURES", "system.nanoseconds", graphics.COLOR_MACHINE)
	fact(inside, 0, "handshake", handshake_last == 0 ? "" : system.format(buffer[:], time_text(other[:], handshake_last), ", least ", handshake_least, " us"), graphics.COLOR_MACHINE, MEASURES_VALUE_COLUMN)
	fact(inside, 20, "one connection", best_keep_alive_rate == 0 ? "" : system.format(buffer[:], best_keep_alive_rate, " requests in 1 s, the best"), graphics.COLOR_MACHINE, MEASURES_VALUE_COLUMN)
	fact(inside, 40, "new connections", best_new_connection_rate == 0 ? "" : system.format(buffer[:], best_new_connection_rate, " requests in 1 s, the best"), graphics.COLOR_MACHINE, MEASURES_VALUE_COLUMN)
	fact(inside, 60, "one second", best_second_requests == 0 ? "" : system.format(buffer[:], best_second_requests, " requests at most"), graphics.COLOR_MACHINE, MEASURES_VALUE_COLUMN)
	fact(inside, 80, "one draw", draw_time == 0 ? "" : time_text(buffer[:], draw_time), graphics.COLOR_TEXT, MEASURES_VALUE_COLUMN)
	if secret_weak {
		fact(inside, 100, "ISN secret", "weak: the cycle counter", graphics.COLOR_FAILED, MEASURES_VALUE_COLUMN)
	} else {
		fact(inside, 100, "ISN secret", secret_source, graphics.COLOR_TEXT, MEASURES_VALUE_COLUMN)
	}

	// The connection table, live, then the connections that ended.
	inside = card(canvas, 8, 176, 536, 488, "CONNECTIONS", "tcp.Connection", graphics.COLOR_PROGRAM)
	graphics.text(inside, 0, 0, "remote", graphics.COLOR_DIM)
	graphics.text(inside, COLUMN_STATE, 0, "state", graphics.COLOR_DIM)
	right(inside, COLUMN_IN, 0, "in", graphics.COLOR_DIM)
	right(inside, COLUMN_OUT, 0, "out", graphics.COLOR_DIM)
	right(inside, COLUMN_RTT, 0, "srtt", graphics.COLOR_DIM)
	graphics.text(inside, COLUMN_WINDOW, 0, "cwnd", graphics.COLOR_DIM)
	graphics.fill(inside, 0, 20, inside.width, 1, graphics.COLOR_TRACK)
	y := 28
	rows := 0
	ROWS :: 17
	for &connection in connections {
		if connection.state == .Closed || rows == ROWS {
			continue
		}
		connection_row_draw(inside, y, &connection, "", rows % 2 == 1)
		y += LINE
		rows += 1
	}
	if rows == 0 {
		graphics.text(inside, 0, y, "no connection: the table waits for a SYN", graphics.COLOR_DIM)
		y += LINE
		rows += 1
	}
	for back in 1 ..= CONNECTION_HISTORY {
		if rows == ROWS {
			break
		}
		item := &ended_connections[(ended_connection_next - back + CONNECTION_HISTORY) % CONNECTION_HISTORY]
		if !item.known {
			break
		}
		// A connection in TIME-WAIT is in the history already: its live row shows it.
		waits := false
		for &connection in connections {
			if connection.state == .Time_Wait && connection.remote_address == item.record.remote_address && connection.remote_port == item.record.remote_port {
				waits = true
			}
		}
		if waits {
			continue
		}
		how := item.how
		switch {
		case how == "reset by the remote":
			how = "reset"
		case how == "closed, the remote first":
			how = "closed by it"
		case how == "closed, this server first":
			how = "closed by us"
		case len(how) >= 7 && how[:7] == "aborted":
			how = "aborted"
		}
		connection_row_draw(inside, y, &item.record, how, rows % 2 == 1)
		y += LINE
		rows += 1
	}

	// The last requests, the newest first.
	inside = card(canvas, 552, 176, 416, 488, "REQUESTS", "Access_Record", graphics.COLOR_MEMORY)
	graphics.text(inside, 0, 0, "method", graphics.COLOR_DIM)
	graphics.text(inside, ACCESS_TARGET + 16, 0, "target", graphics.COLOR_DIM)
	graphics.text(inside, ACCESS_STATUS - 8, 0, "status", graphics.COLOR_DIM)
	right(inside, ACCESS_BYTES, 0, "bytes", graphics.COLOR_DIM)
	right(inside, ACCESS_TIME, 0, "time", graphics.COLOR_DIM)
	graphics.fill(inside, 0, 20, inside.width, 1, graphics.COLOR_TRACK)
	y = 28
	shown := 0
	for back in 1 ..= ACCESS_HISTORY {
		if shown == 17 {
			break
		}
		record := &access_records[(access_next - back + ACCESS_HISTORY) % ACCESS_HISTORY]
		if record.status == 0 {
			break
		}
		access_row_draw(inside, y, record, shown % 2 == 1)
		y += LINE
		shown += 1
	}
	if shown == 0 {
		graphics.text(inside, 0, y, "no request yet", graphics.COLOR_DIM)
	}
	display.present(window)
	microseconds_taken := (system.nanoseconds() - started) / 1000
	if draw_time == 0 {
		system.log("server: one draw of the window: ", microseconds_taken, " us")
	}
	draw_time = microseconds_taken
}
