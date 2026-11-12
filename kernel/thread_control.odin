package kernel

import "base:intrinsics"
import op "contract:operation"

// The control of a thread (docs/ARCHITECTURE.md, "The control of a
// thread"): Thread_Control stops a thread, reads and writes its registers
// and its extended state, and resumes it. A debugger, a garbage collector,
// a sampling profiler and the program that runs a guest use it.
//
// The stop is a count, not a state: two holders that each stop the thread
// each resume it, and the thread runs again only after the last Resume. The
// count is orthogonal to the wait of the thread (Ready or Waiting): a wait
// still ends as before, but a thread whose count is above 0 enters no run
// queue. The three places where a thread enters a queue check it under
// the run lock of the home of the thread:
// - thread_ready_held (the end of a wait) leaves the thread out of the
//   queue;
// - schedule leaves the thread out of the queue when its processor leaves
//   it;
// - kernel_interrupt does not continue the thread after an entry.
// The Resume that makes the count 0 puts a thread that is Ready in the
// queue of its home.
//
// The registers of a thread are complete only while no processor runs it:
// the frame from its last kernel entry, the extended state from the save of
// schedule. So they are read and written only while the thread is held:
// its count is above 0, or it waits for an answer of the fault ring. Both
// last at least while the program lock of the thread is held: the count
// goes down and fault_waits ends only under it.
//
// A write is checked whole before anything changes: the frame must be one
// that the return to a program takes (op.thread_registers_refusal), the
// extended state one that xrstor or fxrstor takes
// (op.extended_state_refusal). So no write makes the kernel fault at the
// return or at the restore of the thread.

// thread_control runs the operation Thread_Control. The caller holds the
// program lock of the program of the calling thread, and the control lock
// when the operation asked for it.
thread_control :: proc "contextless" (caller_index: u32, v: [7]u64, results: ^[7]u64) -> op.Status {
	caller_program_index := threads[caller_index].program
	caller_program := &programs[caller_program_index]
	command := op.Thread_Control_Command(v[2])
	if command == .None || v[2] > u64(max(op.Thread_Control_Command)) {
		return .Bad_Operation
	}
	target_index: u32
	owner := caller_program_index
	if v[0] == 0 {
		// A thread of this program, by its number: under the program lock,
		// which the caller holds, no thread of this program starts or ends.
		target_index = thread_of_number(caller_program_index, v[1])
		if target_index == 0 {
			return .Bad_State
		}
	} else {
		slot := handle_find(caller_program, v[0], .Thread, {.Control}) or_return
		target_index = slot.object
		// A thread of another program: its program lock, which the lock
		// order allows only with the control lock. The program of a thread
		// changes only under the control lock (thread_finish).
		if intrinsics.atomic_load(&threads[target_index].program) != caller_program_index {
			if need_control() {
				return STATUS_RETRY
			}
			owner = threads[target_index].program
		}
	}
	if owner == 0 {
		return .Bad_State // The thread ended.
	}
	// The lock of the program of the caller is held already: then this
	// takes nothing (program_lock).
	taken := program_lock(owner)
	defer program_unlock(owner, taken)
	if programs[owner].state == .Stopped || programs[owner].state == .None {
		return .Bad_State
	}
	thread := &threads[target_index]
	if thread.program != owner {
		return .Bad_State
	}
	switch command {
	case .None:
		return .Bad_Operation
	case .Stop:
		return thread_control_stop(target_index, results)
	case .Resume:
		return thread_control_resume(thread, results)
	case .Read_Registers, .Write_Registers, .Read_Extended_State, .Write_Extended_State:
		size := command == .Read_Registers || command == .Write_Registers ? u64(size_of(op.Thread_Registers)) : extended_state_size
		writes_to_the_caller := command == .Read_Registers || command == .Read_Extended_State
		if v[4] < size || !user_range(caller_program, v[3], size, writes_to_the_caller) {
			return .Bad_Address
		}
		if target_index == caller_index || !thread_held_off_processor(thread) {
			return .Bad_State
		}
		#partial switch command {
		case .Read_Registers:
			registers := thread_registers_of_frame(thread)
			user_copy(rawptr(uintptr(v[3])), &registers, size)
		case .Write_Registers:
			registers: op.Thread_Registers
			user_copy(&registers, rawptr(uintptr(v[3])), size)
			if refusal, _ := op.thread_registers_refusal(&registers); refusal != .None {
				return .Bad_Operation
			}
			thread_frame_write(thread, &registers)
			thread.registers_written = true
		case .Read_Extended_State:
			user_copy(rawptr(uintptr(v[3])), &thread.extended_state, size)
			results[1] = transmute(u64)extended_state_components
		case .Write_Extended_State:
			written := &processor_self().extended_state_written
			// The bytes past the size of a save keep the values of the thread:
			// the area is copied whole below.
			written^ = thread.extended_state
			user_copy(written, rawptr(uintptr(v[3])), size)
			if refusal, _ := extended_state_write_refusal(written); refusal != .None {
				return .Bad_Operation
			}
			thread.extended_state = written^
			thread.registers_written = true
		}
		results[0] = size
		return .Ok
	}
	return .Bad_Operation
}

// thread_of_number gives the live thread of a program with a number, or 0.
// The caller holds the program lock.
thread_of_number :: proc "contextless" (program_index: u32, number: u64) -> u32 {
	if number >= op.THREAD_CAPACITY {
		return 0
	}
	for &thread, slot in threads[1:] {
		if thread.program == program_index && u64(thread.number) == number && thread.state != .None && thread.state != .Stopped && !thread.finished {
			return u32(slot + 1)
		}
	}
	return 0
}

// thread_control_stop adds 1 to the stop count of a thread. A thread in the
// queue of its home leaves it; a thread on another processor gets an
// interrupt, and the operation returns after it left that processor
// (stop_wait), so that the registers are complete when the caller reads
// them. The calling thread stops at the end of its kernel entry.
thread_control_stop :: proc "contextless" (index: u32, results: ^[7]u64) -> op.Status {
	thread := &threads[index]
	home := run_lock(thread)
	if thread.state == .None || thread.state == .Stopped || intrinsics.atomic_load(&thread.stop_requested) || thread.control_stops >= op.THREAD_STOP_COUNT_LIMIT {
		run_unlock(home)
		return .Bad_State
	}
	intrinsics.atomic_store(&thread.control_stops, thread.control_stops + 1)
	count := thread.control_stops
	if thread.queued {
		queue_remove(thread)
		// It left the list with no `stopping` of its strategy: the Resume
		// places it again as a new thread.
		strategy_clear(thread)
	}
	running := thread.processor
	serial := thread.serial
	run_unlock(home)
	self := processor_self()
	if running != 0 && processors[running - 1] != self {
		// The interrupt makes the thread enter the kernel, whose end does
		// not continue it.
		apic_send(processors[running - 1].apic_id, VECTOR_WAKE)
		self.stopped_thread, self.stopped_thread_serial = index, serial
	}
	results[0] = u64(count)
	return .Ok
}

// thread_control_resume takes 1 from the stop count of a thread. At 0, a
// thread that is Ready and on no processor enters the queue of its home, as
// at the end of a wait.
thread_control_resume :: proc "contextless" (thread: ^Thread, results: ^[7]u64) -> op.Status {
	home := run_lock(thread)
	if thread.control_stops == 0 {
		run_unlock(home)
		return .Bad_State
	}
	intrinsics.atomic_store(&thread.control_stops, thread.control_stops - 1)
	count := thread.control_stops
	queued := false
	if count == 0 && thread.state == .Ready && thread.processor == 0 && !thread.queued && !intrinsics.atomic_load(&thread.stop_requested) {
		queue_ready(thread, .Woken)
		queued = true
	}
	run_unlock(home)
	if queued {
		kick(home)
	}
	results[0] = u64(count)
	return .Ok
}

// thread_held_off_processor says if a thread is held, and waits until no
// processor runs it when it waits for an answer of the fault ring. The
// caller holds the program lock of the thread: the hold lasts while it is
// held.
//
// A thread that waits for an answer can still be on its way out of its
// processor: its record is published before it leaves. That way takes no
// program lock and no control lock (fault_deliver returned; then
// kernel_interrupt and schedule up to the store of `processor`), so the
// wait here ends. A thread held only by its stop count and still on a
// processor can be inside an operation that waits for the program lock
// that the caller holds: no wait for it; Stop already waited for it, so a
// thread still there is one that another Stop holds now, and the caller
// gets Bad_State.
thread_held_off_processor :: proc "contextless" (thread: ^Thread) -> bool {
	if thread.state == .None || thread.state == .Stopped || intrinsics.atomic_load(&thread.stop_requested) {
		return false
	}
	if thread.fault_waits {
		cpu := processor_self()
		self := &threads[cpu.current]
		for intrinsics.atomic_load(&thread.processor) != 0 {
			if intrinsics.atomic_load(&self.stop_requested) {
				return false
			}
			sync_acknowledge(cpu)
			intrinsics.cpu_relax()
		}
		return true
	}
	return intrinsics.atomic_load(&thread.control_stops) != 0 && intrinsics.atomic_load(&thread.processor) == 0
}

// thread_registers_of_frame gives the registers of a held thread from its
// frame.
thread_registers_of_frame :: proc "contextless" (thread: ^Thread) -> op.Thread_Registers {
	frame := &thread.frame
	return {
		rax = frame.rax, rbx = frame.rbx, rcx = frame.rcx, rdx = frame.rdx,
		rsi = frame.rsi, rdi = frame.rdi, rbp = frame.rbp, rsp = frame.rsp,
		r8 = frame.r8, r9 = frame.r9, r10 = frame.r10, r11 = frame.r11,
		r12 = frame.r12, r13 = frame.r13, r14 = frame.r14, r15 = frame.r15,
		rip = frame.rip, rflags = frame.rflags, cs = frame.cs, ss = frame.ss,
		in_kernel_entry = thread.in_enter ? 1 : 0,
	}
}

// thread_frame_write writes checked registers into the frame of a held
// thread. The vector and the error code stay: they are the ones of the last
// entry, and no return reads them.
thread_frame_write :: proc "contextless" (thread: ^Thread, registers: ^op.Thread_Registers) {
	frame := &thread.frame
	frame.rax, frame.rbx, frame.rcx, frame.rdx = registers.rax, registers.rbx, registers.rcx, registers.rdx
	frame.rsi, frame.rdi, frame.rbp, frame.rsp = registers.rsi, registers.rdi, registers.rbp, registers.rsp
	frame.r8, frame.r9, frame.r10, frame.r11 = registers.r8, registers.r9, registers.r10, registers.r11
	frame.r12, frame.r13, frame.r14, frame.r15 = registers.r12, registers.r13, registers.r14, registers.r15
	frame.rip, frame.rflags, frame.cs, frame.ss = registers.rip, registers.rflags, registers.cs, registers.ss
}

#assert(op.THREAD_CODE_SELECTOR == SELECTOR_USER_CODE)
#assert(op.THREAD_STACK_SELECTOR == SELECTOR_USER_DATA)
#assert(op.THREAD_FLAGS_ALLOWED == RETURN_FLAGS_OF_A_PROGRAM | USER_FLAGS)
#assert(op.THREAD_FLAGS_REQUIRED == USER_FLAGS)
#assert(op.USER_END == USER_END)
