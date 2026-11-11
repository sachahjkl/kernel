package kernel

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
	.Fair        = ROUND_ROBIN,
	.Eevdf       = ROUND_ROBIN,
}

// The strategy at boot.
STRATEGY_START :: op.Strategy.Round_Robin

// The strategy that the machine has: Strategy_Set writes it. Each queue has
// its own word (Run_Queue.strategy), which changes under its run lock.
strategy_chosen: op.Strategy
strategy_changes: u64

// strategy_start gives each run queue the strategy of the boot, before the
// first thread.
strategy_start :: proc "contextless" () {
	strategy_chosen = STRATEGY_START
	for &queue in run_queues {
		queue.strategy = STRATEGY_START
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

// strategy_tick charges the time of the thread that runs on this processor
// to its strategy, under the run lock of the processor: the home of a
// thread that runs is its processor. true: the turn ends.
strategy_tick :: proc "contextless" (cpu: ^Processor, thread: ^Thread, cycles: u64) -> bool {
	queue := &run_queues[cpu.index]
	lock_take(&queue.lock, .Run)
	strategy := strategy_of(queue)
	if !thread.placed {
		strategy.ready(queue, cpu.index, thread, .New)
	}
	ended := strategy.tick(queue, cpu, thread, cycles)
	lock_free(&queue.lock, .Run)
	return ended
}

// The round robin: the queue in its order, a time slice of TIME_SLICE
// ticks, no wake preemption. The behavior of the kernel before the
// strategies.
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
	cpu.slice_left -= min(cpu.slice_left, 1)
	return cpu.slice_left == 0
}

round_robin_stopping :: proc "contextless" (queue: ^Run_Queue, cpu: ^Processor, thread: ^Thread, cycles: u64, waits: bool) {}

round_robin_wake_preempts :: proc "contextless" (queue: ^Run_Queue, home: u32, running: ^Thread, woken: ^Thread) -> bool {
	return false
}

round_robin_move :: proc "contextless" (from: ^Run_Queue, from_home: u32, to: ^Run_Queue, to_home: u32, thread: ^Thread) {}

