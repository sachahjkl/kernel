// The kernel operations: what a program can ask the kernel (property 1).
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
	Write   = 2, // Memory: map it with Write. Log: write text on the log.
	Execute = 3, // Memory: map it with Execute.
	Control = 4, // Program: map memory in it, give handles to it, start it, stop it. Thread: stop it.
	Inspect = 5, // Machine: read the reports.
	Devices = 6, // Machine: create device handles.
	Stop    = 7, // Machine: stop the machine.
	Spend   = 8, // Budget: create objects with it, and take a part of it for a new budget.
	Physical = 9, // Machine: read the physical address of a memory object (Memory_Physical).
	Schedule = 10, // Machine: change the scheduling strategy of the machine (Strategy_Set).
	// Budget: pay pages of a memory object that this budget already pays for (Memory_Commit), and nothing else: no
	// object, thread, program or budget is created with it. The narrow form of Spend, to give to another program.
	Commit = 11,
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
	Thread_State   = 18, // (thread) -> Program_State: Ready, Waiting or Stopped.
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
	// Commit or Spend (owner, 2026-11-11: the right Write on the object does not spend the budget of its maker; to let
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
}

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
	// read with the right Inspect: counts, places and states (property 20).
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
// checks that it lost none: each new line of a program broke the check
// (docs/FIRST_MILESTONE.md, the choice of the pointer pictures).
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
// the double fault, and guard pages to the end of the slot.
KERNEL_STACK_BASE :: 0xFFFF_FF00_0000_0000
KERNEL_STACK_SLOT_PAGES :: 32
KERNEL_STACK_PAGES :: 16 // From page 1 of the slot.
KERNEL_FAULT_STACK_PAGES :: 4 // From page 2 + KERNEL_STACK_PAGES of the slot.

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

// The context: the one record that a program receives when it starts
// (property 19). The address of the record is the parameter of the entry.
CONTEXT_HANDLES :: 16
CONTEXT_VALUES :: 16

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
CONTEXT_BUDGET :: 15 // The budget of the program.
// The value that the root service fixes for each program that it starts
// with a surface or a terminal: values[13] is the address of the settings
// page (contract:settings, VALUE_PAGE), 0 for none. A program does not use
// value 13 for another role.

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
