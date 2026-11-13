package kernel

import "base:intrinsics"
import op "contract:operation"

// The scheduling strategies (docs/SCHEDULING.md). A strategy is six
// procedures over the data of one run queue. The generic code of
// schedule.odin keeps the list of each queue, the run locks, the balance
// between processors and the budgets; a strategy decides only the order.
//
// The generic code calls a procedure of the strategy of a queue through one
// of the six queue_strategy procedures below: a switch on the strategy of
// the queue, with a direct call in each case. The strategies are a closed
// set that the kernel contains, so no address of a procedure is read from
// memory on these paths, and the compiler can put a strategy procedure in
// the place of its call.
//
// The state of a strategy is in fixed fields: in the thread record (the
// hot line: virtual, virtual_deadline, lag, placed) and in the run queue
// (virtual, weight). Zero is valid in each field for each strategy: a
// thread that is not placed is placed by `ready` with the kind New.
//
// Each procedure runs under the run lock of the queue that it receives.
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

// A switch below names each member of the enumeration, with no default
// case: a new strategy does not build until each of the six has its call.
// A queue with no strategy runs as round robin.

// queue_strategy_ready: a thread becomes ready in the queue of its home. It
// is not yet in the list: the generic code puts it at the end after this
// call.
queue_strategy_ready :: #force_inline proc "contextless" (queue: ^Run_Queue, home: u32, thread: ^Thread, kind: Ready_Kind) {
	switch queue.strategy {
	case .None, .Round_Robin:
		round_robin_ready(queue, home, thread, kind)
	case .Fair:
		fair_ready(queue, home, thread, kind)
	case .Eevdf:
		eevdf_ready(queue, home, thread, kind)
	}
}

// queue_strategy_pick gives the next thread of a queue, among the threads
// that a budget lets run, or nil. The generic code takes it out of the list.
queue_strategy_pick :: #force_inline proc "contextless" (queue: ^Run_Queue, home: u32) -> (picked: ^Thread) {
	switch queue.strategy {
	case .None, .Round_Robin:
		picked = round_robin_pick(queue, home)
	case .Fair:
		picked = fair_pick(queue, home)
	case .Eevdf:
		picked = eevdf_pick(queue, home)
	}
	return
}

// queue_strategy_tick: the tick on the processor that runs the thread:
// cycles is the time since the last charge. true: the turn ends.
queue_strategy_tick :: #force_inline proc "contextless" (queue: ^Run_Queue, cpu: ^Processor, thread: ^Thread, cycles: u64) -> (turn_ends: bool) {
	switch queue.strategy {
	case .None, .Round_Robin:
		turn_ends = round_robin_tick(queue, cpu, thread, cycles)
	case .Fair:
		turn_ends = fair_tick(queue, cpu, thread, cycles)
	case .Eevdf:
		turn_ends = eevdf_tick(queue, cpu, thread, cycles)
	}
	return
}

// queue_strategy_stopping: the thread leaves its processor: cycles since
// the last charge. waits: it waits, or it ends; else it goes back to the
// queue (ready, Back).
queue_strategy_stopping :: #force_inline proc "contextless" (queue: ^Run_Queue, cpu: ^Processor, thread: ^Thread, cycles: u64, waits: bool) {
	switch queue.strategy {
	case .None, .Round_Robin:
		round_robin_stopping(queue, cpu, thread, cycles, waits)
	case .Fair:
		fair_stopping(queue, cpu, thread, cycles, waits)
	case .Eevdf:
		eevdf_stopping(queue, cpu, thread, cycles, waits)
	}
}

// queue_strategy_wake_preempts: a thread woke in the queue (it is in the
// list now) while `running` runs on the processor of the queue. true: the
// turn of running ends.
queue_strategy_wake_preempts :: #force_inline proc "contextless" (queue: ^Run_Queue, home: u32, running: ^Thread, woken: ^Thread) -> (turn_ends: bool) {
	switch queue.strategy {
	case .None, .Round_Robin:
		turn_ends = round_robin_wake_preempts(queue, home, running, woken)
	case .Fair:
		turn_ends = fair_wake_preempts(queue, home, running, woken)
	case .Eevdf:
		turn_ends = eevdf_wake_preempts(queue, home, running, woken)
	}
	return
}

// queue_strategy_move: a processor takes a thread from the queue `from` to
// run it: its home becomes `to`. The thread is still in the list of `from`.
// The strategy is the one of `from`: the caller moves a thread this way
// only when the two queues have the same strategy.
queue_strategy_move :: #force_inline proc "contextless" (from: ^Run_Queue, from_home: u32, to: ^Run_Queue, to_home: u32, thread: ^Thread) {
	switch from.strategy {
	case .None, .Round_Robin:
		round_robin_move(from, from_home, to, to_home, thread)
	case .Fair:
		fair_move(from, from_home, to, to_home, thread)
	case .Eevdf:
		eevdf_move(from, from_home, to, to_home, thread)
	}
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
		queue_strategy_ready(queue, home, &threads[index], .New)
	}
}

// strategy_clear gives the strategy fields of a thread their zero values.
// The caller holds the run lock of its home.
strategy_clear :: proc "contextless" (thread: ^Thread) {
	thread.virtual = 0
	thread.virtual_deadline = 0
	thread.lag = 0
	thread.placed = false
}

// strategy_weight_raised gives a thread whose weight was raised the zero
// values of its strategy fields, and places it again as a new thread when
// it is in the list: what a change of strategy does to each thread, for
// the same reason. The place of a thread is a history under its old
// weight. A place far from the other threads is harmless at a small
// weight, which moves the average of the queue little; the same place at
// a large weight moves the average far, and the other threads then wait.
// A thread placed as new is at the average: it has no such place. Only
// the holder of the machine raises a weight, so no program gets these
// zero values for its own thread. A thread on a processor is placed at
// its next tick or when it leaves; a thread that waits or that a stop
// holds is placed when it enters the list again. The caller holds the run
// lock of the queue, which is the queue of the home of the thread, and
// wrote the new weight.
//
// A write that lowers a weight or changes a request calls nothing here:
// the fields stay, and the next charge, the next turn and the next bound
// use the new values (docs/SCHEDULING.md, "The schedule of a live
// thread").
strategy_weight_raised :: proc "contextless" (queue: ^Run_Queue, home: u32, thread: ^Thread) {
	strategy_clear(thread)
	if thread.queued {
		queue_strategy_ready(queue, home, thread, .New)
	}
}

// strategy_leaves_list keeps the position of a thread that leaves the list
// of its queue with no turn: a stop of Thread_Control holds it. The thread
// leaves as a thread that starts to wait, with no time to charge, and the
// Resume places it as a woken thread: a thread that owes time still owes
// it after a Stop and a Resume. The caller holds the run lock of the
// queue; the thread is still in the list.
//
// Under EEVDF the lag of a thread that leaves its processor is V minus its
// virtual time, where V counts the thread. A thread of the list is in V
// only while its budget has time. So its lag is taken here from the
// average of the other threads, times W / (W + w), with W their weights
// and w its own: the same value, with no read of its budget. The
// difference is clamped as a key of the average is (2^44), and the
// weights sum to at most 2^18.
strategy_leaves_list :: proc "contextless" (queue: ^Run_Queue, home: u32, thread: ^Thread) {
	if !thread.placed {
		return
	}
	if queue.strategy != .Eevdf {
		queue_strategy_stopping(queue, processors[home], thread, 0, true)
		return
	}
	lag: i64
	if average, others := eevdf_average(queue, home, thread); others != 0 {
		lag = clamp(i64(average - thread.virtual), -KEY_LIMIT, KEY_LIMIT) * others / (others + i64(thread.weight))
	}
	bound := i64(eevdf_bound(thread))
	thread.lag = clamp(lag, -bound, bound)
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
	if !thread.placed {
		queue_strategy_ready(queue, cpu.index, thread, .New)
	}
	ended := queue_strategy_tick(queue, cpu, thread, cycles)
	lock_free(&queue.lock, .Run)
	cpu.slice_left -= min(cpu.slice_left, 1)
	return ended || cpu.slice_left == 0
}

// The round robin: the queue in its order, a time slice of TIME_SLICE
// ticks (strategy_tick), no wake preemption. The behavior of the kernel
// before the strategies. A procedure with an empty body stays, so that each
// strategy has the same six procedures.

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
// other threads of a thread. The keys are clamped (KEY_LIMIT): a product is at
// most 2^54, the sum of 256 threads at most 2^62.
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
