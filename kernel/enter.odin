package kernel

import "contract:ring"
import "base:intrinsics"
import op "contract:operation"

// K4: the kernel entry. It executes the command records of the kernel ring
// of the program, then makes the program wait if it asked for that.


enter :: proc "contextless" (index: u32) {
	thread := &threads[index]
	intrinsics.atomic_add(&programs[thread.program].entries, 1)
	thread.in_enter = true
	wait_begin(thread)
	for _ in 0 ..< ring.CAPACITY {
		command, ok := ring.pop(&thread.ring.commands)
		if !ok {
			break
		}
		completion := ring.Record{tag = command.tag}
		status := command_run(index, command, &completion.values)
		// The operation can end the thread: then it does nothing more.
		if intrinsics.atomic_load(&thread.stop_requested) {
			return
		}
		completion.kind = u32(status)
		if status != .Ok {
			// The error record: the values of a failed operation (diagnose.odin).
			completion.values = transmute([7]u64)diagnose(thread.program, command, status)
		}
		ring.push(&thread.ring.completions, completion)
	}
	// A word that changed before the wait: the thread reads it again.
	wait_end(thread, thread.frame.rdi)
}

// command_run executes one command under the program lock of the caller.
// An operation that touches another program, or ends an object that other
// programs name, needs the control lock (docs/ARCHITECTURE.md, "Locks of
// the kernel"): it asks for it before it changes anything, and runs again
// with it.
command_run :: proc "contextless" (index: u32, command: ring.Record, results: ^[7]u64) -> op.Status {
	cpu := processor_self()
	cpu.retry = false
	cpu.operation = true
	status := execute_locked(index, command, results)
	if cpu.retry || status == STATUS_RETRY {
		cpu.retry = false
		results^ = {}
		control_take()
		cpu.control = true
		status = execute_locked(index, command, results)
		cpu.control = false
		control_free()
	}
	cpu.operation = false
	stop_wait(cpu)
	return status
}

// stop_wait waits, with no lock held, until each thread that this
// operation stopped on another processor left it: after Thread_Stop or
// Program_Stop, no thread of what stopped runs an instruction (choice 18).
// The wait ends at once if the current thread is stopped too: two threads
// that stop each other do not wait for each other.
stop_wait :: proc "contextless" (cpu: ^Processor) {
	self := &threads[cpu.current]
	if cpu.stopped_thread != 0 {
		thread := &threads[cpu.stopped_thread]
		for intrinsics.atomic_load(&thread.serial) == cpu.stopped_thread_serial && intrinsics.atomic_load(&thread.processor) != 0 && !intrinsics.atomic_load(&self.stop_requested) {
			sync_acknowledge(cpu)
			intrinsics.cpu_relax()
		}
		cpu.stopped_thread = 0
	}
	for cpu.stopped_programs != 0 {
		index := u32(intrinsics.count_trailing_zeros(cpu.stopped_programs))
		cpu.stopped_programs &~= 1 << index
		program := &programs[index]
		for intrinsics.atomic_load(&program.serial) == cpu.stopped_serials[index] && intrinsics.atomic_load(&program.holds) & (HOLDS_STOPPED - 1) != 0 && !intrinsics.atomic_load(&self.stop_requested) {
			sync_acknowledge(cpu)
			intrinsics.cpu_relax()
		}
	}
}

execute_locked :: proc "contextless" (index: u32, command: ring.Record, results: ^[7]u64) -> op.Status {
	program_index := threads[index].program
	taken := program_lock(program_index)
	defer program_unlock(program_index, taken)
	return execute(index, command, results)
}

// need_control says if the operation must run again with the control lock.
need_control :: proc "contextless" () -> bool {
	cpu := processor_self()
	if cpu.control {
		return false
	}
	cpu.retry = true
	return true
}

// target_lock gives the program that a program handle with the right
// Control names, with its lock (0 names the caller). The caller holds the
// control lock when the handle is not 0.
target_lock :: proc "contextless" (program: ^Program, handle: u64) -> (to: ^Program, taken: bool, status: op.Status) {
	if handle == 0 {
		return program, false, .Ok
	}
	slot := handle_find(program, handle, .Program, {.Control}) or_return
	return &programs[slot.object], program_lock(slot.object), .Ok
}

// execute runs one operation. The caller holds the program lock of the
// program of the thread, and the control lock if the operation asked for it.
execute :: proc "contextless" (index: u32, command: ring.Record, results: ^[7]u64) -> op.Status {
	program_index := threads[index].program
	program := &programs[program_index]
	v := command.values

	switch op.Operation(command.kind) {
	case .None:
		return .Ok

	case .Log:
		_ = handle_find(program, v[0], .Log, {.Write}) or_return
		if v[2] > 4096 || !user_range(program, v[1], v[2], false) {
			return .Bad_Address
		}
		if v[3] > u64(max(op.Log_Level)) {
			return .Bad_Operation
		}
		if !budget_log(program.budget) {
			return .No_Budget
		}
		// The channel: the characters before the first one that is not a
		// character of a text.
		channel := transmute([op.LOG_CHANNEL_CAPACITY]u8)[2]u64{v[4], v[5]}
		channel_count := 0
		for channel_count < len(channel) && channel[channel_count] > ' ' && channel[channel_count] < 127 {
			channel_count += 1
		}
		name := transmute([]u8)program_name(program)
		log_text := &processor_self().log_text
		user_copy(log_text, rawptr(uintptr(v[1])), v[2])
		taken := log_take()
		defer log_free(taken)
		log_bytes({'['})
		log_bytes(name)
		if channel_count != 0 {
			log_bytes({':'})
			log_bytes(channel[:channel_count])
		}
		log_bytes({']', ' '})
		log_bytes(log_text[:v[2]])
		log_bytes({'\r', '\n'})
		log_record(program_index, index, name, channel[:channel_count], op.Log_Level(v[3]), log_text[:v[2]])
		return .Ok

	case .Memory_Create:
		budget := handle_find(program, v[0], .Budget, {.Spend}) or_return
		flags := transmute(op.Memory_Flags)v[2]
		if flags - {.Frames_Now, .Contiguous, .Uncommitted, .Large_Pages} != {} {
			return .Bad_Operation
		}
		// An uncommitted object has its pages paid later: no frame now, and
		// a frame list. A large-page object is contiguous, of whole large pages.
		if .Uncommitted in flags && flags != {.Uncommitted} || .Large_Pages in flags && v[1] % op.LARGE_PAGE_PAGES != 0 {
			return .Bad_Operation
		}
		large_pages := .Large_Pages in flags
		region := region_create(budget.object, v[1], contiguous = .Contiguous in flags || large_pages, now = .Frames_Now in flags, uncommitted = .Uncommitted in flags, large_pages = large_pages) or_return
		handle := handle_insert(program, {kind = .Memory, rights = RIGHTS_MEMORY, object = region})
		if handle == 0 {
			regions[region].references = 1
			region_release(region)
			return .No_Slot
		}
		results[0] = u64(handle)
		return .Ok

	case .Memory_Map:
		flags := transmute(op.Map_Flags)v[3]
		needed := op.Rights{.Read}
		if .Write in flags {
			needed += {.Write}
		}
		if .Execute in flags {
			needed += {.Execute}
		}
		slot := handle_find(program, v[0], .Memory, needed) or_return
		if v[1] != 0 && need_control() {
			return STATUS_RETRY
		}
		to, taken := target_lock(program, v[1]) or_return
		defer program_unlock(index_of_program(to), taken)
		if to.state == .None || to.state == .Stopped {
			return .Bad_State
		}
		address, status := map_region(to, slot.object, v[2], flags, v[4], v[5], holding_of_handle(program, slot))
		results[0] = address
		return status

	case .Memory_Unmap:
		if v[0] != 0 && need_control() {
			return STATUS_RETRY
		}
		to, taken := target_lock(program, v[0]) or_return
		defer program_unlock(index_of_program(to), taken)
		if to.state == .None || to.state == .Stopped {
			return .Bad_State
		}
		for &mapping in to.mappings {
			if mapping.page_count != 0 && mapping.address == v[1] && mapping.address < op.THREAD_AREA_BASE {
				unmap(to, &mapping)
				return .Ok
			}
		}
		return .Bad_Address

	case .Memory_Size:
		slot := handle_find(program, v[0], .Memory) or_return
		results[0] = regions[slot.object].page_count
		return .Ok

	case .Program_Create:
		if need_control() {
			return STATUS_RETRY
		}
		budget := handle_find(program, v[0], .Budget, {.Spend}) or_return
		if v[2] > 31 || !user_range(program, v[1], v[2], false) {
			return .Bad_Address
		}
		name: [32]u8
		user_copy(&name, rawptr(uintptr(v[1])), v[2])
		created := program_create(budget.object, name[:v[2]]) or_return
		handle := handle_insert(program, {kind = .Program, rights = RIGHTS_PROGRAM, object = created})
		if handle == 0 {
			program_stop(created, 0)
			return .No_Slot
		}
		results[0] = u64(handle)
		return .Ok

	case .Program_Start:
		if need_control() {
			return STATUS_RETRY
		}
		slot := handle_find(program, v[0], .Program, {.Control}) or_return
		to := &programs[slot.object]
		taken := program_lock(slot.object)
		defer program_unlock(slot.object, taken)
		if to.state != .Created {
			return .Bad_State
		}
		if _, status := thread_create(slot.object, to.budget, v[1], v[2], v[3]); status != .Ok {
			return status
		}
		to.state = .Ready
		return .Ok

	case .Thread_Create:
		if need_control() {
			return STATUS_RETRY
		}
		budget := handle_find(program, v[0], .Budget, {.Spend}) or_return
		// A weight above the full weight would raise the share (P20).
		if v[4] > op.WEIGHT_FULL || v[5] > op.REQUEST_LIMIT {
			return .Bad_Operation
		}
		created := thread_create(program_index, budget.object, v[1], v[2], v[3], v[4], v[5]) or_return
		handle := handle_insert(program, {kind = .Thread, rights = RIGHTS_THREAD, object = created})
		if handle == 0 {
			thread_stop(created)
			return .No_Slot
		}
		results[0] = u64(handle)
		return .Ok

	case .Thread_Stop:
		if need_control() {
			return STATUS_RETRY
		}
		if v[0] == 0 {
			thread_stop(index)
			return .Ok
		}
		slot := handle_find(program, v[0], .Thread, {.Control}) or_return
		thread_stop(slot.object)
		return .Ok

	case .Thread_State:
		slot := handle_find(program, v[0], .Thread, {.Read}) or_return
		results[0] = u64(intrinsics.atomic_load(&threads[slot.object].state))
		return .Ok

	case .Program_Stop:
		if need_control() {
			return STATUS_RETRY
		}
		to, taken := target_lock(program, v[0]) or_return
		program_unlock(index_of_program(to), taken)
		program_stop(index_of_program(to), u32(v[1]))
		return .Ok

	case .Program_State:
		if need_control() {
			return STATUS_RETRY
		}
		slot := handle_find(program, v[0], .Program, {.Read}) or_return
		taken := program_lock(slot.object)
		defer program_unlock(slot.object, taken)
		results[0] = u64(program_state(slot.object))
		results[1] = u64(programs[slot.object].code)
		results[2] = programs[slot.object].entries
		if v[1] != 0 {
			if !user_range(program, v[1], size_of(op.Stop_Report), true) {
				return .Bad_Address
			}
			user_copy(rawptr(uintptr(v[1])), &programs[slot.object].stop, size_of(op.Stop_Report))
		}
		return .Ok

	case .Handle_Give:
		// A copy in this program needs no Give right: no other program receives it.
		given := handle_find(program, v[1], .None, v[0] == 0 ? op.Rights{} : op.Rights{.Give}) or_return
		if (v[0] != 0 || given.kind == .Ports || given.kind == .Interrupt) && need_control() {
			return STATUS_RETRY
		}
		to: ^Program
		through: u64
		to_slot: ^Handle_Slot
		if v[0] == 0 {
			to = program
			to_slot = given
		} else {
			to_slot = handle_find(program, v[0], .None) or_return
		}
		#partial switch v[0] == 0 ? Object_Kind.None : to_slot.kind {
		case .Program:
			if .Control not_in to_slot.rights {
				return .No_Right
			}
			to = &programs[to_slot.object]
		case .Memory:
			find: for &other, other_index in programs[1:] {
				other_taken := program_lock(u32(other_index + 1))
				maps := &other != program && other.state != .None && other.state != .Stopped && maps_region(&other, to_slot.object)
				program_unlock(u32(other_index + 1), other_taken)
				if maps {
					to = &other
					break find
				}
			}
			if to == nil {
				// No other program maps the memory yet: the one other
				// program that holds a handle to it. Two holders: no target.
				for &other, other_index in programs[1:] {
					other_taken := program_lock(u32(other_index + 1))
					holds := &other != program && other.state != .None && other.state != .Stopped && holds_region(&other, to_slot.object)
					program_unlock(u32(other_index + 1), other_taken)
					if !holds {
						continue
					}
					if to != nil {
						return .Bad_Handle
					}
					to = &other
				}
			}
			through = regions[to_slot.object].serial
		}
		if to == nil {
			return .Bad_Handle
		}
		to_taken := program_lock(index_of_program(to))
		defer program_unlock(index_of_program(to), to_taken)
		if to.state == .None || to.state == .Stopped {
			return .Bad_State
		}
		// An object with marks of protection of a part is not given: the marks
		// would reach the mapping of the other program.
		if given.kind == .Memory && to != program && intrinsics.atomic_load(&regions[given.object].marked_pages) != 0 {
			return .Bad_State
		}
		copy := given^
		copy.rights &= transmute(op.Rights)u32(v[2])
		copy.through = through
		handle := handle_insert(to, copy)
		if handle == 0 {
			return .No_Slot
		}
		if !origin_attach(holding_of_handle(to, &to.handles[u32(handle) & 0xFFFF]), holding_of_handle(program, given)) {
			handle_insert_undo(to, handle)
			return STATUS_RETRY
		}
		results[0] = u64(handle)
		return .Ok

	case .Handle_Revoke:
		if need_control() {
			return STATUS_RETRY
		}
		slot := handle_find(program, v[0], .None) or_return
		only: u32
		if v[1] != 0 {
			in_program := handle_find(program, v[1], .Program, {.Control}) or_return
			only = in_program.object
		}
		results[0] = revoke(holding_of_handle(program, slot), program_index, only)
		return .Ok

	case .Program_Module:
		if v[0] != 0 && need_control() {
			return STATUS_RETRY
		}
		to, taken := target_lock(program, v[0]) or_return
		defer program_unlock(index_of_program(to), taken)
		if to.state == .None || to.state == .Stopped {
			return .Bad_State
		}
		if !user_range(program, v[1], size_of(op.Module_Record), false) {
			return .Bad_Address
		}
		record: op.Module_Record
		user_copy(&record, rawptr(uintptr(v[1])), size_of(record))
		return program_module(to, record)

	case .Handle_Close:
		slot := handle_find(program, v[0], .None) or_return
		if handle_needs_control(slot.kind) && need_control() {
			return STATUS_RETRY
		}
		handle_close(program, slot)
		return .Ok

	case .Budget_Create:
		if need_control() {
			return STATUS_RETRY
		}
		from := handle_find(program, v[0], .Budget, {.Spend}) or_return
		created := budget_create(from.object, {pages = v[1], programs = v[2], threads = v[3], processor = v[4], log_records = v[5]}) or_return
		handle := handle_insert(program, {kind = .Budget, rights = RIGHTS_BUDGET, object = created})
		if handle == 0 {
			budgets[created].references = 1
			budget_release(created)
			return .No_Slot
		}
		results[0] = u64(handle)
		return .Ok

	case .Handle_State:
		slot := handle_find(program, v[0], .None) or_return
		results[0] = u64(slot.kind)
		results[1] = u64(transmute(u32)slot.rights)
		if v[1] != 0 {
			memory := handle_find(program, v[1], .Memory) or_return
			results[2] = u64(slot.through != 0 && slot.through == regions[memory.object].serial)
		}
		results[3] = origin_count(holding_of_handle(program, slot))
		return .Ok

	case .Budget_Read:
		slot := handle_find(program, v[0], .Budget, {.Read}) or_return
		amounts := budgets[slot.object].amounts
		results[0] = amounts.pages
		results[1] = amounts.programs
		results[2] = amounts.threads
		results[3] = amounts.processor
		results[4] = amounts.log_records
		results[5] = microseconds(budgets[slot.object].spent_total)
		results[6] = budgets[slot.object].refused
		return .Ok

	case .Word_Wait:
		thread := &threads[index]
		if v[1] > u64(op.WORD_WAIT_CAPACITY - thread.word_count) {
			return .No_Slot
		}
		if !user_range(program, v[0], v[1] * size_of(op.Word), false) {
			return .Bad_Address
		}
		for index in 0 ..< v[1] {
			word: op.Word
			user_copy(&word, rawptr(uintptr(v[0] + index * size_of(op.Word))), size_of(op.Word))
			physical := word_address(program, word.address)
			if physical == 0 {
				thread.word_changed = true // The wait cannot end by this word: do not wait.
				return .Bad_Address
			}
			if !wait_register(thread, physical, u32(word.value)) {
				thread.word_changed = true
			}
		}
		return .Ok

	case .Word_Wake:
		word := word_address(program, v[0])
		if word == 0 {
			return .Bad_Address
		}
		results[0] = word_wake(word, v[1])
		return .Ok

	case .Interrupt_Read:
		slot := handle_find(program, v[0], .Interrupt, {.Read}) or_return
		results[0] = u64(intrinsics.atomic_exchange(&interrupt_pending[slot.object], 0))
		return .Ok

	case .Device_Create:
		_ = handle_find(program, v[0], .Machine, {.Devices}) or_return
		if need_control() {
			return STATUS_RETRY
		}
		slot: Handle_Slot
		switch op.Device_Kind(v[1]) {
		case .Ports:
			if v[2] >= 65536 || v[3] == 0 || v[3] > 65536 - v[2] {
				return .Bad_Address
			}
			slot = {kind = .Ports, rights = RIGHTS_PORTS, object = u32(v[2]), count = u32(v[3])}
		case .Interrupt:
			if v[2] == 0 || v[2] >= INTERRUPT_LINES {
				return .Bad_Address
			}
			slot = {kind = .Interrupt, rights = RIGHTS_INTERRUPT, object = u32(v[2])}
		case .Memory:
			if !device_range(v[2], v[3]) {
				return .Bad_Address
			}
			region := region_device(v[2], v[3])
			if region == 0 {
				return .No_Slot
			}
			regions[region].uncached = true
			handle := handle_insert(program, {kind = .Memory, rights = {.Give, .Read, .Write}, object = region})
			if handle == 0 {
				regions[region].references = 1
				region_release(region)
				return .No_Slot
			}
			results[0] = u64(handle)
			return .Ok
		case .Message:
			message := u32(INTERRUPT_CAPACITY)
			for candidate in u32(INTERRUPT_LINES) ..< INTERRUPT_CAPACITY {
				if interrupt_references[candidate] == 0 {
					message = candidate
					break
				}
			}
			if message == INTERRUPT_CAPACITY {
				return .No_Slot
			}
			interrupt_pending[message] = 0
			handle := handle_insert(program, {kind = .Interrupt, rights = RIGHTS_INTERRUPT, object = message})
			if handle == 0 {
				return .No_Slot
			}
			// The first processor receives each message: the address names
			// its interrupt controller, the value is the vector.
			results[0] = u64(handle)
			results[1] = 0xFEE0_0000 | u64(processors[0].apic_id & 0xFF) << 12
			results[2] = u64(VECTOR_MESSAGE_BASE + message - INTERRUPT_LINES)
			return .Ok
		case .None:
			return .Bad_Operation
		case:
			return .Bad_Operation
		}
		handle := handle_insert(program, slot)
		if handle == 0 {
			return .No_Slot
		}
		results[0] = u64(handle)
		return .Ok

	case .Inspect:
		_ = handle_find(program, v[0], .Machine, {.Inspect}) or_return
		switch op.Inspect_Kind(v[1]) {
		case .System:
			if v[4] < size_of(op.System_Report) || !user_range(program, v[3], size_of(op.System_Report), true) {
				return .Bad_Address
			}
			report := op.System_Report {
				time          = intrinsics.atomic_load(&time_milliseconds),
				page_count    = frame_count,
				program_slots = PROGRAM_CAPACITY,
				processors    = u64(processor_count),
				locks         = lock_counts_sum(),
				strategy      = intrinsics.atomic_load(&strategy_chosen),
				strategy_changes = u32(intrinsics.atomic_load(&strategy_changes)),
			}
			// One section of the frame lock: the free pages are the pages of
			// the budgets and the reserved pages, at this moment.
			lock_take(&frame_lock, .Frame)
			report.free_pages, report.reserved_pages = frames_counted() // With the frame caches.
			for budget in budgets {
				report.budget_pages += budget.amounts.pages
			}
			lock_free(&frame_lock, .Frame)
			for cpu in processors[:processor_count] {
				report.entries += intrinsics.volatile_load(&cpu.entries)
				report.interrupts += intrinsics.volatile_load(&cpu.interrupts)
				report.first_use_faults += intrinsics.volatile_load(&cpu.first_use_faults)
			}
			for region in regions {
				if region.page_count != 0 {
					report.region_count += 1
				}
			}
			user_copy(rawptr(uintptr(v[3])), &report, size_of(report))
			results[0] = size_of(op.System_Report)
		case .Program:
			if v[4] < size_of(op.Program_Report) || !user_range(program, v[3], size_of(op.Program_Report), true) {
				return .Bad_Address
			}
			// Another program: under its lock, with the control lock.
			if need_control() {
				return STATUS_RETRY
			}
			report: op.Program_Report
			if v[2] != 0 && v[2] < PROGRAM_CAPACITY {
				about := &programs[v[2]]
				about_taken := program_lock(u32(v[2]))
				defer program_unlock(u32(v[2]), about_taken)
				report = {
					state        = program_state(u32(v[2])),
					thread_count = u64(about.thread_count),
					code         = about.code,
					name         = about.name,
					mapped_pages = about.mapped_pages,
					present_pages = about.state == .None || about.table == 0 ? 0 : present_pages(about),
					program_serial = u64(about.serial),
					run_time     = about.run_time,
					start_time   = about.start_time,
					entries      = about.entries,
				}
				if about.state != .None {
					report.budget = budgets[about.budget].amounts
				}
				for slot in about.handles {
					if slot.kind != .None {
						report.handle_count += 1
					}
				}
			}
			user_copy(rawptr(uintptr(v[3])), &report, size_of(report))
			results[0] = size_of(op.Program_Report)
		case .Boot:
			if v[4] < size_of(op.Boot_Report) || !user_range(program, v[3], size_of(op.Boot_Report), true) {
				return .Bad_Address
			}
			record := &processor_self().boot_report
			boot_report(record)
			user_copy(rawptr(uintptr(v[3])), record, size_of(op.Boot_Report))
			results[0] = size_of(op.Boot_Report)
		case .Mappings:
			if v[4] < size_of(op.Mapping_Report) || !user_range(program, v[3], size_of(op.Mapping_Report), true) {
				return .Bad_Address
			}
			record := &processor_self().mapping_report
			if v[2] == 0 {
				mappings_report(record, kernel_table, 256, 512)
			} else {
				mappings_report(record, program.table, 0, 256)
			}
			user_copy(rawptr(uintptr(v[3])), record, size_of(op.Mapping_Report))
			results[0] = size_of(op.Mapping_Report)
		case .Modules:
			if v[4] < size_of(op.Module_Report) || !user_range(program, v[3], size_of(op.Module_Report), true) {
				return .Bad_Address
			}
			if need_control() {
				return STATUS_RETRY
			}
			report := &processor_self().module_report
			report^ = {}
			if v[2] != 0 && v[2] < PROGRAM_CAPACITY {
				about_taken := program_lock(u32(v[2]))
				defer program_unlock(u32(v[2]), about_taken)
				if programs[v[2]].state != .None {
					report.program_serial = u64(programs[v[2]].serial)
				}
				// In the order of the addresses: the module of the program first.
				for item in programs[v[2]].modules {
					if item.size == 0 {
						continue
					}
					place := report.count
					for place > 0 && report.modules[place - 1].base > item.base {
						report.modules[place] = report.modules[place - 1]
						place -= 1
					}
					report.modules[place] = item
					report.count += 1
				}
			}
			user_copy(rawptr(uintptr(v[3])), report, size_of(op.Module_Report))
			results[0] = size_of(op.Module_Report)
		case .Processor:
			if v[4] < size_of(op.Processor_Report) || !user_range(program, v[3], size_of(op.Processor_Report), true) {
				return .Bad_Address
			}
			report: op.Processor_Report
			if v[2] < u64(processor_count) {
				cpu := processors[v[2]]
				report.busy_time = cpu.busy_time
				report.apic_id = u64(cpu.apic_id)
				// Counts that the processor writes alone, and two words of
				// its queue: read with no lock, each one whole.
				report.strategy = intrinsics.atomic_load(&run_queues[cpu.index].strategy)
				report.queued = intrinsics.atomic_load(&run_queues[cpu.index].count)
				report.picks = intrinsics.volatile_load(&cpu.picks)
				report.preemptions = intrinsics.volatile_load(&cpu.preemptions)
				report.moves = intrinsics.volatile_load(&cpu.moves)
				report.pick_cycles = intrinsics.volatile_load(&cpu.pick_cycles)
				report.interrupt_preemptions = intrinsics.volatile_load(&cpu.interrupt_preemptions)
				report.preempt_cycles = intrinsics.volatile_load(&cpu.preempt_cycles)
				report.cache_frames = u64(intrinsics.volatile_load(&cpu.frame_cache.count))
				report.cache_batches_taken = intrinsics.volatile_load(&cpu.frame_cache.batches_taken)
				report.cache_batches_given = intrinsics.volatile_load(&cpu.frame_cache.batches_given)
				report.cache_drains = intrinsics.volatile_load(&cpu.frame_cache.drains)
				if cpu.current != 0 {
					report.program = u64(threads[cpu.current].program)
					report.same = u64(programs[report.program].table == program.table)
				}
			}
			user_copy(rawptr(uintptr(v[3])), &report, size_of(report))
			results[0] = size_of(op.Processor_Report)
		case .Program_Mappings, .Threads, .Stop:
			// The reports of a developer tool (report.odin). Another program:
			// with the control lock, so that the slot keeps its program.
			kind := op.Inspect_Kind(v[1])
			size := u64(kind == .Program_Mappings ? size_of(op.Program_Mapping_Report) : kind == .Threads ? size_of(op.Thread_Table_Report) : size_of(op.Stop_Report))
			if v[4] < size || !user_range(program, v[3], size, true) {
				return .Bad_Address
			}
			if need_control() {
				return STATUS_RETRY
			}
			cpu := processor_self()
			source: rawptr
			#partial switch kind {
			case .Program_Mappings:
				program_mappings_report(&cpu.program_mapping_report, u32(min(v[2], PROGRAM_CAPACITY)))
				source = &cpu.program_mapping_report
			case .Threads:
				threads_report(&cpu.thread_table_report, u32(min(v[2], PROGRAM_CAPACITY)))
				source = &cpu.thread_table_report
			case:
				stop_report_for_inspect(&cpu.stop_report, u32(min(v[2], PROGRAM_CAPACITY)))
				source = &cpu.stop_report
			}
			user_copy(rawptr(uintptr(v[3])), source, size)
			results[0] = size
		case .Pages:
			if v[4] < size_of(op.Page_Report) || !user_range(program, v[3], size_of(op.Page_Report), true) {
				return .Bad_Address
			}
			// The program that asks only: another program is not watched page
			// by page. Its program lock is held (execute_locked).
			if v[2] != 0 {
				return .Bad_Operation
			}
			report: op.Page_Report
			user_copy(&report, rawptr(uintptr(v[3])), size_of(report))
			if report.address & (PAGE_SIZE - 1) != 0 || report.address >= op.USER_END || op.PAGE_REPORT_CAPACITY * PAGE_SIZE > op.USER_END - report.address {
				return .Bad_Operation
			}
			pages_report(&report, program)
			user_copy(rawptr(uintptr(v[3])), &report, size_of(report))
			results[0] = size_of(op.Page_Report)
		case .None:
			return .Bad_Operation
		case:
			return .Bad_Operation
		}
		return .Ok

	case .Memory_Physical:
		_ = handle_find(program, v[0], .Machine, {.Physical}) or_return
		slot := handle_find(program, v[1], .Memory, {.Read}) or_return
		if !regions[slot.object].contiguous {
			return .Bad_Operation // Its frames come at first use, from anywhere: no one address names them.
		}
		results[0] = regions[slot.object].physical
		return .Ok

	case .Memory_Commit:
		memory := handle_find(program, v[0], .Memory, {.Write}) or_return
		flags := transmute(op.Commit_Flags)v[4]
		decommit := .Decommit in flags
		// The payer: a handle to the budget of the object, with Commit or
		// Spend (docs/ARCHITECTURE.md, "Who pays a commit"). A decommit gives pages back to it, and
		// reads no budget handle.
		if !decommit {
			budget := handle_find(program, v[1], .Budget) or_return
			if budget.rights & {.Commit, .Spend} == {} {
				return .No_Right
			}
			if budget.object != intrinsics.atomic_load(&regions[memory.object].budget) {
				return .Bad_Handle
			}
		}
		if v[3] == 0 || v[3] > op.RANGE_TABLE_CAPACITY || flags - {.Decommit} != {} {
			return .Bad_Operation
		}
		if !user_range(program, v[2], v[3] * size_of(op.Page_Range), false) {
			return .Bad_Address
		}
		table := &processor_self().range_table
		user_copy(table, rawptr(uintptr(v[2])), v[3] * size_of(op.Page_Range))
		counts: [op.RANGE_TABLE_CAPACITY]u64
		for range, index in table[:v[3]] {
			counts[index] = range.page_count
		}
		if table_pages(counts[:v[3]]) > op.RANGE_TABLE_PAGE_LIMIT {
			return .Bad_Operation
		}
		changed := memory_commit(program, memory.object, table[:v[3]], decommit) or_return
		results[0] = changed
		return .Ok

	case .Memory_Protect:
		flags := transmute(op.Map_Flags)v[2]
		if v[1] == 0 || v[1] > op.RANGE_TABLE_CAPACITY || flags - {.Write, .Execute, .No_Access} != {} {
			return .Bad_Operation
		}
		if !user_range(program, v[0], v[1] * size_of(op.Address_Range), false) {
			return .Bad_Address
		}
		table := &processor_self().range_table
		user_copy(table, rawptr(uintptr(v[0])), v[1] * size_of(op.Address_Range))
		ranges := ([^]op.Address_Range)(&table[0])[:v[1]]
		changed := memory_protect(program, ranges, flags) or_return
		results[0] = changed
		return .Ok

	case .Fault_Handler_Set:
		// The fault ring (fault_ring.odin): the program names one of its
		// own threads; a pager for another program is not in this step.
		if v[1] > 1 {
			return .Bad_Operation
		}
		if v[1] == 1 {
			return fault_handler_set(program_index, 0)
		}
		handler := index
		if v[0] != 0 {
			slot := handle_find(program, v[0], .Thread, {.Control}) or_return
			handler = slot.object
		}
		return fault_handler_set(program_index, handler)

	case .Fault_Answer:
		answer := op.Fault_Answer_Kind(v[2])
		if answer != .Resume && answer != .Stop {
			return .Bad_Operation
		}
		// A stop of the program on a fault takes the control lock.
		if answer == .Stop && need_control() {
			return STATUS_RETRY
		}
		waiter_index := fault_waiter_find(program_index, v[0], v[1])
		if waiter_index == 0 {
			return .Bad_State // No thread with that number and fault serial waits: an old answer, or a wrong one.
		}
		waiter := &threads[waiter_index]
		waiter.fault_waits = false
		if answer == .Resume {
			thread_wake(waiter)
			return .Ok
		}
		// The report of the fault, as with no handler: the frame of the
		// waiting thread is the frame of its fault, and the page table of
		// this processor is the one of the program (the stack trace).
		program_stop(program_index, program_fault_report(program_index, &waiter.frame, waiter.fault_address))
		return .Ok

	case .Strategy_Set:
		_ = handle_find(program, v[0], .Machine, {.Schedule}) or_return
		if v[1] == 0 || v[1] > u64(max(op.Strategy)) {
			return .Bad_Operation
		}
		results[0] = u64(strategy_change(op.Strategy(v[1])))
		return .Ok

	case .Machine_Stop:
		_ = handle_find(program, v[0], .Machine, {.Stop}) or_return
		log("kernel: the machine stops with code ", v[1])
		machine_stop(u8(v[1]))

	case:
	}
	return .Bad_Operation
}
