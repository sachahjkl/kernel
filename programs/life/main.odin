// A demonstration: Conway's Game of Life.
//   pointer, left button: draw cells    space: pause    r: random    c: clear
//
// This program is also a service: another program reads and changes the
// cells with isolated calls, while the game runs.
package life

import "support:display"
import "support:graphics"
import "support:interface"
import "support:system"

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
	board_generation += 1
}

// population gives the count of live cells.
@(export, link_name = "population")
population :: proc "c" () -> i64 {
	count: i64
	for &line in cells[shown] {
		for cell in line {
			count += i64(cell)
		}
	}
	return count
}

// empty removes all the cells.
@(export, link_name = "empty")
empty :: proc "c" () {
	cells[shown] = {}
	board_generation += 1
}

// glider adds a glider: five cells that move down and right.
@(export, link_name = "glider")
glider :: proc "c" (column, row: i64) {
	shape := [5][2]i64{{1, 0}, {2, 1}, {0, 2}, {1, 2}, {2, 2}}
	for cell in shape {
		cells[shown][u64(row + cell[1]) % ROWS][u64(column + cell[0]) % COLUMNS] = 1
	}
	board_generation += 1
}

// The window is built with the interface package (docs/INTERFACE.md): the
// board is a picture of pixels of this program, and the window shows it
// with one Picture record. Its generation changes when a cell changes, so
// a frame with no change draws nothing.
board_pixels: [COLUMNS * CELL * ROWS * CELL]graphics.Color
board_generation: u32
board_drawn_generation: u32 = max(u32) // The generation that the board pixels show.
records_now, records_before: [4]interface.Draw_Record
text_now, text_before: [16]u8
pictures: [1]graphics.Canvas
drawing: interface.Window_Drawing

// board_draw draws the cells into the board picture, when they changed.
board_draw :: proc "contextless" () {
	if board_drawn_generation == board_generation {
		return
	}
	board := pictures[0]
	graphics.clear(board, 0x0C1210)
	for y in 0 ..< ROWS {
		for x in 0 ..< COLUMNS {
			if cells[shown][y][x] != 0 {
				graphics.fill(board, x * CELL, y * CELL, CELL - 1, CELL - 1, 0x60E090)
			}
		}
	}
	board_drawn_generation = board_generation
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	service, _ := system.service_open(ctx)
	window, ok := display.open(ctx, COLUMNS * CELL, ROWS * CELL, "life")
	if !ok {
		system.stop(1)
	}
	pictures[0] = {pixels = raw_data(board_pixels[:]), width = COLUMNS * CELL, height = ROWS * CELL, stride = COLUMNS * CELL}
	drawing = interface.window_drawing_of(records_now[:], records_before[:], text_now[:], text_before[:])
	drawing.now.pictures = pictures[:]
	drawing.before.pictures = pictures[:]
	random_state = system.time() * 0x9E3779B97F4A7C15 + 0x1234567
	fill_random()
	paused := false
	next := system.time()
	logged := false
	for {
		system.service_run(&service)
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
						empty()
					}
				}
			case .Pointer:
				x, y := event.x / CELL, event.y / CELL
				if event.buttons & display.BUTTON_LEFT != 0 && event.x >= 0 && event.y >= 0 && x < COLUMNS && y < ROWS {
					cells[shown][y][x] = 1
					board_generation += 1
				}
			}
		}
		now := system.time()
		if !paused && now >= next {
			step()
			board_generation += 1
			next = now + STEP_INTERVAL
		}
		board_draw()
		frame := interface.window_frame_begin(&drawing, &window)
		interface.draw_picture(frame.table, 0, 0, 0, board_generation)
		interface.window_frame_end(&drawing, &frame, &window)
		if !logged {
			system.log("life: ok")
			logged = true
		}
		wait: system.Wait
		display.wait_events(&wait, &window)
		system.service_wait(&wait, &service)
		system.wait_end(&wait, paused ? system.WAIT_FOREVER : next)
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
