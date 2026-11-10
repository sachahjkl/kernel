// A demonstration: drawing with the pointer.
//   left button: draw    right button: erase    click a color at the top    c: clear
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

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	window, ok := display.open(ctx, WIDTH, HEIGHT, "paint")
	if !ok {
		system.stop(1)
	}
	canvas := window.canvas
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
		graphics.text(canvas, len(colors) * PALETTE_CELL + 10, 4, "c: clear", 0x606468)
		display.present(&window)
		display.wait(&window)
		for event in display.next_event(&window) {
			#partial switch event.kind {
			case .Key:
				if event.pressed && event.character == 'c' {
					graphics.clear(canvas, COLOR_PAPER)
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
