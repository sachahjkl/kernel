// A measure of the time page.
//
// The kernel writes the time in one page. Each program has this page and
// can only read it: a program reads the time with one load from memory.
// This program reads the time as often as it can for one second, in the
// two ways: from the time page, and with a kernel entry. It counts the
// kernel entries of each way.
//
// It checks that the time never goes back, that the two ways give the same
// time, that the milliseconds of the page follow the cycle counter (the
// kernel writes them from it at each tick: a late tick loses no time), and
// that the kernel refuses to remove the time page.
//
// **What it is for.** It shows that the kernel is off the path of a read
// of the time: the [time page](term:time-page) gives the time with one
// load from memory, and one million reads make 0 kernel entries. The read
// with a kernel entry is measured too, for comparison.
//
// **What a reader sees.** Start it from the menu of the programs, or with
// `start("clock")` in the console. The window shows the two measures: the
// reads in one second and the kernel entries for one million reads. The
// log gets one line for each way (`clock: the time page: <rate> reads in
// one second, 0 kernel entries for one million reads`), the comparison with
// the cycle counter, then `clock: ok, the time never went back, ...`, or
// `clock: wrong: ...`.
//
// **Its grant**: **Inspect**: the machine handle reads the kernel entries
// of this program (its program report), which the measure counts.
//
// **What it does not prove.** The rates are measures of the host of the
// run: no test compares them to a bound.
package clock

import "support:display"
import "support:graphics"
import "support:interface"
import op "contract:operation"
import "support:system"

DURATION :: 1000 // Milliseconds of one measure.

LINE :: interface.TABLE_LINE
WIDTH :: 816
HEIGHT :: 312

COLOR_PAGE :: 0x58D878
COLOR_ENTRY :: 0x5890E0

Measure :: struct {
	name:    string,
	done:    bool,
	rate:    u64, // Reads in one second.
	entries: u64, // Kernel entries for one million reads.
}

measures := [2]Measure{{name = "time page"}, {name = "kernel entry"}}
went_back: u64 // The reads that gave a time before the time of the last read.
apart: u64 // The most milliseconds between the two ways.
// The milliseconds of the page against system.nanoseconds(), which reads
// the cycle counter: the most that the page was behind, and ahead.
behind, ahead, compared: u64
// The least that the page was behind: just after a tick it is behind by
// less than one tick, however late the ticks come. More is time that the
// page lost. The most that it was behind is only how late a tick came: on
// a machine under another system that is the load of that system.
least: u64 = max(u64)
LEAST_LIMIT :: 1
AHEAD_LIMIT :: 1 // The cycle counters of two processors can differ a little.
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

// The memory of the interface package for the window (docs/INTERFACE.md).
records_now, records_before: [256]interface.Draw_Record
text_now, text_before: [4096]u8
drawing: interface.Window_Drawing

// clock_text writes a time since boot as hours:minutes:seconds.milliseconds.
clock_text :: proc "contextless" (builder: ^interface.Text_Builder, milliseconds: u64) -> string {
	builder.count = 0
	seconds := milliseconds / 1000
	interface.text_put_number(builder, seconds / 3600, 2)
	interface.text_put(builder, ":")
	interface.text_put_number(builder, seconds / 60 % 60, 2)
	interface.text_put(builder, ":")
	interface.text_put_number(builder, seconds % 60, 2)
	interface.text_put(builder, ".")
	interface.text_put_number(builder, milliseconds % 1000, 3)
	return interface.text_of(builder)
}

// Part: one part of a sentence, with its color.
Part :: struct {
	text:  string,
	color: graphics.Color,
}

// sentence draws the parts of a sentence one after the other.
sentence :: proc "contextless" (frame: ^interface.Frame, area: interface.Area, parts: ..Part) {
	x := area.x
	for part in parts {
		x = interface.draw_text(frame.table, x, area.y + (area.height - interface.LINE) / 2, part.text, part.color)
	}
}

// draw builds the window with the interface package: a card, the time since
// boot, a table of the two ways with their bars, the checks.
draw :: proc "contextless" (window: ^display.Window) {
	frame := interface.window_frame_begin(&drawing, window)
	interface.background(&frame, {0, 0, WIDTH, HEIGHT})
	content := interface.card(&frame, {8, 8, WIDTH - 16, HEIGHT - 16}, "THE TIME PAGE", "Time_Record: one page that each program reads", graphics.COLOR_KERNEL)
	column := interface.column_of(content)
	interface.cell_text(&frame, interface.column_take(&column, LINE), "the kernel writes the time in one page. each program reads it: no kernel entry.", graphics.COLOR_DIM)
	builder: interface.Text_Builder
	interface.label_value_line(&frame, interface.column_take(&column, LINE), "since boot", clock_text(&builder, system.time()), graphics.COLOR_TEXT, 120)
	interface.column_take(&column, 8)

	// The table: the way, its reads in one second as a bar and a number, its kernel entries.
	cells: [4]interface.Area
	sizes := [4]interface.Size{interface.pixels(120), interface.share(), interface.characters(12), interface.characters(20)}
	interface.row_split(interface.column_take(&column, LINE), sizes[:], cells[:], 16)
	interface.table_header(&frame, cells[:], {"way", "reads of the time in one second", "", "kernel entries"}, {.Left, .Left, .Right, .Right})
	most: u64
	for measure in measures {
		most = max(most, measure.rate)
	}
	for measure, index in measures {
		line := interface.column_take(&column, LINE)
		interface.table_band(&frame, {line.x - 8, line.y, line.width + 16, line.height}, index)
		interface.row_split(line, sizes[:], cells[:], 16)
		color := graphics.Color(index == 0 ? COLOR_PAGE : COLOR_ENTRY)
		interface.cell_text(&frame, cells[0], measure.name, color)
		if !measure.done {
			interface.cell_text(&frame, cells[1], "...", graphics.COLOR_DIM)
			continue
		}
		interface.bar(&frame, {cells[1].x, cells[1].y + 8, cells[1].width, 8}, measure.rate, most, color)
		interface.cell_text(&frame, cells[2], interface.number_text(&builder, measure.rate), graphics.COLOR_TEXT, .Right)
		interface.cell_text(&frame, cells[3], interface.number_text(&builder, measure.entries), graphics.COLOR_TEXT, .Right)
	}
	interface.column_take(&column, 8)
	if checked {
		numbers: [5]interface.Text_Builder
		sentence(&frame, interface.column_take(&column, LINE),
			{"the time went back ", graphics.COLOR_DIM},
			{interface.number_text(&numbers[0], went_back), went_back == 0 ? graphics.COLOR_TEXT : graphics.COLOR_FAILED},
			{" times. the two ways are ", graphics.COLOR_DIM},
			{interface.number_text(&numbers[1], apart), apart <= 1 ? graphics.COLOR_TEXT : graphics.COLOR_FAILED},
			{" ms apart at most.", graphics.COLOR_DIM})
		sentence(&frame, interface.column_take(&column, LINE),
			{"against the cycle counter, the page was ", graphics.COLOR_DIM},
			{interface.number_text(&numbers[2], least), least <= LEAST_LIMIT ? graphics.COLOR_TEXT : graphics.COLOR_FAILED},
			{" to ", graphics.COLOR_DIM},
			{interface.number_text(&numbers[3], behind), graphics.COLOR_TEXT},
			{" ms behind and ", graphics.COLOR_DIM},
			{interface.number_text(&numbers[4], ahead), ahead <= AHEAD_LIMIT ? graphics.COLOR_TEXT : graphics.COLOR_FAILED},
			{" ms ahead.", graphics.COLOR_DIM})
		sentence(&frame, interface.column_take(&column, LINE), {refused ? "the kernel refuses to remove the time page of this program." : "the kernel removed the time page.", refused ? graphics.COLOR_DIM : graphics.COLOR_FAILED})
	}
	interface.window_frame_end(&drawing, &frame, window)
}

// entry finds its own slot with the machine handle, runs the two measures
// of one second each (`run`), compares the two ways and the cycle counter,
// tries to remove the time page, and writes the summary line. It then
// draws the window at each event, and measures the time of a draw. It
// never returns; with no window, it stops with the code 1.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	window, ok := display.open(ctx, WIDTH, HEIGHT, "clock")
	if !ok {
		system.stop(1)
	}
	drawing = interface.window_drawing_of(records_now[:], records_before[:], text_now[:], text_before[:])
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
	// The page follows the cycle counter: for half a second, each read of
	// the page is compared with the time that the cycle counter gives now.
	for begin := system.time(); system.time() < begin + DURATION / 2; {
		page := system.time()
		fine := system.nanoseconds() / 1_000_000
		behind = max(behind, fine > page ? fine - page : 0)
		least = min(least, fine > page ? fine - page : 0)
		ahead = max(ahead, page > fine ? page - fine : 0)
		compared += 1
	}
	system.log("clock: the time page and the cycle counter: in ", compared, " reads the page was ", least, " to ", behind, " ms behind and at most ", ahead, " ms ahead")
	refused = system.memory_unmap(rawptr(uintptr(op.TIME_ADDRESS))) != .Ok && system.time() != 0
	checked = true
	if slot != 0 && went_back == 0 && apart <= 1 && least <= LEAST_LIMIT && ahead <= AHEAD_LIMIT && refused && measures[0].entries == 0 {
		system.log("clock: ok, the time never went back, the page and the kernel give the same time, the kernel refuses to remove the time page")
	} else {
		system.log("clock: wrong: the time went back ", went_back, " times, the two ways are ", apart, " ms apart, the page is at least ", least, " ms behind and ", ahead, " ms ahead of the cycle counter, the kernel ", refused ? "refuses" : "does not refuse", " to remove the time page")
	}
	deadline := system.time()
	// The time of one picture: the mean of ten pictures after the checks
	// (docs/DESIGN.md, section 7).
	drawn, drawn_time: u64
	for {
		start := system.nanoseconds()
		draw(&window)
		if drawn < 10 {
			drawn_time += system.nanoseconds() - start
			drawn += 1
			if drawn == 10 {
				system.log("clock: the window drew one picture in ", drawn_time / 10 / 1000, ".", drawn_time / 10 / 100 % 10, " us, the mean of 10")
				// One frame where one number changed: the time since boot.
				system.log("clock: the interface: ", u64(drawing.now.record_count), " records, ", u64(drawing.damage.count), " damage rectangles; build ", drawing.build_time / 1000, ".", drawing.build_time / 100 % 10, " us, difference ", drawing.difference_time / 1000, ".", drawing.difference_time / 100 % 10, " us, draw ", drawing.draw_time / 1000, ".", drawing.draw_time / 100 % 10, " us")
			}
		}
		deadline += 100
		display.wait(&window, deadline)
		interface.window_events(&drawing, &window)
	}
}
