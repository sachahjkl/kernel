// The program that the test of the debugger debugs (docs/TOOLS.md, "The
// debugger").
//
// It holds what a debugger shows, with values that a test knows: a record
// with a record inside it, an array, an enumeration, a text, a count that
// a watch can see, a procedure with parameters and local variables, a loop
// to step through, and a second thread that only waits.
//
// **What it is for.** The machine test `kerneltool test debugger` attaches
// the debugger service to this program from the console and from the host,
// and waits for exact rows: a breakpoint by a procedure name and by a file
// and a line, the frames of the stack, a local variable of a caller, the
// fields of the record, an element of the array, the name of the
// enumeration value, one step, one line, and a watch of the count.
//
// **Start**: `start("debug_target")` in the console. It has no grant of
// the root service, so each caller that acts for the principal of its
// session can debug it.
//
// **What a reader sees**: the log has "debug_target: 64 more rounds ran, so
// the program is not held: as it must" each time its main thread ended 64
// rounds: a thread that a debugger holds writes no such line. The program
// has no window and no end: `stop("debug_target")` ends it.
//
// **Why its variables stay in memory.** The build optimises each module,
// and a variable that the compiler keeps in a register, or removes, is
// "not readable" in the debug object. The address of each variable that
// the test reads goes to a procedure that the compiler cannot put inside
// its caller, and each global is written and read with a volatile access:
// the compiler must keep them in memory, where the debug object finds
// them.
//
// The lines of `add_step` are named in the scenario of the test
// (tools/kerneltool/debugger_scenario.odin, DEBUG_TARGET_LINE_OF_THE_LOAD
// and DEBUG_TARGET_LINE_OF_THE_STORE): a change of this file above that
// procedure changes those two numbers.
package debug_target

import "base:intrinsics"
import "modus:support/system"

// What the program does now.
Phase :: enum u8 {
	Starting = 0,
	Counting = 1,
	Waiting  = 2,
}

// A point: the inner record.
Point :: struct {
	x: i64,
	y: i64,
}

// A record with two records, an enumeration and an integer inside it.
Shape :: struct {
	corner: Point,
	size:   Point,
	phase:  Phase,
	sides:  u32,
}

ROUND_LIMIT :: 3 // The calls of add_step in one round.
ROUND_STEP :: 2 // What each call adds.
ROUNDS_FOR_ONE_LINE :: 64 // The rounds between two lines of the log.

// The globals that the test reads. `fill_globals` writes their values.
rounds: u64 // The rounds that the main thread ended: a watch stops at its write.
shape: Shape // {corner = {3, 4}, size = {30, 40}, phase = Counting, sides = 4}.
table: [4]u64 // {10, 20, 30, 40}.
title: string // "debug target".
waiter_word: u32 // The word that the second thread waits on: nobody changes it.

// add_step adds a step to a sum. The debugger stops at its first
// instruction, runs one instruction, then one line, and stops at the line
// of the store.
add_step :: proc "contextless" (sum: ^u64, step: u64) {
	before := intrinsics.volatile_load(sum)
	intrinsics.volatile_store(sum, before + step)
}

// keep_in_memory receives the address of a variable, so that the compiler
// keeps the variable in memory.
keep_in_memory :: proc "contextless" (variable: ^u64) -> u64 {
	return intrinsics.volatile_load(variable)
}

// count_rounds adds `step` to a total `limit` times, and gives the total.
// Its two local variables are in memory for the whole procedure.
count_rounds :: proc "contextless" (limit: u64, step: u64) -> u64 {
	total: u64
	index: u64
	for {
		reached := #force_no_inline keep_in_memory(&index)
		if reached >= limit {
			break
		}
		#force_no_inline add_step(&total, step)
		intrinsics.volatile_store(&index, reached + 1)
	}
	return #force_no_inline keep_in_memory(&total)
}

// record_round counts one round: the one write of `rounds`.
record_round :: proc "contextless" () {
	intrinsics.volatile_store(&rounds, intrinsics.volatile_load(&rounds) + 1)
}

// fill_globals writes the values that the test knows.
fill_globals :: proc "contextless" () {
	intrinsics.volatile_store(&shape.corner.x, 3)
	intrinsics.volatile_store(&shape.corner.y, 4)
	intrinsics.volatile_store(&shape.size.x, 30)
	intrinsics.volatile_store(&shape.size.y, 40)
	intrinsics.volatile_store(&shape.phase, Phase.Counting)
	intrinsics.volatile_store(&shape.sides, 4)
	for &value, index in table {
		intrinsics.volatile_store(&value, u64(index + 1) * 10)
	}
	intrinsics.volatile_store(&title, "debug target")
}

// run_rounds is the loop of the main thread: one round, its count, a line
// of the log each ROUNDS_FOR_ONE_LINE rounds, and a short sleep.
run_rounds :: proc "contextless" () -> ! {
	wrong_totals: u64
	for {
		total := #force_no_inline count_rounds(ROUND_LIMIT, ROUND_STEP)
		if total != ROUND_LIMIT * ROUND_STEP {
			wrong_totals += 1
		}
		#force_no_inline record_round()
		if intrinsics.volatile_load(&rounds) % ROUNDS_FOR_ONE_LINE == 0 {
			if wrong_totals == 0 {
				system.log("debug_target: 64 more rounds ran, so the program is not held: as it must")
			} else {
				system.log("debug_target: 64 more rounds ran, and ", wrong_totals, " rounds gave a wrong total: WRONG")
			}
		}
		system.sleep(system.time() + 1)
	}
}

// waiter is the second thread: it waits on a word that nobody changes.
waiter :: proc "c" (parameter: rawptr) -> ! {
	for {
		system.word_wait(&waiter_word, 0)
	}
}

// The entry of debug_target. It writes its globals, starts the thread that
// waits, writes "debug_target: runs, with a thread that waits" (or stops
// with the code 1 when the thread does not start), then runs its rounds
// for ever.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	#force_no_inline fill_globals()
	if _, status := system.thread_start(waiter, nil); status != .Ok {
		system.log("debug_target: the second thread did not start: status ", status)
		system.stop(1)
	}
	system.log("debug_target: runs, with a thread that waits")
	#force_no_inline run_rounds()
}
