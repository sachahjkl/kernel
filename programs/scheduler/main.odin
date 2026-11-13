// The scheduling strategies of the kernel, measured side by side
// (docs/SCHEDULING.md).
//
// The program runs four cases under each strategy: two threads that wake
// each other while spinners keep each processor busy; a thread that sleeps
// 2 ms, many times, while 8 spinners run, with the delay of each wake;
// 8 spinners of one weight, their shares and their work; 12 spinners with
// the weights 1, 2 and 4, their shares; 12 spinners that start with the
// full weight and get the weights 1, 2 and 4 while they run, their shares.
// Then it changes the strategy 100 times while threads start, stop, wake
// each other and move, and while a thread writes the schedule of the
// spinners. The window
// shows the numbers and the strategy in use; the keys 1, 2 and 3, or a
// click on a strategy, change it.
//
// The program checks what does not depend on the load of the host: no
// spinner starved, a wake ended turns under EEVDF and none under round
// robin (the counts of the kernel; the wakes in one second are measures),
// the weights order the shares under the strategies with weights, each
// thread runs after the changes, no wake was lost, the kernel refuses a
// change with no right Schedule and a weight above the full weight. For the
// schedule of a live thread (docs/SCHEDULING.md, "The schedule of a live
// thread"): a thread reads and writes its own schedule, the weights written
// through the machine handle order the shares, the kernel refuses each
// write that it must refuse, and writes during the changes of strategy
// lose no thread; the schedule of a thread of another program is read and
// written through the machine handle; a weight limit that the machine
// handle wrote holds against the writes of the thread and against its new
// threads; a write of the program never raises a weight or a request; the
// lag that the kernel reports for a held thread stays the same after a
// write of the program, and is 0 after a raise through the machine
// handle.
//
// The program needs the machine with the rights Inspect and Schedule.
//
// **What it is for.** The kernel has three scheduling strategies (round
// robin, fair, EEVDF) and changes from one to another at run time. This
// program shows what each one gives on the same load, and checks what each
// one must keep, whatever the speed of the host.
//
// **Start**: `start("scheduler")` in the console, or the bar of the
// desktop. Its budget has room for 24 threads: 12 spinners, two threads
// that wake each other, one that sleeps, a changer, a thread that writes
// schedules, and a thread that starts threads.
//
// **Grants**, as the root service gives them:
//
// - **Inspect**: the machine with the right Inspect, for the counts of the
//   scheduler in the system report.
// - **Schedule**: the right to change the strategy of the whole machine,
//   and the weight and the request of any thread. A change touches every
//   program, so this right is rare.
//
// **What a reader sees**: one tile for each strategy with its numbers, and
// the strategy in use. The log has one line of results for each strategy,
// then "scheduler: ok, no spinner starved under 3 strategies, ..." or
// "scheduler: wrong: ..." with the first problem, and the time to draw the
// window. At the end the program sets the strategy that was in use at its
// start.
//
// **What it does not prove**: the wakes in one second and the shares are
// measures of this host, printed and not checked.
package scheduler

import "base:intrinsics"
import "contract:errors"
import "support:display"
import "support:graphics"
import "support:interface"
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
// A wait that ends at this deadline after its word changed lost its wake. A
// wake that is only late on a loaded host comes long before it: the bound of
// a hang.
LOST_WAIT :: system.TEST_HANG_BOUND_MILLISECONDS
EQUAL_COUNT :: 8
WEIGHTED_COUNT :: 12
@(rodata)
weights := [3]u64{256, 512, 1024} // 1 : 2 : 4.
CHANGES :: 100
SPINNER_LIMIT :: 16

// One spinner: its count of work, alone in its cache line.
Spinner :: struct #align (64) {
	count:  u64,
	stop:   u32,
	number: u32, // 1 + the number of its thread in the program: the spinner writes it when it starts. 0: not yet.
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
	// The same for 12 spinners that started with the full weight and got
	// their weights through the machine handle while they ran.
	written:         [3]u64,
	written_ordered: bool, // The heavier weight got more.
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
	intrinsics.atomic_store(&spinner.number, u32(system.thread_record().number) + 1)
	system.word_wake(&spinner.number)
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

// The threads of this program as the kernel reports them: the machine
// number of each one is its name for the machine handle.
self_slot, self_serial: u64
self_machine_number: u64 // The machine number of the first thread of this program.
thread_table: op.Thread_Table_Report

program_report :: proc "contextless" (slot: u64) -> (report: op.Program_Report, status: system.Status) {
	_, status = system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.Program), slot, u64(uintptr(&report)), size_of(report))
	return report, status
}

// threads_of reads the thread report of a program slot into thread_table.
// true: the report is of the program with this serial.
threads_of :: proc "contextless" (slot, serial: u64) -> bool {
	_, status := system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.Threads), slot, u64(uintptr(&thread_table)), size_of(thread_table))
	return status == .Ok && thread_table.program_serial == serial
}

// machine_number_is_this_thread says if a machine number names the calling
// thread. A name of a program does not say it: two programs can have one
// name. The thread lowers its request by one microsecond by its own
// number, which names a thread of this program only, and reads the new
// value by the machine number: two times. A write of a program only
// lowers a request, so each try costs two microseconds of the request;
// for its own thread the machine handle then writes the schedule of the
// start back.
machine_number_is_this_thread :: proc "contextless" (candidate: u64) -> bool {
	number := system.thread_record().number
	start, start_status := system.thread_schedule_read(0, number)
	own := start_status == .Ok && start.request > 2
	for round in u32(1) ..= 2 {
		if !own {
			break
		}
		own = system.thread_schedule_write(0, number, {request = start.request - round}) == .Ok
		schedule, status := system.thread_schedule_read(machine, candidate)
		own &&= status == .Ok && schedule.request == start.request - round
	}
	if own {
		// The weight is the same: no raise, the thread keeps its place.
		own = system.thread_schedule_write(machine, candidate, start) == .Ok
	}
	return own
}

// find_self finds the slot and the serial of this program, and the machine
// number of its first thread, which runs this code. A slot is a candidate
// by its name; it is this program only when the thread of the calling
// number in its report is the calling thread. false: not found.
find_self :: proc "contextless" () -> bool {
	number := u32(system.thread_record().number)
	for index in u64(1) ..< 64 {
		report, status := program_report(index)
		if status != .Ok || system.name_of(report.name[:]) != "scheduler" || report.state == .Stopped || report.state == .None {
			continue
		}
		if !threads_of(index, report.program_serial) {
			continue
		}
		candidate: u64
		for &item in thread_table.threads[:min(thread_table.count, op.THREAD_REPORT_CAPACITY)] {
			if item.number == number && item.state != .Stopped {
				candidate = item.machine_number
			}
		}
		if candidate != 0 && machine_number_is_this_thread(candidate) {
			self_slot, self_serial, self_machine_number = index, report.program_serial, candidate
			return true
		}
	}
	return false
}

// spinner_machine_numbers gives the machine number of each of count
// spinners from first. It waits until each spinner wrote the number of its
// thread (the time only ends a hang), then reads the thread report of this
// program. false: a spinner did not start, or the report does not name it.
spinner_machine_numbers :: proc "contextless" (first, count: int, numbers: ^[SPINNER_LIMIT]u64) -> bool {
	deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS
	for index in first ..< first + count {
		for intrinsics.atomic_load(&spinners[index].number) == 0 {
			if system.time() >= deadline {
				return false
			}
			system.word_wait(&spinners[index].number, 0, deadline)
		}
	}
	if self_slot == 0 || !threads_of(self_slot, self_serial) {
		return false
	}
	for index in first ..< first + count {
		numbers[index] = 0
		for &item in thread_table.threads[:min(thread_table.count, op.THREAD_REPORT_CAPACITY)] {
			if item.number + 1 == intrinsics.atomic_load(&spinners[index].number) && item.state != .Stopped {
				numbers[index] = item.machine_number
			}
		}
		if numbers[index] == 0 {
			return false
		}
	}
	return true
}

// weighted_shares measures the 12 spinners that run now, in three classes
// (the spinner n is of the class n modulo 3): the mean share of a spinner
// of each class and the least share of the 12, in tenths of a percent; if
// the class of the heaviest weight did more work than the class of the
// lightest; if a spinner starved (it has a sixteenth of its equal part or
// less). The shares are a measure of this host.
weighted_shares :: proc "contextless" () -> (shares: [3]u64, least: u64, heavier_got_more: bool, starved: bool) {
	system.sleep(system.time() + WARM_TIME)
	first := spinner_counts(0, WEIGHTED_COUNT)
	system.sleep(system.time() + SHARE_TIME)
	last := spinner_counts(0, WEIGHTED_COUNT)
	total: u64
	for spinner in 0 ..< WEIGHTED_COUNT {
		total += last[spinner] - first[spinner]
	}
	class_sum: [3]u64
	least = 1000
	for spinner in 0 ..< WEIGHTED_COUNT {
		part := last[spinner] - first[spinner]
		class_sum[spinner % 3] += part
		least = min(least, share_tenths(part, total))
		if part * 16 * WEIGHTED_COUNT <= total {
			starved = true
		}
	}
	for class in 0 ..< 3 {
		shares[class] = share_tenths(class_sum[class], total * (WEIGHTED_COUNT / 3))
	}
	return shares, least, class_sum[2] > class_sum[0], starved
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
		// A side that did not start has no handle: a wait for the handle 0
		// would end the calling thread.
		if thread.handle != 0 {
			system.thread_wait(thread)
		}
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
		pair_stop()
		spinners_stop(0, int(processors))
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
		spinners_stop(0, EQUAL_COUNT)
		fail("a thread did not start")
		return
	}
	system.sleep(system.time() + WARM_TIME)
	sleeper = {}
	sleeping, status := system.thread_start(sleep_run, nil, request = 500)
	if status != .Ok {
		spinners_stop(0, EQUAL_COUNT)
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
		spinners_stop(0, WEIGHTED_COUNT)
		fail("a thread did not start")
		return
	}
	heavier_got_more, starved: bool
	result.weighted, result.weighted_least, heavier_got_more, starved = weighted_shares()
	spinners_stop(0, WEIGHTED_COUNT)
	if starved {
		fail("a spinner with a weight starved")
	}
	if strategies[index] != .Round_Robin && !heavier_got_more {
		fail("the weights did not order the shares")
	}

	// 5. 12 spinners that start with the full weight. While they run, the
	// program writes the weights 1, 2 and 4 through the machine handle, and
	// reads each one back. The condition is the one of the case 4.
	if !spinners_start(0, WEIGHTED_COUNT, full_weight) {
		spinners_stop(0, WEIGHTED_COUNT)
		fail("a thread did not start")
		return
	}
	numbers: [SPINNER_LIMIT]u64
	weights_written := spinner_machine_numbers(0, WEIGHTED_COUNT, &numbers)
	for spinner in 0 ..< WEIGHTED_COUNT {
		if !weights_written {
			break
		}
		weight := u32(weights[spinner % 3])
		weights_written = system.thread_schedule_write(machine, numbers[spinner], {weight = weight}) == .Ok
		if schedule, read_status := system.thread_schedule_read(machine, numbers[spinner]); read_status != .Ok || schedule.weight != weight || schedule.request != op.REQUEST_DEFAULT {
			weights_written = false
		}
	}
	if !weights_written {
		spinners_stop(0, WEIGHTED_COUNT)
		fail("a weight was not written through the machine handle")
		return
	}
	result.written, _, result.written_ordered, starved = weighted_shares()
	spinners_stop(0, WEIGHTED_COUNT)
	if starved {
		fail("a spinner with a written weight starved")
	}
	if strategies[index] != .Round_Robin && !result.written_ordered {
		fail("the written weights did not order the shares")
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
	log_whole(system.written(&writer))
}

// log_whole writes one text on the log in one Log call: a text can be
// longer than the buffer of system.log (512 bytes).
log_whole :: proc "contextless" (text: string) {
	system.call(.Log, u64(system.context_record().handles[op.CONTEXT_LOG]), u64(uintptr(raw_data(text))), u64(len(text)), u64(op.Log_Level.Info), 0, 0)
}

// log_written writes the two lines of the weights written through the
// machine handle: the shares under each strategy, which are a measure of
// this host; then if the heavier weight got more under the two strategies
// that use weights.
log_written :: proc "contextless" () {
	buffer: [800]u8
	writer := system.Writer{buffer = buffer[:]}
	system.write_part(&writer, "scheduler: 12 spinners that started with the full weight, the weights 1 2 4 written through the machine handle while they ran: a spinner of each weight")
	for index in 0 ..< STRATEGY_COUNT {
		system.write_part(&writer, index == 0 ? " " : "; ")
		tenths_part(&writer, results[index].written[0])
		system.write_part(&writer, ", ")
		tenths_part(&writer, results[index].written[1])
		system.write_part(&writer, ", ")
		tenths_part(&writer, results[index].written[2])
		system.write_part(&writer, " under ")
		system.write_part(&writer, op.STRATEGY_NAMES[strategies[index]])
	}
	log_whole(system.written(&writer))
	ordered := results[1].measured && results[2].measured && results[1].written_ordered && results[2].written_ordered
	system.log("scheduler: the weights 1 2 4 written through the machine handle while 12 spinners ran: each write was read back, and the heavier weight got more under fair and EEVDF", ordered ? string(": as it must") : string(": WRONG"))
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

// The thread that writes the schedule of the 8 spinners of the stress case
// through the machine handle, while the strategy changes.
Schedule_Writer :: struct {
	numbers: [SPINNER_LIMIT]u64, // The machine numbers of the spinners.
	writes:  u64,
	refused: u64,
}

schedule_writer: Schedule_Writer

schedule_write_run :: proc "c" (parameter: rawptr) -> ! {
	for round := 0; intrinsics.atomic_load(&changer.ended) == 0; round += 1 {
		for spinner in 0 ..< EQUAL_COUNT {
			schedule := op.Thread_Schedule {
				weight  = u32(weights[(spinner + round) % 3]),
				request = u32(500 + (round % 4) * 1000),
			}
			if system.thread_schedule_write(machine, schedule_writer.numbers[spinner], schedule) == .Ok {
				schedule_writer.writes += 1
			} else {
				schedule_writer.refused += 1
			}
		}
		// A pause, so that the writes fall at many moments of the changes.
		system.sleep(system.time() + 1)
	}
	system.thread_stop()
}

stress :: proc "contextless" () {
	at_start, _ := system.budget_read()
	if !spinners_start(0, EQUAL_COUNT, weight_of_class) || !pair_start() {
		pair_stop()
		spinners_stop(0, EQUAL_COUNT)
		fail("a thread did not start")
		return
	}
	schedule_writer = {}
	if !spinner_machine_numbers(0, EQUAL_COUNT, &schedule_writer.numbers) {
		pair_stop()
		spinners_stop(0, EQUAL_COUNT)
		fail("the thread report did not name a spinner")
		return
	}
	changer = {}
	thread, status := system.thread_start(change_run, nil)
	if status != .Ok {
		pair_stop()
		spinners_stop(0, EQUAL_COUNT)
		fail("a thread did not start")
		return
	}
	writing, writing_status := system.thread_start(schedule_write_run, nil)
	if writing_status != .Ok {
		// The changer ends by itself after its changes.
		system.thread_wait(thread)
		pair_stop()
		spinners_stop(0, EQUAL_COUNT)
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
	system.thread_wait(writing)
	// The schedule written last is the schedule of each spinner.
	last_schedule := op.Thread_Schedule{weight = 512, request = 2000, weight_limit = op.WEIGHT_FULL}
	schedules_right := schedule_writer.writes != 0 && schedule_writer.refused == 0
	for spinner in 0 ..< EQUAL_COUNT {
		write_status := system.thread_schedule_write(machine, schedule_writer.numbers[spinner], last_schedule)
		schedule, read_status := system.thread_schedule_read(machine, schedule_writer.numbers[spinner])
		schedules_right &&= write_status == .Ok && read_status == .Ok && schedule == last_schedule
	}
	// After the last change, each thread still runs: the wait is for each
	// count to grow, and the bound only ends a hang.
	first := spinner_counts(0, EQUAL_COUNT)
	rounds := intrinsics.atomic_load(&pair.rounds[0])
	ran := false
	for deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS; !ran && system.time() < deadline; {
		system.sleep(system.time() + 10)
		last := spinner_counts(0, EQUAL_COUNT)
		ran = intrinsics.atomic_load(&pair.rounds[0]) > rounds
		for spinner in 0 ..< EQUAL_COUNT {
			ran &&= last[spinner] > first[spinner]
		}
	}
	stress_wakes = pair.rounds[0]
	pair_stop()
	spinners_stop(0, EQUAL_COUNT)
	// The slots of the threads returned to the budget.
	after: system.Budget_Amounts
	for deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS; system.time() < deadline; {
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
	stress_right = ran && schedules_right && changer.changes == CHANGES && changer.refused == 0 && after.threads == at_start.threads
	if !stress_right {
		fail("the stress case")
	}
	stress_done = true
	system.log("scheduler: one Strategy_Set, with its kernel entry: ", change_least, " ns at least, ", change_middle, " ns in the middle, ", change_worst, " ns at worst")
	system.log("scheduler: stress: ", changer.changes, " changes of strategy while ", stress_churned, " threads started and stopped, two threads woke each other ", stress_wakes, " times and 8 spinners ran and moved; after the last change each thread ran: ", u64(ran), "; thread slots ", after.threads, " of ", at_start.threads, "; ", schedule_writer.writes, " writes of a schedule through the machine handle, ", schedule_writer.refused, " refused")
	system.log("scheduler: writes of a schedule through the machine handle while the strategy changed 100 times: none was refused, each of the 8 spinners ran after them and has the schedule written last", ran && schedules_right && changer.changes == CHANGES ? string(": as it must") : string(": WRONG"))
}

// The thread that reads and writes its own schedule, by its number.
OWN_WEIGHT :: 300
OWN_REQUEST :: 700

Own_Schedule :: struct {
	created: op.Thread_Schedule, // What the thread read first: the values of its creation.
	written: op.Thread_Schedule, // What it read after it wrote half the weight and the request 0.
	last:    op.Thread_Schedule, // What it read after the two refused writes.
	weight_raise, request_raise: system.Status, // Its writes of the weight and of the request of its creation.
	statuses_right: bool,
}

own_schedule: Own_Schedule

own_schedule_run :: proc "c" (parameter: rawptr) -> ! {
	number := system.thread_record().number
	read_status, write_status, again_status, last_status: system.Status
	own_schedule.created, read_status = system.thread_schedule_read(0, number)
	// The request 0 keeps the request of the thread.
	write_status = system.thread_schedule_write(0, number, {weight = OWN_WEIGHT / 2, request = OWN_REQUEST / 2})
	own_schedule.written, again_status = system.thread_schedule_read(0, number)
	// A program only lowers: the values of the creation are refused now.
	own_schedule.weight_raise = system.thread_schedule_write(0, number, {weight = OWN_WEIGHT})
	own_schedule.request_raise = system.thread_schedule_write(0, number, {request = OWN_REQUEST})
	own_schedule.last, last_status = system.thread_schedule_read(0, number)
	own_schedule.statuses_right = read_status == .Ok && write_status == .Ok && again_status == .Ok && last_status == .Ok
	system.thread_stop()
}

// own_schedules: a thread reads the schedule of its creation, lowers its
// weight and its request and reads them; its writes of the values of its
// creation are refused and change nothing; the first thread of the
// program reads the defaults.
own_schedules :: proc "contextless" () -> bool {
	own_schedule = {}
	thread, status := system.thread_start(own_schedule_run, nil, weight = OWN_WEIGHT, request = OWN_REQUEST)
	if status != .Ok {
		return false
	}
	system.thread_wait(thread)
	first, first_status := system.thread_schedule_read(0, system.thread_record().number)
	lowered := op.Thread_Schedule{weight = OWN_WEIGHT / 2, request = OWN_REQUEST / 2, weight_limit = op.WEIGHT_FULL}
	as_it_must := own_schedule.statuses_right && first_status == .Ok
	as_it_must &&= own_schedule.created == op.Thread_Schedule{weight = OWN_WEIGHT, request = OWN_REQUEST, weight_limit = op.WEIGHT_FULL}
	as_it_must &&= own_schedule.written == lowered && own_schedule.last == lowered
	as_it_must &&= own_schedule.weight_raise == .Bad_Operation && own_schedule.request_raise == .Bad_Operation
	as_it_must &&= first == op.Thread_Schedule{weight = op.WEIGHT_FULL, request = op.REQUEST_DEFAULT, weight_limit = op.WEIGHT_FULL}
	system.log("scheduler: a thread created with the weight ", u64(OWN_WEIGHT), " and the request ", u64(OWN_REQUEST), " us read its own schedule: weight ", u64(own_schedule.created.weight), ", request ", u64(own_schedule.created.request), " us; after it lowered them to ", u64(OWN_WEIGHT / 2), " and ", u64(OWN_REQUEST / 2), " us: weight ", u64(own_schedule.written.weight), ", request ", u64(own_schedule.written.request), " us; its own writes of the weight ", u64(OWN_WEIGHT), " and of the request ", u64(OWN_REQUEST), " us: ", op.STATUS_NAMES[own_schedule.weight_raise], " and ", op.STATUS_NAMES[own_schedule.request_raise], ", and the schedule stayed: ", u64(own_schedule.last == lowered), "; the first thread: weight ", u64(first.weight), ", request ", u64(first.request), as_it_must ? string(" us: as it must") : string(" us: WRONG"))
	return as_it_must
}

// schedule_refusals: each write of a schedule that the kernel must refuse,
// on one spinner that runs. The statuses are in the line of the log.
schedule_refusals :: proc "contextless" () -> bool {
	if !spinners_start(0, 1, full_weight) {
		return false
	}
	numbers: [SPINNER_LIMIT]u64
	if !spinner_machine_numbers(0, 1, &numbers) {
		spinners_stop(0, 1)
		return false
	}
	spinner := spinner_threads[0].handle
	too_heavy := system.thread_schedule_write(spinner, 0, {weight = op.WEIGHT_FULL + 1})
	too_long := system.thread_schedule_write(spinner, 0, {request = op.REQUEST_LIMIT + 1})
	// A refused write changed nothing.
	kept, kept_status := system.thread_schedule_read(spinner, 0)
	unchanged := kept_status == .Ok && kept == op.Thread_Schedule{weight = op.WEIGHT_FULL, request = op.REQUEST_DEFAULT, weight_limit = op.WEIGHT_FULL}
	// The machine with no right Schedule; the machine with Schedule and no
	// Inspect, which names no thread; a thread handle with Inspect and no
	// Control, which reads and does not write.
	no_schedule, no_inspect, no_control := system.Status.Ok, system.Status.Ok, system.Status.Ok
	reads := false
	if copy, status := system.give(0, machine, {.Inspect}); status == .Ok {
		no_schedule = system.thread_schedule_write(copy, numbers[0], {weight = 1})
		system.close(copy)
	}
	blind_write := system.Status.Ok
	if copy, status := system.give(0, machine, {.Schedule}); status == .Ok {
		_, no_inspect = system.thread_schedule_read(copy, numbers[0])
		blind_write = system.thread_schedule_write(copy, numbers[0], {weight = 1})
		system.close(copy)
	}
	if copy, status := system.give(0, spinner, {.Inspect}); status == .Ok {
		no_control = system.thread_schedule_write(copy, 0, {weight = 1})
		_, read_status := system.thread_schedule_read(copy, 0)
		reads = read_status == .Ok
		system.close(copy)
	}
	// The machine handle names a thread for the schedule only.
	_, other_command := system.call(.Thread_Control, u64(machine), numbers[0], u64(op.Thread_Control_Command.Stop))
	// The spinner ends: its machine number names no thread.
	spinners_stop(0, 1)
	ended := system.thread_schedule_write(machine, numbers[0], {weight = 1})
	as_it_must := too_heavy == .Bad_Operation && too_long == .Bad_Operation && unchanged && no_schedule == .No_Right && no_inspect == .No_Right && blind_write == .No_Right && no_control == .No_Right && reads && other_command == .Bad_Handle && ended == .Bad_State
	system.log("scheduler: refused writes of a schedule: a weight above the full weight ", op.STATUS_NAMES[too_heavy], ", a request above the limit ", op.STATUS_NAMES[too_long], ", and the schedule stayed: ", u64(unchanged), "; the machine handle with no right Schedule ", op.STATUS_NAMES[no_schedule], "; a read and a write through the machine handle with Schedule and no Inspect ", op.STATUS_NAMES[no_inspect], " and ", op.STATUS_NAMES[blind_write], "; a thread handle with Inspect and no Control ", op.STATUS_NAMES[no_control], ", and it reads: ", u64(reads), "; another command with the machine handle ", op.STATUS_NAMES[other_command], "; the machine number of a thread that ended ", op.STATUS_NAMES[ended], as_it_must ? string(": as it must") : string(": WRONG"))
	return as_it_must
}

// other_program_schedule reads and writes the schedule of a thread of
// another program through the machine handle: the root service, which
// lives as long as the machine. Its slot is found by its name, and it is
// not this program by its serial; the thread report and a second program
// report have the same serial, so each read is of one program. The write
// changes the request by one microsecond, and the last write gives the
// schedule that the thread had.
other_program_schedule :: proc "contextless" () -> bool {
	slot, serial: u64
	for index in u64(1) ..< 64 {
		report, status := program_report(index)
		if status == .Ok && system.name_of(report.name[:]) == "root" && report.state != .Stopped && report.state != .None && report.program_serial != self_serial {
			slot, serial = index, report.program_serial
			break
		}
	}
	number: u64
	if slot != 0 && threads_of(slot, serial) {
		for &item in thread_table.threads[:min(thread_table.count, op.THREAD_REPORT_CAPACITY)] {
			if item.state != .Stopped && number == 0 {
				number = item.machine_number
			}
		}
	}
	as_it_must := false
	if number != 0 {
		before, before_status := system.thread_schedule_read(machine, number)
		changed := before
		changed.request = before.request == 2999 ? 2998 : 2999
		write_status := before_status == .Ok ? system.thread_schedule_write(machine, number, changed) : system.Status.Bad_State
		after, after_status := system.thread_schedule_read(machine, number)
		restore_status := before_status == .Ok ? system.thread_schedule_write(machine, number, before) : system.Status.Bad_State
		restored, restored_status := system.thread_schedule_read(machine, number)
		again, again_status := program_report(slot)
		as_it_must = before_status == .Ok && write_status == .Ok && after_status == .Ok && restore_status == .Ok && restored_status == .Ok
		as_it_must &&= after == changed && restored == before
		as_it_must &&= again_status == .Ok && again.program_serial == serial
	}
	system.log("scheduler: a thread of another program, the root service, found by its name and its serial: through the machine handle its schedule was read, written, read back and written back", as_it_must ? string(": as it must") : string(": WRONG"))
	return as_it_must
}

// The weight limit (docs/SCHEDULING.md, "The schedule of a live thread"). The first
// thread of the program gets a limit through the machine handle, tries to
// leave it by its own writes and by new threads, and gets the full limit
// back at the end, on each path.
WEIGHT_LIMIT_OF_THE_CASE :: 256
LIMIT_ROUNDS :: 1000

// A thread that the limited thread created: what it read of its own
// schedule, and the status of its own write of the full weight.
Limited_Child :: struct {
	schedule: op.Thread_Schedule,
	read:     system.Status,
	raise:    system.Status,
}

limited_child: Limited_Child

limited_child_run :: proc "c" (parameter: rawptr) -> ! {
	number := system.thread_record().number
	limited_child.schedule, limited_child.read = system.thread_schedule_read(0, number)
	limited_child.raise = system.thread_schedule_write(0, number, {weight = op.WEIGHT_FULL})
	system.thread_stop()
}

// weight_limits: the conditions are statuses and values that the kernel
// gives, with no time in them: under a limit, no write of the thread and
// no new thread has a weight above the limit, a write of the thread never
// raises its weight, and only the machine handle raises a weight or a
// limit.
weight_limits :: proc "contextless" () -> bool {
	LIMIT :: WEIGHT_LIMIT_OF_THE_CASE
	number := system.thread_record().number
	limited := op.Thread_Schedule{weight = LIMIT, request = op.REQUEST_DEFAULT, weight_limit = LIMIT}
	lowered := system.thread_schedule_write(machine, self_machine_number, {weight_limit = LIMIT})
	now, now_status := system.thread_schedule_read(0, number)
	error: errors.Error_Record
	raise := system.thread_schedule_write(0, number, {weight = op.WEIGHT_FULL}, &error)
	record_right := error.kind == i64(errors.Kind.Bad_Value) && error.value == op.WEIGHT_FULL && error.limit == LIMIT && error.found == i64(op.Thread_Write_Refusal.Weight)
	// The limit of the record of an own write is not read: the thread
	// keeps its limit, and the weight 0 is the limit.
	ignored := system.thread_schedule_write(0, number, {weight_limit = op.WEIGHT_FULL})
	kept, kept_status := system.thread_schedule_read(0, number)
	first_right := lowered == .Ok && now_status == .Ok && now == limited && raise == .Bad_Operation && record_right && ignored == .Ok && kept_status == .Ok && kept == limited
	// The same weight again and a lower one are accepted. The full weight
	// and the weight of the limit are refused then: a program only lowers.
	// Only the machine handle gives the weight of the limit back.
	accepted, refused, machine_raises, above: u64
	for _ in 0 ..< LIMIT_ROUNDS {
		accepted += u64(system.thread_schedule_write(0, number, {weight = LIMIT}) == .Ok)
		accepted += u64(system.thread_schedule_write(0, number, {weight = 1}) == .Ok)
		refused += u64(system.thread_schedule_write(0, number, {weight = op.WEIGHT_FULL}) == .Bad_Operation)
		refused += u64(system.thread_schedule_write(0, number, {weight = LIMIT}) == .Bad_Operation)
		// The refused writes changed nothing: the weight is still 1.
		after_refusal, after_status := system.thread_schedule_read(0, number)
		machine_raises += u64(system.thread_schedule_write(machine, self_machine_number, {weight_limit = LIMIT}) == .Ok)
		last, last_status := system.thread_schedule_read(0, number)
		if after_status != .Ok || after_refusal.weight != 1 || after_refusal.weight_limit != LIMIT || last_status != .Ok || last != limited {
			above += 1
		}
	}
	rounds_right := accepted == 2 * LIMIT_ROUNDS && refused == 2 * LIMIT_ROUNDS && machine_raises == LIMIT_ROUNDS && above == 0
	system.log("scheduler: the weight limit ", u64(LIMIT), " written through the machine handle: the thread has the weight ", u64(now.weight), "; its own write of the full weight ", op.STATUS_NAMES[raise], ", the error record has the weight of the thread: ", u64(record_right), "; its own write of the full limit changed nothing: ", u64(kept == limited), "; ", u64(LIMIT_ROUNDS), " rounds of its own writes of the weights ", u64(LIMIT), ", 1, 1024 and ", u64(LIMIT), ", then the weight ", u64(LIMIT), " through the machine handle: ", accepted, " of its own accepted, ", refused, " refused, ", machine_raises, " raised by the machine handle, a wrong weight or limit ", above, " times", first_right && rounds_right ? string(": as it must") : string(": WRONG"))

	// A new thread: a weight above the limit is refused; with the weight
	// 0 it has the limit as its weight and as its limit.
	limited_child = {read = .Bad_State, raise = .Ok}
	_, too_heavy := system.thread_start(brief, nil, weight = LIMIT + 1)
	child, child_status := system.thread_start(limited_child_run, nil)
	if child_status == .Ok {
		system.thread_wait(child)
	}
	child_right := too_heavy == .Bad_Operation && child_status == .Ok && limited_child.read == .Ok && limited_child.schedule == limited && limited_child.raise == .Bad_Operation
	// The machine handle gives the full limit back, on each path.
	full := op.Thread_Schedule{weight = op.WEIGHT_FULL, request = op.REQUEST_DEFAULT, weight_limit = op.WEIGHT_FULL}
	raised := system.thread_schedule_write(machine, self_machine_number, {})
	restored, restored_status := system.thread_schedule_read(0, number)
	restored_right := raised == .Ok && restored_status == .Ok && restored == full
	system.log("scheduler: under the weight limit ", u64(LIMIT), ": a new thread with the weight ", u64(LIMIT + 1), " ", op.STATUS_NAMES[too_heavy], "; a new thread with the weight 0 has the weight ", u64(limited_child.schedule.weight), " and the limit ", u64(limited_child.schedule.weight_limit), ", and its own write of the full weight ", op.STATUS_NAMES[limited_child.raise], "; after the machine handle wrote the full limit the first thread has the weight ", u64(restored.weight), child_right && restored_right ? string(": as it must") : string(": WRONG"))
	return first_right && rounds_right && child_right && restored_right
}

// The place of a held thread, on what the kernel reports
// (docs/SCHEDULING.md, "The schedule of a live thread"). The thread report
// gives the lag that EEVDF keeps for a thread that is held
// (`Thread_Report.lag`): below 0 the thread owes time, above 0 it is owed
// time. A write of the program lowers or is refused, and leaves that
// number as it is. A raise through the machine handle makes it 0: the
// thread starts again as a new thread. The conditions compare numbers of
// the kernel: no time and no share is in them.
OWING_ROUNDS :: 100

// What the rounds saw: the last three values are measures.
Owing_Result :: struct {
	rounds:    u64, // The rounds that ran.
	changed:   u64, // Writes of the program after which the reported lag was another number.
	raised:    u64, // Raises of the program that the kernel did not refuse.
	not_new:   u64, // Raises through the machine handle after which the lag was not 0.
	owing:     u64, // Rounds where the held thread owed time.
	owed:      u64, // Rounds where it was owed time.
	largest:   u64, // The most that it owed, in weighted cycles.
}

// thread_item gives the record of a thread of this program in a new
// thread report, or nil.
thread_item :: proc "contextless" (number: u32) -> ^op.Thread_Report {
	if self_slot == 0 || !threads_of(self_slot, self_serial) {
		return nil
	}
	for &item in thread_table.threads[:min(thread_table.count, op.THREAD_REPORT_CAPACITY)] {
		if item.number == number && item.state != .Stopped {
			return &item
		}
	}
	return nil
}

// held_lag gives the lag that the kernel reports for a thread of this
// program that a stop holds. false: the report does not show it held.
held_lag :: proc "contextless" (number: u32) -> (lag: i64, held: bool) {
	item := thread_item(number)
	if item == nil {
		return 0, false
	}
	return item.lag, item.processor == 0 && item.queued == 0
}

// spinner_with_company gives a spinner that runs on a processor whose
// queue holds another spinner, from the thread report: a Stop of it finds
// other threads in its queue, so its lag is taken against them. With none
// it gives the first spinner; the choice is a help, not a condition.
spinner_with_company :: proc "contextless" (count: int) -> int {
	if self_slot == 0 || !threads_of(self_slot, self_serial) {
		return 0
	}
	items := thread_table.threads[:min(thread_table.count, op.THREAD_REPORT_CAPACITY)]
	for index in 0 ..< count {
		number := intrinsics.atomic_load(&spinners[index].number) - 1
		for &item in items {
			if item.number != number || item.processor == 0 {
				continue
			}
			for &other in items {
				if other.number != number && other.queued == 1 && other.home == item.processor - 1 {
					return index
				}
			}
		}
	}
	return 0
}

// owing_kept: one spinner more than the processors, so that a queue has
// two threads. In each round a spinner lowers to the weight 1 through its
// thread handle while it runs or is in a list. The round waits until the
// kernel counted a tick of run for it after that write: the tick is
// charged at the weight 1, so the spinner then owes about one second of
// virtual time to the other threads of its queue. Then a Stop holds it.
// In the hold: a write of the full weight through the thread handle is
// refused, a write of the request 1 us is accepted, and the lag is the
// same number after each; the machine handle writes the full weight, and
// the lag is 0. Then a Resume.
//
// A round where the held spinner has the lag 0 checks nothing: it was
// alone in its queue at the Stop. So the rounds go on after the first
// OWING_ROUNDS until the kernel reported the held spinner with a lag below
// 0 at least one time: a state of the kernel, not a speed. The hang bound
// ends the rounds if that state never comes, and the case then fails and
// says so. With as many processors as the program has spinners, or more,
// each spinner can be alone in its queue for ever: the case says so and
// checks nothing.
owing_kept :: proc "contextless" (processors: u64) -> bool {
	if processors >= SPINNER_LIMIT {
		system.log("scheduler: the lag of a held spinner is not checked on a machine with ", u64(SPINNER_LIMIT), " processors or more: each spinner can be alone in its queue")
		return true
	}
	result: Owing_Result
	before, set_status := system.strategy_set(machine, .Eevdf)
	if set_status != .Ok {
		return false
	}
	count := int(processors) + 1
	numbers: [SPINNER_LIMIT]u64
	started := spinners_start(0, count, full_weight) && spinner_machine_numbers(0, count, &numbers)
	wrong_rounds: u64
	deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS
	for started && wrong_rounds == 0 && (result.rounds < OWING_ROUNDS || result.owing == 0) && system.time() < deadline {
		target := spinner_with_company(count)
		thread := spinner_threads[target].handle
		number := intrinsics.atomic_load(&spinners[target].number) - 1
		ran_before: u64
		if item := thread_item(number); item != nil {
			ran_before = item.run_time
		}
		round_right := system.thread_schedule_write(thread, 0, {weight = 1}) == .Ok
		// The wait is for a count of the kernel; the bound only ends a hang.
		for ran := false; round_right && !ran && system.time() < deadline; {
			system.sleep(system.time() + 1)
			item := thread_item(number)
			ran = item != nil && item.run_time > ran_before
		}
		_, stop_status := system.call(.Thread_Control, u64(thread), 0, u64(op.Thread_Control_Command.Stop))
		if stop_status == .Ok {
			first, held := held_lag(number)
			round_right &&= held
			// The program: a raise is refused, a lower request is accepted.
			raise := system.thread_schedule_write(thread, 0, {weight = op.WEIGHT_FULL})
			after_raise, held_after_raise := held_lag(number)
			lower := system.thread_schedule_write(thread, 0, {request = 1})
			after_lower, held_after_lower := held_lag(number)
			round_right &&= held_after_raise && held_after_lower && lower == .Ok
			result.raised += u64(raise != .Bad_Operation)
			result.changed += u64(after_raise != first) + u64(after_lower != first)
			// The machine handle: the full weight and the default request.
			by_machine := system.thread_schedule_write(machine, numbers[target], {})
			after_machine, held_after_machine := held_lag(number)
			round_right &&= by_machine == .Ok && held_after_machine
			result.not_new += u64(after_machine != 0)
			_, resume_status := system.call(.Thread_Control, u64(thread), 0, u64(op.Thread_Control_Command.Resume))
			round_right &&= resume_status == .Ok
			if first < 0 {
				result.owing += 1
				result.largest = max(result.largest, u64(-first))
			} else if first > 0 {
				result.owed += 1
			}
		} else {
			round_right = false
		}
		result.rounds += 1
		wrong_rounds += u64(!round_right)
	}
	spinners_stop(0, count)
	system.strategy_set(machine, before)
	ran_all := started && wrong_rounds == 0 && result.rounds >= OWING_ROUNDS
	as_it_must := ran_all && result.owing != 0 && result.changed == 0 && result.raised == 0 && result.not_new == 0
	ending := string(": as it must")
	switch {
	case !ran_all:
		ending = ": a round did not run: WRONG"
	case result.owing == 0:
		ending = ": no round had a lag below 0, so nothing was checked: WRONG"
	case !as_it_must:
		ending = ": WRONG"
	}
	system.log("scheduler: at least ", u64(OWING_ROUNDS), " rounds on a held spinner under EEVDF, until one had a lag below 0: the spinner lowered to the weight 1 and ran a tick, a Stop, its own writes of the full weight and of the request 1 us, the full weight through the machine handle, a Resume: ", result.raised, " of its raises were not refused, the reported lag changed after ", result.changed, " of its writes, and was not 0 after ", result.not_new, " raises of the machine handle", ending)
	system.log("scheduler: in ", result.rounds, " rounds the kernel reported the held spinner with a lag below 0 ", result.owing, " times and above 0 ", result.owed, " times; the lowest lag was minus ", result.largest, " weighted cycles (measures)")
	return as_it_must
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

// The window is built with the interface package (docs/INTERFACE.md).
records_now, records_before: [1024]interface.Draw_Record
text_now, text_before: [16384]u8
drawing: interface.Window_Drawing
frame_table: ^interface.Draw_Table // The table of the frame that draw builds.
WHOLE :: interface.Area{0, 0, WIDTH, HEIGHT}

// bar: a full part of a bar, from 125 % of its color at the top to 78 % at
// the bottom, on its track.
bar :: proc "contextless" (area: interface.Area, x, y, width, height, full: int, color: graphics.Color) {
	interface.draw_rectangle(frame_table, area.x + x, area.y + y, width, height, graphics.COLOR_TRACK)
	interface.draw_vertical_gradient(frame_table, area.x + x, area.y + y, clamp(full, 0, width), height, graphics.shade(color, 125), graphics.shade(color, 78))
}

fill :: proc "contextless" (area: interface.Area, x, y, width, height: int, color: graphics.Color) {
	interface.draw_rectangle(frame_table, area.x + x, area.y + y, width, height, color)
}

block :: proc "contextless" (area: interface.Area, x, y, width, height: int, top, bottom: graphics.Color) {
	interface.draw_vertical_gradient(frame_table, area.x + x, area.y + y, width, height, top, bottom)
}

write :: proc "contextless" (area: interface.Area, x, y: int, characters: string, color: graphics.Color) -> int {
	return interface.draw_text(frame_table, area.x + x, area.y + y, characters, color) - area.x
}

large :: proc "contextless" (area: interface.Area, x, y: int, characters: string, scale: int, color: graphics.Color) -> int {
	return interface.draw_text(frame_table, area.x + x, area.y + y, characters, color, {scale = u8(scale)}) - area.x
}

card :: proc "contextless" (frame: ^interface.Frame, x, y, width, height: int, title, caption: string) -> interface.Area {
	return interface.card(frame, {x, y, width, height}, title, caption, graphics.COLOR_KERNEL)
}

// The tiles of the strategies in the head: a click on one changes the strategy.
TILE_X :: 480
TILE_Y :: MARGIN + 44
TILE_WIDTH :: 152
TILE_HEIGHT :: 40

LABEL_WIDTH :: 224 // The names of the rows of the measures.
COLUMN_WIDTH :: 232
BAR_WIDTH :: COLUMN_WIDTH - 32
ROW :: 28
CHART :: 44 // A row of columns: the shares.
HEAD_HEIGHT :: 96
MEASURES_HEIGHT :: CARD_TITLE + 24 + 6 * ROW + 2 * CHART + 8

draw :: proc "contextless" (window: ^display.Window, report: op.System_Report, processors: u64) {
	if drawing.now.records == nil {
		drawing = interface.window_drawing_of(records_now[:], records_before[:], text_now[:], text_before[:])
	}
	frame_value := interface.window_frame_begin(&drawing, window)
	frame := &frame_value
	frame_table = frame.table
	interface.background(frame, WHOLE)
	line: [96]u8

	// The head: the strategy in use.
	head := card(frame, MARGIN, MARGIN, WIDTH - 2 * MARGIN, HEAD_HEIGHT, "SCHEDULER", "System_Report.strategy")
	in_use := -1
	for strategy, index in strategies {
		if strategy == report.strategy {
			in_use = index
		}
	}
	name := op.STRATEGY_NAMES[report.strategy]
	after := large(head, 0, 0, name, 2, in_use >= 0 ? strategy_color(in_use) : graphics.COLOR_DIM)
	write(head, after + 16, 0, "in use", graphics.COLOR_DIM)
	write(head, after + 16, 16, system.format(line[:], u64(report.strategy_changes), " changes since boot"), graphics.COLOR_DIM)
	write(WHOLE, TILE_X, MARGIN + 12, "Strategy_Set: a key 1 2 3, Tab and Enter, or a click", graphics.COLOR_DIM)
	for index in 0 ..< STRATEGY_COUNT {
		x := TILE_X + index * (TILE_WIDTH + MARGIN)
		color := strategy_color(index)
		// A tile is a button of the package: the pointer, or Tab and Enter.
		tile := interface.element_interact(frame, interface.identity_with(interface.identity("strategy"), index), {x, TILE_Y, TILE_WIDTH, TILE_HEIGHT}, .Button)
		if tile.activated {
			choose(index)
		}
		label := system.format(line[:], u64(index + 1), "  ", op.STRATEGY_NAMES[strategies[index]])
		if index == in_use {
			block(WHOLE, x, TILE_Y, TILE_WIDTH, TILE_HEIGHT, graphics.shade(color, 120), graphics.shade(color, 70))
			write(WHOLE, x + 12, TILE_Y + 12, label, graphics.COLOR_BACKGROUND)
		} else {
			fill(WHOLE, x, TILE_Y, TILE_WIDTH, TILE_HEIGHT, tile.under_pointer ? graphics.shade(graphics.COLOR_TRACK, 130) : graphics.COLOR_TRACK)
			fill(WHOLE, x, TILE_Y + TILE_HEIGHT - 2, TILE_WIDTH, 2, color)
			write(WHOLE, x + 12, TILE_Y + 12, label, graphics.COLOR_TEXT)
		}
		if tile.focused {
			// The focus: a line of 2 pixels at the top of the tile.
			fill(WHOLE, x, TILE_Y, TILE_WIDTH, 2, graphics.COLOR_WHITE)
		}
	}

	// The measures: one column for each strategy.
	top := MARGIN + HEAD_HEIGHT + MARGIN
	height := MEASURES_HEIGHT
	inside := card(frame, MARGIN, top, WIDTH - 2 * MARGIN, height, "MEASURES", "the same cases under each strategy, in this run")
	for index in 0 ..< STRATEGY_COUNT {
		x := LABEL_WIDTH + index * COLUMN_WIDTH
		fill(inside, x, 0, 4, 16, strategy_color(index))
		write(inside, x + 12, 0, op.STRATEGY_NAMES[strategies[index]], strategy_color(index))
	}
	most_wakes, most_worst, most_work: u64 = 1, 1, 1
	for result in results {
		most_wakes = max(most_wakes, result.wakes)
		most_worst = max(most_worst, result.worst)
		most_work = max(most_work, result.work)
	}
	y := 24
	number_row :: proc "contextless" (area: interface.Area, y: int, label: string, values: [STRATEGY_COUNT]u64, most: u64, unit: string) {
		write(area, 0, y, label, graphics.COLOR_DIM)
		line: [48]u8
		for index in 0 ..< STRATEGY_COUNT {
			x := LABEL_WIDTH + index * COLUMN_WIDTH
			if !results[index].measured {
				write(area, x, y, "not measured yet", graphics.COLOR_DIM)
				continue
			}
			write(area, x, y, system.format(line[:], values[index], unit), graphics.COLOR_TEXT)
			if most != 0 {
				bar(area, x, y + 18, BAR_WIDTH, 4, int(values[index] * BAR_WIDTH / most), strategy_color(index))
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
	write(inside, 0, y, "8 spinners, one weight", graphics.COLOR_DIM)
	write(inside, 0, y + 16, "share of each", graphics.COLOR_DIM)
	for index in 0 ..< STRATEGY_COUNT {
		x := LABEL_WIDTH + index * COLUMN_WIDTH
		if !results[index].measured {
			write(inside, x, y, "not measured yet", graphics.COLOR_DIM)
			continue
		}
		for share, spinner in results[index].shares {
			full := int(min(share, 250) * 36 / 250) // 25 %: the full height.
			fill(inside, x + spinner * 24, y, 16, 36, graphics.COLOR_TRACK)
			block(inside, x + spinner * 24, y + 36 - full, 16, full, graphics.shade(strategy_color(index), 125), graphics.shade(strategy_color(index), 78))
		}
		fill(inside, x, y + 36 - 125 * 36 / 250, 8 * 24 - 8, 1, graphics.COLOR_TEXT) // 12.5 %: the equal part.
	}
	y += CHART
	write(inside, 0, y, "12 spinners, weights 1 2 4", graphics.COLOR_DIM)
	write(inside, 0, y + 16, "share of one of each", graphics.COLOR_DIM)
	for index in 0 ..< STRATEGY_COUNT {
		x := LABEL_WIDTH + index * COLUMN_WIDTH
		if !results[index].measured {
			write(inside, x, y, "not measured yet", graphics.COLOR_DIM)
			continue
		}
		for class in 0 ..< 3 {
			share := results[index].weighted[class]
			full := int(min(share, 200) * 36 / 200) // 20 %: the full height.
			fill(inside, x + class * 48, y, 40, 36, graphics.COLOR_TRACK)
			block(inside, x + class * 48, y + 36 - full, 40, full, graphics.shade(strategy_color(index), 125), graphics.shade(strategy_color(index), 78))
			write(inside, x + class * 48 + 16, y + 20, class == 0 ? "1" : class == 1 ? "2" : "4", graphics.COLOR_BACKGROUND)
		}
		least := results[index].weighted_least
		write(inside, x + 152, y + 20, system.format(line[:], least / 10, ".", least % 10, " %"), graphics.COLOR_DIM)
		write(inside, x + 152, y + 4, "least", graphics.COLOR_DIM)
	}
	y += CHART
	number_row(inside, y, "work, millions in 1 s", values(proc "contextless" (result: ^Result) -> u64 {return result.work / 1_000_000}), most_work / 1_000_000, "")
	y += ROW
	number_row(inside, y, "turns ended by a wake", values(proc "contextless" (result: ^Result) -> u64 {return result.preemptions}), 0, "")
	y += ROW
	number_row(inside, y, "one pick", values(proc "contextless" (result: ^Result) -> u64 {return result.pick}), 0, " ns")
	for index in 0 ..< STRATEGY_COUNT {
		if results[index].measured && results[index].interrupt_preemption != 0 {
			write(inside, LABEL_WIDTH + index * COLUMN_WIDTH + 96, y, system.format(line[:], "preempt ", results[index].interrupt_preemption, " ns"), graphics.COLOR_DIM)
		}
	}

	// The processors: the strategy of each queue and its counts.
	top += height + MARGIN
	shown := min(processors, 4)
	processors_height := CARD_TITLE + 24 + int(shown) * 20 + 8
	rows := card(frame, MARGIN, top, WIDTH - 2 * MARGIN, processors_height, "PROCESSORS", "Processor_Report: the run queue of each processor, since boot")
	headers := [6]string{"processor", "strategy", "queued", "picks", "preemptions", "moves"}
	for header, column in headers {
		write(rows, column * 152, 0, header, graphics.COLOR_DIM)
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
		write(rows, 0, row_y, system.format(line[:], index), graphics.COLOR_TEXT)
		write(rows, 152, row_y, op.STRATEGY_NAMES[report_of.strategy], strategy_index >= 0 ? strategy_color(strategy_index) : graphics.COLOR_DIM)
		write(rows, 2 * 152, row_y, system.format(line[:], u64(report_of.queued)), graphics.COLOR_TEXT)
		write(rows, 3 * 152, row_y, system.format(line[:], report_of.picks), graphics.COLOR_TEXT)
		write(rows, 4 * 152, row_y, system.format(line[:], report_of.preemptions), graphics.COLOR_TEXT)
		write(rows, 5 * 152, row_y, system.format(line[:], report_of.moves), graphics.COLOR_TEXT)
	}

	// The change under load, and the result.
	top += processors_height + MARGIN
	last := card(frame, MARGIN, top, WIDTH - 2 * MARGIN, HEIGHT - top - MARGIN, "CHANGES WHILE THREADS RUN", "Strategy_Set, 100 times")
	if stress_done {
		text := system.format(line[:], stress_changes, " changes while ", stress_churned, " threads started and ended; one change ", change_least / 1000, " to ", change_worst / 1000, " us, middle ", change_middle / 1000, " us")
		write(last, 0, 0, text, stress_right ? graphics.COLOR_TEXT : graphics.COLOR_FAILED)
	} else {
		write(last, 0, 0, "not measured yet", graphics.COLOR_DIM)
	}
	status_y := 20
	switch {
	case !done:
		write(last, 0, status_y, "measures in progress", graphics.COLOR_BOOT_PROGRAM)
	case right:
		write(last, 0, status_y, "ok: no thread starved, each thread ran after the changes, a change needs the right Schedule", graphics.COLOR_PROGRAM)
	case:
		write(last, 0, status_y, system.format(line[:], "wrong: ", problem), graphics.COLOR_FAILED)
	}
	interface.window_frame_end(&drawing, frame, window)
}

choose :: proc "contextless" (index: int) {
	if index < 0 || index >= STRATEGY_COUNT {
		return
	}
	if before, status := system.strategy_set(machine, strategies[index]); status == .Ok && before != strategies[index] {
		system.log("scheduler: the strategy is now ", op.STRATEGY_NAMES[strategies[index]], ", it was ", op.STRATEGY_NAMES[before])
	}
}

// The entry of scheduler: the checks of the refusals, the four cases under
// each strategy, the stress of the changes, then a window where a key or a
// click chooses the strategy.
//
// With no window it stops with the code 1. A failed check does not stop
// it: `fail` keeps the first problem, and the result line says it. After
// the measures it gives the machine back the strategy of its start. Then it
// draws every 500 ms; the keys 1, 2 and 3, or a click on a tile, change the
// strategy of the machine.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	window, ok := display.open(ctx, WIDTH, HEIGHT, "scheduler")
	if !ok {
		system.stop(1)
	}
	machine = ctx.handles[system.GRANT_MACHINE]
	report := system_report()
	processors := report.processors
	draw(&window, report, processors)

	original := report.strategy
	refusals_right = refusals()
	if !refusals_right {
		fail("a change with no right Schedule, or a weight above 1024, was not refused")
	}
	if !find_self() {
		fail("the program did not find its own threads in the reports")
	}
	if !own_schedules() {
		fail("a thread did not read or write its own schedule")
	}
	if !schedule_refusals() {
		fail("a write of a schedule was not refused as it must")
	}
	if !other_program_schedule() {
		fail("the schedule of a thread of another program was not read and written")
	}
	if self_machine_number == 0 || !weight_limits() {
		fail("a weight limit did not hold")
	}
	if !owing_kept(processors) {
		fail("a write of a schedule did not leave or start again the place of a held thread")
	}
	for index in 0 ..< STRATEGY_COUNT {
		measure(index, processors)
		if results[index].measured {
			log_result(index)
		}
		draw(&window, system_report(), processors)
	}
	log_written()
	if lost_wakes != 0 {
		fail("a wake was lost")
	}
	// Round robin has no wake preemption, and EEVDF has it: the counts of
	// the kernel in the case of the two threads say it. The wakes in one
	// second of each are a measure, printed and not checked.
	round_robin_preemptions := results[0].pair_local + results[0].pair_interrupts
	eevdf_preemptions := results[2].pair_local + results[2].pair_interrupts
	if results[0].measured && results[2].measured && (round_robin_preemptions != 0 || eevdf_preemptions == 0) {
		fail("round robin ended a turn by a wake, or EEVDF never did")
	}
	stress()
	system.strategy_set(machine, original)
	done = true
	if right {
		system.log("scheduler: ok, no spinner starved under 3 strategies, EEVDF woke ", results[2].wakes / max(results[0].wakes, 1), " times as often as round robin (a measure), a wake ended ", eevdf_preemptions, " turns under EEVDF and 0 under round robin, the weights ordered the shares, each thread ran after ", stress_changes, " changes, 0 wakes lost, a change needs the right Schedule")
	} else {
		system.log("scheduler: wrong: ", problem)
	}
	start := system.nanoseconds()
	draw(&window, system_report(), processors)
	drawn := system.nanoseconds() - start
	system.log("scheduler: the window took ", drawn / 1000, " us to draw")
	for {
		// The events go to the input of the next frame: a click or Enter on
		// a tile chooses its strategy there; the keys 1 2 3 choose here.
		interface.window_events(&drawing, &window)
		for &key in drawing.input.keys[:drawing.input.key_count] {
			if key.character >= '1' && key.character <= '3' {
				key.taken = true
				choose(int(key.character - '1'))
			}
		}
		// The counts of the processors change: the window shows them each 500 ms.
		draw(&window, system_report(), processors)
		display.wait(&window, system.time() + 500)
	}
}
