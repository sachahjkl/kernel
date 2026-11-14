package kernel

import "base:intrinsics"
import op "modus:contract/operation"

// The fault ring (docs/ARCHITECTURE.md, "The fault ring"). A program names
// one of its threads as its fault handler (Fault_Handler_Set), with the
// fault kinds that it takes. A fault of such a kind of another thread of the
// program, which would stop the program, becomes a record in the thread
// record of the handler; the faulting thread waits; a thread of the program
// repairs (Memory_Commit, Memory_Protect) and answers (Fault_Answer): Resume
// lets the thread continue at the instruction of its record, Stop stops the
// program with the report of the fault, as with no handler.
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
//   return (return_frame_prepare), as each return. A stop of
//   Thread_Control keeps a Ready thread out of the queue until its Resume.
// While it waits, Thread_Control reads and writes its registers and its
// extended state (thread_control.odin); a write makes Resume valid for a
// fault that would otherwise run the same instruction again.
// - waiting -> stopped (Fault_Answer Stop, a stop of the program, the end of
//   the handler): program_stop ends each thread of the program, a waiting
//   one as any thread that is on no processor.
// A waiting thread holds nothing but its thread: no record of the kernel,
// no lock, no page.
//
// A thread that waits for an answer is in no table of words, and only
// Fault_Answer, the end of the ring (its handler ends, or Fault_Handler_Set
// while it waits) or the stop of its program ends its wait. A thread whose
// record went to the debugger of its program waits in the same state, with
// fault_to_debugger true: the answer of the debugger or the end of the
// debugging ends its wait, and the ring of its program does not count it.
//
// The record names the faulting thread by its number and by the serial of
// the fault: a count of the program (Program.fault_serial), not the serial
// of the kernel's thread slot, which all programs share and which would
// tell a program how many threads others made in that slot.

// The debugger of a program (docs/ARCHITECTURE.md, "The debugger of a
// program"). A program with a handle of another program with the right
// Debug names one of its own threads as the debug handler of that program
// (Fault_Handler_Set with the handle). Then the faults of the kinds Debug
// and Breakpoint of that program go to the ring of that thread first, and
// only the debugger answers them (Fault_Answer with the handle).
//
// The ring is the fault ring of the thread record of the debug handler:
// the debugger pays for it. A thread is the debug handler of one program,
// and not the fault handler of its own, so one ring has one writer: the
// faults of the debugged program, each under the program lock of that
// program. The kernel's count of that ring is Program.debug_written of the
// debugged program.
//
// The record is memory of another program than the one that faults. The
// debugged program keeps the address of the record (Program.debug_record)
// under its own program lock. The end of the debug handler clears it under
// that lock, before the thread record is unmapped: thread_finish calls
// debug_handler_end first. So a fault never writes a record that is gone,
// and a fault takes one program lock only.
//
// What the debugger did to the program ends with the debugging
// (debug_handler_end): the breakpoints of each thread, the trap flag that
// it wrote, the stops that it made, and the wait of each thread for its
// answer. A debugger that ends never holds and never stops the program.

// What fault_deliver did with a fault.
Fault_Delivery :: enum u8 {
	Stops_The_Program,   // No ring takes the fault: the program stops, as with no handler.
	Waits_For_An_Answer, // The record is written, and the thread waits.
	Continues,           // A debug exception that no debugger waits for any more: the thread goes on.
}

// fault_deliver gives a fault of the current thread of this processor to
// the ring of the debugger of its program, or to the fault ring of its
// program. The frame of the thread is the frame of the fault; address is
// the address of a page fault, and 0 for another kind. The caller holds no
// lock.
fault_deliver :: proc "contextless" (thread_index: u32, address: u64) -> Fault_Delivery {
	thread := &threads[thread_index]
	vector := thread.frame.vector
	program_index := thread.program
	program := &programs[program_index]
	if vector >= 64 {
		return .Stops_The_Program
	}
	kind_bit := u64(1) << vector
	// The kinds of the handler and of the debugger, read with no lock: a
	// fault of a kind that neither asked for, and every fault of a program
	// with no handler, takes no lock here. The check under the lock below
	// decides. A debug exception always takes the lock: the status of a
	// breakpoint that was removed is judged there.
	if vector != VECTOR_DEBUG && (intrinsics.atomic_load(&program.fault_kinds) | intrinsics.atomic_load(&program.debug_kinds)) & kind_bit == 0 {
		return .Stops_The_Program
	}
	// The thread areas, the time page and the kernel half are not served: a
	// handler cannot repair them, and the records of the ring are in a
	// thread area.
	if vector == VECTOR_PAGE_FAULT && address >= op.THREAD_AREA_BASE {
		return .Stops_The_Program
	}
	taken := program_lock(program_index)
	defer program_unlock(program_index, taken)
	if program.state == .Stopped {
		return .Stops_The_Program
	}
	if vector == VECTOR_DEBUG && debug_exception_is_dropped(program, thread) {
		return .Continues
	}
	// The ring of the debugger first, for its kinds.
	record: ^op.Thread_Record
	to_debugger := false
	if program.debug_record != nil && program.debug_kinds & kind_bit != 0 {
		record = program.debug_record
		// fault_read is memory of the debugger: any value. The rule of the
		// ring of a program, below, holds here too: the kernel indexes with
		// its own count.
		if program.debug_written - intrinsics.atomic_load(&record.fault_read) >= op.FAULT_RECORD_CAPACITY {
			program.debug_full += 1
			intrinsics.volatile_store(&record.fault_full, program.debug_full)
			// One line of the log for each time that the ring becomes
			// full, with the count: a thread that steps through a full
			// ring comes here at each instruction, and a line for each one
			// would fill the log. The next record that finds room allows
			// the next line.
			if !program.debug_full_logged {
				program.debug_full_logged = true
				log_in("fault", .Warning, "kernel: program ", Module_Name{program_name(program)}, ": the ring of its debugger is full (", u64(program.debug_full), " times): the debugger does not see the fault")
			}
			// A breakpoint, or a single step that the debugger asked for,
			// that finds no place is lost for the debugger, and is no
			// fault of the program: the thread goes on. The step is over:
			// its trap flag leaves the thread, so that the thread does not
			// come here again at each instruction. A breakpoint belongs to
			// the debugger: only the debugger writes one.
			status := thread.frame.error
			debugger_stepped := status & op.DEBUG_STATUS_STEP != 0 && thread.debugger_step
			if vector == VECTOR_DEBUG && (status & op.DEBUG_STATUS_BREAKPOINTS != 0 || debugger_stepped) {
				if debugger_stepped {
					thread.debugger_step = false
					thread.frame.rflags &~= FLAG_TRAP
				}
				breakpoint_resume_flag_set(thread)
				return .Continues
			}
			// Each other one (int3, int1, a single step that the program
			// asked for itself) stays with the program, as with no
			// debugger: its own fault handler below, or its stop.
		} else {
			to_debugger = true
			program.debug_full_logged = false
		}
	}
	if !to_debugger {
		handler_index := program.fault_handler
		// A fault of the handler itself is not delivered: no fault of a fault.
		if handler_index == 0 || handler_index == thread_index || program.fault_kinds & kind_bit == 0 {
			return .Stops_The_Program
		}
		handler := &threads[handler_index]
		// The handler of the program is a live thread of the program: thread_finish
		// clears fault_handler under this lock before it unmaps the record.
		record = handler.record_in_kernel
		if handler.program != program_index || handler.serial != program.fault_handler_serial || record == nil {
			return .Stops_The_Program
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
			log_in("fault", .Warning, "kernel: program ", Module_Name{program_name(program)}, ": the fault ring is full (", u64(program.fault_full), " times): the fault stops the program")
			return .Stops_The_Program
		}
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
	thread.fault_to_debugger = to_debugger
	thread.fault_serial = program.fault_serial
	thread.fault_address = address
	thread.fault_instruction = thread.frame.rip
	thread.fault_frame_pointer = thread.frame.rbp
	// A write of Thread_Control before this fault does not make Resume
	// valid for it: the handler writes after it reads this record.
	thread.registers_written = false
	run_unlock(home)
	// The mark of a trap flag that the debugger wrote stays through its
	// record: the flag is still in the frame of the thread, and only the
	// next write of the registers, or the end of the debugging, takes it
	// out (debug_handler_end).
	access: u64
	if vector == VECTOR_PAGE_FAULT {
		access = thread.frame.error & 0b10011 // Present, Write, Execute: the bits of Fault_Access.
	}
	written := to_debugger ? &program.debug_written : &program.fault_written
	record.fault_records[written^ % op.FAULT_RECORD_CAPACITY] = {
		thread      = u64(thread.number),
		serial      = program.fault_serial,
		address     = address,
		access      = access,
		instruction = thread.frame.rip,
		kind        = op.Fault_Kind(vector),
		error_code  = thread.frame.error,
	}
	written^ += 1
	// The record is written before the count that publishes it.
	intrinsics.atomic_store(&record.fault_written, written^)
	word_wake(physical_of(&record.fault_written), max(u64))
	return .Waits_For_An_Answer
}

// fault_handler_set makes a thread of the program its fault handler for the
// fault kinds of a mask of vectors, with an empty ring, or ends the delivery
// (handler_index 0). The ring of the old handler ends either way: a thread
// that waits then has a record that no thread will read, so the program
// stops as at the end of the handler thread. The caller holds the program
// lock (execute).
fault_handler_set :: proc "contextless" (program_index: u32, handler_index: u32, kinds: u64) -> op.Status {
	program := &programs[program_index]
	handler := &threads[handler_index]
	// Only a live thread of this program: thread.program is 0 after
	// thread_finish, which runs under this lock.
	if handler_index != 0 && (handler.program != program_index || handler.record_in_kernel == nil) {
		return .Bad_State
	}
	// One ring has one role: the ring of a debug handler takes the records
	// of the program that it debugs, with the count of that program.
	if handler_index != 0 && intrinsics.atomic_load(&handler.debugs_program) != 0 {
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
		intrinsics.atomic_store(&program.fault_kinds, 0)
		return .Ok
	}
	program.fault_handler_serial = handler.serial
	program.fault_written = 0
	intrinsics.atomic_store(&handler.record_in_kernel.fault_written, 0)
	intrinsics.atomic_store(&handler.record_in_kernel.fault_read, 0)
	intrinsics.atomic_store(&program.fault_kinds, kinds)
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

// fault_waiter_exists says if a thread of a program waits for an answer
// in the fault ring of the program. A thread that waits for the debugger
// of the program has its record in the ring of the debugger: the end of
// the ring of the program does not lose it. The caller holds the program
// lock.
fault_waiter_exists :: proc "contextless" (program_index: u32) -> bool {
	for &thread in threads[1:] {
		if thread.program == program_index && thread.fault_waits && !thread.fault_to_debugger {
			return true
		}
	}
	return false
}

// debug_handler_set makes a thread of the calling program the debug
// handler of another program, for the fault kinds of a mask of vectors,
// with an empty ring. The caller holds the control lock and the program
// lock of the calling program, and checked the right Debug on the handle
// of the debugged program.
debug_handler_set :: proc "contextless" (caller_index: u32, handler_index: u32, debugged_index: u32, kinds: u64) -> op.Status {
	// A program does not debug itself: its debug handler would wait for
	// its own answer.
	if debugged_index == caller_index {
		return .Bad_State
	}
	handler := &threads[handler_index]
	// Only a live thread of the calling program, which is not its fault
	// handler: one ring has one role.
	if handler.program != caller_index || handler.record_in_kernel == nil || programs[caller_index].fault_handler == handler_index {
		return .Bad_State
	}
	if serves := intrinsics.atomic_load(&handler.debugs_program); serves != 0 && serves != debugged_index {
		return .Bad_State
	}
	// Two programs do not debug each other: each one could hold the debug
	// handler of the other, and both would wait for ever.
	if debugger_is(caller_index, debugged_index) {
		return .Bad_State
	}
	taken := program_lock(debugged_index)
	defer program_unlock(debugged_index, taken)
	program := &programs[debugged_index]
	if program.state != .Created && program.state != .Ready {
		return .Bad_State
	}
	if program.debug_handler != 0 {
		// One debugger at a time. The program of a thread changes only
		// under the control lock, which the caller holds.
		if threads[program.debug_handler].program != caller_index {
			return .Bad_State
		}
		// A new debug handler of the same debugger: the ring of the old
		// one ends as at a detach, and its threads go on.
		debug_handler_end(debugged_index)
	}
	record := handler.record_in_kernel
	program.debug_handler = handler_index
	program.debug_record = record
	program.debug_written = 0
	// The counts of a full ring are those of this debugger.
	program.debug_full = 0
	program.debug_full_logged = false
	intrinsics.volatile_store(&record.fault_full, 0)
	intrinsics.atomic_store(&record.fault_written, 0)
	intrinsics.atomic_store(&record.fault_read, 0)
	intrinsics.atomic_store(&handler.debugs_program, debugged_index)
	intrinsics.atomic_store(&program.debug_kinds, kinds)
	return .Ok
}

// debug_handler_detach ends the debugging of a program by its debugger,
// the calling program. The caller holds the control lock.
debug_handler_detach :: proc "contextless" (caller_index: u32, debugged_index: u32) -> op.Status {
	taken := program_lock(debugged_index)
	defer program_unlock(debugged_index, taken)
	if !debugger_is(debugged_index, caller_index) {
		return .Bad_State
	}
	debug_handler_end(debugged_index)
	return .Ok
}

// debugger_is says if a program is the debugger of another one: a thread
// of it is the debug handler. The caller holds the control lock, under
// which the program of a thread changes, and the program lock of the
// debugged program.
debugger_is :: proc "contextless" (debugged_index: u32, debugger_index: u32) -> bool {
	handler := programs[debugged_index].debug_handler
	return handler != 0 && debugger_index != debugged_index && threads[handler].program == debugger_index
}

// debug_handler_end ends the debugging of a program, if it has a
// debugger: the detach, the end of the debug handler thread, the end of
// the right Debug of the debugger, the stop of the program. No fault of
// the program goes to the old ring after it. In a program that runs, each
// thread gets back what the debugger took: its breakpoints end, the trap
// flag that the debugger wrote is cleared, the stops that the debugger
// made are taken back, and a thread that waits for the answer of the
// debugger goes on. The caller holds the control lock; this takes the
// program lock of the debugged program.
//
// A thread that a processor runs keeps its debug registers until it
// leaves that processor, and a trap flag that the debugger wrote is still
// in its flags. Its next debug exception finds no breakpoint and no
// debugger under the program lock, and is dropped
// (debug_exception_is_dropped).
debug_handler_end :: proc "contextless" (debugged_index: u32) {
	program := &programs[debugged_index]
	taken := program_lock(debugged_index)
	defer program_unlock(debugged_index, taken)
	handler_index := program.debug_handler
	if handler_index == 0 {
		return
	}
	program.debug_handler = 0
	program.debug_record = nil
	intrinsics.atomic_store(&program.debug_kinds, 0)
	intrinsics.atomic_store(&threads[handler_index].debugs_program, 0)
	if program.state != .Created && program.state != .Ready {
		return // The program stops: each of its threads ends.
	}
	for &thread in threads[1:] {
		if thread.program != debugged_index {
			continue
		}
		intrinsics.atomic_store(&thread.has_breakpoints, false)
		waits := thread.fault_waits && thread.fault_to_debugger
		stops := thread.debug_stops
		if !waits && stops == 0 {
			continue
		}
		// A thread that waits for the answer can still be on its way out
		// of its processor: that way takes no lock that is held here
		// (thread_held_off_processor).
		if waits {
			_ = thread_held_off_processor(&thread)
		}
		// The frame of a thread that no processor runs: the program lock
		// keeps the thread held.
		if intrinsics.atomic_load(&thread.processor) == 0 && thread.debugger_step {
			thread.frame.rflags &~= FLAG_TRAP
			thread.debugger_step = false
		}
		// Only the stops of the debugger: a stop of the program itself, or
		// of a holder of a thread handle, stays (thread_control.odin keeps
		// debug_stops at most control_stops).
		if stops != 0 {
			thread.debug_stops = 0
			thread_stops_release(&thread, stops)
		}
		if waits {
			thread.fault_waits = false
			thread.fault_to_debugger = false
			thread_wake(&thread)
		}
	}
}

// debug_right_closed ends the debugging of a program when a handle of its
// debugger to it with the right Debug closes or is revoked, and no other
// handle of the debugger has that right on it. handle_close calls it
// before it clears the slot: the slot still holds the handle, and the loop
// skips it. The caller holds the program lock of the program that closes
// the handle and the control lock (a close of a program handle asks for
// it; a revocation and the cleanup of a program hold it).
debug_right_closed :: proc "contextless" (holder: ^Program, closed: ^Handle_Slot) {
	debugged_index := closed.object
	for &slot in holder.handles {
		if &slot != closed && slot.kind == .Program && slot.object == debugged_index && .Debug in slot.rights {
			return
		}
	}
	taken := program_lock(debugged_index)
	defer program_unlock(debugged_index, taken)
	if debugger_is(debugged_index, index_of_program(holder)) {
		debug_handler_end(debugged_index)
	}
}

// debug_fault_answer lets a thread of a debugged program go on after a
// fault whose record went to its debugger, the calling program. The
// caller holds the control lock.
debug_fault_answer :: proc "contextless" (caller_index: u32, debugged_index: u32, number: u64, serial: u64) -> op.Status {
	taken := program_lock(debugged_index)
	defer program_unlock(debugged_index, taken)
	if !debugger_is(debugged_index, caller_index) {
		return .Bad_State
	}
	waiter_index := fault_waiter_find(debugged_index, number, serial)
	if waiter_index == 0 || !threads[waiter_index].fault_to_debugger {
		return .Bad_State
	}
	waiter := &threads[waiter_index]
	// The frame is written below: the thread left its processor first.
	if !thread_held_off_processor(waiter) {
		return .Bad_State
	}
	breakpoint_resume_flag_set(waiter)
	waiter.fault_waits = false
	waiter.fault_to_debugger = false
	thread_wake(waiter)
	return .Ok
}
