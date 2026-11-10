// A measure of the time page.
//
// The kernel writes the time in one page. Each program has this page and
// can only read it: a program reads the time with one load from memory.
// This program reads the time as often as it can for one second, in the
// two ways: from the time page, and with a kernel entry. It counts the
// kernel entries of each way.
//
// It checks that the time never goes back, that the two ways give the same
// time, and that the kernel refuses to remove the time page.
package clock

import "support:display"
import "support:graphics"
import op "contract:operation"
import "support:system"

DURATION :: 1000 // Milliseconds of one measure.

LINE :: 24
BAR_WIDTH :: 240
RATE_X :: 132
ENTRIES_X :: RATE_X + BAR_WIDTH + 120
WIDTH :: ENTRIES_X + 320
HEIGHT :: 12 + 8 * LINE + 12

COLOR_BACKGROUND :: 0x10151C
COLOR_PANEL :: 0x18202A
COLOR_TEXT :: 0xD8E0E8
COLOR_DIM :: 0x7A8794
COLOR_PAGE :: 0x58D878
COLOR_ENTRY :: 0x5890E0
COLOR_BAR_BACK :: 0x232C38
COLOR_WRONG :: 0xF06060

Measure :: struct {
	name:    string,
	done:    bool,
	rate:    u64, // Reads in one second.
	entries: u64, // Kernel entries for one million reads.
}

measures := [2]Measure{{name = "time page"}, {name = "kernel entry"}}
went_back: u64 // The reads that gave a time before the time of the last read.
apart: u64 // The most milliseconds between the two ways.
refused: bool // The kernel refused to remove the time page.
checked: bool

machine: system.Handle
slot: u64 // The slot of this program in the kernel.

// entries gives the times that this program entered the kernel.
entries :: proc "contextless" () -> u64 {
	report: op.Program_Report
	system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.Program), slot, u64(uintptr(&report)), size_of(report))
	return report.entries
}

run :: proc "contextless" (measure: ^Measure, entered: bool) {
	before := entries()
	begin := system.time()
	last := begin
	reads: u64
	for last < begin + DURATION {
		now := entered ? system.time_entered() : system.time()
		if now < last {
			went_back += 1
		}
		last = now
		reads += 1
	}
	// The count of one Inspect call is in the difference: the call of
	// `before` ends before the kernel counts it.
	after := entries() - 1
	measure.rate = reads * 1000 / max(last - begin, 1)
	measure.entries = (after - before) * 1_000_000 / reads
	measure.done = true
}

clock_text :: proc "contextless" (canvas: graphics.Canvas, x, y: int, milliseconds: u64, color: graphics.Color) {
	x := x
	seconds := milliseconds / 1000
	x = graphics.unsigned(canvas, x, y, seconds / 3600, color, 2)
	x = graphics.text(canvas, x, y, ":", color)
	x = graphics.unsigned(canvas, x, y, seconds / 60 % 60, color, 2)
	x = graphics.text(canvas, x, y, ":", color)
	x = graphics.unsigned(canvas, x, y, seconds % 60, color, 2)
	x = graphics.text(canvas, x, y, ".", color)
	graphics.unsigned(canvas, x, y, milliseconds % 1000, color, 3)
}

bar :: proc "contextless" (canvas: graphics.Canvas, x, y: int, value, most: u64, color: graphics.Color) {
	graphics.fill(canvas, x, y + 3, BAR_WIDTH, 10, COLOR_BAR_BACK)
	graphics.fill(canvas, x, y + 3, int(value * BAR_WIDTH / max(most, 1)), 10, color)
	graphics.unsigned(canvas, x + BAR_WIDTH + 8, y, value, COLOR_TEXT)
}

draw :: proc "contextless" (window: ^display.Window) {
	canvas := window.canvas
	graphics.clear(canvas, COLOR_BACKGROUND)
	y := 12
	graphics.text(canvas, 12, y, "the kernel writes the time in one page. each program reads it: no kernel entry.", COLOR_DIM)
	y += LINE + LINE / 2
	graphics.text(canvas, 12, y, "since boot", COLOR_DIM)
	clock_text(canvas, RATE_X, y, system.time(), COLOR_TEXT)
	y += LINE + LINE / 2
	graphics.text(canvas, 12, y, "way", COLOR_DIM)
	graphics.text(canvas, RATE_X, y, "reads of the time in one second", COLOR_DIM)
	graphics.text(canvas, ENTRIES_X, y, "kernel entries, one million reads", COLOR_DIM)
	y += LINE
	most: u64
	for measure in measures {
		most = max(most, measure.rate)
	}
	for measure, index in measures {
		if index % 2 == 0 {
			graphics.fill(canvas, 6, y - 4, WIDTH - 12, LINE, COLOR_PANEL)
		}
		graphics.text(canvas, 12, y, measure.name, index == 0 ? COLOR_PAGE : COLOR_ENTRY)
		if measure.done {
			bar(canvas, RATE_X, y, measure.rate, most, index == 0 ? COLOR_PAGE : COLOR_ENTRY)
			graphics.unsigned(canvas, ENTRIES_X, y, measure.entries, COLOR_TEXT)
		} else {
			graphics.text(canvas, RATE_X, y, "...", COLOR_DIM)
		}
		y += LINE
	}
	y += LINE / 2
	if checked {
		x := graphics.text(canvas, 12, y, "the time went back ", COLOR_DIM)
		x = graphics.unsigned(canvas, x, y, went_back, went_back == 0 ? COLOR_TEXT : COLOR_WRONG)
		x = graphics.text(canvas, x, y, " times. the two ways are ", COLOR_DIM)
		x = graphics.unsigned(canvas, x, y, apart, apart <= 1 ? COLOR_TEXT : COLOR_WRONG)
		graphics.text(canvas, x, y, " ms apart at most.", COLOR_DIM)
		y += LINE
		graphics.text(canvas, 12, y, refused ? "the kernel refuses to remove the time page of this program." : "the kernel removed the time page.", refused ? COLOR_DIM : COLOR_WRONG)
	}
	display.present(window)
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	window, ok := display.open(ctx, WIDTH, HEIGHT, "clock")
	if !ok {
		system.stop(1)
	}
	machine = ctx.handles[system.GRANT_MACHINE]
	report: op.System_Report
	system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.System), 0, u64(uintptr(&report)), size_of(report))
	for index in 1 ..< report.program_slots {
		program: op.Program_Report
		system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.Program), index, u64(uintptr(&program)), size_of(program))
		if program.state != .None && program.state != .Stopped && system.name_of(program.name[:]) == "clock" {
			slot = index
		}
	}
	draw(&window)
	run(&measures[0], false)
	system.log("clock: the time page: ", measures[0].rate, " reads in one second, ", measures[0].entries, " kernel entries for one million reads")
	draw(&window)
	run(&measures[1], true)
	system.log("clock: a kernel entry: ", measures[1].rate, " reads in one second, ", measures[1].entries, " kernel entries for one million reads")

	// The two ways give the same time. The kernel can count one
	// millisecond between the two reads.
	for _ in 0 ..< 1000 {
		entered := system.time_entered()
		page := system.time()
		apart = max(apart, max(entered, page) - min(entered, page))
	}
	refused = system.memory_unmap(rawptr(uintptr(op.TIME_ADDRESS))) != .Ok && system.time() != 0
	checked = true
	if slot != 0 && went_back == 0 && apart <= 1 && refused && measures[0].entries == 0 {
		system.log("clock: ok, the time never went back, the page and the kernel give the same time, the kernel refuses to remove the time page")
	} else {
		system.log("clock: wrong: the time went back ", went_back, " times, the two ways are ", apart, " ms apart, the kernel ", refused ? "refuses" : "does not refuse", " to remove the time page")
	}
	deadline := system.time()
	for {
		draw(&window)
		deadline += 100
		display.wait(&window, deadline)
		for _ in display.next_event(&window) {
		}
	}
}
