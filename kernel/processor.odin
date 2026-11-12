package kernel

import "base:intrinsics"
import op "contract:operation"

// The processor: segments, the interrupt table, the interrupt controller and
// the timer. The frame layout is the one of kernel/processor.asm.

Frame :: struct {
	r15, r14, r13, r12, r11, r10, r9, r8: u64,
	rdi, rsi, rbp, rbx, rdx, rcx, rax:    u64,
	vector, error:                        u64,
	rip, cs, rflags, rsp, ss:             u64,
}
#assert(size_of(Frame) == 22 * 8)

SELECTOR_KERNEL_CODE :: 0x08
SELECTOR_USER_DATA :: 0x18 | 3
SELECTOR_USER_CODE :: 0x20 | 3
SELECTOR_TASK :: 0x28
USER_FLAGS :: 0x202 // Interrupts on.

VECTOR_DEBUG :: 1
VECTOR_NON_MASKABLE_INTERRUPT :: 2
VECTOR_DOUBLE_FAULT :: 8
VECTOR_PAGE_FAULT :: 14
VECTOR_MACHINE_CHECK :: 18
VECTOR_INTERRUPT_BASE :: 32 // The 16 lines of the 8259 are the vectors 32 to 47.
VECTOR_TIMER :: 48 // The timer of the processor.
VECTOR_WAKE :: 49 // Another processor made a thread ready.
VECTOR_SYNC :: 50 // Another processor waits for this one: see processor_sync.
VECTOR_SPURIOUS :: 63
VECTOR_MESSAGE_BASE :: 64 // The message interrupts (operation.Device_Kind.Message): vectors 64 to 79.
VECTOR_KERNEL_ENTER :: 128
// The interrupt stacks of the task state, from 1 (0 in a gate: no stack of
// its own).
INTERRUPT_STACK_DOUBLE_FAULT :: 1
INTERRUPT_STACK_DEBUG :: 2
INTERRUPT_STACK_NON_MASKABLE_INTERRUPT :: 3
INTERRUPT_STACK_MACHINE_CHECK :: 4
INTERRUPT_LINES :: 16
// An interrupt object: a line of the 8259 (0 to 15), or a message interrupt
// (16 and after).
INTERRUPT_CAPACITY :: INTERRUPT_LINES + op.MESSAGE_CAPACITY
STUB_COUNT :: 80
TICKS_PER_SECOND :: 1000
MSR_GS_BASE :: 0xC000_0101
MSR_KERNEL_GS_BASE :: 0xC000_0102 // In the kernel: the gs register of the program.
TIME_SLICE :: 10 // Ticks that a program runs before another ready program gets the processor.

foreign _ {
	// sti, hlt, cli: wait for one interrupt. It stays in processor.asm: the
	// compiler takes hlt as the end of the flow of a template.
	idle_wait :: proc "c" () ---
	// The load of the segment table also loads cs with a far return: it
	// uses its own return address.
	gdt_load :: proc "c" (descriptor: rawptr) ---
	kernel_enter :: proc "c" () ---
	resume :: proc "c" (frame: ^Frame) -> ! ---
	interrupt_stubs: [STUB_COUNT]u64
}

Task_State :: struct #packed {
	reserved_0:  u32,
	stack_0:     u64, // The stack of an interrupt that comes from a program.
	stacks:      [2]u64,
	reserved_1:  u64,
	interrupts:  [7]u64,
	reserved_2:  u64,
	reserved_3:  u16,
	port_offset: u16,
	ports:       [8192 + 1]u8, // One bit per port. 1: a program cannot use the port.
}

Table_Descriptor :: struct #packed {
	limit:   u16,
	address: u64,
}

Interrupt_Gate :: struct {
	offset_low:  u16,
	selector:    u16,
	stack:       u8,
	type:        u8,
	offset_mid:  u16,
	offset_high: u32,
	reserved:    u32,
}

PROCESSOR_CAPACITY :: 64

// The frame cache of a processor (memory.odin): a stack of free page
// frames, under its cache lock.
FRAME_CACHE_CAPACITY :: 256 // Chosen by measure: 16, 64 and 256 (docs/FIRST_MILESTONE.md).
FRAME_CACHE_BATCH :: FRAME_CACHE_CAPACITY / 2

Frame_Cache :: struct #align (64) {
	lock:          Lock,
	count:         u32, // The frames of the stack.
	taken:         u64, // Reserved pages that the stack served, not yet subtracted from reserved_pages.
	refills:       u64, // The takes that found the stack empty.
	batches_taken: u64, // Batches that the stack took from the frame table.
	batches_given: u64, // Batches that the stack gave back.
	drains:        u64, // Drains that took frames from this stack.
	frames:        [FRAME_CACHE_CAPACITY]u64,
}

// The record of one processor. The kernel has one stack per processor: a
// kernel entry starts at the top of the stack and never continues an
// earlier entry.
Processor :: struct {
	// These three fields are read through the gs register: the first two
	// by processor.asm, self by processor_self (instructions.odin).
	stack_top:     u64, // The top of the kernel stack (paging.odin).
	user_stack:    u64,
	self:          ^Processor,
	index:         u32,
	apic_id:       u32,
	// The thread that runs. 0: none. Only this processor writes it
	// (queue_pick, schedule): schedule saves the extended state of this
	// thread when it leaves it, and a 0 written by another processor would
	// skip that save and lose the registers of the thread.
	current:       u32,
	record_thread: u32, // The thread whose thread record address is in the gs register of programs.
	ports_loaded:  u32, // The program whose ports are open in the task state.
	pending:       u32, // Not 0: another processor waits in processor_sync.
	idle:          bool, // The processor waits for an interrupt, with no thread. Another processor clears it to wake it (kick).
	extended_state_refused: bool, // At its start, the processor could not save the extended state that the first processor saves: it never runs a thread.
	// The kinds of kernel events that the event table has rules for: bit n
	// for the Event_Kind n; 0 with no table (events.odin). Each event point
	// reads it first. It is in the first line of the record, which each
	// kernel entry reads already. The control path writes it (atomic).
	observed_kinds: u32,
	table:         u64, // The page table that the processor uses. Only this processor writes it; others read it (unmap).
	slice_left:    u64, // Ticks left of the time slice, the longest turn under each strategy; 0: the turn ends (strategy.odin).
	charged_from:  u64, // The cycle counter when the kernel last counted the time of the current thread (limit.odin).
	turn_start:    u64, // The cycle counter when the processor picked its current thread.
	// The scheduler (strategy.odin): counts of this processor only.
	picks:         u64, // Threads that a pick gave to this processor.
	preemptions:   u64, // Turns that a wake preemption ended.
	moves:         u64, // Threads that this processor took from the queue of another processor.
	pick_cycles:   u64, // The cycles of all the picks.
	// Another processor sets it: a thread that woke preempts the thread
	// that runs here (kick). The processor clears it (atomic).
	preempt:       bool,
	// Another processor that wakes this idle processor stores 1 + the queue
	// of the thread that woke: schedule_pick looks there first. The
	// processor clears it (atomic).
	look_first:    u32,
	// 1 + time_milliseconds of the last wake preemption of this processor
	// by a thread of another program (thread_ready_held). Run lock of this
	// processor.
	preempted_at:  u64,
	// The cost of the preemptions by interrupt: from the handler of the
	// interrupt to the resume of the next thread (run). Its processor only.
	preempt_from:  u64,
	interrupt_preemptions: u64,
	preempt_cycles: u64,
	busy_time:     u64, // Ticks with a thread.
	// Counts of this processor only: no other processor writes them, and
	// the reports add the counts of all processors.
	entries:       u64, // Kernel entries.
	interrupts:    u64, // Device interrupts.
	first_use_faults: u64, // Page faults after which the page was present.
	lock_counts:   [op.LOCK_KIND_CAPACITY]op.Lock_Count, // By Lock_Kind (lock.odin).
	held:          [op.Lock_Kind]u32, // The locks of each kind that the processor holds.
	programs_held: u64, // Bit n: the processor holds the lock of program n.
	control:       bool, // The operation that runs holds the control lock (enter.odin).
	retry:         bool, // The operation needs the control lock: it runs again with it.
	ports_serial:  u64, // The ports_serial of the program whose ports are open (ports_switch).
	record_serial: u32, // The serial of the thread whose record address is in the gs register of programs.
	// The stops that the operation in progress made (stop_wait).
	operation:     bool, // A kernel operation of the current thread runs (command_run).
	stopped_thread, stopped_thread_serial: u32, // A thread that ran on another processor. 0: none.
	stopped_programs: u64, // Bit n: program n had a thread on a processor.
	stopped_serials:  [PROGRAM_CAPACITY]u32,
	// The event ring of this processor (events.odin): only this processor
	// writes these fields and the ring, while observed_kinds is not 0; the
	// control path writes them only while it is 0 and after a
	// processor_sync. The counts are the kernel's own: event_written and
	// event_lost are what the head of the ring says, event_read_seen is the
	// last `read` of the program that the kernel loaded.
	event_ring:      ^op.Event_Ring,
	event_records:   [^]op.Event_Record,
	event_capacity:  u64, // A power of two.
	event_written:   u64,
	event_read_seen: u64,
	event_lost:      u64,
	frame_cache:   Frame_Cache,
	// The table of ranges of the Memory_Commit or Memory_Protect that runs
	// on this processor (a copy of the table of the caller).
	range_table:   [op.RANGE_TABLE_CAPACITY]op.Page_Range,
	// Records too large for the kernel stack, for the operation that runs on
	// this processor.
	log_text:       [4096]u8,
	boot_report:    op.Boot_Report,
	mapping_report: op.Mapping_Report,
	module_report:  op.Module_Report,
	// The reports of a developer tool (report.odin): built here under the
	// locks, then copied to the caller with no lock of another program.
	program_mapping_report: op.Program_Mapping_Report,
	thread_table_report:    op.Thread_Table_Report,
	stop_report:            op.Stop_Report,
	// The extended state area that a Thread_Control on this processor
	// writes: copied from the caller once, checked here, then copied to the
	// thread, so the caller cannot change it between the check and the use.
	extended_state_written: Extended_State_Area,
	// The part and the value that a write of Thread_Control on this
	// processor refused: the error record of the operation takes them from
	// here, not from a second read of the memory of the caller, which the
	// caller can change between the two reads.
	thread_write_refusal:       op.Thread_Write_Refusal,
	thread_write_refused_value: u64,
	segments:      [7]u64,
	task_state:    Task_State,
}

#assert(offset_of(Processor, user_stack) == 8)
#assert(offset_of(Processor, self) == 16) // processor_self in instructions.odin
#assert(offset_of(Processor, observed_kinds) < 64) // The first line of the record.

processors: [PROCESSOR_CAPACITY]^Processor
processor_count: u32
gates: [256]Interrupt_Gate
machine_stopping: bool

// processor_sync waits until each processor of the set (bit n: processor n)
// passed a point where it has no address translation of a program from
// before the call, and walks no chain of budgets: a kernel entry, the idle
// wait, or the wait for a lock (sync_acknowledge). The caller uses it after
// it removed a mapping (before the frames return), before it frees a page
// table, and before the slot of a budget that ended serves again.
processor_sync :: proc "contextless" (set: u64) {
	if set == 0 {
		return
	}
	for cpu in processors[:processor_count] {
		if set & (1 << cpu.index) != 0 {
			intrinsics.atomic_store(&cpu.pending, 1)
			apic_send(cpu.apic_id, VECTOR_SYNC)
		}
	}
	self := processor_self()
	for cpu in processors[:processor_count] {
		if set & (1 << cpu.index) != 0 {
			for intrinsics.atomic_load(&cpu.pending) != 0 {
				// Two processors can synchronize each other at one time.
				sync_acknowledge(self)
				intrinsics.cpu_relax()
			}
		}
	}
}

// sync_acknowledge answers processor_sync. The processor is in the kernel
// with interrupts off, at a kernel entry or in a wait for a lock.
sync_acknowledge :: proc "contextless" (cpu: ^Processor) {
	if intrinsics.atomic_load(&machine_stopping) {
		processor_stop()
	}
	if intrinsics.atomic_load(&cpu.pending) == 0 {
		return
	}
	// The page table of the program of the current thread; 0 with no thread.
	// Between the pick of a thread and run, current names the thread while
	// table is still the one of the program that the processor left, and a
	// wait for a lock there (a refused return takes the control lock)
	// answers here. That program can end meanwhile and free its tables: so
	// the processor keeps a table only if it is the one of its thread, and
	// run loads that one before the return.
	current_table: u64
	if current := intrinsics.atomic_load(&cpu.current); current != 0 {
		current_table = programs[threads[current].program].table
	}
	if current_table == 0 || intrinsics.atomic_load(&cpu.table) != current_table {
		intrinsics.atomic_store(&cpu.table, kernel_table)
		control_register_3_write(kernel_table)
	} else {
		control_register_3_write(control_register_3_read())
	}
	intrinsics.atomic_store(&cpu.pending, 0)
}

// processor_create makes the record of a processor.
processor_create :: proc "contextless" (index: u32, apic_id: u32) -> ^Processor {
	address := frames_allocate((size_of(Processor) + PAGE_SIZE - 1) / PAGE_SIZE)
	if address == 0 {
		return nil
	}
	tops, ok := stacks_create(index)
	if !ok {
		frames_free(address, (size_of(Processor) + PAGE_SIZE - 1) / PAGE_SIZE)
		return nil
	}
	cpu := direct(address, Processor)
	cpu.self = cpu
	cpu.index = index
	cpu.apic_id = apic_id
	cpu.stack_top = tops.kernel
	// The interrupt stacks of the task state (the gates name them in
	// processor_start). A double fault arrives on its own stack: the kernel
	// stack can be full. A debug exception, a non-maskable interrupt and a
	// machine check can arrive in the first instructions of the entry of
	// syscall, where the stack pointer is still the one of the program: on
	// their own stacks, the processor never pushes a frame where a program
	// chose (docs/ARCHITECTURE.md, "The windows of the entry and of the
	// return").
	cpu.task_state.interrupts[INTERRUPT_STACK_DOUBLE_FAULT - 1] = tops.double_fault
	cpu.task_state.interrupts[INTERRUPT_STACK_DEBUG - 1] = tops.interrupts[0]
	cpu.task_state.interrupts[INTERRUPT_STACK_NON_MASKABLE_INTERRUPT - 1] = tops.interrupts[1]
	cpu.task_state.interrupts[INTERRUPT_STACK_MACHINE_CHECK - 1] = tops.interrupts[2]
	cpu.table = kernel_table
	cpu.task_state.stack_0 = cpu.stack_top
	cpu.task_state.port_offset = u16(offset_of(Task_State, ports))
	for &b in cpu.task_state.ports {
		b = 0xFF
	}
	task_address := u64(uintptr(&cpu.task_state))
	task_limit := u64(size_of(Task_State) - 1)
	cpu.segments = {
		0,
		0x00AF_9A00_0000_FFFF, // kernel code
		0x00CF_9200_0000_FFFF, // kernel data
		0x00CF_F200_0000_FFFF, // user data
		0x00AF_FA00_0000_FFFF, // user code
		task_limit & 0xFFFF | (task_address & 0xFF_FFFF) << 16 | 0x89 << 40 | (task_limit >> 16 & 0xF) << 48 | (task_address >> 24 & 0xFF) << 56,
		task_address >> 32,
	}
	return cpu
}

// The control registers that the kernel writes on each processor, the first
// one and the others (docs/ARCHITECTURE.md, "The control registers of a
// processor"). CR0 is one value, of the bits below; CR4 keeps the bits of
// CR4_KEPT and adds those of CR4_FROM_FEATURES that the processor has.
CR0_PROTECTED_MODE :: 1 << 0
CR0_MONITOR_COPROCESSOR :: 1 << 1 // wait and fwait obey the flag task switched, which stays clear.
CR0_EXTENSION_TYPE :: 1 << 4
// An x87 error is the exception 16 of the thread, at its next x87
// instruction. Without it, the error goes out on line 13 of the interrupt
// controller, a device interrupt of the program that owns that line.
CR0_NUMERIC_ERROR :: 1 << 5
CR0_WRITE_PROTECT :: 1 << 16 // The kernel obeys read-only pages.
// A program that sets the flag AC gets the exception 17 for an access that
// is not aligned. Every 64-bit processor has it, and it acts at level 3
// only: the kernel, and its stac and clac, are not changed.
CR0_ALIGNMENT_MASK :: 1 << 18
CR0_PAGING :: 1 << 31
// Clear: emulation of the x87 (bit 2) and task switched (bit 3), so that
// device not available never comes; not write-through (29) and cache
// disabled (30), so that the caches work.
CR0_OF_THE_KERNEL :: u64(CR0_PROTECTED_MODE | CR0_MONITOR_COPROCESSOR | CR0_EXTENSION_TYPE | CR0_NUMERIC_ERROR | CR0_WRITE_PROTECT | CR0_ALIGNMENT_MASK | CR0_PAGING)
#assert(CR0_OF_THE_KERNEL == 0x8005_0033)

CR4_PHYSICAL_ADDRESS_EXTENSION :: 1 << 5
CR4_MACHINE_CHECK :: 1 << 6 // A machine check is the exception 18, which stops the machine with a line; without it the processor shuts down with no line.
// sgdt, sidt, sldt, smsw and str of a program give a protection fault: a
// program reads no address of a table of the kernel.
CR4_USER_INSTRUCTION_PREVENTION :: 1 << 11
// The fifth level of the page table. The boot program loads its tables of
// four levels in cr3 and does not change cr4, and the processor cannot
// change the count of levels in 64-bit mode: so the bit is 0 when the
// kernel starts (with it set the tables of four levels would not translate
// the kernel), and every walk of the kernel has four levels. The kernel
// writes it 0, and the start code of the other processors too.
CR4_FIVE_LEVEL_PAGING :: 1 << 12
CR4_NO_EXECUTE_PROGRAM :: 1 << 20
CR4_GUARD_PROGRAM :: 1 << 21
// The bits of CR4 that the kernel keeps from the value before
// processor_setup: long mode needs the physical address extension, and the
// setup of the extended state set the three others just before. Every
// other bit that the firmware set is cleared.
CR4_KEPT :: u64(CR4_PHYSICAL_ADDRESS_EXTENSION | CR4_OSFXSR | CR4_OSXMMEXCPT | CR4_OSXSAVE)
#assert(CR4_KEPT == 0x4_0620)
#assert(CR4_KEPT & CR4_FIVE_LEVEL_PAGING == 0)
// The bits of CR4 that processor_setup adds when CPUID has them.
CR4_FROM_FEATURES :: u64(CR4_MACHINE_CHECK | CR4_USER_INSTRUCTION_PREVENTION | CR4_NO_EXECUTE_PROGRAM | CR4_GUARD_PROGRAM)
#assert(CR4_FROM_FEATURES == 0x30_0840)
#assert(CR4_KEPT & CR4_FROM_FEATURES == 0)
// The instructions that let a program write its own fs and gs bases. Off:
// interrupt_common (kernel/processor.asm) tells the gs base of the kernel
// from the base of a program by its sign, and with them on a program could
// set a base in the kernel half.
CR4_FS_GS_BASE :: 1 << 16
#assert((CR4_KEPT | CR4_FROM_FEATURES) & CR4_FS_GS_BASE == 0)

// DR7 with no breakpoint on (bit 10 is always 1), and DR6 with no status
// (its reserved bits are 1).
DR7_NO_BREAKPOINT :: 0x400
DR6_CLEAR :: 0xFFFF_0FF0

// The processors refuse sgdt, sidt, sldt, smsw and str to programs
// (CR4_USER_INSTRUCTION_PREVENTION). Written by processor_setup.
user_instruction_prevention: bool

// processor_setup loads the registers of the processor that runs it.
processor_setup :: proc "contextless" (cpu: ^Processor) {
	descriptor := Table_Descriptor{size_of(cpu.segments) - 1, u64(uintptr(&cpu.segments))}
	gdt_load(&descriptor)
	task_register_load(SELECTOR_TASK)
	descriptor = {size_of(gates) - 1, u64(uintptr(&gates))}
	interrupt_table_load(&descriptor)
	model_specific_register_write(MSR_GS_BASE, u64(uintptr(cpu)))
	model_specific_register_write(MSR_KERNEL_GS_BASE, 0)

	// The syscall instruction.
	MSR_EFER :: 0xC000_0080
	MSR_STAR :: 0xC000_0081
	MSR_LSTAR :: 0xC000_0082
	MSR_SFMASK :: 0xC000_0084
	model_specific_register_write(MSR_EFER, model_specific_register_read(MSR_EFER) | 1)
	model_specific_register_write(MSR_STAR, 0x0010_0008 << 32)
	model_specific_register_write(MSR_LSTAR, u64(uintptr(rawptr(kernel_enter))))
	// The flags of the kernel at a syscall: the flags of the program with
	// these cleared: interrupt, direction, trap, user access, and nested
	// task. A program can set nested task with popfq; with it set in the
	// kernel, the iretq of resume would fault in the kernel.
	model_specific_register_write(MSR_SFMASK, 0x44700)
	// The control registers are the kernel's own on each processor: a bit
	// that the firmware left would decide what a program sees (an x87 error
	// as a device interrupt, no alignment check, the addresses of the tables
	// of the kernel). docs/ARCHITECTURE.md, "The control registers of a
	// processor".
	control_register_0_write(CR0_OF_THE_KERNEL)
	cr4 := control_register_4_read() & CR4_KEPT
	_, _, _, basic_features := intrinsics.x86_cpuid(1, 0)
	if basic_features & (1 << 7) != 0 {
		cr4 |= CR4_MACHINE_CHECK
	}
	// The kernel does not execute the memory of programs, and uses it only
	// in user_copy, when the processor can refuse the rest (SMEP, SMAP).
	if highest, _, _, _ := intrinsics.x86_cpuid(0, 0); highest >= 7 {
		_, features, more_features, _ := intrinsics.x86_cpuid(7, 0)
		if features & (1 << 7) != 0 {
			cr4 |= CR4_NO_EXECUTE_PROGRAM
			kernel_no_execute = true
		}
		if features & (1 << 20) != 0 {
			cr4 |= CR4_GUARD_PROGRAM
			user_access_guard = 1
		}
		if more_features & (1 << 2) != 0 {
			cr4 |= CR4_USER_INSTRUCTION_PREVENTION
			user_instruction_prevention = true
		}
	}
	control_register_4_write(cr4)
	// No breakpoint that the firmware set stays on: a debug exception in
	// the kernel stops the machine, except in the first instructions of the
	// entry of syscall, where interrupt_common drops it.
	debug_register_7_write(DR7_NO_BREAKPOINT)
	debug_register_6_write(DR6_CLEAR)
	apic_setup(cpu)
}

// processor_start prepares the first processor.
processor_start :: proc "contextless" () {
	for stub, vector in interrupt_stubs {
		gates[vector] = {
			offset_low  = u16(stub),
			selector    = SELECTOR_KERNEL_CODE,
			type        = 0x8E, // Interrupt gate: interrupts are off in the kernel.
			offset_mid  = u16(stub >> 16),
			offset_high = u32(stub >> 32),
		}
	}
	// The vectors with a stack of their own: the number of an interrupt
	// stack of the task state (processor_create gives each processor its
	// stacks).
	gates[VECTOR_DOUBLE_FAULT].stack = INTERRUPT_STACK_DOUBLE_FAULT
	gates[VECTOR_DEBUG].stack = INTERRUPT_STACK_DEBUG
	gates[VECTOR_NON_MASKABLE_INTERRUPT].stack = INTERRUPT_STACK_NON_MASKABLE_INTERRUPT
	gates[VECTOR_MACHINE_CHECK].stack = INTERRUPT_STACK_MACHINE_CHECK
	// int3 of a program reaches its gate only with the privilege level 3 in
	// the gate; with 0 the processor gives a protection fault in its place,
	// and a fault handler cannot tell a breakpoint. Every other gate keeps
	// 0: no `int n` of a program can act as an exception or an interrupt.
	gates[3].type = 0xEE

	// The interrupt controller of the device lines (8259): lines 0 to 15
	// become vectors 32 to 47. Line 0 (the 8254 timer) is off: each
	// processor has its own timer.
	port_write_8(0x20, 0x11)
	port_write_8(0xA0, 0x11)
	port_write_8(0x21, VECTOR_INTERRUPT_BASE)
	port_write_8(0xA1, VECTOR_INTERRUPT_BASE + 8)
	port_write_8(0x21, 4)
	port_write_8(0xA1, 2)
	port_write_8(0x21, 1)
	port_write_8(0xA1, 1)
	port_write_8(0x21, 0x01)
	port_write_8(0xA1, 0x00)

	apic_start()
	cpu := processor_create(0, apic_id())
	if cpu == nil {
		log("kernel: no memory for the record of the processor")
		machine_stop(1)
	}
	processors[0] = cpu
	processor_count = 1
	extended_state_first_setup()
	processor_setup(cpu)
	lock_ready = true
	extended_state_prove()
	extended_state_log()
	return_to_program_log()
	control_registers_log()
	performance_counters_log()
	timer_calibrate()
	timer_start()
}

// control_registers_log names, at boot, the control registers of the first
// processor, and what a program can read of the tables of the kernel.
control_registers_log :: proc "contextless" () {
	log("kernel: control registers: cr0 ", Hex(control_register_0_read()), ", cr4 ", Hex(control_register_4_read()), user_instruction_prevention ? string("; UMIP on: sgdt, sidt, sldt, smsw and str of a program give a protection fault") : string("; no UMIP: a program reads with sgdt and sidt the addresses of the segment table and of the interrupt table of its processor"))
}

interrupt_end :: proc "contextless" (line: u64) {
	if line >= 8 {
		port_write_8(0xA0, 0x20)
	}
	port_write_8(0x20, 0x20)
}

// ports_allow lets the program on a processor use, or not use, a range of ports.
ports_allow :: proc "contextless" (cpu: ^Processor, first, count: u64, allow: bool) {
	for port in first ..< min(first + count, 65536) {
		if allow {
			cpu.task_state.ports[port / 8] &~= 1 << (port % 8)
		} else {
			cpu.task_state.ports[port / 8] |= 1 << (port % 8)
		}
	}
}
