package kernel

import "base:intrinsics"

// K3: the scheduler (docs/ARCHITECTURE.md, "Locks of the kernel", "The
// scheduler"). Each processor has a run queue: the threads that are Ready,
// that no processor runs, and whose home is this processor. The run lock of
// a processor protects its queue and the scheduling state of the threads
// whose home it is: state, processor, home and the links of the queue.
//
// The policy is in queue_pick and in schedule_pick: a later step changes
// them (the scheduling strategies).

Run_Queue :: struct #align (64) {
	lock:   Lock,
	head:   u32, // The first thread. 0: the queue is empty.
	tail:   u32,
	count:  u32,
	pushes: u32, // Threads put in the queue since boot: an idle processor sees a new one.
}

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
	intrinsics.atomic_store(&queue.count, queue.count - 1)
}

// queue_pick takes the first thread of a queue whose budget has processor
// time in this period. The caller holds the run lock. 0: none.
queue_pick :: proc "contextless" (home: u32) -> u32 {
	for index := run_queues[home].head; index != 0; index = threads[index].queue_next {
		thread := &threads[index]
		if !budget_spent(thread.budget) {
			queue_remove(thread)
			return index
		}
	}
	return 0
}

// queue_move takes a thread from the queue of another processor, and makes
// this processor its home. The two run locks are taken in the order of the
// processors. 0: none.
queue_move :: proc "contextless" (from: u32, to: u32) -> u32 {
	first, second := min(from, to), max(from, to)
	lock_take(&run_queues[first].lock, .Run)
	lock_take(&run_queues[second].lock, .Run)
	index := queue_pick(from)
	if index != 0 {
		intrinsics.atomic_store(&threads[index].home, to)
	}
	lock_free(&run_queues[second].lock, .Run)
	lock_free(&run_queues[first].lock, .Run)
	return index
}

// longest_queue gives the other processor with the most threads in its
// queue, and that count. It reads the counts with no lock: a hint.
longest_queue :: proc "contextless" (cpu: ^Processor) -> (longest: u32, count: u32) {
	for other in processors[:processor_count] {
		if other == cpu {
			continue
		}
		if waiting := intrinsics.atomic_load(&run_queues[other.index].count); waiting > count {
			longest, count = other.index, waiting
		}
	}
	return longest, count
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
// thread.
kick :: proc "contextless" (home: u32) {
	target := processors[home]
	if intrinsics.atomic_exchange(&target.idle, false) {
		apic_send(target.apic_id, VECTOR_WAKE)
		return
	}
	for cpu in processors[:processor_count] {
		if intrinsics.atomic_exchange(&cpu.idle, false) {
			apic_send(cpu.apic_id, VECTOR_WAKE)
			return
		}
	}
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
// leftovers. The caller holds the run lock of the home. true: the thread is
// in the queue now.
thread_ready_held :: proc "contextless" (thread: ^Thread) -> bool {
	thread.state = .Ready
	intrinsics.atomic_store(&thread.deadline, 0)
	intrinsics.atomic_add(&thread.wait_serial, 1)
	if thread.processor == 0 {
		queue_push(thread)
		return true
	}
	return false
}

// thread_wake ends the wait of a thread that waits. With a time, only a
// wait whose deadline is not after it ends. true: the thread waited.
thread_wake :: proc "contextless" (thread: ^Thread, deadline_before := max(u64)) -> bool {
	home := run_lock(thread)
	woken := thread.state == .Waiting && thread.deadline <= deadline_before
	queued := woken && thread_ready_held(thread)
	run_unlock(home)
	if queued {
		kick(home)
	}
	return woken
}

// thread_queue puts a new thread in the queue of the processor that runs
// this code.
thread_queue :: proc "contextless" (thread: ^Thread) {
	home := processor_self().index
	intrinsics.atomic_store(&thread.home, home)
	lock_take(&run_queues[home].lock, .Run)
	queue_push(thread)
	lock_free(&run_queues[home].lock, .Run)
	kick(home)
}

// schedule_pick takes the next thread for a processor: from its own queue,
// or from the longest queue when its own queue is empty or shorter by 2.
// 0: none.
schedule_pick :: proc "contextless" (cpu: ^Processor) -> u32 {
	own := intrinsics.atomic_load(&run_queues[cpu.index].count)
	if longest, count := longest_queue(cpu); count != 0 && (own == 0 || count >= own + 2) {
		if index := queue_move(longest, cpu.index); index != 0 {
			return index
		}
	}
	lock_take(&run_queues[cpu.index].lock, .Run)
	index := queue_pick(cpu.index)
	lock_free(&run_queues[cpu.index].lock, .Run)
	return index
}

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
// processor waits for an interrupt. The caller holds the kernel lock.
schedule :: proc "contextless" () -> ! {
	cpu := processor_self()
	budget_charge(cpu)
	if cpu.current != 0 {
		thread := &threads[cpu.current]
		home := run_lock(thread)
		thread.processor = 0
		if thread.state == .Ready {
			queue_push(thread)
		}
		cpu.current = 0
		run_unlock(home)
	}
	for {
		// A thread that a queue receives after this read is seen below.
		pushes := queue_pushes()
		if index := schedule_pick(cpu); index != 0 {
			thread := &threads[index]
			lock_take(&run_queues[cpu.index].lock, .Run)
			thread.processor = cpu.index + 1
			cpu.current = index
			lock_free(&run_queues[cpu.index].lock, .Run)
			cpu.charged_from = cycles_now()
			cpu.slice_left = TIME_SLICE
			run(cpu, thread)
		}
		if !threads_alive() {
			log("kernel: no program is left")
			machine_stop(0)
		}
		// Idle: a processor that makes a thread ready sees the flag and sends
		// an interrupt. The flag is set before the last look at the queues.
		// A queue can keep threads whose budget has no time in this period:
		// the start of the next period wakes the idle processors (kick_all).
		intrinsics.atomic_store(&cpu.idle, true)
		if queue_pushes() != pushes {
			intrinsics.atomic_store(&cpu.idle, false)
			continue
		}
		if cpu.index != 0 {
			timer_pause(true)
		}
		lock_release(cpu)
		idle_wait()
		lock_acquire(cpu)
		intrinsics.atomic_store(&cpu.idle, false)
		if cpu.index != 0 {
			timer_pause(false)
		}
	}
}

// run gives the processor to its current thread, and frees the kernel lock.
run :: proc "contextless" (cpu: ^Processor, thread: ^Thread) -> ! {
	program := &programs[thread.program]
	ports_switch(cpu, program.has_ports ? thread.program : 0)
	if cpu.table != program.table {
		intrinsics.atomic_store(&cpu.table, program.table)
		cr3_write(program.table)
	}
	// Two programs have thread records at the same address. The test is on
	// the thread, so a program that changes its gs register harms only itself.
	if cpu.record_thread != cpu.current {
		cpu.record_thread = cpu.current
		msr_write(MSR_KERNEL_GS_BASE, thread.record)
	}
	cpu.fpu_area = &thread.fpu
	if thread.in_enter {
		thread.in_enter = false
		thread.frame.rax = intrinsics.atomic_load(&ticks)
	}
	lock_release(cpu)
	resume(&thread.frame)
}
