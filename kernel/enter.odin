package kernel

import "contract:ring"
import "base:intrinsics"
import op "contract:operation"

// K4: the kernel entry. It executes the command records of the kernel ring
// of the program, then makes the program wait if it asked for that.

// Records that are too large for the kernel stack. The kernel lock guards them.
log_text: [4096]u8
boot_report_record: op.Boot_Report
mapping_report_record: op.Mapping_Report
module_report_record: op.Module_Report

enter :: proc "contextless" (index: u32) {
	thread := &threads[index]
	programs[thread.program].entries += 1
	thread.in_enter = true
	thread.word_count = 0
	thread.word_changed = false
	for _ in 0 ..< ring.CAPACITY {
		command, ok := ring.pop(&thread.ring.commands)
		if !ok {
			break
		}
		completion := ring.Record{tag = command.tag}
		status := execute(index, command, &completion.values)
		// The operation can stop the thread: then it has no ring.
		if thread.state != .Ready {
			return
		}
		completion.kind = u32(status)
		ring.push(&thread.ring.completions, completion)
	}
	wait := thread.frame.rdi
	if wait != 0 {
		// A word that changed before the wait: the thread reads it again.
		if !thread.word_changed {
			thread.state = .Waiting
			thread.deadline = wait
		}
	}
}

execute :: proc "contextless" (index: u32, command: ring.Record, results: ^[7]u64) -> op.Status {
	program_index := threads[index].program
	program := &programs[program_index]
	v := command.values

	// target gives the program that a program handle with the right Control
	// names. 0 names the caller.
	target :: proc "contextless" (program: ^Program, handle: u64) -> (to: ^Program, status: op.Status) {
		if handle == 0 {
			return program, .Ok
		}
		slot := handle_find(program, handle, .Program, {.Control}) or_return
		return &programs[slot.object], .Ok
	}

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
		user_copy(&log_text, rawptr(uintptr(v[1])), v[2])
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
		if flags - {.Frames_Now, .Contiguous} != {} {
			return .Bad_Operation
		}
		region := region_create(budget.object, v[1], contiguous = .Contiguous in flags, now = .Frames_Now in flags) or_return
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
		to := target(program, v[1]) or_return
		if to.state == .None || to.state == .Stopped {
			return .Bad_State
		}
		address, status := map_region(to, slot.object, v[2], flags, v[4], v[5], holding_of_handle(program, slot))
		results[0] = address
		return status

	case .Memory_Unmap:
		to := target(program, v[0]) or_return
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
		slot := handle_find(program, v[0], .Program, {.Control}) or_return
		to := &programs[slot.object]
		if to.state != .Created {
			return .Bad_State
		}
		if _, status := thread_create(slot.object, to.budget, v[1], v[2], v[3]); status != .Ok {
			return status
		}
		to.state = .Ready
		return .Ok

	case .Thread_Create:
		budget := handle_find(program, v[0], .Budget, {.Spend}) or_return
		created := thread_create(program_index, budget.object, v[1], v[2], v[3]) or_return
		handle := handle_insert(program, {kind = .Thread, rights = RIGHTS_THREAD, object = created})
		if handle == 0 {
			thread_stop(created)
			return .No_Slot
		}
		results[0] = u64(handle)
		return .Ok

	case .Thread_Stop:
		if v[0] == 0 {
			thread_stop(index)
			return .Ok
		}
		slot := handle_find(program, v[0], .Thread, {.Control}) or_return
		thread_stop(slot.object)
		return .Ok

	case .Thread_State:
		slot := handle_find(program, v[0], .Thread, {.Read}) or_return
		results[0] = u64(threads[slot.object].state)
		return .Ok

	case .Program_Stop:
		to := target(program, v[0]) or_return
		program_stop(u32(intrinsics.ptr_sub(to, &programs[0])), u32(v[1]))
		return .Ok

	case .Program_State:
		slot := handle_find(program, v[0], .Program, {.Read}) or_return
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
			find: for &other in programs[1:] {
				if &other == program || other.state == .None || other.state == .Stopped {
					continue
				}
				if maps_region(&other, to_slot.object) {
					to = &other
					break find
				}
			}
			if to == nil {
				// No other program maps the memory yet: the one other
				// program that holds a handle to it. Two holders: no target.
				for &other in programs[1:] {
					if &other == program || other.state == .None || other.state == .Stopped || !holds_region(&other, to_slot.object) {
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
		if to.state == .None || to.state == .Stopped {
			return .Bad_State
		}
		copy := given^
		copy.rights &= transmute(op.Rights)u32(v[2])
		copy.through = through
		handle := handle_insert(to, copy)
		if handle == 0 {
			return .No_Slot
		}
		origin_attach(holding_of_handle(to, &to.handles[u32(handle) & 0xFFFF]), holding_of_handle(program, given))
		results[0] = u64(handle)
		return .Ok

	case .Handle_Revoke:
		slot := handle_find(program, v[0], .None) or_return
		only: u32
		if v[1] != 0 {
			in_program := handle_find(program, v[1], .Program, {.Control}) or_return
			only = in_program.object
		}
		results[0] = revoke(holding_of_handle(program, slot), program_index, only)
		return .Ok

	case .Program_Module:
		to := target(program, v[0]) or_return
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
		handle_close(program, slot)
		return .Ok

	case .Budget_Create:
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
			if direct(physical, u32)^ != u32(word.value) {
				thread.word_changed = true
			}
			thread.words[thread.word_count] = physical
			thread.word_count += 1
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
		results[0] = u64(interrupt_pending[slot.object])
		interrupt_pending[slot.object] = 0
		return .Ok

	case .Device_Create:
		_ = handle_find(program, v[0], .Machine, {.Devices}) or_return
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
				regions[region] = {}
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
				time          = ticks,
				page_count    = frame_count,
				free_pages    = free_frames,
				program_slots = PROGRAM_CAPACITY,
				entries       = entry_count,
				interrupts    = interrupt_count,
				processors    = u64(processor_count),
				locks         = lock_counts,
				reserved_pages = reserved_pages,
				first_use_faults = first_use_faults,
			}
			for region in regions {
				if region.page_count != 0 {
					report.region_count += 1
				}
			}
			for budget in budgets {
				report.budget_pages += budget.amounts.pages
			}
			user_copy(rawptr(uintptr(v[3])), &report, size_of(report))
			results[0] = size_of(op.System_Report)
		case .Program:
			if v[4] < size_of(op.Program_Report) || !user_range(program, v[3], size_of(op.Program_Report), true) {
				return .Bad_Address
			}
			report: op.Program_Report
			if v[2] != 0 && v[2] < PROGRAM_CAPACITY {
				about := &programs[v[2]]
				report = {
					state        = program_state(u32(v[2])),
					thread_count = u64(about.thread_count),
					code         = about.code,
					name         = about.name,
					mapped_pages = about.mapped_pages,
					present_pages = about.state == .None || about.table == 0 ? 0 : present_pages(about),
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
			boot_report(&boot_report_record)
			user_copy(rawptr(uintptr(v[3])), &boot_report_record, size_of(op.Boot_Report))
			results[0] = size_of(op.Boot_Report)
		case .Mappings:
			if v[4] < size_of(op.Mapping_Report) || !user_range(program, v[3], size_of(op.Mapping_Report), true) {
				return .Bad_Address
			}
			if v[2] == 0 {
				mappings_report(&mapping_report_record, kernel_table, 256, 512)
			} else {
				mappings_report(&mapping_report_record, program.table, 0, 256)
			}
			user_copy(rawptr(uintptr(v[3])), &mapping_report_record, size_of(op.Mapping_Report))
			results[0] = size_of(op.Mapping_Report)
		case .Modules:
			if v[4] < size_of(op.Module_Report) || !user_range(program, v[3], size_of(op.Module_Report), true) {
				return .Bad_Address
			}
			report := &module_report_record
			report^ = {}
			if v[2] != 0 && v[2] < PROGRAM_CAPACITY {
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
				if cpu.current != 0 {
					report.program = u64(threads[cpu.current].program)
					report.same = u64(programs[report.program].table == program.table)
				}
			}
			user_copy(rawptr(uintptr(v[3])), &report, size_of(report))
			results[0] = size_of(op.Processor_Report)
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

	case .Machine_Stop:
		_ = handle_find(program, v[0], .Machine, {.Stop}) or_return
		log("kernel: the machine stops with code ", v[1])
		machine_stop(u8(v[1]))

	case:
	}
	return .Bad_Operation
}
