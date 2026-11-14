// A system tool: the log of the machine, as records.
//
// Each record has a time, a program, a thread, a level, a channel and a
// text. The kernel writes the records in one memory object; this program
// maps it with the right Read, and waits on its counter. The top part
// counts the records of each channel. The bottom part shows the last
// records: the color of the mark is the level, and the color of the name
// is the program. Each value of a text is in the color of its value kind,
// as the record keeps it (modus:contract/value_kinds); the head of the column of
// the text is the legend of the kinds. A text that starts with its program,
// or its channel, and ": " shows without that start: the columns at its
// left already say it. The record keeps its text whole.
//
// The program needs the grant to read the records of the log. It is also a
// service: records() and value_runs() give the records and their value runs
// as tables (exports.odin).
//
// **What it is for.** The log is the one record of what the machine did:
// the kernel and every program write to it, and the serial port prints the
// same texts. This program shows the log as [log records](term:log-record)
// with typed fields, not as lines of text: a reader sees at once which
// program wrote a record, at which [level](term:level), on which
// [channel](term:channel), and which parts of the text are values (a
// number, a size, a time, a module, a version, a status: the
// [value runs](term:value-run)). It shows that a log is data, not text to
// parse again.
//
// **What a reader sees.** Start it from the menu of the programs, or with
// `start("log")` in the console. The window has:
//
// - a top line: the count of records read, the count lost, and the count of
//   each level;
// - the channels, each with its count of records (at most 12; the others
//   count together);
// - the last 30 records: the time in seconds, the program, the channel and
//   the text, with the legend of the value kinds over the column of the
//   text.
//
// At its start it writes two records: `log: the kernel wrote <count>
// records in the channel boot` and `log: ok, <count> records, <count> lost,
// <count> channels`.
//
// **Lost records.** The kernel keeps the last 2047 records in a ring of
// memory, and writes over the oldest one when the ring is full. A reader
// that is slower than the writers loses records. This program counts them,
// in red when the count is not 0.
//
// **Its grants**: **Log_Records**, the memory of the log records with the
// right Read, and **Serve**, its exports. The program writes no record in
// the name of another program: the kernel sets the program, the thread and
// the time of each record.
//
// **Its exports** (`exports.odin`): `records` and `value_runs`, to a caller
// that [acts for the principal](term:acts-for-the-principal).
//
// ```
// connect("log")
// log.records(0)
// where(log.records(0), "level", "error")
// ```
package log

import "modus:contract/value_kinds"
import "modus:support/display"
import "modus:support/graphics"
import "modus:support/system"

ROWS :: 30
CHANNELS :: 12
MARGIN :: 12
LINE :: 16
COLUMN_PROGRAM :: 11 * 8 // After "00000.000" and two spaces.
COLUMN_CHANNEL :: COLUMN_PROGRAM + 13 * 8
COLUMN_TEXT :: COLUMN_CHANNEL + 11 * 8
TEXT_CHARACTERS :: 80
WIDTH :: 2 * MARGIN + COLUMN_TEXT + TEXT_CHARACTERS * 8
TOP_LINES :: 4
HEIGHT :: 2 * MARGIN + (TOP_LINES + ROWS) * LINE

COLOR_PANEL :: 0x131B26
COLOR_ACCENT :: 0x4A9CF0

@(rodata)
level_colors := [system.Log_Level]graphics.Color {
	.Info    = 0x58D878,
	.Debug   = 0x7C8A99,
	.Warning = 0xE0A040,
	.Error   = 0xF06060,
}

@(rodata)
program_colors := [?]graphics.Color{0x4A9CF0, 0x38C0B0, 0xD070B0, 0xE0A040, 0x8E7CC3, 0x58D878, 0xE07860, 0x9CC040}

Channel :: struct {
	name:  [16]u8,
	count: u64,
}

rows: [ROWS]system.Log_Record // The last records: rows[n % ROWS] is record n of this reader.
row_count: u64
lost: u64
channels: [CHANNELS]Channel
channel_count: int
other_channels: u64 // Records of the channels that have no place in `channels`.
level_counts: [system.Log_Level]u64
kernel_boot: u64 // Records of the kernel in the channel "boot".

same :: proc "contextless" (name: []u8, text: string) -> bool {
	return system.name_of(name) == text
}

// The kinds that the legend shows: the kinds that the logs of the system
// write.
@(rodata)
legend_kinds := [?]value_kinds.Value_Kind{.Number, .Size, .Time, .Module, .Version, .Status}

@(rodata)
legend_names := [?]string{"number", "size", "time", "module", "version", "status"}

// repeated_start gives the count of bytes at the start of a text that say
// its program, then its channel, each followed by ": ": "kernel: boot: " in
// a record of the kernel in the channel boot.
repeated_start :: proc "contextless" (record: ^system.Log_Record, text: string) -> int {
	skip := 0
	fields := [2]string{system.name_of(record.name[:]), system.name_of(record.channel[:])}
	for field in fields {
		rest := text[skip:]
		if field != "" && len(rest) >= len(field) + 2 && rest[:len(field)] == field && rest[len(field):][:2] == ": " {
			skip += len(field) + 2
		}
	}
	return skip
}

// record_text_draw draws the bytes from ..< end of the text of a record:
// each value run in the color of its kind, the rest in plain. A run that
// starts before `from`, or that the record cannot hold, is drawn plain.
record_text_draw :: proc "contextless" (canvas: graphics.Canvas, x, y: int, record: ^system.Log_Record, from, end: int, plain: graphics.Color) {
	text_count := min(int(record.text_count), len(record.text))
	at := from
	left := x
	for index in 0 ..< min(int(record.run_count), len(record.runs)) {
		run := record.runs[index]
		start, run_end, ok := value_kinds.value_run_in_text(run, text_count)
		if !ok || start < at {
			continue
		}
		if start >= end {
			break
		}
		run_end = min(run_end, end)
		left = graphics.text(canvas, left, y, string(record.text[at:start]), plain)
		left = graphics.text(canvas, left, y, string(record.text[start:run_end]), graphics.value_kind_color(run.kind, false, plain))
		at = run_end
	}
	graphics.text(canvas, left, y, string(record.text[at:end]), plain)
}

// take keeps one new record: it is the newest of the last 30 rows, and it
// counts for its level and for its channel. A channel that finds no free
// place of the 12 counts in `other_channels`.
take :: proc "contextless" (record: ^system.Log_Record) {
	rows[row_count % ROWS] = record^
	row_count += 1
	level_counts[record.level] += 1
	if record.program == 0 && same(record.channel[:], "boot") {
		kernel_boot += 1
	}
	for &channel in channels[:channel_count] {
		if channel.name == record.channel {
			channel.count += 1
			return
		}
	}
	if channel_count == CHANNELS {
		other_channels += 1
		return
	}
	channels[channel_count] = {name = record.channel, count = 1}
	channel_count += 1
}

// draw draws the whole window: the counts, the channels, the legend of the
// value kinds, and the last records. A text drops the start that repeats
// its program and its channel (`repeated_start`).
draw :: proc "contextless" (canvas: graphics.Canvas) {
	graphics.clear(canvas, graphics.COLOR_BACKGROUND)
	graphics.fill(canvas, MARGIN, MARGIN - 4, WIDTH - 2 * MARGIN, 2, COLOR_ACCENT)
	x := graphics.text(canvas, MARGIN, MARGIN, "the log  ", COLOR_ACCENT)
	x = graphics.unsigned(canvas, x, MARGIN, row_count, graphics.COLOR_TEXT)
	x = graphics.text(canvas, x, MARGIN, " records read, ", graphics.COLOR_DIM)
	x = graphics.unsigned(canvas, x, MARGIN, lost, lost == 0 ? graphics.COLOR_TEXT : level_colors[.Error])
	x = graphics.text(canvas, x, MARGIN, " lost    ", graphics.COLOR_DIM)
	for count, level in level_counts {
		names := [system.Log_Level]string {
			.Info    = "info ",
			.Debug   = "debug ",
			.Warning = "warning ",
			.Error   = "error ",
		}
		graphics.fill(canvas, x, MARGIN + 4, 8, 8, level_colors[level])
		x = graphics.text(canvas, x + 12, MARGIN, names[level], graphics.COLOR_DIM)
		x = graphics.unsigned(canvas, x, MARGIN, count, graphics.COLOR_TEXT) + 16
	}

	// The channels, with the count of records of each one.
	x = graphics.text(canvas, MARGIN, MARGIN + LINE, "channels ", graphics.COLOR_DIM)
	y := MARGIN + LINE
	for &channel in channels[:channel_count] {
		name := system.name_of(channel.name[:])
		if name == "" {
			name = "(none)"
		}
		width := (len(name) + 1) * 8 + graphics.text_width("00000") + 12
		if x + width > WIDTH - MARGIN {
			x = MARGIN + 9 * 8
			y += LINE
		}
		graphics.fill(canvas, x - 4, y, width - 8, LINE, COLOR_PANEL)
		after := graphics.text(canvas, x, y, name, graphics.COLOR_TEXT)
		graphics.unsigned(canvas, after + 8, y, channel.count, COLOR_ACCENT)
		x += width
	}

	top := MARGIN + TOP_LINES * LINE
	graphics.text(canvas, MARGIN, top - LINE, "time (s)", graphics.COLOR_DIM)
	graphics.text(canvas, MARGIN + COLUMN_PROGRAM, top - LINE, "program", graphics.COLOR_DIM)
	graphics.text(canvas, MARGIN + COLUMN_CHANNEL, top - LINE, "channel", graphics.COLOR_DIM)
	x = graphics.text(canvas, MARGIN + COLUMN_TEXT, top - LINE, "text   ", graphics.COLOR_DIM)
	for kind, index in legend_kinds {
		x = graphics.text(canvas, x, top - LINE, legend_names[index], graphics.value_kind_color(kind, false)) + 16
	}
	shown := min(row_count, ROWS)
	for line in 0 ..< shown {
		record := &rows[(row_count - shown + line) % ROWS]
		y = top + int(line) * LINE
		if line % 2 == 1 {
			graphics.fill(canvas, MARGIN - 4, y, WIDTH - 2 * MARGIN + 8, LINE, COLOR_PANEL)
		}
		graphics.fill(canvas, MARGIN - 4, y, 3, LINE, level_colors[record.level])
		milliseconds := record.time / 1000
		x = graphics.unsigned(canvas, MARGIN + 4, y, milliseconds / 1000, graphics.COLOR_DIM, 4)
		x = graphics.text(canvas, x, y, ".", graphics.COLOR_DIM)
		graphics.unsigned(canvas, x, y, milliseconds % 1000, graphics.COLOR_DIM, 3)
		name := system.name_of(record.name[:])
		graphics.text(canvas, MARGIN + COLUMN_PROGRAM, y, name[:min(len(name), 12)], record.program == 0 ? graphics.COLOR_TEXT : program_colors[record.program % len(program_colors)])
		graphics.text(canvas, MARGIN + COLUMN_CHANNEL, y, system.name_of(record.channel[:10]), graphics.COLOR_DIM)
		text_count := min(int(record.text_count), len(record.text))
		from := repeated_start(record, string(record.text[:text_count]))
		record_text_draw(canvas, MARGIN + COLUMN_TEXT, y, record, from, min(text_count, from + TEXT_CHARACTERS), record.level == .Error ? level_colors[.Error] : graphics.COLOR_TEXT)
	}
}

// entry opens the window of the log and runs its loop: it shows each new
// log record until the program is stopped.
//
// **What it sets up**: a window, the reader of the log records (the memory
// of the records that the grant **Log_Records** gives, mapped read-only),
// and the service ring of its exports, which read the same memory.
//
// **The loop.** One wait covers the window, the counter of the log and the
// service ring. After each wake it takes every new record (`take`): the
// counts of each level and of each channel, and the last 30 records. It
// adds the records that the kernel wrote over before the read to the lost
// count. It draws the window again only when a record came. At the first
// turn it writes two records of its own on the channel `log`: the count of
// the records of the kernel on the channel `boot`, then
// `log: ok, <count> records, <count> lost, <count> channels`. Then it runs
// the calls of its exports.
//
// **The stop**: with no window, it stops with the code 1. With no grant of
// the log records, it writes `log: cannot read the records of the log:
// status <status>` at the level error, and stops with the code 1. Else it
// never returns.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	window, ok := display.open(ctx, WIDTH, HEIGHT, "log")
	if !ok {
		system.stop(1)
	}
	reader, status := system.log_open(ctx.handles[system.GRANT_LOG_RECORDS])
	if status != .Ok {
		system.log_in("log", .Error, "log: cannot read the records of the log: status ", u64(status))
		system.stop(1)
	}
	// The service reads the same memory object: exports.odin.
	reader_head, reader_records = reader.head, reader.records
	service, _ = system.service_open(ctx)
	logged := false
	for {
		wait: system.Wait
		display.wait_events(&wait, &window)
		system.wait_log(&wait, &reader)
		system.service_wait(&wait, &service)
		changed := !logged
		for {
			record, late, has := system.log_next(&reader)
			lost += late
			if !has {
				break
			}
			take(&record)
			changed = true
		}
		for _ in display.next_event(&window) {}
		if changed {
			draw(window.canvas)
			display.present(&window)
		}
		if !logged {
			logged = true
			system.log_in("log", .Info, "log: the kernel wrote ", kernel_boot, " records in the channel boot")
			system.log_in("log", .Info, "log: ok, ", row_count, " records, ", lost, " lost, ", u64(channel_count), " channels")
			continue
		}
		system.wait_end(&wait)
		system.service_run(&service)
	}
}
