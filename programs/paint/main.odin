// A demonstration: drawing with the pointer.
//   left button: draw    right button: erase    click a color at the top    c: clear
//
// This program is also a service: it serves its exports while it runs.
// Another program draws on the paper with isolated calls. The calls execute
// in the one thread of this program, between two input events.
package paint

import "../../display"
import "../../graphics"
import "../../system"

WIDTH :: 480
HEIGHT :: 320
PALETTE_HEIGHT :: 24
PALETTE_CELL :: 40
COLOR_PAPER :: 0xF4F1EA

@(rodata)
colors := [?]graphics.Color{0x202428, 0xD03838, 0x2E9E4A, 0x2F6FD0, 0xE0A020, 0x9040C0}

canvas: graphics.Canvas
drawn: i64 // The lines that calls drew.

// The part of the canvas under the palette.
paper :: proc "contextless" () -> graphics.Canvas {
	return {pixels = canvas.pixels[PALETTE_HEIGHT * canvas.stride:], width = canvas.width, height = canvas.height - PALETTE_HEIGHT, stride = canvas.stride}
}

palette_color :: proc "contextless" (color: i64) -> graphics.Color {
	return colors[u64(color) % len(colors)]
}

// line draws a line on the paper, with a color of the palette (0 to 5).
@(export, link_name = "line")
line :: proc "c" (from_x, from_y, to_x, to_y, color: i64) {
	limit :: 4096
	graphics.line(paper(), int(clamp(from_x, -limit, limit)), int(clamp(from_y, -limit, limit)), int(clamp(to_x, -limit, limit)), int(clamp(to_y, -limit, limit)), 3, palette_color(color))
	drawn += 1
}

// write draws a text on the paper, with a color of the palette (0 to 5).
@(export, link_name = "write")
write :: proc "c" (x, y: i64, text: ^string, color: i64) {
	if x < 0 || y < 0 || x > WIDTH || y > HEIGHT {
		return
	}
	graphics.text(paper(), int(x), int(y), text^, palette_color(color))
}

// clear erases the paper.
@(export, link_name = "clear")
clear :: proc "c" () {
	graphics.clear(paper(), COLOR_PAPER)
	drawn = 0
}

// lines gives the count of lines that calls drew since the last clear.
@(export, link_name = "lines")
lines :: proc "c" () -> i64 {
	return drawn
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	service, _ := system.service_open(ctx)
	window, ok := display.open(ctx, WIDTH, HEIGHT, "paint")
	if !ok {
		system.stop(1)
	}
	canvas = window.canvas
	graphics.clear(canvas, COLOR_PAPER)
	color := colors[0]
	last_x, last_y := 0, 0
	drawing := false
	system.log("paint: ok")
	for {
		for index in 0 ..< len(colors) {
			graphics.fill(canvas, index * PALETTE_CELL, 0, PALETTE_CELL, PALETTE_HEIGHT, colors[index])
			if colors[index] == color {
				graphics.outline(canvas, index * PALETTE_CELL, 0, PALETTE_CELL, PALETTE_HEIGHT, 3, 0xFFFFFF)
			}
		}
		// The rest of the top line: the keys, and the calls that this program served.
		x := len(colors) * PALETTE_CELL
		graphics.fill(canvas, x, 0, WIDTH - x, PALETTE_HEIGHT, COLOR_PAPER)
		x = graphics.text(canvas, x + 10, 4, "c: clear", 0x606468)
		if service.connected != 0 || service.calls != 0 {
			x = graphics.text(canvas, x + 16, 4, "callers ", 0x606468)
			x = graphics.unsigned(canvas, x, 4, u64(service.connected), 0x2F6FD0)
			x = graphics.text(canvas, x + 8, 4, "calls ", 0x606468)
			graphics.unsigned(canvas, x, 4, service.calls, 0x2F6FD0)
		}
		display.present(&window)

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
					graphics.line(canvas, last_x, last_y, event.x, y, erase ? 12 : 3, erase ? COLOR_PAPER : color)
				}
				last_x, last_y, drawing = event.x, y, true
			}
		}
	}
}
