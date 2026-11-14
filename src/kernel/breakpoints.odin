package kernel

import "base:intrinsics"
import op "contract:operation"

// The breakpoints of a thread, and the read of the memory of a program
// (docs/ARCHITECTURE.md, "The debugger of a program").
//
// A breakpoint is a debug register of the processor, not a byte written in
// the code: the code of a module is shared by each program that maps it,
// and a written byte would stop each of them. The processor has four
// address registers (DR0 to DR3), one control register (DR7) that says
// which are on and what each one stops on, and one status register (DR6)
// that says what made the last debug exception.
//
// The registers belong to a thread. Thread_Control writes the breakpoints
// of a held thread into its thread record, after it checked each one
// (op.thread_breakpoints_refusal): an address of a program, never of the
// kernel; an execute breakpoint or a data breakpoint; the local enable
// bits of the control register only. The processor that takes the thread
// loads the registers, and the processor that leaves it clears the control
// register. So the breakpoints of a thread never stop another thread, and
// they do not outlive the thread on a processor.
//
// The cost for a thread with no breakpoint is one test at each switch to
// it (Thread.has_breakpoints, in the hot line) and one test of the
// processor record at each switch away (Processor.breakpoints_loaded).
//
// While a thread with breakpoints is in the kernel, its registers stay
// loaded. An execute breakpoint is an address of a program, where the
// kernel runs no instruction. A data breakpoint can be reached by a copy of
// the kernel from or to the memory of the program (user_copy): that debug
// exception comes from the kernel, and the stub of the interrupts drops it
// (interrupt_common in processor.asm). The copy goes on, and the debugger
// does not see an access that the kernel made.

// The trap flag and the resume flag of the flags register.
FLAG_TRAP :: u64(1) << 8
FLAG_RESUME :: u64(1) << 16

// debug_status_take reads the debug status of the processor after a debug
// exception of a program, and clears it: the processor never clears the
// status itself, so an old bit would name a breakpoint that the next
// exception did not reach. It gives the bits of the contract: the
// breakpoints and the single step.
debug_status_take :: proc "contextless" () -> u64 {
	status := debug_register_6_read()
	debug_register_6_write(DR6_CLEAR)
	return status & (op.DEBUG_STATUS_BREAKPOINTS | op.DEBUG_STATUS_STEP)
}

// breakpoints_load gives the debug registers of this processor the
// breakpoints of the thread that it takes. The control register comes
// last: no breakpoint is on with an address of the thread before.
breakpoints_load :: proc "contextless" (cpu: ^Processor, thread: ^Thread) {
	debug_register_0_write(thread.breakpoints.breakpoints[0].address)
	debug_register_1_write(thread.breakpoints.breakpoints[1].address)
	debug_register_2_write(thread.breakpoints.breakpoints[2].address)
	debug_register_3_write(thread.breakpoints.breakpoints[3].address)
	debug_register_7_write(thread.breakpoint_control)
	cpu.breakpoints_loaded = true
}

// breakpoints_unload turns each breakpoint of this processor off. The
// address registers keep their values: with the control register clear
// they stop nothing.
breakpoints_unload :: proc "contextless" (cpu: ^Processor) {
	debug_register_7_write(DR7_NO_BREAKPOINT)
	cpu.breakpoints_loaded = false
}

// breakpoints_enabled gives the breakpoints of a thread that are on, as
// the bits of the debug status: bit n for the breakpoint n. The local
// enable bit of the breakpoint n is bit 2n of the control register.
breakpoints_enabled :: proc "contextless" (thread: ^Thread) -> (enabled: u64) {
	if !intrinsics.atomic_load(&thread.has_breakpoints) {
		return 0
	}
	for place in 0 ..< u64(op.THREAD_BREAKPOINT_CAPACITY) {
		if thread.breakpoint_control & (u64(1) << (2 * place)) != 0 {
			enabled |= u64(1) << place
		}
	}
	return enabled
}

// thread_breakpoints_write gives a held thread a checked set of
// breakpoints. The caller holds the program lock of the thread, and the
// thread is on no processor and in no queue: no processor loads the
// registers while they change.
thread_breakpoints_write :: proc "contextless" (thread: ^Thread, breakpoints: ^op.Thread_Breakpoints) {
	control := op.thread_breakpoints_control(breakpoints)
	intrinsics.atomic_store(&thread.has_breakpoints, false)
	thread.breakpoints = breakpoints^
	thread.breakpoint_control = control
	intrinsics.atomic_store(&thread.has_breakpoints, control != DR7_NO_BREAKPOINT)
}

// debug_exception_is_dropped judges a debug exception of the current
// thread of this processor, under the program lock of its program, and
// writes the debug status of the contract in the frame of the thread
// (its error code, which a fault record gives). The frame holds the bits
// that the processor gave (debug_status_take).
//
// The status keeps a breakpoint only when the thread has it on now: the
// processor can set the bit of an address register that is not on, and the
// debugger of the program can have removed the breakpoints of a thread
// that ran (debug_handler_end), whose processor still holds them. Then the
// control register of this processor is cleared here.
//
// true: nothing is left that a ring or a stop must see: a breakpoint that
// was removed, or a single step that a debugger asked for and that came
// after the end of the debugging. The thread goes on. An execute
// breakpoint that was removed does not come again: the control register
// is clear.
debug_exception_is_dropped :: proc "contextless" (program: ^Program, thread: ^Thread) -> bool {
	cpu := processor_self()
	given := thread.frame.error
	status := given & (op.DEBUG_STATUS_STEP | breakpoints_enabled(thread))
	if cpu.breakpoints_loaded && !intrinsics.atomic_load(&thread.has_breakpoints) {
		breakpoints_unload(cpu)
	}
	if status & op.DEBUG_STATUS_STEP != 0 && thread.debugger_step && program.debug_handler == 0 {
		thread.debugger_step = false
		thread.frame.rflags &~= FLAG_TRAP
		status &~= op.DEBUG_STATUS_STEP
	}
	thread.frame.error = status
	return given != 0 && status == 0
}

// breakpoint_resume_flag_set sets the resume flag of a thread that goes on
// at the instruction of an execute breakpoint that it just reached: the
// processor then runs that instruction once with no debug exception, and
// clears the flag. Without it the thread reaches the same breakpoint again
// with no end. The thread is on no processor, or it is the current thread
// of this processor in the kernel; the caller holds its program lock.
breakpoint_resume_flag_set :: proc "contextless" (thread: ^Thread) {
	if thread.frame.vector != VECTOR_DEBUG || !intrinsics.atomic_load(&thread.has_breakpoints) {
		return
	}
	for breakpoint, place in thread.breakpoints.breakpoints {
		reached := thread.frame.error & (u64(1) << u64(place)) != 0
		if reached && breakpoint.kind == .Execute && breakpoint.address == thread.frame.rip {
			thread.frame.rflags |= FLAG_RESUME
		}
	}
}

// thread_stops_release takes a count of stops from the stop count of a
// thread: the stops that the debugger of its program made, at the end of
// the debugging. At 0, a thread that is Ready and on no processor enters
// the queue of its home, as after the last Resume. The caller holds the
// program lock of the thread.
thread_stops_release :: proc "contextless" (thread: ^Thread, count: u32) {
	home := run_lock(thread)
	left := thread.control_stops - min(count, thread.control_stops)
	intrinsics.atomic_store(&thread.control_stops, left)
	queued := false
	if left == 0 && thread.state == .Ready && thread.processor == 0 && !thread.queued && !intrinsics.atomic_load(&thread.stop_requested) {
		queue_ready(thread, .Woken)
		queued = true
	}
	run_unlock(home)
	if queued {
		kick(home, thread)
	}
}

// program_memory_read copies bytes of the memory of a program into memory
// of the calling program, and gives the count that it copied. The caller
// holds the program lock of the program that is read, so its page table
// and its mappings do not change under the copy, and the program lock of
// the calling program, with the destination checked (user_range): for two
// programs, the control lock first, as for each path that holds two
// program locks. The page table of this processor is the one of the
// calling program.
//
// The source is read through the direct map, page by page: the kernel
// never loads the page table of the program that is read. A page is read
// only if the program maps it, can read it, and it has a frame: a read
// gives no frame to a page, so it changes nothing of the program and
// spends none of its budget. The copy stops before the first page that is
// not so. A range that is not whole below USER_END copies nothing: no
// address of the kernel is ever read.
program_memory_read :: proc "contextless" (program: ^Program, source: u64, destination: u64, count: u64) -> (copied: u64) {
	if source >= USER_END || count > USER_END - source {
		return 0
	}
	for copied < count {
		address := source + copied
		physical := program_page_physical(program, address)
		if physical == 0 {
			break
		}
		part := min(count - copied, PAGE_SIZE - address % PAGE_SIZE)
		user_copy(rawptr(uintptr(destination + copied)), direct(physical, u8), part)
		copied += part
	}
	return copied
}

// program_page_physical gives the physical address of a byte of a program
// that the program can read now, or 0: no mapping, no frame yet, no
// access, or device memory. Device memory is not memory of the direct map,
// and a read of the registers of a device can change the device. The
// caller holds the program lock.
program_page_physical :: proc "contextless" (program: ^Program, address: u64) -> u64 {
	mapping := mapping_at(program, address)
	if mapping == nil || program.table == 0 || regions[mapping.region].device {
		return 0
	}
	entry := page_entry(program.table, address)
	if entry == nil || entry^ & (PAGE_PRESENT | PAGE_USER) != PAGE_PRESENT | PAGE_USER {
		return 0
	}
	if mapping.large {
		return entry^ & PAGE_ADDRESS &~ u64(LARGE_PAGE_SIZE - 1) | address & (LARGE_PAGE_SIZE - 1)
	}
	return entry^ & PAGE_ADDRESS | address & (PAGE_SIZE - 1)
}
