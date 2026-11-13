package kernel

import "base:intrinsics"
import "contract:errors"
import op "contract:operation"
import "contract:ring"
import "contract:value_kinds"

// The error record of a kernel operation that failed, and the stack trace
// of a fault (docs/MODULE_CONTRACT.md, section 8).
//
// The kernel finds the record after the operation failed: the operations
// do not change, and an operation that succeeds runs no code of this file.
// The record comes from the forms of the parameters (op.OPERATIONS), read
// in their order, as the operation reads them. It describes what the
// caller gave and its own handles: the amounts of a budget and the state
// of a program only when the handle has the right Read: without it, a
// program learns nothing of another program.
//
// Each table is read in one place: the procedures `read_*` below. Each one
// takes the lock that protects what it reads in the table "Locks of the
// kernel" of docs/ARCHITECTURE.md, in the lock order, copies what it reads,
// and frees the lock before it returns. `diagnose` runs after the operation
// freed all its locks (enter, after command_run), and only on a failure: the
// path of a success takes no lock here. Between the failure and the record,
// another thread can change the state: the record describes what the kernel
// reads now, and `diagnose` keeps it only if its kind can explain the status
// (`kind_explains`); else the record is Refused with the status. A record
// never contradicts its status.
//
// A read that follows a handle to another object (a budget, a memory object,
// a program) finds the handle again under the program lock of the caller,
// and keeps that lock while it reads the object: the handle holds a
// reference, so the slot of the object cannot serve another object.

// The lock of the program that runs. Taken by each read of its handle table,
// its mappings and its page table. A read in the stack trace runs under this
// lock already (program_fault): program_lock then takes nothing.
@(private = "file")
caller_lock :: proc "contextless" (program: ^Program) -> (index: u32, taken: bool) {
	index = u32(intrinsics.ptr_sub(program, &programs[0]))
	return index, program_lock(index)
}

// find is handle_find on a copy of the slot, under the program lock that the
// caller of find holds.
@(private = "file")
find :: proc "contextless" (program: ^Program, handle: u64, kind: Object_Kind, rights: op.Rights) -> (slot: Handle_Slot, ok: bool) {
	index := handle & 0xFFFF
	if index == 0 || index >= HANDLE_CAPACITY || handle >> 32 != 0 {
		return {}, false
	}
	slot = program.handles[index]
	if slot.kind == .None || u64(slot.generation) != handle >> 16 || kind != .None && slot.kind != kind || !(rights <= slot.rights) {
		return {}, false
	}
	return slot, true
}

// read_handle copies the slot of a handle of a program. Lock: the program
// lock.
@(private = "file")
read_handle :: proc "contextless" (program: ^Program, index: u64) -> Handle_Slot {
	at, taken := caller_lock(program)
	defer program_unlock(at, taken)
	return program.handles[index]
}

// read_handle_find copies the slot of a handle that names an object of the
// kind with the rights. Lock: the program lock.
@(private = "file")
read_handle_find :: proc "contextless" (program: ^Program, handle: u64, kind: Object_Kind, rights: op.Rights = {}) -> (slot: Handle_Slot, ok: bool) {
	at, taken := caller_lock(program)
	defer program_unlock(at, taken)
	return find(program, handle, kind, rights)
}

// read_free_handles counts the free places of the handle table of a
// program. Lock: the program lock.
@(private = "file")
read_free_handles :: proc "contextless" (program: ^Program) -> (count: u64) {
	at, taken := caller_lock(program)
	defer program_unlock(at, taken)
	for slot in program.handles[1:] {
		count += u64(slot.kind == .None)
	}
	return count
}

// read_user copies memory of the program that runs, if it can read it.
// Lock: the program lock: no unmap runs between user_range and user_copy.
@(private = "file")
read_user :: proc "contextless" (program: ^Program, address: u64, destination: rawptr, size: u64) -> bool {
	at, taken := caller_lock(program)
	defer program_unlock(at, taken)
	if !user_range(program, address, size, false) {
		return false
	}
	user_copy(destination, rawptr(uintptr(address)), size)
	return true
}

// read_range says if the program can read (or write) a range of its
// memory. Lock: the program lock.
@(private = "file")
read_range :: proc "contextless" (program: ^Program, address: u64, size: u64, write := false) -> bool {
	at, taken := caller_lock(program)
	defer program_unlock(at, taken)
	return user_range(program, address, size, write)
}

// read_overlaps says if a range of addresses overlaps a mapping of the
// program. Lock: the program lock.
@(private = "file")
read_overlaps :: proc "contextless" (program: ^Program, address: u64, size: u64) -> bool {
	at, taken := caller_lock(program)
	defer program_unlock(at, taken)
	for mapping in program.mappings {
		if mapping.page_count != 0 && address < mapping.address + mapping.page_count * PAGE_SIZE && mapping.address < address + size {
			return true
		}
	}
	return false
}

// read_mapping_at says if a mapping of the program starts at an address.
// Lock: the program lock.
@(private = "file")
read_mapping_at :: proc "contextless" (program: ^Program, address: u64) -> bool {
	at, taken := caller_lock(program)
	defer program_unlock(at, taken)
	for mapping in program.mappings {
		if mapping.page_count != 0 && mapping.address == address {
			return true
		}
	}
	return false
}

// read_own_full says which tables of the program are full: its mappings,
// its module records, its thread areas. Lock: the program lock.
@(private = "file")
read_own_full :: proc "contextless" (program: ^Program) -> (mappings, modules, threads: bool) {
	at, taken := caller_lock(program)
	defer program_unlock(at, taken)
	mappings, modules = true, true
	for mapping in program.mappings {
		if mapping.page_count == 0 {
			mappings = false
		}
	}
	for item in program.modules {
		if item.size == 0 {
			modules = false
		}
	}
	threads = program.thread_areas == max(u32)
	return mappings, modules, threads
}

// read_regions_full says if the table of the memory objects is full. Lock:
// the frame lock (the slots of the memory objects).
@(private = "file")
read_regions_full :: proc "contextless" () -> bool {
	lock_take(&frame_lock, .Frame)
	defer lock_free(&frame_lock, .Frame)
	for region in regions[1:] {
		if region.page_count == 0 {
			return false
		}
	}
	return true
}

// Machine_Full: which tables of the machine are full.
@(private = "file")
Machine_Full :: struct {
	programs, budgets, messages: bool,
}

// read_machine_full reads the tables of the machine that the operations
// that create objects scan under the control lock. Lock: the control lock.
@(private = "file")
read_machine_full :: proc "contextless" () -> (full: Machine_Full) {
	control_take()
	defer control_free()
	full = {true, true, true}
	for program in programs[1:] {
		if program.state == .None {
			full.programs = false
		}
	}
	for budget in budgets[1:] {
		if !budget.live {
			full.budgets = false
		}
	}
	for candidate in u32(INTERRUPT_LINES) ..< INTERRUPT_CAPACITY {
		if interrupt_references[candidate] == 0 {
			full.messages = false
		}
	}
	return full
}

// read_word says if a program can wait on a word. Lock: the program lock.
@(private = "file")
read_word :: proc "contextless" (program: ^Program, address: u64) -> bool {
	at, taken := caller_lock(program)
	defer program_unlock(at, taken)
	return word_address(program, address) != 0
}

// read_threads gives the threads of a program. Lock: the program lock.
@(private = "file")
read_threads :: proc "contextless" (program: ^Program) -> u32 {
	at, taken := caller_lock(program)
	defer program_unlock(at, taken)
	return program.thread_count
}

// read_budget copies the rights of a budget handle with the right Spend,
// and, with the right Read, the amounts that the operation needs. Locks, in
// their order: the control lock only for the programs, the threads and the
// limits (Program_Create, Thread_Create, Budget_Create); the program lock
// (the handle); the frame lock (the pages). A handle without Read gives no
// amount: the amounts tell of the other programs that the budget pays for.
@(private = "file")
read_budget :: proc "contextless" (program: ^Program, handle: u64, operation: op.Operation) -> (amounts: op.Budget_Amounts, rights: op.Rights, ok: bool) {
	rights, ok = read_budget_rights(program, handle)
	if !ok || .Read not_in rights {
		return {}, rights, ok
	}
	control := operation != .Memory_Create
	if control {
		control_take()
	}
	at, taken := caller_lock(program)
	slot: Handle_Slot
	if slot, ok = find(program, handle, .Budget, {.Spend, .Read}); ok {
		budget := &budgets[slot.object]
		if control {
			amounts = budget.amounts
		}
		lock_take(&frame_lock, .Frame)
		amounts.pages = budget.amounts.pages
		lock_free(&frame_lock, .Frame)
	}
	program_unlock(at, taken)
	if control {
		control_free()
	}
	return amounts, slot.rights, ok
}

// read_budget_rights gives the rights of a budget handle with the right
// Spend. Lock: the program lock.
@(private = "file")
read_budget_rights :: proc "contextless" (program: ^Program, handle: u64) -> (rights: op.Rights, ok: bool) {
	at, taken := caller_lock(program)
	defer program_unlock(at, taken)
	slot: Handle_Slot
	slot, ok = find(program, handle, .Budget, {.Spend})
	return slot.rights, ok
}

// read_log_count gives the log records in this second of the budget that
// paid for the program, and its limit, if the program holds that budget
// with the right Read, because the count tells of the other programs that
// the budget pays for; held is false otherwise. Lock: the program lock
// only. The handle keeps the budget live; program.budget changes only when
// that budget ends (an atomic store), and the limit of a live budget never
// changes: no other lock is needed. The count is atomic.
@(private = "file")
read_log_count :: proc "contextless" (program: ^Program) -> (logged, limit: u64, held: bool) {
	at, taken := caller_lock(program)
	defer program_unlock(at, taken)
	budget := intrinsics.atomic_load(&program.budget)
	for slot in program.handles[1:] {
		if slot.kind == .Budget && slot.object == budget && .Read in slot.rights {
			held = true
		}
	}
	if !held {
		return 0, 0, false
	}
	word := intrinsics.atomic_load(&budgets[budget].logged)
	second := intrinsics.atomic_load(&time_milliseconds) / LOG_PERIOD
	logged = word >> 32 == second ? word & 0xFFFF_FFFF : 0
	return logged, budgets[budget].amounts.log_records, true
}

// read_protect_range says if one mapping of the program holds a range of
// pages from an address, and if the range is a part of a mapping whose
// protection changes only whole (a contiguous object, a thread area).
@(private = "file")
read_protect_range :: proc "contextless" (program: ^Program, address: u64, page_count: u64) -> (covered: bool, whole_only: bool) {
	at, taken := caller_lock(program)
	defer program_unlock(at, taken)
	for mapping in program.mappings {
		if mapping.page_count != 0 && address >= mapping.address && (address - mapping.address) / PAGE_SIZE + page_count <= mapping.page_count {
			whole := address == mapping.address && page_count == mapping.page_count
			whole_only = mapping.address >= op.THREAD_AREA_BASE || !whole && regions[mapping.region].contiguous
			return true, whole_only
		}
	}
	return false, false
}

// read_protect_walk gives what a table of address ranges of a protection
// change costs, as memory_protect counts it (protect_walk_count). A range
// that no mapping covers counts its pages.
@(private = "file")
read_protect_walk :: proc "contextless" (program: ^Program, address: u64, count: u64) -> (walked: u64) {
	at, taken := caller_lock(program)
	defer program_unlock(at, taken)
	for index in 0 ..< min(count, op.RANGE_TABLE_CAPACITY) {
		range: op.Address_Range
		if !read_user(program, address + index * size_of(op.Address_Range), &range, size_of(range)) {
			return 0
		}
		cost := min(range.page_count, op.RANGE_TABLE_PAGE_LIMIT + 1)
		for &mapping in program.mappings {
			if mapping.page_count != 0 && range.address >= mapping.address && (range.address - mapping.address) / PAGE_SIZE + range.page_count <= mapping.page_count {
				cost = protect_walk_count(&mapping, range)
				break
			}
		}
		walked += cost
	}
	return walked
}

// read_marked_pages gives the pages with a protection of their own of the
// memory object of a handle; 0 for another handle.
@(private = "file")
read_marked_pages :: proc "contextless" (program: ^Program, handle: u64) -> u64 {
	slot, found := read_handle_find(program, handle, .Memory)
	if !found {
		return 0
	}
	return intrinsics.atomic_load(&regions[slot.object].marked_pages)
}

// read_table_pages gives the pages of a table of ranges in memory of the
// program (a Page_Range or an Address_Range: the offset of the count).
@(private = "file")
read_table_pages :: proc "contextless" (program: ^Program, address: u64, count: u64, record_size: u64, count_offset: uintptr) -> (pages: u64) {
	for index in 0 ..< min(count, op.RANGE_TABLE_CAPACITY) {
		value: u64
		if !read_user(program, address + index * record_size + u64(count_offset), &value, 8) {
			return 0
		}
		pages += min(value, op.RANGE_TABLE_PAGE_LIMIT + 1)
	}
	return pages
}

@(private = "file")
// read_commit_needed gives the pages that a commit of a table of ranges
// asks (the pages that are not committed) and the pages that the budget of
// the object holds; held is false when the record must not name them.
read_commit_needed :: proc "contextless" (program: ^Program, handle: u64, ranges_address: u64, count: u64) -> (needed, pages: u64, held: bool) {
	at, taken := caller_lock(program)
	defer program_unlock(at, taken)
	slot: Handle_Slot
	ok: bool
	if slot, ok = find(program, handle, .Memory, {}); !ok {
		return
	}
	region := &regions[slot.object]
	if !region.uncommitted {
		return
	}
	walked: u64
	for index in 0 ..< min(count, op.RANGE_TABLE_CAPACITY) {
		range: op.Page_Range
		if !read_user(program, ranges_address + index * size_of(op.Page_Range), &range, size_of(range)) || range.first >= region.page_count || range.page_count > region.page_count - range.first {
			return
		}
		// At most RANGE_TABLE_PAGE_LIMIT pages read: the table is memory of
		// the program, which can grow it after the call failed, and the
		// sum runs with the program lock held.
		walked += range.page_count
		if walked > op.RANGE_TABLE_PAGE_LIMIT {
			return
		}
		for page in range.first ..< range.first + range.page_count {
			needed += 1 - intrinsics.atomic_load(region_slot(region, page)) & SLOT_COMMITTED
		}
	}
	lock_take(&frame_lock, .Frame)
	pages = budgets[region.budget].amounts.pages
	lock_free(&frame_lock, .Frame)
	return needed, pages, true
}

// read_memory_pages gives the pages of the memory object of a handle.
// Locks, in their order: the program lock (the handle), the frame lock (the
// slot of the object).
@(private = "file")
read_memory_pages :: proc "contextless" (program: ^Program, handle: u64) -> (pages: u64, ok: bool) {
	at, taken := caller_lock(program)
	defer program_unlock(at, taken)
	slot: Handle_Slot
	if slot, ok = find(program, handle, .Memory, {}); !ok {
		return 0, false
	}
	lock_take(&frame_lock, .Frame)
	pages = regions[slot.object].page_count
	lock_free(&frame_lock, .Frame)
	return pages, true
}

// read_program_state gives the kind and the rights of a handle, and the
// state of its program when it names a program with the right Read (else
// None). Locks, in their order: the control lock (another program), the
// program lock of the caller (the handle), the program lock of the other
// program (two program locks only under the control lock).
@(private = "file")
read_program_state :: proc "contextless" (program: ^Program, handle: u64) -> (slot: Handle_Slot, state: op.Program_State, ok: bool) {
	control_take()
	defer control_free()
	at, taken := caller_lock(program)
	defer program_unlock(at, taken)
	if slot, ok = find(program, handle, .None, {}); !ok {
		return {}, .None, false
	}
	if slot.kind == .Program && .Read in slot.rights {
		other := program_lock(slot.object)
		state = program_state(slot.object)
		program_unlock(slot.object, other)
	}
	return slot, state, true
}

// kind_explains says if an error kind can be the cause of a status.
@(private = "file")
kind_explains :: proc "contextless" (kind: errors.Kind, status: op.Status) -> bool {
	#partial switch status {
	case .Bad_Handle:
		return kind == .Handle_Absent || kind == .Handle_Ended || kind == .Handle_Kind || kind == .No_Target || kind == .Not_Payer
	case .No_Right:
		return kind == .Handle_Rights
	case .No_Budget:
		return kind == .Budget || kind == .Budget_Hidden || kind == .Over_Limit
	case .Bad_Address:
		return kind == .Bad_Address || kind == .Too_Long || kind == .Too_Small || kind == .Overlap || kind == .Absent || kind == .Whole_Only
	case .No_Slot:
		return kind == .Full || kind == .Too_Long
	case .Bad_State:
		return kind == .State || kind == .Object_Shared || kind == .Object_Marked
	case .Bad_Operation:
		return kind == .Bad_Flags || kind == .Bad_Value || kind == .Too_Small || kind == .Too_Long || kind == .Unknown_Operation || kind == .Not_Multiple
	}
	return false
}

@(private = "file")
record_set :: proc "contextless" (record: ^errors.Error_Record, kind: errors.Kind, unit: errors.Unit, argument: int, value, limit, found: u64) {
	record.kind, record.unit, record.argument = i64(kind), i64(unit), i64(argument)
	record.value, record.limit, record.found = i64(value), i64(limit), i64(found)
}

// diagnose gives the error record of an operation of a program that failed
// with a status.
diagnose :: proc "contextless" (program_index: u32, command: ring.Record, status: op.Status) -> (record: errors.Error_Record) {
	// It runs with no lock held: each read takes its locks in the lock order.
	when TEST_BUILD_CHECKS_LOCK_ORDER {
		for kind in op.Lock_Kind {
			if lock_ready && lock_held(kind) {
				log("kernel: diagnose runs with a lock ", op.LOCK_KIND_NAMES[kind], " held")
				machine_stop(3)
			}
		}
	}
	record.operation = i64(command.kind)
	if command.kind == 0 || command.kind > u32(max(op.Operation)) {
		record_set(&record, .Unknown_Operation, .None, 0, u64(command.kind), u64(max(op.Operation)), 0)
		return record
	}
	operation := op.Operation(command.kind)
	program := &programs[program_index]
	v := command.values
	explained := false
	#partial switch status {
	case .Bad_Handle, .No_Right:
		explained = handles_explain(&record, program, operation, v)
		if !explained && operation == .Handle_Give && v[0] != 0 {
			record_set(&record, .No_Target, .None, 1, v[0], 0, 0) // A memory object that no one other program maps or holds.
			explained = true
		}
	case .No_Budget:
		explained = budget_explain(&record, program, operation, v)
	case .Bad_Address:
		explained = address_explain(&record, program, operation, v)
	case .No_Slot:
		explained = slot_explain(&record, program, operation, v)
	case .Bad_State:
		explained = state_explain(&record, program, operation, v)
	case .Bad_Operation:
		explained = value_explain(&record, program, operation, v)
	}
	if !explained || !kind_explains(errors.Kind(record.kind), status) {
		record = {operation = record.operation}
		record_set(&record, .Refused, .None, 0, 0, 0, u64(status))
	}
	return record
}

// handle_explain says what is wrong with a handle that an operation needs
// of a kind (None: any kind) with rights. false: the handle is good.
@(private = "file")
handle_explain :: proc "contextless" (record: ^errors.Error_Record, program: ^Program, argument: int, handle: u64, kind: Object_Kind, rights: op.Rights) -> bool {
	index := handle & 0xFFFF
	generation := handle >> 16
	if index == 0 || index >= HANDLE_CAPACITY || generation > 0xFFFF {
		record_set(record, .Handle_Absent, .None, argument, handle, 0, 0)
		return true
	}
	slot := read_handle(program, index)
	if slot.kind == .None || u64(slot.generation) != generation {
		switch {
		case slot.kind == .None && slot.generation == u16(generation + 1): // A close of generation 0xFFFF gives 0.
			record_set(record, .Handle_Ended, .None, argument, handle, 0, u64(slot.ended))
		case u64(slot.generation) > generation:
			record_set(record, .Handle_Ended, .None, argument, handle, 0, u64(errors.End.Unknown))
		case:
			record_set(record, .Handle_Absent, .None, argument, handle, 0, 0)
		}
		return true
	}
	if kind != .None && slot.kind != kind {
		record_set(record, .Handle_Kind, .None, argument, handle, u64(kind), u64(slot.kind))
		return true
	}
	if !(rights <= slot.rights) {
		record_set(record, .Handle_Rights, .None, argument, handle, u64(transmute(u32)rights), u64(transmute(u32)slot.rights))
		return true
	}
	return false
}

@(private = "file")
handles_explain :: proc "contextless" (record: ^errors.Error_Record, program: ^Program, operation: op.Operation, v: [7]u64) -> bool {
	form := &op.OPERATIONS[operation]
	for parameter, n in form.parameters {
		if parameter.form != .Handle && parameter.form != .Handle_Or_Zero || parameter.form == .Handle_Or_Zero && v[n] == 0 {
			continue
		}
		rights := parameter.rights
		kind := parameter.kind
		#partial switch operation {
		case .Memory_Map:
			if n == 0 {
				flags := transmute(op.Map_Flags)v[3]
				if .Write in flags {
					rights += {.Write}
				}
				if .Execute in flags {
					rights += {.Execute}
				}
			}
		case .Handle_Give:
			if n == 1 && v[0] == 0 {
				rights = {} // A copy in this program needs no Give.
			}
			if n == 0 {
				// The target: a program with Control, or a memory object.
				slot, found := read_handle_find(program, v[0], .None)
				if found && slot.kind == .Program {
					rights = {.Control}
				} else if found && slot.kind != .Memory {
					kind = .Program
				}
			}
		case .Thread_Control:
			// The right depends on the command: Write for a write of the
			// registers, Control for a write of the schedule. A command of
			// the schedule also takes the machine handle, with Schedule,
			// and with Inspect too for a read.
			if n == 0 && v[2] <= u64(max(op.Thread_Control_Command)) {
				command := op.Thread_Control_Command(v[2])
				rights = op.thread_control_rights(command)
				machine_rights, by_machine_number := op.thread_control_machine_rights(command)
				if slot, found := read_handle_find(program, v[0], .None); found && slot.kind == .Machine && by_machine_number {
					kind, rights = .Machine, machine_rights
				}
			}
		}
		if handle_explain(record, program, n + 1, v[n], kind, rights) {
			return true
		}
	}
	// The payer of a commit: a handle of the budget of the object, with
	// Commit or Spend. The record says nothing of a budget that is not the
	// payer: a program sees only what its handles let it see.
	if operation == .Memory_Commit && transmute(op.Commit_Flags)v[4] & {.Decommit} == {} {
		if v[1] == 0 {
			record_set(record, .Handle_Absent, .None, 2, 0, 0, 0)
			return true
		}
		slot, found := read_handle_find(program, v[1], .Budget)
		if !found {
			return false
		}
		if slot.rights & {.Commit, .Spend} == {} {
			record_set(record, .Handle_Rights, .None, 2, v[1], u64(transmute(u32)op.Rights{.Commit}), u64(transmute(u32)slot.rights))
			return true
		}
		if memory, held := read_handle_find(program, v[0], .Memory); held && !read_pays_for(slot.object, memory.object) {
			record_set(record, .Not_Payer, .None, 2, v[1], 0, 0)
			return true
		}
	}
	return false
}

// read_pays_for says if a budget pays for a memory object now.
read_pays_for :: proc "contextless" (budget: u32, region: u32) -> bool {
	lock_take(&frame_lock, .Frame)
	defer lock_free(&frame_lock, .Frame)
	return regions[region].budget == budget
}

// budget_ask gives what an operation asks of a budget, and what the budget
// holds of it.
@(private = "file")
budget_explain :: proc "contextless" (record: ^errors.Error_Record, program: ^Program, operation: op.Operation, v: [7]u64) -> bool {
	if operation == .Log {
		// The limit of the budget of the program. Its counts only with a
		// handle with Read, so that a program without it learns nothing of
		// another program; a budget above it is never described: when
		// the budget of the program is not over its limit now, a budget above
		// refused, or a new second started, and the record is Refused.
		logged, limit, held := read_log_count(program)
		if !held {
			record_set(record, .Budget_Hidden, .Log_Records, 0, 0, 1, 0)
			return true
		}
		if logged < limit {
			return false
		}
		record_set(record, .Over_Limit, .Log_Records, 0, logged + 1, limit, 0)
		return true
	}
	if operation == .Memory_Commit {
		// The pages that the table asks against what the budget holds; what
		// it holds only with the right Read on the budget handle.
		needed, pages, held := read_commit_needed(program, v[0], v[2], v[3])
		if !held || needed <= pages {
			return false
		}
		if budget, found := read_handle_find(program, v[1], .Budget); found && .Read not_in budget.rights {
			record_set(record, .Budget_Hidden, .Pages, 2, v[1], needed, 0)
			return true
		}
		record_set(record, .Budget, .Pages, 2, v[1], needed, pages)
		return true
	}
	if operation != .Memory_Create && operation != .Program_Create && operation != .Thread_Create && operation != .Budget_Create {
		return false
	}
	holds, rights, found := read_budget(program, v[0], operation)
	if !found {
		return false
	}
	// Without Read the record depends on the operation alone, so that it
	// tells nothing of another program.
	if .Read not_in rights {
		#partial switch operation {
		case .Memory_Create:
			flags := transmute(op.Memory_Flags)v[2]
			record_set(record, .Budget_Hidden, .Pages, 1, v[0], region_cost(v[1], .Contiguous in flags), 0)
		case .Program_Create:
			record_set(record, .Budget_Hidden, .Programs, 1, v[0], 1, 0)
		case .Thread_Create:
			record_set(record, .Budget_Hidden, .Threads, 1, v[0], 1, 0)
		case .Budget_Create:
			record_set(record, .Budget_Hidden, .None, 1, v[0], 0, 0)
		}
		return true
	}
	unit: errors.Unit
	asked, held: u64
	argument := 1
	#partial switch operation {
	case .Memory_Create:
		flags := transmute(op.Memory_Flags)v[2]
		unit, asked, held = .Pages, region_cost(v[1], .Contiguous in flags), holds.pages
	case .Program_Create:
		unit, asked, held = .Programs, 1, holds.programs
		if holds.programs != 0 {
			unit, held = .Pages, holds.pages // The page tables.
		}
	case .Thread_Create:
		unit, asked, held = .Threads, 1, holds.threads
		if holds.threads != 0 {
			unit, asked, held = .Pages, 1 + ring.PAGE_COUNT, holds.pages // The thread area.
		}
	case .Budget_Create:
		amounts := [5]u64{holds.pages, holds.programs, holds.threads, holds.processor, holds.log_records}
		units := [5]errors.Unit{.Pages, .Programs, .Threads, .Processor, .Log_Records}
		for amount, n in amounts {
			if v[n + 1] > amount {
				argument, unit, asked, held = n + 2, units[n], v[n + 1], amount
				break
			}
		}
	}
	// The cause is gone: the budget can pay now.
	if asked <= held {
		return false
	}
	record_set(record, .Budget, unit, argument, v[0], asked, held)
	return true
}

@(private = "file", rodata)
INSPECT_SIZES := [op.Inspect_Kind]u64 {
	.None      = 0,
	.System    = size_of(op.System_Report),
	.Program   = size_of(op.Program_Report),
	.Processor = size_of(op.Processor_Report),
	.Boot      = size_of(op.Boot_Report),
	.Mappings  = size_of(op.Mapping_Report),
	.Modules   = size_of(op.Module_Report),
	.Program_Mappings = size_of(op.Program_Mapping_Report),
	.Threads   = size_of(op.Thread_Table_Report),
	.Stop      = size_of(op.Stop_Report),
	.Pages     = size_of(op.Page_Report),
}

@(private = "file")
address_explain :: proc "contextless" (record: ^errors.Error_Record, program: ^Program, operation: op.Operation, v: [7]u64) -> bool {
	#partial switch operation {
	case .Log:
		// The text, then its value runs, at the address.
		if v[2] > 4096 {
			record_set(record, .Too_Long, .Bytes, 3, v[2], 4096, 0)
		} else if v[6] <= op.LOG_CALL_RUN_LIMIT && !read_range(program, v[1], v[2] + v[6] * size_of(value_kinds.Value_Run_In_Call)) {
			record_set(record, .Bad_Address, .Bytes, 2, v[1], v[2] + v[6] * size_of(value_kinds.Value_Run_In_Call), 0)
		} else {
			return false
		}
	case .Program_Create:
		if v[2] > 31 {
			record_set(record, .Too_Long, .Bytes, 3, v[2], 31, 0)
		} else if !read_range(program, v[1], v[2]) {
			record_set(record, .Bad_Address, .Bytes, 2, v[1], v[2], 0)
		} else {
			return false
		}
	case .Program_State:
		if read_range(program, v[1], size_of(op.Stop_Report), true) {
			return false
		}
		record_set(record, .Bad_Address, .Bytes, 2, v[1], size_of(op.Stop_Report), 1)
	case .Program_Module:
		module: op.Module_Record
		if !read_user(program, v[1], &module, size_of(module)) {
			record_set(record, .Bad_Address, .Bytes, 2, v[1], size_of(op.Module_Record), 0)
			return true
		}
		// The records of another program need its lock: no more detail.
		if v[0] != 0 {
			return false
		}
		if module.size == 0 {
			record_set(record, .Absent, .Bytes, 2, module.base, 0, 0) // No record has this base.
		} else {
			record_set(record, .Overlap, .Bytes, 2, module.base, module.size, 0)
		}
	case .Word_Wait:
		if !read_range(program, v[0], v[1] * size_of(op.Word)) {
			record_set(record, .Bad_Address, .Bytes, 1, v[0], v[1] * size_of(op.Word), 0)
			return true
		}
		for index in 0 ..< v[1] {
			word: op.Word
			if !read_user(program, v[0] + index * size_of(op.Word), &word, size_of(op.Word)) {
				return false // Unmapped since: the cause is not known now.
			}
			if !read_word(program, word.address) {
				record_set(record, .Bad_Address, .Bytes, 1, word.address, 4, 0)
				return true
			}
		}
		return false
	case .Word_Wake:
		if read_word(program, v[0]) {
			return false
		}
		record_set(record, .Bad_Address, .Bytes, 1, v[0], 4, 0)
	case .Inspect:
		kind := op.Inspect_Kind(v[1])
		size := kind <= max(op.Inspect_Kind) ? INSPECT_SIZES[kind] : 0
		if v[4] < size {
			record_set(record, .Too_Small, .Bytes, 5, v[4], size, 0)
		} else if !read_range(program, v[3], size, true) {
			record_set(record, .Bad_Address, .Bytes, 4, v[3], size, 1)
		} else {
			return false
		}
	case .Memory_Map:
		page_count, found := read_memory_pages(program, v[0])
		if !found {
			return false
		}
		count := v[5] == 0 && v[4] < page_count ? page_count - v[4] : v[5]
		switch {
		case v[4] >= page_count:
			record_set(record, .Too_Long, .Pages, 5, v[4], page_count - 1, 0)
		case count > page_count - v[4]:
			record_set(record, .Too_Long, .Pages, 6, count, page_count - v[4], 0)
		case v[2] != 0 && (v[2] % PAGE_SIZE != 0 || v[2] < PAGE_SIZE || v[2] >= USER_END || count * PAGE_SIZE > USER_END - v[2]):
			record_set(record, .Bad_Address, .Bytes, 3, v[2], count * PAGE_SIZE, 0)
		case v[2] != 0 && v[1] == 0 && read_overlaps(program, v[2], count * PAGE_SIZE):
			record_set(record, .Overlap, .Bytes, 3, v[2], count * PAGE_SIZE, 0) // The addresses of another mapping.
		case:
			return false // In another program, whose mappings need its lock, or the overlap is gone.
		}
	case .Memory_Commit:
		// The first range that is not in the object, or not after the one before.
		pages, found := read_memory_pages(program, v[0])
		if !found || !read_range(program, v[2], v[3] * size_of(op.Page_Range)) {
			return false
		}
		end: u64
		for index in 0 ..< v[3] {
			range: op.Page_Range
			if !read_user(program, v[2] + index * size_of(op.Page_Range), &range, size_of(range)) {
				return false
			}
			switch {
			case range.page_count == 0:
				record_set(record, .Too_Small, .Pages, 3, 0, 1, index)
				return true
			case range.first >= pages || range.page_count > pages - range.first:
				record_set(record, .Too_Long, .Pages, 3, range.first + range.page_count, pages, index)
				return true
			case range.first < end:
				record_set(record, .Overlap, .Pages, 3, range.first, end, index)
				return true
			}
			end = range.first + range.page_count
		}
		return false
	case .Memory_Protect:
		// The first range that is not inside one mapping of this program, or
		// a part of a mapping that changes only whole.
		if !read_range(program, v[0], v[1] * size_of(op.Address_Range)) {
			return false
		}
		for index in 0 ..< v[1] {
			range: op.Address_Range
			if !read_user(program, v[0] + index * size_of(op.Address_Range), &range, size_of(range)) {
				return false
			}
			covered, whole_only := read_protect_range(program, range.address, range.page_count)
			if range.address % PAGE_SIZE != 0 || range.page_count == 0 || !covered {
				record_set(record, .Absent, .Bytes, 1, range.address, range.page_count * PAGE_SIZE, index)
				return true
			}
			if whole_only {
				record_set(record, .Whole_Only, .Bytes, 1, range.address, range.page_count * PAGE_SIZE, index)
				return true
			}
		}
		return false
	case .Memory_Unmap:
		if v[0] != 0 || read_mapping_at(program, v[1]) {
			return false
		}
		record_set(record, .Absent, .Bytes, 2, v[1], 0, 0) // No mapping starts at this address.
	case:
		return false
	}
	return true
}

// slot_explain names the full table that refused, only when the table is
// full now and it is the one cause that the state shows; else Refused.
@(private = "file")
slot_explain :: proc "contextless" (record: ^errors.Error_Record, program: ^Program, operation: op.Operation, v: [7]u64) -> bool {
	mappings, modules, areas := read_own_full(program)
	#partial switch operation {
	case .Word_Wait:
		// The words of this entry count too: only a list longer than the
		// capacity is one cause that the record can name.
		if v[1] <= op.WORD_WAIT_CAPACITY {
			return false
		}
		record_set(record, .Too_Long, .Words, 2, v[1], op.WORD_WAIT_CAPACITY, 0)
		return true
	case .Memory_Map:
		if v[1] != 0 || !mappings {
			return false
		}
		record_set(record, .Full, .Mappings, 0, 0, MAPPING_CAPACITY, 0)
		return true
	case .Program_Module:
		if v[0] != 0 || !modules {
			return false
		}
		record_set(record, .Full, .Modules, 0, 0, op.PROGRAM_MODULE_CAPACITY, 0)
		return true
	case .Handle_Give:
		// The one cause of No_Slot here: the handle table of the target.
		record_set(record, .Full, .Handles, 1, v[0], HANDLE_CAPACITY - 1, 0)
		return true
	case .Events_Set:
		// The one cause of No_Slot here: more rules than the event table holds.
		if v[3] <= op.EVENT_RULE_CAPACITY {
			return false
		}
		record_set(record, .Too_Long, .Records, 4, v[3], op.EVENT_RULE_CAPACITY, 0)
		return true
	}
	// The new handle goes in the table of the caller.
	if operation != .Program_Start && read_free_handles(program) == 0 {
		record_set(record, .Full, .Handles, 0, 0, HANDLE_CAPACITY - 1, 0)
		return true
	}
	// A table of the machine is named only where it is the one cause that
	// the status leaves, and its lock is taken only for that operation.
	#partial switch operation {
	case .Memory_Create:
		if !read_regions_full() {
			return false
		}
		record_set(record, .Full, .Memory, 0, 0, REGION_CAPACITY - 1, 0)
	case .Program_Create:
		if !read_machine_full().programs {
			return false
		}
		record_set(record, .Full, .Programs, 0, 0, PROGRAM_CAPACITY - 1, 0)
	case .Thread_Create, .Program_Start:
		// The causes: the thread areas of the program, its mappings (the
		// thread area is a mapping), the memory objects of the machine (the
		// thread area is one), the thread table of the machine. The record
		// names a table of the caller only. Which of two tables of the
		// machine is full is a fact of the machine that the status does not
		// give, because a program learns nothing of another program:
		// Refused. The areas and the mappings of another program
		// (Program_Start) need its lock: Refused too.
		switch {
		case operation == .Thread_Create && areas:
			record_set(record, .Full, .Threads, 0, 0, op.THREAD_CAPACITY, 0)
		case operation == .Thread_Create && mappings:
			record_set(record, .Full, .Mappings, 0, 0, MAPPING_CAPACITY, 0)
		case:
			return false
		}
	case .Budget_Create:
		if !read_machine_full().budgets {
			return false
		}
		record_set(record, .Full, .Budgets, 0, 0, BUDGET_CAPACITY - 1, 0)
	case .Device_Create:
		switch {
		case op.Device_Kind(v[1]) == .Message && read_machine_full().messages:
			record_set(record, .Full, .Interrupts, 0, 0, op.MESSAGE_CAPACITY, 0)
		case op.Device_Kind(v[1]) == .Memory && read_regions_full():
			record_set(record, .Full, .Memory, 0, 0, REGION_CAPACITY - 1, 0)
		case:
			return false
		}
	case:
		return false
	}
	return true
}

@(private = "file")
state_explain :: proc "contextless" (record: ^errors.Error_Record, program: ^Program, operation: op.Operation, v: [7]u64) -> bool {
	argument := 0
	#partial switch operation {
	case .Memory_Map, .Handle_Give:
		// An object with pages of their own protection is not mapped again
		// and not given: the marks would reach the other mapping.
		memory_argument := operation == .Memory_Map ? 0 : 1
		// A target program that stopped is the cause first; the marks after.
		if operation == .Memory_Map && v[1] != 0 {
			if _, state, held := read_program_state(program, v[1]); held && (state == .Stopped || state == .None) {
				record_set(record, .State, .None, 2, v[1], 0, u64(state))
				return true
			}
		}
		if marked := read_marked_pages(program, v[memory_argument]); marked != 0 {
			record_set(record, .Object_Marked, .Pages, memory_argument + 1, v[memory_argument], 0, marked)
			return true
		}
		argument = operation == .Memory_Map ? 2 : 1
	case .Memory_Unmap, .Program_Start, .Program_Module:
		argument = 1
	case .Memory_Commit:
		// A decommit needs an object that only this program names.
		record_set(record, .Object_Shared, .None, 1, v[0], 0, 0)
		return true
	case .Memory_Protect:
		// A part of a mapping needs an object that only this program names.
		record_set(record, .Object_Shared, .None, 1, 0, 0, 0)
		return true
	case:
		return false
	}
	handle := v[argument - 1]
	if handle == 0 {
		return false
	}
	_, state, held := read_program_state(program, handle)
	if !held {
		return false
	}
	found := u64(state)
	limit := operation == .Program_Start ? u64(op.Program_State.Created) : 0
	record_set(record, .State, .None, argument, handle, limit, found)
	return true
}

@(private = "file")
value_explain :: proc "contextless" (record: ^errors.Error_Record, program: ^Program, operation: op.Operation, v: [7]u64) -> bool {
	form := &op.OPERATIONS[operation]
	#partial switch operation {
	case .Log:
		if v[6] > op.LOG_CALL_RUN_LIMIT {
			record_set(record, .Too_Long, .Records, 7, v[6], op.LOG_CALL_RUN_LIMIT, 0)
			return true
		}
	case .Inspect:
		if op.Inspect_Kind(v[1]) != .Pages {
			break
		}
		page_report: op.Page_Report
		switch {
		case v[2] != 0:
			// Pages gives the pages of the program that asks only: index 0.
			record_set(record, .Bad_Value, .None, 3, v[2], 0, 0)
			return true
		case v[4] >= size_of(op.Page_Report) && read_user(program, v[3], &page_report, size_of(page_report)) && (page_report.address & (PAGE_SIZE - 1) != 0 || page_report.address >= USER_END || op.PAGE_REPORT_CAPACITY * PAGE_SIZE > USER_END - page_report.address):
			// The first page that the report at the argument address names:
			// aligned, and its 64 pages in the user half. The record gives that
			// first page, and the last first page that the call takes.
			record_set(record, .Bad_Value, .None, 4, page_report.address, USER_END - op.PAGE_REPORT_CAPACITY * PAGE_SIZE, 0)
			return true
		}
	case .Memory_Create:
		flags := transmute(op.Memory_Flags)v[2]
		switch {
		case v[2] & ~u64(0b1111) != 0:
			record_set(record, .Bad_Flags, .None, 3, v[2], 0b1111, 0)
		case .Uncommitted in flags && flags != {.Uncommitted}:
			record_set(record, .Bad_Flags, .None, 3, v[2], 1 << u64(op.Memory_Flag.Uncommitted), 0) // Uncommitted goes alone.
		case .Large_Pages in flags && v[1] % op.LARGE_PAGE_PAGES != 0:
			record_set(record, .Not_Multiple, .Pages, 2, v[1], op.LARGE_PAGE_PAGES, v[1] % op.LARGE_PAGE_PAGES) // Whole large pages of 512 pages.
		case v[1] == 0:
			record_set(record, .Too_Small, .Pages, 2, 0, 1, 0)
		case:
			record_set(record, .Too_Long, .Pages, 2, v[1], op.MEMORY_PAGE_LIMIT, 0)
		}
		return true
	case .Memory_Map:
		if v[3] & ~u64(0b111) != 0 {
			record_set(record, .Bad_Flags, .None, 4, v[3], 0b111, 0)
		} else {
			record_set(record, .Bad_Value, .None, 4, v[3], 0, 0) // Write and Execute: no page is both.
		}
		return true
	case .Memory_Commit:
		switch {
		case v[3] == 0:
			record_set(record, .Too_Small, .Records, 4, 0, 1, 0)
		case v[3] > op.RANGE_TABLE_CAPACITY:
			record_set(record, .Too_Long, .Records, 4, v[3], op.RANGE_TABLE_CAPACITY, 0)
		case v[4] & ~u64(1) != 0:
			record_set(record, .Bad_Flags, .None, 5, v[4], 1, 0)
		case:
			if pages := read_table_pages(program, v[2], v[3], size_of(op.Page_Range), offset_of(op.Page_Range, page_count)); pages > op.RANGE_TABLE_PAGE_LIMIT {
				record_set(record, .Too_Long, .Pages, 3, pages, op.RANGE_TABLE_PAGE_LIMIT, 0)
			} else {
				record_set(record, .Bad_Value, .None, 1, v[0], 0, 0) // The memory object was not made Uncommitted.
			}
		}
		return true
	case .Memory_Protect:
		switch {
		case v[1] == 0:
			record_set(record, .Too_Small, .Records, 2, 0, 1, 0)
		case v[1] > op.RANGE_TABLE_CAPACITY:
			record_set(record, .Too_Long, .Records, 2, v[1], op.RANGE_TABLE_CAPACITY, 0)
		case v[2] & ~u64(0b111) != 0:
			record_set(record, .Bad_Flags, .None, 3, v[2], 0b111, 0)
		case:
			// The entries that the call changes, as the kernel counts them:
			// one for each large page, the present pages of a whole mapping.
			if pages := read_protect_walk(program, v[0], v[1]); pages > op.RANGE_TABLE_PAGE_LIMIT {
				record_set(record, .Too_Long, .Pages, 1, pages, op.RANGE_TABLE_PAGE_LIMIT, 0)
			} else {
				// Write and Execute together; No_Access with another flag;
				// more than the mapping was made with; a part asks more than
				// its mapping has now.
				record_set(record, .Bad_Value, .None, 3, v[2], 0, 0)
			}
		}
		return true
	case .Thread_Control:
		// A refused write: the value and the part that the check refused, as
		// the operation kept them on this processor from its own copy. The
		// command itself is a choice, below. A weight, a request and a
		// weight limit have a largest value, which the operation kept too:
		// for a weight it is the weight limit that the thread had then.
		if cpu := processor_self(); cpu.thread_write_refusal != .None {
			record_set(record, .Bad_Value, .None, 4, cpu.thread_write_refused_value, cpu.thread_write_refused_limit, u64(cpu.thread_write_refusal))
			return true
		}
	case .Fault_Handler_Set:
		switch {
		case v[1] > 1:
			record_set(record, .Bad_Value, .None, 2, v[1], 1, 0)
		case v[1] == 1:
			record_set(record, .Bad_Flags, .None, 3, v[2], 0, 0) // The end of the delivery takes no kinds.
		case:
			record_set(record, .Bad_Flags, .None, 3, v[2], op.FAULT_KINDS_DELIVERED, 0)
		}
		return true
	case .Thread_Create:
		// The most of a weight is the weight limit of the calling thread,
		// which is the full weight unless the holder of the machine
		// lowered it.
		weight_limit := u64(intrinsics.atomic_load(&threads[processor_self().current].weight_limit))
		switch {
		case v[4] > weight_limit:
			record_set(record, .Bad_Value, .None, 5, v[4], weight_limit, 0)
		case v[5] > op.REQUEST_LIMIT:
			record_set(record, .Bad_Value, .None, 6, v[5], op.REQUEST_LIMIT, 0)
		case:
			return false
		}
		return true
	}
	for parameter, n in form.parameters {
		if parameter.form == .Choice && (v[n] > parameter.limit || v[n] == 0 && operation != .Log) {
			record_set(record, .Bad_Value, .None, n + 1, v[n], parameter.limit, 0)
			return true
		}
	}
	return false
}

// stack_trace writes the stack trace of a thread that faulted: frame 0 is
// the instruction; each next frame is the return address that the frame
// pointer names. The program is the one of this processor: its page table
// is the one in use, so read_user reads its stack (the program lock). It
// runs on the path of the stop of a program on a fault.
stack_trace :: proc "contextless" (program: ^Program, frame: ^Frame, report: ^op.Stop_Report) {
	add :: proc "contextless" (program: ^Program, report: ^op.Stop_Report, address: u64) {
		item := &report.frames[report.frame_count]
		item.address = address
		if found := module_of(program, address); found != nil {
			item.base, item.hash = found.base, found.hash
		}
		report.frame_count += 1
	}
	report.frame_count = 0
	add(program, report, frame.rip)
	at := frame.rbp
	for report.frame_count < op.STOP_FRAME_CAPACITY {
		pair: [2]u64 // The frame pointer of the caller, then the return address.
		if at == 0 || at % 8 != 0 || !read_user(program, at, &pair, 16) {
			break
		}
		if pair[1] == 0 {
			break
		}
		add(program, report, pair[1])
		if pair[0] <= at {
			break
		}
		at = pair[0]
	}
}
