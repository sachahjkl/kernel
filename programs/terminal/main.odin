// The terminal: it shows the text that a program gives as records, and it
// gives the keys that the input types to that program (support/terminal).
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
//
// **What it is for.** A program with the grant **Terminal** (the console,
// flood) writes typed records, not pixels and not escape sequences: a run
// of text has its style as a field. The program never draws, never waits
// for a picture, and never parses a key sequence. See the terms
// [terminal](term:terminal) and [terminal ring](term:terminal-ring).
//
// **Start**: nothing starts it by name. The root service starts one
// terminal with each program that has the grant **Terminal**, and refuses
// `start("terminal")`. It has no grant of `grants_of`: it receives only
// the handles above.
//
// **What a reader sees**: a window with the name of the program, its
// lines, a status bar that the program fills, and on the log:
//
// - "terminal: ok, console writes in a ring of N records";
// - "terminal: the first key goes to console";
// - "terminal: console stopped with code C after L lines and R records".
//
// The terminal of flood measures: it shows the rates of the program, and
// writes one line with the lines, the records and the kernel entries of one
// second.
//
// **What it proves**: a text output with no kernel entry for each line, and
// a writer that never waits for the screen. It does not prove fairness
// between two writers: one terminal serves one program.
package terminal_program

import "support:display"
import "support:graphics"
import "support:interface"
import "contract:ring"
import "support:system"
import terminal "support:terminal"
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
// The completion list: a card over the text, its chosen row in the chosen
// blue of the rules with its text in white, the matched characters in the
// accent, a border of one pixel in the color of the kernel as the menus of
// the bar.
COLOR_LIST :: graphics.COLOR_CARD_TOP
COLOR_LIST_BORDER :: graphics.COLOR_KERNEL
LIST_WIDTH_LEAST :: 16 // Cells: a list of short names stays wide enough to read.

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
	code:       terminal.Code_Runs, // Checked against the text. None: the line is plain.
}
edit_line: Edit_Line
// The runs of code that the next Edit record takes (terminal.Kind.Code_Runs).
edit_runs_pending: terminal.Code_Runs
// The lists of runs of code that were refused for the edit line: each one
// left its line plain. The list counts its own.
edit_runs_refused: u64
runs_refusal_logged: bool

// The line under the edit line (terminal.Kind.Hint): a long form, and a
// short form for a terminal too narrow for the long one. The text holds
// the long form, then the short form.
Hint_Line :: struct {
	text:       [terminal.RUN_LIMIT]u8,
	length:     int,
	long_count: int,
	marked:     [terminal.Hint_Form][2]int, // The first byte and the count of bytes that each form marks.
	style:      terminal.Style,
}
hint_line: Hint_Line

// The completion list (terminal.Kind.List_Row, terminal.Kind.List).
list_keeping: terminal.List_Keeping

// ---- What the drawer asks, and the view that the reader gives.

Request :: struct {
	follow: bool, // The view shows the last lines.
	top:    u64, // If not follow: the line of the first row.
	stopped: bool, // The program stopped: the reader writes a line that says it.
	code:    u32,
}

Cell :: interface.Text_Grid_Cell

View :: struct {
	cells:   [ROWS_LIMIT][COLUMNS_LIMIT]Cell,
	top:     u64,
	count:   u64, // The lines since the start.
	oldest:  u64,
	gone:    bool, // The terminal does not have the lines of the cells now.
	records: u64,
	bytes:   u64,
	status:  Status_Line,
	// The cells of the completion list, for its border: list_columns 0 is
	// no list.
	list_left, list_top, list_columns, list_rows: int,
	// The rows of the view that show lines of the text: the edit line and
	// the row under it are not lines of the text. After a clear, the view
	// can show none.
	text_rows: u64,
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
		edit_line.code = edit_runs_pending
		edit_runs_pending = {}
		if edit_line.code.count != 0 && !terminal.code_runs_check(&edit_line.code, edit_line.length) {
			edit_runs_refused += 1
		}
	case .Hint:
		first, second := take(record.tag)
		hint_line = {style = transmute(terminal.Style)record.values[0]}
		hint_line.length = copy(hint_line.text[:], first)
		hint_line.length += copy(hint_line.text[hint_line.length:], second)
		hint_line.long_count = int(min(record.values[3], u64(hint_line.length)))
		short_count := hint_line.length - hint_line.long_count
		long_start := int(min(record.values[1], u64(hint_line.long_count)))
		short_start := int(min(record.values[4], u64(short_count)))
		hint_line.marked[.Long] = {long_start, int(min(record.values[2], u64(hint_line.long_count - long_start)))}
		hint_line.marked[.Short] = {short_start, int(min(record.values[5], u64(short_count - short_start)))}
	case .List_Row:
		first, second := take(record.tag)
		terminal.list_keep_row(&list_keeping, record.values, first, second)
	case .List:
		terminal.list_keep_show(&list_keeping, record.values)
	case .Code_Runs:
		first, second := take(record.tag)
		target := record.values[0] <= u64(max(terminal.Kind)) ? terminal.Kind(u32(record.values[0])) : terminal.Kind.None
		switch target {
		case .Edit:
			read, ok := terminal.code_runs_read(first, second)
			if !ok {
				edit_runs_refused += 1
			}
			edit_runs_pending = read
		case .List_Row:
			terminal.list_keep_code_runs(&list_keeping, record.values, first, second)
		case .None, .Text, .Status, .Clear, .Hint, .List, .Code_Runs:
			edit_runs_refused += 1 // No other record takes runs.
		}
	}
	// A program that sends runs that do not fit its rows: its rows stay
	// plain, and the log says it once.
	if !runs_refusal_logged && edit_runs_refused + list_keeping.runs_refused != 0 {
		runs_refusal_logged = true
		system.log("terminal: ", program_name, " sent runs of code that do not fit their row: the row is drawn plain, its text whole")
	}
}

// style_color gives the color of a run of text: its own color with the
// flag Color; if not, the color of its code kind when the kind has one; if
// not, the color of its tone. A kind or a tone past the known ones is the
// default.
style_color :: proc "contextless" (style: terminal.Style) -> graphics.Color {
	if .Color in style.flags {
		return style.color & 0xFFFFFF
	}
	plain := tone_colors[terminal.Tone(min(u8(style.tone), u8(max(terminal.Tone))))]
	return terminal.code_kind_color(terminal.code_kind_of(u8(style.code)), plain)
}

// shown_character gives the byte that a cell shows for a byte of a list or
// a hint: the font draws 32 to 126, and these texts come from the
// descriptions of other programs.
shown_character :: proc "contextless" (character: u8) -> u8 {
	return character >= ' ' && character <= '~' ? character : '?'
}

// list_fill writes the cells of the completion list over the rows of the
// view, at the edit line: under it when the rows below hold the list, if
// not above it, and if neither holds it, on the larger side with fewer
// rows. edit_top is the row of the view of the first row of the edit line,
// below the first row under the edit line and its hint.
list_fill :: proc "contextless" (edit_top, below: int) {
	view.list_columns = 0
	if list_keeping.shown.row_count == 0 || edit_top < 0 || edit_top >= rows {
		return
	}
	shown_rows := list_keeping.shown.row_count
	space_below := max(rows - below, 0)
	space_above := edit_top
	top: int
	switch {
	case space_below >= shown_rows:
		top = below
	case space_above >= shown_rows:
		top = edit_top - shown_rows
	case space_below >= space_above:
		top, shown_rows = below, space_below
	case:
		top, shown_rows = 0, space_above
	}
	if shown_rows <= 0 {
		return
	}
	// The rows shown keep the chosen row in view.
	offset := list_keeping.shown.chosen >= shown_rows ? list_keeping.shown.chosen - shown_rows + 1 : 0
	scroll := list_keeping.shown.total > list_keeping.shown.row_count || shown_rows < list_keeping.shown.row_count ? 1 : 0
	longest := 0
	for &row in list_keeping.shown.rows[offset:][:shown_rows] {
		about := row.length - row.name_length
		longest = max(longest, row.name_length + (about > 0 ? 2 + about : 0))
	}
	list_width := min(max(longest + 2 + scroll, LIST_WIDTH_LEAST), columns)
	anchor := min(list_keeping.shown.anchor, edit_line.length)
	left := min(anchor % columns, columns - list_width)
	inner := list_width - 2 - scroll
	// The scroll mark: a track, and a thumb at the place of the rows shown
	// in all the names.
	shown_first := list_keeping.shown.first + offset
	thumb_rows := max(shown_rows * shown_rows / max(list_keeping.shown.total, 1), 1)
	thumb_top := min(shown_first * shown_rows / max(list_keeping.shown.total, 1), shown_rows - thumb_rows)
	for index in 0 ..< shown_rows {
		row := &list_keeping.shown.rows[offset + index]
		chosen := offset + index == list_keeping.shown.chosen
		background: graphics.Color = chosen ? graphics.COLOR_CHOSEN : COLOR_LIST
		name_color: graphics.Color = chosen ? graphics.COLOR_WHITE : graphics.COLOR_TEXT
		about_color: graphics.Color = chosen ? graphics.COLOR_WHITE : tone_colors[.Dim]
		cells := view.cells[top + index][left:][:list_width]
		for &cell in cells {
			cell = {character = ' ', filled = true, color = name_color, background = background}
		}
		// A row with runs of code: each part in the color of its kind, and
		// the part with no kind in the color of the name. On the chosen row
		// each part is white: no color of a kind keeps its contrast on the
		// blue (docs/CONSOLE.md, section 7). A matched character is in the
		// accent over its kind: the match is what the person typed. No tone
		// but white keeps its contrast on the chosen blue, so there a matched
		// character is the reverse: the chosen blue on a white cell.
		colored := row.code.count != 0
		if colored && !chosen {
			about_color = name_color
		}
		code_cursor := 0 // The run of code of the bytes of the row, in order.
		name_shown := min(row.name_length, inner)
		for place in 0 ..< name_shown {
			matched := row.matched[place / 64] & (1 << u64(place % 64)) != 0
			kind := terminal.code_runs_kind_at(&row.code, place, &code_cursor)
			name_cell := Cell{character = shown_character(row.text[place]), filled = true, color = chosen ? name_color : terminal.code_kind_color(kind, name_color), background = background}
			switch {
			case matched && chosen:
				name_cell.color, name_cell.background = graphics.COLOR_CHOSEN, graphics.COLOR_WHITE
			case matched:
				name_cell.color = tone_colors[.Accent]
			}
			cells[1 + place] = name_cell
		}
		// What the name is, at the right, cut at its end when the room is short.
		about_room := inner - name_shown - 2
		about_shown := about_room > 0 ? min(row.length - row.name_length, about_room) : 0
		about_left := 1 + inner - about_shown
		for place in 0 ..< about_shown {
			kind := terminal.code_runs_kind_at(&row.code, row.name_length + place, &code_cursor)
			color := chosen ? about_color : terminal.code_kind_color(kind, about_color)
			cells[about_left + place] = {character = shown_character(row.text[row.name_length + place]), filled = true, color = color, background = background}
		}
		if scroll == 1 {
			thumb := index >= thumb_top && index < thumb_top + thumb_rows
			cells[list_width - 1] = {character = ' ', filled = true, background = thumb ? COLOR_THUMB : graphics.COLOR_TRACK}
		}
	}
	view.list_left, view.list_top, view.list_columns, view.list_rows = left, top, list_width, shown_rows
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
		edit_runs_pending = {}
		hint_line = {}
		terminal.list_keep_forget(&list_keeping)
	}
	count := lines_written
	if lines[lines_written & (LINE_CAPACITY - 1)].run_count != 0 {
		count += 1
	}
	// The line that the program changes takes rows after the last line.
	edit_cells := edit_line.length + int(edit_line.has_cursor)
	edit_rows := u64(min((edit_cells + columns - 1) / columns, rows))
	// One row under the edit line stays free at all times, with or without
	// a hint line: the hint is drawn over it, as the list is drawn over the
	// text, so the text does not move when a hint comes or goes.
	free_rows: u64 = edit_rows > 0 ? 1 : 0
	total := count + edit_rows + free_rows
	top := request.top
	if request.follow || top + u64(rows) > total {
		top = total > u64(rows) ? total - u64(rows) : 0
	}
	view.count, view.oldest, view.records, view.bytes, view.status = count, oldest, records_read, bytes_written, status_line
	// The person holds lines that the terminal does not have now: the view
	// keeps its cells.
	view.gone = !request.follow && top == view.top && top < oldest
	if view.gone {
		view.list_columns = 0
		view.text_rows = 0
		return
	}
	view.text_rows = 0
	top = max(top, oldest)
	view.top = top
	edit_color := style_color(edit_line.style)
	for &row, index in view.cells[:rows] {
		row = {}
		number := top + u64(index)
		if number >= count && number - count < edit_rows {
			first := int(number - count) * columns
			code_cursor := 0 // The run of code of the bytes of this row, in order.
			for column in 0 ..< columns {
				place := first + column
				if place < edit_line.length {
					kind := terminal.code_runs_kind_at(&edit_line.code, place, &code_cursor)
					row[column] = {character = edit_line.text[place], color = terminal.code_kind_color(kind, edit_color)}
				}
				if edit_line.has_cursor && place == edit_line.cursor {
					row[column] = {character = max(row[column].character, ' '), reverse = true, color = COLOR_CURSOR}
				}
			}
			continue
		}
		if free_rows == 1 && number == count + edit_rows {
			hint_fill(&row)
			continue
		}
		if number >= count || !line_valid(number) {
			continue
		}
		view.text_rows += 1
		line := lines[number & (LINE_CAPACITY - 1)]
		column := 0
		for run_index in line.first_run ..< line.first_run + u64(line.run_count) {
			run := runs[run_index & (RUN_CAPACITY - 1)]
			color := style_color(run.style)
			reverse := .Reverse in run.style.flags
			for offset in 0 ..< u64(run.length) {
				if column == columns {
					break
				}
				row[column] = {character = bytes[(run.start + offset) & (BYTE_CAPACITY - 1)], reverse = reverse, color = color}
				column += 1
			}
		}
		if int(line.length) > columns {
			row[columns - 1] = {character = '>', reverse = true, color = graphics.COLOR_DIM} // The line continues after the window.
		}
	}
	edit_top := int(i64(count) - i64(top))
	list_fill(edit_top, edit_top + int(edit_rows + free_rows))
}

// hint_fill writes the hint line in the free row under the edit line: its
// long form when it fits in the columns, if not its short form, cut to the
// columns.
hint_fill :: proc "contextless" (row: ^[COLUMNS_LIMIT]Cell) {
	form, shown := terminal.hint_form_choose(hint_line.long_count, hint_line.length - hint_line.long_count, columns)
	first := form == .Long ? 0 : hint_line.long_count
	marked := hint_line.marked[form]
	color := style_color(hint_line.style)
	for place in 0 ..< shown {
		in_mark := place >= marked[0] && place < marked[0] + marked[1]
		row[place] = {character = shown_character(hint_line.text[first + place]), color = in_mark ? tone_colors[.Accent] : color}
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

// The drawing of the window with the interface package: the cells of the
// view are a text grid, so a frame damages only the cells that changed.
// Each picture of the surface has its own table before, with its own copy
// of the cells.
records_now, records_before, records_second: [256]interface.Draw_Record
text_now, text_before, text_second: [1024]u8
cells_before, cells_second: [ROWS_LIMIT * COLUMNS_LIMIT]Cell
grids_now, grids_before, grids_second: [1]interface.Text_Grid
drawing: interface.Window_Drawing

drawing_start :: proc "contextless" () {
	drawing = interface.window_drawing_of(records_now[:], records_before[:], text_now[:], text_before[:], records_second[:], text_second[:])
	grids_now[0] = {cells = ([^]Cell)(&view.cells[0][0])[:ROWS_LIMIT * COLUMNS_LIMIT], columns = columns, rows = rows, stride = COLUMNS_LIMIT}
	grids_before[0] = {cells = cells_before[:]}
	grids_second[0] = {cells = cells_second[:]}
	drawing.now.grids = grids_now[:]
	drawing.before.grids = grids_before[:]
	drawing.before_second.grids = grids_second[:]
}

tile :: proc "contextless" (table: ^interface.Draw_Table, x: int, label: string, value: u64, color: graphics.Color) {
	buffer: [27]u8
	interface.draw_text(table, x, 8, label, graphics.COLOR_DIM)
	interface.draw_text(table, x, 28, number(&buffer, value), color, interface.FONT_MEDIUM)
}

draw :: proc "contextless" (window: ^display.Window, follow: bool) {
	buffer: [27]u8
	frame := interface.window_frame_begin(&drawing, window)
	table := frame.table

	if measure {
		// The head: the rates, and the graph of the lines in one second.
		interface.draw_rectangle(table, 0, 0, width, HEAD_HEIGHT - 6, graphics.COLOR_CARD_TOP)
		tile(table, 12, "lines in one second", rates.lines, COLOR_GRAPH)
		tile(table, 196, "records in one second", rates.records, graphics.COLOR_TEXT)
		tile(table, 388, "kernel entries, million records", rates.entries, COLOR_HELD)
		most: u64 = 1
		for value in history {
			most = max(most, value)
		}
		for value, index in history {
			bar_height := int(value * GRAPH_HEIGHT / most)
			x := graph_x + index * GRAPH_BAR
			interface.draw_rectangle(table, x, 9, GRAPH_BAR - 1, GRAPH_HEIGHT - bar_height, COLOR_GRAPH_DIM)
			interface.draw_rectangle(table, x, 9 + GRAPH_HEIGHT - bar_height, GRAPH_BAR - 1, bar_height, COLOR_GRAPH)
		}
	}

	// The text: only the rows of the window, as one text grid.
	interface.draw_text_grid(table, TEXT_X, text_y, 0)

	// Where the view is in the lines that the terminal has.
	interface.draw_rectangle(table, scroll_x, text_y, SCROLL_WIDTH, text_height, graphics.COLOR_TRACK)
	kept := view.count - view.oldest
	if kept > 0 && !view.gone {
		thumb := max(int(min(u64(rows), kept) * u64(text_height) / kept), 12)
		place := kept > u64(rows) ? int(min(view.top - view.oldest, kept - u64(rows)) * u64(text_height - thumb) / (kept - u64(rows))) : 0
		interface.draw_rectangle(table, scroll_x, text_y + place, SCROLL_WIDTH, thumb, follow ? COLOR_THUMB : COLOR_HELD)
	}

	// The status of the program: a text, and a value of a total. With the
	// rates it has its own line. If not, it takes the place of the line count.
	interface.draw_rectangle(table, 0, status_y - 4, width, 1, graphics.COLOR_TRACK)
	status := &view.status
	has_status := status.total != 0
	status_end := TEXT_X // Where the text of the status ends: the keys at the right must not run over it.
	if has_status {
		color := style_color(status.style)
		x := interface.draw_text(table, TEXT_X, status_y, string(status.text[:status.length]), graphics.COLOR_TEXT) + 12
		bar :: 240
		interface.draw_rectangle(table, x, status_y + 4, bar, 8, graphics.COLOR_TRACK)
		interface.draw_rectangle(table, x, status_y + 4, status_bar_length(status.value, status.total, bar), 8, color)
		x = interface.draw_text(table, x + bar + 12, status_y, number(&buffer, status.value), graphics.COLOR_TEXT)
		x = interface.draw_text(table, x, status_y, " of ", graphics.COLOR_DIM)
		status_end = interface.draw_text(table, x, status_y, number(&buffer, status.total), graphics.COLOR_DIM)
	} else if program == 0 && measure {
		interface.draw_text(table, TEXT_X, status_y, "the program does not run", COLOR_STOPPED)
	}
	if measure {
		// At the right: the frames of the terminal.
		frames := number(&buffer, rates.frames)
		x := width - MARGIN - (len(frames) + len(" pictures in one second")) * CELL_WIDTH
		x = interface.draw_text(table, x, status_y, frames, graphics.COLOR_TEXT)
		interface.draw_text(table, x, status_y, " pictures in one second", graphics.COLOR_DIM)
	}

	// The place of the view, and the keys.
	// Where the text at the left of the keys ends. With no rates, the status
	// is on the line of the keys.
	hint_left := measure ? TEXT_X : status_end
	if measure || !has_status {
		// The lines of the text that the rows show: the edit line and the
		// row under it are not lines of the text.
		x := interface.draw_text(table, TEXT_X, hint_y, follow ? "lines " : "held at lines ", follow ? graphics.COLOR_DIM : COLOR_HELD)
		if view.text_rows == 0 {
			x = interface.draw_text(table, x, hint_y, "none in view", follow ? graphics.COLOR_TEXT : COLOR_HELD)
		} else {
			x = interface.draw_text(table, x, hint_y, number(&buffer, view.top + 1), follow ? graphics.COLOR_TEXT : COLOR_HELD)
			x = interface.draw_text(table, x, hint_y, " to ", graphics.COLOR_DIM)
			x = interface.draw_text(table, x, hint_y, number(&buffer, view.top + view.text_rows), follow ? graphics.COLOR_TEXT : COLOR_HELD)
		}
		x = interface.draw_text(table, x, hint_y, " of ", graphics.COLOR_DIM)
		x = interface.draw_text(table, x, hint_y, number(&buffer, view.count), graphics.COLOR_TEXT)
		if view.gone {
			x = interface.draw_text(table, x, hint_y, "  older than the lines kept", graphics.COLOR_DIM)
		}
		if program == 0 && !measure {
			x = interface.draw_text(table, x, hint_y, "  the program does not run", COLOR_STOPPED)
		}
		hint_left = x
	}
	// The keys, at the right, when the text at the left leaves room for them.
	hint :: "page up, page down: move  other keys: to the program"
	hint_x := width - MARGIN - len(hint) * CELL_WIDTH
	if hint_left + 2 * CELL_WIDTH <= hint_x {
		interface.draw_text(table, hint_x, hint_y, hint, graphics.COLOR_DIM)
	}
	// The border of the completion list, one pixel outside its cells. It
	// comes last, so that the records before keep their places in the
	// table when the list opens or closes: the damage stays small.
	if view.list_columns > 0 {
		x := TEXT_X + view.list_left * CELL_WIDTH - 1
		y := text_y + view.list_top * CELL_HEIGHT - 1
		list_width := view.list_columns * CELL_WIDTH + 2
		list_height := view.list_rows * CELL_HEIGHT + 2
		interface.draw_rectangle(table, x, y, list_width, 1, COLOR_LIST_BORDER)
		interface.draw_rectangle(table, x, y + list_height - 1, list_width, 1, COLOR_LIST_BORDER)
		interface.draw_rectangle(table, x, y, 1, list_height, COLOR_LIST_BORDER)
		interface.draw_rectangle(table, x + list_width - 1, y, 1, list_height, COLOR_LIST_BORDER)
	}
	interface.window_frame_end(&drawing, &frame, window)
	if table.full {
		system.log("terminal: the draw table is full: records are missing")
	}
}

// status_bar_length gives the pixels of the bar of a status: value of total
// on length pixels. The program that writes chooses both numbers: a
// product value x length can pass the largest u64, so a large total is
// divided first. The bar is never longer than length.
status_bar_length :: proc "contextless" (value, total: u64, length: int) -> int {
	if total == 0 {
		return 0
	}
	shown := min(value, total)
	if total <= max(u64) / u64(length) {
		return int(shown * u64(length) / total)
	}
	return int(min(shown / (total / u64(length)), u64(length)))
}

fail :: proc "contextless" (text: string) -> ! {
	system.log("terminal: ", text)
	system.stop(1)
}

// The entry of the terminal: it opens the window of one program, starts the
// reader thread, then draws the lines and sends the keys until the machine
// stops.
//
// When the root service starts it, the entry:
//
// 1. reads its values: the name of the program, the columns (40 at least),
//    the rows (4 at least), and the flag that it measures;
// 2. opens a window of two pictures with the name of the program; with no
//    window, it writes "terminal: no surface" and stops with the code 1;
// 3. creates the three areas of the lines;
// 4. opens the terminal ring and maps the text region, read-only; a wrong
//    ring or region stops it with the code 1;
// 5. starts the reader thread, and writes "terminal: ok, ...".
//
// The first thread is then the drawer. It sleeps while nothing changes,
// and wakes for a record, a key, or every 250 ms to look at the state of
// the program. Page Up and Page Down move the view; each other key goes to
// the program, and a key is lost when the queue is full. When the program
// stops, the terminal shows its code and keeps its lines: it does not stop
// with it.
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
	drawing_start()

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
			// A new font: each record of the frame is the same, each pixel
			// of text is not. The next frame of each picture is whole.
			if event.kind == .Settings_Changed {
				interface.draw_whole_window_next(&drawing)
				dirty = true
				continue
			}
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
					if system.send(&source.completions, ring.Record{kind = u32(terminal.Input.Key), tag = event.code, values = {0 = u64(event.character), 1 = u64(event.modifiers)}}) {
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
