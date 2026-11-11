package kernel

import "base:intrinsics"
import "contract:errors"
import op "contract:operation"
import "contract:ring"

// The error record of a kernel operation that failed, and the stack trace
// of a fault (docs/MODULE_CONTRACT.md, section 8).
//
// The kernel finds the record after the operation failed: the operations
// do not change, and an operation that succeeds runs no code of this file.
// The record comes from the forms of the parameters (op.OPERATIONS), read
// in their order, as the operation reads them. It describes what the
// caller gave and its own handles: the amounts of a budget and the state
// of a program only when the handle has the right Read (P20).
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
// amount (P20).
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
// with the right Read (P20); held is false otherwise. Lock: the program lock
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
		return kind == .Handle_Absent || kind == .Handle_Ended || kind == .Handle_Kind || kind == .No_Target
	case .No_Right:
		return kind == .Handle_Rights
	case .No_Budget:
		return kind == .Budget || kind == .Budget_Hidden || kind == .Over_Limit
	case .Bad_Address:
		return kind == .Bad_Address || kind == .Too_Long || kind == .Too_Small || kind == .Overlap || kind == .Absent
	case .No_Slot:
		return kind == .Full || kind == .Too_Long
	case .Bad_State:
		return kind == .State
	case .Bad_Operation:
		return kind == .Bad_Flags || kind == .Bad_Value || kind == .Too_Small || kind == .Too_Long || kind == .Unknown_Operation
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
		explained = value_explain(&record, operation, v)
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
		}
		if handle_explain(record, program, n + 1, v[n], kind, rights) {
			return true
		}
	}
	return false
}

// budget_ask gives what an operation asks of a budget, and what the budget
// holds of it.
@(private = "file")
budget_explain :: proc "contextless" (record: ^errors.Error_Record, program: ^Program, operation: op.Operation, v: [7]u64) -> bool {
	if operation == .Log {
		// The limit of the budget of the program. Its counts only with a
		// handle with Read (P20); a budget above it is never described: when
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
	if operation != .Memory_Create && operation != .Program_Create && operation != .Thread_Create && operation != .Budget_Create {
		return false
	}
	holds, rights, found := read_budget(program, v[0], operation)
	if !found {
		return false
	}
	// Without Read the record depends on the operation alone (P20).
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
		if v[2] > 4096 {
			record_set(record, .Too_Long, .Bytes, 3, v[2], 4096, 0)
		} else if !read_range(program, v[1], v[2]) {
			record_set(record, .Bad_Address, .Bytes, 2, v[1], v[2], 0)
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
		if kind == .Pages && v[2] != 0 {
			// Pages gives the pages of the program that asks only: index 0.
			record_set(record, .Bad_Value, .None, 3, v[2], 0, 0)
		} else if v[4] < size {
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
		// give (P20): Refused. The areas and the mappings of another program
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
	case .Memory_Map:
		argument = 2
	case .Memory_Unmap, .Program_Start, .Program_Module, .Handle_Give:
		argument = 1
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
value_explain :: proc "contextless" (record: ^errors.Error_Record, operation: op.Operation, v: [7]u64) -> bool {
	form := &op.OPERATIONS[operation]
	#partial switch operation {
	case .Memory_Create:
		switch {
		case v[2] & ~u64(0b11) != 0:
			record_set(record, .Bad_Flags, .None, 3, v[2], 0b11, 0)
		case v[1] == 0:
			record_set(record, .Too_Small, .Pages, 2, 0, 1, 0)
		case:
			record_set(record, .Too_Long, .Pages, 2, v[1], op.MEMORY_PAGE_LIMIT, 0)
		}
		return true
	case .Memory_Map:
		record_set(record, .Bad_Value, .None, 4, v[3], 0, 0) // Write and Execute: no page is both.
		return true
	case .Thread_Create:
		switch {
		case v[4] > op.WEIGHT_FULL:
			record_set(record, .Bad_Value, .None, 5, v[4], op.WEIGHT_FULL, 0)
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
