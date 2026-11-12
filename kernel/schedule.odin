package kernel

import "base:intrinsics"
import op "contract:operation"

// K3: the scheduler (docs/ARCHITECTURE.md, "Locks of the kernel", "The
// scheduler"). Each processor has a run queue: the threads that are Ready,
// that no processor runs, and whose home is this processor. The run lock of
// a processor protects its queue and the scheduling state of the threads
// whose home it is: state, processor, home and the links of the queue.
//
// The order of the threads of a queue is the strategy of the queue
// (strategy.odin, docs/SCHEDULING.md): ready, pick, tick, stopping, wake
// preemption and move. This file keeps the lists, the locks and the
// balance between the processors.
//
// A thread that a processor runs belongs to that processor. Another
// processor that ends it sets stop_requested; the processor ends it in
// schedule. A program ends when the last processor that ran one of its
// threads leaves it after a stop (program_leave).

Run_Queue :: struct #align (64) {
	lock:     Lock,
	head:     u32, // The first thread. 0: the queue is empty.
	tail:     u32,
	count:    u32,
	pushes:   u32, // Threads put in the queue since boot: an idle processor sees a new one.
	strategy: op.Strategy, // The strategy whose state the queue and the threads of this home hold.
	weight:   u32, // The sum of the weights of the threads in the list.
	virtual:  u64, // The queue clock: it never goes back (strategy.odin).
}

#assert(size_of(Run_Queue) == 64)

run_queues: [PROCESSOR_CAPACITY]Run_Queue

// run_lock takes the run lock of the home of a thread, and gives the home.
// The home changes only under the run lock of the old home and of the new
// one: after the take, the home is checked again.
run_lock :: proc "contextless" (thread: ^Thread) -> u32 {
	for {
		home := intrinsics.atomic_load(&thread.home)
		lock_take(&run_queues[home].lock, .Run)
		if intrinsics.atomic_load(&thread.home) == home {
			return home
		}
		lock_free(&run_queues[home].lock, .Run)
	}
}

run_unlock :: proc "contextless" (home: u32) {
	lock_free(&run_queues[home].lock, .Run)
}

thread_index :: #force_inline proc "contextless" (thread: ^Thread) -> u32 {
	return u32(intrinsics.ptr_sub(thread, &threads[0]))
}

// queue_push puts a thread at the end of the queue of its home. The caller
// holds the run lock of the home.
queue_push :: proc "contextless" (thread: ^Thread) {
	queue := &run_queues[thread.home]
	index := thread_index(thread)
	thread.queue_next = 0
	thread.queue_previous = queue.tail
	if queue.tail != 0 {
		threads[queue.tail].queue_next = index
	} else {
		queue.head = index
	}
	queue.tail = index
	thread.queued = true
	queue.weight += thread.weight
	intrinsics.atomic_store(&queue.count, queue.count + 1)
	intrinsics.atomic_add(&queue.pushes, 1)
}

// queue_remove takes a thread out of the queue of its home. The caller holds
// the run lock of the home.
queue_remove :: proc "contextless" (thread: ^Thread) {
	if !thread.queued {
		return
	}
	queue := &run_queues[thread.home]
	if thread.queue_previous != 0 {
		threads[thread.queue_previous].queue_next = thread.queue_next
	} else {
		queue.head = thread.queue_next
	}
	if thread.queue_next != 0 {
		threads[thread.queue_next].queue_previous = thread.queue_previous
	} else {
		queue.tail = thread.queue_previous
	}
	thread.queue_next = 0
	thread.queue_previous = 0
	thread.queued = false
	queue.weight -= thread.weight
	intrinsics.atomic_store(&queue.count, queue.count - 1)
}

// queue_ready puts a thread that became ready in the queue of its home,
// placed by the strategy of the queue. The caller holds the run lock of
// the home.
queue_ready :: proc "contextless" (thread: ^Thread, kind: Ready_Kind) {
	queue := &run_queues[thread.home]
	strategy_of(queue).ready(queue, thread.home, thread, kind)
	queue_push(thread)
}

// queue_pick takes the thread that the strategy of a queue picks, among
// the threads whose budget has processor time in this period, and gives it
// to a processor, in the same section: the thread is never Ready in no
// queue and on no processor, where a stop would end it while the processor
// is about to run it. The caller holds the run lock of the queue, and the
// run lock of the processor when it is another one (queue_move): the
// thread changes its home under the two. 0: none.
queue_pick :: proc "contextless" (home: u32, cpu: ^Processor) -> u32 {
	start := cycles_now()
	queue := &run_queues[home]
	thread := strategy_of(queue).pick(queue, home)
	if thread == nil {
		return 0
	}
	index := thread_index(thread)
	if home != cpu.index {
		to := &run_queues[cpu.index]
		if to.strategy == queue.strategy {
			strategy_of(queue).move(queue, home, to, cpu.index, thread)
		} else {
			// During a change of strategy: the fields of the old strategy
			// mean nothing in the new one (strategy_change).
			strategy_clear(thread)
		}
		cpu.moves += 1
	}
	queue_remove(thread)
	intrinsics.atomic_store(&thread.home, cpu.index)
	thread.processor = cpu.index + 1
	intrinsics.atomic_store(&cpu.current, index)
	// A stop that marks this thread sees it on this processor, and
	// counts it in `holds`.
	intrinsics.atomic_add(&programs[thread.program].holds, 1)
	cpu.picks += 1
	cpu.pick_cycles += cycles_now() - start
	return index
}

// queue_move takes a thread from the queue of another processor for this
// processor, which becomes its home. The two run locks are taken in the
// order of the processors. 0: none.
queue_move :: proc "contextless" (from: u32, cpu: ^Processor) -> u32 {
	first, second := min(from, cpu.index), max(from, cpu.index)
	lock_take(&run_queues[first].lock, .Run)
	lock_take(&run_queues[second].lock, .Run)
	index := queue_pick(from, cpu)
	lock_free(&run_queues[second].lock, .Run)
	lock_free(&run_queues[first].lock, .Run)
	return index
}

// busiest_queue gives the other processor with the highest load (the
// threads that wait in its queue, plus 1 if it runs a thread) that has a
// thread in its queue, and that load. It reads with no lock: a hint.
busiest_queue :: proc "contextless" (cpu: ^Processor) -> (busiest: u32, load: u32) {
	for other in processors[:processor_count] {
		if other == cpu {
			continue
		}
		waiting := intrinsics.atomic_load(&run_queues[other.index].count)
		if waiting == 0 {
			continue
		}
		other_load := waiting + (intrinsics.atomic_load(&other.current) != 0 ? 1 : 0)
		if other_load > load {
			busiest, load = other.index, other_load
		}
	}
	return busiest, load
}

// queue_pushes gives the sum of the pushes of all the queues.
queue_pushes :: proc "contextless" () -> (sum: u32) {
	for cpu in processors[:processor_count] {
		sum += intrinsics.atomic_load(&run_queues[cpu.index].pushes)
	}
	return sum
}

// kick makes a processor look at the queues: the home of a thread that
// became ready if it is idle, else another idle processor, which takes the
// thread. With no idle processor, a thread that preempts (the strategy of
// its home said so, under its run lock) ends the turn of the thread that
// runs on its home: on this processor at once, on another one by `preempt`
// and an interrupt (the case VECTOR_WAKE of kernel_interrupt). The thread
// that runs there can have changed since the decision: then the turn of
// another thread ends, which costs one pass through schedule.
kick :: proc "contextless" (home: u32, preempts := false) {
	target := processors[home]
	if intrinsics.atomic_exchange(&target.idle, false) {
		apic_send(target.apic_id, VECTOR_WAKE)
		return
	}
	// The idle processor that the waker wakes gets the queue of the thread
	// as a hint (look_first), after the exchange of `idle` and before the
	// interrupt: the idle protocol (push, then exchange) does not change.
	// If the processor woke by itself (it saw `pushes` change) before the
	// store, it picks as before, and the hint stays for its next pick,
	// where it serves only if that queue has a thread. Two wakers cannot
	// win the exchange of one idle processor; a hint that a later one
	// replaces before the pick is lost, and the pick is the one of before
	// (the busiest queue).
	for cpu in processors[:processor_count] {
		if intrinsics.atomic_exchange(&cpu.idle, false) {
			intrinsics.atomic_store(&cpu.look_first, home + 1)
			apic_send(cpu.apic_id, VECTOR_WAKE)
			return
		}
	}
	if !preempts {
		return
	}
	if self := processor_self(); target == self {
		if self.current != 0 {
			self.slice_left = 0
			self.preemptions += 1
		}
		return
	}
	intrinsics.atomic_store(&target.preempt, true)
	apic_send(target.apic_id, VECTOR_WAKE)
}

// kick_all makes each idle processor look at the queues.
kick_all :: proc "contextless" () {
	for cpu in processors[:processor_count] {
		if intrinsics.atomic_exchange(&cpu.idle, false) {
			apic_send(cpu.apic_id, VECTOR_WAKE)
		}
	}
}

// thread_ready_held ends the wait of a thread: it becomes Ready, in the
// queue of its home if no processor runs it. The entries of its wait become
// leftovers. The caller holds the run lock of the home. queued: the thread
// is in the queue now. preempts: the strategy of the queue says that it
// preempts the thread that runs on its home.
thread_ready_held :: proc "contextless" (thread: ^Thread) -> (queued: bool, preempts: bool) {
	thread.state = .Ready
	intrinsics.atomic_store(&thread.deadline, 0)
	intrinsics.atomic_add(&thread.wait_serial, 1)
	if thread.processor != 0 {
		return false, false
	}
	queue_ready(thread, .Woken)
	queue := &run_queues[thread.home]
	home := processors[thread.home]
	if running := home.current; running != 0 {
		// At most one wake preemption of a processor in each millisecond
		// by a thread of another program (P20): the interrupt and the pass
		// through schedule are paid by the thread that runs there. A
		// thread of the same program preempts with no limit: its program
		// pays. With no preemption the woken thread waits at most for a
		// tick, where its strategy ends the turn when it says so.
		other := threads[running].program != thread.program
		now := intrinsics.atomic_load(&time_milliseconds) + 1
		if !other || home.preempted_at != now {
			preempts = strategy_of(queue).wake_preempts(queue, thread.home, &threads[running], thread)
			if preempts && other {
				home.preempted_at = now
			}
		}
	}
	return true, preempts
}

// thread_wake ends the wait of a thread that waits. With a time, only a
// wait whose deadline is not after it ends. true: the thread waited.
thread_wake :: proc "contextless" (thread: ^Thread, deadline_before := max(u64)) -> bool {
	home := run_lock(thread)
	woken := thread.state == .Waiting && thread.deadline <= deadline_before
	queued, preempts: bool
	if woken {
		queued, preempts = thread_ready_held(thread)
	}
	run_unlock(home)
	if queued {
		kick(home, preempts)
	}
	return woken
}

// thread_queue puts a new thread in the queue of the processor that runs
// this code.
thread_queue :: proc "contextless" (thread: ^Thread) {
	home := processor_self().index
	lock_take(&run_queues[home].lock, .Run)
	// The home changes under the run lock of the new home: a change of
	// strategy that visits the old home does not count this thread
	// (strategy_change skips a thread that is Ready, in no list and on no
	// processor).
	intrinsics.atomic_store(&thread.home, home)
	queue_ready(thread, .New)
	lock_free(&run_queues[home].lock, .Run)
	kick(home)
}

// schedule_pick takes the next thread for a processor that runs no thread,
// and gives it to the processor (queue_pick)
// now: from the busiest other queue when its load is above the threads
// that wait in the own queue, else from the own queue. So the threads that
// are ready move to the processors that have less, and each one gets its
// turn on all the processors, as with one queue. 0: none.
schedule_pick :: proc "contextless" (cpu: ^Processor) -> u32 {
	// The queue of a thread that woke this processor from idle (kick).
	if hint := intrinsics.atomic_exchange(&cpu.look_first, 0); hint != 0 && hint - 1 != cpu.index && intrinsics.atomic_load(&run_queues[hint - 1].count) != 0 {
		if index := queue_move(hint - 1, cpu); index != 0 {
			return index
		}
	}
	own := intrinsics.atomic_load(&run_queues[cpu.index].count)
	if busiest, load := busiest_queue(cpu); load > own {
		if index := queue_move(busiest, cpu); index != 0 {
			return index
		}
	}
	lock_take(&run_queues[cpu.index].lock, .Run)
	index := queue_pick(cpu.index, cpu)
	lock_free(&run_queues[cpu.index].lock, .Run)
	return index
}

// root_started: the first thread exists. Before, a processor that the
// first processor started finds no thread, and waits.
root_started: bool

// threads_alive says if a thread exists that is not stopped.
threads_alive :: proc "contextless" () -> bool {
	for &thread in threads[1:] {
		if state := intrinsics.atomic_load(&thread.state); state != .None && state != .Stopped {
			return true
		}
	}
	return false
}

// schedule leaves the current thread and runs the next one. With none, the
// processor waits for an interrupt. The caller holds no lock.
schedule :: proc "contextless" () -> ! {
	cpu := processor_self()
	spent := budget_charge(cpu)
	// The thread that this processor leaves, for the record of a switch.
	left_program, left_number: u32
	if cpu.current != 0 {
		index := cpu.current
		thread := &threads[index]
		left_program, left_number = thread.program, thread.number
		// The x87, SSE and AVX registers of the thread are still live: no
		// code of the kernel changed them since the thread entered. They
		// go to its area now, before any other processor can take the
		// thread: a thread on a processor is in no queue, and it reaches
		// one only below (queue_ready), or through a wake after its
		// processor is 0. The release of the run lock orders this save
		// before the restore of the processor that takes it.
		extended_state_save(&thread.extended_state, extended_state_form)
		program := thread.program
		home := run_lock(thread)
		ended := intrinsics.atomic_load(&thread.stop_requested)
		// The strategy sees the thread while it is still the current
		// thread of its home: the last part of its turn, and its lag.
		queue := &run_queues[home]
		strategy := strategy_of(queue)
		if !thread.placed {
			strategy.ready(queue, home, thread, .New)
		}
		strategy.stopping(queue, cpu, thread, spent, ended || thread.state != .Ready)
		intrinsics.atomic_store(&thread.processor, 0)
		// The slot of an ended thread can serve a new thread before this
		// processor gets the control lock: the serial names this thread.
		serial := thread.serial
		if ended {
			// This processor owns the thread: it ends it (thread_stop,
			// program_stop).
			thread.state = .Stopped
			intrinsics.atomic_add(&thread.wait_serial, 1)
		} else if thread.state == .Ready {
			queue_ready(thread, .Back)
		}
		intrinsics.atomic_store(&cpu.current, 0)
		run_unlock(home)
		cleanup := program_leave(program)
		if ended || cleanup {
			control_take()
			if ended {
				thread_finish(index, serial)
			}
			if cleanup {
				program_cleanup(program)
			}
			control_free()
		}
	}
	for {
		// A thread that a queue receives after this read is seen below.
		pushes := queue_pushes()
		if index := schedule_pick(cpu); index != 0 {
			thread := &threads[index]
			cpu.charged_from = cycles_now()
			cpu.turn_start = cpu.charged_from
			cpu.slice_left = TIME_SLICE
			// The registers of this processor hold the thread that it left,
			// or nothing of use: the area of the thread that it takes is
			// complete (saved where it left, or the start state of a new
			// thread). Also when it takes the thread that it left just now:
			// a restore then costs a little, and keeps no rule of who owns
			// the registers.
			extended_state_restore(&thread.extended_state, extended_state_form)
			// The event point of a switch of threads (events.odin). The
			// thread is the current thread of this processor now.
			if event_observed(cpu, OBSERVED_SWITCH) {
				event_record(cpu, .Switch, thread.program, thread.number, 0, u64(left_program), u64(left_number))
			}
			run(cpu, thread)
		}
		// No thread was taken: the next one follows the idle wait.
		left_program, left_number = 0, 0
		if intrinsics.atomic_load(&root_started) && !threads_alive() {
			log("kernel: no program is left")
			machine_stop(0)
		}
		// Idle: a processor that makes a thread ready sees the flag and sends
		// an interrupt. The flag is set before the last look at the queues.
		// A queue can keep threads whose budget has no time in this period:
		// the start of the next period wakes the idle processors (kick_all).
		cpu.preempt_from = 0 // No next thread: the preemption that ended the last turn is not counted.
		intrinsics.atomic_store(&cpu.idle, true)
		if queue_pushes() != pushes {
			intrinsics.atomic_store(&cpu.idle, false)
			continue
		}
		if cpu.index != 0 {
			timer_pause(true)
		}
		idle_wait()
		intrinsics.atomic_store(&cpu.idle, false)
		if cpu.index != 0 {
			timer_pause(false)
		}
	}
}

// run gives the processor to its current thread. The program of the
// thread stays while the thread is on this processor (`holds`). The
// registers of the extended state of the thread are live already: a
// thread that continues after an entry kept them, and schedule restored a
// thread that it took from a queue.
run :: proc "contextless" (cpu: ^Processor, thread: ^Thread) -> ! {
	// The one place before each return to a program: a frame that the
	// processor would refuse stops the program here, as its own fault.
	if refusal, value := return_frame_prepare(&thread.frame); refusal != .None {
		program_return_refused(thread, refusal, value, 0)
		schedule_on_a_fresh_stack(cpu)
	}
	if cpu.preempt_from != 0 {
		cpu.preempt_cycles += cycles_now() - cpu.preempt_from
		cpu.interrupt_preemptions += 1
		cpu.preempt_from = 0
	}
	program := &programs[thread.program]
	ports_switch(cpu, intrinsics.atomic_load(&program.has_ports) ? thread.program : 0)
	if cpu.table != program.table {
		// The store comes before the load of the table: an unmap that does
		// not see it cleared its entries before this load.
		intrinsics.atomic_store(&cpu.table, program.table)
		control_register_3_write(program.table)
	}
	// Two programs have thread records at the same address. The test is on
	// the thread, so a program that changes its gs register harms only itself.
	if cpu.record_thread != cpu.current || cpu.record_serial != thread.serial {
		cpu.record_thread = cpu.current
		cpu.record_serial = thread.serial
		model_specific_register_write(MSR_KERNEL_GS_BASE, thread.record)
	}
	if thread.in_enter {
		thread.in_enter = false
		thread.frame.rax = intrinsics.atomic_load(&time_milliseconds)
	}
	resume(&thread.frame)
}
