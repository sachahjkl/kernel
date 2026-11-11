package remote_service

import "contract:isolated"
import "contract:remote"
import "support:display"
import "support:graphics"
import "support:system"

// The window follows docs/DESIGN.md: rectangles only, the grid of 8 pixels,
// three cards with a title in the accent of their concept and a caption
// that names their record, names in the dim color, values in the text
// color, the state of a call in the color of a program that runs or in the
// color "failed", with a text that says the same.

WIDTH :: 720
HEIGHT :: 480

COLOR_BACKGROUND :: 0x0B1018
COLOR_POINT :: 0x18212D
COLOR_CARD_TOP :: 0x17212E
COLOR_CARD :: 0x111822
COLOR_TRACK :: 0x1C2633
COLOR_TEXT :: 0xDCE4EC
COLOR_DIM :: 0x7C8A99
COLOR_PROGRAM :: 0x58D878
COLOR_MEMORY :: 0x38C0B0
COLOR_FAILED :: 0xF06060

CARD_MARGIN :: 16
CARD_TITLE :: 40
LINE :: 16

mix :: proc "contextless" (first, second: graphics.Color, level: u32) -> graphics.Color {
	part :: proc "contextless" (a, b, level: u32) -> u32 {
		return (a * (255 - level) + b * level) / 255
	}
	return graphics.rgb(part(first >> 16 & 0xFF, second >> 16 & 0xFF, level), part(first >> 8 & 0xFF, second >> 8 & 0xFF, level), part(first & 0xFF, second & 0xFF, level))
}

// shade gives a color nearer to black (percent under 100) or nearer to
// white (percent from 100 to 200).
shade :: proc "contextless" (color: graphics.Color, percent: u32) -> graphics.Color {
	return percent <= 100 ? mix(0x000000, color, percent * 255 / 100) : mix(color, 0xFFFFFF, (min(percent, 200) - 100) * 255 / 100)
}

// block draws a rectangle whose color goes from top to bottom.
block :: proc "contextless" (canvas: graphics.Canvas, x, y, width, height: int, top, bottom: graphics.Color) {
	for row in 0 ..< height {
		graphics.fill(canvas, x, y + row, width, 1, mix(top, bottom, u32(row * 255 / max(height - 1, 1))))
	}
}

// card draws the frame of one subject, and gives the place of its content.
card :: proc "contextless" (canvas: graphics.Canvas, x, y, width, height: int, title, caption: string, accent: graphics.Color) -> graphics.Canvas {
	block(canvas, x, y, width, height, shade(accent, 28), shade(accent, 14))
	block(canvas, x + 1, y + 1, width - 2, height - 2, COLOR_CARD_TOP, COLOR_CARD)
	block(canvas, x + CARD_MARGIN, y + 12, 4, 16, shade(accent, 130), accent)
	after := graphics.text(canvas, x + CARD_MARGIN + 12, y + 12, title, accent)
	graphics.text(canvas, after + 16, y + 12, caption, COLOR_DIM)
	return graphics.view(canvas, x + CARD_MARGIN, y + CARD_TITLE, width - 2 * CARD_MARGIN, height - CARD_TITLE - 8)
}

// large draws characters three times their size.
large :: proc "contextless" (canvas: graphics.Canvas, x, y: int, characters: string, color: graphics.Color) -> int {
	SCALE :: 3
	at := x
	for index in 0 ..< len(characters) {
		value := characters[index]
		if value >= graphics.FONT_FIRST && value <= graphics.FONT_LAST {
			glyph := graphics.font[value - graphics.FONT_FIRST]
			for bits, row in glyph {
				for column in 0 ..< graphics.CELL_WIDTH {
					if bits << uint(column) & 0x80 != 0 {
						graphics.fill(canvas, at + column * SCALE, y + row * SCALE, SCALE, SCALE, color)
					}
				}
			}
		}
		at += graphics.CELL_WIDTH * SCALE
	}
	return at
}

// right draws a number with its unit, the end at x.
right :: proc "contextless" (canvas: graphics.Canvas, x, y: int, color: graphics.Color, parts: ..system.Part) {
	buffer: [48]u8
	text := system.format(buffer[:], ..parts)
	graphics.text(canvas, x - graphics.text_width(text), y, text, color)
}

// hash_color gives the color of a module from its hash (docs/DESIGN.md:
// a thing with an identity takes its color from it).
hash_color :: proc "contextless" (hash: [32]u8) -> graphics.Color {
	return mix(graphics.rgb(u32(hash[0]) | 0x40, u32(hash[1]) | 0x40, u32(hash[2]) | 0x40), COLOR_TEXT, 64)
}

draw :: proc "contextless" (window: ^display.Window) {
	canvas := window.canvas
	graphics.clear(canvas, COLOR_BACKGROUND)
	for y := 12; y < HEIGHT; y += 24 {
		for x := 12; x < WIDTH; x += 24 {
			graphics.fill(canvas, x, y, 2, 2, COLOR_POINT)
		}
	}
	buffer: [64]u8

	// The calls of the host, with the large number of the card.
	inside := card(canvas, 8, 8, WIDTH - 16, 152, "CALLS FROM THE HOST", "remote.Request -> isolated call -> remote.Answer", COLOR_PROGRAM)
	after := large(inside, 0, 0, system.format(buffer[:], counts.calls), COLOR_PROGRAM)
	graphics.text(inside, 0, 56, "calls that ran", COLOR_DIM)
	COLUMN :: 232
	VALUE :: 456
	_ = after
	Fact :: struct {
		name:  string,
		value: u64,
		unit:  string,
	}
	facts := [?]Fact {
		{"requests from 10.0.2.2", counts.requests, ""},
		{"datagrams of the answers", counts.datagrams, ""},
		{"refused by this program", counts.refused, ""},
		{"sent again, not run again", counts.repeated, ""},
		{"bytes in", counts.bytes_in, " B"},
		{"bytes out", counts.bytes_out, " B"},
	}
	for item, index in facts {
		graphics.text(inside, COLUMN, index * LINE, item.name, COLOR_DIM)
		right(inside, VALUE + 64, index * LINE, item.name == "refused by this program" && item.value != 0 ? COLOR_FAILED : COLOR_TEXT, item.value, item.unit)
	}
	graphics.text(inside, VALUE + 96, 0, "endpoint", COLOR_DIM)
	graphics.text(inside, VALUE + 96, LINE, system.format(buffer[:], "port ", local_port), COLOR_TEXT)
	graphics.text(inside, VALUE + 96, 2 * LINE, "grant", COLOR_DIM)
	graphics.text(inside, VALUE + 96, 3 * LINE, system.format(buffer[:], "10.0.2.2:", u64(remote.HOST_PORT)), COLOR_TEXT)
	// One bar: the width of each part is its count of requests.
	BAR_Y :: 96
	bar := inside.width
	graphics.fill(inside, 0, BAR_Y, bar, 8, COLOR_TRACK)
	total := max(counts.requests, 1)
	ran := int(u64(bar) * (counts.calls - counts.failed) / total)
	failed := int(u64(bar) * counts.failed / total)
	refused := int(u64(bar) * counts.refused / total)
	block(inside, 0, BAR_Y, ran, 8, shade(COLOR_PROGRAM, 125), shade(COLOR_PROGRAM, 78))
	block(inside, ran, BAR_Y, failed, 8, shade(COLOR_PROGRAM, 70), shade(COLOR_PROGRAM, 50))
	block(inside, ran + failed, BAR_Y, refused, 8, shade(COLOR_FAILED, 125), shade(COLOR_FAILED, 78))
	x := graphics.text(inside, 0, BAR_Y + 12, system.format(buffer[:], counts.calls - counts.failed, " gave a result"), COLOR_PROGRAM)
	x = graphics.text(inside, x + 24, BAR_Y + 12, system.format(buffer[:], counts.failed, " gave an error record"), shade(COLOR_PROGRAM, 70))
	graphics.text(inside, x + 24, BAR_Y + 12, system.format(buffer[:], counts.refused, " refused"), COLOR_FAILED)

	// The connections that the root service made.
	inside = card(canvas, 8, 168, WIDTH - 16, 112, "CONNECTIONS", "root: Connect, a call ring and a call region of 64 KiB", COLOR_MEMORY)
	shown := 0
	for &connection in connections {
		if connection.name[0] == 0 {
			continue
		}
		y := shown * LINE
		graphics.fill(inside, 0, y + 2, 12, 12, hash_color(connection.hash))
		graphics.text(inside, 24, y, remote.name_text(&connection.name), COLOR_TEXT)
		hash: [16]u8
		digits := system.HEX_DIGITS
		for index in 0 ..< 8 {
			hash[2 * index] = digits[connection.hash[index] >> 4]
			hash[2 * index + 1] = digits[connection.hash[index] & 15]
		}
		graphics.text(inside, 160, y, string(hash[:]), hash_color(connection.hash))
		right(inside, VALUE + 64, y, COLOR_TEXT, connection.count, " calls")
		shown += 1
	}
	if shown == 0 {
		graphics.text(inside, 0, 0, "none yet: a connection starts at the first call to a service", COLOR_DIM)
	}

	// The last calls, the last one first.
	inside = card(canvas, 8, 288, WIDTH - 16, 184, "LAST CALLS", "remote.Answer: status, value, bytes, time in this program", COLOR_PROGRAM)
	for row in 0 ..< min(recent_count, RECENT_CAPACITY) {
		item := &recent[(recent_count - 1 - row) % RECENT_CAPACITY]
		y := int(row) * LINE
		graphics.text(inside, 0, y, item.service[0] != 0 ? remote.name_text(&item.service) : "-", COLOR_TEXT)
		state, color := "ok", graphics.Color(COLOR_PROGRAM)
		switch {
		case item.status == .Refused:
			state, color = "refused", COLOR_FAILED
		case isolated.Status(item.call_status) != .Ok:
			state, color = "refused by the service", COLOR_FAILED
		case item.error != 0:
			state, color = "error record", shade(COLOR_PROGRAM, 70)
		}
		if item.status != .Refused {
			graphics.text(inside, 96, y, system.format(buffer[:], "export ", u64(item.export)), COLOR_DIM)
		}
		graphics.fill(inside, 200, y + 4, 8, 8, color)
		graphics.text(inside, 216, y, state, color)
		if item.text_count != 0 {
			at := 216 + graphics.text_width(state) + 16
			graphics.text(inside, at, y, string(item.text[:min(item.text_count, (inside.width - at) / graphics.CELL_WIDTH)]), COLOR_DIM)
		} else {
			right(inside, 488, y, COLOR_TEXT, item.value)
			right(inside, 576, y, COLOR_TEXT, item.bytes, " B")
			right(inside, inside.width, y, COLOR_TEXT, item.microseconds, " us")
		}
	}
	if recent_count == 0 {
		graphics.text(inside, 0, 0, "none yet: kerneltool call \"monitor.programs()\" on the host", COLOR_DIM)
	}
	display.present(window)
}
