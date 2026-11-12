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
//   9. A child that stops with its own table: the kernel forgets the table.
//  10. The cost: kernel entries in one second with no rule, with one rule
//      that matches nothing, and with a rule on every kernel entry.
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
	Owner   = 3, // Gives its own event table, then waits until it is stopped.
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
OWNER_RECORDS :: 16
FAULT_ADDRESS :: u64(0x1000) // Below the module of the program: no mapping.
MEASURE_TIME :: 300 // Milliseconds of one measure.
CHILD_PAGES :: 256
CHILD_THREADS :: 2
STOP_BY_PARENT :: 9

// The rounds of the load child.
ROUND_EXACT :: 1
ROUND_ONE_IN :: 2
ROUND_FULL :: 3
ROUND_TAKEN_AWAY :: 4

// The page that the parent shares with each child, at SHARED_ADDRESS in the
// child.
SHARED_ADDRESS :: fixed_addresses.OWN_CHOICE_START + 0x0000_0400_0000_0000
Shared_Page :: struct {
	go:           u32, // The round that the parent asks.
	done:         u32, // The last round that the load child ran.
	installed:    u32, // The owner child: 1 when its call of Events_Set returned.
	owner_status: u32, // Its status.
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

cases := [10]Case {
	{name = "no grant"},
	{name = "a seventeenth rule"},
	{name = "1000 operations of one program"},
	{name = "a thread that sleeps"},
	{name = "a child that faults once"},
	{name = "one in 10"},
	{name = "a full ring"},
	{name = "the table taken away"},
	{name = "a program that stops with its table"},
	{name = "kernel entries in one second"},
}

// What the records of the rings say.
Tally :: struct {
	kinds:             [op.Event_Kind]u64,
	faults_stopped:    u64, // Fault records whose program stopped.
	fault_detail:      u64,
	fault_address:     u64,
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
ring_bytes: u64
ring_records: u64 // The records of each ring in the table given last.
processor_count: u64

shown: Tally // The records of all the cases, for the window.
shown_lost: u64
entry_rates: [3]u64 // No rule, one rule that matches nothing, a rule on each operation.

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

child_start :: proc "contextless" (role: Role, name: string, with_events: bool) -> (child: Child, ok: bool) {
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
	grants: [op.CONTEXT_HANDLES]system.Grant
	if with_events {
		grants[system.GRANT_MACHINE] = {machine, {.Events}}
	}
	values: [op.CONTEXT_VALUES]u64
	values[VALUE_ROLE] = ROLE_TAG | u64(role)
	error: module.Load_Error
	child.program, status = system.program_start(system.image_find(image, "kernel_events"), "kernel_events child", grants, random.values_with_seed(&program_generator, values), {pages = CHILD_PAGES, programs = 1, threads = CHILD_THREADS, processor = 500_000, log_records = 20}, mappings[:], nil, {image = image}, &error)
	if status != .Ok {
		buffer: [512]u8
		lines := system.Writer{buffer = buffer[:]}
		system.load_error_text(&lines, &error)
		system.log("kernel_events: ", name, ": program_start failed: ", op.STATUS_NAMES[status], "; the load: ", system.written(&lines))
		system.memory_unmap(address)
		system.close(child.shared_memory)
		return
	}
	return child, true
}

// child_stopped waits until a child stopped, at most a number of
// milliseconds.
child_stopped :: proc "contextless" (child: ^Child, milliseconds: u64) -> bool {
	for deadline := system.time() + milliseconds; system.time() < deadline; {
		results, status := system.call(.Program_State, u64(child.program))
		if status != .Ok || op.Program_State(results[0]) == .Stopped {
			return status == .Ok
		}
		system.sleep(system.time() + 10)
	}
	return false
}

// child_end stops a child, closes it, and says if its budget came back
// whole within one second: each page, each thread and its program.
child_end :: proc "contextless" (child: ^Child, name: string) -> (back: bool) {
	system.call(.Program_Stop, u64(child.program), STOP_BY_PARENT)
	child_stopped(child, 5000)
	system.close(child.program)
	for deadline := system.time() + 1000; !back && system.time() < deadline; {
		after, _ := system.budget_read()
		back = after.pages == child.before.pages && after.threads == child.before.threads && after.programs == child.before.programs
		if !back {
			system.sleep(system.time() + 10)
		}
	}
	if !back {
		system.log("kernel_events: ", name, ": the budget of this program did not get back every page, thread and program of the child in 1 s")
	}
	system.memory_unmap(child.shared)
	system.close(child.shared_memory)
	return back
}

// round_run asks the load child to run one round and waits for its end.
round_run :: proc "contextless" (load: ^Child, round: u32) -> bool {
	intrinsics.atomic_store(&load.shared.go, round)
	system.word_wake(&load.shared.go)
	deadline := system.time() + 5000
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
	system.log("kernel_events: the load child did not end the round ", u64(round), " in 5 s")
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

// The cases 3 to 8, with the load child and the child that faults.
cases_of_counts :: proc "contextless" (window: ^display.Window) {
	load, load_started := child_start(.Load, "the load child", false)
	faulter, faulter_started := child_start(.Faulter, "the child that faults", false)
	if !load_started || !faulter_started {
		system.log("kernel_events: the children did not start")
		return
	}
	memory_size := u64(op.Operation.Memory_Size)

	// 3, 4 and 5. One table: the operations Memory_Size of the load child,
	// its switches, the faults of the other child, and every wait for a
	// lock of the kernel (shown, not checked).
	exact := [4]op.Event_Rule {
		{kind = .Operation, flags = {.Match_Detail}, program = u64(load.program), detail = memory_size},
		{kind = .Switch, program = u64(load.program)},
		{kind = .Fault, program = u64(faulter.program)},
		{kind = .Lock_Wait},
	}
	tally: Tally
	given := table_give(exact[:], RING_RECORDS)
	intrinsics.atomic_store(&faulter.shared.go, 1)
	system.word_wake(&faulter.shared.go)
	ran := given == .Ok && round_run(&load, ROUND_EXACT)
	faulted := child_stopped(&faulter, 5000)
	_, lost, _ := heads()
	rings_read(&tally)
	right := ran && tally.kinds[.Operation] == CALLS && lost == 0
	system.log("kernel_events: 1000 operations Memory_Size of one program: ", tally.kinds[.Operation], " records, ", lost, " lost", right ? string(": as it must") : string(": WRONG"))
	case_end(2, right, tally.kinds[.Operation], " records, ", lost, " lost", right ? string(": as it must") : string(": WRONG"))
	right = ran && tally.kinds[.Switch] >= SLEEPS
	system.log("kernel_events: a thread that sleeps 20 times: ", tally.kinds[.Switch], " switches to it", right ? string(": as it must") : string(": WRONG"))
	case_end(3, right, tally.kinds[.Switch], " switches to it, at least 20", right ? string(": as it must") : string(": WRONG"))
	code, _ := system.call(.Program_State, u64(faulter.program))
	right = faulted && tally.faults_stopped == 1 && tally.fault_detail == 14 && tally.fault_address == FAULT_ADDRESS
	system.log("kernel_events: a child that faults once: ", tally.faults_stopped, " record of a fault that stopped it, vector ", tally.fault_detail, ", address ", system.Hex(tally.fault_address), ", stop code ", system.Hex(code[1]), right ? string(": as it must") : string(": WRONG"))
	case_end(4, right, tally.faults_stopped, " record, vector ", tally.fault_detail, right ? string(": as it must") : string(": WRONG"))
	child_end(&faulter, "the child that faults")
	interface_draw(window)

	// 6. One in 10.
	one_in := [1]op.Event_Rule{{kind = .Operation, flags = {.Match_Detail}, program = u64(load.program), detail = memory_size, one_in = ONE_IN}}
	tally = {}
	ran = table_give(one_in[:], RING_RECORDS) == .Ok && round_run(&load, ROUND_ONE_IN)
	rings_read(&tally)
	right = ran && tally.kinds[.Operation] == CALLS / ONE_IN
	system.log("kernel_events: one in 10: ", tally.kinds[.Operation], " records of 1000 operations", right ? string(": as it must") : string(": WRONG"))
	case_end(5, right, tally.kinds[.Operation], " records of 1000", right ? string(": as it must") : string(": WRONG"))
	interface_draw(window)

	// 7. A full ring: this program reads nothing until the end of the round.
	tally = {}
	ran = table_give(exact[:1], FULL_RING_RECORDS) == .Ok && round_run(&load, ROUND_FULL)
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
	ran = ended == .Ok && round_run(&load, ROUND_TAKEN_AWAY)
	written_after, lost_after, _ := heads()
	second := system.events_end(machine)
	right = ran && written_after == written_before && lost_after == lost_before && second == .Bad_State
	system.log("kernel_events: the table taken away: ", written_after - written_before, " records after it; a second take gave ", op.STATUS_NAMES[second], right ? string(": as it must") : string(": WRONG"))
	case_end(7, right, written_after - written_before, " records after it", right ? string(": as it must") : string(": WRONG"))
	child_end(&load, "the load child")
	interface_draw(window)
}

// Case 9: a child gives its own table and stops with it.
case_of_the_owner :: proc "contextless" () {
	owner, started := child_start(.Owner, "the child that owns a table", true)
	if !started {
		case_end(8, false, string("WRONG: the child did not start"))
		return
	}
	for deadline := system.time() + 5000; intrinsics.atomic_load(&owner.shared.installed) == 0 && system.time() < deadline; {
		system.word_wait(&owner.shared.installed, 0, system.time() + 100)
	}
	owner_status := system.Status(intrinsics.atomic_load(&owner.shared.owner_status))
	rules := [1]op.Event_Rule{{kind = .Lock_Wait}}
	// One table at a time: the table of the child is not replaced.
	while_it_runs := table_give(rules[:], RING_RECORDS)
	back := child_end(&owner, "the child that owns a table")
	// The kernel forgot the table of the child when it stopped.
	after := table_give(rules[:], RING_RECORDS)
	if after == .Ok {
		system.events_end(machine)
	}
	right := owner_status == .Ok && while_it_runs == .Bad_State && after == .Ok && back
	system.log("kernel_events: a program that stops with its table: the child gave it (", op.STATUS_NAMES[owner_status], "); this program while it ran: ", op.STATUS_NAMES[while_it_runs], "; after its stop: ", op.STATUS_NAMES[after], right ? string(": as it must") : string(": WRONG"))
	case_end(8, right, right ? string("forgotten at its stop: as it must") : string("WRONG: see the log"))
}

// The measure: kernel entries in one second, each one operation Memory_Size
// of this program, as the lockers of the program locks do.
entries_measure :: proc "contextless" (memory: system.Handle) -> u64 {
	count: u64
	start := system.nanoseconds()
	for end := system.time() + MEASURE_TIME; system.time() < end; {
		for _ in 0 ..< 64 {
			system.call(.Memory_Size, u64(memory))
		}
		count += 64
	}
	elapsed := max(system.nanoseconds() - start, 1)
	return count * 1_000_000_000 / elapsed
}

// The thread that empties the rings while a rule records each operation:
// it moves the count read of each ring to its count written, each
// millisecond, as an observer does.
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

case_of_the_cost :: proc "contextless" () {
	memory, status := system.memory_create(1)
	if status != .Ok {
		case_end(9, false, string("WRONG: no memory"))
		return
	}
	defer system.close(memory)
	entry_rates[0] = entries_measure(memory)
	nothing := [1]op.Event_Rule{{kind = .Operation, flags = {.Match_Detail}, detail = u64(op.Operation.Machine_Stop)}}
	given_nothing := table_give(nothing[:], RING_RECORDS)
	entry_rates[1] = entries_measure(memory)
	every := [1]op.Event_Rule{{kind = .Operation}}
	given_every := table_give(every[:], RING_RECORDS)
	intrinsics.atomic_store(&drain_running, 1)
	drainer, drainer_status := system.thread_start(drain_thread, nil)
	entry_rates[2] = entries_measure(memory)
	intrinsics.atomic_store(&drain_running, 0)
	if drainer_status == .Ok {
		system.thread_wait(drainer)
	}
	written, lost, _ := heads()
	system.events_end(machine)
	right := given_nothing == .Ok && given_every == .Ok && drainer_status == .Ok && entry_rates[0] != 0 && entry_rates[1] != 0 && entry_rates[2] != 0
	system.log("kernel_events: kernel entries in one second, one program: no rule ", entry_rates[0], ", one rule that matches nothing ", entry_rates[1], ", a rule on every kernel entry ", entry_rates[2], " (", written, " records, ", lost, " lost)")
	case_end(9, right, entry_rates[0], ", ", entry_rates[1], ", ", entry_rates[2])

	// The longest operation of the machine in 200 ms, for the window.
	tally: Tally
	if table_give(every[:], RING_RECORDS) == .Ok {
		system.sleep(system.time() + 200)
		system.events_end(machine)
		rings_read(&tally)
		system.log("kernel_events: the longest operation of the machine in 200 ms: ", operation_name(tally.longest_operation), ", ", nanoseconds_of(tally.longest), " ns, of ", tally.kinds[.Operation], " operations")
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

// The children.
child_role_run :: proc "contextless" (role: Role, ctx: ^system.Context) -> ! {
	shared := shared_page()
	switch role {
	case .Parent:
		// Not a child: entry calls child_role_run only for another role.
	case .Load:
		memory, status := system.memory_create(1)
		if status != .Ok {
			system.stop(20)
		}
		round: u32
		for {
			for intrinsics.atomic_load(&shared.go) == round {
				system.word_wait(&shared.go, round, system.time() + 100)
			}
			round = intrinsics.atomic_load(&shared.go)
			for _ in 0 ..< CALLS {
				system.call(.Memory_Size, u64(memory))
			}
			if round == ROUND_EXACT {
				// Each sleep leaves the processor; each wake is a switch to
				// this thread.
				for _ in 0 ..< SLEEPS {
					system.sleep(system.time() + 1)
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
	case .Owner:
		processors := max(u64(system.thread_record().processors), 1)
		bytes := processors * (op.EVENT_RING_HEAD_BYTES + OWNER_RECORDS * size_of(op.Event_Record))
		memory, status := system.memory_create((bytes + PAGE - 1) / PAGE, flags = {.Contiguous})
		if status == .Ok {
			rules := [1]op.Event_Rule{{kind = .Operation}}
			_, _, status = system.events_set(ctx.handles[system.GRANT_MACHINE], memory, rules[:], OWNER_RECORDS)
		}
		intrinsics.atomic_store(&shared.owner_status, u32(status))
		intrinsics.atomic_store(&shared.installed, 1)
		system.word_wake(&shared.installed)
		for {
			system.sleep(system.time() + 1000)
		}
	}
	system.stop(30) // The child that faults does not come here: its fault stops it.
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	if role := role_of(ctx.values[VALUE_ROLE]); role != .Parent {
		child_role_run(role, ctx)
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
	rings_memory, status = system.memory_create((bytes + PAGE - 1) / PAGE, flags = {.Contiguous})
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
	cases_of_counts(&window)
	case_of_the_owner()
	interface_draw(&window)
	case_of_the_cost()

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
