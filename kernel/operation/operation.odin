// The kernel operations: what a program can ask the kernel (property 1).
//
// A program has one ring to the kernel, at KERNEL_RING_ADDRESS. A kernel
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
KERNEL_RING_ADDRESS :: 0x0000_7FFF_FFFF_0000
USER_END :: 0x0000_8000_0000_0000

Handle :: distinct u32 // 0 names no object.

Operation :: enum u32 {
	None           = 0,
	Log            = 1, // (address, count): write text on the log of the kernel.
	Memory_Create  = 2, // (page_count) -> memory handle. The memory is zero.
	Memory_Map     = 3, // (memory, program or 0 for self, address or 0, Map_Flags, first page, page_count or 0 for all) -> address
	Memory_Unmap   = 4, // (program or 0, address)
	Memory_Size    = 5, // (memory) -> page_count
	Program_Create = 6, // (name address, name count) -> program handle. The program has no memory and no handle.
	Program_Start  = 7, // (program, entry address, stack address, context address)
	Program_Stop   = 8, // (program or 0 for self, code)
	Program_State  = 9, // (program) -> Program_State, code
	Handle_Give    = 10, // (target: program handle or memory handle, handle) -> the handle in the target program.
	// With a memory handle, the target is the other program that maps this memory: the other side of a ring.
	Handle_Close   = 11, // (handle)
	Wake           = 12, // (memory): wake the other programs that map this memory.
	Interrupt_Read = 13, // (interrupt) -> the number of interrupts since the last read.
	Device_Create  = 14, // (machine, Device_Kind, a, b) -> handle. Ports: a = first port, b = count. Interrupt: a = line.
	Inspect        = 15, // (machine, Inspect_Kind, index, address, size) -> bytes written
	Machine_Stop   = 16, // (machine, code)
}

Status :: enum u32 {
	Ok            = 0,
	Bad_Operation = 1,
	Bad_Handle    = 2,
	Bad_Address   = 3,
	No_Memory     = 4,
	No_Slot       = 5,
	Bad_State     = 6,
}

Map_Flag :: enum u64 {
	Write   = 0,
	Execute = 1,
}
Map_Flags :: bit_set[Map_Flag;u64]

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
}

Program_Report :: struct {
	state:        Program_State,
	code:         u32,
	name:         [32]u8,
	mapped_pages: u64,
	handle_count: u64,
	run_time:     u64, // Milliseconds of processor time.
	entries:      u64,
}

// The context: the one record that a program receives when it starts
// (property 19). The address of the record is the parameter of the entry.
CONTEXT_HANDLES :: 16
CONTEXT_VALUES :: 16
CONTEXT_TEXT :: 256

Context :: struct {
	handles:    [CONTEXT_HANDLES]Handle, // The granted handles. The role of each index is fixed by who starts the program.
	values:     [CONTEXT_VALUES]u64,
	text:       [CONTEXT_TEXT]u8, // The arguments.
	text_count: u64,
}

// The roles of the first program (the root service).
ROOT_MACHINE :: 0
ROOT_FRAMEBUFFER :: 1
ROOT_BOOT_IMAGE :: 2
ROOT_VALUE_WIDTH :: 0
ROOT_VALUE_HEIGHT :: 1
ROOT_VALUE_PIXELS_PER_LINE :: 2
ROOT_VALUE_FORMAT :: 3
ROOT_VALUE_BOOT_IMAGE_SIZE :: 4
