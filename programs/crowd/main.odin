// A measure of the shared queue and of the event.
//
// Several threads write records in one queue as fast as they can, and
// several threads read them, for one second. The shared queue has no lock:
// a thread takes its place with one compare-and-exchange. The last measure
// uses a queue with one lock, for comparison.
//
// The threads of each measure wait on one event. The first thread wakes
// the event one time: all of them start together.
//
// Each record has the number of its writer and a count. A reader checks
// that the counts of each writer increase. At the end, the records that
// the readers took are the records that the writers wrote: no record is
// lost, and no record arrives two times.
package crowd

import "support:display"
import "support:graphics"
import op "contract:operation"
import "contract:ring"
import "support:system"
import "base:intrinsics"

DURATION :: 1000 // Milliseconds of one measure.
CAPACITY :: 1024
THREAD_LIMIT :: 4 // The writers and the readers of one measure.
RECORD :: 1
END :: 2

LINE :: 24
BAR_WIDTH :: 200
RATE_X :: 284
ENTRIES_X :: RATE_X + BAR_WIDTH + 110
WIDTH :: ENTRIES_X + BAR_WIDTH + 96
HEIGHT :: 12 + 3 * LINE + len(measures) * LINE + LINE + 12

COLOR_RATE :: 0x58D878
COLOR_LOCK :: 0x5890E0
COLOR_ENTRIES :: 0xE0A040

Measure :: struct {
	writers:   int,
	readers:   int,
	with_lock: bool,
	done:      bool,
	rate:      u64, // Records in one second.
	entries:   u64, // Kernel entries of the program for one million records.
	wrong:     u64, // Records that are lost, that arrived two times, or that arrived before an older record of the same writer.
	together:  u64, // The threads that the event started.
}

measures: [5]Measure

// What one thread of a measure counts. Each thread has its own line of
// the cache.
Member :: struct #align (64) {
	number:   int,
	count:    u64, // The records that it wrote or read.
	disorder: u64,
	from:     [THREAD_LIMIT]u64, // A reader: the records of each writer.
}

// The queue of the measure that runs.
shared: ring.Shared // Several writers, several readers, no lock.
locked: ring.Ring // The same work with one lock: only the queue of commands.
queue_lock: system.Lock
records_event: system.Event // The queue with a lock: a record arrived.
room_event: system.Event // The queue with a lock: a record left.
with_lock: bool

start: system.Event // All the threads of a measure wait on it.
running: u32
started: u32
stop: u32 // 1: the writers end.
members: [THREAD_LIMIT]Member

machine: system.Handle
slot: u64 // The slot of this program in the kernel.

// put writes a record. If the queue is full, the thread waits.
put :: proc "contextless" (record: ring.Record) {
	if with_lock {
		for {
			seen := system.event_count(&room_event)
			system.lock(&queue_lock)
			ok := ring.push(&locked.commands, record)
			system.unlock(&queue_lock)
			if ok {
				system.event_wake(&records_event)
				return
			}
			list: system.Wait
			system.wait_event(&list, &room_event, seen)
			if !system.wait_spin(&list) {
				system.wait_end(&list)
			}
		}
	}
	for !system.shared_send(&shared, record) {
		list: system.Wait
		system.wait_shared_room(&list, &shared)
		if !system.wait_spin(&list) {
			system.wait_end(&list)
		}
	}
}

// take reads a record. If the queue is empty, the thread waits.
take :: proc "contextless" () -> ring.Record {
	if with_lock {
		for {
			seen := system.event_count(&records_event)
			system.lock(&queue_lock)
			record, ok := ring.pop(&locked.commands)
			system.unlock(&queue_lock)
			if ok {
				system.event_wake(&room_event)
				return record
			}
			list: system.Wait
			system.wait_event(&list, &records_event, seen)
			if !system.wait_spin(&list) {
				system.wait_end(&list)
			}
		}
	}
	for {
		if record, ok := system.shared_receive(&shared); ok {
			return record
		}
		list: system.Wait
		system.wait_shared_records(&list, &shared)
		if !system.wait_spin(&list) {
			system.wait_end(&list)
		}
	}
}

// wait_start stops the thread until the first thread wakes the event.
wait_start :: proc "contextless" () {
	for {
		seen := system.event_count(&start)
		if intrinsics.atomic_load(&running) != 0 {
			break
		}
		system.event_wait(&start, seen)
	}
	intrinsics.atomic_add(&started, 1)
}

write_records :: proc "c" (parameter: rawptr) -> ! {
	member := (^Member)(parameter)
	wait_start()
	for intrinsics.volatile_load(&stop) == 0 {
		put({kind = RECORD, values = {0 = u64(member.number), 1 = member.count}})
		member.count += 1
	}
	system.thread_stop()
}

read_records :: proc "c" (parameter: rawptr) -> ! {
	member := (^Member)(parameter)
	next: [THREAD_LIMIT]u64 // The least count that each writer can give now.
	wait_start()
	for {
		record := take()
		if record.kind == END {
			break
		}
		writer := record.values[0] % THREAD_LIMIT
		if record.values[1] < next[writer] {
			member.disorder += 1
		}
		next[writer] = record.values[1] + 1
		member.from[writer] += 1
		member.count += 1
	}
	system.thread_stop()
}

// entries gives the times that this program entered the kernel.
entries :: proc "contextless" () -> u64 {
	report: op.Program_Report
	system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.Program), slot, u64(uintptr(&report)), size_of(report))
	return report.entries
}

run :: proc "contextless" (measure: ^Measure) -> bool {
	memory: system.Handle
	status: system.Status
	if measure.with_lock {
		memory, locked, status = system.ring_create(CAPACITY)
	} else {
		memory, shared, status = system.shared_create(CAPACITY)
	}
	if status != .Ok {
		return false
	}
	defer {
		system.close(memory)
		system.ring_close(&locked)
		system.shared_close(&shared)
	}
	with_lock, stop, running, started = measure.with_lock, 0, 0, 0
	members = {}
	threads: [THREAD_LIMIT]system.Thread
	count := measure.writers + measure.readers
	for index in 0 ..< count {
		is_writer := index < measure.writers
		members[index].number = is_writer ? index : index - measure.writers
		threads[index], status = system.thread_start(is_writer ? write_records : read_records, &members[index])
		if status != .Ok {
			return false
		}
	}
	// One wake of the event starts all the threads.
	before := entries()
	begin := system.time()
	intrinsics.atomic_store(&running, 1)
	system.event_wake(&start)
	end := system.sleep(begin + DURATION)
	intrinsics.atomic_store(&stop, 1)
	for thread in threads[:measure.writers] {
		system.thread_wait(thread)
	}
	// The records of the writers are all in the queue: one last record for
	// each reader.
	for _ in 0 ..< measure.readers {
		put({kind = END})
	}
	for thread in threads[measure.writers:count] {
		system.thread_wait(thread)
	}
	after := entries()

	written, read: u64
	measure.wrong = 0
	for writer in 0 ..< measure.writers {
		written += members[writer].count
		taken: u64
		for reader in members[measure.writers:count] {
			taken += reader.from[writer]
		}
		// More: a record arrived two times. Fewer: a record is lost.
		measure.wrong += max(taken, members[writer].count) - min(taken, members[writer].count)
	}
	for reader in members[measure.writers:count] {
		read += reader.count
		measure.wrong += reader.disorder
	}
	measure.rate = read * 1000 / max(end - begin, 1)
	measure.entries = (after - before) * 1_000_000 / max(read, 1)
	measure.together = u64(started)
	measure.done = true
	system.log("crowd: ", measure.with_lock ? "queue with a lock, " : "shared queue, ", u64(measure.writers), " writers, ", u64(measure.readers), " readers: ", measure.rate, " records in one second, ", measure.entries, " kernel entries for one million records, ", written, " written, ", read, " read, ", measure.wrong, " wrong")
	return read != 0 && written == read && measure.together == u64(count)
}

bar :: proc "contextless" (canvas: graphics.Canvas, x, y: int, value, most: u64, color: graphics.Color) {
	graphics.fill(canvas, x, y + 3, BAR_WIDTH, 10, graphics.COLOR_TRACK)
	graphics.fill(canvas, x, y + 3, int(value * BAR_WIDTH / max(most, 1)), 10, color)
	graphics.unsigned(canvas, x + BAR_WIDTH + 8, y, value, graphics.COLOR_TEXT)
}

draw :: proc "contextless" (window: ^display.Window) {
	canvas := window.canvas
	display.picture_begin(window) // The measure of a picture (display.present).
	graphics.clear(canvas, graphics.COLOR_BACKGROUND)
	most_rate, most_entries: u64
	for measure in measures {
		most_rate, most_entries = max(most_rate, measure.rate), max(most_entries, measure.entries)
	}
	y := 12
	graphics.text(canvas, 12, y, "several threads write records in one queue, several threads read them, for one second.", graphics.COLOR_DIM)
	y += LINE
	graphics.text(canvas, 12, y, "one event starts the threads of a measure. no record is lost, none arrives two times.", graphics.COLOR_DIM)
	y += LINE + LINE / 2
	graphics.text(canvas, 12, y, "queue    writers  readers  wrong", graphics.COLOR_DIM)
	graphics.text(canvas, RATE_X, y, "records in one second", graphics.COLOR_DIM)
	graphics.text(canvas, ENTRIES_X, y, "kernel entries, one million records", graphics.COLOR_DIM)
	y += LINE
	for measure, index in measures {
		if index % 2 == 0 {
			graphics.fill(canvas, 6, y - 4, WIDTH - 12, LINE, graphics.COLOR_CARD_TOP)
		}
		graphics.text(canvas, 12, y, measure.with_lock ? "lock" : "shared", measure.with_lock ? COLOR_LOCK : graphics.COLOR_TEXT)
		graphics.unsigned(canvas, 84, y, u64(measure.writers), graphics.COLOR_TEXT)
		graphics.unsigned(canvas, 156, y, u64(measure.readers), graphics.COLOR_TEXT)
		if measure.done {
			graphics.unsigned(canvas, 228, y, measure.wrong, measure.wrong == 0 ? graphics.COLOR_DIM : graphics.COLOR_FAILED)
			bar(canvas, RATE_X, y, measure.rate, most_rate, measure.wrong != 0 ? graphics.COLOR_FAILED : measure.with_lock ? COLOR_LOCK : COLOR_RATE)
			bar(canvas, ENTRIES_X, y, measure.entries, most_entries, COLOR_ENTRIES)
		} else {
			graphics.text(canvas, RATE_X, y, "...", graphics.COLOR_DIM)
		}
		y += LINE
	}
	display.present(window)
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	window, ok := display.open(ctx, WIDTH, HEIGHT, "crowd")
	if !ok {
		system.stop(1)
	}
	machine = ctx.handles[system.GRANT_MACHINE]
	report: op.System_Report
	system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.System), 0, u64(uintptr(&report)), size_of(report))
	for index in 1 ..< report.program_slots {
		program: op.Program_Report
		system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.Program), index, u64(uintptr(&program)), size_of(program))
		if program.state != .None && program.state != .Stopped && system.name_of(program.name[:]) == "crowd" {
			slot = index
		}
	}
	measures = {{writers = 1, readers = 1}, {writers = 2, readers = 2}, {writers = 3, readers = 1}, {writers = 1, readers = 3}, {writers = 2, readers = 2, with_lock = true}}
	draw(&window)
	wrong := slot == 0
	total_wrong: u64
	for &measure in measures {
		if !run(&measure) {
			wrong = true
		}
		total_wrong += measure.wrong
		draw(&window)
	}
	if wrong || total_wrong != 0 {
		system.log("crowd: wrong: ", total_wrong, " records lost, in disorder or read two times")
	} else {
		system.log("crowd: ok, ", u64(len(measures)), " measures, each record written is read one time, each event started all the threads")
	}
	for {
		draw(&window)
		display.wait(&window)
		for _ in display.next_event(&window) {
		}
	}
}
