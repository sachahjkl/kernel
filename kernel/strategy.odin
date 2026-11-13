package kernel

import "base:intrinsics"
import op "contract:operation"

// The scheduling strategies (docs/SCHEDULING.md). A strategy is a table of
// six functions over the data of one run queue. The generic code of
// schedule.odin keeps the list of each queue, the run locks, the balance
// between processors and the budgets; a strategy decides only the order.
//
// The state of a strategy is in fixed fields: in the thread record (the
// hot line: virtual, virtual_deadline, lag, placed) and in the run queue
// (virtual, weight). Zero is valid in each field for each strategy: a
// thread that is not placed is placed by `ready` with the kind New.
//
// Each function runs under the run lock of the queue that it receives.
// A thread that it reads is in that queue, or runs on the processor of
// that queue (its home is that processor): its fields are under the same
// lock. `move` holds the run locks of the two queues.
//
// Invariant (the change of strategy, strategy_change below): the strategy
// fields of a thread are zero or belong to the strategy of the queue of
// its home.

// How a thread became ready.
Ready_Kind :: enum u8 {
	New, // A new thread, or a thread whose strategy fields are zero.
	Woken, // A thread that waited.
	Back, // The thread that ran: its turn ended and it is still ready.
}

Strategy_Table :: struct {
	// A thread becomes ready in the queue of its home. It is not yet in
	// the list: the generic code puts it at the end after this call.
	ready:         proc "contextless" (queue: ^Run_Queue, home: u32, thread: ^Thread, kind: Ready_Kind),
	// The next thread of a queue, among the threads that a budget lets
	// run, or nil. The generic code takes it out of the list.
	pick:          proc "contextless" (queue: ^Run_Queue, home: u32) -> ^Thread,
	// The tick on the processor that runs the thread: cycles is the time
	// since the last charge. true: the turn ends.
	tick:          proc "contextless" (queue: ^Run_Queue, cpu: ^Processor, thread: ^Thread, cycles: u64) -> bool,
	// The thread leaves its processor: cycles since the last charge. waits:
	// it waits, or it ends; else it goes back to the queue (ready, Back).
	stopping:      proc "contextless" (queue: ^Run_Queue, cpu: ^Processor, thread: ^Thread, cycles: u64, waits: bool),
	// A thread woke in the queue (it is in the list now) while `running`
	// runs on the processor of the queue. true: the turn of running ends.
	wake_preempts: proc "contextless" (queue: ^Run_Queue, home: u32, running: ^Thread, woken: ^Thread) -> bool,
	// A processor takes a thread from the queue `from` to run it: its home
	// becomes `to`. The thread is still in the list of `from`.
	move:          proc "contextless" (from: ^Run_Queue, from_home: u32, to: ^Run_Queue, to_home: u32, thread: ^Thread),
}

@(rodata)
STRATEGIES := [op.Strategy]Strategy_Table {
	.None        = ROUND_ROBIN,
	.Round_Robin = ROUND_ROBIN,
	.Fair        = FAIR,
	.Eevdf       = EEVDF,
}

// The strategy at boot: EEVDF, for its wake preemption (docs/SCHEDULING.md).
STRATEGY_START :: op.Strategy.Eevdf

// The strategy that the machine has: Strategy_Set writes it. Each queue has
// its own word (Run_Queue.strategy), which changes under its run lock.
strategy_chosen: op.Strategy
strategy_changes: u64

// The lengths of the strategies, in cycles of the cycle counter: the
// kernel measured its frequency before (timer_calibrate).
fair_latency, fair_least_turn, fair_wake, fair_credit, tick_cycles: u64

FAIR_LATENCY :: 6000 // Microseconds: the time in which each thread of a queue runs one time.
FAIR_LEAST_TURN :: 750 // Microseconds: the shortest turn.
FAIR_WAKE :: 1000 // Microseconds: a woken thread preempts if its virtual time is less by more than this.
FAIR_CREDIT :: 3000 // Microseconds: a woken thread is at most this much under the queue clock.

// strategy_start gives each run queue the strategy of the boot, before the
// first thread.
strategy_start :: proc "contextless" () {
	fair_latency = microseconds_to_cycles(FAIR_LATENCY)
	fair_least_turn = microseconds_to_cycles(FAIR_LEAST_TURN)
	fair_wake = microseconds_to_cycles(FAIR_WAKE)
	fair_credit = microseconds_to_cycles(FAIR_CREDIT)
	tick_cycles = cycle_frequency / TICKS_PER_SECOND
	strategy_chosen = STRATEGY_START
	for &queue in run_queues {
		queue.strategy = STRATEGY_START
	}
}

// microseconds_to_cycles: at most 10^5 microseconds (REQUEST_LIMIT) times
// a frequency below 2^40: no overflow.
microseconds_to_cycles :: #force_inline proc "contextless" (value: u64) -> u64 {
	return value * cycle_frequency / 1_000_000
}

// strategy_change gives the machine a new strategy while it runs
// (docs/SCHEDULING.md, "The change at run time"; docs/ARCHITECTURE.md,
// "The change of strategy"). It writes the word of the machine, then
// visits each run queue under its run lock, one at a time, and converts the
// queue to the strategy that the word holds at that moment. It holds no
// other lock: the caller holds at most its program lock (lock order:
// program before run). It gives the strategy that the machine had.
//
// Why the last change wins on each queue: let B be the operation whose
// write of the word is the last one. B visits each queue after its write;
// at its visit the word holds B's strategy, so the queue gets it; a later
// visit of another operation reads the same word. So after the last
// operation returns, each queue has the strategy of the word.
strategy_change :: proc "contextless" (target: op.Strategy) -> op.Strategy {
	before := intrinsics.atomic_exchange(&strategy_chosen, target)
	intrinsics.atomic_add(&strategy_changes, 1)
	for cpu in processors[:processor_count] {
		queue := &run_queues[cpu.index]
		lock_take(&queue.lock, .Run)
		queue_convert(queue, cpu.index, intrinsics.atomic_load(&strategy_chosen))
		lock_free(&queue.lock, .Run)
	}
	return before
}

// queue_convert gives a queue a strategy. The caller holds its run lock.
//
// It changes no list, no state, no home and no processor: each thread that
// was in the queue stays in it, in its order, and each thread that ran
// still runs. It clears the strategy fields of each thread whose home is
// this queue and whose fields the old strategy wrote: a thread in the
// list, the thread on the processor, a thread that waits, a thread that a
// stop of Thread_Control holds. These fields are under this run lock: the
// home of a thread changes only under the run lock of the old home and of
// the new one. Another thread that is Ready, in no list and on no
// processor is a new thread whose creation writes its fields with no lock:
// it is skipped; its fields are zero, and it enters the list
// (thread_queue) under this lock, after the conversion or before it. Then
// each thread of the list is placed by the new strategy (New); the thread
// on the processor is placed at its next tick or when it leaves (not
// placed); a thread that waits or that a stop holds is placed when it
// enters the list again.
queue_convert :: proc "contextless" (queue: ^Run_Queue, home: u32, target: op.Strategy) {
	if queue.strategy == target {
		return
	}
	for &thread in threads[1:] {
		if intrinsics.atomic_load(&thread.home) != home {
			continue
		}
		state := intrinsics.atomic_load(&thread.state)
		if state == .Waiting || state == .Ready && (thread.queued || thread.processor != 0 || thread.control_stops != 0) {
			strategy_clear(&thread)
		}
	}
	intrinsics.atomic_store(&queue.strategy, target) // A report reads it with no lock.
	for index := queue.head; index != 0; index = threads[index].queue_next {
		strategy_of(queue).ready(queue, home, &threads[index], .New)
	}
}

// strategy_of gives the table of the strategy of a queue. The caller holds
// its run lock.
strategy_of :: #force_inline proc "contextless" (queue: ^Run_Queue) -> ^Strategy_Table {
	return &STRATEGIES[queue.strategy]
}

// strategy_clear gives the strategy fields of a thread their zero values.
// The caller holds the run lock of its home.
strategy_clear :: proc "contextless" (thread: ^Thread) {
	thread.virtual = 0
	thread.virtual_deadline = 0
	thread.lag = 0
	thread.placed = false
}

// strategy_schedule_changed keeps the strategy fields of a thread right
// after its weight or its request changed (thread_schedule_write). The
// caller holds the run lock of the home of the thread, whose queue this is,
// and wrote the new values; old_weight is the weight before the write.
//
// What a write keeps: the position of the thread against the other
// threads, so that a thread that owes time still owes it, and no write
// makes larger what a thread is owed.
//
// What each strategy holds that depends on the two values:
// - Round robin reads neither.
// - The fair strategy reads the weight only to charge a run and to size a
//   turn, at the moment of each. Its virtual time, and the distance to the
//   queue clock that a waiting thread keeps, have no weight in them: they
//   stay, and the next charge uses the new weight.
// - EEVDF, a thread in the list or on the processor: the virtual time
//   stays. Two values come from the old weight and the old request: the
//   largest lag of the thread, and its virtual deadline. The thread is kept
//   within its new bound under the queue clock, as each pick does for the
//   list: a thread that was owed much virtual time under a small weight is
//   not owed that much under a large one. Its deadline is at most one new
//   request after its virtual time, and never later than it was: a shorter
//   request counts at once, and a write gives no later end to a turn.
// - EEVDF, a thread that waits or that a stop holds: its kept lag is not a
//   plain distance. The average at the stop counted the thread with its
//   weight, and the place at the wake scales the lag back with the weight
//   that the thread has then (eevdf_place). With one weight the two cancel.
//   With two they do not: a lag kept under the full weight and placed under
//   the weight 1 is about half the distance, so a thread would lose half of
//   its debt at each wait. So the write converts the lag
//   (eevdf_lag_converted), then keeps it within the new bound.
// A thread that is not placed has zero fields: nothing to keep.
//
// The time that a running thread used since its last charge is charged at
// the new weight, at its next tick or when it leaves: at most one tick.
strategy_schedule_changed :: proc "contextless" (queue: ^Run_Queue, thread: ^Thread, old_weight: u32) {
	if queue.strategy != .Eevdf || !thread.placed {
		return
	}
	bound := eevdf_bound(thread)
	if thread.queued || thread.processor != 0 {
		floor_to(thread, queue.virtual - bound)
		latest := thread.virtual + eevdf_slice(thread)
		if before(latest, thread.virtual_deadline) {
			thread.virtual_deadline = latest
		}
	} else {
		thread.lag = clamp(eevdf_lag_converted(thread.lag, old_weight, thread.weight), -i64(bound), i64(bound))
	}
}

// eevdf_lag_converted gives the lag that a thread which waits keeps after
// its weight changed. The lag times the weight is the processor time that
// the thread owes (below 0) or is owed (above 0): the conversion keeps that
// time, lag * old / new, with one exception.
//
// The exception: what a thread is owed does not grow in virtual time when
// its weight goes down. A thread in the list keeps its virtual time across
// a write, so a larger lag under a small weight, then the full weight
// written again after the wake, would be time that the thread never
// waited for: a thread that sleeps a little and writes its weight down
// and up would run before each other thread at each wake. So a write
// keeps what a thread owes, exactly in both directions, and can only
// make smaller what it is owed.
//
// The lag is at most 2^40 (eevdf_bound; it is clamped again here, also for
// a value that another strategy left) and a weight at most 2^10: the
// product is below 2^51.
eevdf_lag_converted :: proc "contextless" (lag: i64, old_weight, new_weight: u32) -> i64 {
	if old_weight == new_weight || lag > 0 && new_weight < old_weight {
		return lag
	}
	LAG_LIMIT :: i64(1) << 40
	return clamp(lag, -LAG_LIMIT, LAG_LIMIT) * i64(max(old_weight, 1)) / i64(max(new_weight, 1))
}

// strategy_leaves_list keeps the position of a thread that leaves the list
// of its queue with no turn: a stop of Thread_Control holds it. It is the
// `stopping` of a thread that starts to wait, with no time to charge: the
// Resume places the thread as a woken thread, so a thread that owes time
// still owes it after a Stop and a Resume. The caller holds the run lock
// of the queue; the thread is still in the list.
//
// The average of EEVDF does not count a thread of the list whose budget
// has no time left, and `stopping` takes the average with the thread in
// it. For such a thread the lag is taken against the other threads and
// scaled as the average would scale it, so the place at the wake gives the
// same distance back.
strategy_leaves_list :: proc "contextless" (queue: ^Run_Queue, home: u32, thread: ^Thread) {
	if !thread.placed {
		return
	}
	if queue.strategy == .Eevdf && budget_spent(thread.budget) {
		average, total := eevdf_average(queue, home)
		lag := eevdf_lag(thread, average) // At most 2^40; the weights sum to at most 2^18.
		if total != 0 {
			lag = lag * total / (total + i64(thread.weight))
		}
		thread.lag = lag
		return
	}
	strategy_of(queue).stopping(queue, processors[home], thread, 0, true)
}

// strategy_tick charges the time of the thread that runs on this processor
// to its strategy, under the run lock of the processor: the home of a
// thread that runs is its processor. true: the turn ends.
//
// The time slice (TIME_SLICE ticks) is the longest turn under each
// strategy: at its end the processor passes through schedule_pick, where
// it takes a thread from a queue with more load. Without it, a thread
// alone in its queue under EEVDF keeps its processor while threads wait in
// another queue: measured, "at most 3 of 4 processors ran the program at
// the same time" (program processors).
strategy_tick :: proc "contextless" (cpu: ^Processor, thread: ^Thread, cycles: u64) -> bool {
	queue := &run_queues[cpu.index]
	lock_take(&queue.lock, .Run)
	strategy := strategy_of(queue)
	if !thread.placed {
		strategy.ready(queue, cpu.index, thread, .New)
	}
	ended := strategy.tick(queue, cpu, thread, cycles)
	lock_free(&queue.lock, .Run)
	cpu.slice_left -= min(cpu.slice_left, 1)
	return ended || cpu.slice_left == 0
}

// The round robin: the queue in its order, a time slice of TIME_SLICE
// ticks (strategy_tick), no wake preemption. The behavior of the kernel
// before the strategies.
ROUND_ROBIN :: Strategy_Table {
	ready         = round_robin_ready,
	pick          = round_robin_pick,
	tick          = round_robin_tick,
	stopping      = round_robin_stopping,
	wake_preempts = round_robin_wake_preempts,
	move          = round_robin_move,
}

round_robin_ready :: proc "contextless" (queue: ^Run_Queue, home: u32, thread: ^Thread, kind: Ready_Kind) {}

// The first thread of the queue whose budget has processor time in this
// period: one line of the queue and one line of each thread passed over.
round_robin_pick :: proc "contextless" (queue: ^Run_Queue, home: u32) -> ^Thread {
	for index := queue.head; index != 0; index = threads[index].queue_next {
		if !budget_spent(threads[index].budget) {
			return &threads[index]
		}
	}
	return nil
}

round_robin_tick :: proc "contextless" (queue: ^Run_Queue, cpu: ^Processor, thread: ^Thread, cycles: u64) -> bool {
	return false
}

round_robin_stopping :: proc "contextless" (queue: ^Run_Queue, cpu: ^Processor, thread: ^Thread, cycles: u64, waits: bool) {}

round_robin_wake_preempts :: proc "contextless" (queue: ^Run_Queue, home: u32, running: ^Thread, woken: ^Thread) -> bool {
	return false
}

round_robin_move :: proc "contextless" (from: ^Run_Queue, from_home: u32, to: ^Run_Queue, to_home: u32, thread: ^Thread) {}


// Arithmetic of the virtual times (docs/SCHEDULING.md, "Integer arithmetic
// and the overflow argument"). A virtual time is a u64 that can wrap: two
// of them compare by the sign of their difference.

CHARGE_LIMIT :: u64(1) << 32 // Cycles: the longest charge.
KEY_LIMIT :: i64(1) << 44 // Weighted cycles: the largest distance to the queue clock in an average.

before :: #force_inline proc "contextless" (a, b: u64) -> bool {
	return i64(a - b) < 0
}

// weighted gives the virtual time of a run: cycles * WEIGHT_FULL / weight.
weighted :: #force_inline proc "contextless" (cycles: u64, weight: u32) -> u64 {
	return min(cycles, CHARGE_LIMIT) * op.WEIGHT_FULL / u64(max(weight, 1))
}

// charge adds a run to the virtual time of a thread.
charge :: #force_inline proc "contextless" (thread: ^Thread, cycles: u64) {
	thread.virtual += weighted(cycles, thread.weight)
}

// floor_to keeps a thread at most at a distance under a virtual time.
floor_to :: #force_inline proc "contextless" (thread: ^Thread, floor: u64) {
	if before(thread.virtual, floor) {
		thread.virtual = floor
	}
}

// clock_advance moves the queue clock up to a virtual time, never back.
clock_advance :: #force_inline proc "contextless" (queue: ^Run_Queue, virtual: u64) {
	if before(queue.virtual, virtual) {
		queue.virtual = virtual
	}
}

// The fair strategy: the idea of CFS. The least virtual time runs. A turn
// is the target latency divided by weight, at least the least turn. A
// woken thread is at most the credit under the queue clock, and preempts
// when its virtual time is less by more than the wake granularity.
FAIR :: Strategy_Table {
	ready         = fair_ready,
	pick          = fair_pick,
	tick          = fair_tick,
	stopping      = fair_stopping,
	wake_preempts = fair_wake_preempts,
	move          = fair_move,
}

// A thread that is placed (new, or placed again after a change of
// strategy: the two cases are one, so each thread of a change starts equal)
// starts one least turn, weighted, after the queue clock: a program that
// creates threads all the time does not get a turn before each other thread.
//
// A thread that waits keeps its position relative to the queue clock
// (`lag`, written by fair_stopping), not its virtual time: the clock can
// move by any amount during a wait, and an absolute virtual time compared
// after 2^63 weighted cycles would look ahead. A thread does not move while
// it waits (a move takes a thread from a list), so its home and its clock
// are the ones of fair_stopping. A thread that is Back is in the list: the
// next pick keeps it within the credit under the clock (fair_pick).
fair_ready :: proc "contextless" (queue: ^Run_Queue, home: u32, thread: ^Thread, kind: Ready_Kind) {
	switch {
	case !thread.placed || kind == .New:
		thread.virtual = queue.virtual + weighted(fair_least_turn, thread.weight)
		thread.placed = true
	case kind == .Woken:
		thread.virtual = queue.virtual + u64(thread.lag)
	}
}

// One pass over the list: each thread is kept within the credit under the
// clock; the least virtual time among the threads that a budget lets run.
fair_pick :: proc "contextless" (queue: ^Run_Queue, home: u32) -> ^Thread {
	best: ^Thread
	floor := queue.virtual - fair_credit
	for index := queue.head; index != 0; index = threads[index].queue_next {
		thread := &threads[index]
		floor_to(thread, floor)
		if !budget_spent(thread.budget) && (best == nil || before(thread.virtual, best.virtual)) {
			best = thread
		}
	}
	if best != nil {
		clock_advance(queue, best.virtual)
	}
	return best
}

fair_tick :: proc "contextless" (queue: ^Run_Queue, cpu: ^Processor, thread: ^Thread, cycles: u64) -> bool {
	charge(thread, cycles)
	if queue.count == 0 {
		clock_advance(queue, thread.virtual)
		return false
	}
	// The weights are at most 2^10 each, 2^18 for the 256 threads.
	turn := max(fair_least_turn, fair_latency * u64(thread.weight) / u64(thread.weight + queue.weight))
	return cycles_now() - cpu.turn_start >= turn
}

// A thread that waits keeps its distance to the queue clock, at most the
// credit under it and at most KEY_LIMIT above it.
fair_stopping :: proc "contextless" (queue: ^Run_Queue, cpu: ^Processor, thread: ^Thread, cycles: u64, waits: bool) {
	charge(thread, cycles)
	if waits {
		thread.lag = clamp(i64(thread.virtual - queue.virtual), -i64(fair_credit), KEY_LIMIT)
	}
}

fair_wake_preempts :: proc "contextless" (queue: ^Run_Queue, home: u32, running: ^Thread, woken: ^Thread) -> bool {
	return running.placed && before(woken.virtual + weighted(fair_wake, woken.weight), running.virtual)
}

// A move keeps the distance of the thread to the queue clock.
fair_move :: proc "contextless" (from: ^Run_Queue, from_home: u32, to: ^Run_Queue, to_home: u32, thread: ^Thread) {
	thread.virtual = thread.virtual - from.virtual + to.virtual
}

// EEVDF: the average virtual time V of the queue, with the thread that runs
// on its processor; a thread is eligible when its virtual time is not
// above V; among the eligible threads, the earliest virtual deadline runs.
// The deadline is the virtual time plus the request in weighted cycles.
// The lag (V minus the virtual time) is kept across a wait, within two
// requests (at least one tick), and across a move.
EEVDF :: Strategy_Table {
	ready         = eevdf_ready,
	pick          = eevdf_pick,
	tick          = eevdf_tick,
	stopping      = eevdf_stopping,
	wake_preempts = eevdf_wake_preempts,
	move          = eevdf_move,
}

// eevdf_slice gives the request of a thread in weighted cycles: at most
// 2^39 (REQUEST_LIMIT at 5 GHz, weight 1).
eevdf_slice :: #force_inline proc "contextless" (thread: ^Thread) -> u64 {
	return weighted(microseconds_to_cycles(u64(thread.request)), thread.weight)
}

// eevdf_bound gives the largest lag of a thread: two requests, at least
// one tick. At most 2^40.
eevdf_bound :: #force_inline proc "contextless" (thread: ^Thread) -> u64 {
	return max(2 * eevdf_slice(thread), weighted(tick_cycles, thread.weight))
}

// eevdf_average gives V for a queue: the threads of the list that a budget
// lets run, and the thread that runs on the processor of the queue, each
// with its weight; and the sum of their weights. A thread that is not
// placed does not count. The keys are clamped (KEY_LIMIT): a product is at
// most 2^54, the sum of 256 threads at most 2^62.
eevdf_average :: proc "contextless" (queue: ^Run_Queue, home: u32) -> (average: u64, weight: i64) {
	clock := queue.virtual
	sum: i64
	add :: #force_inline proc "contextless" (thread: ^Thread, clock: u64, sum: ^i64, weight: ^i64) {
		if thread.placed {
			key := clamp(i64(thread.virtual - clock), -KEY_LIMIT, KEY_LIMIT)
			sum^ += i64(thread.weight) * key
			weight^ += i64(thread.weight)
		}
	}
	for index := queue.head; index != 0; index = threads[index].queue_next {
		if !budget_spent(threads[index].budget) {
			add(&threads[index], clock, &sum, &weight)
		}
	}
	// A processor that starts runs schedule before the first processor
	// puts its record in `processors`: no record, no thread on it.
	if cpu := processors[home]; cpu != nil {
		if running := cpu.current; running != 0 {
			add(&threads[running], clock, &sum, &weight)
		}
	}
	if weight == 0 {
		return clock, 0
	}
	return clock + u64(sum / weight), weight
}

// eevdf_place puts a thread that is not in the list at V minus its lag,
// scaled by (W + w) / W so that V does not move when the thread joins: a
// lag of at most 2^40 times at most 2^18 + 2^10. Its deadline is one
// request after.
eevdf_place :: proc "contextless" (queue: ^Run_Queue, home: u32, thread: ^Thread, lag: i64) {
	average, total := eevdf_average(queue, home)
	scaled := lag
	if total != 0 {
		scaled = lag * (total + i64(thread.weight)) / total
	}
	thread.virtual = average - u64(scaled)
	thread.virtual_deadline = thread.virtual + eevdf_slice(thread)
	thread.placed = true
}

// eevdf_lag gives the lag of a thread against an average, within its bound.
eevdf_lag :: #force_inline proc "contextless" (thread: ^Thread, average: u64) -> i64 {
	bound := i64(eevdf_bound(thread))
	return clamp(i64(average - thread.virtual), -bound, bound)
}

eevdf_ready :: proc "contextless" (queue: ^Run_Queue, home: u32, thread: ^Thread, kind: Ready_Kind) {
	switch {
	case !thread.placed || kind == .New:
		eevdf_place(queue, home, thread, 0)
	case kind == .Woken:
		eevdf_place(queue, home, thread, thread.lag)
	}
}

// Three passes over the list: each thread is kept within its lag bound
// under the clock; V; the earliest deadline among the eligible threads.
// The second and the third read lines that the first brought.
eevdf_pick :: proc "contextless" (queue: ^Run_Queue, home: u32) -> ^Thread {
	if queue.head == 0 {
		return nil
	}
	for index := queue.head; index != 0; index = threads[index].queue_next {
		thread := &threads[index]
		floor_to(thread, queue.virtual - eevdf_bound(thread))
	}
	average, _ := eevdf_average(queue, home)
	best, least: ^Thread
	for index := queue.head; index != 0; index = threads[index].queue_next {
		thread := &threads[index]
		if budget_spent(thread.budget) {
			continue
		}
		if least == nil || before(thread.virtual, least.virtual) {
			least = thread
		}
		if !before(average, thread.virtual) && (best == nil || before(thread.virtual_deadline, best.virtual_deadline)) {
			best = thread
		}
	}
	if least != nil {
		clock_advance(queue, least.virtual)
	}
	// With the thread that runs in V, the least of the list can be above
	// V: it runs, as the least virtual time.
	return best != nil ? best : least
}

// A thread that used its request gets a new deadline; its turn ends if
// another thread waits in the queue.
eevdf_tick :: proc "contextless" (queue: ^Run_Queue, cpu: ^Processor, thread: ^Thread, cycles: u64) -> bool {
	charge(thread, cycles)
	if queue.count == 0 {
		clock_advance(queue, thread.virtual)
	}
	if before(thread.virtual, thread.virtual_deadline) {
		return false
	}
	thread.virtual_deadline = thread.virtual + eevdf_slice(thread)
	return queue.count != 0
}

// A thread that waits keeps its lag: V is taken while the thread is still
// the thread that runs on its home.
eevdf_stopping :: proc "contextless" (queue: ^Run_Queue, cpu: ^Processor, thread: ^Thread, cycles: u64, waits: bool) {
	charge(thread, cycles)
	if waits {
		average, _ := eevdf_average(queue, cpu.index)
		thread.lag = eevdf_lag(thread, average)
	}
}

// A woken thread preempts when it is eligible and its deadline is earlier,
// or when the thread that runs is not eligible.
eevdf_wake_preempts :: proc "contextless" (queue: ^Run_Queue, home: u32, running: ^Thread, woken: ^Thread) -> bool {
	if !running.placed {
		return false
	}
	average, _ := eevdf_average(queue, home)
	if before(average, woken.virtual) {
		return false
	}
	return before(woken.virtual_deadline, running.virtual_deadline) || before(average, running.virtual)
}

// A move keeps the lag: V of the old queue (the thread is still in its
// list), then a place in the new one.
eevdf_move :: proc "contextless" (from: ^Run_Queue, from_home: u32, to: ^Run_Queue, to_home: u32, thread: ^Thread) {
	average, _ := eevdf_average(from, from_home)
	eevdf_place(to, to_home, thread, eevdf_lag(thread, average))
}
