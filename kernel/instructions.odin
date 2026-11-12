package kernel

// The instructions of the processor that the kernel executes on its own
// paths, as instruction templates (`asm` procedures of Odin): the compiler
// puts the instructions in place at each call, in the registers that the
// template names, with no call and no return. kernel/processor.asm keeps
// the code that owns the stack or the frame: the entries, the return to a
// program, the stubs, the save and the restore of the extended state, and
// the two procedures with hlt (docs/ARCHITECTURE.md, "The instructions of
// the kernel").
//
// Each template here is #volatile: the compiler never removes it, never
// merges two of them, and keeps their order. Each one also has #clobber
// memory: the compiler keeps each load and store of the kernel on its side
// of the instruction, as it did around a call to an assembler procedure.
// A change of the page table, of a model-specific register or of a port
// has effects on memory that the compiler cannot see.
//
// A template whose instruction changes a flag also has #clobber %flags
// (the compiler then gives LLVM the flags, the direction flag and the x87
// status, as Clang does for each asm): a move to or from a control register
// leaves the arithmetic flags undefined, cld writes the direction flag, and
// stac and clac write AC. The compiler adds that clobber by itself only for
// an instruction that its table lists as writing an arithmetic flag, and
// its table lists none of these, so without it the compiler could keep the
// result of a comparison in the flags across the instruction.
//
// No template here names an x87, MMX, SSE or AVX register: the registers of
// a program stay live through each kernel entry (docs/ARCHITECTURE.md, "The
// extended state of the processor", section 3a).

// out and in have no operand in a template: the processor takes the port
// from dx and the byte from al, and the widths of the pinned parameters
// choose the form of 8 bits. The table of the compiler lists no read and no
// write of a register for these two: its check of unused parameters would
// refuse an input that is only pinned, and its check of outputs would
// refuse an output that no instruction writes. So each register is an
// input tied to an output: the caller drops the outputs that the
// instruction does not change, and gives 0 as the first value of al for
// in.
port_write_8_in_registers :: asm(port: u16, value: u8) -> (port_after: u16, value_after: u8) [
	port -> port_after   = %dx,
	value -> value_after = %al,
	#volatile,
	#clobber memory,
] {
	out
}

// port_write_8 writes one byte to an input-output port.
port_write_8 :: #force_inline proc "contextless" (port: u16, value: u8) {
	_, _ = port_write_8_in_registers(port, value)
}

port_read_8_in_registers :: asm(port: u16, before: u8) -> (port_after: u16, value: u8) [
	port -> port_after = %dx,
	before -> value    = %al,
	#volatile,
	#clobber memory,
] {
	in
}

// port_read_8 reads one byte from an input-output port.
port_read_8 :: #force_inline proc "contextless" (port: u16) -> u8 {
	_, value := port_read_8_in_registers(port, 0)
	return value
}

// model_specific_register_read_halves is rdmsr: the number of the register
// in ecx, the value in edx (the high 32 bits) and eax (the low 32 bits).
model_specific_register_read_halves :: asm(index: u32) -> (low, high: u32) [
	index = %ecx,
	low   = %eax,
	high  = %edx,
	#volatile,
	#clobber memory,
] {
	rdmsr
}

model_specific_register_read :: #force_inline proc "contextless" (index: u32) -> u64 {
	low, high := model_specific_register_read_halves(index)
	return u64(low) | u64(high) << 32
}

// model_specific_register_write_halves is wrmsr: the number of the register
// in ecx, the value in edx (the high 32 bits) and eax (the low 32 bits).
model_specific_register_write_halves :: asm(index: u32, low: u32, high: u32) [
	index = %ecx,
	low   = %eax,
	high  = %edx,
	#volatile,
	#clobber memory,
] {
	wrmsr
}

model_specific_register_write :: #force_inline proc "contextless" (index: u32, value: u64) {
	model_specific_register_write_halves(index, u32(value), u32(value >> 32))
}

// extended_control_register_write_halves is xsetbv: XCR0 when index is 0.
// CR4.OSXSAVE must be set before.
extended_control_register_write_halves :: asm(index: u32, low: u32, high: u32) [
	index = %ecx,
	low   = %eax,
	high  = %edx,
	#volatile,
	#clobber memory,
] {
	xsetbv
}

extended_control_register_write :: #force_inline proc "contextless" (index: u32, value: u64) {
	extended_control_register_write_halves(index, u32(value), u32(value >> 32))
}

// The control registers. cr0 and cr4 hold the modes of the processor, cr2
// the address of the last page fault, and cr3 the page table.
control_register_0_read :: asm() -> (value: u64) [#volatile, #clobber memory, #clobber %flags] {
	mov value, %cr0
}

control_register_0_write :: asm(value: u64) [#volatile, #clobber memory, #clobber %flags] {
	mov %cr0, value
}

// The debug registers 6 (the status of the last debug exception) and 7
// (which breakpoints are on). Only the start of a processor writes them.
debug_register_6_write :: asm(value: u64) [#volatile, #clobber memory, #clobber %flags] {
	mov %dr6, value
}

debug_register_7_write :: asm(value: u64) [#volatile, #clobber memory, #clobber %flags] {
	mov %dr7, value
}

control_register_2_read :: asm() -> (value: u64) [#volatile, #clobber memory, #clobber %flags] {
	mov value, %cr2
}

control_register_3_read :: asm() -> (value: u64) [#volatile, #clobber memory, #clobber %flags] {
	mov value, %cr3
}

control_register_3_write :: asm(value: u64) [#volatile, #clobber memory, #clobber %flags] {
	mov %cr3, value
}

control_register_4_read :: asm() -> (value: u64) [#volatile, #clobber memory, #clobber %flags] {
	mov value, %cr4
}

control_register_4_write :: asm(value: u64) [#volatile, #clobber memory, #clobber %flags] {
	mov %cr4, value
}

// page_flush makes the processor forget its translation of the page that
// holds this address (invlpg).
page_flush :: asm(address: u64) [#volatile, #clobber memory] {
	invlpg [address]
}

// interrupt_table_load loads the interrupt table from its descriptor
// (lidt): the limit (2 bytes) and the address (8 bytes).
interrupt_table_load :: asm(descriptor: rawptr) [#volatile, #clobber memory] {
	lidt [descriptor]
}

// task_register_load loads the task register (ltr) with the selector of
// the task state in the segment table.
task_register_load :: asm(selector: u16) [#volatile, #clobber memory] {
	ltr selector
}

// processor_self gives the record of the processor that runs it. In the
// kernel, the gs base is the address of that record, and the field self is
// at offset 16 of the record (Processor, in kernel/processor.odin).
processor_self :: asm() -> (cpu: ^Processor) [#volatile, #clobber memory] {
	mov cpu, [%gs: 16]
}

// The copy of user_copy: rep movsb copies count bytes from rsi to rdi,
// upward (the direction flag is clear in the kernel). The three registers
// change, so each input is tied to an output in the same register; the
// caller drops the outputs.
copy_bytes_upward :: asm(destination: u64, source: u64, count: u64) -> (destination_end: u64, source_end: u64, count_left: u64) [
	destination -> destination_end = %rdi,
	source -> source_end           = %rsi,
	count -> count_left            = %rcx,
	#volatile,
	#clobber memory,
	#clobber %flags,
] {
	// The compiler asks that the direction be set in the template itself.
	cld
	rep
	movsb
}

// The same copy, with the use of the memory of programs allowed during it
// (stac sets the flag AC, clac clears it). With the guard on (SMAP), the
// processor refuses the memory of programs to the kernel everywhere else.
// An interrupt in the copy clears AC in interrupt_common, and its iretq
// gives back the flags of the copy.
copy_bytes_upward_with_program_access :: asm(destination: u64, source: u64, count: u64) -> (destination_end: u64, source_end: u64, count_left: u64) [
	destination -> destination_end = %rdi,
	source -> source_end           = %rsi,
	count -> count_left            = %rcx,
	#volatile,
	#clobber memory,
	#clobber %flags,
] {
	stac
	cld
	rep
	movsb
	clac
}

// user_copy is the one place where the kernel uses the memory of a program
// at the addresses of the program. The caller checks the range first
// (user_range). stac and clac exist only on a processor with SMAP: without
// the guard, the copy has neither.
user_copy :: #force_inline proc "contextless" (destination: rawptr, source: rawptr, count: u64) {
	if user_access_guard != 0 {
		_, _, _ = copy_bytes_upward_with_program_access(u64(uintptr(destination)), u64(uintptr(source)), count)
	} else {
		_, _, _ = copy_bytes_upward(u64(uintptr(destination)), u64(uintptr(source)), count)
	}
}
