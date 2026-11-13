#+build !freestanding
package operation

import "core:testing"

// The registers that a thread of a program holds after its start: each
// write that the tests below change starts from them.
@(private = "file")
registers_of_a_program :: proc() -> Thread_Registers {
	return {rip = PROGRAM_BASE, rsp = STACK_TOP - 8, rflags = THREAD_FLAGS_REQUIRED, cs = THREAD_CODE_SELECTOR, ss = THREAD_STACK_SELECTOR}
}

// A write that the return of the processor would take is accepted, with
// each flag that a program can set itself, and the trap flag.
@(test)
the_registers_of_a_program_are_accepted :: proc(t: ^testing.T) {
	registers := registers_of_a_program()
	refusal, _ := thread_registers_refusal(&registers)
	testing.expect_value(t, refusal, Thread_Write_Refusal.None)
	registers.rflags = THREAD_FLAGS_ALLOWED
	refusal, _ = thread_registers_refusal(&registers)
	testing.expect_value(t, refusal, Thread_Write_Refusal.None)
	registers.rip = USER_END - 1
	registers.rsp = max(u64) // Canonical: all the high bits are 1.
	refusal, _ = thread_registers_refusal(&registers)
	testing.expect_value(t, refusal, Thread_Write_Refusal.None)
}

// Each value that would make the processor refuse the return, or give a
// program a right that it does not have, is refused, with that value.
@(test)
the_registers_that_a_program_cannot_hold_are_refused :: proc(t: ^testing.T) {
	Case :: struct {
		change:  proc(registers: ^Thread_Registers),
		refusal: Thread_Write_Refusal,
		value:   u64,
	}
	cases := [?]Case {
		{proc(registers: ^Thread_Registers) {registers.cs = 0x08}, .Code_Selector, 0x08}, // The code selector of the kernel.
		{proc(registers: ^Thread_Registers) {registers.ss = 0x10}, .Stack_Selector, 0x10},
		{proc(registers: ^Thread_Registers) {registers.rflags |= 0x3000}, .Flags, 0x3202}, // The I/O privilege level 3.
		{proc(registers: ^Thread_Registers) {registers.rflags = 0x2}, .Flags, 0x2}, // Interrupts off.
		{proc(registers: ^Thread_Registers) {registers.rflags |= 0x4000}, .Flags, 0x4202}, // Nested task.
		{proc(registers: ^Thread_Registers) {registers.rflags |= 1 << 17}, .Flags, 0x20202}, // Virtual-8086.
		{proc(registers: ^Thread_Registers) {registers.rip = USER_END}, .Instruction_Address, USER_END},
		{proc(registers: ^Thread_Registers) {registers.rip = 0xFFFF_8000_0000_0000}, .Instruction_Address, 0xFFFF_8000_0000_0000}, // An address of the kernel.
		{proc(registers: ^Thread_Registers) {registers.rsp = 0x8000_0000_0000_0000}, .Stack_Address, 0x8000_0000_0000_0000},
	}
	for item in cases {
		registers := registers_of_a_program()
		item.change(&registers)
		refusal, value := thread_registers_refusal(&registers)
		testing.expectf(t, refusal == item.refusal && value == item.value, "%v %x, not %v %x", refusal, value, item.refusal, item.value)
	}
}

// An area that a save wrote is accepted; a header that names a component
// that the kernel does not save, a reserved byte of the header, and an
// MXCSR bit outside the mask are refused. The form of fxsave reads no
// header.
@(test)
the_extended_state_that_the_processor_refuses_is_refused :: proc(t: ^testing.T) {
	area: [EXTENDED_STATE_LEGACY_BYTES + EXTENDED_STATE_HEADER_BYTES]u8
	components := u64(0b111) // x87, SSE, AVX.
	mask := u32(0xFFFF)
	area[EXTENDED_STATE_MXCSR_OFFSET] = 0x80
	area[EXTENDED_STATE_MXCSR_OFFSET + 1] = 0x1F // MXCSR 0x1F80.
	area[EXTENDED_STATE_LEGACY_BYTES] = 0b111
	refusal, value := extended_state_refusal(area[:], components, mask, true)
	testing.expect_value(t, refusal, Thread_Write_Refusal.None)

	area[EXTENDED_STATE_LEGACY_BYTES] = 0b1000_0011 // Component 7, which XCR0 does not enable.
	refusal, value = extended_state_refusal(area[:], components, mask, true)
	testing.expect_value(t, refusal, Thread_Write_Refusal.Header_Components)
	testing.expect_value(t, value, u64(0b1000_0011))
	refusal, _ = extended_state_refusal(area[:], components, mask, false)
	testing.expect_value(t, refusal, Thread_Write_Refusal.None)

	area[EXTENDED_STATE_LEGACY_BYTES] = 0b11
	area[EXTENDED_STATE_LEGACY_BYTES + 15] = 0x80 // XCOMP_BV bit 63: the compacted form.
	refusal, value = extended_state_refusal(area[:], components, mask, true)
	testing.expect_value(t, refusal, Thread_Write_Refusal.Header_Reserved)
	testing.expect_value(t, value, u64(0x8000_0000_0000_0000))
	area[EXTENDED_STATE_LEGACY_BYTES + 15] = 0

	area[EXTENDED_STATE_MXCSR_OFFSET + 2] = 1 // Bit 16 of MXCSR is reserved.
	refusal, value = extended_state_refusal(area[:], components, mask, false)
	testing.expect_value(t, refusal, Thread_Write_Refusal.Mxcsr)
	testing.expect_value(t, value, u64(0x1_1F80))
}

// The form of the operation names the command as a choice, so that an
// error record names a command that does not exist.
@(test)
the_form_of_thread_control :: proc(t: ^testing.T) {
	form := OPERATIONS[.Thread_Control]
	testing.expect_value(t, form.name, "Thread_Control")
	testing.expect_value(t, form.parameters[2].form, Form.Choice)
	testing.expect_value(t, form.parameters[2].limit, u64(max(Thread_Control_Command)))
	// No right in the form: each command has its own.
	testing.expect_value(t, form.parameters[0].rights, Rights{})
}

// A hold and each read need Inspect; a write of the registers needs Write
// too; only the write of the schedule needs Control, the right to end a
// thread, so a handle given to end a thread neither holds it nor writes its
// registers, and it can give the thread a smaller share.
@(test)
the_rights_of_each_command :: proc(t: ^testing.T) {
	for command in Thread_Control_Command {
		rights := thread_control_rights(command)
		switch command {
		case .Write_Registers, .Write_Extended_State, .Write_Breakpoints, .Read_Memory:
			testing.expect_value(t, rights, Rights{.Inspect, .Write})
			testing.expect(t, .Control not_in rights)
		case .None, .Stop, .Resume, .Read_Registers, .Read_Extended_State, .Read_Schedule, .Read_Breakpoints:
			testing.expect_value(t, rights, Rights{.Inspect})
		case .Write_Schedule:
			testing.expect_value(t, rights, Rights{.Control})
		}
		// The machine handle: the schedule only, with Schedule and Inspect
		// for each: a read is a report of the machine, and a write gives the
		// three values, so its holder reads first.
		machine_rights, by_machine_number := thread_control_machine_rights(command)
		#partial switch command {
		case .Read_Schedule:
			testing.expect(t, by_machine_number)
			testing.expect_value(t, machine_rights, Rights{.Schedule, .Inspect})
		case .Write_Schedule:
			testing.expect(t, by_machine_number)
			testing.expect_value(t, machine_rights, Rights{.Schedule, .Inspect})
		case:
			testing.expect(t, !by_machine_number)
			testing.expect_value(t, machine_rights, Rights{})
		}
	}
}

// The program handle with Debug names a thread for each command but the
// two of the schedule.
@(test)
the_commands_of_a_debug_handle :: proc(t: ^testing.T) {
	for command in Thread_Control_Command {
		taken := thread_control_takes_debug_handle(command)
		#partial switch command {
		case .None, .Read_Schedule, .Write_Schedule:
			testing.expect(t, !taken)
		case:
			testing.expect(t, taken)
		}
	}
}

// A breakpoint is at an address of a program, with a kind and a length
// that the processor has; the control register gets the local enable bits
// only.
@(test)
the_breakpoints_that_a_thread_can_have :: proc(t: ^testing.T) {
	breakpoints: Thread_Breakpoints
	refusal, value := thread_breakpoints_refusal(&breakpoints)
	testing.expect_value(t, refusal, Thread_Write_Refusal.None)
	testing.expect_value(t, thread_breakpoints_control(&breakpoints), DEBUG_CONTROL_NO_BREAKPOINT)

	breakpoints.breakpoints[0] = {address = 0x40_1000, kind = .Execute}
	breakpoints.breakpoints[2] = {address = 0x7FFF_0010, kind = .Write, length = 8}
	breakpoints.breakpoints[3] = {address = 0x7FFF_0024, kind = .Read_Or_Write, length = 4}
	refusal, value = thread_breakpoints_refusal(&breakpoints)
	testing.expect_value(t, refusal, Thread_Write_Refusal.None)
	// Local enable 0, 2 and 3; breakpoint 2: write, 8 bytes (1001 at bit
	// 24); breakpoint 3: read or write, 4 bytes (1111 at bit 28).
	testing.expect_value(t, thread_breakpoints_control(&breakpoints), u64(0x400 | 0b0101_0001 | 0b1001 << 24 | 0b1111 << 28))

	refused := [?]struct {
		breakpoint: Thread_Breakpoint,
		refusal:    Thread_Write_Refusal,
		value:      u64,
	} {
		{{address = USER_END, kind = .Execute}, .Breakpoint_Address, USER_END},
		{{address = 0xFFFF_8000_0000_0000, kind = .Write, length = 1}, .Breakpoint_Address, 0xFFFF_8000_0000_0000},
		{{address = USER_END - 4, kind = .Write, length = 8}, .Breakpoint_Address, USER_END - 4},
		{{address = 0x1001, kind = .Write, length = 2}, .Breakpoint_Address, 0x1001},
		{{address = 0x1000, kind = .Write, length = 3}, .Breakpoint_Length, 3},
		{{address = 0x1000, kind = .Write}, .Breakpoint_Length, 0},
		{{address = 0x1000, kind = .Execute, length = 1}, .Breakpoint_Length, 1},
		{{address = 0x1000}, .Breakpoint_Address, 0x1000},
		{{address = 0x1000, kind = Thread_Breakpoint_Kind(4)}, .Breakpoint_Kind, 4},
	}
	for item in refused {
		one: Thread_Breakpoints
		one.breakpoints[1] = item.breakpoint
		refusal, value = thread_breakpoints_refusal(&one)
		testing.expect_value(t, refusal, item.refusal)
		testing.expect_value(t, value, item.value)
	}
}

// The debugger of a program takes the two traps, and no other kind.
@(test)
the_kinds_of_a_debugger :: proc(t: ^testing.T) {
	mask, ok := fault_kinds_of_debugger_argument(0)
	testing.expect(t, ok)
	testing.expect_value(t, mask, FAULT_KINDS_DEBUGGER)
	mask, ok = fault_kinds_of_debugger_argument(u64(1) << u64(Fault_Kind.Debug))
	testing.expect(t, ok)
	testing.expect_value(t, mask, u64(1) << 1)
	_, ok = fault_kinds_of_debugger_argument(u64(1) << u64(Fault_Kind.Page_Fault))
	testing.expect(t, !ok)
}

// The values of a schedule that a thread can have: 0 is the default of
// each, the full weight and the longest request are the last ones accepted.
@(test)
the_values_of_a_schedule :: proc(t: ^testing.T) {
	testing.expect(t, thread_schedule_accepted(0, 0))
	testing.expect(t, thread_schedule_accepted(1, 1))
	testing.expect(t, thread_schedule_accepted(WEIGHT_FULL, REQUEST_LIMIT))
	testing.expect(t, !thread_schedule_accepted(WEIGHT_FULL + 1, 0))
	testing.expect(t, !thread_schedule_accepted(0, REQUEST_LIMIT + 1))
}
