// A measure of one ring (properties 4 and 6).
//
// One thread writes records in a ring as fast as it can. A second thread
// reads them. No queue operation enters the kernel: a thread enters the
// kernel only to wait, and to wake the other thread. The program counts
// the records of one second, and asks the kernel how many times the
// program entered it.
//
// It measures four rings: two capacities, and two ways to wait. A thread
// that waits at once enters the kernel each time the queue is full or
// empty. A thread that first reads the counters for a short time
// (system.wait_spin) finds most of the time that the other thread
// continued.
package flow

import "support:display"
import "support:graphics"
import "support:interface"
import op "contract:operation"
import "contract:ring"
import "support:system"
import "base:intrinsics"

// The window is built with the interface package (docs/INTERFACE.md).
records_now, records_before: [512]interface.Draw_Record
text_now, text_before: [8192]u8
drawing: interface.Window_Drawing

DURATION :: 1000 // Milliseconds of one measure.
RECORD :: 1
END :: 2

LINE :: 24
BAR_WIDTH :: 220
RATE_X :: 232
ENTRIES_X :: RATE_X + BAR_WIDTH + 110
WIDTH :: ENTRIES_X + BAR_WIDTH + 96
HEIGHT :: 12 + 3 * LINE + len(measures) * LINE + LINE + 12

COLOR_RATE :: 0x58D878
COLOR_ENTRIES :: 0xE0A040

Measure :: struct {
	capacity: u32,
	spin:     bool,
	done:     bool,
	rate:     u64, // Records in one second.
	entries:  u64, // Kernel entries of the program for one million records.
	lost:     u64, // Records that did not arrive in order.
}

measures: [4]Measure

// The ring of the measure that runs, and what its two threads share.
queue: ring.Ring
spin: bool
stop: u32 // 1: the writer writes its last record.
received: u64
lost: u64

machine: system.Handle
slot: u64 // The slot of this program in the kernel.

// wait waits for a queue: for room if this thread writes it, for a record
// if this thread reads it.
wait :: proc "contextless" (side: ^ring.Queue, for_room: bool) {
	list: system.Wait
	if for_room {
		system.wait_room(&list, side)
	} else {
		system.wait_records(&list, side)
	}
	if spin && system.wait_spin(&list) {
		return
	}
	system.wait_end(&list)
}

write_records :: proc "c" (parameter: rawptr) -> ! {
	side := &queue.commands
	sequence: u64
	for intrinsics.volatile_load(&stop) == 0 {
		if system.send(side, ring.Record{kind = RECORD, values = {0 = sequence}}) {
			sequence += 1
		} else {
			wait(side, true)
		}
	}
	for !system.send(side, ring.Record{kind = END}) {
		wait(side, true)
	}
	system.thread_stop()
}

read_records :: proc "c" (parameter: rawptr) -> ! {
	side := &queue.commands
	count, wrong: u64
	for {
		record, ok := system.receive(side)
		if !ok {
			wait(side, false)
			continue
		}
		if record.kind == END {
			break
		}
		if record.values[0] != count {
			wrong += 1
		}
		count += 1
	}
	received, lost = count, wrong
	system.thread_stop()
}

// entries gives the times that this program entered the kernel.
entries :: proc "contextless" () -> u64 {
	report: op.Program_Report
	system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.Program), slot, u64(uintptr(&report)), size_of(report))
	return report.entries
}

run :: proc "contextless" (measure: ^Measure) -> bool {
	memory, mapped, status := system.ring_create(measure.capacity)
	if status != .Ok {
		return false
	}
	defer system.close(memory)
	queue, spin, stop, received, lost = mapped, measure.spin, 0, 0, 0
	defer system.ring_close(&queue)
	before := entries()
	start := system.time()
	reader, reader_status := system.thread_start(read_records, nil)
	writer, writer_status := system.thread_start(write_records, nil)
	if reader_status != .Ok || writer_status != .Ok {
		return false
	}
	end := system.sleep(start + DURATION)
	intrinsics.atomic_store(&stop, 1)
	system.thread_wait(writer)
	system.thread_wait(reader)
	after := entries()
	measure.rate = received * 1000 / max(end - start, 1)
	measure.entries = (after - before) * 1_000_000 / max(received, 1)
	measure.lost = lost
	measure.done = true
	system.log("flow: capacity ", u64(measure.capacity), measure.spin ? ", read the counters then wait: " : ", wait at once: ", measure.rate, " records in one second, ", measure.entries, " kernel entries for one million records, ", lost, " lost")
	return received != 0
}

bar :: proc "contextless" (table: ^interface.Draw_Table, x, y: int, value, most: u64, color: graphics.Color) {
	interface.draw_rectangle(table, x, y + 3, BAR_WIDTH, 10, graphics.COLOR_TRACK)
	interface.draw_rectangle(table, x, y + 3, int(value * BAR_WIDTH / max(most, 1)), 10, color)
	interface.draw_unsigned(table, x + BAR_WIDTH + 8, y, value, graphics.COLOR_TEXT)
}

draw :: proc "contextless" (window: ^display.Window) {
	if drawing.now.records == nil {
		drawing = interface.window_drawing_of(records_now[:], records_before[:], text_now[:], text_before[:])
	}
	frame := interface.window_frame_begin(&drawing, window)
	table := frame.table
	interface.draw_rectangle(table, 0, 0, WIDTH, HEIGHT, graphics.COLOR_BACKGROUND)
	most_rate, most_entries: u64
	for measure in measures {
		most_rate, most_entries = max(most_rate, measure.rate), max(most_entries, measure.entries)
	}
	y := 12
	interface.draw_text(table, 12, y, "one thread writes records in a ring, one thread reads them, for one second.", graphics.COLOR_DIM)
	y += LINE
	interface.draw_text(table, 12, y, "a queue operation does not enter the kernel. a wait does.", graphics.COLOR_DIM)
	y += LINE + LINE / 2
	interface.draw_text(table, 12, y, "capacity  before a wait", graphics.COLOR_DIM)
	interface.draw_text(table, RATE_X, y, "records in one second", graphics.COLOR_DIM)
	interface.draw_text(table, ENTRIES_X, y, "kernel entries, one million records", graphics.COLOR_DIM)
	y += LINE
	for measure, index in measures {
		if index % 2 == 0 {
			interface.draw_rectangle(table, 6, y - 4, WIDTH - 12, LINE, graphics.COLOR_CARD_TOP)
		}
		interface.draw_unsigned(table, 12, y, u64(measure.capacity), graphics.COLOR_TEXT)
		interface.draw_text(table, 92, y, measure.spin ? "read counters" : "nothing", graphics.COLOR_TEXT)
		if measure.done {
			bar(table, RATE_X, y, measure.rate, most_rate, measure.lost == 0 ? COLOR_RATE : graphics.COLOR_FAILED)
			bar(table, ENTRIES_X, y, measure.entries, most_entries, COLOR_ENTRIES)
		} else {
			interface.draw_text(table, RATE_X, y, "...", graphics.COLOR_DIM)
		}
		y += LINE
	}
	interface.window_frame_end(&drawing, &frame, window)
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	window, ok := display.open(ctx, WIDTH, HEIGHT, "flow")
	if !ok {
		system.stop(1)
	}
	machine = ctx.handles[system.GRANT_MACHINE]
	report: op.System_Report
	system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.System), 0, u64(uintptr(&report)), size_of(report))
	for index in 1 ..< report.program_slots {
		program: op.Program_Report
		system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.Program), index, u64(uintptr(&program)), size_of(program))
		if program.state != .None && program.state != .Stopped && system.name_of(program.name[:]) == "flow" {
			slot = index
		}
	}
	measures = {{capacity = 32}, {capacity = 32, spin = true}, {capacity = 1024}, {capacity = 1024, spin = true}}
	draw(&window)
	wrong := slot == 0
	total_lost: u64
	for &measure in measures {
		if !run(&measure) {
			wrong = true
		}
		total_lost += measure.lost
		draw(&window)
	}
	if wrong || total_lost != 0 {
		system.log("flow: wrong: ", total_lost, " records lost")
	} else {
		system.log("flow: ok, ", u64(len(measures)), " measures, 0 records lost")
	}
	for {
		draw(&window)
		display.wait(&window)
		for _ in display.next_event(&window) {
		}
	}
}
