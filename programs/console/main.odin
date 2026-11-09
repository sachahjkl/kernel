// The console (property 19): a normal program that shows text in a surface.
// The person types expressions of a small language. A command is a function
// with typed parameters and a typed result; it is not a separate program, and
// it does not parse text.
package console

import "../../display"
import "../../graphics"
import "../../system"

CONSOLE_MARK :: "console: ready"

COLUMNS :: 96
ROWS :: 26
CELL_WIDTH :: graphics.CELL_WIDTH
CELL_HEIGHT :: graphics.CELL_HEIGHT
PADDING :: 6
LINE_CAPACITY :: 120
HISTORY_CAPACITY :: 8
PROMPT :: "> "

COLOR_BACKGROUND :: 0x101820
COLOR_TEXT :: 0xD8E0E8
COLOR_CURSOR :: 0x7FC8FF

window: display.Window
grid: [ROWS][COLUMNS]u8
row, column: int
line: [LINE_CAPACITY]u8
line_count: int
history: [HISTORY_CAPACITY][LINE_CAPACITY]u8
history_counts: [HISTORY_CAPACITY]int
history_next: int // Lines entered so far.
history_shown: int
log_line: [COLUMNS * 2]u8 // The output line that goes to the log of the kernel when it ends.
log_count: int

ctx: ^system.Context

@(export, link_name = "entry")
entry :: proc "c" (start_context: ^system.Context) -> ! {
	ctx = start_context
	ok: bool
	window, ok = display.open(ctx, COLUMNS * CELL_WIDTH + 2 * PADDING, ROWS * CELL_HEIGHT + 2 * PADDING, "console")
	if !ok {
		system.log("console: no surface")
		system.stop(1)
	}
	commands_start()
	print("kernel console. A command is a typed function: try help()\n")
	print(PROMPT)
	draw()
	system.log(CONSOLE_MARK)

	for {
		changed := false
		for event in display.next_event(&window) {
			if event.kind == .Key && event.pressed {
				key(event)
				changed = true
			}
		}
		if changed {
			draw()
		}
		system.wait()
	}
}

key :: proc "contextless" (event: display.Event) {
	switch {
	case event.code == display.KEY_ENTER:
		print("\n")
		entered := string(line[:line_count])
		if line_count > 0 {
			slot := history_next % HISTORY_CAPACITY
			history[slot] = line
			history_counts[slot] = line_count
			history_next += 1
			system.log(PROMPT, entered)
			run_line(entered)
		}
		history_shown = history_next
		line_count = 0
		print(PROMPT)
	case event.code == display.KEY_BACKSPACE:
		if line_count > 0 {
			line_count -= 1
			erase()
		}
	case event.code == display.KEY_UP || event.code == display.KEY_DOWN:
		shown := history_shown + (event.code == display.KEY_UP ? -1 : 1)
		if shown < 0 || shown < history_next - HISTORY_CAPACITY || shown > history_next {
			return
		}
		for line_count > 0 {
			line_count -= 1
			erase()
		}
		history_shown = shown
		if shown < history_next {
			line = history[shown % HISTORY_CAPACITY]
			line_count = history_counts[shown % HISTORY_CAPACITY]
			put(string(line[:line_count]))
		}
	case event.character >= ' ' && event.character <= '~':
		if line_count < LINE_CAPACITY {
			line[line_count] = event.character
			line_count += 1
			put(string([]u8{event.character}))
		}
	}
}

// put writes characters at the cursor. It does not go to the log.
put :: proc "contextless" (text: string) {
	for i in 0 ..< len(text) {
		if text[i] == '\n' {
			new_line()
			continue
		}
		if column == COLUMNS {
			new_line()
		}
		grid[row][column] = text[i]
		column += 1
	}
}

erase :: proc "contextless" () {
	if column == 0 && row > 0 {
		row -= 1
		column = COLUMNS
	}
	if column > 0 {
		column -= 1
		grid[row][column] = 0
	}
}

new_line :: proc "contextless" () {
	column = 0
	if row < ROWS - 1 {
		row += 1
		return
	}
	for r in 1 ..< ROWS {
		grid[r - 1] = grid[r]
	}
	grid[ROWS - 1] = {}
}

// print writes output: on the surface, and each full line on the log of the kernel.
print :: proc "contextless" (parts: ..system.Part) {
	buffer: [256]u8
	text := system.format(buffer[:], ..parts)
	put(text)
	for i in 0 ..< len(text) {
		if text[i] == '\n' {
			if log_count > 0 {
				system.log(string(log_line[:log_count]))
			}
			log_count = 0
		} else if log_count < len(log_line) {
			log_line[log_count] = text[i]
			log_count += 1
		}
	}
	if text == PROMPT {
		log_count = 0
	}
}

clear_grid :: proc "contextless" () {
	grid = {}
	row, column = 0, 0
}

draw :: proc "contextless" () {
	canvas := window.canvas
	graphics.clear(canvas, COLOR_BACKGROUND)
	for r in 0 ..< ROWS {
		for c in 0 ..< COLUMNS {
			if grid[r][c] != 0 {
				graphics.character(canvas, PADDING + c * CELL_WIDTH, PADDING + r * CELL_HEIGHT, grid[r][c], COLOR_TEXT)
			}
		}
	}
	graphics.fill(canvas, PADDING + column * CELL_WIDTH, PADDING + row * CELL_HEIGHT, CELL_WIDTH, CELL_HEIGHT, COLOR_CURSOR)
	display.present(&window)
}
