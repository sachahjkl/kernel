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
//
// **What it is for.** It shows how the kernel behaves when many programs
// enter it at one time: the count of the waits of each
// [lock of the kernel](term:lock-of-the-kernel), one
// [run queue](term:run-queue) for each processor, and the
// [word wait](term:word-wait) that loses no wake under load. The checks
// are of counts and of order; the rates are measures.
//
// **What a reader sees.** Start it from the menu of the programs, or with
// `start("locks")` in the console. The window shows the kernel entries and
// the page faults in one second with 1, 2 and 4 lockers, the time of the
// word wait between two threads alone and under load, and, for each
// measure, the waits of each lock. The log gets one line for each locker
// (`locks: locker 1 counted ... entries, the kernel ...`), the lines of the
// stress case and of the case of the frames, then the summary.
//
// **Its grants**: **Inspect**, to read the counts of the locks and of the
// kernel entries, and **Image**, to start the program `locker`. Its budget
// holds 9216 pages and 8 programs: 4 lockers of 1024 pages, then 3 at a
// time in the stress case.
//
// **What it does not prove.** A count of waits says how often a lock was
// contended, not how long: the times are printed as measures, and depend
// on the host of the run.
package locks

import "base:intrinsics"
import "support:display"
import "support:graphics"
import "support:interface"
import "support:lockers"
import op "contract:operation"
import "contract:ring"
import "support:random"
import "support:system"

// The window is built with the interface package (docs/INTERFACE.md).
records_now, records_before: [1024]interface.Draw_Record
text_now, text_before: [16384]u8
drawing: interface.Window_Drawing

MEASURE_TIME :: 300 // Milliseconds of one measure.
PAIR_TIME :: 500 // Milliseconds of one measure of the word wait.
// A wait that ends at this deadline after the word changed lost its wake. A
// wake that is only late on a loaded host comes long before it: the bound of
// a hang.
LOST_WAIT :: system.TEST_HANG_BOUND_MILLISECONDS
LOCKER_AMOUNTS :: system.Budget_Amounts{pages = 1024, programs = 1, threads = 1, processor = 1_000_000, log_records = 10}
CHURN_AMOUNTS :: system.Budget_Amounts{pages = 512, programs = 1, threads = lockers.CHURN_THREADS, processor = 1_000_000, log_records = 10}
CHURN_ROUNDS :: 40
CHURN_COUNT :: 3 // The programs of one round.

// The window follows docs/DESIGN.md where it is cheap: rectangles only,
// the grid of 8 pixels, the colors of the rules, a name in the dim color
// and a value in the text color.
WIDTH :: 784
LINE :: 24 // A line of text (16) and 8 between lines.
LEFT :: 16
GAP :: 8
HEIGHT :: LEFT + 4 * LINE + 2 * GAP + 2 * LINE + GAP + (len(op.Lock_Kind) + 1) * LINE + GAP + (CACHE_ROWS + 1) * LINE + GAP + 2 * LINE + LEFT
CACHE_ROWS :: 4 // The frame caches of the first 4 processors.
COLUMN_X :: 304
COLUMN_WIDTH :: 120
LOCK_X :: 176 // The table of the locks: the names are short.
LOCK_COLUMN_WIDTH :: 200


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
caches: [CACHE_ROWS]op.Processor_Report // The frame caches after the measures.

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
	deadline := end + system.TEST_HANG_BOUND_MILLISECONDS // The bound only ends a hang.
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
	// The lockers end at the same time.
	for index in 0 ..< load {
		slot := &board.slots[index]
		for intrinsics.atomic_load(&slot.done) == seen[index] {
			system.word_wait(&slot.done, seen[index], system.time() + system.TEST_HANG_BOUND_MILLISECONDS)
		}
	}
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

row :: proc "contextless" (table: ^interface.Draw_Table, y: int, label: string, values: []u64) {
	interface.draw_text(table, LEFT, y, label, graphics.COLOR_DIM)
	line: [48]u8
	for value, index in values {
		interface.draw_text(table, COLUMN_X + index * COLUMN_WIDTH, y, system.format(line[:], value), graphics.COLOR_TEXT)
	}
}

// draw builds a frame of the window with the interface package.
draw :: proc "contextless" (window: ^display.Window) {
	if drawing.now.records == nil {
		drawing = interface.window_drawing_of(records_now[:], records_before[:], text_now[:], text_before[:])
	}
	frame := interface.window_frame_begin(&drawing, window)
	draw_records(frame.table)
	interface.window_frame_end(&drawing, &frame, window)
}

draw_records :: proc "contextless" (table: ^interface.Draw_Table) {
	interface.draw_rectangle(table, 0, 0, WIDTH, HEIGHT, graphics.COLOR_BACKGROUND)
	y := LEFT
	interface.draw_text(table, LEFT, y, "each locker works on its own objects: it waits only if the kernel makes it wait.", graphics.COLOR_DIM)
	y += LINE + GAP
	interface.draw_text(table, LEFT, y, "in one second, all lockers", graphics.COLOR_DIM)
	for active, index in counts {
		line: [24]u8
		interface.draw_text(table, COLUMN_X + index * COLUMN_WIDTH, y, system.format(line[:], u64(active), active == 1 ? " locker" : " lockers"), graphics.COLOR_DIM)
	}
	y += LINE
	interface.draw_rectangle(table, GAP, y - 4, WIDTH - 2 * GAP, LINE, graphics.COLOR_CARD_TOP)
	row(table, y, "kernel entries", entry_rates[:])
	y += LINE
	row(table, y, "pages on first use", fault_rates[:])
	y += LINE + GAP
	interface.draw_text(table, LEFT, y, "word wait, two threads", graphics.COLOR_DIM)
	interface.draw_text(table, COLUMN_X, y, "alone", graphics.COLOR_DIM)
	interface.draw_text(table, COLUMN_X + COLUMN_WIDTH, y, "2 lockers enter", graphics.COLOR_DIM)
	y += LINE
	interface.draw_rectangle(table, GAP, y - 4, WIDTH - 2 * GAP, LINE, graphics.COLOR_CARD_TOP)
	row(table, y, "wakes", {pairs_alone, pairs_loaded})
	y += LINE + GAP
	interface.draw_text(table, LEFT, y, "waits of takes", graphics.COLOR_DIM)
	for name, index in ([3]string{"4 lockers, entries", "4 lockers, faults", "word wait"}) {
		interface.draw_text(table, LOCK_X + index * LOCK_COLUMN_WIDTH, y, name, graphics.COLOR_DIM)
	}
	y += LINE
	for kind in op.Lock_Kind {
		if int(kind) % 2 == 0 {
			interface.draw_rectangle(table, GAP, y - 4, WIDTH - 2 * GAP, LINE, graphics.COLOR_CARD_TOP)
		}
		interface.draw_text(table, LEFT, y, op.LOCK_KIND_NAMES[kind], graphics.COLOR_DIM)
		line: [48]u8
		for locks, index in ([3][op.LOCK_KIND_CAPACITY]op.Lock_Count{entry_locks, fault_locks, pair_locks}) {
			count := locks[kind]
			interface.draw_text(table, LOCK_X + index * LOCK_COLUMN_WIDTH, y, system.format(line[:], count.waits, " of ", count.takes), graphics.COLOR_TEXT)
		}
		y += LINE
	}
	y += GAP
	// The frame cache of each processor (Processor_Report): a stack of free
	// frames that pages on first use take with no frame lock.
	interface.draw_text(table, LEFT, y, "frame cache", graphics.COLOR_DIM)
	for name, index in ([4]string{"frames now", "batches taken", "batches given", "drains"}) {
		interface.draw_text(table, LOCK_X + index * (LOCK_COLUMN_WIDTH * 3 / 4), y, name, graphics.COLOR_DIM)
	}
	y += LINE
	for index in 0 ..< CACHE_ROWS {
		cache := caches[index]
		if index % 2 == 0 {
			interface.draw_rectangle(table, GAP, y - 4, WIDTH - 2 * GAP, LINE, graphics.COLOR_CARD_TOP)
		}
		cache_line: [32]u8
		interface.draw_text(table, LEFT, y, system.format(cache_line[:], "processor ", u64(index)), graphics.COLOR_DIM)
		for value, column in ([4]u64{cache.cache_frames, cache.cache_batches_taken, cache.cache_batches_given, cache.cache_drains}) {
			interface.draw_text(table, LOCK_X + column * (LOCK_COLUMN_WIDTH * 3 / 4), y, system.format(cache_line[:], value), graphics.COLOR_TEXT)
		}
		y += LINE
	}
	y += GAP
	line: [64]u8
	interface.draw_text(table, LEFT, y, "programs stopped while they ran", graphics.COLOR_DIM)
	interface.draw_text(table, COLUMN_X, y, system.format(line[:], stress_started), graphics.COLOR_TEXT)
	y += LINE
	if done {
		right := entries_right && faults_right && pages_right && pairs_right && lost_wakes == 0 && stress_right
		interface.draw_text(table, LEFT, y, right ? "the counts add up, no wake was lost, stopped programs returned all" : "a count is wrong", right ? graphics.COLOR_PROGRAM : graphics.COLOR_FAILED)
	} else {
		interface.draw_text(table, LEFT, y, "measures in progress", graphics.COLOR_DIM)
	}
}

// stress stops programs while their threads run, many times: each round
// starts three churn lockers; the second and the third stop the one before
// them after a few milliseconds, while this program stops each one, or
// closes its last handle at once. At the end, each page, program and thread
// is back in the budget of this program, and the free pages are the pages
// of the budgets and the reserved pages.
stress :: proc "contextless" (image: []u8, programs_free: u64) {
	// The lockers of the measures have ended: their slots are back.
	initial: system.Budget_Amounts
	for deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS; system.time() < deadline; {
		initial, _ = system.budget_read()
		if initial.programs == programs_free {
			break
		}
		system.sleep(system.time() + 10)
	}
	file := system.image_find(image, "locker")
	started, stopped, closed: u64
	helper, _ := system.thread_start(stopper_run, nil)
	for round in 0 ..< u64(CHURN_ROUNDS) {
		churners: [CHURN_COUNT]system.Handle
		for &churner, index in churners {
			grants: [op.CONTEXT_HANDLES]system.Grant
			values: [op.CONTEXT_VALUES]u64
			values[lockers.VALUE_ROLE] = lockers.ROLE_CHURN
			values[lockers.VALUE_STOP_AFTER] = 1 + (round + u64(index)) % 4
			if index != 0 {
				grants[lockers.GRANT_PEER] = {churners[index - 1], {.Control}}
			}
			status: system.Status
			churner, status = system.program_start(file, "churn", grants, random.values_with_seed(&program_generator, values), CHURN_AMOUNTS)
			if status == .Ok {
				started += 1
			}
		}
		pause := system.time() + 2 + round % 3
		for system.time() < pause {
			intrinsics.cpu_relax()
		}
		for churner, index in churners {
			if churner == 0 {
				continue
			}
			switch (round + u64(index)) % 3 {
			case 0:
				system.call(.Program_Stop, u64(churner), 7)
				stopped += 1
			case 1:
				// The other thread stops it while this one closes the handle.
				seen := intrinsics.atomic_load(&stopper.done)
				intrinsics.atomic_store(&stopper.target, u32(churner))
				system.word_wake(&stopper.target)
				for intrinsics.atomic_load(&stopper.target) != 0 {
					intrinsics.cpu_relax()
				}
				system.close(churner)
				for intrinsics.atomic_load(&stopper.done) == seen {
					intrinsics.cpu_relax()
				}
				stopped += 1
				closed += 1
				continue
			}
			system.close(churner) // The last handle of this program to it, at once.
			closed += 1
		}
	}
	intrinsics.atomic_store(&stopper.quit, 1)
	system.word_wake(&stopper.target)
	system.thread_wait(helper)
	// The cleanup of a program runs when its last thread leaves its
	// processor: wait for the budget. The bound only ends a hang.
	deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS
	after: system.Budget_Amounts
	for system.time() < deadline {
		after, _ = system.budget_read()
		if after.pages == initial.pages && after.programs == initial.programs && after.threads == initial.threads {
			break
		}
		system.sleep(system.time() + 10)
	}
	stress_started = started
	final := report()
	stress_right = started == CHURN_ROUNDS * CHURN_COUNT && after.pages == initial.pages && after.programs == initial.programs && after.threads == initial.threads && final.budget_pages + final.reserved_pages == final.free_pages
	system.log("locks: stress: ", started, " programs started, ", stopped, " stopped by this program (some by a thread while another thread closed the last handle), ", closed - stopped, " only by the close of their last handle, while their threads ran and they stopped each other; budget: pages ", after.pages, " of ", initial.pages, ", programs ", after.programs, " of ", initial.programs, ", threads ", after.threads, " of ", initial.threads, "; free pages ", final.free_pages, ", in budgets ", final.budget_pages, ", reserved ", final.reserved_pages)
}

stress_right: bool
stress_started: u64

// The stress case of the frames: two lockers make and close memory objects
// of 600 pages (three list pages each), two lockers fault pages on first
// use, and this program reads System_Report with no pause. The kernel checks
// its sums of the frames at each report and at each drain (in the test
// build); this program checks that the free pages less the reserved pages
// are the pages of the budgets in each report. The lockers and this program
// are different programs: no program lock orders their kernel entries.
FRAMES_STRESS_TIME :: 500 // Milliseconds.

frames_stress_right: bool

frames_stress :: proc "contextless" () {
	modes := [lockers.LOCKER_CAPACITY]lockers.Mode{.Large, .Large, .Faults, .Faults}
	reports, wrong, made, faulted: u64
	answered := true
	// A loaded host can give the lockers no time in one round: the rounds go
	// on until each kind of work ran at least once. The bound only ends a
	// hang.
	for stress_deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS; answered && (made == 0 || faulted == 0) && system.time() < stress_deadline; {
		seen: [lockers.LOCKER_CAPACITY]u32
		start := system.time() + 20
		end := start + FRAMES_STRESS_TIME
		for index in 0 ..< lockers.LOCKER_CAPACITY {
			slot := &board.slots[index]
			seen[index] = intrinsics.atomic_load(&slot.done)
			slot.mode = modes[index]
			slot.start = start
			slot.end = end
			intrinsics.atomic_add(&slot.command, 1)
			system.word_wake(&slot.command, system.WAKE_ALL)
		}
		for system.time() < end + 5 {
			read := report()
			reports += 1
			if read.budget_pages + read.reserved_pages != read.free_pages {
				wrong += 1
			}
		}
		for index in 0 ..< lockers.LOCKER_CAPACITY {
			slot := &board.slots[index]
			for intrinsics.atomic_load(&slot.done) == seen[index] {
				if system.time() > end + system.TEST_HANG_BOUND_MILLISECONDS {
					answered = false
					break
				}
				system.word_wait(&slot.done, seen[index], system.time() + 100)
			}
		}
		made += board.slots[0].count + board.slots[1].count
		faulted += board.slots[2].count + board.slots[3].count
	}
	frames_stress_right = answered && made != 0 && faulted != 0 && wrong == 0
	system.log("locks: frames: ", made, " objects of 600 pages made and closed by two lockers while two lockers faulted ", faulted, " pages and this program read ", reports, " reports; reports where the free pages less the reserved pages were not the pages of the budgets: ", wrong)
}

// The second thread of the stress case: it stops the program that the
// first thread names in `stop_target`, while the first thread closes its
// last handle to it.
Stopper :: struct {
	target: u32, // A program handle. 0: none.
	done:   u32, // Adds 1 after each stop.
	quit:   u32,
}

stopper: Stopper

stopper_run :: proc "c" (parameter: rawptr) -> ! {
	for intrinsics.atomic_load(&stopper.quit) == 0 {
		target := intrinsics.atomic_exchange(&stopper.target, 0)
		if target == 0 {
			system.word_wait(&stopper.target, 0, system.time() + 100)
			continue
		}
		system.call(.Program_Stop, u64(target), 7)
		intrinsics.atomic_add(&stopper.done, 1)
	}
	system.thread_stop()
}

// The random generator of this program (support/random).
program_generator: random.Generator

// entry starts the four lockers, runs the measures with 1, 2 and 4 of
// them, the word wait alone and under load, the stress case and the case
// of the frames, checks the counts, and writes the summary. It then keeps
// the window open until the program is stopped. With no random seed, no
// boot image, no memory for the board, or a locker that does not start, it
// writes the reason on the log and stops with the code 1.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	// The random generator of this program, from the seed that its starter
	// gave: it gives the seed of each program that this one starts.
	if !random.generator_from_context(&program_generator, ctx) {
		system.log("locks: no random seed in the context")
		system.stop(1)
	}
	window, ok := display.open(ctx, WIDTH, HEIGHT, "locks")
	if !ok {
		system.stop(1)
	}
	draw(&window)

	machine = ctx.handles[system.GRANT_MACHINE]
	at_start, _ := system.budget_read()
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
		if program, status = system.program_start(system.image_find(image, "locker"), names[index], grants, random.values_with_seed(&program_generator, values), LOCKER_AMOUNTS); status != .Ok {
			system.log("locks: cannot start a locker: status ", u64(status))
			system.stop(1)
		}
	}

	// Each locker is ready: its start is not in a measure.
	for &slot in board.slots {
		deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS
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
	frames_stress()
	for program in programs {
		system.close(program)
	}
	stress(image, at_start.programs)
	// The frame caches of the processors, after the measures and the stress.
	processor_count := report().processors
	for &cache, index in caches {
		if u64(index) < processor_count {
			system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.Processor), u64(index), u64(uintptr(&cache)), size_of(cache))
		}
	}
	{
		buffer: [512]u8
		writer := system.Writer{buffer = buffer[:]}
		system.write_part(&writer, "locks: frame caches after the measures (frames now, batches taken, batches given, drains):")
		for cache, index in caches {
			if u64(index) >= processor_count {
				break
			}
			system.write_part(&writer, " processor ")
			system.write_unsigned(&writer, u64(index))
			system.write_part(&writer, ": ")
			system.write_unsigned(&writer, cache.cache_frames)
			system.write_part(&writer, ", ")
			system.write_unsigned(&writer, cache.cache_batches_taken)
			system.write_part(&writer, ", ")
			system.write_unsigned(&writer, cache.cache_batches_given)
			system.write_part(&writer, ", ")
			system.write_unsigned(&writer, cache.cache_drains)
			system.write_part(&writer, ";")
		}
		system.log(system.written(&writer))
	}
	done = true
	if entries_right && faults_right && pages_right && pairs_right && lost_wakes == 0 && stress_right && frames_stress_right {
		system.log("locks: ok, the kernel counted each entry, each page returned, no wake was lost, each stopped program returned its pages, its slot and its threads")
	} else {
		system.log("locks: wrong: entries ", u64(entries_right), " faults ", u64(faults_right), " pages ", u64(pages_right), " wakes ", u64(pairs_right), " lost ", lost_wakes, " stress ", u64(stress_right), " frames ", u64(frames_stress_right))
	}
	draw(&window)
	for {
		for _ in display.next_event(&window) {}
		display.wait(&window, system.WAIT_FOREVER)
	}
}
