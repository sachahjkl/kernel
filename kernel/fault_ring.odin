package kernel

import "base:intrinsics"
import op "contract:operation"

// The fault ring (docs/ARCHITECTURE.md, "The fault ring"). A program names
// one of its threads as its fault handler (Fault_Handler_Set). A page fault
// of another thread of the program, which would stop the program, becomes a
// record in the thread record of the handler; the faulting thread waits; a
// thread of the program repairs (Memory_Commit, Memory_Protect) and answers
// (Fault_Answer): Resume runs the faulting instruction again, Stop stops
// the program with the report of the fault, as with no handler.
//
// The states of a faulting thread, each change under the locks named:
// - running -> waiting for an answer (fault_deliver): under the program
//   lock and the run lock of its home, the thread becomes Waiting with no
//   deadline and fault_waits true, before its record is published. It is
//   still on its processor, so kernel_interrupt then calls schedule, which
//   saves its extended state as for any thread that leaves a processor.
// - waiting -> ready (Fault_Answer Resume): under the program lock,
//   fault_waits becomes false, then thread_wake makes it Ready under the run
//   lock, as the end of a word wait does. run checks its frame at the
//   return (return_frame_prepare), as each return.
// - waiting -> stopped (Fault_Answer Stop, a stop of the program, the end of
//   the handler): program_stop ends each thread of the program, a waiting
//   one as any thread that is on no processor.
// A waiting thread holds nothing but its thread: no record of the kernel,
// no lock, no page.
//
// A thread that waits for an answer is in no table of words, and only
// Fault_Answer, the end of the ring (its handler ends, or Fault_Handler_Set
// while it waits) or the stop of its program ends its wait.
//
// The record names the faulting thread by its number and by the serial of
// the fault: a count of the program (Program.fault_serial), not the serial
// of the kernel's thread slot, which all programs share and which would
// tell a program how many threads others made in that slot.

// fault_deliver gives a page fault of the current thread of this processor
// to the fault ring of its program. true: the record is written and the
// thread waits for an answer. false: the fault stops the program, as with no
// handler. The caller holds no lock.
fault_deliver :: proc "contextless" (thread_index: u32, address: u64) -> bool {
	// The thread areas, the time page and the kernel half are not served: a
	// handler cannot repair them, and the records of the ring are in a
	// thread area.
	if address >= op.THREAD_AREA_BASE {
		return false
	}
	thread := &threads[thread_index]
	program_index := thread.program
	program := &programs[program_index]
	taken := program_lock(program_index)
	defer program_unlock(program_index, taken)
	handler_index := program.fault_handler
	// A fault of the handler itself is not delivered: no fault of a fault.
	if handler_index == 0 || handler_index == thread_index || program.state == .Stopped {
		return false
	}
	handler := &threads[handler_index]
	// The handler of the program is a live thread of the program: thread_finish
	// clears fault_handler under this lock before it unmaps the record.
	record := handler.record_in_kernel
	if handler.program != program_index || handler.serial != program.fault_handler_serial || record == nil {
		return false
	}
	// fault_read is memory of the program: any value. The kernel indexes
	// with its own count, so it never writes outside fault_records. A
	// difference that is not below the capacity is full. A false fault_read
	// harms only its program: a value above the count makes the ring full,
	// and a value a little below the count lets the kernel write over
	// records that the program did not read yet.
	read := intrinsics.atomic_load(&record.fault_read)
	if program.fault_written - read >= op.FAULT_RECORD_CAPACITY {
		program.fault_full += 1
		intrinsics.volatile_store(&record.fault_full, program.fault_full)
		log_in("fault", .Warning, "kernel: program ", program_name(program), ": the fault ring is full (", u64(program.fault_full), " times): the fault stops the program")
		return false
	}
	// The entries of an earlier word wait stay in the table of words until
	// the next kernel entry of the thread (wait_begin), and a fault is not
	// one: a word_wake, a decommit or a revocation would end this wait
	// through them, with no answer. The thread leaves the table here. Its
	// processor owns it (it is the current thread), and the wait locks come
	// after the program lock.
	wait_unregister(thread)
	thread.woken = false
	program.fault_serial += 1
	// The thread waits before its record is published: an answer reads the
	// record first, so it finds the thread waiting.
	home := run_lock(thread)
	thread.state = .Waiting
	intrinsics.atomic_store(&thread.deadline, op.WAIT_FOREVER)
	thread.fault_waits = true
	thread.fault_serial = program.fault_serial
	thread.fault_address = address
	run_unlock(home)
	record.fault_records[program.fault_written % op.FAULT_RECORD_CAPACITY] = {
		thread      = u64(thread.number),
		serial      = program.fault_serial,
		address     = address,
		access      = thread.frame.error & 0b10011, // Present, Write, Execute: the bits of Fault_Access.
		instruction = thread.frame.rip,
	}
	program.fault_written += 1
	// The record is written before the count that publishes it.
	intrinsics.atomic_store(&record.fault_written, program.fault_written)
	word_wake(physical_of(&record.fault_written), max(u64))
	return true
}

// fault_handler_set makes a thread of the program its fault handler, with
// an empty ring, or ends the delivery (handler_index 0). The ring of the
// old handler ends either way: a thread that waits then has a record that
// no thread will read, so the program stops as at the end of the handler
// thread. The caller holds the program lock (execute).
fault_handler_set :: proc "contextless" (program_index: u32, handler_index: u32) -> op.Status {
	program := &programs[program_index]
	handler := &threads[handler_index]
	// Only a live thread of this program: thread.program is 0 after
	// thread_finish, which runs under this lock.
	if handler_index != 0 && (handler.program != program_index || handler.record_in_kernel == nil) {
		return .Bad_State
	}
	if fault_waiter_exists(program_index) {
		// A stop of the program takes the control lock.
		if need_control() {
			return STATUS_RETRY
		}
		program_stop(program_index, op.STOP_CODE_FAULT_UNANSWERED)
		return .Ok
	}
	program.fault_handler = handler_index
	if handler_index == 0 {
		return .Ok
	}
	program.fault_handler_serial = handler.serial
	program.fault_written = 0
	intrinsics.atomic_store(&handler.record_in_kernel.fault_written, 0)
	intrinsics.atomic_store(&handler.record_in_kernel.fault_read, 0)
	return .Ok
}

// fault_waiter_find gives the thread of a program with a number and a
// fault serial that waits for an answer, or 0. The caller holds the program lock,
// under which fault_waits and thread.program change.
fault_waiter_find :: proc "contextless" (program_index: u32, number: u64, serial: u64) -> u32 {
	for &thread, slot in threads[1:] {
		if thread.program == program_index && thread.fault_waits && u64(thread.number) == number && thread.fault_serial == serial {
			return u32(slot + 1)
		}
	}
	return 0
}

// fault_waiter_exists says if a thread of a program waits for an answer.
// The caller holds the program lock.
fault_waiter_exists :: proc "contextless" (program_index: u32) -> bool {
	for &thread in threads[1:] {
		if thread.program == program_index && thread.fault_waits {
			return true
		}
	}
	return false
}
