// The debugger of a program, as the kernel gives it (docs/ARCHITECTURE.md,
// "The debugger of a program").
//
// A program with a handle of another program that has the right Debug
// becomes its debugger. This program is the debugger of children that it
// starts itself (this module, with a role): the program that creates a
// program has the right Debug on it. Each case checks one part of the
// contract:
//
//   1. The attach: a thread of the debugger is the debug handler of the
//      child.
//   2. A write of breakpoints on a thread that is not held is refused.
//   3. A handle with no Debug gives no debugging.
//   4. A breakpoint at an address of the kernel is refused.
//   5. An execute breakpoint at a procedure of the child: the fault record
//      names the breakpoint and the address.
//   6. The registers of the thread are read at the stop.
//   7. to 9. `Read_Memory` reads a value of the child, and refuses an
//      address of the kernel and a page that the child does not map.
//   10. `Read_Memory` through a thread handle with Inspect only is refused.
//   11. A single step runs one instruction.
//   12. A data breakpoint on a word that the child writes.
//   13. With the breakpoints removed, the child ends with its own code.
//   14. A detach while a thread is held gives the thread back.
//   15. A debugger that ends while the child is held at a breakpoint gives
//       the child back.
//
// **What it is for.** It is the test of the four additions of the kernel
// for a debugger: the right Debug, the delivery of the debug exceptions to
// the debugger, the breakpoints of a thread, and the read of the memory of
// a program. The commands of the console come on top of the same contract.
//
// **Start**: `start("debugged")` in the console. The parent starts each
// child from the boot image.
//
// **Grants**, as the root service gives them:
//
// - **Image**: the boot image, read-only, to start the children from it.
//
// **What a reader sees**: the log has one line for each case, which ends
// with "as it must", then "debugged: ok, 15 cases: a debugger holds, reads
// and steps one program, and its end gives the program back", or
// "debugged: failed: N cases of 15". The program has no window.
//
// The design: (docs/TOOLS.md, "The debugger: the design").
package debugged

import "base:intrinsics"
import "contract:errors"
import "contract:module"
import op "contract:operation"
import "support:random"
import "support:system"

VALUE_ROLE :: 0 // The value of the context that gives the role of a child.
VALUE_ROUNDS :: 1 // The rounds of the loop of a child. 0: with no end.

GRANT_SHARED :: 6 // A child: the page that it shares with the parent.
GRANT_TARGET :: 7 // The debugger that ends: the program that it debugs, with Debug.

CASE_COUNT :: 15

CHILD_ROUNDS :: 3
CHILD_RESULT :: 42 // The code with which a child of a fixed count of rounds stops.
DEBUGGER_ENDED_WITH_THE_CHILD_HELD :: 7 // The code of the debugger that ends, when the child waits at its breakpoint.

// The value that a child writes in `child_known_value`: the debugger reads
// it in the memory of the child, and its own copy stays 0.
KNOWN_VALUE :: u64(0x6368_696C_645F_6F6B)

// An address of the kernel half, and an address that no program maps: the
// first page.
KERNEL_ADDRESS :: u64(0xFFFF_8000_0000_0000)
UNMAPPED_ADDRESS :: u64(0x1000)

// The first byte of a procedure that keeps the frame pointer: push rbp.
PUSH_FRAME_POINTER :: 0x55

FLAG_TRAP :: u64(1) << 8

Role :: enum u64 {
	Parent             = 0,
	Child              = 1,
	Debugger_That_Ends = 2,
}

// The page that a child shares with the parent. The child writes it.
Shared :: struct {
	ready:  u32, // 1: the child wrote its known value.
	go:     u32, // The parent writes 1: a child of a fixed count of rounds starts its loop.
	rounds: u32, // The rounds of its loop that the child ended.
}

// The module is at the same address in the parent and in each child, so
// the address of a procedure or of a global of this module is the same in
// each of them.
child_known_value: u64
child_watched_word: u64
child_calls: u64

program_generator: random.Generator
image: []u8
right_count: int

// child_step_target is the procedure of the child where the debugger sets
// its execute breakpoint. It is not put inside its caller, so the thread
// reaches its first instruction at each call.
child_step_target :: proc "contextless" () {
	intrinsics.volatile_store(&child_calls, intrinsics.volatile_load(&child_calls) + 1)
}

// hang_bound gives a deadline that only ends a hang.
hang_bound :: proc "contextless" () -> u64 {
	return system.time() + system.TEST_HANG_BOUND_MILLISECONDS
}

// verdict counts a case and gives the end of its line.
verdict :: proc "contextless" (right: bool) -> string {
	if right {
		right_count += 1
		return ": as it must"
	}
	return ": WRONG"
}

// child_run is a child that the parent debugs: it writes its known value,
// then calls child_step_target and writes child_watched_word in a loop.
child_run :: proc "contextless" (ctx: ^system.Context) -> ! {
	address, status := system.memory_map(ctx.handles[GRANT_SHARED], {.Write})
	if status != .Ok {
		system.stop(20)
	}
	shared := (^Shared)(address)
	rounds := ctx.values[VALUE_ROUNDS]
	intrinsics.volatile_store(&child_known_value, KNOWN_VALUE)
	intrinsics.atomic_store(&shared.ready, 1)
	if rounds != 0 {
		// The parent sets its first breakpoint before the loop starts.
		for intrinsics.atomic_load(&shared.go) == 0 {
			system.sleep(system.time() + 1)
		}
	}
	for round := u64(0); rounds == 0 || round < rounds; round += 1 {
		#force_no_inline child_step_target()
		intrinsics.volatile_store(&child_watched_word, round + 1)
		intrinsics.atomic_add(&shared.rounds, 1)
		if rounds == 0 {
			system.sleep(system.time() + 1)
		}
	}
	system.stop(CHILD_RESULT)
}

// debugger_that_ends attaches to the program of its context, stops its
// thread at an execute breakpoint, holds it once more, and ends with no
// answer and no detach. Each other code names the step that failed.
debugger_that_ends :: proc "contextless" (ctx: ^system.Context) -> ! {
	target := ctx.handles[GRANT_TARGET]
	if system.debug_attach(target) != .Ok {
		system.stop(10)
	}
	if _, status := system.thread_control_stop(target, 0); status != .Ok {
		system.stop(11)
	}
	breakpoints: op.Thread_Breakpoints
	breakpoints.breakpoints[0] = {address = u64(uintptr(rawptr(child_step_target))), kind = .Execute}
	if system.thread_breakpoints_write(target, 0, breakpoints) != .Ok {
		system.stop(12)
	}
	if _, status := system.thread_control_resume(target, 0); status != .Ok {
		system.stop(13)
	}
	record, came := system.fault_record_next(hang_bound())
	if !came {
		system.stop(14)
	}
	if record.kind != .Debug || record.error_code & 1 == 0 {
		system.stop(15)
	}
	// A stop of the debugger on top of the wait: the end takes it back too.
	if _, status := system.thread_control_stop(target, record.thread); status != .Ok {
		system.stop(16)
	}
	system.stop(DEBUGGER_ENDED_WITH_THE_CHILD_HELD)
}

// parked is a thread of the parent that only waits: the parent names it by
// a thread handle with less rights.
parked :: proc "c" (parameter: rawptr) -> ! {
	for {
		system.sleep(system.time() + 1000)
	}
}

// shared_page_create makes the page that a child shares with the parent.
shared_page_create :: proc "contextless" () -> (memory: system.Handle, shared: ^Shared, ok: bool) {
	status: system.Status
	memory, status = system.memory_create(1)
	if status != .Ok {
		return 0, nil, false
	}
	address, mapped := system.memory_map(memory, {.Write})
	if mapped != .Ok {
		system.close(memory)
		return 0, nil, false
	}
	return memory, (^Shared)(address), true
}

// child_start starts a child of this module with a role.
child_start :: proc "contextless" (role: Role, rounds: u64, shared_memory: system.Handle, target: system.Handle) -> (program: system.Handle, ok: bool) {
	grants: [op.CONTEXT_HANDLES]system.Grant
	values: [op.CONTEXT_VALUES]u64
	values[VALUE_ROLE] = u64(role)
	values[VALUE_ROUNDS] = rounds
	if shared_memory != 0 {
		grants[GRANT_SHARED] = {shared_memory, {.Read, .Write}}
	}
	if target != 0 {
		grants[GRANT_TARGET] = {target, {.Debug}}
	}
	error: module.Load_Error
	status: system.Status
	program, status = system.program_start(system.image_find(image, "debugged"), "debugged child", grants, random.values_with_seed(&program_generator, values), {pages = 256, programs = 1, threads = 1, processor = 200_000, log_records = 10}, nil, nil, {image = image}, &error)
	return program, status == .Ok
}

// wait_for_word waits until a word of a shared page is not `before`. The
// bound only ends a hang.
wait_for_word :: proc "contextless" (word: ^u32, before: u32) -> bool {
	for deadline := hang_bound(); system.time() < deadline; {
		if intrinsics.atomic_load(word) != before {
			return true
		}
		system.sleep(system.time() + 1)
	}
	return false
}

// wait_for_stop waits until a program stopped, and gives its code. The
// bound only ends a hang.
wait_for_stop :: proc "contextless" (program: system.Handle) -> (code: u32, stopped: bool) {
	for deadline := hang_bound(); system.time() < deadline; {
		if state, stop_code := system.program_state(program); state == .Stopped {
			return stop_code, true
		}
		system.sleep(system.time() + 10)
	}
	return 0, false
}

// cases_of_one_child runs the cases 1 to 13 on one child that runs three
// rounds of its loop.
cases_of_one_child :: proc "contextless" () {
	memory, shared, made := shared_page_create()
	if !made {
		system.log("debugged: no shared page")
		return
	}
	defer system.close(memory)
	child, started := child_start(.Child, CHILD_ROUNDS, memory, 0)
	if !started || !wait_for_word(&shared.ready, 0) {
		system.log("debugged: the child did not start")
		return
	}
	defer system.close(child)
	target := u64(uintptr(rawptr(child_step_target)))
	watched := u64(uintptr(&child_watched_word))
	error: errors.Error_Record

	// 1. The attach.
	attached := system.debug_attach(child)
	system.log("debugged: attach: the debugger is the debug handler of the child", verdict(attached == .Ok))
	if attached != .Ok {
		system.log("debugged: detail: the attach gave the status ", u64(attached))
		return
	}

	// 2. The thread of the child runs or sleeps: it is not held.
	breakpoints: op.Thread_Breakpoints
	breakpoints.breakpoints[0] = {address = target, kind = .Execute}
	not_held := system.thread_breakpoints_write(child, 0, breakpoints)
	system.log("debugged: a write of breakpoints on a thread that is not held: refused with Bad_State", verdict(not_held == .Bad_State))

	// 3. A copy of the handle with no Debug.
	without_debug, copied := system.give(0, child, {.Read, .Control})
	attach_refused := system.debug_attach(without_debug)
	_, stop_refused := system.thread_control_stop(without_debug, 0)
	system.close(without_debug)
	system.log("debugged: a handle with no Debug: attach and Stop refused with No_Right", verdict(copied == .Ok && attach_refused == .No_Right && stop_refused == .No_Right))

	// The first breakpoint: the thread is held, gets it, and goes on.
	_, held := system.thread_control_stop(child, 0)
	written := system.thread_breakpoints_write(child, 0, breakpoints)
	_, resumed := system.thread_control_resume(child, 0)
	if held != .Ok || written != .Ok || resumed != .Ok {
		system.log("debugged: the first breakpoint was not set: the statuses ", u64(held), " ", u64(written), " ", u64(resumed))
		return
	}
	intrinsics.atomic_store(&shared.go, 1)

	// 5. The thread reaches the procedure.
	record, came := system.fault_record_next(hang_bound())
	reached := came && record.kind == .Debug && record.error_code == 1 && record.instruction == target && record.thread == 0
	system.log("debugged: detail: the record of the execute breakpoint: kind ", u64(record.kind), ", status ", system.Hex(record.error_code), ", instruction ", system.Hex(record.instruction), ", the procedure ", system.Hex(target))
	if !came {
		system.log("debugged: an execute breakpoint at a procedure of the child: no record came: WRONG")
		return
	}

	// 4. The thread is held at its breakpoint: a breakpoint of the kernel
	// half is refused, and the breakpoints of the thread stay.
	hostile: op.Thread_Breakpoints
	hostile.breakpoints[0] = {address = KERNEL_ADDRESS, kind = .Execute}
	error = {}
	kernel_refused := system.thread_breakpoints_write(child, 0, hostile, &error)
	kept, _ := system.thread_breakpoints_read(child, 0)
	system.log("debugged: a breakpoint at an address of the kernel: refused with the breakpoint address in the error record", verdict(kernel_refused == .Bad_Operation && error.found == i64(op.Thread_Write_Refusal.Breakpoint_Address) && u64(error.value) == KERNEL_ADDRESS && kept.breakpoints[0].address == target && kept.breakpoints[0].kind == .Execute))
	system.log("debugged: an execute breakpoint at a procedure of the child: the fault record names breakpoint 0 and the address", verdict(reached))

	// 6. The registers at the stop.
	registers, read := system.thread_registers_read(child, 0)
	system.log("debugged: the registers at the stop: the instruction address is the breakpoint", verdict(read == .Ok && registers.rip == target))

	// 7. to 9. The memory of the child.
	value: u64
	bytes := ([^]u8)(&value)[:8]
	count, memory_read := system.thread_memory_read(child, 0, u64(uintptr(&child_known_value)), bytes)
	system.log("debugged: detail: the value of the child ", system.Hex(value), ", the copy of the debugger ", system.Hex(intrinsics.volatile_load(&child_known_value)))
	system.log("debugged: Read_Memory of a value of the child: the bytes of the child, not of the debugger", verdict(memory_read == .Ok && count == 8 && value == KNOWN_VALUE && intrinsics.volatile_load(&child_known_value) == 0))
	_, kernel_read := system.thread_memory_read(child, 0, KERNEL_ADDRESS, bytes)
	system.log("debugged: Read_Memory at an address of the kernel: refused with Bad_Address", verdict(kernel_read == .Bad_Address))
	_, unmapped_read := system.thread_memory_read(child, 0, UNMAPPED_ADDRESS, bytes)
	system.log("debugged: Read_Memory of a page that the child does not map: refused with Bad_Address", verdict(unmapped_read == .Bad_Address))

	// 10. A thread handle with Inspect only sees the thread, and reads no
	// byte of its program.
	own, own_started := system.thread_start(parked, nil)
	inspect_only, narrowed := system.give(0, own.handle, {.Inspect})
	_, with_write := system.thread_memory_read(own.handle, 0, u64(uintptr(&child_known_value)), bytes)
	_, with_inspect := system.thread_memory_read(inspect_only, 0, u64(uintptr(&child_known_value)), bytes)
	system.log("debugged: Read_Memory through a thread handle with Inspect only: refused with No_Right", verdict(own_started == .Ok && narrowed == .Ok && with_write == .Ok && with_inspect == .No_Right))

	// 11. One instruction: the trap flag, then the answer.
	first: [1]u8
	system.thread_memory_read(child, 0, target, first[:])
	stepping := registers
	stepping.rflags |= FLAG_TRAP
	step_written := system.thread_registers_write(child, 0, stepping)
	step_answered := system.debug_fault_answer(child, record)
	step, step_came := system.fault_record_next(hang_bound())
	after, _ := system.thread_registers_read(child, 0)
	moved := after.rip > registers.rip && after.rip - registers.rip <= 15
	if first[0] == PUSH_FRAME_POINTER {
		// The instruction is one byte, and it moves the stack by 8.
		moved = after.rip == registers.rip + 1 && after.rsp == registers.rsp - 8
	}
	system.log("debugged: detail: the step: status ", system.Hex(step.error_code), ", the instruction address from ", system.Hex(registers.rip), " to ", system.Hex(after.rip), ", the first byte ", system.Hex(u64(first[0])))
	system.log("debugged: a single step: one instruction ran, and the record names the step", verdict(step_written == .Ok && step_answered == .Ok && step_came && step.kind == .Debug && step.error_code & op.DEBUG_STATUS_STEP != 0 && moved))
	if !step_came {
		return
	}
	// The thread goes on with no trap flag.
	after.rflags &~= FLAG_TRAP
	system.thread_registers_write(child, 0, after)

	// 12. A data breakpoint, and no execute breakpoint.
	data: op.Thread_Breakpoints
	data.breakpoints[1] = {address = watched, kind = .Write, length = 8}
	data_written := system.thread_breakpoints_write(child, 0, data)
	system.debug_fault_answer(child, step)
	write, write_came := system.fault_record_next(hang_bound())
	system.thread_memory_read(child, 0, watched, bytes)
	system.log("debugged: detail: the record of the data breakpoint: kind ", u64(write.kind), ", status ", system.Hex(write.error_code), ", the word of the child ", value)
	system.log("debugged: a data breakpoint on a word that the child writes: the fault record names breakpoint 1", verdict(data_written == .Ok && write_came && write.kind == .Debug && write.error_code == 2 && value == 1))
	if !write_came {
		return
	}

	// 13. No breakpoint: the child ends its rounds.
	none: op.Thread_Breakpoints
	removed := system.thread_breakpoints_write(child, 0, none)
	now, _ := system.thread_breakpoints_read(child, 0)
	system.debug_fault_answer(child, write)
	code, stopped := wait_for_stop(child)
	system.log("debugged: detail: the child stopped with the code ", u64(code), ", rounds ", u64(intrinsics.atomic_load(&shared.rounds)))
	system.log("debugged: the breakpoints removed: the child resumed and ended with its own code", verdict(removed == .Ok && now == none && stopped && code == CHILD_RESULT && intrinsics.atomic_load(&shared.rounds) == CHILD_ROUNDS))
}

// cases_of_the_end runs the cases 14 and 15 on one child whose loop has no
// end: what a debugger held comes back when the debugging ends.
cases_of_the_end :: proc "contextless" () {
	memory, shared, made := shared_page_create()
	if !made {
		system.log("debugged: no shared page")
		return
	}
	defer system.close(memory)
	child, started := child_start(.Child, 0, memory, 0)
	if !started || !wait_for_word(&shared.ready, 0) {
		system.log("debugged: the child did not start")
		return
	}
	defer system.close(child)
	// The child has no end of its own: the parent stops it.
	defer {
		system.call(.Program_Stop, u64(child), 0)
	}

	// 14. The thread is held, so its count of rounds stays; the detach
	// lets it count again.
	attached := system.debug_attach(child)
	_, held := system.thread_control_stop(child, 0)
	before := intrinsics.atomic_load(&shared.rounds)
	detached := system.debug_detach(child)
	runs := wait_for_word(&shared.rounds, before)
	system.log("debugged: a detach while a thread is held: the child runs again", verdict(attached == .Ok && held == .Ok && detached == .Ok && runs))

	// 15. Another program debugs the child, and ends with no answer.
	debugger, debugger_started := child_start(.Debugger_That_Ends, 0, 0, child)
	if !debugger_started {
		system.log("debugged: the debugger that ends did not start")
		return
	}
	defer system.close(debugger)
	code, stopped := wait_for_stop(debugger)
	before = intrinsics.atomic_load(&shared.rounds)
	runs = wait_for_word(&shared.rounds, before)
	state, _ := system.program_state(child)
	system.log("debugged: detail: the debugger that ends stopped with the code ", u64(code))
	system.log("debugged: the debugger ended while the child was held at a breakpoint: the child runs again", verdict(stopped && code == DEBUGGER_ENDED_WITH_THE_CHILD_HELD && runs && state != .Stopped))
}

// The entry of debugged. The context value `VALUE_ROLE` chooses the role:
//
// - `Child`: the program that is debugged (`child_run`).
// - `Debugger_That_Ends`: a debugger that ends while its program waits at
//   a breakpoint (`debugger_that_ends`).
// - `Parent` (0, as the root service starts it): it takes its random
//   generator and maps the boot image (a failure stops it with the code
//   1), runs the cases, writes the result on the log, and then waits for
//   ever.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	switch Role(ctx.values[VALUE_ROLE]) {
	case .Child:
		child_run(ctx)
	case .Debugger_That_Ends:
		debugger_that_ends(ctx)
	case .Parent:
	}
	if !random.generator_from_context(&program_generator, ctx) {
		system.log("debugged: no random seed in the context")
		system.stop(1)
	}
	address, status := system.memory_map(ctx.handles[system.GRANT_IMAGE], {})
	if status != .Ok {
		system.log("debugged: no boot image")
		system.stop(1)
	}
	image = ([^]u8)(address)[:ctx.values[system.GRANT_VALUE_IMAGE_SIZE]]
	cases_of_one_child()
	cases_of_the_end()
	if right_count == CASE_COUNT {
		system.log("debugged: ok, ", u64(CASE_COUNT), " cases: a debugger holds, reads and steps one program, and its end gives the program back")
	} else {
		system.log("debugged: failed: ", u64(CASE_COUNT - right_count), " cases of ", u64(CASE_COUNT))
	}
	for {
		system.sleep(system.time() + 1000)
	}
}
