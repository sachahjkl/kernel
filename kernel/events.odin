package kernel

import "base:intrinsics"
import op "contract:operation"

// Kernel events (docs/ARCHITECTURE.md, "Kernel events"). Four fixed event
// points in the kernel (an operation of a kernel entry, a switch of threads,
// a fault of a program, a wait for a lock of the kernel) and one event table
// of at most 16 rules that one program with the right Events gives
// (Events_Set). A kernel event that a rule accepts is one record in the
// event ring of the processor where it came, in a memory object of that
// program. The rules are data that the kernel tests, never code.
//
// The facts that keep an event point correct, each kept by the code named:
//
// 1. An event point with no rule of its kind reads one word of its own
//    processor record (observed_kinds) and branches: no call, no lock, no
//    other memory (event_observed).
// 2. event_record takes no lock, waits for nothing, calls nothing that
//    answers processor_sync, and writes only the processor record of its own
//    processor, the counts of the rules (atomic additions), and the event
//    ring of its own processor through the direct map. So it can run with
//    any lock held, in the middle of any path, and it never faults: the
//    frames of the ring are frames of a contiguous memory object that the
//    kernel holds a reference to, and the direct map always maps them.
// 3. The event table, the ring fields of each processor record, and the
//    sampling counts change only under the control lock, and only while the
//    observed kinds of every processor are 0 and every processor answered a
//    processor_sync since they became 0 (event_table_end, event_table_give).
//    A processor answers processor_sync only at a kernel entry, in its idle
//    wait, and while it waits for a lock; none of these is inside
//    event_record. So a processor that read its observed kinds as not 0
//    ends its use of the table before it answers, and a processor that
//    answered reads its observed kinds as 0 after: the store of 0 comes
//    before the store of `pending` that it saw (both are atomic stores of
//    one processor, which x86-64 keeps in order, and its load of `pending`
//    comes before its load of the word).
// 4. The kernel drops its reference to the memory object of the rings only
//    after that synchronization: no processor writes there after the free.
// 5. The kernel writes a record only at an index below the capacity that it
//    keeps itself (event_capacity, a power of two), and reads one word of the
//    ring: `read`, memory of the program, any value. A false value can only
//    make the ring look full (the record is lost and counted) or let the
//    kernel write over records of this program that it did not read.

// The bits of observed_kinds: bit n for the Event_Kind n.
OBSERVED_OPERATION :: u32(1) << u32(op.Event_Kind.Operation)
OBSERVED_SWITCH :: u32(1) << u32(op.Event_Kind.Switch)
OBSERVED_FAULT :: u32(1) << u32(op.Event_Kind.Fault)
OBSERVED_LOCK_WAIT :: u32(1) << u32(op.Event_Kind.Lock_Wait)

// One rule as the kernel tests it: the program as its slot and its serial,
// the least duration in cycles of the cycle counter.
Event_Rule_In_Kernel :: struct {
	kind:           op.Event_Kind,
	match_detail:   bool,
	program:        u32, // 0: every program and the kernel.
	program_serial: u32,
	detail:         u64,
	least_cycles:   u64,
	one_in:         u64, // 0 and 1: each event.
}

// The event table of the machine. owner 0: no table. Fact 3 above.
Event_Table :: struct {
	rule_count:   u32,
	rules:        [op.EVENT_RULE_CAPACITY]Event_Rule_In_Kernel,
	observed:     u32, // The bits of the kinds that have a rule.
	owner:        u32, // The program that gave the table.
	owner_serial: u32,
	region:       u32, // The memory object of the rings: the kernel holds one reference to it.
	records:      u64, // The capacity of each ring: a power of two.
	ring_bytes:   u64,
}

event_table: Event_Table

// The count of the events that passed the other tests of each rule, for
// "one in N": one line for each rule, so that two rules do not share a
// line. Several processors add to the count of one rule with an atomic
// addition: exact across processors, at the cost of a line that moves
// between them, and only for a rule with "one in N".
Event_Rule_Count :: struct #align (64) {
	passed: u64,
}

event_rule_counts: [op.EVENT_RULE_CAPACITY]Event_Rule_Count

// event_observed says if the event table has a rule of a kind: the one test
// of an event point when no table exists. The word is written by the
// control path (event_table_give, event_table_end) and read here with no
// lock: the load is an acquire, so the fields of the table that the store
// published are seen after it.
event_observed :: #force_inline proc "contextless" (cpu: ^Processor, bit: u32) -> bool {
	return intrinsics.atomic_load_explicit(&cpu.observed_kinds, .Acquire) & bit != 0
}

// event_record writes one kernel event of this processor into its event
// ring, when a rule accepts it. It reads the observed kinds again itself:
// a caller that read them before a wait for a lock (where the processor
// answers processor_sync) has an old value. Facts 2, 3 and 5 above.
event_record :: proc "contextless" (cpu: ^Processor, kind: op.Event_Kind, program: u32, thread_number: u32, detail: u64, value_0: u64, value_1: u64) {
	if !event_observed(cpu, u32(1) << u32(kind)) {
		return
	}
	if !event_accepted(kind, program, detail, value_0) {
		return
	}
	ring := cpu.event_ring
	if cpu.event_written - cpu.event_read_seen >= cpu.event_capacity {
		// The ring looks full with the count read last time: read the count
		// of the program again, once. A value above the count written makes
		// the difference wrap to a large number: full.
		cpu.event_read_seen = intrinsics.atomic_load_explicit(&ring.read, .Relaxed)
		if cpu.event_written - cpu.event_read_seen >= cpu.event_capacity {
			cpu.event_lost += 1
			intrinsics.atomic_store_explicit(&ring.lost, cpu.event_lost, .Release)
			return
		}
	}
	serial: u64
	if program != 0 {
		serial = u64(intrinsics.atomic_load(&programs[program].serial))
	}
	// The index is below the capacity that the kernel keeps: the record is
	// inside the ring whatever the program wrote.
	cpu.event_records[cpu.event_written & (cpu.event_capacity - 1)] = {
		time           = cycles_now(),
		kind           = kind,
		processor      = cpu.index,
		program        = program,
		thread         = program == 0 ? 0 : thread_number,
		program_serial = serial,
		detail         = detail,
		value_0        = value_0,
		value_1        = value_1,
	}
	cpu.event_written += 1
	// The record is written before the count that publishes it.
	intrinsics.atomic_store_explicit(&ring.written, cpu.event_written, .Release)
}

// event_accepted tests the rules of the table: at most EVENT_RULE_CAPACITY
// tests of a few fields, with no lock. Each rule that passes its other tests
// counts the event for its "one in N", also when another rule accepted the
// event already, so that the count of a rule does not depend on the others.
// value_0 is the duration for the kinds with a least duration; the other
// kinds have a least duration of 0, which each value passes.
@(private = "file")
event_accepted :: proc "contextless" (kind: op.Event_Kind, program: u32, detail: u64, value_0: u64) -> bool {
	accepted := false
	for &rule, rule_index in event_table.rules[:event_table.rule_count] {
		if rule.kind != kind || rule.match_detail && rule.detail != detail || value_0 < rule.least_cycles {
			continue
		}
		// The slot of a program that ended can serve a new program: the
		// serial names the program of the rule.
		if rule.program != 0 && (rule.program != program || intrinsics.atomic_load(&programs[program].serial) != rule.program_serial) {
			continue
		}
		if rule.one_in > 1 {
			passed := intrinsics.atomic_add(&event_rule_counts[rule_index].passed, 1) + 1
			if passed % rule.one_in != 0 {
				continue
			}
		}
		accepted = true
	}
	return accepted
}

// event_current gives the program and the thread number of the thread that
// a processor runs now, for an event point that has no thread at hand. Only
// this processor writes `current`, and the thread of `current` keeps its
// program and its number while it is current: thread_finish runs after the
// processor left it.
event_current :: #force_inline proc "contextless" (cpu: ^Processor) -> (program: u32, thread_number: u32) {
	if cpu.current == 0 {
		return 0, 0
	}
	thread := &threads[cpu.current]
	return thread.program, thread.number
}

// events_set is the operation Events_Set. The caller holds the program lock
// of the caller (execute); the table changes under the control lock.
events_set :: proc "contextless" (program_index: u32, v: [7]u64, results: ^[7]u64) -> op.Status {
	program := &programs[program_index]
	_ = handle_find(program, v[0], .Machine, {.Events}) or_return
	if need_control() {
		return STATUS_RETRY
	}
	owned := event_table.owner == program_index && event_table.owner_serial == program.serial
	if v[1] == 0 {
		if !owned {
			return .Bad_State // The caller has no table to take away.
		}
		event_table_end()
		return .Ok
	}
	memory := handle_find(program, v[1], .Memory, {.Write}) or_return
	if v[3] > op.EVENT_RULE_CAPACITY {
		return .No_Slot
	}
	records := v[4]
	if v[3] == 0 || records < op.EVENT_RING_RECORDS_LEAST || records > op.EVENT_RING_RECORDS_MOST || records & (records - 1) != 0 {
		return .Bad_Operation
	}
	// The rings are written through the direct map, with no fault: frames
	// that the memory object has from its creation and that do not move,
	// and frames of the page frame table, not the registers of a device.
	region := &regions[memory.object]
	if !region.contiguous || region.device {
		return .Bad_Operation
	}
	ring_bytes := op.EVENT_RING_HEAD_BYTES + records * size_of(op.Event_Record)
	if region.page_count * PAGE_SIZE / ring_bytes < u64(processor_count) {
		return .Bad_Operation // One ring for each processor does not fit.
	}
	if !user_range(program, v[2], v[3] * size_of(op.Event_Rule), false) {
		return .Bad_Address
	}
	// One copy of the rules of the caller: each later test reads the copy,
	// never the memory of the program again.
	given: [op.EVENT_RULE_CAPACITY]op.Event_Rule
	user_copy(&given, rawptr(uintptr(v[2])), v[3] * size_of(op.Event_Rule))
	table := Event_Table {
		rule_count = u32(v[3]),
		records    = records,
		ring_bytes = ring_bytes,
	}
	for rule, rule_index in given[:v[3]] {
		table.rules[rule_index] = event_rule_check(program, rule) or_return
		table.observed |= u32(1) << u32(rule.kind)
	}
	if event_table.owner != 0 && !owned {
		return .Bad_State // Another program observes the kernel: one table at a time.
	}
	event_table_end()
	event_table_give(&table, memory.object, program_index)
	results[0] = ring_bytes
	results[1] = u64(processor_count)
	return .Ok
}

// event_rule_check checks one rule of the caller and gives it as the kernel
// tests it. The program of a rule is a handle of the caller with Read.
@(private = "file")
event_rule_check :: proc "contextless" (program: ^Program, rule: op.Event_Rule) -> (kept: Event_Rule_In_Kernel, status: op.Status) {
	if rule.kind == .None || rule.kind > max(op.Event_Kind) || rule.flags - {.Match_Detail} != {} || rule.reserved[0] | rule.reserved[1] | rule.reserved[2] != 0 {
		return {}, .Bad_Operation
	}
	if rule.least_nanoseconds > op.EVENT_LEAST_NANOSECONDS_MOST || rule.one_in > op.EVENT_ONE_IN_MOST {
		return {}, .Bad_Operation
	}
	switch rule.kind {
	case .None:
		return {}, .Bad_Operation
	case .Switch:
		if .Match_Detail in rule.flags || rule.least_nanoseconds != 0 {
			return {}, .Bad_Operation
		}
	case .Fault:
		if rule.least_nanoseconds != 0 {
			return {}, .Bad_Operation
		}
	case .Operation, .Lock_Wait:
	}
	kept = {
		kind         = rule.kind,
		match_detail = .Match_Detail in rule.flags,
		detail       = rule.detail,
		// At most 10^9 ns times a frequency below 1.8 * 10^10: no overflow.
		least_cycles = rule.least_nanoseconds * cycle_frequency / 1_000_000_000,
		one_in       = rule.one_in,
	}
	if rule.program != 0 {
		slot := handle_find(program, rule.program, .Program, {.Read}) or_return
		kept.program = slot.object
		kept.program_serial = intrinsics.atomic_load(&programs[slot.object].serial)
	}
	return kept, .Ok
}

// event_table_give makes a checked table the event table of the machine.
// The caller holds the control lock and the program lock of the owner, and
// no table exists (event_table_end ran): the observed kinds of each
// processor are 0, and each processor answered a processor_sync since. So
// no processor reads the table or its own ring fields while this writes
// them (fact 3). The handle of the caller names the memory object, so its
// count of references is not 0 when the kernel adds its own.
@(private = "file")
event_table_give :: proc "contextless" (table: ^Event_Table, region_index: u32, owner: u32) {
	intrinsics.atomic_add(&regions[region_index].references, 1)
	region := &regions[region_index]
	event_table = table^
	event_table.owner = owner
	event_table.owner_serial = programs[owner].serial
	event_table.region = region_index
	for &count in event_rule_counts {
		count.passed = 0
	}
	for cpu in processors[:processor_count] {
		ring := direct(region.physical + u64(cpu.index) * table.ring_bytes, op.Event_Ring)
		// The head of the ring: the counts start at 0 in the memory of the
		// program too, whatever it held.
		intrinsics.atomic_store(&ring.written, 0)
		intrinsics.atomic_store(&ring.lost, 0)
		intrinsics.atomic_store(&ring.read, 0)
		intrinsics.atomic_store(&ring.records, table.records)
		intrinsics.atomic_store(&ring.processor, u64(cpu.index))
		cpu.event_ring = ring
		cpu.event_records = ([^]op.Event_Record)(uintptr(ring) + op.EVENT_RING_HEAD_BYTES)
		cpu.event_capacity = table.records
		cpu.event_written = 0
		cpu.event_read_seen = 0
		cpu.event_lost = 0
	}
	// Last: the word that lets the event points read what is above. A
	// processor that reads it with its acquire load sees the table.
	for cpu in processors[:processor_count] {
		intrinsics.atomic_store(&cpu.observed_kinds, table.observed)
	}
	log_in("events", .Info, "kernel: program ", program_name(&programs[owner]), " gave the event table: ", u64(table.rule_count), " rules, ", table.records, " records in the ring of each of ", u64(processor_count), " processors")
}

// event_table_end takes the event table away, if one exists, and releases
// the memory object of its rings. The caller holds the control lock. When
// it returns, no processor reads the table and no processor writes in the
// memory object (facts 3 and 4).
event_table_end :: proc "contextless" () {
	if event_table.owner == 0 {
		return
	}
	for cpu in processors[:processor_count] {
		intrinsics.atomic_store(&cpu.observed_kinds, 0)
	}
	// This processor is in no event point here. Each other one is either in
	// one, which it ends before its next answer, or it reads 0 after its
	// answer.
	processor_sync(all_other_processors())
	written, lost: u64
	for cpu in processors[:processor_count] {
		written += cpu.event_written
		lost += cpu.event_lost
		cpu.event_ring = nil
		cpu.event_records = nil
		cpu.event_capacity = 0
		cpu.event_written = 0
		cpu.event_read_seen = 0
		cpu.event_lost = 0
	}
	owner := event_table.owner
	region := event_table.region
	event_table = {}
	log_in("events", .Info, "kernel: the event table of program ", program_name(&programs[owner]), " ended: ", written, " records written, ", lost, " lost")
	region_release(region)
}

// event_table_end_for ends the event table when its owner is the program
// that ends. The caller holds the control lock and no program lock: the
// program stopped, and its cleanup runs (program_cleanup).
event_table_end_for :: proc "contextless" (program_index: u32) {
	if event_table.owner == program_index && event_table.owner_serial == programs[program_index].serial {
		event_table_end()
	}
}

// performance_counters_log writes one line at boot: what the processor
// says of its performance counters. The kernel does not program them; the
// event records carry the cycle counter only (docs/ARCHITECTURE.md, "Kernel
// events", the processor counters).
performance_counters_log :: proc "contextless" () {
	highest, vendor_b, vendor_c, vendor_d := intrinsics.x86_cpuid(0, 0)
	// "GenuineIntel" and "AuthenticAMD", as the three registers give them.
	intel := vendor_b == 0x756E_6547 && vendor_d == 0x4965_6E69 && vendor_c == 0x6C65_746E
	amd := vendor_b == 0x6874_7541 && vendor_d == 0x6974_6E65 && vendor_c == 0x444D_4163
	_, _, features, _ := intrinsics.x86_cpuid(1, 0)
	guest := features & (1 << 31) != 0 // A hypervisor runs this machine.
	where_text := guest ? string(" (a guest of a hypervisor)") : string("")
	if intel && highest >= 0xA {
		monitoring, _, _, fixed := intrinsics.x86_cpuid(0xA, 0)
		version := u64(monitoring & 0xFF)
		if version != 0 {
			log("kernel: performance counters", where_text, ": Intel architectural monitoring version ", version, ", ", u64(monitoring >> 8 & 0xFF), " general counters of ", u64(monitoring >> 16 & 0xFF), " bits, ", version >= 2 ? u64(fixed & 0x1F) : u64(0), " fixed counters; not used: the event records carry the cycle counter only")
			return
		}
	}
	if amd {
		extended, _, _, _ := intrinsics.x86_cpuid(0x8000_0000, 0)
		core_extension := false
		if extended >= 0x8000_0001 {
			_, _, extended_features, _ := intrinsics.x86_cpuid(0x8000_0001, 0)
			core_extension = extended_features & (1 << 23) != 0
		}
		version_2 := false
		counters: u64
		if extended >= 0x8000_0022 {
			monitoring, counts, _, _ := intrinsics.x86_cpuid(0x8000_0022, 0)
			version_2 = monitoring & 1 != 0
			counters = u64(counts & 0xF)
		}
		if core_extension || version_2 {
			log("kernel: performance counters", where_text, ": AMD, core counter extension ", core_extension ? string("yes") : string("no"), ", monitoring version 2 ", version_2 ? string("yes") : string("no"), ", ", counters, " core counters in CPUID 0x80000022; not used: the event records carry the cycle counter only")
			return
		}
	}
	log("kernel: performance counters", where_text, ": none that CPUID shows; the event records carry the cycle counter only")
}
