package kernel

import "base:intrinsics"
import op "contract:operation"

// The locks of the kernel (docs/ARCHITECTURE.md, "Locks of the kernel").
//
// A lock is a ticket lock: a processor takes the next ticket and waits until
// the lock serves it. So processors get a lock in the order that they asked
// for it, and none waits for ever while others take it again and again.
// Interrupts are off in the kernel: a processor never takes a lock again
// from an interrupt. While it waits, it answers processor_sync.
//
// The kind of a lock is its place in the lock order: a processor takes a
// lock only if it holds no lock of a later kind. Each processor counts its
// takes and its waits for each kind; System_Report gives the sums.

TEST_BUILD_CHECKS_LOCK_ORDER :: #config(TEST_BUILD_CHECKS_LOCK_ORDER, true)

Lock :: struct {
	next:    u32, // The next ticket.
	serving: u32, // The ticket that holds the lock.
}

// Before the first processor has its record, the kernel runs on one
// processor, with no gs register: a lock is not taken.
lock_ready: bool

// lock_take waits for the lock, then holds it.
lock_take :: proc "contextless" (lock: ^Lock, kind: op.Lock_Kind) {
	if !lock_ready {
		return
	}
	cpu := processor_self()
	when TEST_BUILD_CHECKS_LOCK_ORDER {
		lock_order_check(cpu, kind)
	}
	ticket := intrinsics.atomic_add(&lock.next, 1)
	count := &cpu.lock_counts[int(kind)]
	count.takes += 1
	if intrinsics.atomic_load(&lock.serving) != ticket {
		count.waits += 1
		for intrinsics.atomic_load(&lock.serving) != ticket {
			sync_acknowledge(cpu)
			intrinsics.cpu_relax()
		}
	}
	cpu.held[kind] += 1
}

// lock_free gives the lock to the next ticket.
lock_free :: proc "contextless" (lock: ^Lock, kind: op.Lock_Kind) {
	if !lock_ready {
		return
	}
	cpu := processor_self()
	cpu.held[kind] -= 1
	intrinsics.atomic_add(&lock.serving, 1)
}

// lock_held says if the processor that runs it holds a lock of this kind.
lock_held :: proc "contextless" (kind: op.Lock_Kind) -> bool {
	return processor_self().held[kind] != 0
}

// Two locks of one kind at one time: the order of ARCHITECTURE.md permits it
// for program locks under the control lock, and for run locks in the order
// of the processors (see queue_move).
@(private = "file")
lock_order_check :: proc "contextless" (cpu: ^Processor, kind: op.Lock_Kind) {
	for other in op.Lock_Kind {
		if other > kind && cpu.held[other] != 0 {
			lock_order_broken(kind, other)
		}
	}
	if cpu.held[kind] != 0 && kind != .Run && !(kind == .Program && cpu.held[.Control] != 0) {
		lock_order_broken(kind, kind)
	}
}

@(private = "file")
lock_order_broken :: proc "contextless" (taken, held: op.Lock_Kind) -> ! {
	intrinsics.atomic_store(&log_serial_only, true)
	log("kernel: the lock order is broken: a lock ", op.LOCK_KIND_NAMES[taken], " was taken while a lock ", op.LOCK_KIND_NAMES[held], " is held")
	machine_stop(3)
}

// lock_counts_sum gives the counts of all the processors.
lock_counts_sum :: proc "contextless" () -> (sum: [op.LOCK_KIND_CAPACITY]op.Lock_Count) {
	for cpu in processors[:processor_count] {
		for &count, kind in sum {
			count.takes += intrinsics.volatile_load(&cpu.lock_counts[kind].takes)
			count.waits += intrinsics.volatile_load(&cpu.lock_counts[kind].waits)
		}
	}
	return sum
}

// The control lock (docs/ARCHITECTURE.md, "Locks of the kernel"). A close
// under it can end the last handle to a program: the stop of that program
// waits in `stops_pending` until control_unlock, so that a stop never runs
// inside the program locks of the path that closed the handle.
control_lock: Lock
stops_pending: u64 // Bit n: program n has no handle. Control lock.

control_take :: proc "contextless" () {
	lock_take(&control_lock, .Control)
}

control_free :: proc "contextless" () {
	for stops_pending != 0 {
		index := u32(intrinsics.count_trailing_zeros(stops_pending))
		stops_pending &~= 1 << index
		program := &programs[index]
		if intrinsics.atomic_load(&program.references) != 0 {
			continue
		}
		if program.state == .Stopped {
			program_free(program) // Only after the cleanup; else the cleanup frees it.
		} else if program.state != .None {
			program_stop(index, op.STOP_CODE_NO_HANDLE)
		}
	}
	lock_free(&control_lock, .Control)
}

// The lock of each program. It is out of the program record: a new program
// in a slot does not reset it.
program_locks: [PROGRAM_CAPACITY]Lock

// program_lock takes the lock of a program, unless this processor holds it
// already. true: this call took it; give it to program_unlock.
program_lock :: proc "contextless" (index: u32) -> bool {
	cpu := processor_self()
	if cpu.programs_held & (1 << index) != 0 {
		return false
	}
	lock_take(&program_locks[index], .Program)
	cpu.programs_held |= 1 << index
	return true
}

program_unlock :: proc "contextless" (index: u32, taken: bool) {
	if taken {
		processor_self().programs_held &~= 1 << index
		lock_free(&program_locks[index], .Program)
	}
}
