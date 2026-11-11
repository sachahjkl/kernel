// The terminal: it shows the text that a program gives as records, and it
// gives the keys of the person to that program (support/terminal).
//
// The terminal starts no program. The root service starts a program and its
// terminal, and gives the same terminal ring and text region to the two.
// The terminal holds a surface, these two memory objects, and a handle that
// reads the state of the program: it has nothing of the role of the program.
// The name of the program, the size of the text and what the window shows
// are values of its context.
//
// Keys: Page Up and Page Down move the view. Each other key goes to the
// program, and the view returns to the last lines.
//
// Two threads:
//   the reader   It reads the records of the terminal ring and keeps the
//                lines. It owns the lines: no lock exists.
//   the drawer   The first thread. At the rate of the screen it asks the
//                reader for a view: the cells of the rows that the window
//                shows. Then it draws the view. The reader makes the view
//                between two groups of records: some microseconds.
//                The surface has two pictures: the compositor never reads
//                a picture that the drawer changes.
//
// The reader does not wait for a picture, so the program that writes does
// not wait for a picture. A line that the window does not show costs one
// copy of its bytes, and no pixel.
//
// The lines that the terminal keeps are in three areas of fixed size: the
// lines, the runs, the bytes. Each area starts again at its first place
// when it is full: the oldest lines go.
package terminal_program

import "support:display"
import "support:graphics"
import "contract:ring"
import "support:system"
import "support:terminal"
import "base:intrinsics"

COLUMNS_LIMIT :: terminal.COLUMNS_LIMIT
ROWS_LIMIT :: terminal.ROWS_LIMIT
CELL_WIDTH :: graphics.CELL_WIDTH
CELL_HEIGHT :: graphics.CELL_HEIGHT

MARGIN :: 8
HEAD_HEIGHT :: 72
TEXT_X :: MARGIN
SCROLL_WIDTH :: 8

// What the root service chose for this terminal, and the places that
// follow from it.
program_name: string
name_bytes: system.Name
columns, rows: int
measure: bool // The window shows the rates of the program, and the status on its own line.
text_y, text_width, text_height, scroll_x, status_y, hint_y, width, height, graph_x: int

layout :: proc "contextless" () {
	text_y = measure ? HEAD_HEIGHT : MARGIN
	text_width = columns * CELL_WIDTH
	text_height = rows * CELL_HEIGHT
	scroll_x = TEXT_X + text_width + 6
	status_y = text_y + text_height + 8
	hint_y = measure ? status_y + 24 : status_y
	width = scroll_x + SCROLL_WIDTH + MARGIN
	height = hint_y + CELL_HEIGHT + 6
	graph_x = width - MARGIN - SCROLL_WIDTH - 6 - HISTORY * GRAPH_BAR
}

FRAME_TIME :: 16 // Milliseconds.
SAMPLE_TIME :: 250 // Milliseconds of one measure of the rates.
HISTORY :: 48 // The measures that the graph shows.
GRAPH_BAR :: 4
GRAPH_HEIGHT :: 48

COLOR_GRAPH :: 0x58D878
COLOR_GRAPH_DIM :: 0x1C3A28
COLOR_THUMB :: 0x5A6878
COLOR_STOPPED :: 0xF07060
COLOR_HELD :: 0xF0C050
COLOR_CURSOR :: 0x7FC8FF

// The color of each tone.
@(rodata)
tone_colors := [terminal.Tone]graphics.Color {
	.Default = 0xC8D0D8,
	.Dim     = 0x6C7986,
	.Strong  = 0xFFFFFF,
	.Good    = 0x58D878,
	.Warning = 0xF0C050,
	.Bad     = 0xF06060,
	.Accent  = 0x58B8F0,
	.Number  = 0x8C98A6,
}

// ---- The lines that the terminal keeps. Only the reader uses them.

LINE_CAPACITY :: 1 << 16
RUN_CAPACITY :: 1 << 18
BYTE_CAPACITY :: 1 << 23
LINE_RUNS :: 1024 // A line of more runs continues on a new line.

Run :: struct {
	start:  u64, // The count of bytes that the terminal kept before this run.
	style:  terminal.Style,
	length: u32,
}

Line :: struct {
	first_run: u64, // The count of runs that the terminal kept before this line.
	run_count: u32,
	length:    u32, // Characters.
}

lines: [^]Line
runs: [^]Run
bytes: []u8
lines_written: u64 // The lines that ended. lines[lines_written] is the line that the program writes now.
runs_written: u64
bytes_written: u64
oldest: u64 // The oldest line that the terminal still has.
records_read: u64
source: ring.Ring // The terminal ring.
source_text: []u8 // The text region, read-only.
source_read: u64 // The bytes that the reader took from the text region.

Status_Line :: struct {
	text:   [COLUMNS_LIMIT]u8,
	length: int,
	value:  u64,
	total:  u64,
	style:  terminal.Style,
}
status_line: Status_Line

// The line that the program changes (terminal.Kind.Edit).
Edit_Line :: struct {
	text:       [terminal.RUN_LIMIT]u8,
	length:     int,
	cursor:     int,
	has_cursor: bool,
	style:      terminal.Style,
}
edit_line: Edit_Line

// ---- What the drawer asks, and the view that the reader gives.

Request :: struct {
	follow: bool, // The view shows the last lines.
	top:    u64, // If not follow: the line of the first row.
	stopped: bool, // The program stopped: the reader writes a line that says it.
	code:    u32,
}

Cell :: struct {
	character: u8,
	reverse:   bool,
	color:     graphics.Color,
}

View :: struct {
	cells:   [ROWS_LIMIT][COLUMNS_LIMIT]Cell,
	top:     u64,
	count:   u64, // The lines since the start.
	oldest:  u64,
	gone:    bool, // The terminal does not have the lines of the cells now.
	records: u64,
	bytes:   u64,
	status:  Status_Line,
}

request: Request
view: View
request_word: u32 // 1: the drawer asks for a view. The reader sets 0 when the view is ready.
reader_idle: u32 // The reader waits, or will wait.
drawer_waits: u32
// The reader adds 1 after each group of records. The drawer draws a new
// picture only after a change: a terminal that receives nothing draws nothing.
activity: u32
drawer_idle: u32

line_valid :: proc "contextless" (index: u64) -> bool {
	line := lines[index & (LINE_CAPACITY - 1)]
	if line.run_count == 0 {
		return true
	}
	return runs_written - line.first_run <= RUN_CAPACITY && bytes_written - runs[line.first_run & (RUN_CAPACITY - 1)].start <= BYTE_CAPACITY
}

line_end :: proc "contextless" () {
	lines_written += 1
	lines[lines_written & (LINE_CAPACITY - 1)] = {first_run = runs_written}
}

// take gives the next count bytes of the text region as two parts: the
// text region starts again at its first byte after its last.
take :: proc "contextless" (count: u32) -> (first, second: []u8) {
	count := int(min(count, terminal.RUN_LIMIT))
	place := int(source_read % terminal.TEXT_SIZE)
	size := min(count, terminal.TEXT_SIZE - place)
	source_read += u64(count)
	return source_text[place:][:size], source_text[:count - size]
}

// put copies bytes to the bytes that the terminal keeps. The program can
// change the text region at any time: the terminal uses only this copy.
put :: proc "contextless" (text: []u8) {
	place := int(bytes_written & (BYTE_CAPACITY - 1))
	size := min(len(text), BYTE_CAPACITY - place)
	copy(bytes[place:], text[:size])
	copy(bytes, text[size:])
	bytes_written += u64(len(text))
}

// keep adds a run to the line that the program writes now. The text of the
// run is two parts.
keep :: proc "contextless" (first, second: []u8, style: terminal.Style) {
	line := &lines[lines_written & (LINE_CAPACITY - 1)]
	length := u32(len(first) + len(second))
	if length != 0 {
		if line.run_count == LINE_RUNS {
			line_end()
			line = &lines[lines_written & (LINE_CAPACITY - 1)]
		}
		runs[runs_written & (RUN_CAPACITY - 1)] = {start = bytes_written, style = style, length = length}
		runs_written += 1
		put(first)
		put(second)
		line.run_count += 1
		line.length += length
	}
	if .End_Line in style.flags {
		line_end()
	}
}

apply :: proc "contextless" (record: ring.Record) {
	records_read += 1
	#partial switch terminal.Kind(record.kind) {
	case .Text:
		first, second := take(record.tag)
		keep(first, second, transmute(terminal.Style)record.values[0])
	case .Status:
		first, second := take(record.tag)
		status_line = {value = record.values[1], total = record.values[2], style = transmute(terminal.Style)record.values[0]}
		status_line.length = copy(status_line.text[:], first)
		status_line.length += copy(status_line.text[status_line.length:], second)
	case .Clear:
		forget()
	case .Edit:
		first, second := take(record.tag)
		edit_line = {style = transmute(terminal.Style)record.values[0]}
		edit_line.length = copy(edit_line.text[:], first)
		edit_line.length += copy(edit_line.text[edit_line.length:], second)
		if record.values[1] != terminal.NO_CURSOR {
			edit_line.has_cursor = true
			edit_line.cursor = int(min(record.values[1], u64(edit_line.length)))
		}
	}
}

forget :: proc "contextless" () {
	lines_written += 1
	lines[lines_written & (LINE_CAPACITY - 1)] = {first_run = runs_written}
	oldest = lines_written
	status_line = {}
}

// note adds a line of the terminal itself.
note :: proc "contextless" (parts: ..system.Part) {
	buffer: [COLUMNS_LIMIT]u8
	if lines[lines_written & (LINE_CAPACITY - 1)].run_count != 0 {
		line_end()
	}
	keep(transmute([]u8)system.format(buffer[:], ..parts), nil, {tone = .Warning, flags = {.End_Line}})
}

// view_make fills the view for the request.
view_make :: proc "contextless" () {
	if request.stopped {
		note("-- ", program_name, " stopped with code ", u64(request.code), " after ", lines_written, " lines --")
		status_line.total = 0
		edit_line = {}
	}
	count := lines_written
	if lines[lines_written & (LINE_CAPACITY - 1)].run_count != 0 {
		count += 1
	}
	// The line that the program changes takes rows after the last line.
	edit_cells := edit_line.length + int(edit_line.has_cursor)
	edit_rows := u64(min((edit_cells + columns - 1) / columns, rows))
	total := count + edit_rows
	top := request.top
	if request.follow || top + u64(rows) > total {
		top = total > u64(rows) ? total - u64(rows) : 0
	}
	view.count, view.oldest, view.records, view.bytes, view.status = count, oldest, records_read, bytes_written, status_line
	// The person holds lines that the terminal does not have now: the view
	// keeps its cells.
	view.gone = !request.follow && top == view.top && top < oldest
	if view.gone {
		return
	}
	top = max(top, oldest)
	view.top = top
	edit_color := .Color in edit_line.style.flags ? edit_line.style.color & 0xFFFFFF : tone_colors[terminal.Tone(min(u8(edit_line.style.tone), u8(max(terminal.Tone))))]
	for &row, index in view.cells[:rows] {
		row = {}
		number := top + u64(index)
		if number >= count && number - count < edit_rows {
			first := int(number - count) * columns
			for column in 0 ..< columns {
				place := first + column
				if place < edit_line.length {
					row[column] = {edit_line.text[place], false, edit_color}
				}
				if edit_line.has_cursor && place == edit_line.cursor {
					row[column] = {max(row[column].character, ' '), true, COLOR_CURSOR}
				}
			}
			continue
		}
		if number >= count || !line_valid(number) {
			continue
		}
		line := lines[number & (LINE_CAPACITY - 1)]
		column := 0
		for run_index in line.first_run ..< line.first_run + u64(line.run_count) {
			run := runs[run_index & (RUN_CAPACITY - 1)]
			color := .Color in run.style.flags ? run.style.color & 0xFFFFFF : tone_colors[terminal.Tone(min(u8(run.style.tone), u8(max(terminal.Tone))))]
			reverse := .Reverse in run.style.flags
			for offset in 0 ..< u64(run.length) {
				if column == columns {
					break
				}
				row[column] = {bytes[(run.start + offset) & (BYTE_CAPACITY - 1)], reverse, color}
				column += 1
			}
		}
		if int(line.length) > columns {
			row[columns - 1] = {'>', true, graphics.COLOR_DIM} // The line continues after the window.
		}
	}
}

BATCH :: 1024 // The records that the reader reads between two looks at the request.

read :: proc "c" (parameter: rawptr) -> ! {
	queue := &source.commands
	for {
		if intrinsics.atomic_load(&request_word) != 0 {
			view_make()
			intrinsics.atomic_store(&request_word, 0)
			if intrinsics.atomic_exchange(&drawer_waits, 0) != 0 {
				system.word_wake(&request_word)
			}
		}
		count := 0
		for count < BATCH {
			record, ok := system.receive(queue)
			if !ok {
				break
			}
			apply(record)
			count += 1
		}
		if count != 0 {
			intrinsics.atomic_add(&activity, 1)
			if intrinsics.atomic_load(&drawer_idle) != 0 && intrinsics.atomic_exchange(&drawer_idle, 0) != 0 {
				system.word_wake(&activity)
			}
		}
		// The oldest lines go when an area starts again.
		if lines_written >= LINE_CAPACITY {
			oldest = max(oldest, lines_written + 1 - LINE_CAPACITY)
		}
		for oldest < lines_written && !line_valid(oldest) {
			oldest += 1
		}
		if count == 0 {
			list: system.Wait
			system.wait_records(&list, queue)
			system.wait_word(&list, &request_word, 0, &reader_idle)
			if !system.wait_spin(&list) {
				system.wait_end(&list)
			}
		}
	}
}

// view_take asks the reader for a view, and waits for it.
view_take :: proc "contextless" () {
	intrinsics.atomic_store(&request_word, 1)
	if intrinsics.atomic_exchange(&reader_idle, 0) != 0 {
		system.word_wake(&request_word)
	}
	for _ in 0 ..< 4000 {
		if intrinsics.atomic_load(&request_word) == 0 {
			break
		}
		intrinsics.cpu_relax()
	}
	for intrinsics.atomic_load(&request_word) != 0 {
		list: system.Wait
		system.wait_word(&list, &request_word, 1, &drawer_waits)
		system.wait_end(&list)
	}
	request.stopped = false
}

// ---- The drawer.

program: system.Handle // The program that writes, with the right Read. 0 after it stopped.

Rates :: struct {
	lines:   u64, // In one second.
	records: u64,
	bytes:   u64,
	entries: u64, // Kernel entries of the program that writes, for one million records.
	frames:  u64,
}

rates: Rates
history: [HISTORY]u64 // Lines in one second, the last measure at the end.

// number gives a number as text, with a space between each three digits.
number :: proc "contextless" (buffer: ^[27]u8, value: u64) -> string {
	place := len(buffer)
	rest := value
	for digit := 0;; digit += 1 {
		if digit != 0 && digit % 3 == 0 {
			place -= 1
			buffer[place] = ' '
		}
		place -= 1
		buffer[place] = u8('0' + rest % 10)
		rest /= 10
		if rest == 0 {
			break
		}
	}
	return string(buffer[place:])
}

// large draws text at two times the size of the font.
large :: proc "contextless" (canvas: graphics.Canvas, x, y: int, text: string, color: graphics.Color) {
	graphics.text_scaled(canvas, x, y, text, color, 2)
}

tile :: proc "contextless" (canvas: graphics.Canvas, x: int, label: string, value: u64, color: graphics.Color) {
	buffer: [27]u8
	graphics.text(canvas, x, 8, label, graphics.COLOR_DIM)
	large(canvas, x, 28, number(&buffer, value), color)
}

draw :: proc "contextless" (window: ^display.Window, follow: bool) {
	canvas := window.canvas
	buffer: [27]u8

	graphics.fill(canvas, 0, 0, width, text_y, graphics.COLOR_BACKGROUND)
	if measure {
		// The head: the rates, and the graph of the lines in one second.
		graphics.fill(canvas, 0, 0, width, HEAD_HEIGHT - 6, graphics.COLOR_CARD_TOP)
		tile(canvas, 12, "lines in one second", rates.lines, COLOR_GRAPH)
		tile(canvas, 196, "records in one second", rates.records, graphics.COLOR_TEXT)
		tile(canvas, 388, "kernel entries, million records", rates.entries, COLOR_HELD)
		most: u64 = 1
		for value in history {
			most = max(most, value)
		}
		for value, index in history {
			bar_height := int(value * GRAPH_HEIGHT / most)
			x := graph_x + index * GRAPH_BAR
			graphics.fill(canvas, x, 9, GRAPH_BAR - 1, GRAPH_HEIGHT - bar_height, COLOR_GRAPH_DIM)
			graphics.fill(canvas, x, 9 + GRAPH_HEIGHT - bar_height, GRAPH_BAR - 1, bar_height, COLOR_GRAPH)
		}
	}

	// The text: only the rows of the window.
	graphics.fill(canvas, 0, text_y, width, height - text_y, graphics.COLOR_BACKGROUND)
	for &row, row_index in view.cells[:rows] {
		y := text_y + row_index * CELL_HEIGHT
		for cell, column in row[:columns] {
			if cell.character <= ' ' && !cell.reverse {
				continue
			}
			x := TEXT_X + column * CELL_WIDTH
			if cell.reverse {
				graphics.fill(canvas, x, y, CELL_WIDTH, CELL_HEIGHT, cell.color)
				graphics.character(canvas, x, y, cell.character, graphics.COLOR_BACKGROUND)
			} else {
				graphics.character(canvas, x, y, cell.character, cell.color)
			}
		}
	}

	// Where the view is in the lines that the terminal has.
	graphics.fill(canvas, scroll_x, text_y, SCROLL_WIDTH, text_height, graphics.COLOR_TRACK)
	kept := view.count - view.oldest
	if kept > 0 && !view.gone {
		thumb := max(int(min(u64(rows), kept) * u64(text_height) / kept), 12)
		place := kept > u64(rows) ? int(min(view.top - view.oldest, kept - u64(rows)) * u64(text_height - thumb) / (kept - u64(rows))) : 0
		graphics.fill(canvas, scroll_x, text_y + place, SCROLL_WIDTH, thumb, follow ? COLOR_THUMB : COLOR_HELD)
	}

	// The status of the program: a text, and a value of a total. With the
	// rates it has its own line. If not, it takes the place of the line count.
	graphics.fill(canvas, 0, status_y - 4, width, 1, graphics.COLOR_TRACK)
	status := &view.status
	has_status := status.total != 0
	if has_status {
		color := .Color in status.style.flags ? status.style.color & 0xFFFFFF : tone_colors[terminal.Tone(min(u8(status.style.tone), u8(max(terminal.Tone))))]
		x := graphics.text(canvas, TEXT_X, status_y, string(status.text[:status.length]), graphics.COLOR_TEXT) + 12
		bar :: 240
		graphics.fill(canvas, x, status_y + 4, bar, 8, graphics.COLOR_TRACK)
		graphics.fill(canvas, x, status_y + 4, int(min(status.value, status.total) * bar / status.total), 8, color)
		x = graphics.text(canvas, x + bar + 12, status_y, number(&buffer, status.value), graphics.COLOR_TEXT)
		x = graphics.text(canvas, x, status_y, " of ", graphics.COLOR_DIM)
		graphics.text(canvas, x, status_y, number(&buffer, status.total), graphics.COLOR_DIM)
	} else if program == 0 && measure {
		graphics.text(canvas, TEXT_X, status_y, "the program does not run", COLOR_STOPPED)
	}
	if measure {
		// At the right: the frames of the terminal.
		frames := number(&buffer, rates.frames)
		x := width - MARGIN - (len(frames) + len(" pictures in one second")) * CELL_WIDTH
		x = graphics.text(canvas, x, status_y, frames, graphics.COLOR_TEXT)
		graphics.text(canvas, x, status_y, " pictures in one second", graphics.COLOR_DIM)
	}

	// The place of the view, and the keys.
	if measure || !has_status {
		x := graphics.text(canvas, TEXT_X, hint_y, follow ? "line " : "held at line ", follow ? graphics.COLOR_DIM : COLOR_HELD)
		x = graphics.text(canvas, x, hint_y, number(&buffer, view.top + 1), follow ? graphics.COLOR_TEXT : COLOR_HELD)
		x = graphics.text(canvas, x, hint_y, " of ", graphics.COLOR_DIM)
		x = graphics.text(canvas, x, hint_y, number(&buffer, view.count), graphics.COLOR_TEXT)
		if view.gone {
			x = graphics.text(canvas, x, hint_y, "  older than the lines kept", graphics.COLOR_DIM)
		}
		if program == 0 && !measure {
			graphics.text(canvas, x, hint_y, "  the program does not run", COLOR_STOPPED)
		}
	}
	hint :: "page up, page down: move  other keys: to the program"
	graphics.text(canvas, width - MARGIN - len(hint) * CELL_WIDTH, hint_y, hint, graphics.COLOR_DIM)
	display.present(window)
}

fail :: proc "contextless" (text: string) -> ! {
	system.log("terminal: ", text)
	system.stop(1)
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	name_bytes = system.name_unpack({ctx.values[terminal.VALUE_NAME], ctx.values[terminal.VALUE_NAME + 1], ctx.values[terminal.VALUE_NAME + 2], ctx.values[terminal.VALUE_NAME + 3]})
	program_name = system.name_of(name_bytes[:])
	columns = int(clamp(ctx.values[terminal.VALUE_COLUMNS], 40, COLUMNS_LIMIT))
	rows = int(clamp(ctx.values[terminal.VALUE_ROWS], 4, ROWS_LIMIT))
	measure = ctx.values[terminal.VALUE_MEASURE] != 0
	layout()
	program = ctx.handles[terminal.GRANT_PROGRAM]
	window, ok := display.open(ctx, width, height, program_name, two_pictures = true)
	if !ok {
		fail("no surface")
	}
	// The surface is text: the pointer over it is the text shape.
	display.pointer_shape_set(&window, .Text)

	// The areas of the lines.
	area :: proc "contextless" (size: u64) -> rawptr {
		memory, status := system.memory_create((size + system.PAGE_SIZE - 1) / system.PAGE_SIZE)
		if status != .Ok {
			fail("no memory for the lines")
		}
		address: rawptr
		if address, status = system.memory_map(memory); status != .Ok {
			fail("no memory for the lines")
		}
		return address
	}
	lines = ([^]Line)(area(LINE_CAPACITY * size_of(Line)))
	runs = ([^]Run)(area(RUN_CAPACITY * size_of(Run)))
	bytes = ([^]u8)(area(BYTE_CAPACITY))[:BYTE_CAPACITY]

	// The terminal ring and the text region, from the root service. This
	// program has the right Read only on the text region.
	status: system.Status
	if source, status = system.ring_open(ctx.handles[terminal.GRANT_RING]); status != .Ok {
		fail("no terminal ring")
	}
	if system.memory_size(ctx.handles[terminal.GRANT_TEXT]) != terminal.TEXT_PAGES {
		fail("no text region")
	}
	if address, map_status := system.memory_map(ctx.handles[terminal.GRANT_TEXT], {}); map_status == .Ok {
		source_text = ([^]u8)(address)[:terminal.TEXT_SIZE]
	} else {
		fail("no text region")
	}
	if _, status = system.thread_start(read, nil); status != .Ok {
		fail("no thread")
	}
	system.log("terminal: ok, ", program_name, " writes in a ring of ", u64(ring.capacity(&source.commands)), " records")

	request.follow = true
	now := system.time()
	next_frame := now
	sample_time := now
	sample_lines, sample_records, sample_bytes, sample_entries: u64
	frames, sample_frames: u64
	sample_entries = system.program_entries(program)
	keys_sent, keys_lost: u64
	// One line of the log, for the second that follows the first second.
	second_start: u64
	second_lines, second_records, second_entries, second_frames: u64
	second_logged := false
	drawn: u32 // The value of activity at the last picture.
	dirty := true // The view changed with no record: a key, the first picture.
	STATE_TIME :: 250 // Milliseconds between two looks at the state of the program.
	for {
		if !measure && !dirty && intrinsics.atomic_load(&activity) == drawn {
			// Nothing to draw: wait for a record, a key, or the next look at the program.
			wait: system.Wait
			display.wait_events(&wait, &window)
			system.wait_word(&wait, &activity, drawn, &drawer_idle)
			system.wait_end(&wait, program != 0 ? system.time() + STATE_TIME : system.WAIT_FOREVER)
			now = system.time()
			next_frame = now
		} else {
			now = display.wait(&window, next_frame)
		}
		for event in display.next_event(&window) {
			if event.kind != .Key || !event.pressed {
				continue
			}
			dirty = true
			move: i64
			switch event.code {
			case display.KEY_PAGE_UP:
				move = -i64(rows - 1)
			case display.KEY_PAGE_DOWN:
				move = i64(rows - 1)
			case:
				// The key goes to the program. The terminal never waits for
				// the program: if the queue is full, the key is lost.
				if program != 0 {
					if system.send(&source.completions, ring.Record{kind = u32(terminal.Input.Key), tag = event.code, values = {0 = u64(event.character)}}) {
						keys_sent += 1
						if keys_sent == 1 {
							system.log("terminal: the first key goes to ", program_name)
						}
					} else {
						keys_lost += 1
						if keys_lost == 1 {
							system.log("terminal: ", program_name, " does not read its keys: the queue is full, a key is lost")
						}
					}
				}
				request.follow = true
			}
			if move != 0 {
				was_following := request.follow
				request.follow = false
				request.top = u64(max(i64(view.top) + move, i64(view.oldest)))
				if request.top + u64(rows) >= view.count {
					request.follow = true
				}
				if was_following && !request.follow {
					system.log("terminal: the view stays at line ", request.top + 1, ", ", program_name, " continues")
				}
			}
		}
		if now < next_frame {
			continue
		}
		if !display.canvas_free(&window) {
			// The compositor did not take the last picture yet.
			next_frame = now + 1
			continue
		}
		next_frame = max(next_frame + FRAME_TIME, now + 1)
		if program != 0 {
			if state, code := system.program_state(program); state == .Stopped {
				request.stopped, request.code = true, code
				view_take()
				system.log("terminal: ", program_name, " stopped with code ", u64(code), " after ", view.count - 1, " lines and ", view.records, " records")
				system.close(program)
				program = 0
				dirty = true
			}
		}
		current := intrinsics.atomic_load(&activity)
		if !measure && !dirty && current == drawn {
			continue
		}
		drawn, dirty = current, false
		view_take()
		frames += 1
		if now - sample_time >= SAMPLE_TIME {
			elapsed := now - sample_time
			entries := program != 0 ? system.program_entries(program) : sample_entries
			records := view.records - sample_records
			rates = {
				lines   = (view.count - sample_lines) * 1000 / elapsed,
				records = records * 1000 / elapsed,
				bytes   = (view.bytes - sample_bytes) * 1000 / elapsed,
				entries = records != 0 && entries >= sample_entries ? (entries - sample_entries) * 1_000_000 / records : 0,
				frames  = (frames - sample_frames) * 1000 / elapsed,
			}
			copy(history[:], history[1:])
			history[HISTORY - 1] = rates.lines
			sample_time, sample_lines, sample_records, sample_bytes, sample_entries, sample_frames = now, view.count, view.records, view.bytes, entries, frames
			if measure && !second_logged && program != 0 {
				if second_start == 0 {
					if view.records != 0 {
						second_start, second_lines, second_records, second_entries, second_frames = now, view.count, view.records, entries, frames
					}
				} else if now - second_start >= 1000 {
					second_logged = true
					time := now - second_start
					system.log(
						"terminal: ",
						program_name,
						" wrote ",
						(view.count - second_lines) * 1000 / time,
						" lines in one second, ",
						(view.records - second_records) * 1000 / time,
						" records, with ",
						(entries - second_entries) * 1_000_000 / max(view.records - second_records, 1),
						" kernel entries for one million records; the terminal drew ",
						(frames - second_frames) * 1000 / time,
						" pictures",
					)
				}
			}
		}
		draw(&window, request.follow)
	}
}
