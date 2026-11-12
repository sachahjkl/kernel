package monitor

import "base:intrinsics"
import "contract:errors"
import "contract:isolated"
import op "contract:operation"
import "support:system"

// The monitor is also a service: its exports give what its window shows, as
// tables of records, not text. The console calls them through a
// connection, and the host through the remote service.
//
// The facts are the facts of the machine: each program and the counts of
// the kernel. The monitor reads them with its grant, the machine with the
// right Inspect, and gives them only to a caller that acts for the principal
// (a program sees no other program).

// One row for each program that runs: programs().
Program :: struct {
	slot:    i64, // The place of the program in the kernel.
	name:    [32]u8,
	state:   [8]u8, // created, ready, waiting or stopped.
	pages:   i64, // The mapped pages that have a page frame.
	mapped:  i64, // The mapped pages.
	handles: i64,
	threads: i64,
	time:    i64, // Milliseconds of processor time.
	entries: i64, // Kernel entries.
	started: i64, // Microseconds after the start of the machine.
}

// The name of one count: a row of the table of counts_named().
Count_Name :: struct {
	name: [24]u8,
}

// One row for each count of the machine: counts().
Count :: struct {
	name:  [24]u8,
	value: i64,
	unit:  [16]u8,
}

// What the monitor did as a service: served().
Served :: struct {
	calls:    i64, // The calls that it executed.
	callers:  i64, // The connections that it has now.
	pictures: i64, // The pictures of its window.
}

ERROR_ACTS_FOR_PRINCIPAL :: -1
ERROR_REFUSED :: -2
ERROR_ABSENT :: -3

@(rodata)
state_names := [op.Program_State]string {
	.None    = "",
	.Created = "created",
	.Ready   = "ready",
	.Waiting = "waiting",
	.Stopped = "stopped",
}

machine: system.Handle
service: system.Service
pictures: u64

// acts_for_principal says if the caller of the export that runs acts for the principal.
// A call of the monitor itself has no caller: it acts for the principal.
@(private = "file")
acts_for_principal :: proc "contextless" () -> bool {
	caller := system.service_caller()
	return caller == nil || caller.grant & isolated.CALLER_ACTS_FOR_PRINCIPAL != 0
}

// programs gives one row for each program that runs, from the reports of the kernel: its slot, its name, its state, its pages with a frame and its mapped pages, its handles, threads, processor time in milliseconds, kernel entries, and the time of its start in microseconds. The result is the count of rows, or a negative number with an error record. The error kinds: No_Grant (-1, the caller does not act for the principal); Refused (-2, the kernel refused a report to the monitor, with its status).
@(export, link_name = "programs")
programs :: proc "c" (result: ^[]Program, error: ^errors.Error_Record) -> i64 {
	if !acts_for_principal() {
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .No_Grant, .Acts_For_Principal)
	}
	report: op.System_Report
	if _, status := system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.System), 0, u64(uintptr(&report)), size_of(report)); status != .Ok {
		return errors.fail(error, ERROR_REFUSED, .Refused, .None, 0, 0, 0, i64(status))
	}
	total := 0
	for slot in 1 ..< report.program_slots {
		program: op.Program_Report
		if _, status := system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.Program), slot, u64(uintptr(&program)), size_of(program)); status != .Ok || program.state == .None {
			continue
		}
		if total < len(result^) {
			row := &result[total]
			row^ = {
				slot    = i64(slot),
				pages   = i64(program.present_pages),
				mapped  = i64(program.mapped_pages),
				handles = i64(program.handle_count),
				threads = i64(program.thread_count),
				time    = i64(program.run_time),
				entries = i64(program.entries),
				started = i64(program.start_time),
			}
			copy(row.name[:len(row.name) - 1], system.name_of(program.name[:]))
			if program.state <= max(op.Program_State) {
				copy(row.state[:], state_names[program.state])
			}
		}
		total += 1
	}
	return i64(total)
}

// counts gives one row for each count of the machine that the kernel reports: the time, the pages, the free pages, the reserved pages, the memory objects, the programs, the processors, the kernel entries, the interrupts, the page faults of a first use, and the takes and the waits of the locks of the kernel, the scheduling strategy (its number, and its name as the unit) and its changes. The result is the count of rows, or a negative number with an error record. The error kinds: No_Grant (-1, the caller does not act for the principal); Refused (-2, the kernel refused the report to the monitor, with its status).
@(export, link_name = "counts")
counts :: proc "c" (result: ^[]Count, error: ^errors.Error_Record) -> i64 {
	if !acts_for_principal() {
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .No_Grant, .Acts_For_Principal)
	}
	rows: [COUNT_CAPACITY]Count
	total, status := counts_read(&rows)
	if status != .Ok {
		return errors.fail(error, ERROR_REFUSED, .Refused, .None, 0, 0, 0, i64(status))
	}
	copy(result^, rows[:total])
	return i64(total)
}

// count gives one count of the machine by its name, as counts() names it: count("free pages"). The result is the count, or a negative number with an error record. The error kinds: No_Grant (-1, the caller does not act for the principal); Refused (-2, the kernel refused the report to the monitor); Absent (-3, no count has this name).
@(export, link_name = "count")
count :: proc "c" (name: ^string, error: ^errors.Error_Record) -> i64 {
	if !acts_for_principal() {
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .No_Grant, .Acts_For_Principal)
	}
	// One copy: the caller can change the call region during the call.
	wanted: [24]u8
	if len(name^) >= len(wanted) {
		return errors.fail(error, ERROR_ABSENT, .Absent, .None, 1)
	}
	copied := copy(wanted[:], name^)
	rows: [COUNT_CAPACITY]Count
	total, status := counts_read(&rows)
	if status != .Ok {
		return errors.fail(error, ERROR_REFUSED, .Refused, .None, 0, 0, 0, i64(status))
	}
	for &row in rows[:total] {
		if system.name_of(row.name[:]) == string(wanted[:copied]) {
			return row.value
		}
	}
	return errors.fail(error, ERROR_ABSENT, .Absent, .None, 1)
}

// counts_named gives the counts of the machine that a table of names names, in the order of the table: many counts in one call. The result is the count of rows, or a negative number with an error record. The error kinds: No_Grant (-1, the caller does not act for the principal); Refused (-2, the kernel refused the report to the monitor); Absent (-3, a name names no count: found is the number of its row, from 1). With a table of error details, it gives one Absent detail for each row that names no count, in the order of the rows; the error record is the first of them.
@(export, link_name = "counts_named")
counts_named :: proc "c" (names: ^system.Table_To_Read(Count_Name), details: ^system.Table_To_Append(errors.Error_Record), result: ^[]Count, error: ^errors.Error_Record) -> i64 {
	if !acts_for_principal() {
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .No_Grant, .Acts_For_Principal)
	}
	rows: [COUNT_CAPACITY]Count
	total, status := counts_read(&rows)
	if status != .Ok {
		return errors.fail(error, ERROR_REFUSED, .Refused, .None, 0, 0, 0, i64(status))
	}
	first_absent: errors.Error_Record
	absent_count := 0
	for number in 0 ..< names.count {
		// One copy of the record: the caller can change the call region
		// during the call (docs/MODULE_CONTRACT.md: an export copies a
		// record before it checks it).
		wanted := intrinsics.volatile_load(&names.records[number])
		found := -1
		for &row, index in rows[:total] {
			if system.name_of(row.name[:]) == system.name_of(wanted.name[:]) {
				found = index
			}
		}
		if found < 0 {
			absent := errors.error_make(.Absent, .None, 1, 0, 0, i64(number + 1))
			if absent_count == 0 {
				first_absent = absent
			}
			absent_count += 1
			// With no table of error details the first row is the whole
			// answer: stop, as a call with no table always did.
			if details == nil {
				break
			}
			system.error_detail_append(details, absent)
			continue
		}
		if number < u64(len(result^)) {
			result[number] = rows[found]
		}
	}
	if absent_count > 0 {
		if error != nil {
			error^ = first_absent
		}
		return ERROR_ABSENT
	}
	return i64(names.count)
}

COUNT_CAPACITY :: 16

// counts_read fills the counts of the machine from the system report.
counts_read :: proc "contextless" (rows: ^[COUNT_CAPACITY]Count) -> (total: int, status: system.Status) {
	report: op.System_Report
	if _, status = system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.System), 0, u64(uintptr(&report)), size_of(report)); status != .Ok {
		return 0, status
	}
	running: u64
	for slot in 1 ..< report.program_slots {
		program: op.Program_Report
		if _, program_status := system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.Program), slot, u64(uintptr(&program)), size_of(program)); program_status == .Ok && program.state != .None {
			running += 1
		}
	}
	takes, waits: u64
	for kind in op.Lock_Kind {
		takes += report.locks[kind].takes
		waits += report.locks[kind].waits
	}
	Item :: struct {
		name:  string,
		value: u64,
		unit:  string,
	}
	items := [?]Item {
		{"time", report.time, "milliseconds"},
		{"pages", report.page_count, "pages"},
		{"free pages", report.free_pages, "pages"},
		{"reserved pages", report.reserved_pages, "pages"},
		{"budget pages", report.budget_pages, "pages"},
		{"memory objects", report.region_count, "objects"},
		{"programs", running, "programs"},
		{"processors", report.processors, "processors"},
		{"kernel entries", report.entries, "entries"},
		{"interrupts", report.interrupts, "interrupts"},
		{"first use faults", report.first_use_faults, "faults"},
		{"lock takes", takes, "takes"},
		{"lock waits", waits, "waits"},
		// The value is the number of the strategy; the unit names it.
		{"strategy", u64(report.strategy), report.strategy <= max(op.Strategy) ? op.STRATEGY_NAMES[report.strategy] : "unknown"},
		{"strategy changes", u64(report.strategy_changes), "changes"},
	}
	#assert(len(items) <= COUNT_CAPACITY)
	for item, index in items {
		rows[index] = {value = i64(item.value)}
		copy(rows[index].name[:len(rows[index].name) - 1], item.name)
		copy(rows[index].unit[:len(rows[index].unit) - 1], item.unit)
	}
	return len(items), .Ok
}

// served gives what the monitor did as a service: the calls that it executed, the connections that it has now, and the pictures of its window. These are facts of the monitor itself: each caller sees them.
@(export, link_name = "served")
served :: proc "c" (result: ^Served) {
	result^ = {calls = i64(service.calls), callers = i64(service.connected), pictures = i64(pictures)}
}
