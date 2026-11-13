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
		case .Write_Registers, .Write_Extended_State, .Read_Memory:
			testing.expect_value(t, rights, Rights{.Inspect, .Write})
			testing.expect(t, .Control not_in rights)
		case .Write_Breakpoints:
			// No thread handle writes a breakpoint: only the debugger of
			// the program, through its program handle.
			testing.expect(t, thread_control_needs_the_debugger(command))
			testing.expect(t, thread_control_takes_debug_handle(command))
		case .None, .Stop, .Resume, .Read_Registers, .Read_Extended_State, .Read_Schedule, .Read_Breakpoints, .Read_Placement:
			testing.expect_value(t, rights, Rights{.Inspect})
		case .Write_Schedule, .Write_Placement:
			// A write that only lowers a share, or only narrows a set of
			// processors: less than the end of the thread.
			testing.expect_value(t, rights, Rights{.Control})
		}
		// The machine handle: the schedule and the placement only, with
		// Schedule and Inspect for each: a read is a report of the machine,
		// and a write gives each value of the record, so its holder reads
		// first.
		machine_rights, by_machine_number := thread_control_machine_rights(command)
		#partial switch command {
		case .Read_Schedule, .Read_Placement:
			testing.expect(t, by_machine_number)
			testing.expect_value(t, machine_rights, Rights{.Schedule, .Inspect})
		case .Write_Schedule, .Write_Placement:
			testing.expect(t, by_machine_number)
			testing.expect_value(t, machine_rights, Rights{.Schedule, .Inspect})
		case:
			testing.expect(t, !by_machine_number)
			testing.expect_value(t, machine_rights, Rights{})
		}
	}
}

// The program handle with Debug names a thread for each command but the
// two of the schedule and the two of the placement.
@(test)
the_commands_of_a_debug_handle :: proc(t: ^testing.T) {
	for command in Thread_Control_Command {
		taken := thread_control_takes_debug_handle(command)
		#partial switch command {
		case .None, .Read_Schedule, .Write_Schedule, .Read_Placement, .Write_Placement:
			testing.expect(t, !taken)
		case:
			testing.expect(t, taken)
		}
	}
}

// The machine of these cases has 4 processors, as the machine of the
// machine test.
@(private = "file")
FOUR_PROCESSORS :: u64(0b1111)

// A program only narrows the set of its thread: a set inside the set that
// the thread has is accepted, 0 keeps the set, and the limit of the record
// is not read. The bits of processors that the machine does not have are
// dropped.
@(test)
a_program_only_narrows_a_placement :: proc(t: ^testing.T) {
	whole := Thread_Placement{processors = FOUR_PROCESSORS, processors_limit = FOUR_PROCESSORS}
	cases := [?]struct {
		written: Thread_Placement,
		held:    Thread_Placement,
		after:   Thread_Placement,
	} {
		// One processor of the four.
		{{processors = 0b0100}, whole, {0b0100, FOUR_PROCESSORS}},
		// 0 keeps the set.
		{{}, {0b0110, FOUR_PROCESSORS}, {0b0110, FOUR_PROCESSORS}},
		// The same set again.
		{{processors = 0b0110}, {0b0110, FOUR_PROCESSORS}, {0b0110, FOUR_PROCESSORS}},
		// All ones: the processors that the machine does not have are dropped.
		{{processors = max(u64)}, whole, whole},
		// The limit of the record is not read: the thread keeps its limit.
		{{processors = 0b0001, processors_limit = max(u64)}, {0b0011, 0b0011}, {0b0001, 0b0011}},
		{{processors_limit = max(u64)}, {0b0011, 0b0011}, {0b0011, 0b0011}},
	}
	for item in cases {
		after, refusal, _ := thread_placement_after_write(item.written, item.held, FOUR_PROCESSORS, false)
		testing.expect_value(t, refusal, Thread_Write_Refusal.None)
		testing.expect_value(t, after, item.after)
	}
}

// What a write of a program refuses: a processor that the set of the
// thread does not have, and a set with no processor of the machine. The
// placement stays, and the error record gets the set that the write had
// to stay inside.
@(test)
the_placements_that_a_program_cannot_write :: proc(t: ^testing.T) {
	cases := [?]struct {
		written: u64,
		held:    Thread_Placement,
		most:    u64,
	} {
		// A wider set.
		{0b0011, {0b0001, FOUR_PROCESSORS}, 0b0001},
		// Another processor, also inside the limit of the thread.
		{0b0010, {0b0001, FOUR_PROCESSORS}, 0b0001},
		// All ones on a thread that was narrowed.
		{max(u64), {0b0110, FOUR_PROCESSORS}, 0b0110},
		// Only processors that the machine does not have.
		{0b1_0000, {FOUR_PROCESSORS, FOUR_PROCESSORS}, FOUR_PROCESSORS},
		{u64(1) << 63, {0b0001, 0b0001}, FOUR_PROCESSORS},
	}
	for item in cases {
		after, refusal, most := thread_placement_after_write({processors = item.written}, item.held, FOUR_PROCESSORS, false)
		testing.expect_value(t, refusal, Thread_Write_Refusal.Processors)
		testing.expect_value(t, most, item.most)
		testing.expect_value(t, after, item.held)
	}
}

// The holder of the machine writes any set and the limit: 0 is every
// processor for the limit and the limit for the set, and the part of a set
// that is outside the new limit is dropped.
@(test)
the_machine_handle_writes_any_placement :: proc(t: ^testing.T) {
	narrow := Thread_Placement{processors = 0b0001, processors_limit = 0b0001}
	cases := [?]struct {
		written: Thread_Placement,
		after:   Thread_Placement,
	} {
		// The zero record: every processor, also for a thread that was narrowed.
		{{}, {FOUR_PROCESSORS, FOUR_PROCESSORS}},
		// A set wider than the set of the thread, and another limit.
		{{processors = 0b1100, processors_limit = 0b1110}, {0b1100, 0b1110}},
		// The set 0 is the limit.
		{{processors_limit = 0b1010}, {0b1010, 0b1010}},
		// The limit 0 is every processor.
		{{processors = 0b1000}, {0b1000, FOUR_PROCESSORS}},
		// The part of the set outside the limit is dropped.
		{{processors = 0b0111, processors_limit = 0b0110}, {0b0110, 0b0110}},
		// All ones for both.
		{{processors = max(u64), processors_limit = max(u64)}, {FOUR_PROCESSORS, FOUR_PROCESSORS}},
	}
	for item in cases {
		after, refusal, _ := thread_placement_after_write(item.written, narrow, FOUR_PROCESSORS, true)
		testing.expect_value(t, refusal, Thread_Write_Refusal.None)
		testing.expect_value(t, after, item.after)
	}
}

// What a write through the machine handle refuses: a limit or a set with
// no processor of the machine, and a set with no processor inside the
// limit. An empty set is never written: no accepted write gives a thread
// no processor.
@(test)
the_placements_that_the_machine_handle_cannot_write :: proc(t: ^testing.T) {
	held := Thread_Placement{processors = 0b0011, processors_limit = 0b0111}
	cases := [?]struct {
		written: Thread_Placement,
		refusal: Thread_Write_Refusal,
		most:    u64,
	} {
		{{processors_limit = 0b1_0000}, .Processors_Limit, FOUR_PROCESSORS},
		{{processors = 0b0001, processors_limit = u64(1) << 40}, .Processors_Limit, FOUR_PROCESSORS},
		{{processors = 0b1_0000}, .Processors, FOUR_PROCESSORS},
		{{processors = 0b1_0000, processors_limit = 0b0011}, .Processors, FOUR_PROCESSORS},
		{{processors = 0b1000, processors_limit = 0b0011}, .Processors, 0b0011},
		{{processors = 0b0100, processors_limit = 0b1011}, .Processors, 0b1011},
	}
	for item in cases {
		after, refusal, most := thread_placement_after_write(item.written, held, FOUR_PROCESSORS, true)
		testing.expect_value(t, refusal, item.refusal)
		testing.expect_value(t, most, item.most)
		testing.expect_value(t, after, held)
	}
}

// Each accepted write leaves a set that is not empty, that is inside its
// limit and inside the machine; a write of a program is also inside the
// set of before and keeps the limit. Each small pair of sets is tried, on
// machines of 1, 4 and 64 processors.
@(test)
no_write_leaves_a_placement_outside_its_bounds :: proc(t: ^testing.T) {
	machines := [?]u64{0b1, FOUR_PROCESSORS, max(u64)}
	writers := [?]bool{false, true}
	for machine in machines {
		for held_set in u64(1) ..< 16 {
			for held_limit in u64(1) ..< 16 {
				// A placement that the kernel can hold: a set inside its
				// limit, both inside the machine.
				if held_set & machine != held_set || held_limit & machine != held_limit || held_set & held_limit != held_set {
					continue
				}
				held := Thread_Placement{held_set, held_limit}
				for set in u64(0) ..< 32 {
					for limit in u64(0) ..< 32 {
						for by_machine in writers {
							after, refusal, _ := thread_placement_after_write({set, limit}, held, machine, by_machine)
							if refusal != .None {
								testing.expect_value(t, after, held)
								continue
							}
							testing.expect(t, after.processors != 0)
							testing.expect(t, after.processors & machine == after.processors)
							testing.expect(t, after.processors_limit & machine == after.processors_limit)
							testing.expect(t, after.processors & after.processors_limit == after.processors)
							if !by_machine {
								testing.expect(t, after.processors & held.processors == after.processors)
								testing.expect_value(t, after.processors_limit, held.processors_limit)
							}
						}
					}
				}
			}
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
	mask, ok = fault_kinds_of_debugger_argument(FAULT_KINDS_DEBUGGER)
	testing.expect(t, ok)
	testing.expect_value(t, mask, FAULT_KINDS_DEBUGGER)
	// One of the two kinds alone is refused: the other would stay with
	// the program.
	_, ok = fault_kinds_of_debugger_argument(u64(1) << u64(Fault_Kind.Debug))
	testing.expect(t, !ok)
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
