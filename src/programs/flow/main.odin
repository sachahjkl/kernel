// A check and a measure of one ring: the ring is the base interface of the
// kernel and the one way that programs communicate.
//
// One thread writes records in a ring as fast as it can. A second thread
// reads them. No queue operation enters the kernel: a thread enters the
// kernel only to wait, and to wake the other thread. The check sends a
// fixed count of records and counts the records that did not arrive in
// order. In a [measure run](term:measure-run) the threads go on for one
// second, and the program writes the records in one second. In the two
// runs it asks the kernel how many times the program entered it.
//
// It runs four rings: two capacities, and two ways to wait. A thread
// that waits at once enters the kernel each time the queue is full or
// empty. A thread that first reads the counters for a short time
// (system.wait_spin) finds most of the time that the other thread
// continued.
//
// **What it is for.** It shows that a [ring](term:ring) is a
// non-blocking queue in shared memory: the records move with no kernel
// entry, and the count of kernel entries for one million records shows
// how rarely a thread must wait.
//
// **What a reader sees.** Start it from the menu of the programs, or with
// `start("flow")` in the console. The window shows the four rings: the
// records read in order, and the kernel entries for one million records.
// The log gets one line for each ring (`flow: capacity 32, wait at once:
// 200000 records read in order, 0 lost, ...`), then `flow: ok, 4 rings, 0
// records lost`, or `flow: wrong: ...`. In a measure run (`kerneltool
// measure flow`) the window and the lines have the records in one second.
//
// **Its grant**: **Inspect**: the machine handle reads the kernel entries
// of this program, which the measure counts.
//
// **What it does not prove.** The rates are measures of the host of the
// run, printed and never compared to a bound.
package flow

import "modus:support/display"
import "modus:support/graphics"
import "modus:support/interface"
import op "modus:contract/operation"
import "modus:contract/ring"
import "modus:support/system"
import "base:intrinsics"

// The window is built with the interface package (docs/INTERFACE.md).
records_now, records_before: [512]interface.Draw_Record
text_now, text_before: [8192]u8
drawing: interface.Window_Drawing

DURATION :: 1000 // Milliseconds of one measure, in a measure run.
RECORDS_CHECKED :: 200_000 // The records that the writer sends in the check.
RECORD :: 1
END :: 2

LINE :: 24
BAR_WIDTH :: 220
RATE_X :: 232
ENTRIES_X :: RATE_X + BAR_WIDTH + 110
WIDTH :: ENTRIES_X + BAR_WIDTH + 96
HEIGHT :: 12 + 3 * LINE + len(measures) * LINE + 2 * LINE + 12

COLOR_RATE :: 0x58D878
COLOR_ENTRIES :: 0xE0A040

Measure :: struct {
	capacity: u32,
	spin:     bool,
	done:     bool,
	received: u64, // The records that the reader read.
	rate:     u64, // Records in one second: a measure run only.
	entries:  u64, // Kernel entries of the program for one million records.
	lost:     u64, // Records that did not arrive in order.
}

measures: [4]Measure

// The ring of the measure that runs, and what its two threads share.
queue: ring.Ring
spin: bool
stop: u32 // 1: the writer writes its last record.
records_wanted: u64 // The records that the writer sends before its last one; 0: it goes on until stop.
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
	for intrinsics.atomic_load_explicit(&stop, .Relaxed) == 0 && (records_wanted == 0 || sequence < records_wanted) {
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

// run sends records through one ring. The check ends when the writer
// sent RECORDS_CHECKED records and the reader read the last one; a measure
// run stops the writer after DURATION, and has the rate.
run :: proc "contextless" (measure: ^Measure) -> bool {
	measured := system.measure_run()
	memory, mapped, status := system.ring_create(measure.capacity)
	if status != .Ok {
		return false
	}
	defer system.close(memory)
	queue, spin, stop, received, lost = mapped, measure.spin, 0, 0, 0
	records_wanted = measured ? 0 : RECORDS_CHECKED
	defer system.ring_close(&queue)
	before := entries()
	start := system.time()
	reader, reader_status := system.thread_start(read_records, nil)
	writer, writer_status := system.thread_start(write_records, nil)
	if reader_status != .Ok || writer_status != .Ok {
		return false
	}
	end := start
	if measured {
		end = system.sleep(start + DURATION)
		intrinsics.atomic_store(&stop, 1)
	}
	system.thread_wait(writer)
	system.thread_wait(reader)
	after := entries()
	measure.received = received
	measure.entries = (after - before) * 1_000_000 / max(received, 1)
	measure.lost = lost
	measure.done = true
	if measured {
		measure.rate = received * 1000 / max(end - start, 1)
		system.log("flow: capacity ", u64(measure.capacity), measure.spin ? ", read the counters then wait: " : ", wait at once: ", measure.rate, " records in one second, ", measure.entries, " kernel entries for one million records, ", lost, " lost")
		return received != 0
	}
	system.log("flow: capacity ", u64(measure.capacity), measure.spin ? ", read the counters then wait: " : ", wait at once: ", received, " records read in order, ", lost, " lost, ", measure.entries, " kernel entries for one million records")
	return received == RECORDS_CHECKED
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
	measured := system.measure_run()
	most_rate, most_entries: u64
	for measure in measures {
		most_rate, most_entries = max(most_rate, measured ? measure.rate : measure.received), max(most_entries, measure.entries)
	}
	y := 12
	interface.draw_text(table, 12, y, measured ? "one thread writes records in a ring, one thread reads them, for one second." : "one thread writes 200000 records in a ring, one thread reads them.", graphics.COLOR_DIM)
	y += LINE
	interface.draw_text(table, 12, y, "a queue operation does not enter the kernel. a wait does.", graphics.COLOR_DIM)
	y += LINE + LINE / 2
	interface.draw_text(table, 12, y, "capacity  before a wait", graphics.COLOR_DIM)
	interface.draw_text(table, RATE_X, y, measured ? "records in one second" : "records read in order", graphics.COLOR_DIM)
	interface.draw_text(table, ENTRIES_X, y, "kernel entries, one million records", graphics.COLOR_DIM)
	y += LINE
	for measure, index in measures {
		if index % 2 == 0 {
			interface.draw_rectangle(table, 6, y - 4, WIDTH - 12, LINE, graphics.COLOR_CARD_TOP)
		}
		interface.draw_unsigned(table, 12, y, u64(measure.capacity), graphics.COLOR_TEXT)
		interface.draw_text(table, 92, y, measure.spin ? "read counters" : "nothing", graphics.COLOR_TEXT)
		if measure.done {
			bar(table, RATE_X, y, measured ? measure.rate : measure.received - measure.lost, most_rate, measure.lost == 0 ? COLOR_RATE : graphics.COLOR_FAILED)
			bar(table, ENTRIES_X, y, measure.entries, most_entries, COLOR_ENTRIES)
		} else {
			interface.draw_text(table, RATE_X, y, "...", graphics.COLOR_DIM)
		}
		y += LINE
	}
	if !measured {
		interface.draw_text(table, 12, y + LINE / 2, "the records in one second are a measure: run `kerneltool measure flow`.", graphics.COLOR_DIM)
	}
	interface.window_frame_end(&drawing, &frame, window)
}

// entry finds its own slot with the machine handle, runs the four rings
// (`run`), and writes the summary line. A ring is wrong when a record is
// lost, when the check did not read each record, or when the program found
// no slot. The program then keeps its
// window open until it is stopped; with no window, it stops with the code
// 1.
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
		system.log("flow: ok, ", u64(len(measures)), " rings, 0 records lost")
	}
	for {
		draw(&window)
		display.wait(&window)
		for _ in display.next_event(&window) {
		}
	}
}
