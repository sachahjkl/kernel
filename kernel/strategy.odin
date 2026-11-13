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
	thread.lag_weight = 0
	thread.placed = false
}

// The invariant of a write of a schedule (docs/SCHEDULING.md, "The
// schedule of a live thread"). Each strategy has one quantity that says
// where a thread is against the other threads of its queue:
// - round robin: none; the order of the list;
// - fair: the virtual time of the thread minus the queue clock;
// - EEVDF: the place of the thread against the other threads of its
//   queue: their average virtual time minus its own. Above 0 the thread
//   is owed time; below 0 it owes time.
// A write of a schedule leaves that quantity as it is when the thread
// owes, and can only make it smaller when the thread is owed, in every
// state of the thread: in the list, on a processor, in a wait, held by a
// stop. The state must not matter, because a program chooses the state in
// which each write lands (a Stop takes a thread from the list to a hold;
// a wake or a Resume puts it back).
//
// A thread in the list or on a processor holds the quantity as its
// virtual time, which no write moves back. A thread that waits or is held
// under EEVDF holds it as a kept lag: the lag against the average that
// counts the thread itself, which has the weight of the thread in it, and
// which the place at the wake scales back with a weight. The two weights
// must be one weight, or a weight written during the wait changes the
// quantity. So the thread keeps the weight of its stop beside the lag
// (`lag_weight`), and the wake scales with that one: a write during a
// wait reads and writes neither.
//
// The bounds follow the same rule. What a thread is owed is cut to the
// bound of its values (two requests), which a write can make smaller:
// that is against the thread. What a thread owes is cut by a bound with
// no request in it: the longest turn at the weight of the stop
// (eevdf_owing_bound). A request written short before a wait then takes
// nothing away, and a weight written before the wait leaves the thread
// owing at least what a thread at its weight limit owes for the same run.

// strategy_schedule_changed applies the bounds of the new values after the
// weight or the request of a thread changed (thread_schedule_write). The
// caller holds the run lock of the home of the thread, whose queue this
// is, and wrote the new values.
//
// - Round robin and the fair strategy: nothing. Their quantity has no
//   bound that depends on the two values; the next charge and the next
//   turn use the new weight.
// - EEVDF: what the thread is owed is cut to the bound of the new values.
//   A thread in the list or on the processor is raised to that bound under
//   the queue clock, as each pick does for the list; a thread that waits
//   or is held has its kept lag cut to it. What it owes is not touched,
//   and the weight of its stop stays.
//   The virtual deadline of a thread in the list is at most one new
//   request after its virtual time, and never later than it was: a shorter
//   request counts at once, and a write gives no later end to a turn. The
//   deadline orders the eligible threads; it is not in the lag.
// A thread that is not placed has zero fields: nothing to keep.
//
// The time that a running thread used since its last charge is charged at
// the new weight, at its next tick or when it leaves: at most one tick.
strategy_schedule_changed :: proc "contextless" (queue: ^Run_Queue, thread: ^Thread) {
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
		thread.lag = min(thread.lag, i64(bound))
	}
}

// strategy_leaves_list keeps the position of a thread that leaves the list
// of its queue with no turn: a stop of Thread_Control holds it. It is the
// `stopping` of a thread that starts to wait, with no time to charge: the
// Resume places the thread as a woken thread, so a thread that owes time
// still owes it after a Stop and a Resume. The caller holds the run lock
// of the queue; the thread is still in the list.
strategy_leaves_list :: proc "contextless" (queue: ^Run_Queue, home: u32, thread: ^Thread) {
	if thread.placed {
		strategy_of(queue).stopping(queue, processors[home], thread, 0, true)
	}
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
// The lag (V minus the virtual time) is kept across a wait and across a
// move: what a thread is owed within two requests (at least one tick),
// what it owes within the longest turn at its weight.
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
// placed does not count, and `without` does not count: the average of the
// other threads of a thread. The keys are clamped (KEY_LIMIT): a product
// is at most 2^54, the sum of 256 threads at most 2^62.
eevdf_average :: proc "contextless" (queue: ^Run_Queue, home: u32, without: ^Thread = nil) -> (average: u64, weight: i64) {
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
		if &threads[index] != without && !budget_spent(threads[index].budget) {
			add(&threads[index], clock, &sum, &weight)
		}
	}
	// A processor that starts runs schedule before the first processor
	// puts its record in `processors`: no record, no thread on it.
	if cpu := processors[home]; cpu != nil {
		if running := cpu.current; running != 0 && &threads[running] != without {
			add(&threads[running], clock, &sum, &weight)
		}
	}
	if weight == 0 {
		return clock, 0
	}
	return clock + u64(sum / weight), weight
}

// eevdf_owing_bound gives the most that a thread keeps of what it owes,
// across a wait and across a move: the longest turn (the time slice and
// one tick) at the weight that the thread has, in weighted cycles. No
// thread owes more after one turn, so the bound takes nothing away that
// one turn ran. No request is in it: a request that a thread writes short
// before it waits cuts nothing. At most 11 ticks at the weight 1: below
// 2^36 at 5 GHz.
eevdf_owing_bound :: #force_inline proc "contextless" (thread: ^Thread) -> u64 {
	return weighted((TIME_SLICE + 1) * tick_cycles, thread.weight)
}

// eevdf_place puts a thread that is not in the list, and does not run on
// the processor of the queue, at V minus its lag, scaled by (W + w) / W so
// that V does not move when the thread joins. w is the weight that the
// lag was taken with: the weight of the stop for a woken thread
// (`lag_weight`), not the weight of now, which a write can have changed
// during the wait. A lag of at most 2^40 times at most 2^18 + 2^10: below
// 2^59. Its deadline is one request after.
eevdf_place :: proc "contextless" (queue: ^Run_Queue, home: u32, thread: ^Thread, lag: i64, lag_weight: u32) {
	average, total := eevdf_average(queue, home)
	scaled := lag
	if total != 0 {
		scaled = lag * (total + i64(lag_weight)) / total
	}
	thread.virtual = average - u64(scaled)
	thread.virtual_deadline = thread.virtual + eevdf_slice(thread)
	thread.placed = true
}

// eevdf_lag gives the lag that a thread of a queue keeps: V minus its
// virtual time, where V counts the thread with its weight. The thread is
// in the list or runs on the processor of the queue. With W the weights
// of the other threads and w its own, that lag is the average of the
// others minus its virtual time, times W / (W + w): it is computed in
// that form, so that the budget of the thread is never read (the average
// does not count a thread of the list whose budget has no time left) and
// a thread that a stop takes from the list has the lag of a thread that
// leaves its processor. With no other thread the lag is 0.
//
// What the thread is owed is cut to the bound of its values; what it owes
// to eevdf_owing_bound. The difference is clamped as the keys of the
// average are (2^44) and the weights sum to at most 2^18: the product is
// at most 2^62.
eevdf_lag :: proc "contextless" (queue: ^Run_Queue, home: u32, thread: ^Thread) -> i64 {
	average, others := eevdf_average(queue, home, thread)
	if others == 0 {
		return 0
	}
	against_others := clamp(i64(average - thread.virtual), -KEY_LIMIT, KEY_LIMIT)
	lag := against_others * others / (others + i64(thread.weight))
	return clamp(lag, -i64(eevdf_owing_bound(thread)), i64(eevdf_bound(thread)))
}

eevdf_ready :: proc "contextless" (queue: ^Run_Queue, home: u32, thread: ^Thread, kind: Ready_Kind) {
	switch {
	case !thread.placed || kind == .New:
		eevdf_place(queue, home, thread, 0, thread.weight)
	case kind == .Woken:
		eevdf_place(queue, home, thread, thread.lag, u32(thread.lag_weight))
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

// A thread that waits keeps its lag, and the weight that the lag was taken
// with. The thread still runs on its home, or is still in the list
// (strategy_leaves_list).
eevdf_stopping :: proc "contextless" (queue: ^Run_Queue, cpu: ^Processor, thread: ^Thread, cycles: u64, waits: bool) {
	charge(thread, cycles)
	if waits {
		thread.lag = eevdf_lag(queue, cpu.index, thread)
		thread.lag_weight = u16(thread.weight)
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

// A move keeps the lag: the one of the old queue (the thread is still in
// its list), then a place in the new one, both with the weight of now.
eevdf_move :: proc "contextless" (from: ^Run_Queue, from_home: u32, to: ^Run_Queue, to_home: u32, thread: ^Thread) {
	eevdf_place(to, to_home, thread, eevdf_lag(from, from_home, thread), thread.weight)
}
