package kernel

import "base:intrinsics"
import op "contract:operation"

// The control of a thread (docs/ARCHITECTURE.md, "The control of a
// thread"): Thread_Control stops a thread, reads and writes its registers
// and its extended state, and resumes it. A debugger, a garbage collector,
// a sampling profiler and the program that runs a guest use it.
//
// Through a handle, a stop, a resume and a read need the right Inspect, a
// write the right Write (op.thread_control_rights). A write lets its holder
// choose the code that the program runs; a hold and a read do not, so a
// profiler or a collector that only reads gets no write. Control, the right
// to end the thread, gives neither: a handle given only so that another
// program can end a thread does not become a grant to debug it.
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
//
// The schedule of a thread (its weight and its request, op.Thread_Schedule)
// is read and written with no hold: a share changes while the thread runs
// (docs/SCHEDULING.md, "The schedule of a live thread"). A program writes
// the schedule of its own threads; through a thread handle a read needs
// Inspect and a write Control, because a holder that can end a thread can
// also give it a smaller share. These writes only lower the weight and
// the request. The machine handle with the right Schedule
// names any thread of the machine by its machine number, for these two
// commands only. It needs Inspect too, for a read as each report of the
// machine does, and for a write because a write gives the three values of
// the record: its holder must read the schedule to keep the values that
// it does not change.
//
// Only a write through the machine handle raises a weight or a request,
// and a raised weight starts the thread again as a new thread for its
// strategy. Each thread has a weight limit, the full weight at first.
// Only a write through the machine handle sets it, and a new thread gets
// the limit of the thread that creates it, with a weight up to it. So a
// weight that the holder of Schedule lowered stays lowered: the program
// of the thread cannot write it back, and cannot leave the limit by a new
// thread.

// thread_control runs the operation Thread_Control. The caller holds the
// program lock of the program of the calling thread, and the control lock
// when the operation asked for it.
thread_control :: proc "contextless" (caller_index: u32, v: [7]u64, results: ^[7]u64) -> op.Status {
	caller_program_index := threads[caller_index].program
	caller_program := &programs[caller_program_index]
	cpu := processor_self()
	cpu.thread_write_refusal, cpu.thread_write_refused_value, cpu.thread_write_refused_limit = .None, 0, 0
	command := op.Thread_Control_Command(v[2])
	if command == .None || v[2] > u64(max(op.Thread_Control_Command)) {
		return .Bad_Operation
	}
	target_index: u32
	owner := caller_program_index
	by_machine := false // The machine handle names the thread: a write sets its weight limit.
	if v[0] == 0 {
		// A thread of this program, by its number: under the program lock,
		// which the caller holds, no thread of this program starts or ends.
		target_index = thread_of_number(caller_program_index, v[1])
		if target_index == 0 {
			return .Bad_State
		}
	} else {
		named := handle_find(caller_program, v[0], .None) or_return
		machine_rights, by_machine_number := op.thread_control_machine_rights(command)
		if named.kind == .Machine && by_machine_number {
			// The machine handle names any thread, for the schedule only:
			// the right Schedule already lets its holder change the order
			// of every thread (Strategy_Set). Each other command with a
			// machine handle goes to the branch below, which refuses a
			// handle that is not a thread handle.
			if !(machine_rights <= named.rights) {
				return .No_Right
			}
			by_machine = true
			place, serial := v[1] & 0xFFFF_FFFF, u32(v[1] >> 32)
			if place == 0 || place >= THREAD_TABLE_CAPACITY {
				return .Bad_State
			}
			// No handle keeps the place for this thread: a place serves a
			// new thread only under the control lock (thread_create), so
			// with it the serial names one thread until the operation ends.
			if need_control() {
				return STATUS_RETRY
			}
			target_index = u32(place)
			if threads[target_index].serial != serial {
				return .Bad_State // The thread of that number ended, and the place serves another one.
			}
			owner = threads[target_index].program
		} else {
			// The right of the command: a handle that a program gave so
			// that another one can end a thread (Control) does not let it
			// hold the thread or write its registers.
			slot := handle_find(caller_program, v[0], .Thread, op.thread_control_rights(command)) or_return
			target_index = slot.object
			// A thread of another program: its program lock, which the
			// lock order allows only with the control lock. The program of
			// a thread changes only under the control lock (thread_finish).
			if intrinsics.atomic_load(&threads[target_index].program) != caller_program_index {
				if need_control() {
					return STATUS_RETRY
				}
				owner = threads[target_index].program
			}
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
			if refusal, value := op.thread_registers_refusal(&registers); refusal != .None {
				cpu.thread_write_refusal, cpu.thread_write_refused_value = refusal, value
				return .Bad_Operation
			}
			thread_frame_write(thread, &registers)
			thread.registers_written = true
		case .Read_Extended_State:
			user_copy(rawptr(uintptr(v[3])), &thread.extended_state, size)
			results[1] = transmute(u64)extended_state_components
		case .Write_Extended_State:
			written := &cpu.extended_state_written
			// The bytes past the size of a save keep the values of the thread:
			// the area is copied whole below.
			written^ = thread.extended_state
			user_copy(written, rawptr(uintptr(v[3])), size)
			if refusal, value := extended_state_write_refusal(written); refusal != .None {
				cpu.thread_write_refusal, cpu.thread_write_refused_value = refusal, value
				return .Bad_Operation
			}
			thread.extended_state = written^
			thread.registers_written = true
		}
		results[0] = size
		return .Ok
	case .Read_Schedule, .Write_Schedule:
		size := u64(size_of(op.Thread_Schedule))
		if v[4] < size || !user_range(caller_program, v[3], size, command == .Read_Schedule) {
			return .Bad_Address
		}
		// One copy in the memory of the kernel: the values that the check
		// accepts are the values that the thread gets.
		schedule: op.Thread_Schedule
		if command == .Read_Schedule {
			read_status: op.Status
			schedule, read_status = thread_schedule_read(thread)
			if read_status != .Ok {
				return read_status
			}
			user_copy(rawptr(uintptr(v[3])), &schedule, size)
		} else {
			user_copy(&schedule, rawptr(uintptr(v[3])), size)
			// The check of Thread_Create; the error record names the value
			// that it refused and the most that it takes. The weight limit
			// of the record is read only from the holder of the machine.
			refusal: op.Thread_Write_Refusal
			refused, most: u64
			switch {
			case schedule.weight > op.WEIGHT_FULL:
				refusal, refused, most = .Weight, u64(schedule.weight), op.WEIGHT_FULL
			case schedule.request > op.REQUEST_LIMIT:
				refusal, refused, most = .Request, u64(schedule.request), op.REQUEST_LIMIT
			case by_machine && schedule.weight_limit > op.WEIGHT_FULL:
				refusal, refused, most = .Weight_Limit, u64(schedule.weight_limit), op.WEIGHT_FULL
			case:
				write_status, write_refusal, write_most := thread_schedule_write(thread, schedule, by_machine)
				if write_status != .Ok && write_status != .Bad_Operation {
					return write_status
				}
				// A weight or a request above the one that the thread has.
				refusal, refused, most = write_refusal, u64(write_refusal == .Request ? schedule.request : schedule.weight), u64(write_most)
			}
			if refusal != .None {
				cpu.thread_write_refusal, cpu.thread_write_refused_value, cpu.thread_write_refused_limit = refusal, refused, most
				return .Bad_Operation
			}
		}
		results[0] = size
		return .Ok
	}
	return .Bad_Operation
}

// thread_machine_number gives the machine number of a thread: its place in
// the thread table in the low 32 bits, and the serial of the thread in that
// place in the high 32 bits. The serial changes for each new thread of a
// place, so the number of a thread that ended names no later thread.
thread_machine_number :: #force_inline proc "contextless" (index: u32, serial: u32) -> u64 {
	return u64(index) | u64(serial) << 32
}

// thread_schedule_ends says if a thread has no schedule to read or to
// write: it ended, or another processor ends it. The caller holds the run
// lock of its home.
thread_schedule_ends :: #force_inline proc "contextless" (thread: ^Thread) -> bool {
	return thread.state == .None || thread.state == .Stopped || intrinsics.atomic_load(&thread.stop_requested)
}

// thread_schedule_read gives the weight, the request and the weight limit
// of a thread, all of one moment: they change together under the run lock
// of its home. The caller holds the program lock of the thread.
thread_schedule_read :: proc "contextless" (thread: ^Thread) -> (schedule: op.Thread_Schedule, status: op.Status) {
	home := run_lock(thread)
	defer run_unlock(home)
	if thread_schedule_ends(thread) {
		return {}, .Bad_State
	}
	return op.Thread_Schedule{weight = thread.weight, request = thread.request, weight_limit = thread.weight_limit}, .Ok
}

// thread_schedule_write gives a thread a weight and a request, in any state
// of the thread: in the queue of its home, on a processor, in a wait, or
// held by a stop. The caller checked each value against the most of the
// contract. The caller holds the program lock of the thread, so the thread
// does not end its life in the table and its place serves no new thread.
//
// by_machine false: the program of the thread, or the holder of a thread
// handle, writes. Such a write only lowers: a weight above the weight that
// the thread has now, or a request above its request, is refused
// (Bad_Operation, with the part and the value that the thread has), and
// nothing changes. 0 keeps the value that the thread has. The weight limit
// of the record is not read. A program chooses the moment of its writes;
// with one direction only, no sequence of them gets back what a write
// gave up.
//
// by_machine true: the holder of the machine writes the three values. 0
// is the default of each: the full weight for the limit, the limit for
// the weight, the default request. A weight above the new limit becomes
// the limit. Only this write raises a weight, and a raised thread gets
// the zero values of its strategy fields (strategy_weight_raised).
//
// All of it is one section of the run lock of the home of the thread
// (run_lock reads the home again after the take): a pick, a move, a wake,
// a tick, the end of a turn, a stop and the conversion of the queue to
// another strategy each take that lock, so each one sees the old schedule
// whole or the new one whole (docs/ARCHITECTURE.md, "Locks of the kernel").
// No weight is ever above its limit: both are written in this section.
//
// The sum of the weights of the list stays exact: the old weight of a
// thread of the list leaves it and the new one enters it. The list keeps
// its order, and the thread keeps its state, its home and its processor.
thread_schedule_write :: proc "contextless" (thread: ^Thread, schedule: op.Thread_Schedule, by_machine: bool) -> (status: op.Status, refusal: op.Thread_Write_Refusal, most: u32) {
	home := run_lock(thread)
	defer run_unlock(home)
	if thread_schedule_ends(thread) {
		return .Bad_State, .None, 0
	}
	old_weight := thread.weight
	weight_limit := thread.weight_limit
	weight, request: u32
	if by_machine {
		weight_limit = schedule.weight_limit == 0 ? u32(op.WEIGHT_FULL) : schedule.weight_limit
		weight = schedule.weight == 0 ? weight_limit : min(schedule.weight, weight_limit)
		request = schedule.request == 0 ? u32(op.REQUEST_DEFAULT) : schedule.request
	} else {
		weight = schedule.weight == 0 ? old_weight : schedule.weight
		request = schedule.request == 0 ? thread.request : schedule.request
		if weight > old_weight {
			return .Bad_Operation, .Weight, old_weight
		}
		if request > thread.request {
			return .Bad_Operation, .Request, thread.request
		}
	}
	queue := &run_queues[home]
	if thread.queued {
		queue.weight = queue.weight - old_weight + weight
	}
	// A report, and the diagnosis of a refused Thread_Create, read these
	// words with no lock, each one whole.
	intrinsics.atomic_store(&thread.weight, weight)
	intrinsics.atomic_store(&thread.request, request)
	intrinsics.atomic_store(&thread.weight_limit, weight_limit)
	if weight > old_weight {
		strategy_weight_raised(queue, home, thread)
	}
	return .Ok, .None, 0
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
		// It leaves the list as a thread that starts to wait: its strategy
		// keeps its position, and the Resume places it as a woken thread.
		// Zero values here would forgive what the thread owes: a Stop and a
		// Resume by another thread of its program would put it before
		// threads that waited longer.
		strategy_leaves_list(&run_queues[home], home, thread)
		queue_remove(thread)
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
