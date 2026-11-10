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
package tally

import "../../display"
import "../../graphics"
import "../../system"

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

// add adds an amount to the count, with a note that says why. The result is the new count. The module keeps the last 8 notes.
@(export, link_name = "add")
add :: proc "c" (amount: i64, note: ^string) -> i64 {
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
@(export, link_name = "total")
total :: proc "c" () -> i64 {
	return count
}

// adds gives the number of calls of add after the start, or after the last reset.
@(export, link_name = "adds")
adds :: proc "c" () -> i64 {
	return calls
}

// last gives the note of the last add. The text is empty before the first add.
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
@(export, link_name = "reset")
reset :: proc "c" () -> i64 {
	before := count
	count, calls, notes = 0, 0, {}
	return before
}

COLOR_PAPER :: 0x14181C
COLOR_TEXT :: 0xD8DCE0
COLOR_DIM :: 0x7C848C
COLOR_COUNT :: 0xF0C050
COLOR_PLUS :: 0x58C878
COLOR_MINUS :: 0xE06C60

draw :: proc "contextless" (canvas: graphics.Canvas, service: ^system.Service) {
	graphics.clear(canvas, COLOR_PAPER)
	buffer: [24]u8
	x := graphics.text(canvas, 12, 10, "count ", COLOR_DIM)
	x = graphics.text(canvas, x, 10, system.format(buffer[:], count), COLOR_COUNT)
	x = graphics.text(canvas, x + 24, 10, "adds ", COLOR_DIM)
	graphics.text(canvas, x, 10, system.format(buffer[:], calls), COLOR_TEXT)
	graphics.fill(canvas, 12, 32, WIDTH - 24, 1, 0x30363C)
	// The notes, the last one first.
	for row in 0 ..< min(calls, NOTE_CAPACITY) {
		item := &notes[u64(calls - 1 - row) % NOTE_CAPACITY]
		y := 40 + int(row) * 18
		amount := system.format(buffer[:], item.amount)
		if item.amount >= 0 {
			graphics.text(canvas, 12, y, "+", COLOR_PLUS)
		}
		graphics.text(canvas, item.amount >= 0 ? 20 : 12, y, amount, item.amount >= 0 ? COLOR_PLUS : COLOR_MINUS)
		graphics.text(canvas, 92, y, string(item.text[:item.count]), row == 0 ? COLOR_TEXT : COLOR_DIM)
	}
	graphics.fill(canvas, 12, HEIGHT - 30, WIDTH - 24, 1, 0x30363C)
	x = graphics.text(canvas, 12, HEIGHT - 22, "space: add 1", COLOR_DIM)
	x = graphics.text(canvas, x + 24, HEIGHT - 22, "callers ", COLOR_DIM)
	x = graphics.text(canvas, x, HEIGHT - 22, system.format(buffer[:], u64(service.connected)), COLOR_TEXT)
	x = graphics.text(canvas, x + 16, HEIGHT - 22, "calls ", COLOR_DIM)
	graphics.text(canvas, x, HEIGHT - 22, system.format(buffer[:], service.calls), COLOR_TEXT)
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	service, _ := system.service_open(ctx)
	window, ok := display.open(ctx, WIDTH, HEIGHT, "tally")
	if !ok {
		system.stop(1)
	}
	system.log("tally: ok")
	for {
		draw(window.canvas, &service)
		display.present(&window)

		wait: system.Wait
		display.wait_events(&wait, &window)
		system.service_wait(&wait, &service)
		system.wait_end(&wait)
		system.service_run(&service)
		for event in display.next_event(&window) {
			if event.kind == .Key && event.pressed && event.character == ' ' {
				note := "a key of the program"
				add(1, &note)
			}
		}
	}
}
