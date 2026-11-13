// Kernel events (docs/ARCHITECTURE.md, "Kernel events"), case by case.
//
// The kernel records its own work (the operations of the kernel entries,
// the switches of threads, the faults of programs, the waits for its locks)
// when a rule of the event table accepts an event, into one event ring for
// each processor, in a memory object of the program that gave the table.
// This program gives tables, runs a known load in children (this module,
// with a role), reads the rings, and checks the counts that must be exact:
//
//   1. No grant: a copy of the machine handle with no right is refused.
//   2. 16 rules are taken; a seventeenth rule is refused.
//   3. 1000 operations Memory_Size of one child: exactly 1000 records.
//   4. A thread of that child sleeps 20 times: a switch to it at each wake.
//   5. A child that faults once: one record of a fault that stops it.
//   6. "One in 10": exactly 100 records of 1000 operations.
//   7. A full ring: the records written and the lost count add up to 1000.
//   8. The table taken away: no record after it.
//   9. The address of a fault: 0 with a rule for every program, the
//      address with a rule that names the child.
//  10. 1000 gives and ends of a table while the loaders of the load child
//      enter the kernel on each processor: after each end, a pattern over
//      the whole memory object of the rings stays whole.
//  11. The cost: kernel entries in one second of the load child, with its
//      own count and time: with no rule, with a rule that names another
//      program, with a rule for every program that matches nothing, and
//      with a rule that accepts each of its operations; the records
//      written plus lost must be 0 for the second and the third, and its
//      count for the fourth.
//  12. The right revoked: the principal revokes the grant machine of this
//      program (the console, in the scenario); the table ends with it, no
//      record comes after, and Events_Set is refused.
//
// The end of a table with its owner is a step of the scenario: the tool
// stops this program while its table is given, waits for the line of the
// kernel, and starts it again; the first table of the second run is taken
// (a table that the kernel had kept would make it Bad_State). This program
// is the one holder of the right Events: it gives no right on.
//
// **What it is for.** A reader who wants to see what the kernel does for
// one program (its operations, its switches, its faults, its waits for a
// lock) asks for [kernel events](term:kernel-event), with no change of the
// kernel and no cost when no [event rule](term:event-rule) asks. This
// program checks that the counts are exact, that a rule that names
// another program costs nothing, and that the right **Events** holds.
//
// **What a reader sees.** Start it from the menu of the programs, or with
// `start("kernel_events")` in the console. The window has one row for each
// case. The log gets one line for each case, then `kernel_events: ok, 12
// cases: each count of the rings was exact, ...`, or `kernel_events:
// failed: <count> cases of 12`.
//
// **Its grants**: **Events**, the machine handle with the right Events,
// which gives an [event table](term:event-table) for every program, and
// **Image**, to start its children from the boot image. Its budget holds
// its window, an [event ring](term:event-ring) for each processor, and two
// children at one time.
package kernel_events

import "base:intrinsics"
import "contract:fixed_addresses"
import "contract:module"
import op "contract:operation"
import "support:display"
import "support:graphics"
import "support:interface"
import "support:random"
import "support:system"

LINE :: interface.TABLE_LINE
WIDTH :: 960
HEIGHT :: 600
PAGE :: system.PAGE_SIZE

// The value of the context that gives the role of a child: ROLE_TAG in the
// high half, the role in the low half. A value without the tag is the
// parent (the root service writes other values for a program with grants).
VALUE_ROLE :: 5
ROLE_TAG :: u64(0x4556_454E_0000_0000) // "EVEN"

Role :: enum u64 {
	Parent  = 0,
	Load    = 1, // Runs the operations of each round that the parent asks.
	Faulter = 2, // Faults once, at FAULT_ADDRESS, and stops.
}

// role_of gives the role that the starter of this program wrote.
role_of :: proc "contextless" (value: u64) -> Role {
	if value & 0xFFFF_FFFF_0000_0000 != ROLE_TAG || value & 0xFFFF_FFFF > u64(max(Role)) {
		return .Parent
	}
	return Role(value & 0xFFFF_FFFF)
}

CALLS :: 1000 // The operations Memory_Size of one round of the load child.
ONE_IN :: 10
SLEEPS :: 20 // The sleeps of the load child in the first round.
RING_RECORDS :: 8192 // The records of each ring: 512 KiB for each processor.
FULL_RING_RECORDS :: 16
STRESS_ROUNDS :: 1000
// The loaders of the load child: one for each processor, at most 4 (the
// test machine has 4); its budget pays for 4.
LOADERS_MOST :: 4
STRESS_PATTERN :: u64(0x5EED_E7E7_0000_0000)
FAULT_ADDRESS :: u64(0x1000) // Below the module of the program: no mapping.
MEASURE_TIME :: 300 // Milliseconds of one measure.
STOP_BY_PARENT :: 9

// What each child asks of the budget of this program: only what it uses.
// pages: its own copy of the module (the file is about 160 KiB, 40 pages,
// with its data), its stack (64 pages), its context (1), its thread area
// (1 + 2), its page tables (about 8) and its own objects (at most 2): under
// 130 pages; 256 leaves room for a larger module. The load child also has
// LOADERS_MOST loaders, each a stack of 16 pages and a thread area of 3.
// programs 1; threads: the main thread, and the loaders of the load child.
// Program_Create takes the program and its first thread from this budget.
// processor: the load child runs the measure of the cost for 300 ms with no
// wait, and its loaders run on each processor: it asks the limit of this
// program, at most one processor for each of its threads (entry sets it);
// with less, its budget would stop it in each period, and the measure
// would count the stops. The child that faults waits: 100 000.
// log_records 0: a child has no log handle and writes no record.
LOAD_AMOUNTS :: system.Budget_Amounts{pages = 256 + LOADERS_MOST * (16 + 3), programs = 1, threads = 1 + LOADERS_MOST, processor = (1 + LOADERS_MOST) * 1_000_000, log_records = 0}
WAITER_AMOUNTS :: system.Budget_Amounts{pages = 256, programs = 1, threads = 1, processor = 100_000, log_records = 0}

// The rounds of the load child.
ROUND_EXACT :: 1
ROUND_ONE_IN :: 2
ROUND_FULL :: 3
ROUND_TAKEN_AWAY :: 4
// One first use of a new page: the child writes its address in the page
// that it shares.
ROUND_FIRST_USE_ALL :: 5
ROUND_FIRST_USE_NAMED :: 6
// The loaders start, then stop.
ROUND_LOADERS_START :: 7
ROUND_LOADERS_STOP :: 8
// The rounds of the measure: the load child runs its loop of Memory_Size
// for MEASURE_TIME, and writes its own count and its own time.
ROUND_MEASURE_NO_RULE :: 9
ROUND_MEASURE_OTHER :: 10
ROUND_MEASURE_NOTHING :: 11
ROUND_MEASURE_EACH :: 12
// The right revoked: CALLS operations before the revocation, CALLS after.
ROUND_BEFORE_REVOCATION :: 13
ROUND_AFTER_REVOCATION :: 14

// The page that the parent shares with each child, at SHARED_ADDRESS in the
// child.
SHARED_ADDRESS :: fixed_addresses.OWN_CHOICE_START + 0x0000_0400_0000_0000
Shared_Page :: struct {
	go:           u32, // The round that the parent asks.
	done:         u32, // The last round that the load child ran.
	loaders:      u32, // The loaders that the load child started.
	reserved:     u32,
	first_use_address: u64, // A round of a first use: the address of the page.
	// A round of the measure: the operations Memory_Size that the load
	// child made, counted by its own loop, and the nanoseconds of the loop.
	measure_count:       u64,
	measure_nanoseconds: u64,
}

shared_page :: #force_inline proc "contextless" () -> ^Shared_Page {
	return (^Shared_Page)(uintptr(SHARED_ADDRESS))
}

// One case of the parent.
Case :: struct {
	name:  string,
	ran:   bool,
	right: bool,
	value: [96]u8, // The text of the row.
	value_length: int,
}

cases := [12]Case {
	{name = "no grant"},
	{name = "a seventeenth rule"},
	{name = "1000 operations of one program"},
	{name = "a thread that sleeps"},
	{name = "a child that faults once"},
	{name = "one in 10"},
	{name = "a full ring"},
	{name = "the table taken away"},
	{name = "the address of a fault"},
	{name = "1000 gives and ends under load"},
	{name = "kernel entries in one second"},
	{name = "the right revoked"},
}

// What the records of the rings say.
Tally :: struct {
	kinds:             [op.Event_Kind]u64,
	faults_stopped:    u64, // Fault records whose program stopped.
	fault_detail:      u64,
	fault_address:     u64,
	// Fault records with an address that is not 0, and whether one of them
	// had the address that this program looks for (fault_address_wanted).
	faults_with_address:  u64,
	fault_address_wanted: u64,
	fault_address_found:  bool,
	longest:           u64, // Cycles of the longest operation.
	longest_operation: u64,
}

program_generator: random.Generator
image: []u8
machine: system.Handle

// The memory object of the rings of this program, mapped with Write: the
// program writes the count read of each ring.
rings_memory: system.Handle
rings_base: rawptr
rings_pages: u64 // The pages of the memory object of the rings.
ring_bytes: u64
ring_records: u64 // The records of each ring in the table given last.
processor_count: u64

shown: Tally // The records of all the cases, for the window.
shown_lost: u64
// The four measures of the cost, in the order of the rounds: no rule; a
// rule that names another program; a rule for every program that matches
// nothing; a rule that accepts each operation of the load child.
Measure :: struct {
	count:       u64, // The operations of the loop of the load child: its own count.
	nanoseconds: u64, // The time of its loop.
	rate:        u64, // count in one second.
	written:     u64, // The records in all the rings when the table ended: the sum of the heads.
	lost:        u64,
}
measures: [4]Measure

records_now, records_before: [256]interface.Draw_Record
text_now, text_before: [4096]u8
drawing: interface.Window_Drawing

// A child of this program: its handle and the page that it shares.
Child :: struct {
	program:       system.Handle,
	shared_memory: system.Handle,
	shared:        ^Shared_Page,
	before:        system.Budget_Amounts,
}

child_start :: proc "contextless" (role: Role, name: string, amounts: system.Budget_Amounts) -> (child: Child, ok: bool) {
	status: system.Status
	child.shared_memory, status = system.memory_create(1)
	if status != .Ok {
		system.log("kernel_events: ", name, ": memory_create of the shared page failed: ", op.STATUS_NAMES[status])
		return
	}
	address: rawptr
	address, status = system.memory_map(child.shared_memory)
	if status != .Ok {
		system.log("kernel_events: ", name, ": memory_map of the shared page failed: ", op.STATUS_NAMES[status])
		system.close(child.shared_memory)
		return
	}
	child.shared = (^Shared_Page)(address)
	child.before, _ = system.budget_read()
	mappings := [1]system.Mapping{{memory = child.shared_memory, address = SHARED_ADDRESS, flags = {.Write}}}
	// A child gets no handle of this program: the right Events stays here.
	grants: [op.CONTEXT_HANDLES]system.Grant
	values: [op.CONTEXT_VALUES]u64
	values[VALUE_ROLE] = ROLE_TAG | u64(role)
	error: module.Load_Error
	child.program, status = system.program_start(system.image_find(image, "kernel_events"), "kernel_events child", grants, random.values_with_seed(&program_generator, values), amounts, mappings[:], nil, {image = image}, &error)
	if status != .Ok {
		buffer: [512]u8
		lines := system.Writer{buffer = buffer[:]}
		system.load_error_text(&lines, &error)
		// No_Budget: Budget_Create moves the pages, the programs and the
		// threads from this budget, and refuses a processor limit or a log
		// limit above the limits of this budget; then the new budget pays
		// for the program, its page tables, its first thread and the load.
		// Each amount, what this budget holds and what the child asks.
		system.log("kernel_events: ", name, ": program_start failed: ", op.STATUS_NAMES[status], "; the load: ", system.written(&lines), "; this program can give pages ", child.before.pages, ", programs ", child.before.programs, ", threads ", child.before.threads, ", processor ", child.before.processor, ", log records ", child.before.log_records, "; the child asks pages ", amounts.pages, ", programs ", amounts.programs, ", threads ", amounts.threads, ", processor ", amounts.processor, ", log records ", amounts.log_records)
		system.memory_unmap(address)
		system.close(child.shared_memory)
		return
	}
	return child, true
}

// child_stopped waits until a child stopped. The bound only ends a hang.
child_stopped :: proc "contextless" (child: ^Child) -> bool {
	for deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS; system.time() < deadline; {
		results, status := system.call(.Program_State, u64(child.program))
		if status != .Ok || op.Program_State(results[0]) == .Stopped {
			return status == .Ok
		}
		system.sleep(system.time() + 10)
	}
	return false
}

// child_end stops a child, closes it, and says if its budget came back
// whole: each page, each thread and its program. The budget comes back when
// the last processor left the child; the bound only ends a hang.
child_end :: proc "contextless" (child: ^Child, name: string) -> (back: bool) {
	system.call(.Program_Stop, u64(child.program), STOP_BY_PARENT)
	child_stopped(child)
	system.close(child.program)
	for deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS; !back && system.time() < deadline; {
		after, _ := system.budget_read()
		back = after.pages == child.before.pages && after.threads == child.before.threads && after.programs == child.before.programs
		if !back {
			system.sleep(system.time() + 10)
		}
	}
	if !back {
		system.log("kernel_events: ", name, ": the budget of this program did not get back every page, thread and program of the child in ", u64(system.TEST_HANG_BOUND_MILLISECONDS), " ms")
	}
	system.memory_unmap(child.shared)
	system.close(child.shared_memory)
	return back
}

// round_run asks the load child to run one round and waits for its end. The
// bound only ends a hang.
round_run :: proc "contextless" (load: ^Child, round: u32) -> bool {
	intrinsics.atomic_store(&load.shared.go, round)
	system.word_wake(&load.shared.go)
	deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS
	for system.time() < deadline {
		done := intrinsics.atomic_load(&load.shared.done)
		if done == round {
			return true
		}
		system.word_wait(&load.shared.done, done, system.time() + 100)
	}
	if intrinsics.atomic_load(&load.shared.done) == round {
		return true
	}
	system.log("kernel_events: the load child did not end the round ", u64(round), " in ", u64(system.TEST_HANG_BOUND_MILLISECONDS), " ms")
	return false
}

// table_give gives an event table with the rings of this program.
table_give :: proc "contextless" (rules: []op.Event_Rule, records: u64) -> system.Status {
	bytes, processors, status := system.events_set(machine, rings_memory, rules, records)
	if status == .Ok {
		ring_bytes = bytes
		processor_count = processors
		ring_records = records
	} else {
		system.log("kernel_events: Events_Set with ", u64(len(rules)), " rules and ", records, " records gave ", op.STATUS_NAMES[status])
	}
	return status
}

// heads gives the sums of the counts of the heads of the rings, and the
// most records that one ring holds.
heads :: proc "contextless" () -> (written: u64, lost: u64, most: u64) {
	for processor in 0 ..< processor_count {
		head, _ := system.event_ring(rings_base, ring_bytes, processor, ring_records)
		ring_written := intrinsics.atomic_load(&head.written)
		written += ring_written
		lost += intrinsics.atomic_load(&head.lost)
		most = max(most, ring_written - intrinsics.atomic_load(&head.read))
	}
	return
}

// rings_read reads every record of every ring.
rings_read :: proc "contextless" (tally: ^Tally) {
	for processor in 0 ..< processor_count {
		head, records := system.event_ring(rings_base, ring_bytes, processor, ring_records)
		for {
			record, ok := system.event_next(head, records)
			if !ok {
				break
			}
			tally_add(tally, record)
			tally_add(&shown, record)
		}
		shown_lost += intrinsics.atomic_load(&head.lost)
	}
}

tally_add :: proc "contextless" (tally: ^Tally, record: op.Event_Record) {
	if record.kind > max(op.Event_Kind) {
		return
	}
	tally.kinds[record.kind] += 1
	#partial switch record.kind {
	case .Operation:
		if record.value_0 > tally.longest {
			tally.longest = record.value_0
			tally.longest_operation = record.detail
		}
	case .Fault:
		if record.value_0 != 0 {
			tally.faults_with_address += 1
		}
		if tally.fault_address_wanted != 0 && record.value_0 == tally.fault_address_wanted && op.Event_Fault_Outcome(record.value_1) == .First_Use {
			tally.fault_address_found = true
		}
		if op.Event_Fault_Outcome(record.value_1) == .Stopped {
			tally.faults_stopped += 1
			tally.fault_detail = record.detail
			tally.fault_address = record.value_0
		}
	}
}

// nanoseconds_of gives the time of a number of cycles of the cycle counter.
nanoseconds_of :: proc "contextless" (cycles: u64) -> u64 {
	frequency := max(system.cycle_frequency(), 1)
	return cycles / frequency * 1_000_000_000 + cycles % frequency * 1_000_000_000 / frequency
}

operation_name :: proc "contextless" (operation: u64) -> string {
	if operation > u64(max(op.Operation)) {
		return "an unknown operation"
	}
	return op.OPERATIONS[op.Operation(operation)].name
}

case_end :: proc "contextless" (index: int, right: bool, parts: ..system.Part) {
	item := &cases[index]
	item.ran = true
	item.right = right
	item.value_length = len(system.format(item.value[:], ..parts))
}

// The cases 1 and 2: with no rule in the kernel yet.
cases_of_refusal :: proc "contextless" () {
	rules: [op.EVENT_RULE_CAPACITY + 1]op.Event_Rule
	for &rule in rules {
		rule = {kind = .Lock_Wait}
	}
	// 1. A copy of the machine handle in this program, with no right: the
	// grant of the root service is the only way to the event table.
	without_right, given := system.give(0, machine, {})
	refused := system.Status.Ok
	if given == .Ok {
		_, _, refused = system.events_set(without_right, rings_memory, rules[:1], RING_RECORDS)
		system.close(without_right)
	}
	right := given == .Ok && refused == .No_Right
	system.log("kernel_events: no grant: Events_Set with a copy of the machine handle with no right gave ", op.STATUS_NAMES[refused], right ? string(": as it must") : string(": WRONG"))
	case_end(0, right, right ? string("refused with No_Right: as it must") : string("WRONG: see the log"))

	// 2. 16 rules, then 17.
	sixteen := table_give(rules[:op.EVENT_RULE_CAPACITY], RING_RECORDS)
	if sixteen == .Ok {
		system.events_end(machine)
	}
	_, _, seventeen := system.events_set(machine, rings_memory, rules[:], RING_RECORDS)
	right = sixteen == .Ok && seventeen == .No_Slot
	system.log("kernel_events: a seventeenth rule: 16 rules ", op.STATUS_NAMES[sixteen], ", 17 rules ", op.STATUS_NAMES[seventeen], right ? string(": as it must") : string(": WRONG"))
	case_end(1, right, right ? string("16 taken, 17 refused with No_Slot: as it must") : string("WRONG: see the log"))
}

// The cases 3 to 8, with the load child (the caller started it and ends
// it) and the child that faults. Each count that a case checks is a count
// that this program knows by its own means: the loop of the load child
// (CALLS, SLEEPS), the one access of the child that faults. The child that
// faults stops at its fault; the caller keeps its handle until after the
// measure, where a rule names it (case_of_the_cost), and ends it then.
cases_of_counts :: proc "contextless" (window: ^display.Window, load: ^Child) -> (faulter: Child, faulter_started: bool) {
	faulter, faulter_started = child_start(.Faulter, "the child that faults", WAITER_AMOUNTS)
	if !faulter_started {
		system.log("kernel_events: the child that faults did not start: the cases 3 to 8 do not run")
		return
	}
	memory_size := u64(op.Operation.Memory_Size)

	// 3, 4 and 5. One table: the operations Memory_Size of the load child,
	// its switches, and the faults of the other child. No rule for every
	// program here: its records would share the rings with the counted
	// ones, and a ring that it fills would lose counted records.
	exact := [3]op.Event_Rule {
		{kind = .Operation, flags = {.Match_Detail}, program = u64(load.program), detail = memory_size},
		{kind = .Switch, program = u64(load.program)},
		{kind = .Fault, program = u64(faulter.program)},
	}
	tally: Tally
	given := table_give(exact[:], RING_RECORDS)
	intrinsics.atomic_store(&faulter.shared.go, 1)
	system.word_wake(&faulter.shared.go)
	ran := given == .Ok && round_run(load, ROUND_EXACT)
	faulted := child_stopped(&faulter)
	_, lost, _ := heads()
	rings_read(&tally)
	// Each record of the kind Operation comes from the one rule of that
	// kind, so the records + lost of all the rings is at most the count of
	// the loop; with no record lost, it is exactly that count.
	right := ran && tally.kinds[.Operation] == CALLS && lost == 0
	system.log("kernel_events: 1000 operations Memory_Size of one program: ", tally.kinds[.Operation], " records, ", lost, " lost", right ? string(": as it must") : string(": WRONG"))
	case_end(2, right, tally.kinds[.Operation], " records, ", lost, " lost", right ? string(": as it must") : string(": WRONG"))
	// A lower bound: each of the 20 sleeps of the loop ends with a switch
	// to the thread; its waits for the round add more.
	right = ran && tally.kinds[.Switch] >= SLEEPS
	system.log("kernel_events: a thread that sleeps 20 times: ", tally.kinds[.Switch], " switches to it", right ? string(": as it must") : string(": WRONG"))
	case_end(3, right, tally.kinds[.Switch], " switches to it, at least 20", right ? string(": as it must") : string(": WRONG"))
	code, _ := system.call(.Program_State, u64(faulter.program))
	right = faulted && tally.faults_stopped == 1 && tally.fault_detail == 14 && tally.fault_address == FAULT_ADDRESS
	system.log("kernel_events: a child that faults once: ", tally.faults_stopped, " record of a fault that stopped it, vector ", tally.fault_detail, ", address ", system.Hex(tally.fault_address), ", stop code ", system.Hex(code[1]), right ? string(": as it must") : string(": WRONG"))
	case_end(4, right, tally.faults_stopped, " record, vector ", tally.fault_detail, right ? string(": as it must") : string(": WRONG"))
	interface_draw(window)

	// 6. One in 10.
	one_in := [1]op.Event_Rule{{kind = .Operation, flags = {.Match_Detail}, program = u64(load.program), detail = memory_size, one_in = ONE_IN}}
	tally = {}
	ran = table_give(one_in[:], RING_RECORDS) == .Ok && round_run(load, ROUND_ONE_IN)
	rings_read(&tally)
	right = ran && tally.kinds[.Operation] == CALLS / ONE_IN
	system.log("kernel_events: one in 10: ", tally.kinds[.Operation], " records of 1000 operations", right ? string(": as it must") : string(": WRONG"))
	case_end(5, right, tally.kinds[.Operation], " records of 1000", right ? string(": as it must") : string(": WRONG"))
	interface_draw(window)

	// 7. A full ring: this program reads nothing until the end of the round.
	tally = {}
	ran = table_give(exact[:1], FULL_RING_RECORDS) == .Ok && round_run(load, ROUND_FULL)
	written, full_lost, most := heads()
	rings_read(&tally)
	right = ran && written + full_lost == CALLS && full_lost > 0 && most <= FULL_RING_RECORDS && tally.kinds[.Operation] == written
	system.log("kernel_events: a full ring of 16 records: ", written, " written, ", full_lost, " lost, ", written + full_lost, " of 1000", right ? string(": as it must") : string(": WRONG"))
	case_end(6, right, written, " written, ", full_lost, " lost, of 1000", right ? string(": as it must") : string(": WRONG"))
	interface_draw(window)

	// 8. The table taken away: the heads do not move in a round after it,
	// and a second take is refused.
	ended := system.events_end(machine)
	written_before, lost_before, _ := heads()
	ran = ended == .Ok && round_run(load, ROUND_TAKEN_AWAY)
	written_after, lost_after, _ := heads()
	second := system.events_end(machine)
	right = ran && written_after == written_before && lost_after == lost_before && second == .Bad_State
	system.log("kernel_events: the table taken away: ", written_after - written_before, " records after it; a second take gave ", op.STATUS_NAMES[second], right ? string(": as it must") : string(": WRONG"))
	case_end(7, right, written_after - written_before, " records after it", right ? string(": as it must") : string(": WRONG"))
	interface_draw(window)
	return
}

// Case 9: the address of a fault. The load child makes one first use of a
// new page in each round, and writes its address. With a rule for every
// program, no Fault record has an address; with a rule that names the
// child, one record has that address.
case_of_the_fault_address :: proc "contextless" (load: ^Child) {
	every := [1]op.Event_Rule{{kind = .Fault, flags = {.Match_Detail}, detail = 14}}
	named := [1]op.Event_Rule{{kind = .Fault, flags = {.Match_Detail}, program = u64(load.program), detail = 14}}
	all_tally, named_tally: Tally
	ran := table_give(every[:], RING_RECORDS) == .Ok && round_run(load, ROUND_FIRST_USE_ALL)
	ran = ran && system.events_end(machine) == .Ok
	rings_read(&all_tally)
	ran = ran && table_give(named[:], RING_RECORDS) == .Ok && round_run(load, ROUND_FIRST_USE_NAMED)
	ran = ran && system.events_end(machine) == .Ok
	// The address of the second round: the child wrote it in its round.
	named_tally.fault_address_wanted = intrinsics.atomic_load(&load.shared.first_use_address)
	rings_read(&named_tally)
	right := ran && all_tally.kinds[.Fault] >= 1 && all_tally.faults_with_address == 0 && named_tally.fault_address_wanted != 0 && named_tally.fault_address_found
	system.log("kernel_events: the address of a fault: a rule for every program: ", all_tally.kinds[.Fault], " page faults, ", all_tally.faults_with_address, " with an address; a rule that names the child: its first use at ", system.Hex(named_tally.fault_address_wanted), named_tally.fault_address_found ? string(" is in a record") : string(" is in no record"), right ? string(": as it must") : string(": WRONG"))
	case_end(8, right, all_tally.faults_with_address, " addresses for every program; the named one ", named_tally.fault_address_found ? string("given") : string("missing"), right ? string(": as it must") : string(": WRONG"))
}

// Case 10: the end of a table while event points run on every processor.
// The loaders of the load child make kernel entries on each processor; a
// rule accepts each of their operations, so the rings fill (records and
// lost records both). After each end, this program writes a pattern over
// the whole memory object, lets the loaders run, and reads it back: a
// changed word is a record that the kernel wrote after the end.
case_of_the_ends_under_load :: proc "contextless" (load: ^Child, window: ^display.Window) {
	rules := [1]op.Event_Rule{{kind = .Operation, program = u64(load.program)}}
	words := rings_pages * PAGE / size_of(u64)
	base := ([^]u64)(rings_base)
	ran := round_run(load, ROUND_LOADERS_START)
	loaders := intrinsics.atomic_load(&load.shared.loaders)
	rounds := 0
	broken_round := -1
	broken_offset: u64
	written_sum, lost_sum: u64
	for ran && rounds < STRESS_ROUNDS && broken_round < 0 {
		if table_give(rules[:], RING_RECORDS) != .Ok {
			ran = false
			break
		}
		system.sleep(system.time() + 1)
		if system.events_end(machine) != .Ok {
			ran = false
			break
		}
		written, lost, _ := heads()
		written_sum += written
		lost_sum += lost
		pattern := STRESS_PATTERN ~ u64(rounds) << 32
		for index in 0 ..< words {
			intrinsics.volatile_store(&base[index], pattern ~ u64(index))
		}
		system.sleep(system.time() + 1)
		for index in 0 ..< words {
			if intrinsics.volatile_load(&base[index]) != pattern ~ u64(index) {
				broken_round = rounds
				broken_offset = index * size_of(u64)
				break
			}
		}
		rounds += 1
	}
	stopped := round_run(load, ROUND_LOADERS_STOP)
	right := ran && stopped && loaders >= 1 && rounds == STRESS_ROUNDS && broken_round < 0 && written_sum != 0
	if broken_round >= 0 {
		system.log("kernel_events: 1000 gives and ends under load: WRONG: after the end ", u64(broken_round), ", the word at the offset ", system.Hex(broken_offset), " of the memory object of the rings changed: a record written after the end")
	}
	system.log("kernel_events: 1000 gives and ends under load: ", u64(rounds), " ends with ", u64(loaders), " loaders, ", written_sum, " records and ", lost_sum, " lost in all, the pattern whole after each end", right ? string(": as it must") : string(": WRONG"))
	case_end(9, right, u64(rounds), " ends, ", u64(loaders), " loaders, the pattern whole", right ? string(": as it must") : string(": WRONG"))
	interface_draw(window)
}

// Case 12: the right revoked. The table names the operations Memory_Size
// of the load child. A round before the revocation gives CALLS records;
// then this program waits until its machine handle ends (the principal
// revokes the grant machine; the scenario types it in the console). The
// table must have ended with it: a round after it adds no record, and
// Events_Set with the handle is refused.
case_of_the_revoked_right :: proc "contextless" (load: ^Child) {
	rules := [1]op.Event_Rule{{kind = .Operation, flags = {.Match_Detail}, program = u64(load.program), detail = u64(op.Operation.Memory_Size)}}
	ran := table_give(rules[:], RING_RECORDS) == .Ok && round_run(load, ROUND_BEFORE_REVOCATION)
	written_before, lost_before, _ := heads()
	system.log("kernel_events: the table is given; waiting for the revocation of the grant machine")
	// The wait for the principal has no bound: the principal takes the time that
	// they take, and the machine test bounds each of its own steps.
	revoked := false
	for !revoked {
		if _, status := system.call(.Handle_State, u64(machine)); status != .Ok {
			revoked = true
			break
		}
		system.sleep(system.time() + 10)
	}
	ran = ran && round_run(load, ROUND_AFTER_REVOCATION)
	written_after, lost_after, _ := heads()
	_, _, refused := system.events_set(machine, rings_memory, rules[:], RING_RECORDS)
	right := ran && revoked && written_before + lost_before == CALLS && written_after == written_before && lost_after == lost_before && refused == .Bad_Handle
	system.log("kernel_events: the right revoked: ", written_before + lost_before, " records of ", u64(CALLS), " before it; ", written_after - written_before, " records after it; Events_Set after it gave ", op.STATUS_NAMES[refused], right ? string(": as it must") : string(": WRONG"))
	case_end(11, right, written_after - written_before, " records after it, then ", op.STATUS_NAMES[refused], right ? string(": as it must") : string(": WRONG"))
}

// The thread that empties the rings during the measures: it moves the
// count read of each ring to its count written, each millisecond, as an
// observer does. It runs in the four rounds, so that the four measures
// have the same threads; its own kernel entries are waits with no command,
// and no rule of the measure names this program.
drain_running: u32

drain_thread :: proc "c" (_: rawptr) -> ! {
	for intrinsics.atomic_load(&drain_running) == 1 {
		for processor in 0 ..< processor_count {
			head, _ := system.event_ring(rings_base, ring_bytes, processor, ring_records)
			intrinsics.atomic_store(&head.read, intrinsics.atomic_load(&head.written))
		}
		system.sleep(system.time() + 1)
	}
	system.thread_stop()
}

// measure_round runs one round of the measure in the load child, with a
// table of rules or none. The table lives from before the round to after
// it, and in that time the load child makes no operation Memory_Size but
// the ones of its loop: so the events that a rule for its Memory_Size
// accepts are exactly the count of its loop. The heads are read after the
// table ended: the kernel writes no more there.
measure_round :: proc "contextless" (load: ^Child, round: u32, rules: []op.Event_Rule, measure: ^Measure) -> bool {
	if len(rules) != 0 && table_give(rules, RING_RECORDS) != .Ok {
		return false
	}
	intrinsics.atomic_store(&drain_running, 1)
	drainer, drainer_status := system.thread_start(drain_thread, nil)
	ran := drainer_status == .Ok && round_run(load, round)
	intrinsics.atomic_store(&drain_running, 0)
	if drainer_status == .Ok {
		system.thread_wait(drainer)
	} else {
		system.log("kernel_events: the thread that empties the rings did not start: ", op.STATUS_NAMES[drainer_status])
	}
	if len(rules) != 0 {
		ended := system.events_end(machine)
		measure.written, measure.lost, _ = heads()
		ran = ran && ended == .Ok
	}
	measure.count = intrinsics.atomic_load(&load.shared.measure_count)
	measure.nanoseconds = max(intrinsics.atomic_load(&load.shared.measure_nanoseconds), 1)
	measure.rate = measure.count * 1_000_000_000 / measure.nanoseconds
	return ran && measure.count != 0
}

// Case 11: the cost of an entry, measured by the load child with its own
// count and its own time (one operation Memory_Size in each entry, as the
// lockers of the program locks), four times, each round of the same time
// and with the thread that empties the rings:
//   1. no rule;
//   2. a rule of the kind Operation that names another program: the child
//      that faults, which stopped at its fault, whose handle this program
//      keeps, and which makes no operation (the slot keeps its program and
//      its serial while the handle lives). The event point of the load
//      child loads the set of the program slots of the kind and skips;
//   3. a rule for every program that matches nothing (Machine_Stop): the
//      event point reads the cycle counter twice, calls event_record and
//      tests the rule;
//   4. a rule that accepts each operation of the loop.
// The three last ones are checked against the heads of the rings: written
// + lost is 0 for the second and the third, the count of the loop for the
// fourth. A measure whose numbers do not agree is a failed case.
case_of_the_cost :: proc "contextless" (load: ^Child, other: ^Child) {
	other_program: u64
	if other != nil {
		other_program = u64(other.program)
	}
	named_other := [1]op.Event_Rule{{kind = .Operation, program = other_program}}
	nothing := [1]op.Event_Rule{{kind = .Operation, flags = {.Match_Detail}, detail = u64(op.Operation.Machine_Stop)}}
	each := [1]op.Event_Rule{{kind = .Operation, flags = {.Match_Detail}, program = u64(load.program), detail = u64(op.Operation.Memory_Size)}}
	ran := measure_round(load, ROUND_MEASURE_NO_RULE, nil, &measures[0])
	// With no other program, the round does not run: a rule for every
	// program would not measure the same path.
	ran = other != nil && measure_round(load, ROUND_MEASURE_OTHER, named_other[:], &measures[1]) && ran
	ran = measure_round(load, ROUND_MEASURE_NOTHING, nothing[:], &measures[2]) && ran
	ran = measure_round(load, ROUND_MEASURE_EACH, each[:], &measures[3]) && ran
	other_agrees := measures[1].written + measures[1].lost == 0
	nothing_agrees := measures[2].written + measures[2].lost == 0
	each_agrees := measures[3].written + measures[3].lost == measures[3].count
	right := ran && other_agrees && nothing_agrees && each_agrees
	system.log("kernel_events: kernel entries in one second of the load child (its own count and time): no rule ", measures[0].rate, " (", measures[0].count, " operations in ", measures[0].nanoseconds, " ns); a rule that names another program ", measures[1].rate, " (", measures[1].count, " operations in ", measures[1].nanoseconds, " ns; ", measures[1].written, " records + ", measures[1].lost, " lost, of 0); a rule for every program that matches nothing ", measures[2].rate, " (", measures[2].count, " operations in ", measures[2].nanoseconds, " ns; ", measures[2].written, " records + ", measures[2].lost, " lost, of 0); a rule that accepts each of its operations ", measures[3].rate, " (", measures[3].count, " operations in ", measures[3].nanoseconds, " ns; ", measures[3].written, " records + ", measures[3].lost, " lost = ", measures[3].written + measures[3].lost, ", of ", measures[3].count, ")", right ? string(": as it must") : string(": WRONG"))
	case_end(10, right, measures[0].rate, ", ", measures[1].rate, ", ", measures[2].rate, ", ", measures[3].rate, right ? string(": as it must") : string(": WRONG"))

	// What every program does while this one sleeps 200 ms: shown, not
	// checked (no count of this program can check it).
	everything := [2]op.Event_Rule{{kind = .Operation}, {kind = .Lock_Wait}}
	tally: Tally
	if table_give(everything[:], RING_RECORDS) == .Ok {
		system.sleep(system.time() + 200)
		system.events_end(machine)
		rings_read(&tally)
		system.log("kernel_events: in 200 ms while this program sleeps, every program: ", tally.kinds[.Operation], " operations, the longest ", operation_name(tally.longest_operation), " in ", nanoseconds_of(tally.longest), " ns; ", tally.kinds[.Lock_Wait], " waits for a lock (shown, not checked)")
	}
}

interface_draw :: proc "contextless" (window: ^display.Window) {
	frame := interface.window_frame_begin(&drawing, window)
	interface.background(&frame, {0, 0, WIDTH, HEIGHT})
	content := interface.card(&frame, {8, 8, WIDTH - 16, HEIGHT - 16}, "KERNEL EVENTS", "the kernel records its own work by a table of rules, into one ring for each processor", graphics.COLOR_KERNEL)
	column := interface.column_of(content)
	for &item in cases {
		value := "not run yet"
		color: graphics.Color = graphics.COLOR_DIM
		if item.ran {
			value = string(item.value[:item.value_length])
			color = item.right ? graphics.COLOR_PROGRAM : graphics.COLOR_FAILED
		}
		interface.label_value_line(&frame, interface.column_take(&column, LINE), item.name, value, color, 380)
	}
	_ = interface.column_take(&column, LINE)
	line: [96]u8
	kinds := system.format(line[:], shown.kinds[.Operation], " operations, ", shown.kinds[.Switch], " switches, ", shown.kinds[.Fault], " faults, ", shown.kinds[.Lock_Wait], " waits for a lock")
	interface.label_value_line(&frame, interface.column_take(&column, LINE), "records read", kinds, graphics.COLOR_KERNEL, 380)
	longest_line: [96]u8
	longest := system.format(longest_line[:], operation_name(shown.longest_operation), ", ", nanoseconds_of(shown.longest), " ns")
	interface.label_value_line(&frame, interface.column_take(&column, LINE), "the longest operation", shown.longest == 0 ? string("none yet") : longest, graphics.COLOR_KERNEL, 380)
	lost_line: [64]u8
	interface.label_value_line(&frame, interface.column_take(&column, LINE), "records lost", system.format(lost_line[:], shown_lost), graphics.COLOR_KERNEL, 380)
	interface.window_frame_end(&drawing, &frame, window)
}

// The loaders of the load child: each one enters the kernel with one
// operation Memory_Size at a time while loaders_running is 1.
loaders_running: u32
load_memory: system.Handle

loader :: proc "c" (_: rawptr) -> ! {
	for intrinsics.atomic_load(&loaders_running) == 1 {
		for _ in 0 ..< 64 {
			system.call(.Memory_Size, u64(load_memory))
		}
	}
	system.thread_stop()
}

// The children.
child_role_run :: proc "contextless" (role: Role) -> ! {
	shared := shared_page()
	switch role {
	case .Parent:
		// Not a child: entry calls child_role_run only for another role.
	case .Load:
		status: system.Status
		load_memory, status = system.memory_create(1)
		if status != .Ok {
			system.stop(20)
		}
		round: u32
		loaders: [LOADERS_MOST]system.Thread
		loader_count: u32
		for {
			for intrinsics.atomic_load(&shared.go) == round {
				system.word_wait(&shared.go, round, system.time() + 100)
			}
			round = intrinsics.atomic_load(&shared.go)
			switch round {
			case ROUND_MEASURE_NO_RULE, ROUND_MEASURE_OTHER, ROUND_MEASURE_NOTHING, ROUND_MEASURE_EACH:
				// The measure: its own count and its own time. The loop
				// makes one kernel entry with one operation Memory_Size for
				// each count, and no other operation Memory_Size; the
				// loaders do not run.
				count: u64
				start := system.nanoseconds()
				for end := system.time() + MEASURE_TIME; system.time() < end; {
					for _ in 0 ..< 64 {
						system.call(.Memory_Size, u64(load_memory))
					}
					count += 64
				}
				intrinsics.atomic_store(&shared.measure_nanoseconds, system.nanoseconds() - start)
				intrinsics.atomic_store(&shared.measure_count, count)
			case ROUND_FIRST_USE_ALL, ROUND_FIRST_USE_NAMED:
				// One first use of a new page: a page fault that the kernel
				// serves, at the address that the child writes.
				page, created := system.memory_create(1)
				if created == .Ok {
					if address, mapped := system.memory_map(page); mapped == .Ok {
						intrinsics.volatile_store((^u64)(address), u64(round))
						intrinsics.atomic_store(&shared.first_use_address, u64(uintptr(address)))
						system.memory_unmap(address)
					}
					system.close(page)
				}
			case ROUND_LOADERS_START:
				// One loader for each processor, at most LOADERS_MOST.
				intrinsics.atomic_store(&loaders_running, 1)
				wanted := min(max(u32(system.thread_record().processors), 1), LOADERS_MOST)
				for _ in 0 ..< wanted {
					if thread, started := system.thread_start(loader, nil); started == .Ok {
						loaders[loader_count] = thread
						loader_count += 1
					}
				}
				intrinsics.atomic_store(&shared.loaders, loader_count)
			case ROUND_LOADERS_STOP:
				intrinsics.atomic_store(&loaders_running, 0)
				for thread in loaders[:loader_count] {
					system.thread_wait(thread)
				}
				loader_count = 0
			case:
				for _ in 0 ..< CALLS {
					system.call(.Memory_Size, u64(load_memory))
				}
				if round == ROUND_EXACT {
					// Each sleep leaves the processor; each wake is a
					// switch to this thread.
					for _ in 0 ..< SLEEPS {
						system.sleep(system.time() + 1)
					}
				}
			}
			intrinsics.atomic_store(&shared.done, round)
			system.word_wake(&shared.done)
		}
	case .Faulter:
		for intrinsics.atomic_load(&shared.go) == 0 {
			system.word_wait(&shared.go, 0, system.time() + 100)
		}
		_ = intrinsics.volatile_load((^u64)(uintptr(FAULT_ADDRESS)))
	}
	system.stop(30) // The child that faults does not come here: its fault stops it.
}

// entry runs the role that the context names, for a child; else it runs
// each case in order, writes one line for each and the summary, then keeps
// the window open until the program is stopped. The last case waits for
// the console to revoke its machine handle, in the scenario of the test.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	if role := role_of(ctx.values[VALUE_ROLE]); role != .Parent {
		child_role_run(role)
	}
	if !random.generator_from_context(&program_generator, ctx) {
		system.log("kernel_events: no random seed in the context")
		system.stop(1)
	}
	machine = ctx.handles[system.GRANT_MACHINE]
	window, ok := display.open(ctx, WIDTH, HEIGHT, "kernel_events")
	if !ok {
		system.stop(1)
	}
	drawing = interface.window_drawing_of(records_now[:], records_before[:], text_now[:], text_before[:])
	address, status := system.memory_map(ctx.handles[system.GRANT_IMAGE], {})
	if status != .Ok {
		system.log("kernel_events: no boot image")
		system.stop(1)
	}
	image = ([^]u8)(address)[:ctx.values[system.GRANT_VALUE_IMAGE_SIZE]]
	interface_draw(&window)

	// The rings: one of RING_RECORDS records for each processor, in one
	// contiguous memory object.
	processors := max(u64(system.thread_record().processors), 1)
	bytes := processors * (op.EVENT_RING_HEAD_BYTES + RING_RECORDS * size_of(op.Event_Record))
	rings_pages = (bytes + PAGE - 1) / PAGE
	rings_memory, status = system.memory_create(rings_pages, flags = {.Contiguous})
	if status != .Ok {
		system.log("kernel_events: memory_create of the rings failed: ", op.STATUS_NAMES[status])
		system.stop(1)
	}
	rings_base, status = system.memory_map(rings_memory)
	if status != .Ok {
		system.log("kernel_events: memory_map of the rings failed: ", op.STATUS_NAMES[status])
		system.stop(1)
	}

	cases_of_refusal()
	interface_draw(&window)
	// The load child asks the processor limit of this program, at most one
	// processor for each of its threads.
	load_amounts := LOAD_AMOUNTS
	own, _ := system.budget_read()
	load_amounts.processor = min(load_amounts.processor, own.processor)
	load, load_started := child_start(.Load, "the load child", load_amounts)
	if load_started {
		faulter, faulter_started := cases_of_counts(&window, &load)
		case_of_the_fault_address(&load)
		interface_draw(&window)
		case_of_the_ends_under_load(&load, &window)
		other: ^Child
		if faulter_started {
			other = &faulter
		}
		case_of_the_cost(&load, other)
		if faulter_started {
			child_end(&faulter, "the child that faults")
		}
		interface_draw(&window)
		case_of_the_revoked_right(&load)
		child_end(&load, "the load child")
	} else {
		system.log("kernel_events: the load child did not start: the cases 3 to 12 do not run")
	}

	right := 0
	for item in cases {
		if item.right {
			right += 1
		}
	}
	if right == len(cases) {
		system.log("kernel_events: ok, ", u64(len(cases)), " cases: each count of the rings was exact, each refusal came, and each child gave back every page and every thread")
	} else {
		system.log("kernel_events: failed: ", u64(len(cases) - right), " cases of ", u64(len(cases)))
	}
	for {
		interface_draw(&window)
		display.wait(&window, system.time() + 1000)
		interface.window_events(&drawing, &window)
	}
}
