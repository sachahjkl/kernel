// The measures of the locks of the kernel.
//
// The program starts four programs `locker`. Each one works on its own
// objects only: a kernel entry of one locker touches no object of another
// locker. So a locker waits for another one only when the kernel makes it
// wait. With 1, 2 and 4 lockers at one time, the program measures the
// kernel entries in one second and the page faults on first use in one
// second. Then two threads of this program wake each other with the word
// wait, alone, then while two lockers enter the kernel. The window shows
// the numbers, and the waits of each lock of the kernel in each measure.
//
// The program checks the counts: the kernel counted each entry of a
// locker, each page returned to its budget, each free page is in a budget
// or reserved, and no wake was lost. It does not check a speed.
//
// The program needs the grant to inspect the machine, and the boot image
// (it starts the lockers).
package locks

import "base:intrinsics"
import "support:display"
import "support:graphics"
import "support:lockers"
import op "contract:operation"
import "contract:ring"
import "support:system"

MEASURE_TIME :: 300 // Milliseconds of one measure.
PAIR_TIME :: 500 // Milliseconds of one measure of the word wait.
LOST_WAIT :: 1000 // Milliseconds: a wait that ends at its deadline after the word changed lost its wake.
LOCKER_AMOUNTS :: system.Budget_Amounts{pages = 1024, programs = 1, threads = 1, processor = 1_000_000, log_records = 10}

WIDTH :: 760
LINE :: 22
HEIGHT :: 12 + 3 * LINE + 3 * LINE + LINE / 2 + 2 * LINE + LINE / 2 + (int(op.LOCK_KIND_CAPACITY) + 1) * LINE + 2 * LINE + 12
COLUMN_X :: 300
COLUMN_WIDTH :: 120

COLOR_BACKGROUND :: 0x10151C
COLOR_PANEL :: 0x18202A
COLOR_TEXT :: 0xD8E0E8
COLOR_DIM :: 0x7A8794
COLOR_RIGHT :: 0x58D878
COLOR_WRONG :: 0xE0B040

@(rodata)
counts := [3]int{1, 2, 4}

machine: system.Handle
board: ^lockers.Board
programs: [lockers.LOCKER_CAPACITY]system.Handle

entry_rates: [len(counts)]u64 // Kernel entries in one second, all the lockers together.
fault_rates: [len(counts)]u64 // Pages on first use in one second, all the lockers together.
pairs_alone, pairs_loaded: u64 // Wakes between the two threads in one second.
lost_wakes: u64
entry_locks, fault_locks, pair_locks: [op.LOCK_KIND_CAPACITY]op.Lock_Count // The locks during the measures with 4 lockers, and with the word wait.
entries_right, faults_right, pages_right, pairs_right := true, true, true, true
done: bool

report :: proc "contextless" () -> (report: op.System_Report) {
	system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.System), 0, u64(uintptr(&report)), size_of(report))
	return report
}

locks_between :: proc "contextless" (before, after: op.System_Report) -> (delta: [op.LOCK_KIND_CAPACITY]op.Lock_Count) {
	for &count, index in delta {
		count = {takes = after.locks[index].takes - before.locks[index].takes, waits = after.locks[index].waits - before.locks[index].waits}
	}
	return delta
}

// command gives one command to the first `active` lockers, and waits for
// their results.
command :: proc "contextless" (active: int, mode: lockers.Mode, start, end: u64) -> bool {
	seen: [lockers.LOCKER_CAPACITY]u32
	for index in 0 ..< active {
		slot := &board.slots[index]
		seen[index] = intrinsics.atomic_load(&slot.done)
		slot.mode = mode
		slot.start = start
		slot.end = end
		intrinsics.atomic_add(&slot.command, 1)
		system.word_wake(&slot.command, system.WAKE_ALL)
	}
	deadline := end + 5000
	for index in 0 ..< active {
		slot := &board.slots[index]
		for intrinsics.atomic_load(&slot.done) == seen[index] {
			if system.time() >= deadline {
				return false
			}
			system.word_wait(&slot.done, seen[index], deadline)
		}
	}
	return true
}

// measure runs one mode on 1, 2 and 4 lockers, and checks the counts.
measure :: proc "contextless" (mode: lockers.Mode, rates: ^[len(counts)]u64, locks: ^[op.LOCK_KIND_CAPACITY]op.Lock_Count) {
	for active, row in counts {
		entries_before: [lockers.LOCKER_CAPACITY]u64
		for index in 0 ..< active {
			entries_before[index] = system.program_entries(programs[index])
		}
		before := report()
		start := system.time() + 20
		end := start + MEASURE_TIME
		answered := command(active, mode, start, end)
		after := report()
		total: u64
		kernel_total: u64
		for index in 0 ..< active {
			slot := &board.slots[index]
			total += slot.count
			kernel := system.program_entries(programs[index]) - entries_before[index]
			kernel_total += kernel
			// The kernel counted each entry that the library of the locker
			// counted: the loop, two budget reads, the wake of this program,
			// and the wait that follows (it can be in the count or not yet).
			if mode == .Entries && (slot.entries != slot.count + 1 || kernel < slot.count + 3 || kernel > slot.count + 8) {
				if entries_right {
					system.log("locks: locker ", u64(index + 1), " counted ", slot.count, " operations and ", slot.entries, " entries, the kernel ", kernel)
				}
				entries_right = false
			}
			if slot.budget_before != slot.budget_after {
				pages_right = false
			}
		}
		// The entries of the lockers are a part of the entries of the machine.
		if !answered || kernel_total > after.entries - before.entries {
			entries_right = false
		}
		if mode == .Faults && after.first_use_faults - before.first_use_faults < total {
			faults_right = false
		}
		if after.budget_pages + after.reserved_pages != after.free_pages {
			pages_right = false
		}
		rates[row] = total * 1000 / MEASURE_TIME
		if active == lockers.LOCKER_CAPACITY {
			locks^ = locks_between(before, after)
		}
	}
}

// The word wait between two threads: each one changes the word, wakes the
// other one, and waits while the word holds its own value, in one kernel entry.
Pair :: struct {
	turn:   u32, // Even: the first thread runs. Odd: the second one.
	stop:   u32,
	rounds: [2]u64,
	lost:   [2]u64,
}

pair: Pair

// pair_round is one turn of one side: the side writes turn + 1, wakes the
// other side and waits while the word holds turn + 1.
pair_round :: proc "contextless" (side: int, turn: u32) {
	next := turn + 1
	intrinsics.atomic_store(&pair.turn, next)
	kernel := system.kernel_ring()
	word := op.Word{address = u64(uintptr(&pair.turn)), value = u64(next)}
	ring.push(&kernel.commands, ring.Record{kind = u32(op.Operation.Word_Wake), values = {0 = u64(uintptr(&pair.turn)), 1 = 1}})
	ring.push(&kernel.commands, ring.Record{kind = u32(op.Operation.Word_Wait), values = {0 = u64(uintptr(&word)), 1 = 1}})
	deadline := system.time() + LOST_WAIT
	now := system.enter(deadline)
	ring.pop(&kernel.completions)
	ring.pop(&kernel.completions)
	// The word changed while the wait ended at its deadline: a lost wake.
	if now >= deadline && intrinsics.atomic_load(&pair.turn) != next {
		pair.lost[side] += 1
	}
	pair.rounds[side] += 1
}

// pair_second is the entry of the second thread.
pair_second :: proc "c" (parameter: rawptr) -> ! {
	for intrinsics.atomic_load(&pair.stop) == 0 {
		turn := intrinsics.atomic_load(&pair.turn)
		if turn % 2 == 0 {
			system.word_wait(&pair.turn, turn, system.time() + LOST_WAIT)
			continue
		}
		pair_round(1, turn)
	}
	system.thread_stop()
}

// pairs measures the wakes between the two threads in one second, with
// `load` lockers that enter the kernel at the same time.
pairs :: proc "contextless" (load: int) -> u64 {
	pair = {}
	thread, status := system.thread_start(pair_second, nil)
	if status != .Ok {
		pairs_right = false
		return 0
	}
	before := report()
	start := system.time() + 20
	end := start + PAIR_TIME
	if load != 0 {
		seen: [lockers.LOCKER_CAPACITY]u32
		for index in 0 ..< load {
			slot := &board.slots[index]
			seen[index] = intrinsics.atomic_load(&slot.done)
			slot.mode = .Entries
			slot.start = start
			slot.end = end
			intrinsics.atomic_add(&slot.command, 1)
			system.word_wake(&slot.command, system.WAKE_ALL)
		}
		defer for index in 0 ..< load {
			slot := &board.slots[index]
			for intrinsics.atomic_load(&slot.done) == seen[index] {
				system.word_wait(&slot.done, seen[index], system.time() + 5000)
			}
		}
	}
	for system.time() < start {
		intrinsics.cpu_relax()
	}
	for system.time() < end {
		turn := intrinsics.atomic_load(&pair.turn)
		if turn % 2 == 1 {
			system.word_wait(&pair.turn, turn, system.time() + LOST_WAIT)
			continue
		}
		pair_round(0, turn)
	}
	after := report()
	intrinsics.atomic_store(&pair.stop, 1)
	intrinsics.atomic_add(&pair.turn, 2)
	system.word_wake(&pair.turn, system.WAKE_ALL)
	system.thread_wait(thread)
	lost_wakes += pair.lost[0] + pair.lost[1]
	if pair.rounds[0] < pair.rounds[1] || pair.rounds[0] > pair.rounds[1] + 1 {
		pairs_right = false
	}
	if load != 0 {
		pair_locks = locks_between(before, after)
	}
	return pair.rounds[0] * 1000 / PAIR_TIME
}

locks_text :: proc "contextless" (buffer: []u8, locks: [op.LOCK_KIND_CAPACITY]op.Lock_Count) -> string {
	writer := system.Writer{buffer = buffer}
	first := true
	for kind in op.Lock_Kind {
		count := locks[kind]
		if !first {
			system.write_part(&writer, ", ")
		}
		first = false
		system.write_part(&writer, op.LOCK_KIND_NAMES[kind])
		system.write_part(&writer, " ")
		system.write_part(&writer, count.waits)
		system.write_part(&writer, " of ")
		system.write_part(&writer, count.takes)
	}
	return system.written(&writer)
}

row :: proc "contextless" (canvas: graphics.Canvas, y: int, label: string, values: []u64, unit: string) {
	graphics.text(canvas, 12, y, label, COLOR_TEXT)
	line: [48]u8
	for value, index in values {
		graphics.text(canvas, COLUMN_X + index * COLUMN_WIDTH, y, system.format(line[:], value, unit), COLOR_TEXT)
	}
}

draw :: proc "contextless" (canvas: graphics.Canvas) {
	graphics.clear(canvas, COLOR_BACKGROUND)
	y := 12
	graphics.text(canvas, 12, y, "each locker works on its own objects: it waits only if the kernel makes it wait.", COLOR_DIM)
	y += LINE + LINE / 2
	graphics.text(canvas, 12, y, "in one second, all lockers", COLOR_DIM)
	for active, index in counts {
		line: [24]u8
		graphics.text(canvas, COLUMN_X + index * COLUMN_WIDTH, y, system.format(line[:], u64(active), active == 1 ? " locker" : " lockers"), COLOR_DIM)
	}
	y += LINE
	row(canvas, y, "kernel entries", entry_rates[:], "")
	y += LINE
	row(canvas, y, "pages on first use", fault_rates[:], "")
	y += LINE + LINE / 2
	graphics.text(canvas, 12, y, "word wait, two threads", COLOR_DIM)
	graphics.text(canvas, COLUMN_X, y, "alone", COLOR_DIM)
	graphics.text(canvas, COLUMN_X + COLUMN_WIDTH, y, "2 lockers enter", COLOR_DIM)
	y += LINE
	row(canvas, y, "wakes", {pairs_alone, pairs_loaded}, "")
	y += LINE + LINE / 2
	graphics.text(canvas, 12, y, "lock: waits of takes", COLOR_DIM)
	graphics.text(canvas, COLUMN_X, y, "4 entries", COLOR_DIM)
	graphics.text(canvas, COLUMN_X + COLUMN_WIDTH + 60, y, "4 faults", COLOR_DIM)
	graphics.text(canvas, COLUMN_X + 2 * COLUMN_WIDTH + 120, y, "word wait", COLOR_DIM)
	y += LINE
	for kind in op.Lock_Kind {
		graphics.text(canvas, 12, y, op.LOCK_KIND_NAMES[kind], COLOR_TEXT)
		line: [48]u8
		for locks, index in ([3][op.LOCK_KIND_CAPACITY]op.Lock_Count{entry_locks, fault_locks, pair_locks}) {
			count := locks[kind]
			graphics.text(canvas, COLUMN_X + index * (COLUMN_WIDTH + 60), y, system.format(line[:], count.waits, " of ", count.takes), COLOR_TEXT)
		}
		y += LINE
	}
	y += LINE / 2
	if done {
		right := entries_right && faults_right && pages_right && pairs_right && lost_wakes == 0
		graphics.text(canvas, 12, y, right ? "the counts add up, no wake was lost" : "a count is wrong", right ? COLOR_RIGHT : COLOR_WRONG)
	} else {
		graphics.text(canvas, 12, y, "measures in progress", COLOR_DIM)
	}
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	window, ok := display.open(ctx, WIDTH, HEIGHT, "locks")
	if !ok {
		system.stop(1)
	}
	canvas := window.canvas
	draw(canvas)
	display.present(&window)

	machine = ctx.handles[system.GRANT_MACHINE]
	image: []u8
	if address, status := system.memory_map(ctx.handles[system.GRANT_IMAGE], {}); status == .Ok {
		image = ([^]u8)(address)[:ctx.values[system.GRANT_VALUE_IMAGE_SIZE]]
	}
	memory, memory_status := system.memory_create(1)
	address, map_status := system.memory_map(memory)
	if image == nil || memory_status != .Ok || map_status != .Ok {
		system.log("locks: no boot image or no memory")
		system.stop(1)
	}
	board = (^lockers.Board)(address)
	names := [lockers.LOCKER_CAPACITY]string{"locker 1", "locker 2", "locker 3", "locker 4"}
	for &program, index in programs {
		grants: [op.CONTEXT_HANDLES]system.Grant
		values: [op.CONTEXT_VALUES]u64
		grants[lockers.GRANT_BOARD] = {memory, {.Read, .Write}}
		values[lockers.VALUE_INDEX] = u64(index)
		status: system.Status
		if program, status = system.program_start(system.image_find(image, "locker"), names[index], grants, values, LOCKER_AMOUNTS); status != .Ok {
			system.log("locks: cannot start a locker: status ", u64(status))
			system.stop(1)
		}
	}

	// Each locker is ready: its start is not in a measure.
	for &slot in board.slots {
		deadline := system.time() + 5000
		for intrinsics.atomic_load(&slot.done) == 0 && system.time() < deadline {
			system.word_wait(&slot.done, 0, deadline)
		}
	}
	measure(.Entries, &entry_rates, &entry_locks)
	system.log("locks: kernel entries in one second, each locker on its own objects: 1 locker ", entry_rates[0], ", 2 lockers ", entry_rates[1], ", 4 lockers ", entry_rates[2])
	measure(.Faults, &fault_rates, &fault_locks)
	system.log("locks: pages on first use in one second, each locker in its own memory: 1 locker ", fault_rates[0], ", 2 lockers ", fault_rates[1], ", 4 lockers ", fault_rates[2])
	pairs_alone = pairs(0)
	pairs_loaded = pairs(2)
	system.log("locks: word wait, two threads wake each other: ", pairs_alone, " wakes in one second alone, ", pairs_loaded, " while 2 lockers enter the kernel, ", lost_wakes, " lost")
	text: [512]u8
	system.log("locks: lock waits of takes, 4 lockers, kernel entries: ", locks_text(text[:], entry_locks))
	system.log("locks: lock waits of takes, 4 lockers, pages on first use: ", locks_text(text[:], fault_locks))
	system.log("locks: lock waits of takes, word wait with 2 lockers: ", locks_text(text[:], pair_locks))
	done = true
	if entries_right && faults_right && pages_right && pairs_right && lost_wakes == 0 {
		system.log("locks: ok, the kernel counted each entry, each page returned, no wake was lost")
	} else {
		system.log("locks: wrong: entries ", u64(entries_right), " faults ", u64(faults_right), " pages ", u64(pages_right), " wakes ", u64(pairs_right), " lost ", lost_wakes)
	}
	for program in programs {
		system.close(program)
	}
	draw(canvas)
	display.present(&window)
	for {
		for _ in display.next_event(&window) {}
		display.wait(&window, system.WAIT_FOREVER)
	}
}
