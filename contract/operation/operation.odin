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
import "contract:value_kinds"

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
	Read    = 1, // Memory: map it. Program, Thread: read its state. Interrupt: read its count. Budget: read what it holds (Budget_Read).
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
	Machine   = 5, // The machine: its rights are Give, Inspect, Devices, Stop, Physical, Schedule and Events.
	Thread    = 6,
	Budget    = 7,
	Log       = 8, // The log of the kernel.
}

// What a program asks the kernel. A thread asks for an operation with one
// command record in its kernel ring: `kind` is the operation, and the
// values are its arguments, in the order of its form. Then it enters the
// kernel with the `syscall` instruction. The kernel executes the commands
// of the ring in their order, and gives one completion record for each:
// `kind` is a `Status`, and the values are the results, in the order that
// each operation states. A completion with the status `Ok` has the results;
// with another status the operation failed, and the values of its
// completion are an [error record](errors.Error_Record): the
// argument that was wrong, its value, and what the kernel found (the
// [errors of the kernel](docs/MODULE_CONTRACT.md#8-errors-that-diagnose)).
//
// A handle argument names an object of this program by the number that a
// grant or an operation gave. When the handle names no object of the kind
// that the operation needs, the status is `Bad_Handle`; when it names the
// object but has not the right that the operation needs, `No_Right`. The
// rights that each operation needs are in **bold**.
//
// `support/system` calls each operation with a procedure of its own
// (`system.memory_create`) or with `system.call`.
Operation :: enum u32 {
	None           = 0,
	Log            = 1, // (log, address, length, level: Log_Level, channel, channel, runs).
	// Writes one text on the log of the kernel: records of the log, which a reader with the memory of the log
	// reads, and one line `[name:channel] text` on the serial port. The kernel sets the time, the program and
	// the thread of each record, so a program cannot write a record of another program.
	//
	// **Arguments**
	//
	// - `log`: the log handle, with **Write**. Each program has it in its context at `CONTEXT_LOG`.
	// - `address`, `length`: the text, at most 4096 bytes, in memory that the program can read. A text longer
	//   than `LOG_TEXT_CAPACITY` continues in the next records (`Log_Record`, `more`).
	// - `level`: a `Log_Level`, from `Info` (0) to `Error` (3).
	// - `channel`, `channel`: the name of the channel, 16 bytes in two values. The name is the bytes before
	//   the first one that is not a printable character: all zero is no channel.
	// - `runs`: the count of the value runs of the text, at most `LOG_CALL_RUN_LIMIT`; 0 is a plain text. The
	//   runs (`value_kinds.Value_Run_In_Call`) follow the `length` bytes of the text at `address`. A run says
	//   which bytes of the text are one value, and its kind: a reader of the log shows each value in the color
	//   of its kind. The text is written whole in every case: if a run is wrong, the record is plain.
	//
	// **Results**: none.
	//
	// **Statuses**
	//
	// - `Bad_Handle`, `No_Right`: `log` is not a log handle with **Write**.
	// - `Bad_Address`: `length` is above 4096, or the program cannot read the text and its runs.
	// - `Bad_Operation`: `level` is above `Error`, or `runs` is above `LOG_CALL_RUN_LIMIT`.
	// - `No_Budget`: the budget of the program, or a budget above it, accepted all the records of its limit
	//   in this second (`Budget_Amounts`, `log_records`).
	Memory_Create  = 2, // (budget, pages, flags: Memory_Flags) -> memory handle.
	// Makes a memory object of `pages` pages of 4096 bytes, and gives a handle to it with each right of
	// memory: **Give**, **Read**, **Write** and **Execute**. The memory is zero. The budget pays now, so an
	// access to the memory never fails for lack of memory.
	//
	// **Arguments**
	//
	// - `budget`: a budget handle with **Spend**. It pays now for each page and for the frame list of the
	//   object (`memory_cost`). A `Contiguous` object has no frame list; an `Uncommitted` object pays its
	//   frame list only, and at least one page.
	// - `pages`: the count of pages, from 1; at most `MEMORY_PAGE_LIMIT` (1 GiB) for an object that is not
	//   contiguous.
	// - `flags`: a `Memory_Flags`:
	//   - `Frames_Now`: each page gets its page frame now, not at its first use (a page on first use);
	//   - `Contiguous`: the frames follow each other in physical memory and do not move, for a device;
	//   - `Uncommitted`: no page is paid now, and `Memory_Commit` pays them later; with no other flag;
	//   - `Large_Pages`: `Contiguous`, in one run aligned on 2 MiB, with `pages` a multiple of
	//     `LARGE_PAGE_PAGES`, so that a mapping uses large pages.
	//
	// **Results**: the memory handle.
	//
	// **Statuses**
	//
	// - `Bad_Handle`, `No_Right`: `budget` is not a budget handle with **Spend**.
	// - `Bad_Operation`: `pages` is 0, or above the limit; a flag that the kernel does not know;
	//   `Uncommitted` with another flag; `Large_Pages` with a count that is not a multiple of
	//   `LARGE_PAGE_PAGES`.
	// - `No_Budget`: the budget cannot pay.
	// - `No_Slot`: the table of the memory objects of the kernel is full, or the handle table of the program.
	// - `No_Memory`: a contiguous object finds no free run of its length, though the budget can pay.
	//
	// ```odin
	// memory, status := system.memory_create(16, flags = {.Frames_Now})
	// ```
	Memory_Map     = 3, // (memory, program, address, flags: Map_Flags, first, pages) -> address.
	// Maps pages of a memory object in this program or in another program, and gives the address of the
	// first page.
	//
	// **Arguments**
	//
	// - `memory`: a memory handle with **Read**, and **Write** to map with `Write`, **Execute** to map with
	//   `Execute`.
	// - `program`: 0 for this program, or a program handle with **Control**.
	// - `address`: the address of the first page: a multiple of 4096, at least 4096, with the mapping below
	//   `USER_END` and over no other mapping. 0: the kernel chooses the lowest free place from
	//   `CHOSEN_BASE`, with a page with no mapping before and after it, on 2 MiB for an object of
	//   `Large_Pages` that is mapped by whole large pages.
	// - `flags`: a `Map_Flags`: `Write`, `Execute` (never both: no page is writable and executable), or
	//   `No_Access`: the pages fault until `Memory_Protect` gives them access. No flag: read only. The
	//   kernel reads no other bit.
	// - `first`: the first page of the object.
	// - `pages`: the count of pages, or 0 for each page from `first` to the end of the object.
	//
	// **Results**: the address of the first page.
	//
	// **Statuses**
	//
	// - `Bad_Handle`, `No_Right`: `memory` or `program` is not a handle of its kind with its rights.
	// - `Bad_State`: the program is stopped; or a part of the object has a protection of its own
	//   (`Memory_Protect`): such an object has one mapping only.
	// - `Bad_Address`: the pages are not inside the object; the address is not a multiple of 4096, is below
	//   4096, ends above `USER_END`, or meets another mapping.
	// - `Bad_Operation`: `Write` with `Execute`.
	// - `No_Slot`: the program has 128 mappings, or the kernel finds no free place for the address that it
	//   chooses.
	// - `No_Budget`, `No_Memory`: the budget of the program that receives the mapping cannot pay its page
	//   tables, or no page frame is free.
	//
	// ```odin
	// address, status := system.memory_map(memory, flags = {.Write})
	// ```
	Memory_Unmap   = 4, // (program, address).
	// Removes the mapping that starts at an address, in this program or in another program. The memory
	// object ends when no handle and no mapping names it.
	//
	// **Arguments**
	//
	// - `program`: 0 for this program, or a program handle with **Control**.
	// - `address`: the first byte of a mapping, below `THREAD_AREA_BASE`: the thread areas and the time page
	//   stay.
	//
	// **Results**: none.
	//
	// **Statuses**
	//
	// - `Bad_Handle`, `No_Right`: `program` is not a program handle with **Control**.
	// - `Bad_State`: the program is stopped.
	// - `Bad_Address`: no mapping starts at the address, or it is a thread area or the time page.
	Memory_Size    = 5, // (memory) -> pages.
	// Gives the count of pages of a memory object.
	//
	// **Arguments**
	//
	// - `memory`: a memory handle, with any rights.
	//
	// **Results**: the count of pages.
	//
	// **Statuses**
	//
	// - `Bad_Handle`: `memory` is not a memory handle.
	Program_Create = 6, // (budget, name, name_length) -> program handle.
	// Makes a program, in the state `Created`, and gives a handle to it with **Give**, **Read** and
	// **Control**. The program has no memory and no handle: its addresses hold the time page only.
	// `Program_Start` starts it.
	//
	// **Arguments**
	//
	// - `budget`: a budget handle with **Spend**. It pays for one program slot and for the page tables of
	//   the program. The program keeps it: it pays for its first thread at `Program_Start`, and for each
	//   page table of the program after.
	// - `name`, `name_length`: the name of the program, at most 31 bytes, in memory that the program can
	//   read: the reports and the log show it.
	//
	// **Results**: the program handle.
	//
	// **Statuses**
	//
	// - `Bad_Handle`, `No_Right`: `budget` is not a budget handle with **Spend**.
	// - `Bad_Address`: `name_length` is above 31, or the program cannot read the name.
	// - `No_Budget`: the budget has no program slot or no page left, or it cannot pay the page tables.
	// - `No_Slot`: the table of the programs of the kernel is full, or the handle table of the program.
	Program_Start  = 7, // (program, entry, stack, context).
	// Starts a program that `Program_Create` made: its first thread runs at `entry`, and the program goes
	// from `Created` to `Ready`. The budget of the program pays for the thread, as `Thread_Create` does.
	//
	// **Arguments**
	//
	// - `program`: a program handle with **Control**, of a program in the state `Created`.
	// - `entry`: the address of the first instruction, below `USER_END`.
	// - `stack`: the top of the stack, from 8 to `USER_END`; the thread starts with its stack pointer at
	//   `stack` minus 8, as after a call.
	// - `context`: the value of the first register of the thread. By the rule of the system it is the
	//   address of the `Context` of the program (`CONTEXT_ADDRESS`); the kernel does not read it.
	//
	// **Results**: none.
	//
	// **Statuses**
	//
	// - `Bad_Handle`, `No_Right`: `program` is not a program handle with **Control**.
	// - `Bad_State`: the program is not in the state `Created`.
	// - `Bad_Address`: `entry` or `stack` is out of its range.
	// - `No_Budget`: the budget of the program has no thread slot left, or it cannot pay for the thread
	//   area or its page tables.
	// - `No_Slot`: the thread table of the kernel is full, or the program has `THREAD_CAPACITY` threads.
	// - `No_Memory`: no free run of page frames for the thread area.
	Program_Stop   = 8, // (program, code).
	// Stops a program: this one or another one. Each of its threads ends, and the operation returns when no
	// thread of the program runs an instruction any more. The program is `Stopped` with the stop code, which
	// `Program_State` gives. Its handles, its mappings and its memory end when its last thread left its
	// processor. A program that is stopped already stays as it is.
	//
	// **Arguments**
	//
	// - `program`: 0 for this program, or a program handle with **Control**. With 0, the thread that asks
	//   ends with its program: the operation does not return.
	// - `code`: the stop code, any value. The kernel uses the codes `STOP_CODE_FAULT` to
	//   `STOP_CODE_FAULT_UNANSWERED` for the stops that it makes.
	//
	// **Results**: none.
	//
	// **Statuses**
	//
	// - `Bad_Handle`, `No_Right`: `program` is not a program handle with **Control**.
	Program_State  = 9, // (program, report: Stop_Report) -> state: Program_State, code, entries.
	// Gives the state of a program, its stop code and its count of kernel entries. With an address, the
	// kernel also writes there where the program stopped on a fault.
	//
	// **Arguments**
	//
	// - `program`: a program handle with **Read**.
	// - `report`: 0, or the address of a `Stop_Report` that the program can write: the instruction, the
	//   address of a page fault, the module and the stack trace of the fault that stopped the program. All
	//   zero while the program runs, or when it stopped with no fault.
	//
	// **Results**
	//
	// 1. the `Program_State` of the program: `Created`, `Ready` (one of its threads is ready), `Waiting` or
	//    `Stopped`;
	// 2. its stop code: 0 while it runs;
	// 3. its kernel entries since its start.
	//
	// **Statuses**
	//
	// - `Bad_Handle`, `No_Right`: `program` is not a program handle with **Read**.
	// - `Bad_Address`: the program cannot write the `Stop_Report` at `report`.
	Handle_Give    = 10, // (target, handle, rights: Rights) -> the handle in the target.
	// Copies a handle into a program, with a part of its rights: a grant never adds a right. The kernel
	// records where the copy came from (its origin): `Handle_Revoke` of the given handle ends the copy, and
	// when the given handle closes, the copy comes from the origin of the given handle.
	//
	// **Arguments**
	//
	// - `target`: where the copy goes:
	//   - 0: this program, with no right needed;
	//   - a program handle with **Control**: that program;
	//   - a memory handle: the other program that maps this memory, the other side of a ring. If no other
	//     program maps it, the one other program that holds a handle to it. The kernel keeps, with the
	//     copy, the memory object that it came through: `Handle_State` proves it to the receiver.
	// - `handle`: the handle to give, with **Give** when the target is another program.
	// - `rights`: the rights of the copy are the rights of `handle` that are also in `rights`.
	//
	// **Results**: the number of the copy in the target program.
	//
	// **Statuses**
	//
	// - `Bad_Handle`: `handle` or `target` names nothing; `target` is a handle of another kind; or it is a
	//   memory object that no other program maps or holds, or that two other programs hold.
	// - `No_Right`: `handle` has not **Give**, or the program handle `target` has not **Control**.
	// - `Bad_State`: the target program is stopped; or `handle` names a memory object with a protection of
	//   its own on a part (`Memory_Protect`), and the target is another program.
	// - `No_Slot`: the handle table of the target program is full.
	//
	// ```odin
	// copy, status := system.give(program, memory, {.Read})
	// ```
	Handle_Close   = 11, // (handle).
	// Closes a handle of this program. What came from it (its copies and its mappings) comes from its origin
	// now. The object ends when nothing names it:
	//
	// - a memory object, when no handle and no mapping names it;
	// - a budget, when its last handle closes: what it holds returns to the budget that it came from, which
	//   pays for its objects;
	// - a program: it stops with `STOP_CODE_NO_HANDLE` when its last handle closes;
	// - the event table of the machine, when the last machine handle with **Events** of its program closes.
	//
	// **Arguments**
	//
	// - `handle`: any handle of this program.
	//
	// **Results**: none.
	//
	// **Statuses**
	//
	// - `Bad_Handle`: `handle` names nothing.
	Interrupt_Read = 12, // (interrupt) -> count.
	// Gives the count of the interrupts of a line or of a message interrupt since the last read, and sets
	// it to 0. Each interrupt also adds 1 to the `events` word of the threads of the program that holds the
	// handle, and wakes them.
	//
	// **Arguments**
	//
	// - `interrupt`: an interrupt handle with **Read**.
	//
	// **Results**: the count of interrupts.
	//
	// **Statuses**
	//
	// - `Bad_Handle`, `No_Right`: `interrupt` is not an interrupt handle with **Read**.
	Device_Create  = 13, // (machine, kind: Device_Kind, a, b) -> handle, address, value.
	// Makes a handle to a part of the machine, for a device service.
	//
	// **Arguments**
	//
	// - `machine`: the machine handle, with **Devices**.
	// - `kind`, `a`, `b`: a `Device_Kind` and its two values:
	//   - `Ports`: `a` the first port, below 65536, and `b` the count, from 1 to 65536 minus `a`: a ports
	//     handle with **Give**; the threads of the program use the ports with `in` and `out`;
	//   - `Interrupt`: `a` a line of the 8259, from 1 to 15: an interrupt handle with **Give** and **Read**;
	//   - `Memory`: `a` the physical address, a multiple of 4096, and `b` the count of pages of the
	//     registers of a device: a memory handle with **Give**, **Read** and **Write**, mapped with no cache.
	//     The range meets no memory that the firmware gave as free or as loaded;
	//   - `Message`: a message interrupt (MSI-X) of the first processor: an interrupt handle with **Give**
	//     and **Read**.
	//
	// **Results**
	//
	// 1. the handle;
	// 2. for `Message` only: the address that the device writes;
	// 3. for `Message` only: the value that the device writes there.
	//
	// **Statuses**
	//
	// - `Bad_Handle`, `No_Right`: `machine` is not the machine handle with **Devices**.
	// - `Bad_Address`: the ports, the line or the range of memory is out of its range.
	// - `Bad_Operation`: `kind` is `None` or a kind that the kernel does not know.
	// - `No_Slot`: no free memory object, no free message interrupt (`MESSAGE_CAPACITY`), or the handle
	//   table of the program is full.
	Inspect        = 14, // (machine, kind: Inspect_Kind, index, address, size) -> bytes written.
	// Writes a report of the kernel into memory of the program. Each `Inspect_Kind` has its report:
	//
	// - `System`: a `System_Report`; `index` is not read;
	// - `Program`: the `Program_Report` of the program slot `index`;
	// - `Processor`: the `Processor_Report` of the processor `index`;
	// - `Boot`: the `Boot_Report`;
	// - `Mappings`: the `Mapping_Report` of the page table: `index` 0 for the kernel half of the addresses,
	//   another value for the half of the program that asks;
	// - `Modules`: the `Module_Report` of the program slot `index`;
	// - `Program_Mappings`, `Threads`, `Stop`: the reports of a developer tool for the program slot `index`:
	//   `Program_Mapping_Report`, `Thread_Table_Report`, `Stop_Report`;
	// - `Pages`: the `Page_Report` of the program that asks, for the address that it wrote in the record;
	//   `index` must be 0.
	//
	// A slot or a processor with no program, or out of the table, gives a report of zeros.
	//
	// **Arguments**
	//
	// - `machine`: the machine handle, with **Inspect**.
	// - `kind`, `index`: the report, as above.
	// - `address`, `size`: the memory of the report: `size` is at least the size of the report, and the
	//   program can write it.
	//
	// **Results**: the bytes written: the size of the report.
	//
	// **Statuses**
	//
	// - `Bad_Handle`, `No_Right`: `machine` is not the machine handle with **Inspect**.
	// - `Bad_Address`: `size` is below the size of the report, or the program cannot write the memory.
	// - `Bad_Operation`: `kind` is `None` or a kind that the kernel does not know; for `Pages`, `index` is
	//   not 0, or the address in the record is not a multiple of 4096, or its 64 pages pass `USER_END`.
	Machine_Stop   = 15, // (machine, code).
	// Stops the machine: the kernel writes `kernel: the machine stops with code <code>` on the log, then
	// stops each processor. The operation does not return.
	//
	// **Arguments**
	//
	// - `machine`: the machine handle, with **Stop**.
	// - `code`: the code of the stop; the machine gives its low 8 bits to its host.
	//
	// **Statuses**
	//
	// - `Bad_Handle`, `No_Right`: `machine` is not the machine handle with **Stop**.
	Thread_Create  = 16, // (budget, entry, stack, parameter, weight, request) -> thread handle.
	// Starts a new thread of this program, and gives a handle to it with **Give**, **Read**, **Write**,
	// **Control** and **Inspect**. The thread is ready at once: it starts at `entry` with `parameter` in its
	// first register, and its stack pointer at `stack` minus 8.
	//
	// **Arguments**
	//
	// - `budget`: a budget handle with **Spend**. It pays for the thread slot and for the thread area: the
	//   thread record, the kernel ring and a page with no memory. The budget of the program pays for the
	//   page tables of the area.
	// - `entry`: the address of the first instruction, below `USER_END`.
	// - `stack`: the top of the stack, from 8 to `USER_END`.
	// - `parameter`: any value.
	// - `weight`: from 1 to `WEIGHT_FULL`; 0 is `WEIGHT_FULL`. The share of the thread under the strategies
	//   that use weights. A weight can only be lower than the weight of a thread created with 0.
	// - `request`: microseconds, from 1 to `REQUEST_LIMIT`; 0 is `REQUEST_DEFAULT`. The delay that the
	//   thread asks for under EEVDF ([weights and requests](docs/SCHEDULING.md#weights-and-requests-a-field-at-thread-creation)).
	//
	// **Results**: the thread handle.
	//
	// **Statuses**
	//
	// - `Bad_Handle`, `No_Right`: `budget` is not a budget handle with **Spend**.
	// - `Bad_Operation`: `weight` is above `WEIGHT_FULL`, or `request` above `REQUEST_LIMIT`.
	// - `Bad_Address`: `entry` or `stack` is out of its range.
	// - `Bad_State`: the program stops.
	// - `No_Slot`: the thread table of the kernel is full, the program has `THREAD_CAPACITY` threads, or
	//   its handle table is full.
	// - `No_Budget`: the budget has no thread slot left, or it cannot pay for the thread area or its page
	//   tables.
	// - `No_Memory`: no free run of page frames for the thread area.
	//
	// ```odin
	// thread, status := system.thread_start(worker, nil)
	// ```
	Thread_Stop    = 17, // (thread).
	// Ends a thread: the calling thread, or a thread that a handle names, of this program or of another one.
	// A thread on another processor leaves it at once, and the operation returns after it left. The other
	// threads of its program get an event. A program with no thread left stops, with the code 0.
	//
	// **Arguments**
	//
	// - `thread`: 0 for the calling thread, which ends: the operation does not return. Else a thread handle
	//   with **Control**.
	//
	// **Results**: none. A thread that ended already stays as it is.
	//
	// **Statuses**
	//
	// - `Bad_Handle`, `No_Right`: `thread` is not a thread handle with **Control**.
	Thread_State   = 18, // (thread) -> state: Program_State, stop count, area bytes, components, form.
	// Gives the state of a thread, and what a holder of the thread needs for `Thread_Control`.
	//
	// **Arguments**
	//
	// - `thread`: a thread handle with **Read**.
	//
	// **Results**
	//
	// 1. its `Program_State`: `Ready`, `Waiting` or `Stopped`. A thread that a stop holds is `Ready` when
	//    its wait ended, and runs only when its stop count is 0;
	// 2. its stop count (`Thread_Control`);
	// 3. the bytes of the extended state area of a thread on this machine;
	// 4. its components: the bits of XCR0 (0 x87, 1 SSE, 2 AVX, 5 to 7 AVX-512);
	// 5. 1 when the area has the header of `xsave` at byte 512, 0 when it is the 512 bytes of `fxsave`.
	//
	// **Statuses**
	//
	// - `Bad_Handle`, `No_Right`: `thread` is not a thread handle with **Read**.
	Word_Wait      = 19, // (words: Word, count).
	// Adds words to the wait of this kernel entry: the one way to wait for something else than a time. A
	// thread that asks for a wait when it enters the kernel waits at the end of the entry while each word
	// of its list holds its value. The wait ends when `Word_Wake` names one of its words, or at its
	// deadline. The kernel names a word by its page frame, so two programs that map one memory object wait
	// on one word. If a word does not hold its value already, the wait ends at once: no wake is lost
	// between a read of the word and the wait.
	//
	// **Arguments**
	//
	// - `words`: the address of `count` records `Word`: each one is the address of a word of 32 bits, a
	//   multiple of 4 that the program can read, and the value that the word holds while the thread waits
	//   (the low 32 bits of `value`).
	// - `count`: the words of this command. One entry holds at most `WORD_WAIT_CAPACITY` words in all its
	//   commands.
	//
	// **Results**: none.
	//
	// **Statuses**
	//
	// - `No_Slot`: the entry would hold more than `WORD_WAIT_CAPACITY` words.
	// - `Bad_Address`: the program cannot read the table or a word, or a word is not a multiple of 4. The
	//   entry then does not wait.
	//
	// ```odin
	// system.word_wait(&ready, 0, deadline)
	// ```
	Word_Wake      = 20, // (word, count) -> threads woken.
	// Ends the wait of at most `count` threads that wait on a word. A thread that put the word in the wait
	// of its entry and does not wait yet counts too: it does not wait, and reads its words again.
	//
	// **Arguments**
	//
	// - `word`: the address of a word of 32 bits, a multiple of 4 that the program can read.
	// - `count`: the most threads to wake.
	//
	// **Results**: the count of threads woken.
	//
	// **Statuses**
	//
	// - `Bad_Address`: the program cannot read the word, or its address is not a multiple of 4.
	//
	// ```odin
	// system.word_wake(&ready)
	// ```
	Budget_Create  = 21, // (budget, pages, programs, threads, processor, log_records) -> budget handle.
	// Makes a budget from a budget, and gives a handle to it with **Give**, **Read**, **Spend** and
	// **Commit** (`Budget_Amounts` says what each amount is). The pages, the program slots and the thread
	// slots move from `budget` to the new budget. The processor time and the log records are limits for
	// each second, for the new budget and each budget that comes from it. When the last handle to the new
	// budget closes, what it holds returns to `budget`, which pays for its objects.
	//
	// **Arguments**
	//
	// - `budget`: a budget handle with **Spend**.
	// - `pages`, `programs`, `threads`: what moves to the new budget.
	// - `processor`: microseconds of processor time in each second, on all the processors together: at most
	//   the limit of `budget`.
	// - `log_records`: records of the log in each second: at most the limit of `budget`.
	//
	// **Results**: the budget handle.
	//
	// **Statuses**
	//
	// - `Bad_Handle`, `No_Right`: `budget` is not a budget handle with **Spend**.
	// - `No_Budget`: `budget` holds less than an amount that moves, or a limit is above its own.
	// - `No_Slot`: the table of the budgets of the kernel is full, or the handle table of the program.
	Budget_Read    = 22, // (budget) -> pages, programs, threads, processor, log_records, processor time, refused.
	// Gives what a budget can still pay, its limits, and what it used.
	//
	// **Arguments**
	//
	// - `budget`: a budget handle with **Read**.
	//
	// **Results**
	//
	// 1. the pages that it can still pay;
	// 2. the program slots that it can still pay;
	// 3. the thread slots that it can still pay;
	// 4. its limit of processor time: microseconds in each second;
	// 5. its limit of log records in each second;
	// 6. the microseconds of processor time that its threads used since it was made;
	// 7. the log records that the kernel refused to it.
	//
	// **Statuses**
	//
	// - `Bad_Handle`, `No_Right`: `budget` is not a budget handle with **Read**.
	Handle_State   = 23, // (handle, memory) -> kind: Object_Kind, rights: Rights, through, holdings.
	// Gives the kind and the rights of a handle of this program, and proves where it came from. A program
	// that receives the number of a handle from another program, in a ring, proves with this operation that
	// the other program gave the handle through that ring (`Handle_Give` with the memory of the ring as its
	// target). Without the proof, the other program can name a handle that the receiver holds for itself.
	//
	// **Arguments**
	//
	// - `handle`: any handle of this program.
	// - `memory`: 0, or a memory handle with any rights: the memory of the ring.
	//
	// **Results**
	//
	// 1. the `Object_Kind` of the object;
	// 2. the `Rights` of the handle;
	// 3. 1 when the handle came through the memory object of `memory`, else 0;
	// 4. the count of the holdings that came from this handle, in all programs: what `Handle_Revoke` ends.
	//
	// **Statuses**
	//
	// - `Bad_Handle`: `handle` names nothing, or `memory` is not a memory handle.
	Handle_Revoke  = 24, // (handle, program) -> holdings ended.
	// Ends each holding that came from a handle. A holding is a handle or a mapping. The origin of a handle
	// that `Handle_Give` made is the handle that was given; the origin of a mapping is the memory handle
	// that was mapped. When a handle closes, what came from it comes from its origin. The operation ends
	// each holding that came from the handle, and what came from those holdings, in any program. The handle
	// stays, and the mappings of the program that revokes stay. A program that lost a holding gets an event.
	// A thread that uses memory that its program lost stops its program on a page fault.
	//
	// **Arguments**
	//
	// - `handle`: any handle of this program, with any rights: the program that holds it is the origin of
	//   what came from it.
	// - `program`: 0 for each program, or a program handle with **Control**: only the holdings in that
	//   program.
	//
	// **Results**: the count of the holdings that ended.
	//
	// **Statuses**
	//
	// - `Bad_Handle`: `handle` names nothing, or `program` is not a program handle.
	// - `No_Right`: the program handle has not **Control**.
	Memory_Physical = 25, // (machine, memory) -> physical address.
	// Gives the physical address of the first page of a memory object whose pages follow each other in
	// physical memory and do not move: an object created `Contiguous` or `Large_Pages`, or the registers of
	// a device. A device service gives these addresses to its device, which reads and writes the memory
	// with no processor (direct memory access).
	//
	// **Arguments**
	//
	// - `machine`: the machine handle, with **Physical**.
	// - `memory`: a memory handle with **Read**.
	//
	// **Results**: the physical address.
	//
	// **Statuses**
	//
	// - `Bad_Handle`, `No_Right`: `machine` or `memory` is not a handle of its kind with its right.
	// - `Bad_Operation`: the pages of the object are not contiguous: they get their frames at their first
	//   use, from anywhere.
	Program_Module = 26, // (program, record: Module_Record).
	// Records a module that a loader put in a program, in the module records of the program. The kernel
	// does not read the module: the record is what the loader asserts. The kernel names the module of the
	// address of a fault with it, and `Inspect` gives the records (`Module_Report`).
	//
	// **Arguments**
	//
	// - `program`: 0 for this program, or a program handle with **Control**.
	// - `record`: the address of a `Module_Record` that the program can read. A record with the base of a
	//   record that exists replaces it; a record with the size 0 removes the record of its base. A program
	//   has at most `PROGRAM_MODULE_CAPACITY` records, and no two of them share an address.
	//
	// **Results**: none.
	//
	// **Statuses**
	//
	// - `Bad_Handle`, `No_Right`: `program` is not a program handle with **Control**.
	// - `Bad_State`: the program is stopped.
	// - `Bad_Address`: the program cannot read the record; the module passes `USER_END`; it meets another
	//   record; or a record of size 0 names a base that no record has.
	// - `No_Slot`: the program has `PROGRAM_MODULE_CAPACITY` records.
	Strategy_Set = 27, // (machine, strategy: Strategy) -> the strategy before.
	// Changes the scheduling strategy of the machine while it runs: no thread stops, and none is lost. The
	// state of the strategy of each thread starts from zero
	// ([the change of strategy](docs/SCHEDULING.md#the-change-of-strategy-is-a-kernel-operation-with-a-right)).
	//
	// **Arguments**
	//
	// - `machine`: the machine handle, with **Schedule**.
	// - `strategy`: `Round_Robin`, `Fair` or `Eevdf`.
	//
	// **Results**: the `Strategy` before.
	//
	// **Statuses**
	//
	// - `Bad_Handle`, `No_Right`: `machine` is not the machine handle with **Schedule**.
	// - `Bad_Operation`: `strategy` is `None` or a strategy that the kernel does not know.
	//
	// ```odin
	// before, status := system.strategy_set(machine, .Eevdf)
	// ```
	Memory_Commit = 28, // (memory, budget, ranges: Page_Range, count, flags: Commit_Flags) -> pages changed.
	// Commits the pages of ranges of an object made with `Uncommitted`: the budget pays one page for each
	// page that was not committed, and each gets a frame at its first use. With `Decommit`, the committed
	// pages of the ranges are no longer paid: their frames and their pages return at once to the budget of
	// the object, and a page committed again is zero
	// ([the virtual memory of a program](docs/ARCHITECTURE.md#the-virtual-memory-of-a-program)).
	//
	// **Arguments**
	//
	// - `memory`: a memory handle with **Write**, of an object made with `Uncommitted`.
	// - `budget`: a handle to the budget of the object, with **Commit** or **Spend**. **Write** on the object
	//   does not spend the budget of its maker: to let another program commit, give it the object and a
	//   budget handle with **Commit** only ([who pays a commit](docs/ARCHITECTURE.md#who-pays-a-commit)).
	//   Not read with `Decommit`.
	// - `ranges`, `count`: a table of `count` records `Page_Range`, from 1 to `RANGE_TABLE_CAPACITY`, in
	//   increasing order, with no overlap, inside the object, with at most `RANGE_TABLE_PAGE_LIMIT` pages in
	//   all.
	// - `flags`: a `Commit_Flags`: `Decommit`, or none.
	//
	// **Results**: the count of pages that changed.
	//
	// **Statuses**
	//
	// - `Bad_Handle`, `No_Right`: `memory` is not a memory handle with **Write**; `budget` is not a budget
	//   handle with **Commit** or **Spend**.
	// - `Bad_Handle`: `budget` names another budget than the budget of the object.
	// - `Bad_Operation`: `count` is 0 or above `RANGE_TABLE_CAPACITY`; a flag that the kernel does not know;
	//   the table has more than `RANGE_TABLE_PAGE_LIMIT` pages; the object was not made `Uncommitted`.
	// - `Bad_Address`: the program cannot read the table, or the ranges are not in order, overlap, or pass
	//   the end of the object.
	// - `No_Budget`: the budget cannot pay the table: nothing changes.
	// - `Bad_State`: a `Decommit` of an object that another program names, or that has more than one
	//   mapping.
	//
	// ```odin
	// changed, status := system.memory_commit(memory, ranges[:])
	// ```
	Memory_Protect = 29, // (ranges: Address_Range, count, flags: Map_Flags) -> pages changed.
	// Changes the protection of pages of mappings of this program: read only (no flag), `Write`, `Execute`,
	// or `No_Access`. Each processor that runs a thread of the program forgets the old translations before
	// the operation returns (one shoot-down). A table is done whole or not at all
	// ([protection and the shoot-down](docs/ARCHITECTURE.md#protection-and-the-shoot-down)).
	//
	// **Arguments**
	//
	// - `ranges`, `count`: a table of `count` records `Address_Range`, from 1 to `RANGE_TABLE_CAPACITY`.
	//   Each range is inside one mapping of this program, below `THREAD_AREA_BASE`.
	// - `flags`: a `Map_Flags`. A protection can only take away what the mapping was made with: `Write`
	//   needs a mapping made with `Write`, `Execute` one made with `Execute`. `No_Access` takes no other
	//   flag, and `Write` with `Execute` is refused.
	//
	// A range that is a part of a mapping, not its whole, takes away from the protection of the mapping now:
	// it cannot get more. It needs an object with a frame list that only this program names, with one
	// mapping; while a part has its own protection, the object is not mapped again and not given
	// (`Bad_State`). At most `RANGE_TABLE_PAGE_LIMIT` pages change in one call.
	//
	// **Results**: the count of pages that changed.
	//
	// **Statuses**
	//
	// - `Bad_Operation`: `count` is 0 or above `RANGE_TABLE_CAPACITY`; a flag that the kernel does not know;
	//   `Write` with `Execute`, or `No_Access` with another flag; more than the mapping was made with; one
	//   table names a mapping whole and in part; more than `RANGE_TABLE_PAGE_LIMIT` pages.
	// - `Bad_Address`: the program cannot read the table; a range is not on whole pages, is empty, or is not
	//   inside one mapping; the mapping is a thread area or the time page; a part of a mapping of a
	//   contiguous object.
	// - `Bad_State`: a part of a mapping of an object that another program names, or that has another
	//   mapping.
	//
	// ```odin
	// changed, status := system.memory_protect(ranges[:], {})
	// ```
	Fault_Handler_Set = 30, // (thread, end, kinds: Fault_Kinds).
	// Makes a thread of this program the fault handler of the program: the faults of the chosen kinds of
	// the other threads of the program become records of the
	// [fault ring](docs/ARCHITECTURE.md#the-fault-ring) in the thread record of the handler, in place of a
	// stop. The thread of a fault waits for `Fault_Answer`. A page fault is delivered only below
	// `THREAD_AREA_BASE`. A fault of a kind that the handler did not ask for stops the program as with no
	// handler. A new handler replaces the one before, and its ring starts empty.
	//
	// **Arguments**
	//
	// - `thread`: 0 for the calling thread, or a thread handle with **Control** of a live thread of this
	//   program.
	// - `end`: 1 to end the delivery: each fault stops the program again. 0 to set the handler.
	// - `kinds`: the `Fault_Kinds` to deliver, or 0 for page faults only, so that a handler of pages never
	//   gets a kind that it does not know. Only the kinds of `FAULT_KINDS_DELIVERED`.
	//
	// When a thread of the program waits for an answer, a new handler or the end of the delivery ends the
	// ring that holds its record: the program stops with `STOP_CODE_FAULT_UNANSWERED`, as when the handler
	// thread ends, and the operation gives `Ok`.
	//
	// **Results**: none.
	//
	// **Statuses**
	//
	// - `Bad_Operation`: `end` is above 1; a kind that the kernel never delivers; kinds with the end of the
	//   delivery.
	// - `Bad_Handle`, `No_Right`: `thread` is not a thread handle with **Control**.
	// - `Bad_State`: the thread is not a live thread of this program.
	//
	// ```odin
	// status := system.fault_handler_set(kinds = {.Page_Fault, .Breakpoint})
	// ```
	Fault_Answer = 31, // (thread, serial, answer: Fault_Answer_Kind).
	// Answers a thread of this program that waits in the fault ring, by the two values of its
	// `Fault_Record`.
	//
	// **Arguments**
	//
	// - `thread`, `serial`: the `thread` and the `serial` of the record.
	// - `answer`: a `Fault_Answer_Kind`:
	//   - `Resume`: the thread continues with its registers, at the instruction of its record (the faulting
	//     instruction again, or the next one after a trap), or where `Thread_Control` wrote;
	//   - `Stop`: the program stops as with no handler: the stop code and the stop report of the fault.
	//
	// **Results**: none.
	//
	// **Statuses**
	//
	// - `Bad_Operation`: `answer` is not `Resume` or `Stop`.
	// - `Bad_State`: no thread with that number waits for the fault of that serial: a wrong answer, a second
	//   answer, or an answer from another program. Also for `Resume` after a fault kind that does not resume
	//   by itself (`fault_kind_resumes`) when `Thread_Control` wrote neither the registers nor the extended
	//   state of the thread since its fault: the thread still waits, and `Stop` ends it.
	//
	// ```odin
	// status := system.fault_answer(record, .Resume)
	// ```
	Events_Set = 32, // (machine, memory, rules: Event_Rule, count, records) -> ring bytes, processors.
	// Gives the event table of the machine: the kernel writes an `Event_Record` into the event ring of the
	// processor of each [kernel event](docs/ARCHITECTURE.md#kernel-events) that a rule accepts. A new table
	// replaces the table of the caller. The table also ends when its program ends, and when the last
	// machine handle of its program with **Events** closes or is revoked: the table lives while the right
	// that made it lives.
	//
	// **Arguments**
	//
	// - `machine`: the machine handle, with **Events**.
	// - `memory`: a memory handle with **Write** of an object made `Contiguous` (not the registers of a
	//   device), with room for one ring of `EVENT_RING_HEAD_BYTES` plus `records` times 64 bytes for each
	//   processor, one after the other from its first byte. 0: the caller takes its table away; when the
	//   operation returns, no processor writes in the old memory object.
	// - `rules`, `count`: a table of `count` records `Event_Rule`, from 1 to `EVENT_RULE_CAPACITY`.
	// - `records`: the records of each ring: a power of two from `EVENT_RING_RECORDS_LEAST` to
	//   `EVENT_RING_RECORDS_MOST`.
	//
	// **Results**
	//
	// 1. the bytes of one event ring;
	// 2. the count of processors: the count of rings.
	//
	// **Statuses**
	//
	// - `Bad_Handle`, `No_Right`: `machine` is not the machine handle with **Events**, or `memory` not a
	//   memory handle with **Write**; the program of a rule is not a program handle with **Read**.
	// - `Bad_State`: `memory` is 0 and the caller has no table; or another program has the table: one table
	//   at a time.
	// - `No_Slot`: `count` is above `EVENT_RULE_CAPACITY`.
	// - `Bad_Operation`: `count` is 0; `records` is not a power of two in its range; the object is not
	//   contiguous, is the registers of a device, or is too small for the rings; a rule that the kernel
	//   refuses (its kind, its flags, its reserved values, its least duration or its one in N).
	// - `Bad_Address`: the program cannot read the table of rules.
	Thread_Control = 33, // (thread, number, command: Thread_Control_Command, address, size) -> see the command.
	// Controls a thread: holds it and releases it, reads its registers and its extended state, and writes
	// them ([the control of a thread](docs/ARCHITECTURE.md#the-control-of-a-thread)). `Stop` and `Resume`
	// change the stop count of the thread: it runs only while the count is 0. The registers and the
	// extended state are read and written only while the thread is held: its stop count is above 0, or it
	// waits for an answer of the fault ring.
	//
	// **Arguments**
	//
	// - `thread`: a thread handle with **Inspect** for each command, and **Write** too for a write
	//   (`thread_control_rights`); or 0, and then `number` names a live thread of this program
	//   (`Thread_Record.number`, `Fault_Record.thread`). A thread of another program needs a handle.
	// - `number`: the number of the thread when `thread` is 0.
	// - `command`: a `Thread_Control_Command`.
	// - `address`, `size`: the memory of the command that reads or writes: `size` is at least the size of
	//   a `Thread_Registers`, or of the extended state area (`Thread_State`), and the program can read it,
	//   or write it for a read of the thread.
	//
	// **Results**: what the command gives: the stop count, or the bytes written and the components.
	//
	// **Statuses**
	//
	// - `Bad_Operation`: `command` is `None` or a command that the kernel does not know; a write of values
	//   that a thread of a program cannot hold changes nothing (`thread_registers_refusal`,
	//   `extended_state_refusal`).
	// - `Bad_Handle`, `No_Right`: `thread` is not a thread handle with the rights of the command.
	// - `Bad_State`: no live thread of this program has `number`; the thread or its program ended; a read or
	//   a write of a thread that is not held, or of the calling thread; a `Stop` above
	//   `THREAD_STOP_COUNT_LIMIT` or of a thread that ends; a `Resume` at the count 0.
	// - `Bad_Address`: `size` is too small, or the program cannot read or write the memory.
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
// command of Thread_Control: Inspect for each command, and Write too for a
// write. A write lets its holder choose the code that the program of the
// thread runs, so it has its own right; a hold and a read do not, so a
// profiler gets them with no write. A writer also reads the frame before it
// writes it. Control, the right to end a thread, gives none of them.
thread_control_rights :: proc "contextless" (command: Thread_Control_Command) -> Rights {
	#partial switch command {
	case .Write_Registers, .Write_Extended_State:
		return {.Inspect, .Write}
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

LOG_TEXT_CAPACITY :: 152
LOG_CHANNEL_CAPACITY :: 16
// The value runs that one record keeps: the kind of each typed part of its
// text (contract:value_kinds). A text with more typed parts keeps its first
// runs; the rest of its text is plain.
LOG_RUN_CAPACITY :: 8
// The value runs that one Log operation takes, after its text.
LOG_CALL_RUN_LIMIT :: 32
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
	run_count:  u8, // The value runs of the text: runs[:run_count].
	reserved:   [3]u8,
	name:       [32]u8, // The name of the program, or "kernel".
	channel:    [LOG_CHANNEL_CAPACITY]u8, // All zero: the program gave no channel.
	runs:       [LOG_RUN_CAPACITY]value_kinds.Value_Run, // In order, inside text[:text_count].
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
//
// The record has 16 handles and 24 values of 64 bits. Its starter writes
// it, and the kernel maps it read-write at `CONTEXT_ADDRESS` before the
// first thread runs. A program finds each thing at a **fixed place**: the
// index of a handle or of a value is its role. So a program needs no name,
// no path and no parser to find what it was given:
// `ctx.handles[CONTEXT_LOG]` is its log, and a handle that its starter did
// not give is 0. A program that starts with a context of zeros has no
// handle: it can compute and stop, and reach nothing.
//
// Three groups of places exist:
//
// - **The places that the system fixes for every program**: the log, the
//   budget, the seed, the fixed ranges that the starter mapped. Every
//   starter writes them in the same way.
// - **The places of the first program**, the root service: the kernel
//   writes them at boot, with every handle that exists then (the machine,
//   the framebuffer, the boot image, the records of the log).
// - **The places that a starter and its program agree on**: the handles
//   0 to 13 and the values 0 to 8. The root service gives each program the
//   handles of its grants there (`support/system`, `GRANT_...`); a call
//   host receives its call ring at 0 and its call region at 1.
//
// A handle of the context has the rights that the starter chose, never
// more than the starter holds. Who starts a program decides what it can
// reach: the context is the whole of its authority at its start. The
// design: (docs/MODULE_CONTRACT.md, "The context").
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
//
// The handle 14: the log of the kernel, with the right **Write**. A program
// writes its lines with the kernel operation `Log` on it (`system.log`
// does). The starter gives it, and the root service gives it to each
// program that has the grant log; a call host gets it from the console.
// With no log handle, a line of the program goes nowhere.
CONTEXT_LOG :: 14 // The log of the kernel.
// The values 9 to 12: the random seed of the program, 32 bytes, that its
// starter writes (docs/RANDOMNESS.md). A start with a seed of zeros is
// refused. The root service has none: it gathers its own. A program does
// not use the values 9 to 12 for another role.
//
// The generator of the program (`support/random`) reads the seed, then
// writes zeros over the four values: a copy of the context made later
// holds no seed. A starter makes the seed of each child from its own
// generator (`random.values_with_seed`).
CONTEXT_VALUE_SEED :: 9
CONTEXT_VALUE_SEED_COUNT :: 4
// The value 16: the strength of the seed of the system, from which the seed
// of the program comes (support/random, Seed_Strength): 1 weak (the cycle
// counter only), 2 processor (rdrand), 3 entropy (rdseed). The starter
// writes it with the seed.
//
// The seed itself cannot say how it was made: the generator of the program
// keeps this value. The handshake of `support/quic` refuses a seed weaker
// than its least strength, and the program `randomness` shows it.
CONTEXT_VALUE_SEED_STRENGTH :: 16
// The value 17: the program `settings` runs its boot pass (1): it reads the
// settings kept in its store, writes the settings page, and stops, with no
// window (contract:settings).
//
// The root service writes 1 when it starts `settings` at boot; each other
// start of `settings` has 0 and opens its window. No other program reads
// this value.
CONTEXT_VALUE_SETTINGS_BOOT_PASS :: 17
// The values 18 and 19: the address and the size of the second pointer
// theme file that the root service gives the compositor (the theme of the
// system, beside the theme of the owner at the values 6 and 7 of the
// compositor). The setting "pointer_theme" chooses between the two.
//
// The value 18 is the address where the root service mapped the file,
// read-only, in the compositor; 0 when it mapped none.
CONTEXT_VALUE_SECOND_POINTER_THEME_ADDRESS :: 18
// The value 19: the size in bytes of the second pointer theme file at the
// address of the value 18. The compositor reads no byte past it.
CONTEXT_VALUE_SECOND_POINTER_THEME_SIZE :: 19
// The value 20: a set of bits, bit n for the member n of the fixed ranges
// (contract:fixed_addresses, Fixed_Range): the ranges that the starter
// mapped for this program. A set bit is the statement of the starter that
// the range is mapped; a program reads nothing at a fixed range whose bit
// is clear. It is a value of the context, which only the starter writes,
// and not a field of a shared page, which another program can write.
CONTEXT_VALUE_FIXED_RANGES_MAPPED :: 20
// The value 21: the size in bytes of the debug image, which the starter
// mapped at the fixed range Debug_Image (contract:fixed_addresses) when its
// bit of the value 20 is set. The values 22 and 23 have no role.
//
// A program that prints a stop report (the console) reads the names of the
// procedures there; with no debug image, a report names offsets only.
CONTEXT_VALUE_DEBUG_IMAGE_SIZE :: 21
// The handle 15: the budget that pays for the program, with the rights
// **Give**, **Read** and **Spend**. Each page and each object that the
// program makes is paid from it; `Memory_Create` and `Program_Create` name
// it. The loader of the starter gives it, and a starter cannot put another
// handle at this place: the program receives its new budget here. The root
// service receives the root budget with **Commit** too. When the program
// stops, what the budget still holds returns to the budget of its starter.
CONTEXT_BUDGET :: 15 // The budget of the program.
// The values 13 and 15 have no role: the settings page and the date page
// are fixed ranges, mapped when their bit of the value 20 is set. A new
// role of the system takes a number from 16, never 13 or 15, so that an
// old reader cannot take a new value for a page.

// The roles of the first program (the root service).
//
// The handle 0: the machine, with every right of the machine. The kernel
// gives it at boot to the root service only. The root service gives a
// part of its rights to a program that has a grant for it (Inspect, Stop,
// Schedule, Physical): a machine handle reaches each program, so no other
// program receives it whole.
ROOT_MACHINE :: 0
// The handle 1: the memory of the framebuffer that the firmware set up,
// with **Give**, **Read** and **Write**; 0 when the firmware gave no
// framebuffer. The root service draws the boot display there, then gives
// it to the compositor, which owns the screen.
ROOT_FRAMEBUFFER :: 1
// The handle 2: the memory of the boot image, with **Give** and **Read**:
// every module and resource that the boot program checked. The root
// service starts each program from it, and gives it read-only to a
// program that has the grant image.
ROOT_BOOT_IMAGE :: 2
// The handle 3: the memory of the records of the log of the kernel, with
// **Give** and **Read**. The root service gives it, read-only, to a program
// that has the grant log_records, as the program that shows the log.
ROOT_LOG_RECORDS :: 3 // Memory, with Read: the records of the log.
// The handle 4: the memory of the debug image that the boot program read,
// with **Give** and **Read**: the names of the procedures for the stop
// reports. The kernel reads none of its pages.
ROOT_DEBUG_IMAGE :: 4 // Memory, with Read: the debug image that the boot program read. 0: none.
// The value 0: the width of the framebuffer in pixels; 0 with no
// framebuffer. The values 0 to 3 describe the handle 1.
ROOT_VALUE_WIDTH :: 0
// The value 1: the height of the framebuffer in pixels.
ROOT_VALUE_HEIGHT :: 1
// The value 2: the pixels from the start of one line of the framebuffer to
// the start of the next, which can be more than the width.
ROOT_VALUE_PIXELS_PER_LINE :: 2
// The value 3: the order of the bytes of a pixel, a `Pixel_Format` of the
// boot information (red first or blue first).
ROOT_VALUE_FORMAT :: 3
// The value 4: the size in bytes of the boot image of the handle 2.
ROOT_VALUE_BOOT_IMAGE_SIZE :: 4
// The value 5: the size in bytes of the debug image of the handle 4.
ROOT_VALUE_DEBUG_IMAGE_SIZE :: 5 // 0: no debug image.
