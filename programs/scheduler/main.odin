// The scheduling strategies of the kernel, measured side by side
// (docs/SCHEDULING.md).
//
// The program runs four cases under each strategy: two threads that wake
// each other while spinners keep each processor busy; a thread that sleeps
// 2 ms, many times, while 8 spinners run, with the delay of each wake;
// 8 spinners of one weight, their shares and their work; 12 spinners with
// the weights 1, 2 and 4, their shares. Then it changes the strategy 100
// times while threads start, stop, wake each other and move. The window
// shows the numbers and the strategy in use; the keys 1, 2 and 3, or a
// click on a strategy, change it.
//
// The program checks what does not depend on the load of the host: no
// spinner starved, EEVDF woke more often than round robin in the same run,
// the weights order the shares under the strategies with weights, each
// thread runs after the changes, no wake was lost, the kernel refuses a
// change with no right Schedule and a weight above the full weight.
//
// The program needs the machine with the rights Inspect and Schedule.
package scheduler

import "base:intrinsics"
import "support:display"
import "support:graphics"
import op "contract:operation"
import "contract:ring"
import "support:system"

STRATEGY_COUNT :: 3
@(rodata)
strategies := [STRATEGY_COUNT]op.Strategy{.Round_Robin, .Fair, .Eevdf}

PAIR_TIME :: 400 // Milliseconds: two threads wake each other.
SLEEP_TIME :: 2 // Milliseconds: one sleep of the thread whose delay is measured.
SLEEP_COUNT :: 60
SHARE_TIME :: 500 // Milliseconds: the spinners share the processors.
WARM_TIME :: 50 // Milliseconds before a measure: the spinners started.
LOST_WAIT :: 1000 // Milliseconds: a wait that ends at its deadline after its word changed lost its wake.
EQUAL_COUNT :: 8
WEIGHTED_COUNT :: 12
@(rodata)
weights := [3]u64{256, 512, 1024} // 1 : 2 : 4.
CHANGES :: 100
SPINNER_LIMIT :: 16

// One spinner: its count of work, alone in its cache line.
Spinner :: struct #align (64) {
	count: u64,
	stop:  u32,
}

// The results of one strategy.
Result :: struct {
	measured:    bool,
	wakes:       u64, // In one second.
	// During the case of the two threads: the turns that a wake ended on the
	// processor of the waker and by an interrupt, and the moves.
	pair_local, pair_interrupts, pair_moves: u64,
	median:      u64, // Microseconds.
	worst:       u64,
	shares:      [EQUAL_COUNT]u64, // Tenths of a percent of the work of the spinners.
	work:        u64, // Increments in one second, all the spinners.
	weighted:    [3]u64, // Tenths of a percent: the mean share of a spinner of each weight.
	weighted_least: u64, // The least share of the 12, tenths of a percent.
	preemptions: u64,
	interrupt_preemption: u64, // Nanoseconds in the kernel for one wake preemption by an interrupt.
	pick:        u64, // Nanoseconds for one pick.
	moves:       u64,
}

machine: system.Handle
spinners: [SPINNER_LIMIT]Spinner
spinner_threads: [SPINNER_LIMIT]system.Thread
results: [STRATEGY_COUNT]Result
lost_wakes: u64
right := true
done: bool
problem: string // The first check that failed.
refusals_right: bool

// The stress case.
stress_done: bool
stress_right: bool
stress_churned, stress_wakes, stress_changes: u64

fail :: proc "contextless" (what: string) {
	if right {
		problem = what
	}
	right = false
}

system_report :: proc "contextless" () -> (report: op.System_Report) {
	system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.System), 0, u64(uintptr(&report)), size_of(report))
	return report
}

processor_report :: proc "contextless" (index: u64) -> (report: op.Processor_Report) {
	system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.Processor), index, u64(uintptr(&report)), size_of(report))
	return report
}

// Counts of all the processors.
Counts :: struct {
	picks, preemptions, moves, pick_cycles, interrupt_preemptions, preempt_cycles: u64,
}

counts :: proc "contextless" (processors: u64) -> (sum: Counts) {
	for index in 0 ..< processors {
		report := processor_report(index)
		sum.picks += report.picks
		sum.preemptions += report.preemptions
		sum.moves += report.moves
		sum.pick_cycles += report.pick_cycles
		sum.interrupt_preemptions += report.interrupt_preemptions
		sum.preempt_cycles += report.preempt_cycles
	}
	return sum
}

spin :: proc "c" (parameter: rawptr) -> ! {
	spinner := (^Spinner)(parameter)
	for intrinsics.atomic_load(&spinner.stop) == 0 {
		for _ in 0 ..< 256 {
			intrinsics.volatile_store(&spinner.count, intrinsics.volatile_load(&spinner.count) + 1)
		}
	}
	system.thread_stop()
}

// spinners_start starts count spinners from first; weight 0 is the full
// weight. false: a thread did not start.
spinners_start :: proc "contextless" (first, count: int, weight_of: proc "contextless" (index: int) -> u64) -> bool {
	for index in first ..< first + count {
		spinners[index] = {}
		status: system.Status
		spinner_threads[index], status = system.thread_start(spin, &spinners[index], weight = weight_of(index - first))
		if status != .Ok {
			return false
		}
	}
	return true
}

spinners_stop :: proc "contextless" (first, count: int) {
	for index in first ..< first + count {
		intrinsics.atomic_store(&spinners[index].stop, 1)
	}
	for index in first ..< first + count {
		if spinner_threads[index].handle != 0 {
			system.thread_wait(spinner_threads[index])
			spinner_threads[index] = {}
		}
	}
}

full_weight :: proc "contextless" (index: int) -> u64 {
	return 0
}

weight_of_class :: proc "contextless" (index: int) -> u64 {
	return weights[index % 3]
}

spinner_counts :: proc "contextless" (first, count: int) -> (values: [SPINNER_LIMIT]u64) {
	for index in first ..< first + count {
		values[index] = intrinsics.volatile_load(&spinners[index].count)
	}
	return values
}

// Two threads wake each other with the word wait: each one changes the
// word, wakes the other one, and waits while the word holds its own value,
// in one kernel entry.
Pair :: struct {
	turn:   u32, // Even: the first thread runs. Odd: the second one.
	stop:   u32,
	rounds: [2]u64,
	lost:   [2]u64,
}

pair: Pair

pair_round :: proc "contextless" (side: int, turn: u32) {
	next := turn + 1
	intrinsics.atomic_store(&pair.turn, next)
	word := op.Word{address = u64(uintptr(&pair.turn)), value = u64(next)}
	kernel := system.kernel_ring()
	ring.push(&kernel.commands, ring.Record{kind = u32(op.Operation.Word_Wake), values = {0 = u64(uintptr(&pair.turn)), 1 = 1}})
	ring.push(&kernel.commands, ring.Record{kind = u32(op.Operation.Word_Wait), values = {0 = u64(uintptr(&word)), 1 = 1}})
	deadline := system.time() + LOST_WAIT
	now := system.enter(deadline)
	ring.pop(&kernel.completions)
	ring.pop(&kernel.completions)
	if now >= deadline && intrinsics.atomic_load(&pair.turn) != next {
		pair.lost[side] += 1
	}
	pair.rounds[side] += 1
}

// pair_side is the entry of one side: the parameter is the side.
pair_side :: proc "c" (parameter: rawptr) -> ! {
	side := int(uintptr(parameter))
	for intrinsics.atomic_load(&pair.stop) == 0 {
		turn := intrinsics.atomic_load(&pair.turn)
		if int(turn % 2) != side {
			system.word_wait(&pair.turn, turn, system.time() + LOST_WAIT)
			continue
		}
		pair_round(side, turn)
	}
	system.thread_stop()
}

pair_threads: [2]system.Thread

pair_start :: proc "contextless" () -> bool {
	pair = {}
	for side in 0 ..< 2 {
		status: system.Status
		if pair_threads[side], status = system.thread_start(pair_side, rawptr(uintptr(side))); status != .Ok {
			return false
		}
	}
	return true
}

pair_stop :: proc "contextless" () {
	intrinsics.atomic_store(&pair.stop, 1)
	intrinsics.atomic_add(&pair.turn, 2)
	system.word_wake(&pair.turn, system.WAKE_ALL)
	for &thread in pair_threads {
		system.thread_wait(thread)
		thread = {}
	}
	lost_wakes += pair.lost[0] + pair.lost[1]
}

// The thread whose wake delay is measured: it sleeps SLEEP_TIME, and
// measures how late it runs after the millisecond of its deadline.
Sleeper :: struct {
	delays: [SLEEP_COUNT]u64, // Microseconds.
	ended:  u32,
}

sleeper: Sleeper

sleep_run :: proc "c" (parameter: rawptr) -> ! {
	for index in 0 ..< SLEEP_COUNT {
		deadline := system.time() + SLEEP_TIME
		system.sleep(deadline)
		late := system.nanoseconds()
		late = late > deadline * 1_000_000 ? late - deadline * 1_000_000 : 0
		sleeper.delays[index] = late / 1000
	}
	intrinsics.atomic_store(&sleeper.ended, 1)
	system.word_wake(&sleeper.ended)
	system.thread_stop()
}

// share_tenths gives the tenths of a percent of a part of a total.
share_tenths :: proc "contextless" (part, total: u64) -> u64 {
	return total == 0 ? 0 : part * 1000 / total
}

// measure runs the four cases under one strategy.
measure :: proc "contextless" (index: int, processors: u64) {
	result := &results[index]
	if _, status := system.strategy_set(machine, strategies[index]); status != .Ok {
		fail("Strategy_Set refused")
		return
	}
	before := counts(processors)

	// 1. Two threads wake each other while a spinner runs on each processor.
	if !spinners_start(0, int(processors), full_weight) || !pair_start() {
		fail("a thread did not start")
		return
	}
	system.sleep(system.time() + WARM_TIME)
	start_rounds := intrinsics.atomic_load(&pair.rounds[0])
	pair_before := counts(processors)
	start := system.nanoseconds()
	system.sleep(system.time() + PAIR_TIME)
	rounds := intrinsics.atomic_load(&pair.rounds[0]) - start_rounds
	elapsed := max(system.nanoseconds() - start, 1)
	pair_after := counts(processors)
	result.pair_interrupts = pair_after.interrupt_preemptions - pair_before.interrupt_preemptions
	result.pair_local = pair_after.preemptions - pair_before.preemptions - result.pair_interrupts
	result.pair_moves = pair_after.moves - pair_before.moves
	result.wakes = rounds * 1_000_000_000 / elapsed
	pair_stop()
	spinners_stop(0, int(processors))

	// 2. The delay of a thread that sleeps, while 8 spinners run. Its
	// request is short: under EEVDF, its deadline comes early.
	if !spinners_start(0, EQUAL_COUNT, full_weight) {
		fail("a thread did not start")
		return
	}
	system.sleep(system.time() + WARM_TIME)
	sleeper = {}
	sleeping, status := system.thread_start(sleep_run, nil, request = 500)
	if status != .Ok {
		fail("a thread did not start")
		return
	}
	for intrinsics.atomic_load(&sleeper.ended) == 0 {
		system.word_wait(&sleeper.ended, 0, system.time() + 1000)
	}
	system.thread_wait(sleeping)
	sorted := sleeper.delays
	for at in 1 ..< len(sorted) {
		for back := at; back > 0 && sorted[back - 1] > sorted[back]; back -= 1 {
			sorted[back - 1], sorted[back] = sorted[back], sorted[back - 1]
		}
	}
	result.median = sorted[len(sorted) / 2]
	result.worst = sorted[len(sorted) - 1]

	// 3. The same 8 spinners: their shares and their work.
	first := spinner_counts(0, EQUAL_COUNT)
	start = system.nanoseconds()
	system.sleep(system.time() + SHARE_TIME)
	last := spinner_counts(0, EQUAL_COUNT)
	elapsed = max(system.nanoseconds() - start, 1)
	spinners_stop(0, EQUAL_COUNT)
	total: u64
	for spinner in 0 ..< EQUAL_COUNT {
		total += last[spinner] - first[spinner]
	}
	for spinner in 0 ..< EQUAL_COUNT {
		result.shares[spinner] = share_tenths(last[spinner] - first[spinner], total)
		// No spinner starved: each one has more than a sixteenth of its
		// equal part.
		if (last[spinner] - first[spinner]) * 16 * EQUAL_COUNT <= total {
			fail("a spinner of one weight starved")
		}
	}
	result.work = total * 1_000_000_000 / elapsed

	// 4. 12 spinners with the weights 1, 2 and 4.
	if !spinners_start(0, WEIGHTED_COUNT, weight_of_class) {
		fail("a thread did not start")
		return
	}
	system.sleep(system.time() + WARM_TIME)
	first = spinner_counts(0, WEIGHTED_COUNT)
	system.sleep(system.time() + SHARE_TIME)
	last = spinner_counts(0, WEIGHTED_COUNT)
	spinners_stop(0, WEIGHTED_COUNT)
	total = 0
	for spinner in 0 ..< WEIGHTED_COUNT {
		total += last[spinner] - first[spinner]
	}
	class_sum: [3]u64
	result.weighted_least = 1000
	for spinner in 0 ..< WEIGHTED_COUNT {
		part := last[spinner] - first[spinner]
		class_sum[spinner % 3] += part
		result.weighted_least = min(result.weighted_least, share_tenths(part, total))
		if part * 16 * WEIGHTED_COUNT <= total {
			fail("a spinner with a weight starved")
		}
	}
	for class in 0 ..< 3 {
		result.weighted[class] = share_tenths(class_sum[class], total * (WEIGHTED_COUNT / 3))
	}
	if strategies[index] != .Round_Robin && class_sum[2] <= class_sum[0] {
		fail("the weights did not order the shares")
	}

	after := counts(processors)
	result.preemptions = after.preemptions - before.preemptions
	result.moves = after.moves - before.moves
	picks := max(after.picks - before.picks, 1)
	result.pick = (after.pick_cycles - before.pick_cycles) * 1_000_000_000 / max(system.cycle_frequency(), 1) / picks
	interrupts := max(after.interrupt_preemptions - before.interrupt_preemptions, 1)
	result.interrupt_preemption = (after.preempt_cycles - before.preempt_cycles) * 1_000_000_000 / max(system.cycle_frequency(), 1) / interrupts
	result.measured = true
}

tenths_part :: proc "contextless" (writer: ^system.Writer, value: u64) {
	system.write_unsigned(writer, value / 10)
	system.write_part(writer, ".")
	system.write_unsigned(writer, value % 10)
	system.write_part(writer, " %")
}

log_result :: proc "contextless" (index: int) {
	result := &results[index]
	least, most := u64(1000), u64(0)
	for share in result.shares {
		least, most = min(least, share), max(most, share)
	}
	buffer: [800]u8
	writer := system.Writer{buffer = buffer[:]}
	system.write_part(&writer, "scheduler: ")
	system.write_part(&writer, op.STRATEGY_NAMES[strategies[index]])
	system.write_part(&writer, ": two threads that wake each other, a spinner on each processor: ")
	system.write_unsigned(&writer, result.wakes)
	system.write_part(&writer, " wakes in one second (")
	system.write_unsigned(&writer, result.pair_local)
	system.write_part(&writer, " turns ended on the processor of the waker, ")
	system.write_unsigned(&writer, result.pair_interrupts)
	system.write_part(&writer, " by an interrupt, ")
	system.write_unsigned(&writer, result.pair_moves)
	system.write_part(&writer, " moves); a thread that sleeps 2 ms among 8 spinners: late by ")
	system.write_unsigned(&writer, result.median)
	system.write_part(&writer, " us in the middle, ")
	system.write_unsigned(&writer, result.worst)
	system.write_part(&writer, " us at worst; 8 spinners of one weight: shares ")
	tenths_part(&writer, least)
	system.write_part(&writer, " to ")
	tenths_part(&writer, most)
	system.write_part(&writer, ", work ")
	system.write_unsigned(&writer, result.work / 1_000_000)
	system.write_part(&writer, " million in one second; 12 spinners, weights 1 2 4: a spinner of each weight ")
	tenths_part(&writer, result.weighted[0])
	system.write_part(&writer, ", ")
	tenths_part(&writer, result.weighted[1])
	system.write_part(&writer, ", ")
	tenths_part(&writer, result.weighted[2])
	system.write_part(&writer, "; ")
	system.write_unsigned(&writer, result.preemptions)
	system.write_part(&writer, " turns ended by a wake, ")
	system.write_unsigned(&writer, result.moves)
	system.write_part(&writer, " moves, one pick ")
	system.write_unsigned(&writer, result.pick)
	system.write_part(&writer, " ns, one preemption by an interrupt ")
	system.write_unsigned(&writer, result.interrupt_preemption)
	system.write_part(&writer, " ns in the kernel")
	// Longer than the buffer of system.log (512 bytes): one Log of the whole text.
	text := system.written(&writer)
	system.call(.Log, u64(system.context_record().handles[op.CONTEXT_LOG]), u64(uintptr(raw_data(text))), u64(len(text)), u64(op.Log_Level.Info), 0, 0)
}

// The stress case: a thread changes the strategy CHANGES times while 8
// spinners run (they move between the processors), two threads wake each
// other, and this thread starts threads that end at once.
Changer :: struct {
	ended:   u32,
	changes: u64,
	refused: u64,
	times:   [CHANGES]u64, // Nanoseconds of each Strategy_Set, with its kernel entry.
}

// The time of one Strategy_Set over the changes: least, middle, worst.
change_least, change_middle, change_worst: u64

changer: Changer

change_run :: proc "c" (parameter: rawptr) -> ! {
	for index in 0 ..< CHANGES {
		start := system.nanoseconds()
		_, status := system.strategy_set(machine, strategies[index % STRATEGY_COUNT])
		changer.times[index] = system.nanoseconds() - start
		if status == .Ok {
			changer.changes += 1
		} else {
			changer.refused += 1
		}
		// A pause of 0 to 2 ms: some changes fall in the same tick.
		if index % 3 != 0 {
			system.sleep(system.time() + u64(index % 3))
		}
	}
	intrinsics.atomic_store(&changer.ended, 1)
	system.word_wake(&changer.ended)
	system.thread_stop()
}

brief :: proc "c" (parameter: rawptr) -> ! {
	system.thread_stop()
}

stress :: proc "contextless" () {
	at_start, _ := system.budget_read()
	if !spinners_start(0, EQUAL_COUNT, weight_of_class) || !pair_start() {
		fail("a thread did not start")
		return
	}
	changer = {}
	thread, status := system.thread_start(change_run, nil)
	if status != .Ok {
		fail("a thread did not start")
		return
	}
	for intrinsics.atomic_load(&changer.ended) == 0 {
		if churn, churn_status := system.thread_start(brief, nil); churn_status == .Ok {
			system.thread_wait(churn)
			stress_churned += 1
		}
	}
	system.thread_wait(thread)
	// After the last change, each thread still runs.
	first := spinner_counts(0, EQUAL_COUNT)
	rounds := intrinsics.atomic_load(&pair.rounds[0])
	system.sleep(system.time() + 200)
	last := spinner_counts(0, EQUAL_COUNT)
	stress_wakes = pair.rounds[0]
	ran := intrinsics.atomic_load(&pair.rounds[0]) > rounds
	for spinner in 0 ..< EQUAL_COUNT {
		ran &&= last[spinner] > first[spinner]
	}
	pair_stop()
	spinners_stop(0, EQUAL_COUNT)
	// The slots of the threads returned to the budget.
	after: system.Budget_Amounts
	for deadline := system.time() + 2000; system.time() < deadline; {
		after, _ = system.budget_read()
		if after.threads == at_start.threads {
			break
		}
		system.sleep(system.time() + 10)
	}
	stress_changes = changer.changes
	sorted := changer.times
	for at in 1 ..< len(sorted) {
		for back := at; back > 0 && sorted[back - 1] > sorted[back]; back -= 1 {
			sorted[back - 1], sorted[back] = sorted[back], sorted[back - 1]
		}
	}
	change_least, change_middle, change_worst = sorted[0], sorted[CHANGES / 2], sorted[CHANGES - 1]
	stress_right = ran && changer.changes == CHANGES && changer.refused == 0 && after.threads == at_start.threads
	if !stress_right {
		fail("the stress case")
	}
	stress_done = true
	system.log("scheduler: one Strategy_Set, with its kernel entry: ", change_least, " ns at least, ", change_middle, " ns in the middle, ", change_worst, " ns at worst")
	system.log("scheduler: stress: ", changer.changes, " changes of strategy while ", stress_churned, " threads started and stopped, two threads woke each other ", stress_wakes, " times and 8 spinners ran and moved; after the last change each thread ran: ", u64(ran), "; thread slots ", after.threads, " of ", at_start.threads)
}

// refusals: Strategy_Set with a copy of the machine handle that has no
// right Schedule, and a weight above the full weight.
refusals :: proc "contextless" () -> bool {
	copy, status := system.give(0, machine, {.Inspect})
	if status != .Ok {
		return false
	}
	_, refused := system.strategy_set(copy, .Fair)
	system.close(copy)
	_, too_heavy := system.thread_start(brief, nil, weight = op.WEIGHT_FULL + 1)
	return refused == .No_Right && too_heavy == .Bad_Operation
}

// The window (docs/DESIGN.md): cards of rectangles on the grid of 8
// pixels, the colors of the rules. The scheduler is the kernel: its
// accent is the color of the kernel, and the three strategies are three
// shades of it.
WIDTH :: 976
HEIGHT :: 704
MARGIN :: 8
CARD_TITLE :: graphics.CARD_TITLE
CARD_INSIDE :: graphics.CARD_MARGIN

@(rodata)
strategy_shades := [STRATEGY_COUNT]u32{75, 100, 150}

strategy_color :: proc "contextless" (index: int) -> graphics.Color {
	return graphics.shade(graphics.COLOR_KERNEL, strategy_shades[index])
}

// bar: a full part of a bar, from 125 % of its color at the top to 78 % at
// the bottom, on its track.
bar :: proc "contextless" (canvas: graphics.Canvas, x, y, width, height, full: int, color: graphics.Color) {
	graphics.fill(canvas, x, y, width, height, graphics.COLOR_TRACK)
	graphics.block(canvas, x, y, clamp(full, 0, width), height, graphics.shade(color, 125), graphics.shade(color, 78))
}

large :: proc "contextless" (canvas: graphics.Canvas, x, y: int, characters: string, scale: int, color: graphics.Color) -> int {
	at := x
	for index in 0 ..< len(characters) {
		value := characters[index]
		if value >= graphics.FONT_FIRST && value <= graphics.FONT_LAST {
			glyph := graphics.font[value - graphics.FONT_FIRST]
			for bits, row in glyph {
				for column in 0 ..< graphics.CELL_WIDTH {
					if bits << uint(column) & 0x80 != 0 {
						graphics.fill(canvas, at + column * scale, y + row * scale, scale, scale, color)
					}
				}
			}
		}
		at += graphics.CELL_WIDTH * scale
	}
	return at
}

card :: proc "contextless" (canvas: graphics.Canvas, x, y, width, height: int, title, caption: string) -> graphics.Canvas {
	graphics.block(canvas, x, y, width, height, graphics.shade(graphics.COLOR_KERNEL, 28), graphics.shade(graphics.COLOR_KERNEL, 14))
	graphics.block(canvas, x + 1, y + 1, width - 2, height - 2, graphics.COLOR_CARD_TOP, graphics.COLOR_CARD_BOTTOM)
	graphics.block(canvas, x + CARD_INSIDE, y + 12, 4, 16, graphics.shade(graphics.COLOR_KERNEL, 130), graphics.COLOR_KERNEL)
	after := graphics.text(canvas, x + CARD_INSIDE + 12, y + 12, title, graphics.COLOR_KERNEL)
	graphics.text(canvas, after + 16, y + 12, caption, graphics.COLOR_DIM)
	return graphics.view(canvas, x + CARD_INSIDE, y + CARD_TITLE, width - 2 * CARD_INSIDE, height - CARD_TITLE - 8)
}

// The tiles of the strategies in the head: a click on one changes the strategy.
TILE_X :: 480
TILE_Y :: MARGIN + 44
TILE_WIDTH :: 152
TILE_HEIGHT :: 40

tile_at :: proc "contextless" (x, y: int) -> int {
	for index in 0 ..< STRATEGY_COUNT {
		left := TILE_X + index * (TILE_WIDTH + MARGIN)
		if x >= left && x < left + TILE_WIDTH && y >= TILE_Y && y < TILE_Y + TILE_HEIGHT {
			return index
		}
	}
	return -1
}

LABEL_WIDTH :: 224 // The names of the rows of the measures.
COLUMN_WIDTH :: 232
BAR_WIDTH :: COLUMN_WIDTH - 32
ROW :: 28
CHART :: 44 // A row of columns: the shares.
HEAD_HEIGHT :: 96
MEASURES_HEIGHT :: CARD_TITLE + 24 + 6 * ROW + 2 * CHART + 8

draw :: proc "contextless" (canvas: graphics.Canvas, report: op.System_Report, processors: u64) {
	graphics.clear(canvas, graphics.COLOR_BACKGROUND)
	for y := 0; y < HEIGHT; y += 24 {
		for x := 0; x < WIDTH; x += 24 {
			graphics.fill(canvas, x, y, 2, 2, graphics.COLOR_POINT)
		}
	}
	line: [96]u8

	// The head: the strategy in use.
	head := card(canvas, MARGIN, MARGIN, WIDTH - 2 * MARGIN, HEAD_HEIGHT, "SCHEDULER", "System_Report.strategy")
	in_use := -1
	for strategy, index in strategies {
		if strategy == report.strategy {
			in_use = index
		}
	}
	name := op.STRATEGY_NAMES[report.strategy]
	after := large(head, 0, 0, name, 2, in_use >= 0 ? strategy_color(in_use) : graphics.COLOR_DIM)
	graphics.text(head, after + 16, 0, "in use", graphics.COLOR_DIM)
	graphics.text(head, after + 16, 16, system.format(line[:], u64(report.strategy_changes), " changes since boot"), graphics.COLOR_DIM)
	graphics.text(canvas, TILE_X, MARGIN + 12, "Strategy_Set: a key 1 2 3, or a click", graphics.COLOR_DIM)
	for index in 0 ..< STRATEGY_COUNT {
		x := TILE_X + index * (TILE_WIDTH + MARGIN)
		color := strategy_color(index)
		if index == in_use {
			graphics.block(canvas, x, TILE_Y, TILE_WIDTH, TILE_HEIGHT, graphics.shade(color, 120), graphics.shade(color, 70))
			graphics.text(canvas, x + 12, TILE_Y + 12, system.format(line[:], u64(index + 1), "  ", op.STRATEGY_NAMES[strategies[index]]), graphics.COLOR_BACKGROUND)
		} else {
			graphics.fill(canvas, x, TILE_Y, TILE_WIDTH, TILE_HEIGHT, graphics.COLOR_TRACK)
			graphics.fill(canvas, x, TILE_Y + TILE_HEIGHT - 2, TILE_WIDTH, 2, color)
			graphics.text(canvas, x + 12, TILE_Y + 12, system.format(line[:], u64(index + 1), "  ", op.STRATEGY_NAMES[strategies[index]]), graphics.COLOR_TEXT)
		}
	}

	// The measures: one column for each strategy.
	top := MARGIN + HEAD_HEIGHT + MARGIN
	height := MEASURES_HEIGHT
	inside := card(canvas, MARGIN, top, WIDTH - 2 * MARGIN, height, "MEASURES", "the same cases under each strategy, in this run")
	for index in 0 ..< STRATEGY_COUNT {
		x := LABEL_WIDTH + index * COLUMN_WIDTH
		graphics.fill(inside, x, 0, 4, 16, strategy_color(index))
		graphics.text(inside, x + 12, 0, op.STRATEGY_NAMES[strategies[index]], strategy_color(index))
	}
	most_wakes, most_worst, most_work: u64 = 1, 1, 1
	for result in results {
		most_wakes = max(most_wakes, result.wakes)
		most_worst = max(most_worst, result.worst)
		most_work = max(most_work, result.work)
	}
	y := 24
	number_row :: proc "contextless" (canvas: graphics.Canvas, y: int, label: string, values: [STRATEGY_COUNT]u64, most: u64, unit: string) {
		graphics.text(canvas, 0, y, label, graphics.COLOR_DIM)
		line: [48]u8
		for index in 0 ..< STRATEGY_COUNT {
			x := LABEL_WIDTH + index * COLUMN_WIDTH
			if !results[index].measured {
				graphics.text(canvas, x, y, "not measured yet", graphics.COLOR_DIM)
				continue
			}
			graphics.text(canvas, x, y, system.format(line[:], values[index], unit), graphics.COLOR_TEXT)
			if most != 0 {
				bar(canvas, x, y + 18, BAR_WIDTH, 4, int(values[index] * BAR_WIDTH / most), strategy_color(index))
			}
		}
	}
	values :: proc "contextless" (field: proc "contextless" (result: ^Result) -> u64) -> (out: [STRATEGY_COUNT]u64) {
		for index in 0 ..< STRATEGY_COUNT {
			out[index] = field(&results[index])
		}
		return out
	}
	number_row(inside, y, "wakes in one second", values(proc "contextless" (result: ^Result) -> u64 {return result.wakes}), most_wakes, "")
	y += ROW
	number_row(inside, y, "late wake, middle", values(proc "contextless" (result: ^Result) -> u64 {return result.median}), most_worst, " us")
	y += ROW
	number_row(inside, y, "late wake, worst", values(proc "contextless" (result: ^Result) -> u64 {return result.worst}), most_worst, " us")
	y += ROW
	// The shares of the 8 spinners: one column each, the height is the share; the line is the equal part.
	graphics.text(inside, 0, y, "8 spinners, one weight", graphics.COLOR_DIM)
	graphics.text(inside, 0, y + 16, "share of each", graphics.COLOR_DIM)
	for index in 0 ..< STRATEGY_COUNT {
		x := LABEL_WIDTH + index * COLUMN_WIDTH
		if !results[index].measured {
			graphics.text(inside, x, y, "not measured yet", graphics.COLOR_DIM)
			continue
		}
		for share, spinner in results[index].shares {
			full := int(min(share, 250) * 36 / 250) // 25 %: the full height.
			graphics.fill(inside, x + spinner * 24, y, 16, 36, graphics.COLOR_TRACK)
			graphics.block(inside, x + spinner * 24, y + 36 - full, 16, full, graphics.shade(strategy_color(index), 125), graphics.shade(strategy_color(index), 78))
		}
		graphics.fill(inside, x, y + 36 - 125 * 36 / 250, 8 * 24 - 8, 1, graphics.COLOR_TEXT) // 12.5 %: the equal part.
	}
	y += CHART
	graphics.text(inside, 0, y, "12 spinners, weights 1 2 4", graphics.COLOR_DIM)
	graphics.text(inside, 0, y + 16, "share of one of each", graphics.COLOR_DIM)
	for index in 0 ..< STRATEGY_COUNT {
		x := LABEL_WIDTH + index * COLUMN_WIDTH
		if !results[index].measured {
			graphics.text(inside, x, y, "not measured yet", graphics.COLOR_DIM)
			continue
		}
		for class in 0 ..< 3 {
			share := results[index].weighted[class]
			full := int(min(share, 200) * 36 / 200) // 20 %: the full height.
			graphics.fill(inside, x + class * 48, y, 40, 36, graphics.COLOR_TRACK)
			graphics.block(inside, x + class * 48, y + 36 - full, 40, full, graphics.shade(strategy_color(index), 125), graphics.shade(strategy_color(index), 78))
			graphics.text(inside, x + class * 48 + 16, y + 20, class == 0 ? "1" : class == 1 ? "2" : "4", graphics.COLOR_BACKGROUND)
		}
		least := results[index].weighted_least
		graphics.text(inside, x + 152, y + 20, system.format(line[:], least / 10, ".", least % 10, " %"), graphics.COLOR_DIM)
		graphics.text(inside, x + 152, y + 4, "least", graphics.COLOR_DIM)
	}
	y += CHART
	number_row(inside, y, "work, millions in 1 s", values(proc "contextless" (result: ^Result) -> u64 {return result.work / 1_000_000}), most_work / 1_000_000, "")
	y += ROW
	number_row(inside, y, "turns ended by a wake", values(proc "contextless" (result: ^Result) -> u64 {return result.preemptions}), 0, "")
	y += ROW
	number_row(inside, y, "one pick", values(proc "contextless" (result: ^Result) -> u64 {return result.pick}), 0, " ns")
	for index in 0 ..< STRATEGY_COUNT {
		if results[index].measured && results[index].interrupt_preemption != 0 {
			graphics.text(inside, LABEL_WIDTH + index * COLUMN_WIDTH + 96, y, system.format(line[:], "preempt ", results[index].interrupt_preemption, " ns"), graphics.COLOR_DIM)
		}
	}

	// The processors: the strategy of each queue and its counts.
	top += height + MARGIN
	shown := min(processors, 4)
	processors_height := CARD_TITLE + 24 + int(shown) * 20 + 8
	rows := card(canvas, MARGIN, top, WIDTH - 2 * MARGIN, processors_height, "PROCESSORS", "Processor_Report: the run queue of each processor, since boot")
	headers := [6]string{"processor", "strategy", "queued", "picks", "preemptions", "moves"}
	for header, column in headers {
		graphics.text(rows, column * 152, 0, header, graphics.COLOR_DIM)
	}
	for index in 0 ..< shown {
		report_of := processor_report(index)
		row_y := 24 + int(index) * 20
		strategy_index := -1
		for strategy, at in strategies {
			if strategy == report_of.strategy {
				strategy_index = at
			}
		}
		graphics.text(rows, 0, row_y, system.format(line[:], index), graphics.COLOR_TEXT)
		graphics.text(rows, 152, row_y, op.STRATEGY_NAMES[report_of.strategy], strategy_index >= 0 ? strategy_color(strategy_index) : graphics.COLOR_DIM)
		graphics.text(rows, 2 * 152, row_y, system.format(line[:], u64(report_of.queued)), graphics.COLOR_TEXT)
		graphics.text(rows, 3 * 152, row_y, system.format(line[:], report_of.picks), graphics.COLOR_TEXT)
		graphics.text(rows, 4 * 152, row_y, system.format(line[:], report_of.preemptions), graphics.COLOR_TEXT)
		graphics.text(rows, 5 * 152, row_y, system.format(line[:], report_of.moves), graphics.COLOR_TEXT)
	}

	// The change under load, and the result.
	top += processors_height + MARGIN
	last := card(canvas, MARGIN, top, WIDTH - 2 * MARGIN, HEIGHT - top - MARGIN, "CHANGES WHILE THREADS RUN", "Strategy_Set, 100 times")
	if stress_done {
		text := system.format(line[:], stress_changes, " changes while ", stress_churned, " threads started and ended; one change ", change_least / 1000, " to ", change_worst / 1000, " us, middle ", change_middle / 1000, " us")
		graphics.text(last, 0, 0, text, stress_right ? graphics.COLOR_TEXT : graphics.COLOR_FAILED)
	} else {
		graphics.text(last, 0, 0, "not measured yet", graphics.COLOR_DIM)
	}
	status_y := 20
	switch {
	case !done:
		graphics.text(last, 0, status_y, "measures in progress", graphics.COLOR_BOOT_PROGRAM)
	case right:
		graphics.text(last, 0, status_y, "ok: no thread starved, each thread ran after the changes, a change needs the right Schedule", graphics.COLOR_PROGRAM)
	case:
		graphics.text(last, 0, status_y, system.format(line[:], "wrong: ", problem), graphics.COLOR_FAILED)
	}
}

choose :: proc "contextless" (index: int) {
	if index < 0 || index >= STRATEGY_COUNT {
		return
	}
	if before, status := system.strategy_set(machine, strategies[index]); status == .Ok && before != strategies[index] {
		system.log("scheduler: the strategy is now ", op.STRATEGY_NAMES[strategies[index]], ", it was ", op.STRATEGY_NAMES[before])
	}
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	window, ok := display.open(ctx, WIDTH, HEIGHT, "scheduler")
	if !ok {
		system.stop(1)
	}
	machine = ctx.handles[system.GRANT_MACHINE]
	canvas := window.canvas
	report := system_report()
	processors := report.processors
	draw(canvas, report, processors)
	display.present(&window)

	original := report.strategy
	refusals_right = refusals()
	if !refusals_right {
		fail("a change with no right Schedule, or a weight above 1024, was not refused")
	}
	for index in 0 ..< STRATEGY_COUNT {
		measure(index, processors)
		if results[index].measured {
			log_result(index)
		}
		draw(canvas, system_report(), processors)
		display.present(&window)
	}
	if lost_wakes != 0 {
		fail("a wake was lost")
	}
	if results[0].measured && results[2].measured && results[2].wakes <= results[0].wakes {
		fail("EEVDF did not wake more often than round robin")
	}
	stress()
	system.strategy_set(machine, original)
	done = true
	if right {
		system.log("scheduler: ok, no spinner starved under 3 strategies, EEVDF woke ", results[2].wakes / max(results[0].wakes, 1), " times as often as round robin, the weights ordered the shares, each thread ran after ", stress_changes, " changes, 0 wakes lost, a change needs the right Schedule")
	} else {
		system.log("scheduler: wrong: ", problem)
	}
	start := system.nanoseconds()
	draw(canvas, system_report(), processors)
	drawn := system.nanoseconds() - start
	display.present(&window)
	system.log("scheduler: the window took ", drawn / 1000, " us to draw")
	for {
		for event in display.next_event(&window) {
			switch {
			case event.kind == .Key && event.pressed && event.character >= '1' && event.character <= '3':
				choose(int(event.character - '1'))
			case event.kind == .Pointer && event.buttons & display.BUTTON_LEFT != 0:
				choose(tile_at(event.x, event.y))
			}
		}
		// The counts of the processors change: the window shows them each 500 ms.
		draw(canvas, system_report(), processors)
		display.present(&window)
		display.wait(&window, system.time() + 500)
	}
}
