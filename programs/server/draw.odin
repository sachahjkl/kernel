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
	at := x
	for index in 0 ..< len(characters) {
		value := characters[index]
		if value >= graphics.FONT_FIRST && value <= graphics.FONT_LAST {
			glyph := graphics.font[value - graphics.FONT_FIRST]
			for bits, row in glyph {
				for column in 0 ..< graphics.CELL_WIDTH {
					if bits << uint(column) & 0x80 != 0 {
						graphics.fill(canvas, at + column * scale, y + row * scale, scale, scale, color)
					}
				}
			}
		}
		at += graphics.CELL_WIDTH * scale
	}
	return at
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
fact :: proc "contextless" (canvas: graphics.Canvas, y: int, name: string, value: string, color: graphics.Color = graphics.COLOR_TEXT) {
	graphics.text(canvas, 0, y, name, graphics.COLOR_DIM)
	graphics.text(canvas, 120, y, value, value == "" ? graphics.COLOR_DIM : color)
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
	}
	return system.format(buffer, microseconds / 1000, ".", microseconds % 1000 / 100, " ms")
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

// The columns of the table of connections.
COLUMN_STATE :: 160
COLUMN_IN :: 384 // Right edge.
COLUMN_OUT :: 488
COLUMN_RTT :: 576
COLUMN_WINDOW :: 600 // A bar of WINDOW_BAR pixels for 64 KiB, then its value.
WINDOW_BAR :: 96
COLUMN_RETRANSMIT :: 856 // Right edge.
COLUMN_PROBES :: 936

row_draw :: proc "contextless" (canvas: graphics.Canvas, y: int, connection: ^tcp.Connection, how: string, band: bool) {
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
		graphics.text(canvas, COLUMN_STATE, y, how, how == "reset" || how == "timed out" ? graphics.COLOR_FAILED : graphics.COLOR_NOT_USABLE)
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
	right(canvas, COLUMN_WINDOW + WINDOW_BAR + 96, y, size_text(buffer[:], u64(connection.congestion_window)), text_color)
	right(canvas, COLUMN_RETRANSMIT, y, system.format(buffer[:], connection.retransmissions), connection.retransmissions > 0 && !ended ? graphics.COLOR_BOOT_PROGRAM : text_color)
	right(canvas, COLUMN_PROBES - 16, y, system.format(buffer[:], connection.probes), text_color)
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
	open := tcp.open_count(&table)

	// The listen grant and the table.
	inside := card(canvas, 8, 8, 312, 176, "LISTEN", "tcp.Table", graphics.COLOR_PROGRAM)
	after := write_large(inside, 0, 0, system.format(buffer[:], u64(open)), 3, graphics.COLOR_PROGRAM)
	graphics.text(inside, after + 8, 24, open == 1 ? "connection open" : "connections open", graphics.COLOR_DIM)
	fact(inside, 56, "listen port", system.format(buffer[:], u64(listen_port), ", any remote"))
	fact(inside, 76, "most at once", system.format(buffer[:], u64(most_open), " of ", u64(CAPACITY)))
	fact(inside, 96, "accepted", system.format(buffer[:], accepted))
	fact(inside, 116, "refused SYN", system.format(buffer[:], table.refused_syns, ", RST sent ", table.resets_sent))

	// What went through.
	inside = card(canvas, 328, 8, 312, 176, "TRAFFIC", "tcp.Connection", graphics.COLOR_MEMORY)
	after = write_large(inside, 0, 0, system.format(buffer[:], requests), 3, graphics.COLOR_MEMORY)
	graphics.text(inside, after + 8, 24, requests == 1 ? "request answered" : "requests answered", graphics.COLOR_DIM)
	live_in, live_out, live_retransmit: u64
	for &connection, index in connections {
		if connection.state != .Closed && !sessions[index].logged {
			live_in += connection.bytes_received
			live_out += connection.bytes_sent
			live_retransmit += connection.retransmissions
		}
	}
	fact(inside, 56, "bytes in", size_text(buffer[:], bytes_in + live_in))
	fact(inside, 76, "bytes out", size_text(buffer[:], bytes_out + live_out))
	fact(inside, 96, "retransmitted", system.format(buffer[:], retransmissions + live_retransmit, " segments"))
	fact(inside, 116, "reset", system.format(buffer[:], resets, resets == 1 ? " connection" : " connections"))

	// The measures, with the cycle counter.
	inside = card(canvas, 648, 8, 320, 176, "MEASURES", "system.nanoseconds", graphics.COLOR_MACHINE)
	fact(inside, 0, "handshake", handshake_last == 0 ? "" : system.format(buffer[:], time_text(other[:], handshake_last), ", least ", handshake_least, " us"), graphics.COLOR_MACHINE)
	fact(inside, 20, "GET /, least", request_least == 0 ? "" : time_text(buffer[:], request_least), graphics.COLOR_MACHINE)
	fact(inside, 40, "/large, best", send_best == 0 ? "" : megabytes(buffer[:], send_best), graphics.COLOR_MACHINE)
	fact(inside, 60, "/sink, best", receive_best == 0 ? "" : megabytes(buffer[:], receive_best), graphics.COLOR_MACHINE)
	fact(inside, 80, "one draw", draw_time == 0 ? "" : time_text(buffer[:], draw_time), graphics.COLOR_TEXT)
	if secret_weak {
		fact(inside, 100, "ISN secret", "weak: the cycle counter", graphics.COLOR_FAILED)
	} else {
		fact(inside, 100, "ISN secret", secret_source, graphics.COLOR_TEXT)
	}

	// The connection table, live, then the connections that ended.
	inside = card(canvas, 8, 192, 960, 472, "CONNECTIONS", "tcp.Table.connections, then the ones that ended", graphics.COLOR_PROGRAM)
	graphics.text(inside, 0, 0, "remote", graphics.COLOR_DIM)
	graphics.text(inside, COLUMN_STATE, 0, "state", graphics.COLOR_DIM)
	right(inside, COLUMN_IN, 0, "in", graphics.COLOR_DIM)
	right(inside, COLUMN_OUT, 0, "out", graphics.COLOR_DIM)
	right(inside, COLUMN_RTT, 0, "srtt", graphics.COLOR_DIM)
	graphics.text(inside, COLUMN_WINDOW, 0, "congestion window", graphics.COLOR_DIM)
	right(inside, COLUMN_RETRANSMIT, 0, "retx", graphics.COLOR_DIM)
	right(inside, COLUMN_PROBES - 16, 0, "probes", graphics.COLOR_DIM)
	graphics.fill(inside, 0, 20, inside.width, 1, graphics.COLOR_TRACK)
	y := 28
	rows := 0
	ROWS :: 16
	for &connection in connections {
		if connection.state == .Closed || rows == ROWS {
			continue
		}
		row_draw(inside, y, &connection, "", rows % 2 == 1)
		y += LINE
		rows += 1
	}
	if rows == 0 {
		graphics.text(inside, 0, y, "no connection open: the table waits for a SYN on the listen port", graphics.COLOR_DIM)
		y += LINE
		rows += 1
	}
	for back in 1 ..= HISTORY {
		if rows == ROWS {
			break
		}
		item := &history[(history_next - back + HISTORY) % HISTORY]
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
		switch how {
		case "reset by the remote":
			how = "reset"
		case "closed, the remote first":
			how = "closed by it"
		case "closed, this server first":
			how = "closed by us"
		}
		row_draw(inside, y, &item.record, how, rows % 2 == 1)
		y += LINE
		rows += 1
	}
	display.present(window)
	took := (system.nanoseconds() - started) / 1000
	if draw_time == 0 {
		system.log("server: one draw of the window: ", took, " us")
	}
	draw_time = took
}
