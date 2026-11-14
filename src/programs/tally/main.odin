// A count that its callers add to. This module shows that one file has each role: the system has no difference between a command line program, a library and a dynamic library.
//
// The same file, with the same hash, is used in four ways:
//   start("tally")     a program, with a window that shows the count
//   connect("tally")   a service: the calls go to the program that runs
//   load("tally")      a library: the calls are direct, in the memory of the caller
//   isolate("tally")   a sandboxed program: the calls go through a ring
//
// The data of a module belongs to the program that runs it. The four uses give three counts: the program and the service have one count, the caller that loads the module has its own, and the sandboxed program has its own.
//
// An export needs nothing from the entry: it reads and writes the data of the module only. That is the one rule for a module that has each role.
//
// **Grants**, as the root service gives them: **Serve**, so that `connect("tally")` reaches the program that runs.
// `load` and `isolate` need no grant of tally: the console maps the file from the boot image.
//
// **What a reader sees**, as a program: the count, the number of adds, the last 8 notes with the newest first, and
// the callers and the calls. The key Space adds 1, with the note "a key of the program". The log has "tally: ok"
// when the window opens.
//
// **Example**, in the console:
//
// ```
// load("tally")
// add(2, "two")       the count of the console: 2
// connect("tally")
// tally.add(5, "five")  the count of the program: 5
// ```
//
// The design: (docs/MODULE_CONTRACT.md, "3. Static is dynamic").
package tally

import "modus:contract/errors"
import "modus:support/display"
import "modus:support/graphics"
import "modus:support/interface"
import "modus:support/system"

// The window is built with the interface package (docs/INTERFACE.md).
records_now, records_before: [512]interface.Draw_Record
text_now, text_before: [8192]u8
drawing: interface.Window_Drawing

WIDTH :: 400
HEIGHT :: 214
NOTE_CAPACITY :: 8
NOTE_SIZE :: 36

Note :: struct {
	amount: i64,
	text:   [NOTE_SIZE]u8,
	count:  int,
}

count: i64
calls: i64 // The calls of add.
notes: [NOTE_CAPACITY]Note // notes[(calls - 1) % NOTE_CAPACITY] is the last.

// add adds an amount to the count, with a note that says why.
//
// The count and the notes are data of the module, in the program that runs it: the four ways of tally give three
// counts. The module keeps the last 8 notes.
//
// - **amount**: the amount, positive or negative.
// - **note**: why, 36 bytes at most.
//
// The result is the new count, never negative. It fails with -1 and an error record, and the count does not
// change:
//
// - `Too_Long`: the note has more than 36 bytes;
// - `Too_Small`: the amount takes the count below 0; the record holds the least amount that is allowed;
// - `Bad_Value`: the count passes the largest integer.
//
// Example: `tally.add(-3, "a refund")`.
@(export, link_name = "add")
add :: proc "c" (amount: i64, note: ^string, error: ^errors.Error_Record) -> i64 {
	if len(note) > NOTE_SIZE {
		return errors.fail(error, -1, .Too_Long, .Bytes, 2, i64(len(note)), NOTE_SIZE)
	}
	if amount < -count {
		return errors.fail(error, -1, .Too_Small, .None, 1, amount, -count)
	}
	if amount > max(i64) - count {
		return errors.fail(error, -1, .Bad_Value, .None, 1, amount, max(i64) - count)
	}
	item := &notes[u64(calls) % NOTE_CAPACITY]
	item.amount = amount
	item.count = min(len(note), NOTE_SIZE)
	for i in 0 ..< item.count {
		item.text[i] = note[i]
	}
	calls += 1
	count += amount
	return count
}

// total gives the count.
//
// The count of the program that runs the module: after `load("tally")` it is the count of the caller itself. It
// never fails.
@(export, link_name = "total")
total :: proc "c" () -> i64 {
	return count
}

// adds gives the number of calls of add after the start, or after the last reset.
//
// A refused add does not count. A test compares it with the calls that it made: a call over a ring that ran two
// times shows here.
@(export, link_name = "adds")
adds :: proc "c" () -> i64 {
	return calls
}

// last gives the note of the last add. The text is empty before the first add.
//
// The result is the length of the note, 36 at most; a text shorter than the note gets its first bytes.
@(export, link_name = "last")
last :: proc "c" (result: ^[]u8) -> i64 {
	if calls == 0 {
		return 0
	}
	item := &notes[u64(calls - 1) % NOTE_CAPACITY]
	for i in 0 ..< min(item.count, len(result)) {
		result[i] = item.text[i]
	}
	return i64(item.count)
}

// reset puts the count at 0 and removes the notes. The result is the count before.
//
// It also sets the count of [adds](tally.adds) to 0. It never fails.
@(export, link_name = "reset")
reset :: proc "c" () -> i64 {
	before := count
	count, calls, notes = 0, 0, {}
	return before
}

COLOR_COUNT :: 0xF0C050
COLOR_PLUS :: 0x58C878
COLOR_MINUS :: 0xE06C60

// draw builds a frame of the window with the interface package.
draw :: proc "contextless" (window: ^display.Window, service: ^system.Service) {
	if drawing.now.records == nil {
		drawing = interface.window_drawing_of(records_now[:], records_before[:], text_now[:], text_before[:])
	}
	frame := interface.window_frame_begin(&drawing, window)
	draw_records(frame.table, service)
	interface.window_frame_end(&drawing, &frame, window)
}

draw_records :: proc "contextless" (table: ^interface.Draw_Table, service: ^system.Service) {
	interface.draw_rectangle(table, 0, 0, WIDTH, HEIGHT, graphics.COLOR_BACKGROUND)
	buffer: [24]u8
	x := interface.draw_text(table, 12, 10, "count ", graphics.COLOR_DIM)
	x = interface.draw_text(table, x, 10, system.format(buffer[:], count), COLOR_COUNT)
	x = interface.draw_text(table, x + 24, 10, "adds ", graphics.COLOR_DIM)
	interface.draw_text(table, x, 10, system.format(buffer[:], calls), graphics.COLOR_TEXT)
	interface.draw_rectangle(table, 12, 32, WIDTH - 24, 1, 0x30363C)
	// The notes, the last one first.
	for row in 0 ..< min(calls, NOTE_CAPACITY) {
		item := &notes[u64(calls - 1 - row) % NOTE_CAPACITY]
		y := 40 + int(row) * 18
		amount := system.format(buffer[:], item.amount)
		if item.amount >= 0 {
			interface.draw_text(table, 12, y, "+", COLOR_PLUS)
		}
		interface.draw_text(table, item.amount >= 0 ? 20 : 12, y, amount, item.amount >= 0 ? COLOR_PLUS : COLOR_MINUS)
		interface.draw_text(table, 92, y, string(item.text[:item.count]), row == 0 ? graphics.COLOR_TEXT : graphics.COLOR_DIM)
	}
	interface.draw_rectangle(table, 12, HEIGHT - 30, WIDTH - 24, 1, 0x30363C)
	x = interface.draw_text(table, 12, HEIGHT - 22, "space: add 1", graphics.COLOR_DIM)
	x = interface.draw_text(table, x + 24, HEIGHT - 22, "callers ", graphics.COLOR_DIM)
	x = interface.draw_text(table, x, HEIGHT - 22, system.format(buffer[:], u64(service.connected)), graphics.COLOR_TEXT)
	x = interface.draw_text(table, x + 16, HEIGHT - 22, "calls ", graphics.COLOR_DIM)
	interface.draw_text(table, x, HEIGHT - 22, system.format(buffer[:], service.calls), graphics.COLOR_TEXT)
}

// The entry of tally: it runs only when tally is a program (`start` or
// `connect`), never after `load`. It opens the service and the window, then
// runs the calls and the key Space in one loop until the principal closes
// the window.
//
// With no window it stops with the code 1. It writes "tally: ok". Each turn
// draws the window, waits for an event or a call, runs the calls, then the
// keys: Space is one add of 1.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	service, _ := system.service_open(ctx)
	window, ok := display.open(ctx, WIDTH, HEIGHT, "tally")
	if !ok {
		system.stop(1)
	}
	system.log("tally: ok")
	for {
		draw(&window, &service)

		wait: system.Wait
		display.wait_events(&wait, &window)
		system.service_wait(&wait, &service)
		system.wait_end(&wait)
		system.service_run(&service)
		for event in display.next_event(&window) {
			if event.kind == .Key && event.pressed && event.character == ' ' {
				note := "a key of the program"
				add(1, &note, nil)
			}
		}
	}
}
