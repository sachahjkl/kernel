// The console (property 19): a normal program that shows text in a surface.
// The person types expressions of a small language. A command is a function
// with typed parameters and a typed result; it is not a separate program, and
// it does not parse text.
//
// The console has two threads. The first thread reads the keys and draws.
// The second thread runs the lines. During a line, the first thread keeps
// the keys that the person types, shows the time of the line, and stops an
// isolated call when the person presses Escape.
package console

import "../../display"
import "../../graphics"
import "../../system"
import "base:intrinsics"

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
COLOR_STATUS :: 0x1C2A38
COLOR_STATUS_TEXT :: 0xF0C060
STATUS_HEIGHT :: CELL_HEIGHT + 6
PENDING_CAPACITY :: 128
STATUS_INTERVAL :: 100 // Milliseconds between two pictures of the time of a line.

Key :: struct {
	code:      u32,
	character: u8,
}

// The line that the second thread runs. The two threads share this record.
Work :: struct {
	text:     [LINE_CAPACITY]u8,
	count:    int,
	since:    u64, // The time when the line started.
	started:  u32, // The lines that the first thread gave. The second thread waits on this word.
	finished: u32, // The lines that the second thread ran.
	cancel:   u32, // 1: the person pressed Escape. An isolated call waits on this word.
}

work: Work
running: bool // For the first thread: a line runs.
pending: [PENDING_CAPACITY]Key // The keys that the person typed during a line.
pending_count: int
// The second thread adds 1 when it changes the grid or ends a line. The
// first thread waits on this word.
changes: u32
// The grid and the log line: the two threads write them.
screen_lock: system.Lock

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
	window, ok = display.open(ctx, COLUMNS * CELL_WIDTH + 2 * PADDING, ROWS * CELL_HEIGHT + 2 * PADDING + STATUS_HEIGHT, "console")
	if !ok {
		system.log("console: no surface")
		system.stop(1)
	}
	commands_start()
	if _, status := system.thread_start(run_lines, nil); status != .Ok {
		system.log("console: cannot start a thread")
		system.stop(1)
	}
	print("kernel console. A command is a typed function: try help()\n")
	print(PROMPT)
	draw()
	system.log(CONSOLE_MARK)

	drawn: u32
	for {
		seen := intrinsics.volatile_load(&changes)
		changed := false
		for event in display.next_event(&window) {
			if event.kind != .Key || !event.pressed {
				continue
			}
			changed = true
			pressed := Key{event.code, event.character}
			if !running {
				key(pressed)
			} else if event.code == display.KEY_ESCAPE {
				system.log("console: Escape stops the line after ", system.time() - work.since, " ms; keys that wait: ", u64(pending_count))
				intrinsics.atomic_store(&work.cancel, 1)
				system.word_wake(&work.cancel)
			} else if pending_count < PENDING_CAPACITY && (event.code == display.KEY_ENTER || event.code == display.KEY_BACKSPACE || event.character >= ' ' && event.character <= '~') {
				pending[pending_count] = pressed
				pending_count += 1
			}
		}
		if running && intrinsics.volatile_load(&work.finished) == work.started {
			running = false
			changed = true
			print(PROMPT)
			// The keys that waited, until one of them starts a line.
			taken := 0
			for taken < pending_count && !running {
				key(pending[taken])
				taken += 1
			}
			copy(pending[:], pending[taken:pending_count])
			pending_count -= taken
		}
		if changed || running || seen != drawn {
			drawn = seen
			draw()
		}
		wait: system.Wait
		display.wait_events(&wait, &window)
		system.wait_word(&wait, &changes, seen)
		system.wait_end(&wait, running ? system.time() + STATUS_INTERVAL : system.WAIT_FOREVER)
	}
}

// run_lines is the entry of the second thread: it runs each line that the
// first thread gives.
run_lines :: proc "c" (parameter: rawptr) -> ! {
	done: u32
	for {
		system.word_wait(&work.started, done)
		if intrinsics.volatile_load(&work.started) == done {
			continue
		}
		done += 1
		run_line(string(work.text[:work.count]))
		intrinsics.atomic_store(&work.finished, done)
		change()
	}
}

// change tells the first thread that the second thread changed something.
change :: proc "contextless" () {
	intrinsics.atomic_add(&changes, 1)
	system.word_wake(&changes)
}

key :: proc "contextless" (pressed: Key) {
	event := pressed
	system.lock(&screen_lock)
	defer system.unlock(&screen_lock)
	switch {
	case event.code == display.KEY_ENTER:
		system.unlock(&screen_lock)
		print("\n")
		if line_count > 0 {
			slot := history_next % HISTORY_CAPACITY
			history[slot] = line
			history_counts[slot] = line_count
			history_next += 1
			system.log(PROMPT, string(line[:line_count]))
			work.text, work.count = line, line_count
			work.since = system.time()
			intrinsics.atomic_store(&work.cancel, 0)
			running = true
			intrinsics.atomic_add(&work.started, 1)
			system.word_wake(&work.started)
		} else {
			print(PROMPT)
		}
		history_shown = history_next
		line_count = 0
		system.lock(&screen_lock)
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

// put writes characters at the cursor. It does not go to the log. The
// caller holds the lock of the screen.
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
	system.lock(&screen_lock)
	defer {
		system.unlock(&screen_lock)
		if system.thread_record().number != 0 {
			change()
		}
	}
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
	system.lock(&screen_lock)
	grid = {}
	row, column = 0, 0
	system.unlock(&screen_lock)
	change()
}

draw :: proc "contextless" () {
	canvas := window.canvas
	system.lock(&screen_lock)
	defer system.unlock(&screen_lock)
	graphics.clear(canvas, COLOR_BACKGROUND)
	for r in 0 ..< ROWS {
		for c in 0 ..< COLUMNS {
			if grid[r][c] != 0 {
				graphics.character(canvas, PADDING + c * CELL_WIDTH, PADDING + r * CELL_HEIGHT, grid[r][c], COLOR_TEXT)
			}
		}
	}
	if !running {
		graphics.fill(canvas, PADDING + column * CELL_WIDTH, PADDING + row * CELL_HEIGHT, CELL_WIDTH, CELL_HEIGHT, COLOR_CURSOR)
	}
	// The status line: the line that runs, its time, and the keys that wait.
	top := canvas.height - STATUS_HEIGHT
	graphics.fill(canvas, 0, top, canvas.width, STATUS_HEIGHT, COLOR_STATUS)
	if running {
		buffer: [COLUMNS]u8
		elapsed := system.time() - work.since
		status := system.format(buffer[:], "runs ", elapsed / 1000, ".", elapsed / 100 % 10, " s. Escape stops an isolated call. Keys that wait: ")
		x := graphics.text(canvas, PADDING, top + 3, status, COLOR_STATUS_TEXT)
		for waiting in pending[:pending_count] {
			if x + CELL_WIDTH > canvas.width - PADDING {
				break
			}
			if waiting.code == display.KEY_ENTER || waiting.code == display.KEY_BACKSPACE {
				graphics.fill(canvas, x + 1, top + 5, CELL_WIDTH - 2, CELL_HEIGHT - 4, waiting.code == display.KEY_ENTER ? COLOR_CURSOR : COLOR_STATUS_TEXT)
			} else {
				graphics.character(canvas, x, top + 3, waiting.character, COLOR_TEXT)
			}
			x += CELL_WIDTH
		}
	}
	display.present(&window)
}
