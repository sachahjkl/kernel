// A demonstration: Conway's Game of Life.
//   pointer, left button: draw cells    space: pause    r: random    c: clear
package life

import "../../display"
import "../../graphics"
import "../../system"

COLUMNS :: 96
ROWS :: 64
CELL :: 5
STEP_INTERVAL :: 80

cells: [2][ROWS][COLUMNS]u8
shown: int
random_state: u64

random :: proc "contextless" () -> u64 {
	random_state ~= random_state << 13
	random_state ~= random_state >> 7
	random_state ~= random_state << 17
	return random_state
}

fill_random :: proc "contextless" () {
	for &line in cells[shown] {
		for &cell in line {
			cell = u8(random() % 4 == 0)
		}
	}
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	window, ok := display.open(ctx, COLUMNS * CELL, ROWS * CELL, "life")
	if !ok {
		system.stop(1)
	}
	random_state = system.time() * 0x9E3779B97F4A7C15 + 0x1234567
	fill_random()
	paused := false
	next := system.time()
	logged := false
	for {
		for event in display.next_event(&window) {
			#partial switch event.kind {
			case .Key:
				if event.pressed {
					switch event.character {
					case ' ':
						paused = !paused
					case 'r':
						fill_random()
					case 'c':
						cells[shown] = {}
					}
				}
			case .Pointer:
				x, y := event.x / CELL, event.y / CELL
				if event.buttons & display.BUTTON_LEFT != 0 && event.x >= 0 && event.y >= 0 && x < COLUMNS && y < ROWS {
					cells[shown][y][x] = 1
				}
			}
		}
		now := system.time()
		if !paused && now >= next {
			step()
			next = now + STEP_INTERVAL
		}
		graphics.clear(window.canvas, 0x0C1210)
		for y in 0 ..< ROWS {
			for x in 0 ..< COLUMNS {
				if cells[shown][y][x] != 0 {
					graphics.fill(window.canvas, x * CELL, y * CELL, CELL - 1, CELL - 1, 0x60E090)
				}
			}
		}
		display.present(&window)
		if !logged {
			system.log("life: ok")
			logged = true
		}
		system.wait(paused ? system.WAIT_FOREVER : next)
	}
}

step :: proc "contextless" () {
	from := &cells[shown]
	to := &cells[1 - shown]
	for y in 0 ..< ROWS {
		for x in 0 ..< COLUMNS {
			neighbours := 0
			for dy in -1 ..= 1 {
				for dx in -1 ..= 1 {
					if dx != 0 || dy != 0 {
						neighbours += int(from[(y + dy + ROWS) % ROWS][(x + dx + COLUMNS) % COLUMNS])
					}
				}
			}
			to[y][x] = u8(neighbours == 3 || neighbours == 2 && from[y][x] != 0)
		}
	}
	shown = 1 - shown
}
