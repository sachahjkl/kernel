// A demonstration: drawing with the pointer.
//   left button: draw    right button: erase    click a color at the top    c: clear
//
// This program is also a service: it serves its exports while it runs.
// Another program draws on the paper with isolated calls. The calls execute
// in the one thread of this program, between two input events.
//
// **What it is for.** It is the smallest program that is both an
// application and a service: the same window takes the pointer and the
// calls of the console, with one thread and no lock, because a call runs
// between two events. The top line counts the callers and the calls.
//
// **Start**: `start("paint")` in the console, or the bar of the desktop.
// Then, from the console: `connect("paint")`, `paint.line(0, 0, 479, 295,
// 1)`, `paint.write(20, 20, "hello", 3)`. The log has "paint: ok" when the
// window opens.
//
// **Grants**, as the root service gives them:
//
// - **Serve**: its exports, for the console.
//
// **The paper**: 480 by 296 pixels under a palette of 24 pixels. The
// colors of the palette are numbered 0 to 5: black, red, green, blue,
// yellow, violet. The paper is not kept: a new start gives a clean paper.
package paint

import "contract:errors"
import "support:display"
import "support:graphics"
import "support:interface"
import "support:system"

WIDTH :: 480
HEIGHT :: 320
PALETTE_HEIGHT :: 24
PALETTE_CELL :: 40
COLOR_PAPER :: 0xF4F1EA

@(rodata)
colors := [?]graphics.Color{0x202428, 0xD03838, 0x2E9E4A, 0x2F6FD0, 0xE0A020, 0x9040C0}

drawn: i64 // The lines that calls drew.

// The paper is a picture of this program (a Picture record of the interface
// package). paper_generation changes with each change of its pixels. The
// palette and the top line are records.
PAPER_HEIGHT :: HEIGHT - PALETTE_HEIGHT
paper_pixels: [WIDTH * PAPER_HEIGHT]graphics.Color
paper_generation: u32
pictures: [1]graphics.Canvas
records_now, records_before: [32]interface.Draw_Record
text_now, text_before: [128]u8
window_drawing: interface.Window_Drawing

paper :: proc "contextless" () -> graphics.Canvas {
	paper_generation += 1
	return {pixels = raw_data(paper_pixels[:]), width = WIDTH, height = PAPER_HEIGHT, stride = WIDTH}
}

// line draws a line on the paper, with a color of the palette (0 to 5). A point off the paper is fine: the paper shows the part of the line on it.
//
// The line is 3 pixels wide. A coordinate beyond 4096 in either direction is taken as 4096: the paper is far
// smaller, so the visible part does not change.
//
// - **from_x**, **from_y**: the first point, in pixels of the paper (0, 0 is its top left corner).
// - **to_x**, **to_y**: the last point.
// - **color**: the number of a color of the palette, 0 to 5.
//
// The result is the count of lines that calls drew since the last clear. It fails with -1 and an error record:
// `Bad_Value` when the color is not 0 to 5; the record names the fifth argument.
//
// Example: `paint.line(0, 0, 479, 295, 1)` draws a red diagonal.
@(export, link_name = "line")
line :: proc "c" (from_x, from_y, to_x, to_y, color: i64, error: ^errors.Error_Record) -> i64 {
	if color < 0 || color >= i64(len(colors)) {
		return errors.fail(error, -1, .Bad_Value, .None, 5, color, i64(len(colors) - 1))
	}
	limit :: 4096
	graphics.line(paper(), int(clamp(from_x, -limit, limit)), int(clamp(from_y, -limit, limit)), int(clamp(to_x, -limit, limit)), int(clamp(to_y, -limit, limit)), 3, colors[color])
	drawn += 1
	return drawn
}

// write draws a text on the paper, with a color of the palette (0 to 5).
//
// The text is drawn with the font of the system, from its top left corner. A text that passes the edge of the
// paper is cut there.
//
// - **x**: 0 to 480, the left of the text.
// - **y**: 0 to 320, the top of the text. The paper has 296 rows: a text below row 296 does not show.
// - **text**: the bytes of the text.
// - **color**: the number of a color of the palette, 0 to 5.
//
// The result is the count of bytes of the text. It fails with -1 and an error record: `Bad_Value` when x is not 0
// to 480, when y is not 0 to 320, or when the color is not 0 to 5; the record names the argument.
@(export, link_name = "write")
write :: proc "c" (x, y: i64, text: ^string, color: i64, error: ^errors.Error_Record) -> i64 {
	switch {
	case x < 0 || x > WIDTH:
		return errors.fail(error, -1, .Bad_Value, .None, 1, x, WIDTH)
	case y < 0 || y > HEIGHT:
		return errors.fail(error, -1, .Bad_Value, .None, 2, y, HEIGHT)
	case color < 0 || color >= i64(len(colors)):
		return errors.fail(error, -1, .Bad_Value, .None, 4, color, i64(len(colors) - 1))
	}
	graphics.text(paper(), int(x), int(y), text^, colors[color])
	return i64(len(text))
}

// clear erases the paper.
//
// It also sets the count of lines that [lines](paint.lines) gives back to 0. The key c in the window does the
// same. It has no parameter, no result, and never fails.
@(export, link_name = "clear")
clear :: proc "c" () {
	graphics.clear(paper(), COLOR_PAPER)
	drawn = 0
}

// lines gives the count of lines that calls drew since the last clear.
//
// Only the calls of [line](paint.line) count: the lines that the pointer draws do not. A test draws through
// calls, then reads this count to check that each call ran one time.
@(export, link_name = "lines")
lines :: proc "c" () -> i64 {
	return drawn
}

// The entry of paint: it opens its service and its window, then runs the
// calls and the events of the pointer in one loop until the principal
// closes the window.
//
// With no window it stops with the code 1. Each turn draws the palette, the
// counts of the callers and the paper, then waits for an event or a call.
// The calls run first, then the events: the left button draws, the right
// button erases with a wide line, a click on the palette chooses a color,
// and the key c clears the paper.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	service, _ := system.service_open(ctx)
	window, ok := display.open(ctx, WIDTH, HEIGHT, "paint")
	if !ok {
		system.stop(1)
	}
	pictures[0] = paper()
	graphics.clear(pictures[0], COLOR_PAPER)
	window_drawing = interface.window_drawing_of(records_now[:], records_before[:], text_now[:], text_before[:])
	window_drawing.now.pictures = pictures[:]
	window_drawing.before.pictures = pictures[:]
	color := colors[0]
	last_x, last_y := 0, 0
	drawing := false
	system.log("paint: ok")
	for {
		frame := interface.window_frame_begin(&window_drawing, &window)
		table := frame.table
		for index in 0 ..< len(colors) {
			interface.draw_rectangle(table, index * PALETTE_CELL, 0, PALETTE_CELL, PALETTE_HEIGHT, colors[index])
			if colors[index] == color {
				// The chosen color: a white border of 3 pixels.
				left := index * PALETTE_CELL
				interface.draw_rectangle(table, left, 0, PALETTE_CELL, 3, 0xFFFFFF)
				interface.draw_rectangle(table, left, PALETTE_HEIGHT - 3, PALETTE_CELL, 3, 0xFFFFFF)
				interface.draw_rectangle(table, left, 3, 3, PALETTE_HEIGHT - 6, 0xFFFFFF)
				interface.draw_rectangle(table, left + PALETTE_CELL - 3, 3, 3, PALETTE_HEIGHT - 6, 0xFFFFFF)
			}
		}
		// The rest of the top line: the keys, and the calls that this program served.
		x := len(colors) * PALETTE_CELL
		interface.draw_rectangle(table, x, 0, WIDTH - x, PALETTE_HEIGHT, COLOR_PAPER)
		x = interface.draw_text(table, x + 10, 4, "c: clear", 0x606468)
		if service.connected != 0 || service.calls != 0 {
			x = interface.draw_text(table, x + 16, 4, "callers ", 0x606468)
			x = interface.draw_unsigned(table, x, 4, u64(service.connected), 0x2F6FD0)
			x = interface.draw_text(table, x + 8, 4, "calls ", 0x606468)
			interface.draw_unsigned(table, x, 4, service.calls, 0x2F6FD0)
		}
		interface.draw_picture(table, 0, PALETTE_HEIGHT, 0, paper_generation)
		interface.window_frame_end(&window_drawing, &frame, &window)

		wait: system.Wait
		display.wait_events(&wait, &window)
		system.service_wait(&wait, &service)
		system.wait_end(&wait)
		system.service_run(&service)
		for event in display.next_event(&window) {
			#partial switch event.kind {
			case .Key:
				if event.pressed && event.character == 'c' {
					clear()
				}
			case .Pointer:
				if event.buttons == 0 {
					drawing = false
					continue
				}
				if event.y < PALETTE_HEIGHT && !drawing {
					if event.x >= 0 && event.x / PALETTE_CELL < len(colors) {
						color = colors[event.x / PALETTE_CELL]
					}
					continue
				}
				erase := event.buttons & display.BUTTON_RIGHT != 0
				y := max(event.y, PALETTE_HEIGHT + 2)
				if drawing {
					graphics.line(paper(), last_x, last_y - PALETTE_HEIGHT, event.x, y - PALETTE_HEIGHT, erase ? 12 : 3, erase ? COLOR_PAPER : color)
				}
				last_x, last_y, drawing = event.x, y, true
			}
		}
	}
}
