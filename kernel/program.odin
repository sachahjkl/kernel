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
	Machine   = 5, // The machine: its rights are Devices, Inspect and Stop.
	Thread    = 6, // object: index in threads
}

// The rights of the handle of a new object, by kind.
RIGHTS_MEMORY :: op.Rights{.Give, .Read, .Write, .Execute}
RIGHTS_PROGRAM :: op.Rights{.Give, .Read, .Control}
RIGHTS_THREAD :: op.Rights{.Give, .Read, .Control}
RIGHTS_PORTS :: op.Rights{.Give}
RIGHTS_INTERRUPT :: op.Rights{.Give, .Read}
RIGHTS_MACHINE :: op.Rights{.Give, .Inspect, .Devices, .Stop}

Handle_Slot :: struct {
	kind:       Object_Kind,
	generation: u16,
	rights:     op.Rights,
	object:     u32,
	count:      u32,
}

Mapping :: struct {
	address:    u64,
	page_count: u64, // 0: the slot is free.
	region:     u32,
}

// A thread: one flow of execution in a program. It is a register state and
// a kernel ring. Its stack is memory of the program: the kernel does not
// know it.
Thread :: struct {
	frame:        Frame,
	fpu:          Fpu_State,
	state:        op.Program_State, // None, Ready, Waiting or Stopped.
	program:      u32,
	number:       u32, // The index of the thread area in the program.
	ring:         ^ring.Ring,
	record:       u64, // The address of the thread record in the program.
	events:       ^u32, // The `events` word of the thread record, for the kernel.
	deadline:     u64,
	references:   u32, // Handles to this thread.
	in_enter:     bool,
	run_time:     u64,
	// The word wait of the entry in progress or of the wait in progress:
	// the physical addresses of the words.
	words:        [op.WORD_WAIT_CAPACITY]u64,
	word_count:   u32,
	word_changed: bool, // A word did not hold the value: this entry does not wait.
}

// word_address gives the physical address of a 32-bit word of a program,
// or 0 if the program cannot read it.
word_address :: proc "contextless" (program: ^Program, address: u64) -> u64 {
	if address & 3 != 0 || !user_range(program.table, address, 4, false) {
		return 0
	}
	return page_entry(program.table, address, false)^ & PAGE_ADDRESS | address & (PAGE_SIZE - 1)
}

THREAD_TABLE_CAPACITY :: 256

Program :: struct {
	state:        op.Program_State, // None, Created, Ready or Stopped.
	code:         u32,
	name:         [32]u8,
	table:        u64,
	next_address: u64,
	references:   u32, // Handles to this program.
	thread_areas: u32, // Bit n: thread area n is in use.
	thread_count: u32,
	has_ports:    bool,
	run_time:     u64,
	entries:      u64,
	mapped_pages: u64,
	handles:      [HANDLE_CAPACITY]Handle_Slot,
	mappings:     [MAPPING_CAPACITY]Mapping,
}

regions: [REGION_CAPACITY]Region
programs: [PROGRAM_CAPACITY]Program
threads: [THREAD_TABLE_CAPACITY]Thread
interrupt_owner: [INTERRUPT_LINES]u32 // A program.
interrupt_pending: [INTERRUPT_LINES]u32
current: u32 // The thread that runs. 0: the kernel is idle.
last_run: u32
record_thread: u32 // The thread whose thread record address is in the gs register.
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
		case .Thread:
			threads[slot.object].references += 1
		case .Ports:
			program.has_ports = true
		case .Interrupt:
			interrupt_owner[slot.object] = u32(intrinsics.ptr_sub(program, &programs[0]))
		}
		return op.Handle(u32(index + 1) | u32(generation) << 16)
	}
	return 0
}

// handle_find gives the slot of a handle of a program. The handle must name
// an object of this kind (.None: any kind) and have each of these rights.
handle_find :: proc "contextless" (program: ^Program, handle: u64, kind: Object_Kind, rights: op.Rights = {}) -> (slot: ^Handle_Slot, status: op.Status) {
	index := handle & 0xFFFF
	if index == 0 || index >= HANDLE_CAPACITY || handle >> 32 != 0 {
		return nil, .Bad_Handle
	}
	slot = &program.handles[index]
	if slot.kind == .None || u64(slot.generation) != handle >> 16 || (kind != .None && slot.kind != kind) {
		return nil, .Bad_Handle
	}
	if !(rights <= slot.rights) {
		return nil, .No_Right
	}
	return slot, .Ok
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
	case .Thread:
		thread := &threads[slot.object]
		thread.references -= 1
		if thread.references == 0 && thread.state == .Stopped {
			thread.state = .None
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
		if program.table == 0 {
			return 0
		}
		program.next_address = op.CHOSEN_BASE
		copy(program.name[:len(program.name) - 1], name)
		program.state = .Created
		return u32(index + 1)
	}
	return 0
}

// thread_create adds a thread to a program. The kernel makes the thread
// area: the thread record and the kernel ring of the thread.
thread_create :: proc "contextless" (program_index: u32, entry, stack, parameter: u64) -> (index: u32, status: op.Status) {
	program := &programs[program_index]
	number := u32(op.THREAD_CAPACITY)
	for candidate in 0 ..< u32(op.THREAD_CAPACITY) {
		if program.thread_areas & (1 << candidate) == 0 {
			number = candidate
			break
		}
	}
	for &candidate, slot in threads[1:] {
		if candidate.state == .None && candidate.references == 0 {
			index = u32(slot + 1)
			break
		}
	}
	if number == op.THREAD_CAPACITY || index == 0 {
		return 0, .No_Slot
	}
	region := region_create(1 + ring.PAGE_COUNT)
	if region == 0 {
		return 0, .No_Memory
	}
	record := op.THREAD_AREA_BASE + u64(number) * op.THREAD_AREA_PAGES * PAGE_SIZE
	if _, map_status := map_region(program, region, record, {.Write}, 0, 0); map_status != .Ok {
		regions[region].references = 1
		region_release(region)
		return 0, map_status
	}
	direct(regions[region].physical, op.Thread_Record)^ = {
		self      = record,
		parameter = parameter,
		number    = u64(number),
	}
	thread := &threads[index]
	thread^ = {
		state = .Ready,
		program = program_index,
		number = number,
		ring = direct(regions[region].physical + PAGE_SIZE, ring.Ring),
		record = record,
		events = &direct(regions[region].physical, op.Thread_Record).events,
		frame = {
			rip    = entry,
			cs     = SELECTOR_USER_CODE,
			rflags = USER_FLAGS,
			rsp    = stack - 8, // As after a call instruction.
			ss     = SELECTOR_USER_DATA,
			rdi    = parameter,
		},
	}
	start := FPU_START
	copy(thread.fpu.bytes[:], start[:])
	program.thread_areas |= 1 << number
	program.thread_count += 1
	return index, .Ok
}

// thread_end marks a thread as stopped. The slot stays until the last
// handle to the thread closes: a handle never names another thread.
@(private = "file")
thread_end :: proc "contextless" (thread: ^Thread) {
	thread.state = thread.references == 0 ? .None : .Stopped
	thread.ring = nil
	if record_thread == u32(intrinsics.ptr_sub(thread, &threads[0])) {
		record_thread = 0 // The slot can get a new thread.
	}
}

// thread_stop ends one thread and frees its thread area. The other threads
// of the program get an event: one of them can wait for this end. A program with
// no thread stops.
thread_stop :: proc "contextless" (index: u32) {
	thread := &threads[index]
	if thread.state == .None || thread.state == .Stopped {
		return
	}
	program := &programs[thread.program]
	thread_end(thread)
	for &mapping in program.mappings {
		if mapping.page_count != 0 && mapping.address == thread.record {
			unmap(program, &mapping)
			break
		}
	}
	program.thread_areas &~= 1 << thread.number
	program.thread_count -= 1
	if program.thread_count == 0 {
		program_stop(thread.program, 0)
	} else {
		program_event(thread.program)
	}
}

// word_wake ends the wait of at most count threads that wait on a word.
word_wake :: proc "contextless" (word: u64, count: u64) -> (woken: u64) {
	for &thread in threads[1:] {
		if woken == count {
			break
		}
		if thread.state != .Waiting {
			continue
		}
		for candidate in thread.words[:thread.word_count] {
			if candidate == word {
				thread.state = .Ready
				woken += 1
				break
			}
		}
	}
	return woken
}

// program_event tells each thread of a program that an event arrived: see
// operation.Word.
program_event :: proc "contextless" (index: u32) {
	for &thread in threads[1:] {
		if thread.program != index || thread.state != .Ready && thread.state != .Waiting {
			continue
		}
		intrinsics.volatile_store(thread.events, intrinsics.volatile_load(thread.events) + 1)
		if thread.state == .Waiting {
			word := physical_of(thread.events)
			for candidate in thread.words[:thread.word_count] {
				if candidate == word {
					thread.state = .Ready
					break
				}
			}
		}
	}
}

// program_state gives the state of a program for a report: a running
// program is Ready when one of its threads is Ready.
program_state :: proc "contextless" (index: u32) -> op.Program_State {
	program := &programs[index]
	if program.state != .Ready {
		return program.state
	}
	for &thread in threads[1:] {
		if thread.program == index && thread.state == .Ready {
			return .Ready
		}
	}
	return .Waiting
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
	for &thread in threads[1:] {
		if thread.program == index && thread.state != .None && thread.state != .Stopped {
			thread_end(&thread)
		}
	}
	program.thread_count = 0
	program.thread_areas = 0
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
	for &other, other_index in programs[1:] {
		if other.state == .None || other.state == .Stopped {
			continue
		}
		for slot in other.handles {
			if slot.kind == .Program && slot.object == index {
				program_event(u32(other_index + 1))
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

// schedule runs the next thread that is ready. With none, it waits for an
// interrupt.
schedule :: proc "contextless" () -> ! {
	for {
		alive := false
		for step in 1 ..= u32(THREAD_TABLE_CAPACITY) {
			index := (last_run + step) % THREAD_TABLE_CAPACITY
			thread := &threads[index]
			if index == 0 || thread.state == .None || thread.state == .Stopped {
				continue
			}
			alive = true
			if thread.state != .Ready {
				continue
			}
			current = index
			last_run = index
			slice_left = TIME_SLICE
			run(thread)
		}
		if !alive {
			log("kernel: no program is left")
			machine_stop(0)
		}
		current = 0
		idle_wait()
	}
}

// run gives the processor to a thread.
run :: proc "contextless" (thread: ^Thread) -> ! {
	program := &programs[thread.program]
	ports_switch(program.has_ports ? thread.program : 0)
	if cr3_read() != program.table {
		cr3_write(program.table)
	}
	// Two programs have thread records at the same address. The test is on
	// the thread, so a program that changes its gs register harms only itself.
	if record_thread != current {
		record_thread = current
		msr_write(MSR_GS_BASE, thread.record)
	}
	current_fpu_area = &thread.fpu
	if thread.in_enter {
		thread.in_enter = false
		thread.frame.rax = ticks
	}
	resume(&thread.frame)
}

EXCEPTION_NAMES := [32]string {
	0  = "division by zero",
	6  = "invalid instruction",
	8  = "double fault",
	13 = "protection fault",
	14 = "page fault",
}

// kernel_interrupt is where every interrupt, exception and kernel entry arrives.
@(require, linkage = "strong", link_name = "kernel_interrupt")
kernel_interrupt :: proc "c" (frame: ^Frame) {
	from_program := frame.cs & 3 != 0
	if from_program {
		threads[current].frame = frame^
	}
	switch {
	case frame.vector == VECTOR_KERNEL_ENTER:
		entry_count += 1
		enter(current)
	case frame.vector == VECTOR_TIMER:
		ticks += 1
		if from_program {
			threads[current].run_time += 1
			programs[threads[current].program].run_time += 1
			slice_left -= min(slice_left, 1)
		}
		for &thread in threads[1:] {
			if thread.state == .Waiting && thread.deadline <= ticks {
				thread.state = .Ready
			}
		}
		interrupt_end(0)
	case frame.vector > VECTOR_TIMER && frame.vector < VECTOR_INTERRUPT_BASE + INTERRUPT_LINES:
		line := frame.vector - VECTOR_INTERRUPT_BASE
		interrupt_count += 1
		interrupt_pending[line] += 1
		if owner := interrupt_owner[line]; owner != 0 {
			program_event(owner)
		}
		interrupt_end(line)
	case:
		name := frame.vector < 32 ? EXCEPTION_NAMES[frame.vector] : ""
		if !from_program {
			log("kernel: exception in the kernel: ", name, " vector ", frame.vector, " error ", Hex(frame.error), " at ", Hex(frame.rip), " address ", Hex(cr2_read()))
			machine_stop(2)
		}
		// A fault in one thread stops the program: the threads share all
		// their memory.
		program := threads[current].program
		log("kernel: program ", program_name(&programs[program]), " stopped: ", name, " vector ", frame.vector, " error ", Hex(frame.error), " at ", Hex(frame.rip), " address ", Hex(cr2_read()))
		program_stop(program, op.STOP_CODE_FAULT + u32(frame.vector))
	}
	if !from_program {
		return
	}
	// The thread that entered continues, unless it waits, it stopped, or its
	// time slice is over.
	thread := &threads[current]
	if thread.state == .Ready && slice_left > 0 {
		run(thread)
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
