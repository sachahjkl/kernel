package kernel

import "../ring"
import "base:intrinsics"
import op "operation"

// K1 and K3: the objects, the handle tables, the programs and the scheduler.
// All tables are flat arrays with a fixed capacity. Index 0 of each table is
// not used, so that 0 means "none".

USER_END :: u64(op.USER_END)
REGION_CAPACITY :: 2048
PROGRAM_CAPACITY :: 64
HANDLE_CAPACITY :: 128
MAPPING_CAPACITY :: 128

// A memory object: a block of page frames.
Region :: struct {
	physical:   u64,
	page_count: u64, // 0: the slot is free.
	references: u32, // Handles and mappings.
	device:     bool, // The frames are not from the page frame table: a framebuffer, boot data.
}

Object_Kind :: enum u8 {
	None      = 0,
	Memory    = 1, // object: index in regions
	Program   = 2, // object: index in programs
	Interrupt = 3, // object: interrupt line
	Ports     = 4, // object: first port; count: number of ports
	Machine   = 5, // The right to create device handles, to inspect and to stop the machine.
}

Handle_Slot :: struct {
	kind:       Object_Kind,
	generation: u16,
	object:     u32,
	count:      u32,
}

Mapping :: struct {
	address:    u64,
	page_count: u64, // 0: the slot is free.
	region:     u32,
}

Program :: struct {
	frame:        Frame,
	fpu:          Fpu_State,
	state:        op.Program_State,
	code:         u32,
	name:         [32]u8,
	table:        u64,
	ring:         ^ring.Ring,
	next_address: u64,
	deadline:     u64,
	references:   u32, // Handles to this program.
	wake_pending: bool,
	in_enter:     bool,
	has_ports:    bool,
	run_time:     u64,
	entries:      u64,
	mapped_pages: u64,
	handles:      [HANDLE_CAPACITY]Handle_Slot,
	mappings:     [MAPPING_CAPACITY]Mapping,
}

regions: [REGION_CAPACITY]Region
programs: [PROGRAM_CAPACITY]Program
interrupt_owner: [INTERRUPT_LINES]u32
interrupt_pending: [INTERRUPT_LINES]u32
current: u32 // The program that runs. 0: the kernel is idle.
last_run: u32
ports_loaded: u32 // The program whose ports are open in the task state.
ticks: u64
slice_left: u64
entry_count: u64
interrupt_count: u64

region_create :: proc "contextless" (page_count: u64) -> u32 {
	if page_count == 0 {
		return 0
	}
	for &region, index in regions[1:] {
		if region.page_count == 0 {
			physical := frames_allocate(page_count)
			if physical == 0 {
				return 0
			}
			region = {physical = physical, page_count = page_count}
			return u32(index + 1)
		}
	}
	return 0
}

region_device :: proc "contextless" (physical: u64, page_count: u64) -> u32 {
	for &region, index in regions[1:] {
		if region.page_count == 0 {
			region = {physical = physical, page_count = page_count, device = true}
			return u32(index + 1)
		}
	}
	return 0
}

region_release :: proc "contextless" (index: u32) {
	region := &regions[index]
	region.references -= 1
	if region.references == 0 {
		if !region.device {
			frames_free(region.physical, region.page_count)
		}
		region^ = {}
	}
}

handle_insert :: proc "contextless" (program: ^Program, slot: Handle_Slot) -> op.Handle {
	for &entry, index in program.handles[1:] {
		if entry.kind != .None {
			continue
		}
		generation := entry.generation
		entry = slot
		entry.generation = generation
		#partial switch slot.kind {
		case .Memory:
			regions[slot.object].references += 1
		case .Program:
			programs[slot.object].references += 1
		case .Ports:
			program.has_ports = true
		case .Interrupt:
			interrupt_owner[slot.object] = u32(intrinsics.ptr_sub(program, &programs[0]))
		}
		return op.Handle(u32(index + 1) | u32(generation) << 16)
	}
	return 0
}

handle_find :: proc "contextless" (program: ^Program, handle: u64, kind: Object_Kind) -> ^Handle_Slot {
	index := handle & 0xFFFF
	if index == 0 || index >= HANDLE_CAPACITY || handle >> 32 != 0 {
		return nil
	}
	slot := &program.handles[index]
	if slot.kind == .None || u64(slot.generation) != handle >> 16 || (kind != .None && slot.kind != kind) {
		return nil
	}
	return slot
}

handle_close :: proc "contextless" (program: ^Program, slot: ^Handle_Slot) {
	#partial switch slot.kind {
	case .Memory:
		region_release(slot.object)
	case .Program:
		target := &programs[slot.object]
		// A program runs only while a handle names it: nobody can stop a
		// program that no handle names.
		target.references -= 1
		if target.references == 0 {
			if target.state == .Stopped {
				target.state = .None
			} else {
				program_stop(slot.object, op.STOP_CODE_NO_HANDLE)
			}
		}
	case .Interrupt:
		if interrupt_owner[slot.object] == u32(intrinsics.ptr_sub(program, &programs[0])) {
			interrupt_owner[slot.object] = 0
		}
	}
	slot^ = {generation = slot.generation + 1}
}

// map puts pages of a region in the address space of a program.
map_region :: proc "contextless" (program: ^Program, region_index: u32, address: u64, flags: op.Map_Flags, first: u64, count: u64) -> (result: u64, status: op.Status) {
	region := &regions[region_index]
	count := count
	if count == 0 && first < region.page_count {
		count = region.page_count - first
	}
	if count == 0 || first >= region.page_count || count > region.page_count - first {
		return 0, .Bad_Address
	}
	address := address
	if address == 0 {
		address = program.next_address
		program.next_address += (count + 1) * PAGE_SIZE
	}
	size := count * PAGE_SIZE
	if address % PAGE_SIZE != 0 || address < PAGE_SIZE || address >= USER_END || size > USER_END - address {
		return 0, .Bad_Address
	}
	mapping: ^Mapping
	for &candidate in program.mappings {
		if candidate.page_count == 0 {
			mapping = &candidate
			break
		}
	}
	if mapping == nil {
		return 0, .No_Slot
	}
	for page in 0 ..< count {
		entry := page_entry(program.table, address + page * PAGE_SIZE, false)
		if entry != nil && entry^ & PAGE_PRESENT != 0 {
			return 0, .Bad_Address
		}
	}
	bits := PAGE_PRESENT | PAGE_USER
	if .Write in flags {
		bits |= PAGE_WRITE
	}
	if .Execute not_in flags {
		bits |= PAGE_NO_EXECUTE
	}
	for page in 0 ..< count {
		entry := page_entry(program.table, address + page * PAGE_SIZE, true)
		if entry == nil {
			for undo in 0 ..< page {
				page_entry(program.table, address + undo * PAGE_SIZE, false)^ = 0
			}
			return 0, .No_Memory
		}
		entry^ = (region.physical + (first + page) * PAGE_SIZE) | bits
	}
	mapping^ = {address = address, page_count = count, region = region_index}
	region.references += 1
	program.mapped_pages += count
	return address, .Ok
}

unmap :: proc "contextless" (program: ^Program, mapping: ^Mapping) {
	active := cr3_read() == program.table
	for page in 0 ..< mapping.page_count {
		address := mapping.address + page * PAGE_SIZE
		entry := page_entry(program.table, address, false)
		if entry != nil {
			entry^ = 0
			if active {
				page_flush(address)
			}
		}
	}
	program.mapped_pages -= mapping.page_count
	region_release(mapping.region)
	mapping^ = {}
}

// maps_region says if a program has a mapping of a memory object.
maps_region :: proc "contextless" (program: ^Program, region: u32) -> bool {
	for mapping in program.mappings {
		if mapping.page_count != 0 && mapping.region == region {
			return true
		}
	}
	return false
}

FPU_START :: [32]u8{0 = 0x7F, 1 = 0x03, 24 = 0x80, 25 = 0x1F}

program_create :: proc "contextless" (name: []u8) -> u32 {
	for &program, index in programs[1:] {
		if program.state != .None {
			continue
		}
		program = {}
		program.table = address_space_create()
		ring_region := region_create(ring.PAGE_COUNT)
		if program.table == 0 || ring_region == 0 {
			return 0
		}
		program.ring = direct(regions[ring_region].physical, ring.Ring)
		program.next_address = op.CHOSEN_BASE
		if _, status := map_region(&program, ring_region, op.KERNEL_RING_ADDRESS, {.Write}, 0, 0); status != .Ok {
			return 0
		}
		start := FPU_START
		copy(program.fpu.bytes[:], start[:])
		copy(program.name[:len(program.name) - 1], name)
		program.state = .Created
		return u32(index + 1)
	}
	return 0
}

wake :: proc "contextless" (program: ^Program) {
	if program.state == .Waiting {
		program.state = .Ready
	} else {
		program.wake_pending = true
	}
}

// program_stop ends a program and frees all that it has.
program_stop :: proc "contextless" (index: u32, code: u32) {
	program := &programs[index]
	if program.state == .None || program.state == .Stopped {
		return
	}
	// The state changes first: a handle that this program closes below can
	// name this program.
	program.state = .Stopped
	program.code = code
	if cr3_read() == program.table {
		cr3_write(kernel_table)
	}
	if ports_loaded == index {
		ports_switch(0)
	}
	for &mapping in program.mappings {
		if mapping.page_count != 0 {
			unmap(program, &mapping)
		}
	}
	for &slot in program.handles {
		if slot.kind != .None {
			handle_close(program, &slot)
		}
	}
	address_space_free(program.table)
	program.table = 0
	program.ring = nil
	for &other in programs[1:] {
		if other.state == .None || other.state == .Stopped {
			continue
		}
		for slot in other.handles {
			if slot.kind == .Program && slot.object == index {
				wake(&other)
				break
			}
		}
	}
	if program.references == 0 {
		program.state = .None
	}
}

// ports_switch closes the ports of the program that had them, and opens the
// ports of program index.
ports_switch :: proc "contextless" (index: u32) {
	if ports_loaded == index {
		return
	}
	for pass in 0 ..< 2 {
		program := &programs[pass == 0 ? ports_loaded : index]
		if !program.has_ports {
			continue
		}
		for slot in program.handles {
			if slot.kind == .Ports {
				ports_allow(u64(slot.object), u64(slot.count), pass == 1)
			}
		}
	}
	ports_loaded = index
}

// schedule runs the next program that is ready. With none, it waits for an
// interrupt.
schedule :: proc "contextless" () -> ! {
	for {
		alive := false
		for step in 1 ..= u32(PROGRAM_CAPACITY) {
			index := (last_run + step) % PROGRAM_CAPACITY
			program := &programs[index]
			if index == 0 || program.state == .None || program.state == .Stopped {
				continue
			}
			alive = true
			if program.state != .Ready {
				continue
			}
			current = index
			last_run = index
			slice_left = TIME_SLICE
			ports_switch(program.has_ports ? index : 0)
			if cr3_read() != program.table {
				cr3_write(program.table)
			}
			current_fpu_area = &program.fpu
			if program.in_enter {
				program.in_enter = false
				program.frame.rax = ticks
			}
			resume(&program.frame)
		}
		if !alive {
			log("kernel: no program is left")
			machine_stop(0)
		}
		current = 0
		idle_wait()
	}
}

EXCEPTION_NAMES := [32]string {
	0  = "division by zero",
	6  = "invalid instruction",
	8  = "double fault",
	13 = "protection fault",
	14 = "page fault",
}

// kernel_interrupt is where every interrupt, exception and kernel entry arrives.
@(export, link_name = "kernel_interrupt")
kernel_interrupt :: proc "c" (frame: ^Frame) {
	from_program := frame.cs & 3 != 0
	if from_program {
		programs[current].frame = frame^
	}
	switch {
	case frame.vector == VECTOR_KERNEL_ENTER:
		entry_count += 1
		enter(current)
	case frame.vector == VECTOR_TIMER:
		ticks += 1
		if from_program {
			programs[current].run_time += 1
			slice_left -= min(slice_left, 1)
		}
		for &program in programs[1:] {
			if program.state == .Waiting && program.deadline <= ticks {
				program.state = .Ready
			}
		}
		interrupt_end(0)
	case frame.vector > VECTOR_TIMER && frame.vector < VECTOR_INTERRUPT_BASE + INTERRUPT_LINES:
		line := frame.vector - VECTOR_INTERRUPT_BASE
		interrupt_count += 1
		interrupt_pending[line] += 1
		if owner := interrupt_owner[line]; owner != 0 {
			wake(&programs[owner])
		}
		interrupt_end(line)
	case:
		name := frame.vector < 32 ? EXCEPTION_NAMES[frame.vector] : ""
		if !from_program {
			log("kernel: exception in the kernel: ", name, " vector ", frame.vector, " error ", Hex(frame.error), " at ", Hex(frame.rip), " address ", Hex(cr2_read()))
			machine_stop(2)
		}
		program := &programs[current]
		log("kernel: program ", program_name(program), " stopped: ", name, " vector ", frame.vector, " error ", Hex(frame.error), " at ", Hex(frame.rip), " address ", Hex(cr2_read()))
		program_stop(current, op.STOP_CODE_FAULT + u32(frame.vector))
	}
	if !from_program {
		return
	}
	// The program that entered continues, unless it waits, it stopped, or its
	// time slice is over.
	program := &programs[current]
	if program.state == .Ready && slice_left > 0 {
		if program.in_enter {
			program.in_enter = false
			program.frame.rax = ticks
		}
		resume(&program.frame)
	}
	schedule()
}

program_name :: proc "contextless" (program: ^Program) -> string {
	count := 0
	for count < len(program.name) && program.name[count] != 0 {
		count += 1
	}
	return string(program.name[:count])
}
