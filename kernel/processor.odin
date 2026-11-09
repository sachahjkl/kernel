package kernel

// The processor: segments, the interrupt table, the interrupt controller and
// the timer. The frame layout is the one of kernel/processor.asm.

Frame :: struct {
	r15, r14, r13, r12, r11, r10, r9, r8: u64,
	rdi, rsi, rbp, rbx, rdx, rcx, rax:    u64,
	vector, error:                        u64,
	rip, cs, rflags, rsp, ss:             u64,
}
#assert(size_of(Frame) == 22 * 8)

Fpu_State :: struct #align (16) {
	bytes: [512]u8,
}

SELECTOR_KERNEL_CODE :: 0x08
SELECTOR_USER_DATA :: 0x18 | 3
SELECTOR_USER_CODE :: 0x20 | 3
SELECTOR_TASK :: 0x28
USER_FLAGS :: 0x202 // Interrupts on.

VECTOR_PAGE_FAULT :: 14
VECTOR_INTERRUPT_BASE :: 32
VECTOR_TIMER :: 32
VECTOR_KERNEL_ENTER :: 128
INTERRUPT_LINES :: 16
STUB_COUNT :: 48
TICKS_PER_SECOND :: 1000
TIME_SLICE :: 10 // Ticks that a program runs before another ready program gets the processor.

foreign _ {
	idle_wait :: proc "c" () ---
	gdt_load :: proc "c" (descriptor: rawptr) ---
	idt_load :: proc "c" (descriptor: rawptr) ---
	task_load :: proc "c" (selector: u16) ---
	msr_write :: proc "c" (index: u32, value: u64) ---
	msr_read :: proc "c" (index: u32) -> u64 ---
	cr2_read :: proc "c" () -> u64 ---
	cr3_read :: proc "c" () -> u64 ---
	cr3_write :: proc "c" (table: u64) ---
	page_flush :: proc "c" (address: u64) ---
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

KERNEL_STACK_SIZE :: 64 * 1024

segments: [7]u64
task_state: Task_State
gates: [256]Interrupt_Gate
kernel_stack: [KERNEL_STACK_SIZE]u8

@(export, link_name = "kernel_stack_top")
kernel_stack_top: u64

@(export, link_name = "current_fpu_area")
current_fpu_area: ^Fpu_State

idle_fpu_area: Fpu_State

processor_start :: proc "contextless" () {
	kernel_stack_top = (u64(uintptr(&kernel_stack)) + KERNEL_STACK_SIZE) &~ 15
	current_fpu_area = &idle_fpu_area

	task_state.stack_0 = kernel_stack_top
	task_state.port_offset = u16(offset_of(Task_State, ports))
	for &b in task_state.ports {
		b = 0xFF
	}
	task_address := u64(uintptr(&task_state))
	task_limit := u64(size_of(Task_State) - 1)
	segments = {
		0,
		0x00AF_9A00_0000_FFFF, // kernel code
		0x00CF_9200_0000_FFFF, // kernel data
		0x00CF_F200_0000_FFFF, // user data
		0x00AF_FA00_0000_FFFF, // user code
		task_limit & 0xFFFF | (task_address & 0xFF_FFFF) << 16 | 0x89 << 40 | (task_limit >> 16 & 0xF) << 48 | (task_address >> 24 & 0xFF) << 56,
		task_address >> 32,
	}
	descriptor := Table_Descriptor{size_of(segments) - 1, u64(uintptr(&segments))}
	gdt_load(&descriptor)
	task_load(SELECTOR_TASK)

	for stub, vector in interrupt_stubs {
		gates[vector] = {
			offset_low  = u16(stub),
			selector    = SELECTOR_KERNEL_CODE,
			type        = 0x8E, // Interrupt gate: interrupts are off in the kernel.
			offset_mid  = u16(stub >> 16),
			offset_high = u32(stub >> 32),
		}
	}
	descriptor = {size_of(gates) - 1, u64(uintptr(&gates))}
	idt_load(&descriptor)

	// The syscall instruction.
	MSR_EFER :: 0xC000_0080
	MSR_STAR :: 0xC000_0081
	MSR_LSTAR :: 0xC000_0082
	MSR_SFMASK :: 0xC000_0084
	msr_write(MSR_EFER, msr_read(MSR_EFER) | 1)
	msr_write(MSR_STAR, 0x0010_0008 << 32)
	msr_write(MSR_LSTAR, u64(uintptr(rawptr(kernel_enter))))
	msr_write(MSR_SFMASK, 0x700) // Clear the interrupt, direction and trap flags.

	// The interrupt controller (8259): lines 0 to 15 become vectors 32 to 47.
	port_write_8(0x20, 0x11)
	port_write_8(0xA0, 0x11)
	port_write_8(0x21, VECTOR_INTERRUPT_BASE)
	port_write_8(0xA1, VECTOR_INTERRUPT_BASE + 8)
	port_write_8(0x21, 4)
	port_write_8(0xA1, 2)
	port_write_8(0x21, 1)
	port_write_8(0xA1, 1)
	port_write_8(0x21, 0x00)
	port_write_8(0xA1, 0x00)

	// The timer (8254): one interrupt per millisecond.
	DIVISOR :: 1193182 / TICKS_PER_SECOND
	port_write_8(0x43, 0x34)
	port_write_8(0x40, u8(DIVISOR & 0xFF))
	port_write_8(0x40, u8(DIVISOR >> 8))
}

interrupt_end :: proc "contextless" (line: u64) {
	if line >= 8 {
		port_write_8(0xA0, 0x20)
	}
	port_write_8(0x20, 0x20)
}

// ports_allow lets the running program use, or not use, a range of ports.
ports_allow :: proc "contextless" (first, count: u64, allow: bool) {
	for port in first ..< min(first + count, 65536) {
		if allow {
			task_state.ports[port / 8] &~= 1 << (port % 8)
		} else {
			task_state.ports[port / 8] |= 1 << (port % 8)
		}
	}
}
