package kernel

import "../ring"
import "base:intrinsics"
import op "operation"

// K4: the kernel entry. It executes the command records of the kernel ring
// of the program, then makes the program wait if it asked for that.

enter :: proc "contextless" (index: u32) {
	thread := &threads[index]
	programs[thread.program].entries += 1
	thread.in_enter = true
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
		if thread.wake_pending {
			thread.wake_pending = false
		} else {
			thread.state = .Waiting
			thread.deadline = wait
		}
	}
}

execute :: proc "contextless" (index: u32, command: ring.Record, results: ^[7]u64) -> op.Status {
	program_index := threads[index].program
	program := &programs[program_index]
	v := command.values

	// target gives the program that a program handle names. 0 names the caller.
	target :: proc "contextless" (program: ^Program, handle: u64) -> ^Program {
		if handle == 0 {
			return program
		}
		slot := handle_find(program, handle, .Program)
		if slot == nil {
			return nil
		}
		return &programs[slot.object]
	}

	switch op.Operation(command.kind) {
	case .None:
		return .Ok

	case .Log:
		if v[1] > 4096 || !user_range(program.table, v[0], v[1], false) {
			return .Bad_Address
		}
		log_bytes({'['})
		log_bytes(transmute([]u8)program_name(program))
		log_bytes({']', ' '})
		log_bytes(([^]u8)(uintptr(v[0]))[:v[1]])
		log_bytes({'\r', '\n'})
		return .Ok

	case .Memory_Create:
		region := region_create(v[0])
		if region == 0 {
			return .No_Memory
		}
		handle := handle_insert(program, {kind = .Memory, object = region})
		if handle == 0 {
			regions[region].references = 1
			region_release(region)
			return .No_Slot
		}
		results[0] = u64(handle)
		return .Ok

	case .Memory_Map:
		slot := handle_find(program, v[0], .Memory)
		to := target(program, v[1])
		if slot == nil || to == nil {
			return .Bad_Handle
		}
		if to.state == .None || to.state == .Stopped {
			return .Bad_State
		}
		address, status := map_region(to, slot.object, v[2], transmute(op.Map_Flags)v[3], v[4], v[5])
		results[0] = address
		return status

	case .Memory_Unmap:
		to := target(program, v[0])
		if to == nil {
			return .Bad_Handle
		}
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
		slot := handle_find(program, v[0], .Memory)
		if slot == nil {
			return .Bad_Handle
		}
		results[0] = regions[slot.object].page_count
		return .Ok

	case .Program_Create:
		if v[1] > 31 || !user_range(program.table, v[0], v[1], false) {
			return .Bad_Address
		}
		created := program_create(([^]u8)(uintptr(v[0]))[:v[1]])
		if created == 0 {
			return .No_Memory
		}
		handle := handle_insert(program, {kind = .Program, object = created})
		if handle == 0 {
			program_stop(created, 0)
			return .No_Slot
		}
		results[0] = u64(handle)
		return .Ok

	case .Program_Start:
		slot := handle_find(program, v[0], .Program)
		if slot == nil {
			return .Bad_Handle
		}
		to := &programs[slot.object]
		if to.state != .Created {
			return .Bad_State
		}
		if _, status := thread_create(slot.object, v[1], v[2], v[3]); status != .Ok {
			return status
		}
		to.state = .Ready
		return .Ok

	case .Thread_Create:
		created, status := thread_create(program_index, v[0], v[1], v[2])
		if status != .Ok {
			return status
		}
		handle := handle_insert(program, {kind = .Thread, object = created})
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
		slot := handle_find(program, v[0], .Thread)
		if slot == nil {
			return .Bad_Handle
		}
		thread_stop(slot.object)
		return .Ok

	case .Thread_State:
		slot := handle_find(program, v[0], .Thread)
		if slot == nil {
			return .Bad_Handle
		}
		results[0] = u64(threads[slot.object].state)
		return .Ok

	case .Program_Stop:
		to := target(program, v[0])
		if to == nil {
			return .Bad_Handle
		}
		program_stop(u32(intrinsics.ptr_sub(to, &programs[0])), u32(v[1]))
		return .Ok

	case .Program_State:
		slot := handle_find(program, v[0], .Program)
		if slot == nil {
			return .Bad_Handle
		}
		results[0] = u64(program_state(slot.object))
		results[1] = u64(programs[slot.object].code)
		return .Ok

	case .Handle_Give:
		given := handle_find(program, v[1], .None)
		to_slot := handle_find(program, v[0], .None)
		if given == nil || to_slot == nil {
			return .Bad_Handle
		}
		to: ^Program
		#partial switch to_slot.kind {
		case .Program:
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
		}
		if to == nil {
			return .Bad_Handle
		}
		if to.state == .None || to.state == .Stopped {
			return .Bad_State
		}
		handle := handle_insert(to, given^)
		if handle == 0 {
			return .No_Slot
		}
		results[0] = u64(handle)
		return .Ok

	case .Handle_Close:
		slot := handle_find(program, v[0], .None)
		if slot == nil {
			return .Bad_Handle
		}
		handle_close(program, slot)
		return .Ok

	case .Wake:
		slot := handle_find(program, v[0], .Memory)
		if slot == nil {
			return .Bad_Handle
		}
		for &other, other_index in programs[1:] {
			if other.state == .Ready && maps_region(&other, slot.object) {
				wake_program(u32(other_index + 1), index)
			}
		}
		return .Ok

	case .Interrupt_Read:
		slot := handle_find(program, v[0], .Interrupt)
		if slot == nil {
			return .Bad_Handle
		}
		results[0] = u64(interrupt_pending[slot.object])
		interrupt_pending[slot.object] = 0
		return .Ok

	case .Device_Create:
		if handle_find(program, v[0], .Machine) == nil {
			return .Bad_Handle
		}
		slot: Handle_Slot
		switch op.Device_Kind(v[1]) {
		case .Ports:
			if v[2] >= 65536 || v[3] == 0 || v[3] > 65536 - v[2] {
				return .Bad_Address
			}
			slot = {kind = .Ports, object = u32(v[2]), count = u32(v[3])}
		case .Interrupt:
			if v[2] == 0 || v[2] >= INTERRUPT_LINES {
				return .Bad_Address
			}
			slot = {kind = .Interrupt, object = u32(v[2])}
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
		if handle_find(program, v[0], .Machine) == nil {
			return .Bad_Handle
		}
		switch op.Inspect_Kind(v[1]) {
		case .System:
			if v[4] < size_of(op.System_Report) || !user_range(program.table, v[3], size_of(op.System_Report), true) {
				return .Bad_Address
			}
			report := op.System_Report {
				time          = ticks,
				page_count    = frame_count,
				free_pages    = free_frames,
				program_slots = PROGRAM_CAPACITY,
				entries       = entry_count,
				interrupts    = interrupt_count,
			}
			for region in regions {
				if region.page_count != 0 {
					report.region_count += 1
				}
			}
			(^op.System_Report)(uintptr(v[3]))^ = report
			results[0] = size_of(op.System_Report)
		case .Program:
			if v[4] < size_of(op.Program_Report) || !user_range(program.table, v[3], size_of(op.Program_Report), true) {
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
					run_time     = about.run_time,
					entries      = about.entries,
				}
				for slot in about.handles {
					if slot.kind != .None {
						report.handle_count += 1
					}
				}
			}
			(^op.Program_Report)(uintptr(v[3]))^ = report
			results[0] = size_of(op.Program_Report)
		case .None:
			return .Bad_Operation
		case:
			return .Bad_Operation
		}
		return .Ok

	case .Machine_Stop:
		if handle_find(program, v[0], .Machine) == nil {
			return .Bad_Handle
		}
		log("kernel: the machine stops with code ", v[1])
		machine_stop(u8(v[1]))

	case:
	}
	return .Bad_Operation
}
