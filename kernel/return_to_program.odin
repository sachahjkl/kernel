package kernel

import op "contract:operation"

// The return to a program (docs/ARCHITECTURE.md, "The return to a
// program"). The kernel returns to a thread with iretq, from the frame that
// it keeps for the thread. When the processor refuses that frame, it faults
// in the kernel, at the iretq, with the gs of the program: a fault there
// would be a fault of the kernel, and one program would stop the machine.
// Two layers keep it a fault of the thread's program:
//
// 1. Before each return, return_frame_prepare forces the selectors and the
//    flags of the frame to values that a program may have, and refuses an
//    instruction address that is not an address of a program and a stack
//    address that is not canonical. A refused frame stops the program, with
//    a stop report that names the field.
// 2. If the processor still refuses the iretq of resume, the stub of the
//    fault (processor.asm) gives the kernel its gs back, and
//    return_refused_by_the_processor stops the program of the thread that
//    the processor was resuming.

// The flags of a frame that a program keeps at its return: carry, parity,
// adjust, zero, sign, trap, direction, overflow, resume, alignment check
// and identification (bits 0, 2, 4, 6, 7, 8, 10, 11, 16, 18, 21). Not:
// interrupt (always set: USER_FLAGS), the I/O privilege level (always 0),
// nested task (always 0: a program has no task to return to), virtual-8086
// and the virtual interrupt flags.
RETURN_FLAGS_OF_A_PROGRAM :: u64(0x0025_0DD5)

// Why the kernel did not return to a thread.
Return_Refusal :: enum u8 {
	None,
	// The instruction address is not below USER_END: an instruction that
	// ends at the last byte below USER_END gives the address USER_END, which
	// is not canonical (a syscall there, or an interrupt after it).
	Instruction_Address,
	// The stack address is not canonical: a program can hold any value in
	// rsp, and a processor can refuse a return to a stack that is not
	// canonical.
	Stack_Address,
	// The processor faulted at the iretq of resume (vector 11, 12 or 13).
	Refused_By_The_Processor,
}

@(rodata)
return_refusal_sentences := [Return_Refusal]string {
	.None                     = "",
	.Instruction_Address      = "the instruction address is not an address of a program: ",
	.Stack_Address            = "the stack address is not canonical: ",
	.Refused_By_The_Processor = "the processor refused the return, with the instruction address ",
}

foreign _ {
	// The iretq of resume (processor.asm): the one instruction where the
	// kernel runs with the gs of a program.
	resume_return: u8
}

// address_canonical says if an address is canonical with 4 levels of page
// tables: bits 47 to 63 are all 0 or all 1.
address_canonical :: proc "contextless" (address: u64) -> bool {
	high := address >> 47
	return high == 0 || high == (u64(1) << 17) - 1
}

// return_frame_prepare makes the frame of a thread one that a program may
// have, and says what it refuses in it. The caller is the processor that
// resumes the thread (run).
//
// Each invariant after it returns .None:
// - cs is the code selector of programs, and ss their data selector.
// - rflags has the interrupt flag and the reserved bit 1 set, IOPL 0, no
//   nested task, and only the bits of RETURN_FLAGS_OF_A_PROGRAM from the
//   program.
// - rip is below USER_END: canonical, and in the half of a program.
// - rsp is canonical.
return_frame_prepare :: proc "contextless" (frame: ^Frame) -> (refusal: Return_Refusal, value: u64) {
	frame.cs = SELECTOR_USER_CODE
	frame.ss = SELECTOR_USER_DATA
	frame.rflags = frame.rflags & RETURN_FLAGS_OF_A_PROGRAM | USER_FLAGS
	if frame.rip >= USER_END {
		return .Instruction_Address, frame.rip
	}
	if !address_canonical(frame.rsp) {
		return .Stack_Address, frame.rsp
	}
	return .None, 0
}

// program_return_refused stops the program of a thread that the kernel
// cannot return to: a fault of that program, with its stop report. The
// thread is the current thread of this processor; the caller then calls
// schedule, which ends it. The caller holds no lock.
program_return_refused :: proc "contextless" (thread: ^Thread, refusal: Return_Refusal, value: u64, vector: u64) {
	index := thread.program
	control_take()
	defer control_free()
	program := &programs[index]
	taken := program_lock(index)
	first := program.state != .Stopped && program.state != .None
	if first {
		program.stop = {code = op.STOP_CODE_RETURN, vector = u32(vector), instruction = thread.frame.rip, address = value}
		if found := module_of(program, thread.frame.rip); found != nil {
			program.stop.module = found^
		}
	}
	log_in("fault", .Warning, "kernel: program ", program_name(program), " stopped: the kernel cannot return to its thread: ", return_refusal_sentences[refusal], Hex(value))
	program_unlock(index, taken)
	program_stop(index, op.STOP_CODE_RETURN)
}

// return_refused_by_the_processor ends a fault of the iretq of resume. The
// stub of the fault ran swapgs, so the gs base is the record of this
// processor again (processor.asm, interrupt_common). The fault frame is on
// the kernel stack of this processor, below the copy of the frame of the
// thread that resume made (processor.asm, resume). The thread is the
// current thread of this processor: resume returns only to it.
return_refused_by_the_processor :: proc "contextless" (frame: ^Frame) -> ! {
	cpu := processor_self()
	sync_acknowledge(cpu)
	thread := &threads[cpu.current]
	program_return_refused(thread, .Refused_By_The_Processor, thread.frame.rip, frame.vector)
	schedule()
}
