// The terminal: how a program gives text to a terminal, and how the
// terminal gives keys to the program: records of a fixed size in a ring, as
// between any two programs, and only to the program that the terminal was
// given to.
//
// A program does not write a stream of bytes with commands hidden in it:
// no escape character and no escape sequence exists. A program sends
// records. Each record has a kind and typed fields: a run of text with its
// style, the end of a line, a status with a value and a total.
//
// The program and the terminal share two memory objects:
//   the terminal ring   One command record is one Record of this file.
//   the text region     The bytes of the text. The program writes them one
//                       after the other, and starts again at the first byte
//                       after the last. A record gives only the count of
//                       its bytes: a program cannot name another place.
//
// The terminal reads the records as fast as the program writes them. It
// draws at the rate of the screen, and it draws only the lines that the
// window shows: the display does not slow the program. When the ring is
// full, the program waits for the terminal.
//
// The input goes the other way, in the completion queue of the terminal
// ring: one record for each key that the input presses (Input). The
// program edits its line: the terminal does not know what a line of input
// is. The program shows the line with an Edit record; the terminal draws it
// after the last line, with a cursor.
//
// The root service makes the terminal ring and the text region, and starts
// the two programs. The terminal starts no program and holds three things:
// a surface, the two memory objects, and a handle that reads the state of
// the program. The program holds what its role gives, and no surface.
//
// The ring keeps at most RING_CAPACITY records that the terminal did not
// read, of RUN_LIMIT bytes at most: the program never writes over text
// that the terminal did not read.
//
// Who uses it: the console and each program that the root service starts
// with a terminal (`open`, `write`, `edit`, `key`), and the program
// `terminal` (the reading side: `List_Keeping`, `hint_form_choose`). The
// parts:
//
// - `Kind`, `Input`, `Style`, `Tone`, `Flag`: the records of the ring.
// - `Terminal`, `open`, `write`, `line`, `status`, `edit`, `hint`, `key`,
//   `clear`: the side of the program.
// - `Code_Kind`, `Code_Run`, `Code_Runs` (`code_runs.odin`): the colors of a
//   line of code.
// - `List_Row`, `List_Shown`, `List_Keeping`: the completion list, as the
//   terminal keeps it.
//
// ```odin
// terminal := terminal_records.open(ctx) or_return
// terminal_records.line(&terminal, {text = "ready: "}, {text = "3", style = {tone = .Number}})
// ```
//
// See [terminal](term:terminal) and [terminal ring](term:terminal-ring).
package terminal_records

import "contract:cut_mark"
import "contract:errors"
import "contract:ring"
import "support:system"

// The roles of the context of a program that has a terminal, and of the
// terminal itself.
GRANT_RING :: 6 // Memory: the terminal ring. The program writes its command queue.
GRANT_TEXT :: 7 // Memory: the text region. The terminal has the right Read only.
GRANT_PROGRAM :: 1 // For the terminal only: the program that writes, with the right Read.

// The values of the context of the terminal itself.
VALUE_NAME :: 0 // 4 values: the name of the program. It is the title of the window.
VALUE_COLUMNS :: 4 // The columns of the window, at most COLUMNS_LIMIT.
VALUE_ROWS :: 5 // The rows of the window, at most ROWS_LIMIT.
VALUE_MEASURE :: 6 // 1: the window shows the rates of the program.
COLUMNS_LIMIT :: 104 // The most columns of a terminal window.
ROWS_LIMIT :: 32 // The most rows of a terminal window.

RING_CAPACITY :: 4096 // The records of each queue of the terminal ring.
TEXT_PAGES :: 1024 // 4 MiB. A power of two.
TEXT_SIZE :: TEXT_PAGES * system.PAGE_SIZE // The bytes of the text region.
RUN_LIMIT :: 256 // The bytes of the text of one record.
#assert(RING_CAPACITY * RUN_LIMIT <= TEXT_SIZE / 2)

// The kind of a command record.
//   Text    tag: the count of bytes, in the text region after the bytes of
//           the record before. values[0]: a Style.
//   Status  One line that the terminal keeps in view, with a bar. A new
//           status replaces the one before. tag: the count of bytes of its
//           text. values[0]: a Style. values[1]: the value. values[2]: the
//           total; 0 removes the status.
//   Clear   The terminal forgets all the lines.
//   Edit    The line that the program changes: the line of input of the
//           input, or a line that says what the program does now. The
//           terminal shows it after the last line. A new one replaces the
//           one before. tag: the count of bytes of its text. values[0]: a
//           Style. values[1]: the place of the cursor, in bytes from the
//           start of the text, or NO_CURSOR. No text and no cursor: the
//           terminal shows no such line.
//   Hint    One line under the edit line, in the dim color: what the
//           program says about the line (the signature of the call at the
//           cursor). It has a long form, and a short form for a terminal
//           that is too narrow for the long one (hint_form_choose); the
//           text is the long form, then the short form. The terminal keeps
//           a free row under the edit line at all times and draws the hint
//           over it: a hint that comes or goes does not move the text. A
//           new one replaces the one before; no text removes it. tag: the
//           count of bytes of the two forms. values[0]: a Style. values[1],
//           values[2]: the first byte and the count of bytes of the part of
//           the long form that the terminal marks. values[3]: the bytes of
//           the long form. values[4], values[5]: the marked part of the
//           short form, from its first byte.
//   List_Row One row of the next completion list. tag: the count of bytes
//           of its text: the name, then what the name is. values[0]: the
//           number of the row, below LIST_ROWS. values[1]: the bytes of the
//           name. values[2], values[3]: the places of the name that matched
//           what the input typed (bit n: byte n of the name; values[2]
//           holds bytes 0 to 63).
//   List    The completion list that the terminal shows over its text, at
//           the edit line: the rows that List_Row gave before. values[0]:
//           the count of rows, at most LIST_ROWS; 0 removes the list.
//           values[1]: the row that is chosen, or NO_CHOICE. values[2]: the
//           place of the first row in all the names of the program, and
//           values[3] their count: with more names than rows, the list
//           shows a scroll bar. values[4]: the byte of the edit line where
//           the name starts: the list starts at its column.
//   Code_Runs The runs of code of the next record of a target
//           (code_runs.odin): what each part of its text is, so that the
//           terminal colors it. tag: the count of bytes of the runs, 4 for
//           each run, at most CODE_RUN_LIMIT runs. values[0]: the target,
//           Kind.Edit or Kind.List_Row; another target is not kept.
//           values[1]: for List_Row, the number of the row. The next record
//           of the target takes the runs; a record of the target with no
//           Code_Runs before it is plain.
// The terminal draws each byte of a list or a hint that is not a character
// of the font (under 32, over 126) as '?': the text of these records comes
// from the descriptions of other programs.
Kind :: enum u32 {
	None     = 0, // Not a record: the terminal skips it.
	Text     = 1, // A run of text.
	Status   = 2, // The status line.
	Clear    = 3, // Forget all the lines.
	Edit     = 4, // The edit line.
	Hint     = 5, // The hint line.
	List_Row  = 6, // One row of the next completion list.
	List      = 7, // Show the completion list.
	Code_Runs = 8, // The runs of code of the next record of a target.
}

// A new kind of record, or a new field, is a new version. 2: the kind
// Code_Runs, and the byte Style.code, which was the first byte of
// Style.reserved: a program of version 1 writes 0 there, the kind None.
TERMINAL_RECORD_VERSION :: 2

NO_CURSOR :: max(u64) // An Edit record with no cursor.
NO_CHOICE :: max(u64) // A List record with no chosen row.
LIST_ROWS :: 8 // The rows of a completion list.

// The kind of a completion record: what the terminal gives to the program.
//   Key     A key was pressed. tag: the code of the key
//           (display.KEY_*). values[0]: its character, or 0. values[1]:
//           the modifiers that were held (display.MODIFIER_*).
//           Control-R gives the character 'r' with MODIFIER_CONTROL.
// The terminal keeps the keys Page Up and Page Down: they move its view.
// If the program does not read and the queue is full, the newest keys are
// lost: the terminal never waits for a program.
Input :: enum u32 {
	None = 0, // Not a record: the program skips it.
	Key  = 1, // A key was pressed.
}

// One key, as `key` gives it to the program.
Key :: struct {
	code:      u32, // The code of the key (display.KEY_*).
	character: u8, // Its character in ASCII, or 0.
	modifiers: u32, // The modifiers held (display.MODIFIER_*).
}

// What a run of text is. The terminal chooses the color of each tone.
Tone :: enum u8 {
	Default = 0, // Plain text.
	Dim     = 1, // Text of less weight: a unit, a note.
	Strong  = 2, // Text of more weight: a title.
	Good    = 3, // A success: a check that passed.
	Warning = 4, // Something to look at.
	Bad     = 5, // A failure.
	Accent  = 6, // A name that the reader looks for.
	Number  = 7, // A number.
}

// A flag of the style of a run.
Flag :: enum u8 {
	End_Line = 0, // The line ends after this run.
	Color    = 1, // The run has its own color: Style.color, not the color of its tone.
	Reverse  = 2, // The color fills the cells, and the text has the color of the background.
}

// The style of a run: values[0] of a record. The zero value is the default.
// The color of a run: Style.color with the flag Color; if not, the color of
// its code kind when the kind has one; if not, the color of its tone.
Style :: struct {
	tone:     Tone, // What the run is.
	flags:    bit_set[Flag;u8], // End_Line, Color, Reverse.
	code:     Code_Kind, // A Text record: what the run is in a line of code (code_runs.odin).
	reserved: u8, // 0.
	color:    u32, // Red, green, blue: 0xRRGGBB.
}
#assert(size_of(Style) == 8)

// A terminal, as the program that writes sees it.
Terminal :: struct {
	ring:    ring.Ring, // The terminal ring: this program writes its commands.
	text:    []u8, // The text region.
	written: u64, // The bytes that the program wrote since the start.
}

// open gives the terminal of this program. false: the program that started
// this one gave no terminal (the record No_Grant, unit Terminal), or a
// kernel operation failed (its record).
// error: the record of a failure, if the caller gives one:
// system.wrapper_error_text(writer, &error, "terminal.open", {"ctx"}).
open :: proc "contextless" (ctx: ^system.Context, error: ^errors.Error_Record = nil) -> (terminal: Terminal, ok: bool) {
	if ctx.handles[GRANT_RING] == 0 || ctx.handles[GRANT_TEXT] == 0 {
		errors.fail(error, 0, .No_Grant, .Terminal)
		return {}, false
	}
	if size := system.memory_size(ctx.handles[GRANT_TEXT], error); size != TEXT_PAGES {
		if size != 0 {
			errors.fail(error, 0, .Bad_Value, .Pages, 1, i64(size), TEXT_PAGES) // The text region of the grant has another size.
		}
		return {}, false
	}
	status: system.Status
	if terminal.ring, status = system.ring_open(ctx.handles[GRANT_RING], error); status != .Ok {
		return {}, false
	}
	address: rawptr
	if address, status = system.memory_map(ctx.handles[GRANT_TEXT], error = error); status != .Ok {
		return {}, false
	}
	terminal.text = ([^]u8)(address)[:TEXT_SIZE]
	return terminal, true
}

// A run of text and its style.
Run :: struct {
	text:  string, // The bytes; a run longer than RUN_LIMIT is several records.
	style: Style, // Its style.
}

// write gives runs of text to the terminal. The terminal has all of them
// when write returns: the library keeps nothing. A text of more than
// RUN_LIMIT bytes is several records. If the ring is full, the thread
// waits. One call with several runs costs less than one call for each run:
// the reader is told one time.
write :: proc "contextless" (terminal: ^Terminal, runs: ..Run) {
	for run in runs {
		text := run.text
		for {
			part := text[:min(len(text), RUN_LIMIT)]
			text = text[len(part):]
			style := run.style
			if len(text) != 0 {
				style.flags -= {.End_Line}
			}
			append(terminal, part)
			push(terminal, ring.Record{kind = u32(Kind.Text), tag = u32(len(part)), values = {0 = transmute(u64)style}})
			if len(text) == 0 {
				break
			}
		}
	}
	system.wake_reader(&terminal.ring.commands)
}

// line gives runs of text, and ends the line after the last run.
line :: proc "contextless" (terminal: ^Terminal, runs: ..Run) {
	if len(runs) == 0 {
		write(terminal, Run{style = {flags = {.End_Line}}})
		return
	}
	last := runs[len(runs) - 1]
	last.style.flags += {.End_Line}
	// The runs before the last, then the last with the end of the line.
	for run in runs[:len(runs) - 1] {
		text := run.text
		for len(text) != 0 {
			part := text[:min(len(text), RUN_LIMIT)]
			text = text[len(part):]
			style := run.style
			style.flags -= {.End_Line}
			append(terminal, part)
			push(terminal, ring.Record{kind = u32(Kind.Text), tag = u32(len(part)), values = {0 = transmute(u64)style}})
		}
	}
	write(terminal, last)
}

// status sets the status of the terminal: a text, and a value of a total.
// A total of 0 removes the status.
status :: proc "contextless" (terminal: ^Terminal, text: string, value, total: u64, style: Style = {}) {
	marked: [RUN_LIMIT]u8
	part := record_text(text, &marked)
	append(terminal, part)
	push(terminal, ring.Record{kind = u32(Kind.Status), tag = u32(len(part)), values = {0 = transmute(u64)style, 1 = value, 2 = total}})
	system.wake_reader(&terminal.ring.commands)
}

// edit sets the line that the program changes, with the place of its
// cursor. edit(terminal, "") removes the line.
edit :: proc "contextless" (terminal: ^Terminal, text: string, cursor: u64 = NO_CURSOR, style: Style = {}) {
	marked: [RUN_LIMIT]u8
	part := record_text(text, &marked)
	append(terminal, part)
	push(terminal, ring.Record{kind = u32(Kind.Edit), tag = u32(len(part)), values = {0 = transmute(u64)style, 1 = cursor}})
	system.wake_reader(&terminal.ring.commands)
}

// A form of a hint line, and the part of it that the terminal marks: the
// first byte and the count of bytes.
Hint_Form :: enum u8 {
	Long  = 0, // The long form: the whole signature.
	Short = 1, // The short form, for a narrow terminal.
}

// One form of a hint: its text and its marked part.
Hint_Text :: struct {
	text:         string, // The text of the form.
	marked_start: int, // The first byte that the terminal marks.
	marked_count: int, // The bytes that it marks.
}

// hint sets the line under the edit line: a long form, a short form ("" if
// the long form is the only one), and a style. A long form of 0 bytes
// removes it. The two forms together are cut to RUN_LIMIT bytes, the long
// form first.
hint :: proc "contextless" (terminal: ^Terminal, long: Hint_Text, short: Hint_Text, style: Style) {
	long_part := long.text[:min(len(long.text), RUN_LIMIT)]
	short_part := short.text[:min(len(short.text), RUN_LIMIT - len(long_part))]
	append(terminal, long_part)
	append(terminal, short_part)
	push(terminal, ring.Record{kind = u32(Kind.Hint), tag = u32(len(long_part) + len(short_part)), values = {0 = transmute(u64)style, 1 = u64(max(long.marked_start, 0)), 2 = u64(max(long.marked_count, 0)), 3 = u64(len(long_part)), 4 = u64(max(short.marked_start, 0)), 5 = u64(max(short.marked_count, 0))}})
	system.wake_reader(&terminal.ring.commands)
}

// hint_form_choose chooses the form of a hint line for a width of columns
// cells: the long form when it fits; if not, the short form when the
// program gave one; if not, the long form. shown is the bytes of the form
// that the row shows: the form, cut to the columns.
hint_form_choose :: proc "contextless" (long_count, short_count, columns: int) -> (form: Hint_Form, shown: int) {
	room := max(columns, 0)
	if long_count <= room || short_count <= 0 {
		return .Long, clamp(long_count, 0, room)
	}
	return .Short, min(short_count, room)
}

// list_row gives one row of the next completion list: a name, what it is,
// and the places of the name that matched. A name and its text are cut to
// RUN_LIMIT bytes together, the name first.
list_row :: proc "contextless" (terminal: ^Terminal, row: int, name: string, about: string, matched: [2]u64) {
	name_part := name[:min(len(name), RUN_LIMIT)]
	about_part := about[:min(len(about), RUN_LIMIT - len(name_part))]
	append(terminal, name_part)
	append(terminal, about_part)
	push(terminal, ring.Record{kind = u32(Kind.List_Row), tag = u32(len(name_part) + len(about_part)), values = {0 = u64(row), 1 = u64(len(name_part)), 2 = matched[0], 3 = matched[1]}})
}

// list_show shows the rows that list_row gave: row_count rows, the chosen
// one (NO_CHOICE: none), the place of the first row in all the names and
// their count, and the byte of the edit line where the name starts.
// list_show(terminal, 0, ...) removes the list.
list_show :: proc "contextless" (terminal: ^Terminal, row_count: int, chosen: u64, first: int, total: int, anchor: int) {
	push(terminal, ring.Record{kind = u32(Kind.List), values = {0 = u64(clamp(row_count, 0, LIST_ROWS)), 1 = chosen, 2 = u64(max(first, 0)), 3 = u64(max(total, 0)), 4 = u64(max(anchor, 0))}})
	system.wake_reader(&terminal.ring.commands)
}

// What a terminal keeps of the completion list of its program: the rows
// that List_Row records gave, and the list that the last List record shows.
// The values come from the program: each one is brought inside its array
// before it is kept. The rows given before a List go to that List only: a
// List with no new rows shows empty rows, never the rows of a list before,
// which can come from another program of the same terminal.
List_Row :: struct {
	text:        [RUN_LIMIT]u8, // The name, then what the name is.
	length:      int, // The bytes of `text` in use.
	name_length: int, // The bytes of the name, at the start of `text`.
	matched:     [2]u64, // Bit n: byte n of the name matched what the input typed.
	code:        Code_Runs, // The runs of code of the row, checked against its text. None: the row is plain.
}

// The completion list that the terminal shows now.
List_Shown :: struct {
	rows:      [LIST_ROWS]List_Row, // The rows.
	row_count: int, // The rows in use. 0: no list.
	chosen:    int, // -1: no row is chosen.
	first:     int, // The place of the first row in all the names.
	total:     int, // All the names: more than row_count shows a scroll bar.
	anchor:    int, // The byte of the edit line where the name starts.
}

// What the terminal keeps of the completion lists: the rows of the next
// list, and the list that it shows.
List_Keeping :: struct {
	next:         [LIST_ROWS]List_Row, // The rows given since the last List.
	pending:      [LIST_ROWS]Code_Runs, // The runs that the next List_Row of each row takes.
	shown:        List_Shown, // The list on the screen.
	runs_refused: u64, // The lists of runs that were refused: each one left its row plain.
}

// list_keep_row keeps the row of a List_Row record: values[0] its number,
// values[1] the bytes of its name, values[2] and values[3] the matched
// places. The text is in two parts (the text region starts again at its
// first byte). A number past the rows is not kept. The row takes the runs
// of code that came for its number since its last List_Row, when they fit
// its text; if not, it is plain and the refusal is counted.
list_keep_row :: proc "contextless" (keeping: ^List_Keeping, values: [7]u64, first, second: []u8) {
	if values[0] >= LIST_ROWS {
		return
	}
	row := &keeping.next[values[0]]
	row.length = copy(row.text[:], first)
	row.length += copy(row.text[row.length:], second)
	row.name_length = int(min(values[1], u64(row.length)))
	row.matched = {values[2], values[3]}
	row.code = keeping.pending[values[0]]
	keeping.pending[values[0]] = {}
	if row.code.count != 0 && !code_runs_check(&row.code, row.length) {
		keeping.runs_refused += 1
	}
}

// list_keep_code_runs keeps the runs of a Code_Runs record for a list row:
// values[1] the number of the row. A number past the rows, or bytes that
// are not a whole count of runs, are not kept.
list_keep_code_runs :: proc "contextless" (keeping: ^List_Keeping, values: [7]u64, first, second: []u8) {
	if values[1] >= LIST_ROWS {
		keeping.runs_refused += 1
		return
	}
	runs, ok := code_runs_read(first, second)
	if !ok {
		keeping.runs_refused += 1
	}
	keeping.pending[values[1]] = runs
}

// list_keep_show shows the rows given since the last List, with the values
// of a List record, then forgets them.
list_keep_show :: proc "contextless" (keeping: ^List_Keeping, values: [7]u64) {
	shown := &keeping.shown
	shown.rows = keeping.next
	keeping.next = {}
	shown.row_count = int(min(values[0], LIST_ROWS))
	shown.chosen = values[1] < u64(shown.row_count) ? int(values[1]) : -1
	shown.total = int(min(max(values[3], u64(shown.row_count)), 1 << 20))
	shown.first = int(min(values[2], u64(shown.total - shown.row_count)))
	shown.anchor = int(min(values[4], RUN_LIMIT))
}

// list_keep_forget forgets the list and the rows given: the program of the
// terminal stopped.
list_keep_forget :: proc "contextless" (keeping: ^List_Keeping) {
	refused := keeping.runs_refused
	keeping^ = {}
	keeping.shown.chosen = -1
	keeping.runs_refused = refused
}

// record_text gives the text of a record that holds one line as it is:
// the text when it has at most RUN_LIMIT bytes, else its start with the cut
// mark and the count of the missing bytes, written in buffer. The terminal
// draws the line whole, so a cut there is not seen without the mark.
record_text :: proc "contextless" (text: string, buffer: ^[RUN_LIMIT]u8) -> string {
	if len(text) <= RUN_LIMIT {
		return text
	}
	count := copy(buffer[:], text)
	marked, _, _ := cut_mark.apply(buffer[:], count, len(text) - count)
	return string(buffer[:marked])
}

// key gives the next key that was pressed. false: no key waits.
// A program waits for a key with system.wait_records on
// terminal.ring.completions.
key :: proc "contextless" (terminal: ^Terminal) -> (pressed: Key, ok: bool) {
	for {
		record := system.receive(&terminal.ring.completions) or_return
		if Input(record.kind) == .Key {
			return {code = record.tag, character = u8(record.values[0]), modifiers = u32(record.values[1])}, true
		}
	}
}

// clear tells the terminal to forget all the lines.
clear :: proc "contextless" (terminal: ^Terminal) {
	push(terminal, ring.Record{kind = u32(Kind.Clear)})
	system.wake_reader(&terminal.ring.commands)
}

// append writes bytes in the text region after the bytes written before,
// and starts again at its first byte after its last.
@(private)
append :: proc "contextless" (terminal: ^Terminal, text: string) {
	place := int(terminal.written % TEXT_SIZE)
	first := min(len(text), TEXT_SIZE - place)
	copy(terminal.text[place:], text[:first])
	copy(terminal.text, text[first:])
	terminal.written += u64(len(text))
}

// push writes a record with no wake. If the ring is full, the thread
// waits: wait_end wakes the reader first.
@(private)
push :: proc "contextless" (terminal: ^Terminal, record: ring.Record) {
	queue := &terminal.ring.commands
	for !ring.push(queue, record) {
		wait: system.Wait
		system.wait_room(&wait, queue)
		if !system.wait_spin(&wait) {
			system.wait_end(&wait)
		}
	}
}
