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
	budget:     u32, // The budget that paid. 0 for a device.
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
	Budget    = 7, // object: index in budgets
	Log       = 8, // The log of the kernel.
}

// The rights of the handle of a new object, by kind.
RIGHTS_MEMORY :: op.Rights{.Give, .Read, .Write, .Execute}
RIGHTS_PROGRAM :: op.Rights{.Give, .Read, .Control}
RIGHTS_THREAD :: op.Rights{.Give, .Read, .Control}
RIGHTS_PORTS :: op.Rights{.Give}
RIGHTS_INTERRUPT :: op.Rights{.Give, .Read}
RIGHTS_MACHINE :: op.Rights{.Give, .Inspect, .Devices, .Stop}
RIGHTS_BUDGET :: op.Rights{.Give, .Read, .Spend}
RIGHTS_LOG :: op.Rights{.Give, .Write}

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
	processor:    u32, // 1 + the index of the processor that runs the thread. 0: none.
	budget:       u32, // The budget that paid for the slot.
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
	budget:       u32, // The budget that paid for the slot. It pays for the page tables.
	thread_areas: u32, // Bit n: thread area n is in use.
	thread_count: u32,
	has_ports:    bool,
	run_time:     u64,
	start_time:   u64, // Microseconds since the machine started.
	entries:      u64,
	mapped_pages: u64,
	handles:      [HANDLE_CAPACITY]Handle_Slot,
	mappings:     [MAPPING_CAPACITY]Mapping,
}

BUDGET_CAPACITY :: 128

// A budget: see operation.Budget_Amounts. Budget 0 is not live: it holds
// what returned to no budget.
Budget :: struct {
	live:       bool,
	parent:     u32, // The budget that this budget came from. It is live, or it is 0.
	references: u32, // Handles to this budget.
	amounts:    op.Budget_Amounts,
}

budgets: [BUDGET_CAPACITY]Budget
regions: [REGION_CAPACITY]Region
programs: [PROGRAM_CAPACITY]Program
threads: [THREAD_TABLE_CAPACITY]Thread
interrupt_owner: [INTERRUPT_LINES]u32 // A program.
interrupt_pending: [INTERRUPT_LINES]u32
last_run: u32
ticks: u64
entry_count: u64
interrupt_count: u64

// budget_create moves amounts from a budget to a new budget.
budget_create :: proc "contextless" (parent: u32, amounts: op.Budget_Amounts) -> (index: u32, status: op.Status) {
	from := &budgets[parent]
	if !from.live || amounts.pages > from.amounts.pages || amounts.programs > from.amounts.programs || amounts.threads > from.amounts.threads {
		return 0, .No_Budget
	}
	for &budget, slot in budgets[1:] {
		if !budget.live {
			from.amounts.pages -= amounts.pages
			from.amounts.programs -= amounts.programs
			from.amounts.threads -= amounts.threads
			budget = {live = true, parent = parent, amounts = amounts}
			return u32(slot + 1), .Ok
		}
	}
	return 0, .No_Slot
}

// budget_release closes one handle to a budget. With no handle, the budget
// ends: what it holds returns to its parent, and its parent pays for the
// objects that it paid for.
budget_release :: proc "contextless" (index: u32) {
	budget := &budgets[index]
	budget.references -= 1
	if budget.references != 0 {
		return
	}
	parent := budget.parent
	budgets[parent].amounts.pages += budget.amounts.pages
	budgets[parent].amounts.programs += budget.amounts.programs
	budgets[parent].amounts.threads += budget.amounts.threads
	for &region in regions {
		if region.page_count != 0 && region.budget == index {
			region.budget = parent
		}
	}
	for &program in programs {
		if program.state != .None && program.budget == index {
			program.budget = parent
		}
	}
	for &thread in threads {
		if thread.state != .None && thread.budget == index {
			thread.budget = parent
		}
	}
	for &other in budgets {
		if other.live && other.parent == index {
			other.parent = parent
		}
	}
	budget^ = {}
}

// region_create makes a memory object. The budget pays for its pages.
region_create :: proc "contextless" (budget: u32, page_count: u64) -> (index: u32, status: op.Status) {
	if page_count == 0 {
		return 0, .Bad_Operation
	}
	if !budgets[budget].live || budgets[budget].amounts.pages < page_count {
		return 0, .No_Budget
	}
	for &region, slot in regions[1:] {
		if region.page_count == 0 {
			physical := frames_allocate(page_count)
			if physical == 0 {
				return 0, .No_Memory
			}
			budgets[budget].amounts.pages -= page_count
			region = {physical = physical, page_count = page_count, budget = budget}
			return u32(slot + 1), .Ok
		}
	}
	return 0, .No_Slot
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
			budgets[region.budget].amounts.pages += region.page_count
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
		case .Budget:
			budgets[slot.object].references += 1
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
				program_free(target)
			} else {
				program_stop(slot.object, op.STOP_CODE_NO_HANDLE)
			}
		}
	case .Thread:
		thread := &threads[slot.object]
		thread.references -= 1
		if thread.references == 0 && thread.state == .Stopped {
			thread_free(thread)
		}
	case .Budget:
		budget_release(slot.object)
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
	// No page is both writable and executable.
	if .Write in flags && .Execute in flags {
		return 0, .Bad_Operation
	}
	bits := PAGE_PRESENT | PAGE_USER
	if .Write in flags {
		bits |= PAGE_WRITE
	}
	if .Execute not_in flags {
		bits |= PAGE_NO_EXECUTE
	}
	for page in 0 ..< count {
		entry := page_entry(program.table, address + page * PAGE_SIZE, true, program.budget)
		if entry == nil {
			for undo in 0 ..< page {
				page_entry(program.table, address + undo * PAGE_SIZE, false)^ = 0
			}
			return 0, budgets[program.budget].amounts.pages == 0 ? .No_Budget : .No_Memory
		}
		entry^ = (region.physical + (first + page) * PAGE_SIZE) | bits
	}
	mapping^ = {address = address, page_count = count, region = region_index}
	region.references += 1
	program.mapped_pages += count
	return address, .Ok
}

// unmap removes a mapping. Before the memory object can end, each
// processor that uses the page table of the program forgets the mapping.
unmap :: proc "contextless" (program: ^Program, mapping: ^Mapping) {
	self := processor_self()
	for page in 0 ..< mapping.page_count {
		address := mapping.address + page * PAGE_SIZE
		entry := page_entry(program.table, address, false)
		if entry != nil {
			entry^ = 0
			if self.table == program.table {
				page_flush(address)
			}
		}
	}
	others: u64
	for cpu in processors[:processor_count] {
		if cpu != self && cpu.table == program.table {
			others |= 1 << cpu.index
		}
	}
	processor_sync(others)
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

// program_create makes a program with no memory. The budget pays for the
// slot and for the page tables.
program_create :: proc "contextless" (budget: u32, name: []u8) -> (index: u32, status: op.Status) {
	if !budgets[budget].live || budgets[budget].amounts.programs == 0 || budgets[budget].amounts.pages == 0 {
		return 0, .No_Budget
	}
	for &program, slot in programs[1:] {
		if program.state != .None {
			continue
		}
		program = {}
		program.table = address_space_create()
		if program.table == 0 {
			return 0, .No_Memory
		}
		budgets[budget].amounts.pages -= 1
		budgets[budget].amounts.programs -= 1
		program.budget = budget
		program.next_address = op.CHOSEN_BASE
		copy(program.name[:len(program.name) - 1], name)
		program.state = .Created
		program.start_time = microseconds(cycles_now())
		return u32(slot + 1), .Ok
	}
	return 0, .No_Slot
}

// program_free frees the slot of a stopped program that no handle names.
program_free :: proc "contextless" (program: ^Program) {
	program.state = .None
	budgets[program.budget].amounts.programs += 1
}

// thread_free frees the slot of a stopped thread that no handle names.
thread_free :: proc "contextless" (thread: ^Thread) {
	thread.state = .None
	budgets[thread.budget].amounts.threads += 1
}

// thread_create adds a thread to a program. The kernel makes the thread
// area: the thread record and the kernel ring of the thread.
// The budget pays for the slot and for the thread area.
thread_create :: proc "contextless" (program_index: u32, budget: u32, entry, stack, parameter: u64) -> (index: u32, status: op.Status) {
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
	if !budgets[budget].live || budgets[budget].amounts.threads == 0 {
		return 0, .No_Budget
	}
	region := region_create(budget, 1 + ring.PAGE_COUNT) or_return
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
		budget = budget,
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
	wake_needed += 1
	budgets[budget].amounts.threads -= 1
	program.thread_areas |= 1 << number
	program.thread_count += 1
	return index, .Ok
}

// thread_end marks a thread as stopped. The slot stays until the last
// handle to the thread closes: a handle never names another thread.
@(private = "file")
thread_end :: proc "contextless" (thread: ^Thread) {
	index := u32(intrinsics.ptr_sub(thread, &threads[0]))
	if thread.processor != 0 {
		// The thread leaves its processor. Another processor learns it at
		// its next kernel entry, and processor_sync waits for that entry:
		// after it, that processor does not use the thread.
		cpu := processors[thread.processor - 1]
		intrinsics.atomic_store(&cpu.current, 0)
		thread.processor = 0
		if cpu != processor_self() {
			processor_sync(1 << cpu.index)
		}
	}
	thread.state = .Stopped
	if thread.references == 0 {
		thread_free(thread)
	}
	thread.ring = nil
	for cpu in processors[:processor_count] {
		if cpu.record_thread == index {
			cpu.record_thread = 0 // The slot can get a new thread.
		}
	}
}

// thread_ready ends the wait of a thread.
thread_ready :: proc "contextless" (thread: ^Thread) {
	thread.state = .Ready
	wake_needed += 1
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
				thread_ready(&thread)
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
					thread_ready(&thread)
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
	// No processor keeps the page table or the ports of the program.
	self := processor_self()
	others: u64
	for cpu in processors[:processor_count] {
		if cpu.ports_loaded == index {
			ports_switch(cpu, 0)
		}
		if cpu.table != program.table {
			continue
		}
		if cpu == self {
			cpu.table = kernel_table
			cr3_write(kernel_table)
		} else {
			others |= 1 << cpu.index
		}
	}
	processor_sync(others)
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
	budgets[program.budget].amounts.pages += address_space_free(program.table)
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
		program_free(program)
	}
}

// ports_switch closes the ports of the program that had them on a
// processor, and opens the ports of program index.
ports_switch :: proc "contextless" (cpu: ^Processor, index: u32) {
	if cpu.ports_loaded == index {
		return
	}
	for pass in 0 ..< 2 {
		program := &programs[pass == 0 ? cpu.ports_loaded : index]
		if !program.has_ports {
			continue
		}
		for slot in program.handles {
			if slot.kind == .Ports {
				ports_allow(cpu, u64(slot.object), u64(slot.count), pass == 1)
			}
		}
	}
	cpu.ports_loaded = index
}

// schedule runs the next thread that is ready and that no processor runs.
// With none, the processor waits for an interrupt. The caller holds the
// kernel lock.
schedule :: proc "contextless" () -> ! {
	cpu := processor_self()
	if cpu.current != 0 {
		threads[cpu.current].processor = 0
		cpu.current = 0
	}
	for {
		alive := false
		for step in 1 ..= u32(THREAD_TABLE_CAPACITY) {
			index := (last_run + step) % THREAD_TABLE_CAPACITY
			thread := &threads[index]
			if index == 0 || thread.state == .None || thread.state == .Stopped {
				continue
			}
			alive = true
			if thread.state != .Ready || thread.processor != 0 {
				continue
			}
			cpu.current = index
			thread.processor = cpu.index + 1
			last_run = index
			cpu.slice_left = TIME_SLICE
			run(cpu, thread)
		}
		if !alive {
			log("kernel: no program is left")
			machine_stop(0)
		}
		cpu.idle = true
		if cpu.index != 0 {
			timer_pause(true)
		}
		lock_release()
		idle_wait()
		lock_acquire(cpu)
		cpu.idle = false
		if cpu.index != 0 {
			timer_pause(false)
		}
	}
}

// run gives the processor to its current thread, and frees the kernel lock.
run :: proc "contextless" (cpu: ^Processor, thread: ^Thread) -> ! {
	program := &programs[thread.program]
	ports_switch(cpu, program.has_ports ? thread.program : 0)
	if cpu.table != program.table {
		cpu.table = program.table
		cr3_write(program.table)
	}
	// Two programs have thread records at the same address. The test is on
	// the thread, so a program that changes its gs register harms only itself.
	if cpu.record_thread != cpu.current {
		cpu.record_thread = cpu.current
		msr_write(MSR_KERNEL_GS_BASE, thread.record)
	}
	cpu.fpu_area = &thread.fpu
	if thread.in_enter {
		thread.in_enter = false
		thread.frame.rax = ticks
	}
	lock_release()
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
	if !from_program && frame.vector < VECTOR_INTERRUPT_BASE {
		// The processor can hold the kernel lock: it does not take it.
		name := EXCEPTION_NAMES[frame.vector]
		address := cr2_read()
		log_serial_only = true
		log("kernel: exception in the kernel: ", name, " vector ", frame.vector, " error ", Hex(frame.error), " at ", Hex(frame.rip), " address ", Hex(address), ": ", fault_reason(frame, address))
		machine_stop(2)
	}
	cpu := processor_self()
	sync_acknowledge(cpu)
	lock_acquire(cpu)
	// Another processor took the thread away: the thread ended. This entry
	// is not an entry of a thread.
	taken := from_program && cpu.current == 0
	if from_program && !taken {
		threads[cpu.current].frame = frame^
	}
	switch {
	case frame.vector == VECTOR_KERNEL_ENTER:
		entry_count += 1
		if !taken {
			enter(cpu.current)
		}
	case frame.vector == VECTOR_TIMER:
		if from_program && !taken {
			cpu.busy_time += 1
			threads[cpu.current].run_time += 1
			programs[threads[cpu.current].program].run_time += 1
			cpu.slice_left -= min(cpu.slice_left, 1)
		}
		// The first processor counts the time.
		if cpu.index == 0 {
			ticks += 1
			for &thread in threads[1:] {
				if thread.state == .Waiting && thread.deadline <= ticks {
					thread_ready(&thread)
				}
			}
		}
		apic_write(APIC_END, 0)
	case frame.vector == VECTOR_WAKE || frame.vector == VECTOR_SYNC:
		apic_write(APIC_END, 0)
	case frame.vector == VECTOR_SPURIOUS:
	case frame.vector >= VECTOR_INTERRUPT_BASE && frame.vector < VECTOR_INTERRUPT_BASE + INTERRUPT_LINES:
		line := frame.vector - VECTOR_INTERRUPT_BASE
		interrupt_count += 1
		interrupt_pending[line] += 1
		if owner := interrupt_owner[line]; owner != 0 {
			program_event(owner)
		}
		interrupt_end(line)
	case taken:
	case:
		// A fault in one thread stops the program: the threads share all
		// their memory.
		name := frame.vector < 32 ? EXCEPTION_NAMES[frame.vector] : ""
		program := threads[cpu.current].program
		log_in("fault", .Warning, "kernel: program ", program_name(&programs[program]), " stopped: ", name, " vector ", frame.vector, " error ", Hex(frame.error), " at ", Hex(frame.rip), " address ", Hex(cr2_read()))
		program_stop(program, op.STOP_CODE_FAULT + u32(frame.vector))
	}
	if !from_program {
		// The processor was idle. It looks for a thread itself.
		cpu.idle = false
		wake_needed -= min(wake_needed, 1)
		lock_release()
		return
	}
	// The thread that entered continues, unless it waits, it stopped, or its
	// time slice is over.
	if cpu.current != 0 {
		thread := &threads[cpu.current]
		if thread.state == .Ready && cpu.slice_left > 0 {
			run(cpu, thread)
		}
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
