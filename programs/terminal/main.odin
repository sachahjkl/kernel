// The terminal: it shows the text that a program gives as records
// (terminal/terminal.odin). It starts the program `flood`.
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

import "../../display"
import "../../graphics"
import op "../../kernel/operation"
import "../../ring"
import "../../system"
import "../../terminal"
import "base:intrinsics"

PROGRAM :: "flood" // The program that this terminal starts.

COLUMNS :: 104
ROWS :: 32
CELL_WIDTH :: graphics.CELL_WIDTH
CELL_HEIGHT :: graphics.CELL_HEIGHT

MARGIN :: 8
HEAD_HEIGHT :: 72
TEXT_X :: MARGIN
TEXT_Y :: HEAD_HEIGHT
TEXT_WIDTH :: COLUMNS * CELL_WIDTH
TEXT_HEIGHT :: ROWS * CELL_HEIGHT
SCROLL_X :: TEXT_X + TEXT_WIDTH + 6
SCROLL_WIDTH :: 8
STATUS_Y :: TEXT_Y + TEXT_HEIGHT + 8
HINT_Y :: STATUS_Y + 24
WIDTH :: SCROLL_X + SCROLL_WIDTH + MARGIN
HEIGHT :: HINT_Y + CELL_HEIGHT + 8

FRAME_TIME :: 16 // Milliseconds.
SAMPLE_TIME :: 250 // Milliseconds of one measure of the rates.
HISTORY :: 48 // The measures that the graph shows.
GRAPH_BAR :: 4
GRAPH_X :: WIDTH - MARGIN - SCROLL_WIDTH - 6 - HISTORY * GRAPH_BAR
GRAPH_HEIGHT :: 48

COLOR_BACKGROUND :: 0x0C1016
COLOR_HEAD :: 0x141B24
COLOR_TEXT :: 0xD8E0E8
COLOR_DIM :: 0x6C7986
COLOR_RULE :: 0x232C38
COLOR_GRAPH :: 0x58D878
COLOR_GRAPH_DIM :: 0x1C3A28
COLOR_THUMB :: 0x5A6878
COLOR_STOPPED :: 0xF07060
COLOR_HELD :: 0xF0C050

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
	text:   [COLUMNS]u8,
	length: int,
	value:  u64,
	total:  u64,
	style:  terminal.Style,
}
status_line: Status_Line

// ---- What the drawer asks, and the view that the reader gives.

Request :: struct {
	follow: bool, // The view shows the last lines.
	top:    u64, // If not follow: the line of the first row.
	reset:  bool, // The program stopped: the ring starts again.
	clear:  bool,
}

Cell :: struct {
	character: u8,
	reverse:   bool,
	color:     graphics.Color,
}

View :: struct {
	cells:   [ROWS][COLUMNS]Cell,
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
	buffer: [COLUMNS]u8
	if lines[lines_written & (LINE_CAPACITY - 1)].run_count != 0 {
		line_end()
	}
	keep(transmute([]u8)system.format(buffer[:], ..parts), nil, {tone = .Warning, flags = {.End_Line}})
}

// view_make fills the view for the request.
view_make :: proc "contextless" () {
	if request.reset {
		// The program does not run: no other thread writes the ring.
		source.head^ = {}
		source_read = 0
		note("-- the terminal stopped ", PROGRAM, " after ", lines_written, " lines --")
		status_line.total = 0
	}
	if request.clear {
		forget()
	}
	count := lines_written
	if lines[lines_written & (LINE_CAPACITY - 1)].run_count != 0 {
		count += 1
	}
	top := request.top
	if request.follow || top + ROWS > count {
		top = count > ROWS ? count - ROWS : 0
	}
	view.count, view.oldest, view.records, view.bytes, view.status = count, oldest, records_read, bytes_written, status_line
	// The person holds lines that the terminal does not have now: the view
	// keeps its cells.
	view.gone = !request.follow && !request.clear && top == view.top && top < oldest
	if view.gone {
		return
	}
	top = max(top, oldest)
	view.top = top
	for &row, index in view.cells {
		row = {}
		number := top + u64(index)
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
				if column == COLUMNS {
					break
				}
				row[column] = {bytes[(run.start + offset) & (BYTE_CAPACITY - 1)], reverse, color}
				column += 1
			}
		}
		if line.length > COLUMNS {
			row[COLUMNS - 1] = {'>', true, COLOR_DIM} // The line continues after the window.
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
	request.reset, request.clear = false, false
}

// ---- The drawer.

machine: system.Handle
image: []u8
program: system.Handle
program_slot: u64
ring_memory, text_memory: system.Handle

Rates :: struct {
	lines:   u64, // In one second.
	records: u64,
	bytes:   u64,
	entries: u64, // Kernel entries of the program that writes, for one million records.
	frames:  u64,
}

rates: Rates
history: [HISTORY]u64 // Lines in one second, the last measure at the end.

program_entries :: proc "contextless" () -> u64 {
	if program_slot == 0 {
		return 0
	}
	report: op.Program_Report
	system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.Program), program_slot, u64(uintptr(&report)), size_of(report))
	return report.entries
}

program_begin :: proc "contextless" () -> bool {
	grants: [op.CONTEXT_HANDLES]system.Grant
	values: [op.CONTEXT_VALUES]u64
	grants[terminal.GRANT_RING] = {ring_memory, {.Read, .Write}}
	grants[terminal.GRANT_TEXT] = {text_memory, {.Read, .Write}}
	grants[op.CONTEXT_LOG] = {system.context_record().handles[op.CONTEXT_LOG], {.Write}}
	status: system.Status
	program, status = system.program_start(system.image_find(image, PROGRAM), PROGRAM, grants, values, {pages = 256, programs = 1, threads = 1})
	if status != .Ok {
		system.log("terminal: cannot start ", PROGRAM, ": status ", u64(status))
		program = 0
		return false
	}
	// The slot of the program in the kernel: the newest program with this name.
	system_report: op.System_Report
	system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.System), 0, u64(uintptr(&system_report)), size_of(system_report))
	newest: u64
	program_slot = 0
	for index in 1 ..< system_report.program_slots {
		report: op.Program_Report
		system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.Program), index, u64(uintptr(&report)), size_of(report))
		if report.state != .None && report.state != .Stopped && system.name_of(report.name[:]) == PROGRAM && report.start_time >= newest {
			program_slot, newest = index, report.start_time
		}
	}
	return true
}

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
	for index in 0 ..< len(text) {
		value := text[index]
		if value < graphics.FONT_FIRST || value > graphics.FONT_LAST {
			continue
		}
		for bits, row in graphics.font[value - graphics.FONT_FIRST] {
			for column in 0 ..< CELL_WIDTH {
				if bits << uint(column) & 0x80 != 0 {
					graphics.fill(canvas, x + (index * CELL_WIDTH + column) * 2, y + row * 2, 2, 2, color)
				}
			}
		}
	}
}

tile :: proc "contextless" (canvas: graphics.Canvas, x: int, label: string, value: u64, color: graphics.Color) {
	buffer: [27]u8
	graphics.text(canvas, x, 8, label, COLOR_DIM)
	large(canvas, x, 28, number(&buffer, value), color)
}

draw :: proc "contextless" (window: ^display.Window, follow: bool) {
	canvas := window.canvas
	buffer: [27]u8

	// The head: the rates, and the graph of the lines in one second.
	graphics.fill(canvas, 0, 0, WIDTH, HEAD_HEIGHT - 6, COLOR_HEAD)
	graphics.fill(canvas, 0, HEAD_HEIGHT - 6, WIDTH, 6, COLOR_BACKGROUND)
	tile(canvas, 12, "lines in one second", rates.lines, COLOR_GRAPH)
	tile(canvas, 196, "records in one second", rates.records, COLOR_TEXT)
	tile(canvas, 388, "kernel entries, million records", rates.entries, COLOR_HELD)
	most: u64 = 1
	for value in history {
		most = max(most, value)
	}
	for value, index in history {
		height := int(value * GRAPH_HEIGHT / most)
		x := GRAPH_X + index * GRAPH_BAR
		graphics.fill(canvas, x, 9, GRAPH_BAR - 1, GRAPH_HEIGHT - height, COLOR_GRAPH_DIM)
		graphics.fill(canvas, x, 9 + GRAPH_HEIGHT - height, GRAPH_BAR - 1, height, COLOR_GRAPH)
	}

	// The text: only the rows of the window.
	graphics.fill(canvas, 0, TEXT_Y, WIDTH, HEIGHT - TEXT_Y, COLOR_BACKGROUND)
	for &row, row_index in view.cells {
		y := TEXT_Y + row_index * CELL_HEIGHT
		for cell, column in row {
			if cell.character <= ' ' && !cell.reverse {
				continue
			}
			x := TEXT_X + column * CELL_WIDTH
			if cell.reverse {
				graphics.fill(canvas, x, y, CELL_WIDTH, CELL_HEIGHT, cell.color)
				graphics.character(canvas, x, y, cell.character, COLOR_BACKGROUND)
			} else {
				graphics.character(canvas, x, y, cell.character, cell.color)
			}
		}
	}

	// Where the view is in the lines that the terminal has.
	graphics.fill(canvas, SCROLL_X, TEXT_Y, SCROLL_WIDTH, TEXT_HEIGHT, COLOR_RULE)
	kept := view.count - view.oldest
	if kept > 0 && !view.gone {
		thumb := max(int(min(u64(ROWS), kept) * TEXT_HEIGHT / kept), 12)
		place := kept > ROWS ? int((view.top - view.oldest) * u64(TEXT_HEIGHT - thumb) / (kept - ROWS)) : 0
		graphics.fill(canvas, SCROLL_X, TEXT_Y + place, SCROLL_WIDTH, thumb, follow ? COLOR_THUMB : COLOR_HELD)
	}

	// The status of the program: a text, and a value of a total.
	graphics.fill(canvas, 0, STATUS_Y - 4, WIDTH, 1, COLOR_RULE)
	status := &view.status
	if status.total != 0 {
		color := .Color in status.style.flags ? status.style.color & 0xFFFFFF : tone_colors[terminal.Tone(min(u8(status.style.tone), u8(max(terminal.Tone))))]
		x := graphics.text(canvas, TEXT_X, STATUS_Y, string(status.text[:status.length]), COLOR_TEXT) + 12
		bar :: 240
		graphics.fill(canvas, x, STATUS_Y + 4, bar, 8, COLOR_RULE)
		graphics.fill(canvas, x, STATUS_Y + 4, int(min(status.value, status.total) * bar / status.total), 8, color)
		x = graphics.text(canvas, x + bar + 12, STATUS_Y, number(&buffer, status.value), COLOR_TEXT)
		x = graphics.text(canvas, x, STATUS_Y, " of ", COLOR_DIM)
		graphics.text(canvas, x, STATUS_Y, number(&buffer, status.total), COLOR_DIM)
	} else if program == 0 {
		graphics.text(canvas, TEXT_X, STATUS_Y, "the program does not run", COLOR_STOPPED)
	}
	// At the right: the frames of the terminal.
	frames := number(&buffer, rates.frames)
	x := WIDTH - MARGIN - (len(frames) + len(" pictures in one second")) * CELL_WIDTH
	x = graphics.text(canvas, x, STATUS_Y, frames, COLOR_TEXT)
	graphics.text(canvas, x, STATUS_Y, " pictures in one second", COLOR_DIM)

	// The place of the view, and the keys.
	x = graphics.text(canvas, TEXT_X, HINT_Y, follow ? "line " : "held at line ", follow ? COLOR_DIM : COLOR_HELD)
	x = graphics.text(canvas, x, HINT_Y, number(&buffer, view.top + 1), follow ? COLOR_TEXT : COLOR_HELD)
	x = graphics.text(canvas, x, HINT_Y, " of ", COLOR_DIM)
	x = graphics.text(canvas, x, HINT_Y, number(&buffer, view.count), COLOR_TEXT)
	if view.gone {
		graphics.text(canvas, x, HINT_Y, "  older than the lines kept", COLOR_DIM)
	}
	hint :: "space: hold  arrows, page: move  s: stop  c: clear"
	graphics.text(canvas, WIDTH - MARGIN - len(hint) * CELL_WIDTH, HINT_Y, hint, COLOR_DIM)
	display.present(window)
}

fail :: proc "contextless" (text: string) -> ! {
	system.log("terminal: ", text)
	system.stop(1)
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	window, ok := display.open(ctx, WIDTH, HEIGHT, "terminal", two_pictures = true)
	if !ok {
		fail("no surface")
	}
	machine = ctx.handles[system.GRANT_MACHINE]
	if address, status := system.memory_map(ctx.handles[system.GRANT_IMAGE], {}); status == .Ok {
		image = ([^]u8)(address)[:ctx.values[system.GRANT_VALUE_IMAGE_SIZE]]
	} else {
		fail("no grant to read the boot image")
	}

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

	// The terminal ring and the text region. This program only reads the
	// text region.
	status: system.Status
	if ring_memory, source, status = system.ring_create(terminal.RING_CAPACITY); status != .Ok {
		fail("no terminal ring")
	}
	if text_memory, status = system.memory_create(terminal.TEXT_PAGES); status != .Ok {
		fail("no text region")
	}
	if address, map_status := system.memory_map(text_memory, {}); map_status == .Ok {
		source_text = ([^]u8)(address)[:terminal.TEXT_SIZE]
	} else {
		fail("no text region")
	}
	if _, status = system.thread_start(read, nil); status != .Ok {
		fail("no thread")
	}
	if !program_begin() {
		fail("cannot start the program")
	}
	system.log("terminal: ok, ", PROGRAM, " writes in a ring of ", u64(terminal.RING_CAPACITY), " records")

	request.follow = true
	now := system.time()
	next_frame := now
	sample_time := now
	sample_lines, sample_records, sample_bytes, sample_entries: u64
	frames, sample_frames: u64
	sample_entries = program_entries()
	// One line of the log, for the second that follows the first second.
	second_start: u64
	second_lines, second_records, second_entries, second_frames: u64
	second_logged := false
	for {
		now = display.wait(&window, next_frame)
		for event in display.next_event(&window) {
			if event.kind != .Key || !event.pressed {
				continue
			}
			move: i64
			switch event.code {
			case display.KEY_UP:
				move = -1
			case display.KEY_DOWN:
				move = 1
			case display.KEY_PAGE_UP:
				move = -(ROWS - 1)
			case display.KEY_PAGE_DOWN:
				move = ROWS - 1
			case display.KEY_HOME:
				request.follow, request.top = false, 0
			case display.KEY_END:
				request.follow = true
			}
			if move != 0 {
				request.follow = false
				request.top = u64(max(i64(view.top) + move, i64(view.oldest)))
				if request.top + ROWS >= view.count {
					request.follow = true
				}
			}
			switch event.character {
			case ' ':
				request.follow = !request.follow
				request.top = view.top
				if !request.follow {
					system.log("terminal: the view stays at line ", view.top + 1, ", ", PROGRAM, " continues")
				}
			case 'c':
				request.clear = true
			case 's':
				if program != 0 {
					system.close(program)
					program, program_slot = 0, 0
					request.reset = true
					view_take()
					system.log("terminal: stopped ", PROGRAM, " after ", view.count - 1, " lines and ", view.records, " records")
				} else if program_begin() {
					system.log("terminal: started ", PROGRAM)
					sample_entries = 0
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
		view_take()
		frames += 1
		if now - sample_time >= SAMPLE_TIME {
			elapsed := now - sample_time
			entries := program_entries()
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
			if !second_logged && program != 0 {
				if second_start == 0 {
					if view.records != 0 {
						second_start, second_lines, second_records, second_entries, second_frames = now, view.count, view.records, entries, frames
					}
				} else if now - second_start >= 1000 {
					second_logged = true
					time := now - second_start
					system.log(
						"terminal: ",
						PROGRAM,
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
