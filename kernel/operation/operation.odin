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
USER_END :: 0x0000_8000_0000_0000

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
}
Rights :: bit_set[Right;u32]

Operation :: enum u32 {
	None           = 0,
	Log            = 1, // (log, address, count): write text on the log of the kernel.
	Memory_Create  = 2, // (budget, page_count) -> memory handle. The memory is zero.
	Memory_Map     = 3, // (memory, program or 0 for self, address or 0, Map_Flags, first page, page_count or 0 for all) -> address
	Memory_Unmap   = 4, // (program or 0, address)
	Memory_Size    = 5, // (memory) -> page_count
	Program_Create = 6, // (budget, name address, name count) -> program handle. The program has no memory and no handle.
	// The budget pays for the program, for its page tables and for its first thread.
	Program_Start  = 7, // (program, entry address, stack address, context address): the first thread of the program.
	Program_Stop   = 8, // (program or 0 for self, code)
	Program_State  = 9, // (program) -> Program_State, code
	Handle_Give    = 10, // (target: program handle or memory handle, handle, Rights) -> the handle in the target program.
	// The new handle has the rights of the handle that are also in Rights: a grant never adds a right.
	// With a memory handle, the target is the other program that maps this memory: the other side of a ring.
	Handle_Close   = 11, // (handle). The kernel stops a program when its last handle closes.
	Interrupt_Read = 12, // (interrupt) -> the number of interrupts since the last read.
	Device_Create  = 13, // (machine, Device_Kind, a, b) -> handle. Ports: a = first port, b = count. Interrupt: a = line.
	Inspect        = 14, // (machine, Inspect_Kind, index, address, size) -> bytes written
	Machine_Stop   = 15, // (machine, code)
	Thread_Create  = 16, // (budget, entry address, stack address, parameter) -> thread handle. A new thread of this program.
	// The thread starts at the entry with the parameter in the first register.
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
	Budget_Create  = 21, // (budget, pages, programs, threads) -> budget handle. The amounts move from the budget to the new budget.
	Budget_Read    = 22, // (budget) -> pages, programs, threads: what the budget can still pay.
}

// A budget: what its holders can still create. No operation creates an
// object from nothing: Memory_Create, Program_Create and Thread_Create take
// a budget handle, and the budget pays.
//   pages:    the pages of memory objects, of thread areas and of page tables.
//   programs: program slots.
//   threads:  thread slots.
// The kernel gives one budget to the root service: all the free memory and
// all the slots. Budget_Create moves a part of a budget to a new budget.
// When an object ends, what it used returns to the budget that paid.
// When the last handle to a budget closes, what the budget holds returns to
// the budget that it came from, and that budget pays for its objects.
Budget_Amounts :: struct {
	pages:    u64,
	programs: u64,
	threads:  u64,
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

Map_Flag :: enum u64 {
	Write   = 0,
	Execute = 1,
}
Map_Flags :: bit_set[Map_Flag;u64]

// The code of a program that the kernel stopped.
STOP_CODE_FAULT :: 0x100 // Add the number of the processor exception: 14 is a page fault.
STOP_CODE_NO_HANDLE :: 0x200 // The last handle to the program closed.

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
	Interrupt = 2,
}

Inspect_Kind :: enum u64 {
	None    = 0,
	System  = 1, // System_Report
	Program = 2, // Program_Report of program slot `index`
}

System_Report :: struct {
	time:          u64, // Milliseconds since boot.
	page_count:    u64, // Pages of memory that the kernel manages.
	free_pages:    u64,
	program_slots: u64,
	region_count:  u64, // Memory objects in use.
	entries:       u64, // Kernel entries since boot.
	interrupts:    u64,
	budget_pages:  u64, // The pages of all the budgets. It is always free_pages: each page is free or paid.
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
	budget:       Budget_Amounts, // What the budget that pays for the program still holds.
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
CONTEXT_BUDGET :: 15 // The budget of the program.

// The roles of the first program (the root service).
ROOT_MACHINE :: 0
ROOT_FRAMEBUFFER :: 1
ROOT_BOOT_IMAGE :: 2
ROOT_VALUE_WIDTH :: 0
ROOT_VALUE_HEIGHT :: 1
ROOT_VALUE_PIXELS_PER_LINE :: 2
ROOT_VALUE_FORMAT :: 3
ROOT_VALUE_BOOT_IMAGE_SIZE :: 4
