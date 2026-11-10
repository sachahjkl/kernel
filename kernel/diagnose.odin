package kernel

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
// copies what it reads, and names the lock that protects it in the table
// "Locks of the kernel" of docs/ARCHITECTURE.md. With one kernel lock they
// take no lock. With a lock for each kind of data, another thread can change
// the state between the failure and the record: then the record describes
// what the kernel reads now, and `diagnose` keeps a record only if its kind
// can explain the status (`kind_explains`); else the record is Refused with
// the status. A record never contradicts its status.

// read_handle copies the slot of a handle of a program. Lock: the program
// lock of the caller.
@(private = "file")
read_handle :: proc "contextless" (program: ^Program, index: u64) -> Handle_Slot {
	return program.handles[index]
}

// read_handle_find is handle_find on a copy of the slot. ok: the handle
// names an object of the kind with the rights.
@(private = "file")
read_handle_find :: proc "contextless" (program: ^Program, handle: u64, kind: Object_Kind, rights: op.Rights = {}) -> (slot: Handle_Slot, ok: bool) {
	index := handle & 0xFFFF
	if index == 0 || index >= HANDLE_CAPACITY || handle >> 32 != 0 {
		return {}, false
	}
	slot = read_handle(program, index)
	if slot.kind == .None || u64(slot.generation) != handle >> 16 || kind != .None && slot.kind != kind || !(rights <= slot.rights) {
		return {}, false
	}
	return slot, true
}

// read_free_handles counts the free places of the handle table of a
// program. Lock: the program lock.
@(private = "file")
read_free_handles :: proc "contextless" (program: ^Program) -> (count: u64) {
	for slot in program.handles[1:] {
		count += u64(slot.kind == .None)
	}
	return count
}

// read_user copies memory of the program that runs, if it can read it.
// Lock: the program lock of the caller (user_range and user_copy).
@(private = "file")
read_user :: proc "contextless" (program: ^Program, address: u64, destination: rawptr, size: u64) -> bool {
	if !user_range(program, address, size, false) {
		return false
	}
	user_copy(destination, rawptr(uintptr(address)), size)
	return true
}

// read_range says if the program can read a range of its memory. Lock: the
// program lock.
@(private = "file")
read_range :: proc "contextless" (program: ^Program, address: u64, size: u64) -> bool {
	return user_range(program, address, size, false)
}

// read_word says if a program can wait on a word. Lock: the program lock.
@(private = "file")
read_word :: proc "contextless" (program: ^Program, address: u64) -> bool {
	return word_address(program, address) != 0
}

// read_budget copies the amounts of a budget. Lock: the frame lock for the
// pages, the control lock for the other amounts.
@(private = "file")
read_budget :: proc "contextless" (index: u32) -> op.Budget_Amounts {
	return budgets[index].amounts
}

// read_log_count gives the log records of a budget in this second, and its
// limit. Atomic counts, and the control lock for the limit.
@(private = "file")
read_log_count :: proc "contextless" (index: u32) -> (logged, limit: u64) {
	return budgets[index].logged, budgets[index].amounts.log_records
}

// read_region_pages gives the pages of a memory object. Lock: the frame
// lock (the slot of the object).
@(private = "file")
read_region_pages :: proc "contextless" (index: u32) -> u64 {
	return regions[index].page_count
}

// read_program_state gives the state of another program. Lock: the control
// lock.
@(private = "file")
read_program_state :: proc "contextless" (index: u32) -> op.Program_State {
	return program_state(index)
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
		case slot.kind == .None && u64(slot.generation) == generation + 1:
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
		// The limit of the budget of the program, or of a budget above it.
		logged, limit := read_log_count(program.budget)
		record_set(record, .Over_Limit, .Log_Records, 0, logged + 1, limit, 0)
		return true
	}
	if operation != .Memory_Create && operation != .Program_Create && operation != .Thread_Create && operation != .Budget_Create {
		return false
	}
	slot, found := read_handle_find(program, v[0], .Budget, {.Spend})
	if !found {
		return false
	}
	holds := read_budget(slot.object)
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
	if .Read not_in slot.rights {
		record_set(record, .Budget_Hidden, unit, argument, v[0], asked, 0)
	} else {
		record_set(record, .Budget, unit, argument, v[0], asked, held)
	}
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
}

@(private = "file")
address_explain :: proc "contextless" (record: ^errors.Error_Record, program: ^Program, operation: op.Operation, v: [7]u64) -> bool {
	#partial switch operation {
	case .Log:
		if v[2] > 4096 {
			record_set(record, .Too_Long, .Bytes, 3, v[2], 4096, 0)
		} else {
			record_set(record, .Bad_Address, .Bytes, 2, v[1], v[2], 0)
		}
	case .Program_Create:
		if v[2] > 31 {
			record_set(record, .Too_Long, .Bytes, 3, v[2], 31, 0)
		} else {
			record_set(record, .Bad_Address, .Bytes, 2, v[1], v[2], 0)
		}
	case .Program_State:
		record_set(record, .Bad_Address, .Bytes, 2, v[1], size_of(op.Stop_Report), 1)
	case .Program_Module:
		module: op.Module_Record
		if !read_user(program, v[1], &module, size_of(module)) {
			record_set(record, .Bad_Address, .Bytes, 2, v[1], size_of(op.Module_Record), 0)
			return true
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
			read_user(program, v[0] + index * size_of(op.Word), &word, size_of(op.Word))
			if !read_word(program, word.address) {
				record_set(record, .Bad_Address, .Bytes, 1, word.address, 4, 0)
				return true
			}
		}
		return false
	case .Word_Wake:
		record_set(record, .Bad_Address, .Bytes, 1, v[0], 4, 0)
	case .Inspect:
		kind := op.Inspect_Kind(v[1])
		size := kind <= max(op.Inspect_Kind) ? INSPECT_SIZES[kind] : 0
		if v[4] < size {
			record_set(record, .Too_Small, .Bytes, 5, v[4], size, 0)
		} else {
			record_set(record, .Bad_Address, .Bytes, 4, v[3], size, 1)
		}
	case .Memory_Map:
		slot, found := read_handle_find(program, v[0], .Memory)
		if !found {
			return false
		}
		page_count := read_region_pages(slot.object)
		count := v[5] == 0 && v[4] < page_count ? page_count - v[4] : v[5]
		switch {
		case v[4] >= page_count:
			record_set(record, .Too_Long, .Pages, 5, v[4], page_count - 1, 0)
		case count > page_count - v[4]:
			record_set(record, .Too_Long, .Pages, 6, count, page_count - v[4], 0)
		case v[2] != 0 && (v[2] % PAGE_SIZE != 0 || v[2] < PAGE_SIZE || v[2] >= USER_END || count * PAGE_SIZE > USER_END - v[2]):
			record_set(record, .Bad_Address, .Bytes, 3, v[2], count * PAGE_SIZE, 0)
		case:
			record_set(record, .Overlap, .Bytes, 3, v[2], count * PAGE_SIZE, 0) // The addresses of another mapping.
		}
	case .Memory_Unmap:
		record_set(record, .Absent, .Bytes, 2, v[1], 0, 0) // No mapping starts at this address.
	case:
		return false
	}
	return true
}

@(private = "file")
slot_explain :: proc "contextless" (record: ^errors.Error_Record, program: ^Program, operation: op.Operation, v: [7]u64) -> bool {
	free_handles := read_free_handles(program)
	#partial switch operation {
	case .Word_Wait:
		thread_words: u64 = op.WORD_WAIT_CAPACITY
		record_set(record, .Too_Long, .Words, 2, v[1], thread_words, 0)
		return true
	case .Memory_Map:
		record_set(record, .Full, .Mappings, 0, 0, MAPPING_CAPACITY, 0)
		return true
	case .Program_Module:
		record_set(record, .Full, .Modules, 0, 0, op.PROGRAM_MODULE_CAPACITY, 0)
		return true
	case .Handle_Give:
		record_set(record, .Full, .Handles, 1, v[0], HANDLE_CAPACITY - 1, 0) // The table of the target.
		return true
	}
	if free_handles == 0 {
		record_set(record, .Full, .Handles, 0, 0, HANDLE_CAPACITY - 1, 0)
		return true
	}
	#partial switch operation {
	case .Memory_Create:
		record_set(record, .Full, .Memory, 0, 0, REGION_CAPACITY - 1, 0)
	case .Program_Create:
		record_set(record, .Full, .Programs, 0, 0, PROGRAM_CAPACITY - 1, 0)
	case .Thread_Create, .Program_Start:
		record_set(record, .Full, .Threads, 0, 0, op.THREAD_CAPACITY, 0)
	case .Budget_Create:
		record_set(record, .Full, .Budgets, 0, 0, BUDGET_CAPACITY - 1, 0)
	case .Device_Create:
		record_set(record, .Full, .Interrupts, 0, 0, op.MESSAGE_CAPACITY, 0)
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
	slot, held := read_handle_find(program, handle, .None)
	if !held {
		return false
	}
	found: u64
	if slot.kind == .Program && .Read in slot.rights {
		found = u64(read_program_state(slot.object))
	}
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
