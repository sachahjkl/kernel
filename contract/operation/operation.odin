// The kernel operations: what a program can ask the kernel. The list is
// short and counted, and only a change of docs/PROPERTIES.md changes its
// limit (docs/PROPERTIES.md, "Small kernel with a small, counted interface").
//
// Each thread of a program has one ring to the kernel: the kernel ring. It
// is one page after the thread record of the thread, and the `gs` register
// of the thread holds the address of the thread record. A kernel
// operation is a command record in that ring: kind is an Operation, values
// are its parameters. The completion record has a Status in kind, and the
// results in values.
//
// The kernel has one entry point, the `syscall` instruction ("enter"):
//   rdi   0: execute the commands of the kernel ring, then return.
//         n: the same, then wait until a wake or until time n (milliseconds
//            since boot). WAIT_FOREVER waits with no time limit.
//   rax   on return: the time, in milliseconds since boot.
package operation

import info "contract:boot_info"

PAGE_SIZE :: 4096
WAIT_FOREVER :: max(u64)

// The addresses of a program that the system fixes.
PROGRAM_BASE :: 0x0000_0000_0040_0000 // The module of the program.
CHOSEN_BASE :: 0x0000_1000_0000_0000 // Where the kernel puts a mapping with no given address.
MODULE_BASE :: 0x0000_2000_0000_0000 // Where a program loads the modules that it calls.
STACK_TOP :: 0x0000_7FFF_FFE0_0000
STACK_PAGES :: 64
CONTEXT_ADDRESS :: 0x0000_7FFF_FFF0_0000
// The thread areas: one per thread, THREAD_AREA_PAGES pages each. An area
// is the thread record (one page), the kernel ring, and one page with no
// memory.
THREAD_AREA_BASE :: 0x0000_7FFF_FFF4_0000
THREAD_AREA_PAGES :: 4
THREAD_CAPACITY :: 32 // The threads of one program.
// The time page: one page that the kernel writes and that each program can
// only read. A program reads the time with no kernel entry.
TIME_ADDRESS :: 0x0000_7FFF_FFFE_0000
USER_END :: 0x0000_8000_0000_0000

// The record at TIME_ADDRESS. A program reads `milliseconds` with one load
// of 64 bits: the value is always complete.
Time_Record :: struct {
	// Since the kernel made the time page. It never goes back. The kernel
	// writes it at each tick of its timer, from the cycle counter: a tick
	// that comes late loses no time, and the value is at most one tick old.
	milliseconds: u64,
	// Cycles of the cycle counter in one second. It does not change after
	// boot.
	cycle_frequency: u64,
	// The cycle counter at the time 0. It does not change after boot. A
	// program that needs a time finer than one millisecond reads the cycle
	// counter, subtracts this, and divides by the frequency.
	cycle_start: u64,
}

Handle :: distinct u32 // 0 names no object.

// A right: one kind of operation that a handle permits on its object. The
// handle of a new object has each right of its kind. Handle_Give copies a
// handle with a part of its rights. No operation adds a right to a handle.
Right :: enum u32 {
	Give    = 0, // Each kind: give a copy of the handle to another program.
	Read    = 1, // Memory: map it. Program, Thread: read its state. Interrupt: read its count.
	// Memory: map it with Write. Log: write text on the log. Thread: write its registers and its extended state
	// while it is held (Thread_Control): full control of the code that its program runs.
	Write   = 2,
	Execute = 3, // Memory: map it with Execute.
	Control = 4, // Program: map memory in it, give handles to it, start it, stop it. Thread: end it, make it the fault handler.
	// Machine: read the reports. Thread: hold it and release it, and read its registers and its extended state
	// (Thread_Control): what a sampling profiler needs, and no write.
	Inspect = 5,
	Devices = 6, // Machine: create device handles.
	Stop    = 7, // Machine: stop the machine.
	Spend   = 8, // Budget: create objects with it, and take a part of it for a new budget.
	Physical = 9, // Machine: read the physical address of a memory object (Memory_Physical).
	Schedule = 10, // Machine: change the scheduling strategy of the machine (Strategy_Set).
	// Budget: pay pages of a memory object that this budget already pays for (Memory_Commit), and nothing else: no
	// object, thread, program or budget is created with it. The narrow form of Spend, to give to another program.
	Commit = 11,
	// Machine: give the event table of the machine (Events_Set): the kernel then writes records of its own work,
	// for every program or for the programs that the rules name, into memory of the caller.
	Events = 12,
}
Rights :: bit_set[Right;u32]

// The kind of the object that a handle names.
Object_Kind :: enum u8 {
	None      = 0,
	Memory    = 1,
	Program   = 2,
	Interrupt = 3,
	Ports     = 4,
	Machine   = 5, // The machine: its rights are Devices, Inspect and Stop.
	Thread    = 6,
	Budget    = 7,
	Log       = 8, // The log of the kernel.
}

Operation :: enum u32 {
	None           = 0,
	Log            = 1, // (log, address, count, level, channel 0, channel 1): write one text on the log. The channel is 16 bytes in two values.
	Memory_Create  = 2, // (budget, page_count, Memory_Flags) -> memory handle. The memory is zero.
	// The budget pays now for each page. A page gets its page frame at its first use (a page on first use),
	// or now with Frames_Now. An access to the memory never fails for lack of memory.
	Memory_Map     = 3, // (memory, program or 0 for self, address or 0, Map_Flags, first page, page_count or 0 for all) -> address
	Memory_Unmap   = 4, // (program or 0, address)
	Memory_Size    = 5, // (memory) -> page_count
	Program_Create = 6, // (budget, name address, name count) -> program handle. The program has no memory and no handle.
	// The budget pays for the program, for its page tables and for its first thread.
	Program_Start  = 7, // (program, entry address, stack address, context address): the first thread of the program.
	Program_Stop   = 8, // (program or 0 for self, code)
	Program_State  = 9, // (program, address of a Stop_Report or 0) -> Program_State, code, kernel entries of the program.
	// With an address, the kernel writes the Stop_Report of the program there.
	Handle_Give    = 10, // (target: program handle, memory handle, or 0 for this program; handle; Rights) -> the handle in the target program.
	// The new handle has the rights of the handle that are also in Rights: a grant never adds a right.
	// With a memory handle, the target is the other program that maps this memory: the other side of a ring.
	// If no other program maps it, the target is the one other program that holds a handle to it.
	// The kernel keeps, with the new handle, the memory object that it came through (Handle_State).
	Handle_Close   = 11, // (handle). The kernel stops a program when its last handle closes.
	Interrupt_Read = 12, // (interrupt) -> the number of interrupts since the last read.
	Device_Create  = 13, // (machine, Device_Kind, a, b) -> handle. Ports: a = first port, b = count. Interrupt: a = line.
	// Memory: a = physical address, b = page count: the registers of a device, as a memory object that a program maps
	// with no cache. The kernel refuses addresses of the memory that it manages.
	// Message: an interrupt that a device sends as a write to the interrupt controller (MSI-X). The results
	// are the handle, then the address and the value that the device must write.
	Inspect        = 14, // (machine, Inspect_Kind, index, address, size) -> bytes written
	Machine_Stop   = 15, // (machine, code)
	Thread_Create  = 16, // (budget, entry address, stack address, parameter, weight, request) -> thread handle. A new thread
	// of this program. The thread starts at the entry with the parameter in the first register. The weight (1 to
	// WEIGHT_FULL; 0 is WEIGHT_FULL) and the request (microseconds, 1 to REQUEST_LIMIT; 0 is REQUEST_DEFAULT) are for
	// the strategies that use them (Strategy). A weight can only be lower than the weight of a thread with 0.
	Thread_Stop    = 17, // (thread or 0 for self). A program with no thread stops.
	Thread_State   = 18, // (thread) -> Program_State: Ready, Waiting or Stopped; the stop count (Thread_Control); the bytes
	// of the extended state area of a thread; its components (the bits of XCR0: 0 x87, 1 SSE, 2 AVX, 5 to 7 AVX-512); 1
	// when the area has the header of xsave at byte 512, 0 when it is the 512 bytes of fxsave. A thread that a stop
	// holds is Ready when its wait ended, and runs only when its stop count is 0.
	// The word wait: the one way to wait for something else than a time.
	// A thread waits while each word of a list holds its value. The kernel
	// names a word by its page frame, so two programs that map one memory
	// object can use one word.
	Word_Wait      = 19, // (address of Word records, count): the wait of this entry ends when a Word_Wake names one
	// of these words, or at its deadline. If a word does not hold its value, the wait ends at once.
	// One entry can wait on WORD_WAIT_CAPACITY words.
	Word_Wake      = 20, // (address, count) -> threads woken: wake at most count threads that wait on this word.
	Budget_Create  = 21, // (budget, pages, programs, threads, processor, log_records) -> budget handle. See Budget_Amounts.
	Budget_Read    = 22, // (budget) -> pages, programs, threads: what the budget can still pay; processor, log_records: its limits;
	// the microseconds of processor time that it used since it was made; the log records that the kernel refused.
	Handle_State   = 23, // (handle, memory or 0) -> Object_Kind, Rights, 1 if the handle came through this memory object,
	// the count of the holdings that came from this handle.
	// A program that receives the number of a handle from another program, in a ring, proves with this
	// operation that the other program gave the handle through that ring. Without the proof, the
	// other program can name a handle that the receiver holds for itself.
	Handle_Revoke  = 24, // (handle, program or 0) -> the count of holdings that ended.
	// A holding is a handle or a mapping. The origin of a handle that Handle_Give made is the handle
	// that was given. The origin of a mapping is the memory handle that was mapped. When a handle
	// closes, what came from it comes from its origin. Handle_Revoke ends each holding that came from
	// the handle, in one program (a handle with the right Control) or in each program, and what came
	// from those holdings in any program. The handle stays, and the mappings of the program that
	// revokes stay. A program that lost a holding gets an event. A thread that uses memory that
	// its program lost stops its program on a page fault.
	Memory_Physical = 25, // (machine, memory) -> the physical address of the first page of a memory object that was
	// created Contiguous, or of device memory: its pages follow each other in physical memory and do not move.
	// Another memory object gives Bad_Operation. A device service gives these addresses to its device: the device
	// reads and writes the memory with no processor (direct memory access). Needs the right Physical on the machine.
	Program_Module = 26, // (program or 0 for self, address of a Module_Record): the module record of a module that a
	// loader put in the program. A record with the base of a record that exists replaces it; with the size 0
	// it removes it. The kernel does not read the module: the record is what the loader asserts. The kernel
	// names the module of the address of a fault with it, and Inspect gives the records (Module_Report).
	Strategy_Set = 27, // (machine, Strategy) -> the strategy before. The scheduling strategy of the machine changes
	// while it runs: no thread stops, none is lost. The state of the strategy of each thread starts from zero
	// (docs/SCHEDULING.md). Needs the right Schedule on the machine.
	// The virtual memory of a program (docs/ARCHITECTURE.md, "The virtual memory of a program").
	Memory_Commit = 28, // (memory, budget or 0, address of a table of Page_Range, count, Commit_Flags) -> pages changed.
	// The pages of the ranges of an object made with Uncommitted become committed: the budget pays one page for each,
	// and each gets a frame at its first use. The budget handle must name the budget of the object, with the right
	// Commit or Spend (the right Write on the object does not spend the budget of its maker; to let
	// another program commit, give it the object and a budget handle with Commit only). With Decommit, the committed
	// pages of the ranges are no longer paid: their frames and their pages return at once to the budget of the object,
	// and a page committed again is zero; the budget argument is not read. The ranges are in increasing order and do not
	// overlap; at most RANGE_TABLE_CAPACITY, and RANGE_TABLE_PAGE_LIMIT pages. Needs the right Write on the object.
	// Decommit needs an object that only this program names, with one mapping at most. A table that the budget cannot
	// pay changes nothing.
	Memory_Protect = 29, // (address of a table of Address_Range, count, Map_Flags) -> pages changed. The protection of
	// the pages of mappings of this program: Read only (no flag), Write, Execute, or No_Access. It can only take away
	// what the mapping was made with (Bad_Operation); Write and Execute together are refused. A range inside a mapping,
	// not its whole, takes away from the protection of the mapping now (it cannot get more: Bad_Operation), and needs
	// an object with a frame list that only this program names, with one mapping; while a part has its own protection,
	// the object is not mapped again and not given (Bad_State). At most RANGE_TABLE_PAGE_LIMIT pages. Each processor
	// that runs a thread of the program forgets the old translations before the operation returns (one shoot-down).
	// The fault ring (docs/ARCHITECTURE.md, "The fault ring").
	Fault_Handler_Set = 30, // (thread handle with Control or 0 for the calling thread, 1 to end the delivery, Fault_Kinds
	// or 0 for page faults only): the faults of these kinds of the other threads of this program become records of
	// the fault ring in the thread record of this thread, in place of a stop; the thread of a fault waits for
	// Fault_Answer. A page fault is delivered only below THREAD_AREA_BASE. A fault of a kind that the handler did not
	// ask for stops the program as with no handler. Bad_Operation for a kind that the kernel never delivers
	// (FAULT_KINDS_DELIVERED), and for kinds with the end of the delivery. Only a thread of this program. A new handler
	// replaces the one before; its ring starts empty. A new handler, or the end of the delivery, while a thread waits
	// for an answer ends the ring that holds its record: the program stops with STOP_CODE_FAULT_UNANSWERED, as when the
	// handler thread ends.
	Fault_Answer = 31, // (thread number, fault serial, Fault_Answer_Kind): the answer for a thread of this program that
	// waits in the fault ring, by the two values of its record. Bad_State if no thread with that number waits for the
	// fault of that serial: a wrong answer, a second answer, or an answer from another program. Bad_State also for
	// Resume after a fault kind that does not resume by itself (fault_kind_resumes) when Thread_Control wrote neither
	// the registers nor the extended state of the thread since its fault: the thread still waits, and Stop ends it.
	// Kernel events (docs/ARCHITECTURE.md, "Kernel events").
	Events_Set = 32, // (machine with Events, memory or 0, address of a table of Event_Rule, count, records in each ring)
	// -> the bytes of one event ring, the count of processors. The event table of the machine: the kernel writes an
	// Event_Record into the event ring of the processor of each kernel event that a rule accepts. The memory object
	// is Contiguous, with Write, and holds one ring of EVENT_RING_HEAD_BYTES + records * 64 bytes for each processor,
	// one after the other from its first byte; records is a power of two from EVENT_RING_RECORDS_LEAST to
	// EVENT_RING_RECORDS_MOST. At most EVENT_RULE_CAPACITY rules (No_Slot above). A new table replaces the table of
	// the caller; a table of another program is not replaced (Bad_State). With memory 0 the caller takes its table
	// away (Bad_State if it has none): when the operation returns, no processor writes in the old memory object.
	// The table also ends when its program ends, and when the last machine handle of its program with Events closes
	// or is revoked: the table lives while the right that made it lives.
	// The control of a thread (docs/ARCHITECTURE.md, "The control of a thread").
	Thread_Control = 33, // (thread handle or 0, thread number when the handle is 0, Thread_Control_Command, address,
	// size) -> see Thread_Control_Command. The handle needs the rights of thread_control_rights: Inspect to stop, to
	// resume and to read, Write to write. With the handle 0, the number names a live thread of this program
	// (Thread_Record.number, Fault_Record.thread; Bad_State if none); a thread of another program needs a handle.
	// Stop and Resume change the stop count of the thread: it runs only while the count is 0. The registers are read
	// and written only while the thread is held: its stop count is above 0, or it waits for an answer of the fault
	// ring (Bad_State else, and for the calling thread). A write of values that a thread of a program cannot hold
	// changes nothing (Bad_Operation): thread_registers_refusal, extended_state_refusal.
}

// The scheduling strategy of the machine (docs/SCHEDULING.md): the rule that
// orders the ready threads of each run queue. 0 is no strategy: a report of
// a kernel that has none.
Strategy :: enum u32 {
	None        = 0,
	Round_Robin = 1, // A queue in order, a time slice of 10 ms, no wake preemption.
	Fair        = 2, // Virtual time and weights: the least virtual time runs (the idea of CFS).
	Eevdf       = 3, // Earliest eligible virtual deadline first: weights for the share, the request for the delay.
}

@(rodata)
STRATEGY_NAMES := [Strategy]string {
	.None        = "none",
	.Round_Robin = "round robin",
	.Fair        = "fair",
	.Eevdf       = "EEVDF",
}

WEIGHT_FULL :: 1024 // The weight of a thread created with the weight 0: the most.
REQUEST_DEFAULT :: 3000 // Microseconds: the request of a thread created with the request 0.
REQUEST_LIMIT :: 100_000 // Microseconds: the longest request.

// A module record: one module that a loader put in a program (Program_Module).
// The identity of a program that runs is the list of its module records: the
// hash of each module, and the hash that a replacement put it in place of.
Module_Record :: struct {
	base:     u64, // The address of the first byte of the module in the program.
	size:     u64, // The bytes of addresses of the module. 0: no module.
	hash:     [32]u8, // The hash of the module that is loaded.
	replaces: [32]u8, // Zero, or the hash that an import names and that a replacement changed to `hash`.
}
#assert(size_of(Module_Record) == 80)

PROGRAM_MODULE_CAPACITY :: 16 // The module records of one program.

// Where a program stopped on a fault (Program_State). Zero: the program
// runs, or it stopped with no fault.
Stop_Report :: struct {
	code:        u32, // The stop code: STOP_CODE_FAULT plus the vector.
	vector:      u32,
	instruction: u64, // The address of the instruction.
	address:     u64, // A page fault: the address that the instruction used. 0 for another fault.
	module:      Module_Record, // The module of the instruction, as the loader recorded it: the module that ran. Zero: no record.
	// The stack trace: frame 0 is the instruction, each next frame the
	// return address of a call, from the frame pointers of the thread.
	frame_count: u64,
	frames:      [STOP_FRAME_CAPACITY]Stop_Frame,
	// Inspect_Kind.Stop only: the serial of the program of the slot, and the
	// values that the kernel took out (see Inspect_Kind.Stop).
	program_serial: u64,
	hidden_value_count: u64,
}

STOP_FRAME_CAPACITY :: 16

// One frame of a stack trace. A reader names it "module + offset": the
// offset is address - base. A return address is the instruction after
// the call.
Stop_Frame :: struct {
	address: u64,
	base:    u64, // The base of the module record that holds the address. 0: no record holds it.
	hash:    [32]u8, // The hash of that module.
}

// The module records of one program, in the order of their addresses.
Module_Report :: struct {
	count:   u64,
	modules: [PROGRAM_MODULE_CAPACITY]Module_Record,
	program_serial: u64, // The serial of the program of the slot: a reader drops reports of two programs.
}

// A budget: what its holders can still create. No operation creates an
// object from nothing: Memory_Create, Program_Create and Thread_Create take
// a budget handle, and the budget pays.
//   pages:    the pages of memory objects, of thread areas and of page tables.
//   programs: program slots.
//   threads:  thread slots.
// These three move: Budget_Create takes them from a budget for a new budget.
// Time does not return, so the two others are limits for each second:
//   processor:   microseconds of processor time in each second, on all the
//                processors together. 1 000 000 is one full processor.
//   log_records: records on the log in each second.
// A limit is for a budget and for each budget that came from it: what a
// thread uses counts in its budget and in each budget above. A new budget
// cannot have a limit above the limit of the budget that it came from. With
// the limit 0 a budget has no time: its threads do not run, and Log gives
// No_Budget. The processor limit holds in each period of 100 ms, the log
// limit in each second.
// The kernel gives one budget to the root service: all the free memory and
// all the slots. Budget_Create moves a part of a budget to a new budget.
// When an object ends, what it used returns to the budget that paid.
// When the last handle to a budget closes, what the budget holds returns to
// the budget that it came from, and that budget pays for its objects.
Budget_Amounts :: struct {
	pages:       u64,
	programs:    u64,
	threads:     u64,
	processor:   u64,
	log_records: u64,
}

// One word of a word wait: the address of 32 bits of memory, and the value
// that they hold while the thread waits.
Word :: struct {
	address: u64,
	value:   u64, // The low 32 bits.
}

WORD_WAIT_CAPACITY :: 64

// What the kernel tells a thread: the kernel adds 1 to the `events` word of
// the thread record and wakes the thread, when
//   an interrupt of the program arrives,
//   a program stops and this program holds its handle,
//   another thread of the program ends.
// The thread reads `events`, reads the state that it needs, then waits on
// the word with the value that it read first.

// What a thread can read about itself, at the address in its `gs` register.
// The kernel writes it when the thread starts. After that it only adds to `events`.
Thread_Record :: struct {
	self:      u64, // The address of this record. The kernel ring is PAGE_SIZE after it.
	parameter: u64, // The parameter of the entry of the thread.
	number:    u64, // The number of the thread in its program. The first thread is 0.
	events:    u32, // The kernel adds 1 for each event: see Word_Wait.
	processors: u32, // The processors that run threads: a thread that is alone on the machine does not spin.
	// The fault ring of the program, when this thread is its fault handler
	// (Fault_Handler_Set; docs/ARCHITECTURE.md, "The fault ring"). The kernel
	// writes fault_records[n % FAULT_RECORD_CAPACITY] for the record n, then
	// fault_written = n + 1, then wakes the threads that wait on
	// fault_written. The handler reads the records from fault_read to
	// fault_written and writes fault_read: a record is free again once
	// fault_read passed it. A fault that finds FAULT_RECORD_CAPACITY records
	// not read stops the program as a fault does with no handler, and the
	// kernel adds 1 to fault_full.
	fault_written: u32,
	fault_read:    u32,
	fault_full:    u32,
	fault_reserved: u32,
	fault_records: [FAULT_RECORD_CAPACITY]Fault_Record,
}
#assert(size_of(Thread_Record) <= PAGE_SIZE)

// The fault ring: one record for each fault that the kernel gave to the
// fault handler of a program in place of a stop. The thread of the record
// waits until a thread of the program answers (Fault_Answer).
FAULT_RECORD_CAPACITY :: 16

Fault_Record :: struct {
	thread:      u64, // The number of the thread in its program (Thread_Record.number).
	serial:      u64, // The serial of the fault: a count of the faults of this program that went to a ring (the first is 1). Fault_Answer names it, so an answer for an earlier fault, or for an ended thread whose number serves again, is refused.
	address:     u64, // A page fault: the address of the access. 0 for another kind.
	access:      u64, // A page fault: Fault_Access, what the access was. 0 for another kind.
	// The address where the thread continues after Resume. A fault: the
	// instruction that faulted, which runs again. A trap (Debug,
	// Breakpoint): the instruction after the one that trapped, so its
	// length is not known here: int3 (the byte CC) and int1 (the byte F1) are one byte, int 3
	// (CD 03) is two. A debugger that wrote CC subtracts 1.
	instruction: u64,
	kind:        Fault_Kind, // The processor exception.
	// The error code that the processor gave with the exception, whole.
	// General_Protection: 0; a selector that the program loaded or named;
	// or (n << 3) | 2 for an `int n` whose gate a program cannot use (0x72
	// for int 14), which is never the exception n. Segment_Not_Present and
	// Stack_Fault: 0 or a selector. Page_Fault: the bits of the access. 0
	// for a kind with no error code.
	error_code:  u64,
	reserved:    u64,
}
#assert(size_of(Fault_Record) == 64)

// The kind of a fault: the processor exception, named by its vector. These
// are the kinds that the kernel delivers to a fault handler. A fault class
// says where the thread continues after Resume.
//   Fault: the instruction did not run; its address is in the frame, and it
//          runs again.
//   Trap:  the instruction ran; the frame holds the address of the next one.
Fault_Kind :: enum u64 {
	Divide_Error        = 0, // Fault. div or idiv by 0, or a quotient too large.
	Debug               = 1, // Trap. The trap flag after an instruction, or int1. No debug register is set for a program, so no Debug is a fault.
	Breakpoint          = 3, // Trap. int3.
	Invalid_Opcode      = 6, // Fault. ud2, or an instruction that this processor does not have.
	Segment_Not_Present = 11, // Fault. A load of a segment register with a selector whose descriptor is not present.
	Stack_Fault         = 12, // Fault. A stack access at an address that is not canonical.
	General_Protection  = 13, // Fault. A privileged instruction, an address that is not canonical, a bad selector, `int n` for a vector other than 3; sgdt, sidt, sldt, smsw and str when the processor has UMIP.
	Page_Fault          = 14, // Fault. An access that the page table refuses.
	X87_Floating_Point  = 16, // Fault. An unmasked exception of the x87 unit, at the next x87 instruction (the kernel sets CR0.NE on each processor).
	Alignment_Check     = 17, // Fault. An access that is not aligned, with the flag AC set (the kernel sets CR0.AM on each processor).
	Simd_Floating_Point = 19, // Fault. An unmasked exception of an SSE or AVX instruction.
}
Fault_Kinds :: bit_set[Fault_Kind; u64]

// The vectors of the kinds above: the kinds that Fault_Handler_Set takes.
// The kernel never delivers the other vectors: the non-maskable interrupt
// (2), the double fault (8) and the machine check (18) are not faults of an
// instruction of a thread; overflow (4) and bound (5) are invalid
// instructions in 64-bit mode, which give Invalid_Opcode; device not
// available (7) and invalid task state (10) are mistakes of the kernel, which
// keeps the extended state and the task state of each processor; the other
// vectors below 32 are reserved or for modes that the kernel does not use.
FAULT_KINDS_DELIVERED :: u64(1 << 0 | 1 << 1 | 1 << 3 | 1 << 6 | 1 << 11 | 1 << 12 | 1 << 13 | 1 << 14 | 1 << 16 | 1 << 17 | 1 << 19)
// The kinds whose class is Trap.
FAULT_KINDS_TRAPS :: u64(1 << 1 | 1 << 3)
// The kinds after which Resume is accepted by itself: a trap continues after
// its instruction, and a handler changes what a page fault finds with
// Memory_Commit and Memory_Protect. Each other fault would run the same
// instruction on the same registers, and fault again with no end: after it,
// Resume is accepted only when Thread_Control wrote the registers or the
// extended state of the thread since the fault (the handler moved the
// instruction address, or changed the value that faulted).
FAULT_KINDS_RESUMABLE :: FAULT_KINDS_TRAPS | u64(1) << 14

// The class of a vector of the processor (fault_kind_class): Fault and Trap
// as above; a vector that is not a Fault_Kind is never delivered.
Fault_Class :: enum u8 {
	Never_Delivered = 0,
	Fault           = 1,
	Trap            = 2,
}

// fault_kind_class gives the class of a vector of the processor.
fault_kind_class :: proc "contextless" (vector: u64) -> Fault_Class {
	if vector >= 64 || FAULT_KINDS_DELIVERED & (u64(1) << vector) == 0 {
		return .Never_Delivered
	}
	if FAULT_KINDS_TRAPS & (u64(1) << vector) != 0 {
		return .Trap
	}
	return .Fault
}

// fault_kind_resumes says if Fault_Answer accepts Resume for a fault of a
// vector with no write of the registers of the thread.
fault_kind_resumes :: proc "contextless" (vector: u64) -> bool {
	return vector < 64 && FAULT_KINDS_RESUMABLE & (u64(1) << vector) != 0
}

// fault_kinds_of_argument gives the kinds that the argument of
// Fault_Handler_Set names, as a mask of vectors: 0 is page faults only, so
// that a handler of pages never gets a kind that it does not know. ok is
// false for a kind that the kernel never delivers.
fault_kinds_of_argument :: proc "contextless" (argument: u64) -> (mask: u64, ok: bool) {
	if argument & ~FAULT_KINDS_DELIVERED != 0 {
		return 0, false
	}
	if argument == 0 {
		return u64(1) << u64(Fault_Kind.Page_Fault), true
	}
	return argument, true
}

// What a faulting access was: the bits of the error code of the processor.
Fault_Access_Bit :: enum u64 {
	Present = 0, // The page has a translation: the access was not permitted. Without it: the page has no frame (not committed, or no mapping).
	Write   = 1,
	Execute = 4,
}
Fault_Access :: bit_set[Fault_Access_Bit; u64]

// The answer for a thread that waits in the fault ring.
Fault_Answer_Kind :: enum u64 {
	None   = 0,
	Resume = 1, // The thread continues with its registers: at the instruction of its record (the faulting instruction again, or the next one after a trap), or where Thread_Control wrote. For a kind of FAULT_KINDS_RESUMABLE, or after a write of Thread_Control.
	Stop   = 2, // The program stops as if no handler were set: the stop code and the stop report of the fault.
}

// What Thread_Control does. The results are in the completion record.
Thread_Control_Command :: enum u64 {
	None                 = 0,
	// Adds 1 to the stop count -> the count. When the operation returns, the
	// thread runs no instruction until its count is 0 again: a thread on
	// another processor left it; a thread in a wait stays in it, and does
	// not run when it ends. The calling thread itself stops after its kernel
	// entry. At most THREAD_STOP_COUNT_LIMIT (Bad_State above).
	// One case returns earlier: when the calling thread is itself held (it
	// stopped itself earlier in the same entry, or another thread stopped
	// it), the operation does not wait for a thread on another processor to
	// leave it, so that two threads that stop each other do not wait for
	// each other. That thread then leaves its processor at the interrupt
	// that the stop sent, and a read of its registers gets Bad_State until
	// it left.
	Stop                 = 1,
	// Takes 1 from the stop count -> the count. Bad_State at 0. At 0, a
	// thread whose wait ended runs again.
	Resume               = 2,
	// Writes a Thread_Registers at the address (size: at least its size) ->
	// the bytes written.
	Read_Registers       = 3,
	// Reads a Thread_Registers at the address (size: at least its size): the
	// thread continues with these registers. Bad_Operation for values that
	// a thread cannot hold (thread_registers_refusal): nothing changes.
	Write_Registers      = 4,
	// Writes the extended state area of the thread at the address (size: at
	// least the bytes of the area, Thread_State) -> the bytes written, the
	// components. The layout is the one of the processor: the standard form
	// of xsave, with the offset of each component from CPUID leaf 0xD; or
	// the 512 bytes of fxsave on a processor with no xsave.
	Read_Extended_State  = 5,
	// Reads the extended state area at the address: the thread continues
	// with it. Bad_Operation for an area that the processor would refuse
	// (extended_state_refusal): nothing changes.
	Write_Extended_State = 6,
}

// thread_control_rights gives the rights that a thread handle needs for a
// command of Thread_Control. A write lets its holder choose the code that
// the program of the thread runs, so it has its own right; a hold and a
// read do not, so a profiler gets them with no write; Control, the right to
// end a thread, gives neither.
thread_control_rights :: proc "contextless" (command: Thread_Control_Command) -> Rights {
	#partial switch command {
	case .Write_Registers, .Write_Extended_State:
		return {.Write}
	}
	return {.Inspect}
}

THREAD_STOP_COUNT_LIMIT :: 1 << 16

// The general registers, the instruction address and the flags of a thread
// that Thread_Control holds. The names are the names of the registers of
// the processor.
Thread_Registers :: struct {
	rax, rbx, rcx, rdx: u64,
	rsi, rdi, rbp, rsp: u64,
	r8, r9, r10, r11:   u64,
	r12, r13, r14, r15: u64,
	rip:    u64, // The address of the next instruction of the thread: below USER_END.
	rflags: u64, // THREAD_FLAGS_REQUIRED set, and no bit outside THREAD_FLAGS_ALLOWED.
	cs:     u64, // THREAD_CODE_SELECTOR: the one code selector of a program.
	ss:     u64, // THREAD_STACK_SELECTOR: the one stack selector of a program.
	// Read only, 1: the last entry of the thread into the kernel was a
	// syscall that has not returned yet: the thread waits in it, or its
	// processor left it after the operations of the entry and before the
	// return (its time slice ended, or a stop held it). At that return, rax
	// is the time, as after each kernel entry (the line at the top of this
	// file): a write of rax is lost; rcx and r11 hold what the syscall
	// instruction left there. 0: the thread left at an interrupt or a fault
	// of its own code, and each register is its own.
	in_kernel_entry: u64,
	reserved:        u64, // Not read.
}
#assert(size_of(Thread_Registers) == 176)

THREAD_CODE_SELECTOR :: 0x23
THREAD_STACK_SELECTOR :: 0x1B
// Interrupts on, and bit 1, which the processor always sets.
THREAD_FLAGS_REQUIRED :: u64(0x202)
// The flags that a thread of a program can hold: carry, parity, adjust,
// zero, sign, trap, interrupt, direction, overflow, resume, alignment check
// and identification, and bit 1. Not: the I/O privilege level, nested task,
// virtual-8086, the virtual interrupt flags, the reserved bits.
THREAD_FLAGS_ALLOWED :: u64(0x0025_0FD7)

// Which part of a Thread_Registers or of an extended state area a write
// refused.
Thread_Write_Refusal :: enum u64 {
	None                = 0,
	Code_Selector       = 1,
	Stack_Selector      = 2,
	Flags               = 3, // A required flag is clear, or a flag outside THREAD_FLAGS_ALLOWED is set.
	Instruction_Address = 4, // Not below USER_END.
	Stack_Address       = 5, // Not canonical.
	Mxcsr               = 6, // A bit that the processor does not take (its MXCSR mask).
	Header_Components   = 7, // XSTATE_BV names a component that the kernel does not save.
	Header_Reserved     = 8, // A byte of the header after XSTATE_BV is not 0.
}

// thread_registers_refusal says what a write of the registers of a thread
// refuses, and the value that it refuses. The checks are the conditions of
// the return of the processor to a program (iretq): with them, the kernel
// never faults at the return.
thread_registers_refusal :: proc "contextless" (registers: ^Thread_Registers) -> (refusal: Thread_Write_Refusal, value: u64) {
	switch {
	case registers.cs != THREAD_CODE_SELECTOR:
		return .Code_Selector, registers.cs
	case registers.ss != THREAD_STACK_SELECTOR:
		return .Stack_Selector, registers.ss
	case registers.rflags & THREAD_FLAGS_REQUIRED != THREAD_FLAGS_REQUIRED || registers.rflags & ~THREAD_FLAGS_ALLOWED != 0:
		return .Flags, registers.rflags
	case registers.rip >= USER_END:
		return .Instruction_Address, registers.rip
	case registers.rsp >> 47 != 0 && registers.rsp >> 47 != (u64(1) << 17) - 1:
		return .Stack_Address, registers.rsp
	}
	return .None, 0
}

// The places of an extended state area that a write checks (Intel SDM,
// volume 1, chapter 13).
EXTENDED_STATE_MXCSR_OFFSET :: 24
EXTENDED_STATE_LEGACY_BYTES :: 512 // The area of fxsave, and the first part of the area of xsave.
EXTENDED_STATE_HEADER_BYTES :: 64 // At EXTENDED_STATE_LEGACY_BYTES: XSTATE_BV, then XCOMP_BV and reserved bytes.

// extended_state_refusal says what a write of an extended state area
// refuses: the conditions under which xrstor or fxrstor fault on it, in the
// standard form. area holds the bytes of the area of this machine;
// components is XCR0; with_header is false for the form of fxsave, which
// has no header.
extended_state_refusal :: proc "contextless" (area: []u8, components: u64, mxcsr_mask: u32, with_header: bool) -> (refusal: Thread_Write_Refusal, value: u64) {
	if len(area) < EXTENDED_STATE_LEGACY_BYTES {
		return .Header_Reserved, u64(len(area))
	}
	mxcsr := u32(area[EXTENDED_STATE_MXCSR_OFFSET]) | u32(area[EXTENDED_STATE_MXCSR_OFFSET + 1]) << 8 | u32(area[EXTENDED_STATE_MXCSR_OFFSET + 2]) << 16 | u32(area[EXTENDED_STATE_MXCSR_OFFSET + 3]) << 24
	if mxcsr & ~mxcsr_mask != 0 {
		return .Mxcsr, u64(mxcsr)
	}
	if !with_header {
		return .None, 0
	}
	if len(area) < EXTENDED_STATE_LEGACY_BYTES + EXTENDED_STATE_HEADER_BYTES {
		return .Header_Reserved, u64(len(area))
	}
	little_endian_word :: proc "contextless" (bytes: []u8, at: int) -> (result: u64) {
		for index in 0 ..< 8 {
			result |= u64(bytes[at + index]) << u64(8 * index)
		}
		return
	}
	if header := little_endian_word(area, EXTENDED_STATE_LEGACY_BYTES); header & ~components != 0 {
		return .Header_Components, header
	}
	// XCOMP_BV 0 is the standard form; the reserved bytes are 0 in each
	// area that a save of the processor wrote.
	for at := EXTENDED_STATE_LEGACY_BYTES + 8; at < EXTENDED_STATE_LEGACY_BYTES + EXTENDED_STATE_HEADER_BYTES; at += 8 {
		if reserved := little_endian_word(area, at); reserved != 0 {
			return .Header_Reserved, reserved
		}
	}
	return .None, 0
}

// Kernel events (docs/ARCHITECTURE.md, "Kernel events"). The kind of a
// kernel event, and what the fields of its Event_Record hold:
//   Operation: one operation of a kernel entry. detail: the Operation;
//              value_0: its cycles of the cycle counter, from the start of
//              its execution to its end; value_1: its Status.
//   Switch:    a processor takes a thread from a run queue. The program and
//              the thread of the record are the thread taken; value_0: the
//              program slot of the thread that the processor left just
//              before (0: none: it was idle, or it took no thread first);
//              value_1: the number of that thread.
//   Fault:     an exception of a thread of a program. detail: the vector;
//              value_0: the address of a page fault, only when a rule that
//              names the program accepted the event (a rule for every
//              program gets 0: the order of the pages that a program
//              touches can show its data); 0 for another vector;
//              value_1: the Event_Fault_Outcome.
//   Lock_Wait: a processor took a lock of the kernel after a wait. detail:
//              the Lock_Kind; value_0: the cycles of the wait. The program
//              and the thread are the current thread of the processor (0:
//              none).
Event_Kind :: enum u32 {
	None      = 0,
	Operation = 1,
	Switch    = 2,
	Fault     = 3,
	Lock_Wait = 4,
}

// What the kernel did with a fault of a program (Event_Record.value_1 of a
// Fault).
Event_Fault_Outcome :: enum u64 {
	None      = 0,
	First_Use = 1, // A page on first use: the page has its frame, and the instruction runs again.
	Fault_Ring = 2, // A record of the fault ring of the program: the thread waits for an answer.
	Stopped   = 3, // The program stops.
}

Event_Rule_Flag :: enum u32 {
	Match_Detail = 0, // The detail of the event must be the detail of the rule. Not for Switch.
}
Event_Rule_Flags :: bit_set[Event_Rule_Flag;u32]

// One rule of the event table. A rule accepts a kernel event of its kind
// when each of its tests passes: the program, the detail with Match_Detail,
// the least duration; then "one in N": of the events that passed the other
// tests of this rule, since the table was given, the event N, 2N, 3N and so
// on. A kernel event that a rule accepts is one Event_Record, whatever the
// other rules say. The kernel tests the rules in their order: at most
// EVENT_RULE_CAPACITY tests of a few fields, with no lock.
Event_Rule :: struct {
	kind:    Event_Kind,
	flags:   Event_Rule_Flags,
	// A program handle of the caller with the right Read: only the events
	// of that program, with the address of its page faults (Read gives its
	// stop report, which has that address already). 0: every program and
	// the kernel itself (program 0), with no address of a fault.
	program: u64,
	detail:  u64, // With Match_Detail: the Operation, the vector of a Fault, or the Lock_Kind.
	// Operation and Lock_Wait: the least duration in nanoseconds, at most
	// EVENT_LEAST_NANOSECONDS_MOST. 0 for Switch and Fault.
	least_nanoseconds: u64,
	one_in:  u64, // 0 and 1: each event. N: one in N, at most EVENT_ONE_IN_MOST.
	reserved: [3]u64, // 0.
}
#assert(size_of(Event_Rule) == 64)

EVENT_RULE_CAPACITY :: 16
EVENT_LEAST_NANOSECONDS_MOST :: 1_000_000_000
EVENT_ONE_IN_MOST :: 1 << 32
EVENT_RING_RECORDS_LEAST :: 16
EVENT_RING_RECORDS_MOST :: 1 << 20

// One kernel event, in the event ring of the processor where it came.
Event_Record :: struct {
	time:      u64, // The cycle counter at the event point (Time_Record: cycle_start and cycle_frequency).
	kind:      Event_Kind,
	processor: u32, // The index of the processor.
	program:   u32, // The slot of the program. 0: the kernel, with no thread.
	thread:    u32, // The number of the thread in its program (Thread_Record.number). 0 when program is 0.
	program_serial: u64, // The serial of the program of the slot (Program_Report.program_serial).
	detail:    u64,
	value_0:   u64,
	value_1:   u64,
	reserved:  u64,
}
#assert(size_of(Event_Record) == 64)

// The head of one event ring. The ring of processor p starts at the byte
// p * (EVENT_RING_HEAD_BYTES + records * 64) of the memory object; its
// records follow its head. The kernel writes the record n at the index
// n % records, then `written` = n + 1. The program reads the records from
// `read` to `written`, then writes `read`: a place is free for the kernel
// again once `read` passed it. When records - (written - read) is 0, the
// kernel drops the record and adds 1 to `lost`: it never waits, and it
// never writes over a record that the program did not read. The kernel
// keeps its own counts; it reads only `read` from this memory, and a false
// value there loses records of this program, or lets the kernel write over
// records that this program did not read: nothing else.
Event_Ring :: struct {
	// The line that the kernel writes.
	written:   u64,
	lost:      u64,
	records:   u64, // The capacity of the ring, written when the table is given.
	processor: u64,
	reserved_kernel: [4]u64,
	// The line that the program writes.
	read:      u64,
	reserved_program: [7]u64,
}
#assert(size_of(Event_Ring) == 128)
EVENT_RING_HEAD_BYTES :: size_of(Event_Ring)

Status :: enum u32 {
	Ok            = 0,
	Bad_Operation = 1,
	Bad_Handle    = 2,
	Bad_Address   = 3,
	No_Memory     = 4,
	No_Slot       = 5,
	Bad_State     = 6,
	No_Right      = 7, // The handle names the object, but it does not have the right for this operation.
	No_Budget     = 8, // The budget cannot pay for the operation.
}

// The kernel keeps the page frames of a memory object in a frame list: in
// the record of the object for at most MEMORY_INLINE_PAGES pages; else in
// list pages of MEMORY_LIST_ENTRIES frames each, and for more than one list
// page, a top page that names them. The budget pays for the list pages too.
MEMORY_INLINE_PAGES :: 4
MEMORY_LIST_ENTRIES :: 512
MEMORY_PAGE_LIMIT :: MEMORY_LIST_ENTRIES * MEMORY_LIST_ENTRIES // The pages of one memory object: 1 GiB.

// memory_list_pages gives the list pages of a memory object.
memory_list_pages :: proc "contextless" (page_count: u64) -> u64 {
	switch {
	case page_count <= MEMORY_INLINE_PAGES:
		return 0
	case page_count <= MEMORY_LIST_ENTRIES:
		return 1
	}
	return 1 + (page_count + MEMORY_LIST_ENTRIES - 1) / MEMORY_LIST_ENTRIES
}

// memory_cost gives the pages that Memory_Create takes from a budget.
memory_cost :: proc "contextless" (page_count: u64) -> u64 {
	return page_count + memory_list_pages(page_count)
}

Memory_Flag :: enum u64 {
	Frames_Now = 0, // Each page gets its page frame at creation, not at its first use.
	// The page frames follow each other in physical memory, each one from the creation, and they do
	// not move: memory that a device reads and writes (Memory_Physical). The budget pays for no frame
	// list. It can give No_Memory when the budget can pay: no free run is long enough.
	Contiguous = 1,
	// The pages are not paid at the creation: the budget pays the frame list only. Memory_Commit pays pages
	// and makes them usable; a page that is not committed has no frame, and an access to it is a fault.
	Uncommitted = 2,
	// Contiguous, in one run aligned on 2 MiB, and the page count is a multiple of LARGE_PAGE_PAGES: a mapping
	// uses a large page for each 2 MiB whose address and first page are aligned.
	Large_Pages = 3,
}
Memory_Flags :: bit_set[Memory_Flag;u64]

LARGE_PAGE_PAGES :: 512 // The pages of 4096 bytes of one large page (2 MiB).
RANGE_TABLE_CAPACITY :: 256 // The ranges of one Memory_Commit or Memory_Protect.
// The pages of all the ranges of one Memory_Commit or Memory_Protect (256 MiB): the kernel walks each page with
// interrupts off; a larger change is several calls.
RANGE_TABLE_PAGE_LIMIT :: 65536

// A range of pages of a memory object (Memory_Commit).
Page_Range :: struct {
	first:      u64, // The first page of the object.
	page_count: u64,
}

// A range of addresses of the program (Memory_Protect).
Address_Range :: struct {
	address:    u64, // A multiple of PAGE_SIZE.
	page_count: u64,
}

Commit_Flag :: enum u64 {
	Decommit = 0,
}
Commit_Flags :: bit_set[Commit_Flag;u64]

Map_Flag :: enum u64 {
	Write   = 0,
	Execute = 1,
	No_Access = 2, // Memory_Map: a mapping whose pages fault until Memory_Protect gives them access. Memory_Protect: no access.
}
Map_Flags :: bit_set[Map_Flag;u64]

// The code of a program that the kernel stopped.
STOP_CODE_FAULT :: 0x100 // Add the number of the processor exception: 14 is a page fault.
STOP_CODE_NO_HANDLE :: 0x200 // The last handle to the program closed.
STOP_CODE_NOT_COMMITTED :: 0x300 // A page fault on a page of an Uncommitted object that is not committed.
STOP_CODE_RETURN :: 0x400 // The kernel cannot return to a thread of the program: its instruction or stack address is not one that the processor takes (docs/ARCHITECTURE.md, "The return to a program"). The stop report has the address in `address`.
STOP_CODE_FAULT_UNANSWERED :: 0x500 // The fault ring of the program ended while a thread waited for an answer in it: its handler thread ended, or Fault_Handler_Set named another handler or ended the delivery.

// The state of a program or of a thread. A program is Ready when one of
// its threads is Ready.
Program_State :: enum u32 {
	None    = 0,
	Created = 1,
	Ready   = 2,
	Waiting = 3,
	Stopped = 4,
}

Device_Kind :: enum u64 {
	None      = 0,
	Ports     = 1,
	Interrupt = 2, // A line of the 8259.
	Memory    = 3, // The registers of a device.
	Message   = 4, // A message interrupt.
}

// The message interrupts: each one has a vector of its own on the first
// processor.
MESSAGE_CAPACITY :: 16

Inspect_Kind :: enum u64 {
	None    = 0,
	System  = 1, // System_Report
	Program   = 2, // Program_Report of program slot `index`
	Processor = 3, // Processor_Report of processor `index`
	Boot      = 4, // Boot_Report
	Mappings  = 5, // Mapping_Report. index 0: the kernel half of the addresses. 1: the half of the program that asks.
	Modules   = 6, // Module_Report of program slot `index`
	// The reports of a developer tool (docs/TOOLS.md): what one program has,
	// read with the right Inspect: counts, places and states. A program
	// without that right sees no other program.
	// Each one has the serial of the program, so that a reader drops a
	// sample of two programs in one slot.
	Program_Mappings = 7, // Program_Mapping_Report of program slot `index`.
	Threads          = 8, // Thread_Table_Report of program slot `index`.
	// Stop_Report of program slot `index`: zero when it did not stop on a
	// fault, or when the slot has no program. A frame of a stack trace comes
	// from the stack of the program, and a corrupt chain of frame pointers
	// gives values of its memory; the address of a page fault can be a
	// value too. So the kernel gives a frame only when a module record of
	// the program holds its address (else the frame is all zero), and the
	// address of the fault only in the first page or in a module record
	// (else 0). hidden_value_count counts what it took out. The holder of the
	// program handle with Read still reads the whole report (Program_State).
	Stop             = 9,
	// Page_Report of the program that asks, for the address that it writes
	// in the Page_Report: which of the 64 pages from it have a frame. Index
	// must be 0: a page that gets a frame in another program is a fact that
	// it can watch page by page (a side channel), so no slot but its own.
	Pages            = 10,
}

// One mapping of a program: Program_Mapping_Report.
Program_Mapping_Flag :: enum u32 {
	Write       = 0,
	Execute     = 1,
	Uncached    = 2, // The registers of a device.
	Device      = 3, // The frames are not from the page frame table: a framebuffer, boot data, a device.
	Contiguous  = 4,
	Shared      = 5, // Another mapping or another handle names the memory object.
	Thread_Area = 6, // The thread record and the kernel ring of a thread.
	Uncommitted = 7, // An object made with Uncommitted: `committed` says which part its budget pays.
	Large       = 8, // The mapping uses large pages of 2 MiB.
	Protected   = 9, // Memory_Protect changed the protection of pages of the mapping.
	No_Access   = 10, // The protection of the mapping is No_Access now.
}

Program_Mapping :: struct {
	address:       u64,
	page_count:    u64,
	first:         u64, // The first page of the memory object.
	present:       u64, // The pages of this mapping that have a page frame, from the page table.
	region_pages:  u64, // The pages of the memory object.
	region_serial: u64, // The memory object: two mappings with one serial map one object.
	flags:         bit_set[Program_Mapping_Flag;u32],
	references:    u32, // The handles and the mappings that name the memory object, in all programs.
	committed:     u64, // The committed pages of the memory object: all its pages, unless it was made Uncommitted.
}
#assert(size_of(Program_Mapping) == 64)

MAPPING_REPORT_CAPACITY :: 128 // MAPPING_CAPACITY of the kernel.

// The mappings of one program, in the order of their addresses.
Program_Mapping_Report :: struct {
	program_serial: u64,
	count:    u64,
	mappings: [MAPPING_REPORT_CAPACITY]Program_Mapping,
}

// One thread of a program: Thread_Table_Report. The kernel reads the
// fields of the scheduler with no lock: each field is whole, two fields can
// come from two instants.
Thread_Report :: struct {
	number:           u32, // The thread area of the thread in the program.
	state:            Program_State, // Ready or Waiting (Stopped: it ended).
	processor:        u32, // 1 + the processor that runs it now. 0: none.
	home:             u32, // The processor of its run queue.
	weight:           u32,
	request:          u32, // Microseconds.
	words:            u32, // The words of the word wait that it is in. 0: no word.
	queued:           u32, // 1: it is in the run queue of home.
	virtual:          u64,
	virtual_deadline: u64,
	lag:              i64,
	run_time:         u64, // Milliseconds of processor time: the ticks in which it ran.
	deadline:         u64, // The end of its wait, in milliseconds since the start. WAIT_FOREVER: none.
}
#assert(size_of(Thread_Report) == 72)

THREAD_REPORT_CAPACITY :: 32 // The thread areas of one program.

Thread_Table_Report :: struct {
	program_serial: u64,
	count:   u64,
	threads: [THREAD_REPORT_CAPACITY]Thread_Report,
}

// The pages of a range of a program that have a page frame: a reader that
// shows the bytes of memory knows which pages it can read with no fault,
// and does not give a frame to a page by its read.
PAGE_REPORT_CAPACITY :: 64

Page_Report :: struct {
	address: u64, // The first page: the caller writes it, a multiple of 4096.
	present: u64, // Bit n: page n has a frame.
	mapped:  u64, // Bit n: page n is in a mapping.
}

System_Report :: struct {
	time:          u64, // Milliseconds since boot.
	page_count:    u64, // Pages of memory that the kernel manages.
	free_pages:    u64, // The free frames: in the frame table and in the frame caches of the processors.
	program_slots: u64,
	region_count:  u64, // Memory objects in use.
	entries:       u64, // Kernel entries since boot.
	interrupts:    u64,
	budget_pages:  u64, // The pages of all the budgets. free_pages - reserved_pages is always budget_pages, exactly: each page is free or paid.
	// free_pages and reserved_pages alone are not values of one instant: the processors take frames from their
	// caches while the kernel reads them; their difference is exact (docs/ARCHITECTURE.md, "The frame caches").
	processors:    u64, // The processors that run threads.
	reserved_pages:   u64, // Pages that a budget paid for and that have no page frame yet: pages on first use.
	first_use_faults: u64, // Page faults of programs after which the page was present.
	locks:            [LOCK_KIND_CAPACITY]Lock_Count, // By Lock_Kind.
	strategy:         Strategy, // The scheduling strategy of the machine (Strategy_Set): the new one as soon as a change starts, before each run queue converted (Processor_Report.strategy).
	strategy_changes: u32, // The calls of Strategy_Set since boot.
}

// The locks of the kernel, by the data that each one protects
// (docs/ARCHITECTURE.md, "Locks of the kernel"). The order of the kinds is
// the lock order: a processor takes a lock only if it holds no lock of a
// later kind.
Lock_Kind :: enum u64 {
	Control = 0, // The paths that cross programs or end objects that several programs name: rare.
	Program = 1, // The handles, the mappings and the page table of one program.
	Origin  = 2, // The origin tree of the holdings.
	Region  = 3, // One memory object: it gives a page on first use one frame.
	Frame   = 4, // The page frames, the reserved pages, the pages of the budgets, the slots of the memory objects.
	Cache   = 5, // The stack of free page frames of one processor (its frame cache).
	Log     = 6, // The serial port and the records of the log.
	Wait    = 7, // One bucket of the wait table: the threads that wait on its words.
	Run     = 8, // The run queue of one processor, and the scheduling state of its threads.
}

LOCK_KIND_CAPACITY :: 12

@(rodata)
LOCK_KIND_NAMES := [Lock_Kind]string {
	.Control = "control",
	.Program = "program",
	.Origin  = "origin",
	.Region  = "region",
	.Frame   = "frame",
	.Cache   = "cache",
	.Log     = "log",
	.Wait    = "wait",
	.Run     = "run",
}

// What the kernel counts for one kind of lock, on all the processors.
Lock_Count :: struct {
	takes: u64, // The times that a processor took a lock of this kind.
	waits: u64, // The times that the lock was held, and the processor had to wait for it.
}

Processor_Report :: struct {
	program:   u64, // The slot of the program that the processor runs. 0: the processor is idle.
	busy_time: u64, // Milliseconds with a thread.
	same:      u64, // 1: the program is the program that asks.
	apic_id:   u64, // The number that the machine gives to the processor.
	// The scheduler (docs/SCHEDULING.md), since boot.
	strategy:    Strategy, // The strategy of the run queue of the processor.
	queued:      u32, // The threads in the run queue now.
	picks:       u64, // Threads that a pick gave to the processor.
	preemptions: u64, // Turns that a wake preemption ended.
	moves:       u64, // Threads that the processor took from the queue of another processor.
	pick_cycles: u64, // Cycles of the cycle counter in all the picks.
	interrupt_preemptions: u64, // Wake preemptions by an interrupt from another processor.
	preempt_cycles: u64, // Their cycles in the kernel: from the handler of the interrupt to the next thread.
	// The frame cache of the processor: a stack of free page frames.
	cache_frames:        u64, // The frames on the stack now.
	cache_batches_taken: u64, // Batches that the stack took from the frame table.
	cache_batches_given: u64, // Batches that the stack gave back.
	cache_drains:        u64, // Drains that took the frames of the stack, for a take that found no free frame.
}

// The log: records in channels.
//
// The kernel keeps the last LOG_RECORD_CAPACITY records in one memory
// object. The kernel is the one writer: it sets the time, the program and
// the thread of each record, so a program cannot write a record of another
// program. A program chooses only the level, the channel and the text.
// A reader maps the memory object without Write. It reads Log_Head.written,
// and it waits on the low 32 bits of that word (Word_Wait).
//
// Record n is at index n % LOG_RECORD_CAPACITY, after the head. A reader
// that is late by more than the capacity lost records: it knows how many.
// The kernel can write over a record while a reader copies it: the reader
// reads `written` again after the copy.
Log_Level :: enum u8 {
	Info    = 0,
	Debug   = 1, // For the person who looks for a fault.
	Warning = 2,
	Error   = 3,
}

LOG_TEXT_CAPACITY :: 176
LOG_CHANNEL_CAPACITY :: 16
// 128 pages: 2047 records. With 64 pages (1023 records), the main machine
// test wrote about 1024 records before it starts the program log, which
// checks that it lost none: each new line of a program broke the check.
LOG_PAGES :: 128
LOG_RECORD_CAPACITY :: LOG_PAGES * 4096 / size_of(Log_Record) - 1

Log_Head :: struct {
	written:  u64, // The count of records since the start of the machine.
	capacity: u64, // LOG_RECORD_CAPACITY.
	reserved: [30]u64,
}

Log_Record :: struct {
	sequence:   u64, // The number of the record, from 0.
	time:       u64, // Microseconds since the start of the machine.
	program:    u32, // The slot of the program. 0: the kernel.
	thread:     u32, // The slot of the thread. 0: the kernel.
	level:      Log_Level,
	more:       u8, // 1: the text continues in the next record.
	text_count: u16,
	reserved:   u32,
	name:       [32]u8, // The name of the program, or "kernel".
	channel:    [LOG_CHANNEL_CAPACITY]u8, // All zero: the program gave no channel.
	text:       [LOG_TEXT_CAPACITY]u8,
}

#assert(size_of(Log_Record) == 256)
#assert(size_of(Log_Head) == size_of(Log_Record))

// The stacks of the kernel. Each processor has one slot of addresses: a
// guard page with no memory, the kernel stack, a guard page, the stack of
// the double fault, then the interrupt stacks of the debug exception, the
// non-maskable interrupt and the machine check, each after a guard page,
// and guard pages to the end of the slot.
KERNEL_STACK_BASE :: 0xFFFF_FF00_0000_0000
KERNEL_STACK_SLOT_PAGES :: 32
KERNEL_STACK_PAGES :: 16 // From page 1 of the slot.
KERNEL_FAULT_STACK_PAGES :: 4 // From page 2 + KERNEL_STACK_PAGES of the slot.
// Each of the three other interrupt stacks. Each one holds only the frame
// and the report of a fault of the kernel: a debug exception of a program
// leaves it for the kernel stack at once.
KERNEL_INTERRUPT_STACK_PAGES :: 2
KERNEL_INTERRUPT_STACK_COUNT :: 3
// The first page in the slot of an interrupt stack (0: debug, 1:
// non-maskable interrupt, 2: machine check).
kernel_interrupt_stack_first_page :: proc "contextless" (stack_index: u64) -> u64 {
	return 2 + KERNEL_STACK_PAGES + KERNEL_FAULT_STACK_PAGES + 1 + stack_index * (KERNEL_INTERRUPT_STACK_PAGES + 1)
}
// The pages of the slot that hold a stack; each other page is a guard page.
KERNEL_STACK_SLOT_STACK_PAGES :: KERNEL_STACK_PAGES + KERNEL_FAULT_STACK_PAGES + KERNEL_INTERRUPT_STACK_COUNT * KERNEL_INTERRUPT_STACK_PAGES
#assert(1 + KERNEL_STACK_PAGES + 1 + KERNEL_FAULT_STACK_PAGES + KERNEL_INTERRUPT_STACK_COUNT * (1 + KERNEL_INTERRUPT_STACK_PAGES) < KERNEL_STACK_SLOT_PAGES)

// A run of pages that a page table gives, with one protection.
Mapping_Flag :: enum u64 {
	Write   = 0,
	Execute = 1,
	Program = 2, // A program can use the pages.
	Large   = 3, // The table holds pages of 2 MiB.
}

Mapping_Run :: struct {
	start:      u64,
	page_count: u64, // Pages of 4096 bytes.
	flags:      bit_set[Mapping_Flag;u64],
}

MAPPING_RUN_CAPACITY :: 96

// What the page table says, as the kernel reads it from the table itself.
Mapping_Report :: struct {
	run_count:           u64, // The runs of the table. `runs` has the first ones.
	runs:                [MAPPING_RUN_CAPACITY]Mapping_Run, // By address.
	pages:               u64,
	write_pages:         u64,
	execute_pages:       u64,
	write_execute_pages: u64, // Always 0: no page is both.
	guard_pages:         u64, // Kernel half: the pages around the kernel stacks that have no memory.
	guards_expected:     u64,
	kernel_guard:        u64, // 1: the processors refuse the memory of programs to the kernel, outside a copy.
	kernel_no_execute:   u64, // 1: the processors refuse to execute the memory of programs in the kernel.
}

// The record of how the machine started. A time is a number of
// microseconds since the machine started.
BOOT_STAGE_CAPACITY :: 12
BOOT_RANGE_CAPACITY :: 64

Boot_Stage :: struct {
	name:     [48]u8, // Zero bytes after the name.
	start:    u64,
	duration: u64,
}

// A run of physical memory, as the firmware gave it. kind is a
// boot_info.Memory_Kind: 0 not usable, 1 free, 2 loaded by the boot program.
Boot_Range :: struct {
	start:      u64,
	page_count: u64,
	kind:       u64,
}

// boot_range_add adds a run of memory to a report. The runs come by
// address. A run that continues the last one, with the same kind, joins it.
boot_range_add :: proc "contextless" (report: ^Boot_Report, start, page_count, kind: u64) {
	report.firmware_ranges += 1
	if report.range_count != 0 {
		last := &report.ranges[report.range_count - 1]
		if last.kind == kind && last.start + last.page_count * 4096 == start {
			last.page_count += page_count
			return
		}
	}
	if report.range_count < BOOT_RANGE_CAPACITY {
		report.ranges[report.range_count] = {start = start, page_count = page_count, kind = kind}
		report.range_count += 1
	}
}

Boot_Report :: struct {
	time:                   u64, // Now.
	stage_count:            u64,
	stages:                 [BOOT_STAGE_CAPACITY]Boot_Stage,
	range_count:            u64,
	ranges:                 [BOOT_RANGE_CAPACITY]Boot_Range, // By address. Neighbours of one kind are one range.
	firmware_ranges:        u64, // The ranges that the firmware gave.
	firmware_vendor:        [32]u8,
	firmware_revision:      u64,
	framebuffer_address:    u64,
	framebuffer_width:      u64,
	framebuffer_height:     u64,
	framebuffer_line:       u64, // Pixels from one line to the next.
	framebuffer_format:     u64, // A boot_info.Pixel_Format.
	kernel_size:            u64, // Bytes of the kernel in memory.
	kernel_file_size:       u64,
	boot_image_size:        u64,
	direct_map_size:        u64,
	acpi_root:              u64,
	cycle_frequency:        u64, // Cycles of the cycle counter per second.
	timer_frequency:        u64, // Counts of the timer of a processor per second.
	trust:                  info.Boot_Trust, // The trust record of the boot program, as it wrote it.
}

Program_Report :: struct {
	state:        Program_State,
	code:         u32,
	name:         [32]u8,
	mapped_pages: u64,
	handle_count: u64,
	run_time:     u64, // Milliseconds of processor time.
	entries:      u64,
	thread_count: u64,
	start_time:   u64, // Microseconds since the machine started.
	budget:       Budget_Amounts, // What the budget that pays for the program still holds.
	present_pages: u64, // The mapped pages that have a page frame.
	program_serial: u64, // A number that changes for each new program in the slot: two reports with the same serial are of one program.
}

// The context: the one record that a program receives when it starts, in
// place of text arguments that it must parse. The address of the record is
// the parameter of the entry.
CONTEXT_HANDLES :: 16
// The values 0 to 15 began as free values, and the roles of the system
// took 9 to 15 one after the other until two roles wanted one number. The
// values 16 to 23 are for the roles that the system fixes for every
// program: a new role of the system takes a number there, never under 16.
// A starter and its program use 0 to 8 for their own values.
CONTEXT_VALUES :: 24

// It holds no text: a program has nothing to parse.
Context :: struct {
	handles: [CONTEXT_HANDLES]Handle, // The granted handles. The role of each index is fixed by who starts the program,
	// except the last two.
	values:  [CONTEXT_VALUES]u64,
}

// The two roles that the system fixes for each program. A handle that the
// program was not granted is 0.
CONTEXT_LOG :: 14 // The log of the kernel.
// The values 9 to 12: the random seed of the program, 32 bytes, that its
// starter writes (docs/RANDOMNESS.md). A start with a seed of zeros is
// refused. The root service has none: it gathers its own. A program does
// not use the values 9 to 12 for another role.
CONTEXT_VALUE_SEED :: 9
CONTEXT_VALUE_SEED_COUNT :: 4
// The value 16: the strength of the seed of the system, from which the seed
// of the program comes (support/random, Seed_Strength): 1 weak (the cycle
// counter only), 2 processor (rdrand), 3 entropy (rdseed). The starter
// writes it with the seed.
CONTEXT_VALUE_SEED_STRENGTH :: 16
// The value 17: the program `settings` runs its boot pass (1): it reads the
// settings kept in its store, writes the settings page, and stops, with no
// window (contract:settings).
CONTEXT_VALUE_SETTINGS_BOOT_PASS :: 17
// The values 18 and 19: the address and the size of the second pointer
// theme file that the root service gives the compositor (the theme of the
// system, beside the theme of the owner at the values 6 and 7 of the
// compositor). The setting "pointer_theme" chooses between the two.
CONTEXT_VALUE_SECOND_POINTER_THEME_ADDRESS :: 18
CONTEXT_VALUE_SECOND_POINTER_THEME_SIZE :: 19
// The value 20: a set of bits, bit n for the member n of the fixed ranges
// (contract:fixed_addresses, Fixed_Range): the ranges that the starter
// mapped for this program. A set bit is the statement of the starter that
// the range is mapped; a program reads nothing at a fixed range whose bit
// is clear. It is a value of the context, which only the starter writes,
// and not a field of a shared page, which another program can write. The
// values 21, 22 and 23 have no role.
CONTEXT_VALUE_FIXED_RANGES_MAPPED :: 20
CONTEXT_BUDGET :: 15 // The budget of the program.
// The values 13 and 15 have no role: the settings page and the date page
// are fixed ranges, mapped when their bit of the value 20 is set. A new
// role of the system takes a number from 16, never 13 or 15, so that an
// old reader cannot take a new value for a page.

// The roles of the first program (the root service).
ROOT_MACHINE :: 0
ROOT_FRAMEBUFFER :: 1
ROOT_BOOT_IMAGE :: 2
ROOT_LOG_RECORDS :: 3 // Memory, with Read: the records of the log.
ROOT_VALUE_WIDTH :: 0
ROOT_VALUE_HEIGHT :: 1
ROOT_VALUE_PIXELS_PER_LINE :: 2
ROOT_VALUE_FORMAT :: 3
ROOT_VALUE_BOOT_IMAGE_SIZE :: 4
