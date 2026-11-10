// The terminal: how a program gives text to a terminal, and how the
// terminal gives keys to the program (properties 4, 6, 13, 20).
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
// ring: one record for each key that the person presses (Input). The
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
package terminal

import "contract:ring"
import "support:system"

// The roles of the context of a program that has a terminal, and of the
// terminal itself.
GRANT_RING :: 6 // Memory: the terminal ring. The program writes its command queue.
GRANT_TEXT :: 7 // Memory: the text region. The terminal has the right Read only.
GRANT_PROGRAM :: 1 // For the terminal only: the program that writes, with the right Read.

// The values of the context of the terminal itself.
VALUE_NAME :: 0 // 4 values: the name of the program. It is the title of the window.
VALUE_COLUMNS :: 4
VALUE_ROWS :: 5
VALUE_MEASURE :: 6 // 1: the window shows the rates of the program.
COLUMNS_LIMIT :: 104
ROWS_LIMIT :: 32

RING_CAPACITY :: 4096
TEXT_PAGES :: 1024 // 4 MiB. A power of two.
TEXT_SIZE :: TEXT_PAGES * system.PAGE_SIZE
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
//           person, or a line that says what the program does now. The
//           terminal shows it after the last line. A new one replaces the
//           one before. tag: the count of bytes of its text. values[0]: a
//           Style. values[1]: the place of the cursor, in bytes from the
//           start of the text, or NO_CURSOR. No text and no cursor: the
//           terminal shows no such line.
Kind :: enum u32 {
	None   = 0,
	Text   = 1,
	Status = 2,
	Clear  = 3,
	Edit   = 4,
}

NO_CURSOR :: max(u64)

// The kind of a completion record: what the terminal gives to the program.
//   Key     The person pressed a key. tag: the code of the key
//           (display.KEY_*). values[0]: its character, or 0.
// The terminal keeps the keys Page Up and Page Down: they move its view.
// If the program does not read and the queue is full, the newest keys are
// lost: the terminal never waits for a program.
Input :: enum u32 {
	None = 0,
	Key  = 1,
}

Key :: struct {
	code:      u32,
	character: u8,
}

// What a run of text is. The terminal chooses the color of each tone.
Tone :: enum u8 {
	Default = 0,
	Dim     = 1,
	Strong  = 2,
	Good    = 3,
	Warning = 4,
	Bad     = 5,
	Accent  = 6,
	Number  = 7,
}

Flag :: enum u8 {
	End_Line = 0, // The line ends after this run.
	Color    = 1, // The run has its own color: Style.color, not the color of its tone.
	Reverse  = 2, // The color fills the cells, and the text has the color of the background.
}

// The style of a run: values[0] of a record. The zero value is the default.
Style :: struct {
	tone:     Tone,
	flags:    bit_set[Flag;u8],
	reserved: u16,
	color:    u32, // Red, green, blue: 0xRRGGBB.
}
#assert(size_of(Style) == 8)

// A terminal, as the program that writes sees it.
Terminal :: struct {
	ring:    ring.Ring,
	text:    []u8,
	written: u64, // The bytes that the program wrote since the start.
}

// open gives the terminal of this program. false: the program that started
// this one gave no terminal.
open :: proc "contextless" (ctx: ^system.Context) -> (terminal: Terminal, ok: bool) {
	if ctx.handles[GRANT_RING] == 0 || ctx.handles[GRANT_TEXT] == 0 || system.memory_size(ctx.handles[GRANT_TEXT]) != TEXT_PAGES {
		return {}, false
	}
	status: system.Status
	if terminal.ring, status = system.ring_open(ctx.handles[GRANT_RING]); status != .Ok {
		return {}, false
	}
	address: rawptr
	if address, status = system.memory_map(ctx.handles[GRANT_TEXT]); status != .Ok {
		return {}, false
	}
	terminal.text = ([^]u8)(address)[:TEXT_SIZE]
	return terminal, true
}

// A run of text and its style.
Run :: struct {
	text:  string,
	style: Style,
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
	part := text[:min(len(text), RUN_LIMIT)]
	append(terminal, part)
	push(terminal, ring.Record{kind = u32(Kind.Status), tag = u32(len(part)), values = {0 = transmute(u64)style, 1 = value, 2 = total}})
	system.wake_reader(&terminal.ring.commands)
}

// edit sets the line that the program changes, with the place of its
// cursor. edit(terminal, "") removes the line.
edit :: proc "contextless" (terminal: ^Terminal, text: string, cursor: u64 = NO_CURSOR, style: Style = {}) {
	part := text[:min(len(text), RUN_LIMIT)]
	append(terminal, part)
	push(terminal, ring.Record{kind = u32(Kind.Edit), tag = u32(len(part)), values = {0 = transmute(u64)style, 1 = cursor}})
	system.wake_reader(&terminal.ring.commands)
}

// key gives the next key that the person pressed. false: no key waits.
// A program waits for a key with system.wait_records on
// terminal.ring.completions.
key :: proc "contextless" (terminal: ^Terminal) -> (pressed: Key, ok: bool) {
	for {
		record := system.receive(&terminal.ring.completions) or_return
		if Input(record.kind) == .Key {
			return {code = record.tag, character = u8(record.values[0])}, true
		}
	}
}

clear :: proc "contextless" (terminal: ^Terminal) {
	push(terminal, ring.Record{kind = u32(Kind.Clear)})
	system.wake_reader(&terminal.ring.commands)
}

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
