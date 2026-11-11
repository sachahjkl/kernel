package kernel

import "contract:errors"
import "contract:ring"
import "base:intrinsics"
import op "contract:operation"

// K1 and K3: the objects, the handle tables, the programs and the scheduler.
// All tables are flat arrays with a fixed capacity. Index 0 of each table is
// not used, so that 0 means "none".

USER_END :: u64(op.USER_END)
REGION_CAPACITY :: 2048
PROGRAM_CAPACITY :: 64
HANDLE_CAPACITY :: 128
MAPPING_CAPACITY :: 128

// A memory object: pages, each with a page frame or with none yet.
//
// A page on first use gets its page frame at the first read or write, by a
// program (a page fault) or by the kernel (user_range). The budget paid for
// each page when the object was created: the page is reserved, so a free
// page frame exists for it at any time, and an access never fails for lack
// of memory. A page that nobody touched costs no page frame and no zeroing.
//
// The frames of an object that is not contiguous are in its frame list:
// in `frames` for at most REGION_INLINE_PAGES pages; else one list page of
// 512 frames, or for more pages a top page of list pages. The budget pays
// for the list pages too. 0 in the list: the page has no frame yet.
//
// A contiguous object has its frames in one block from `physical`, all
// given at creation: device memory, and the memory that the kernel itself
// reads through the direct map (a thread area, the first program).
REGION_INLINE_PAGES :: op.MEMORY_INLINE_PAGES
LIST_ENTRIES :: op.MEMORY_LIST_ENTRIES

Region :: struct {
	physical:   u64, // Contiguous: the first frame.
	page_count: u64, // 0: the slot is free.
	frames:     [REGION_INLINE_PAGES]u64, // Not contiguous: the frame list (see above).
	present:    u64, // Pages that have a frame.
	references: u32, // Handles and mappings.
	budget:     u32, // The budget that paid. 0 for a device.
	device:     bool, // The frames are not from the page frame table: a framebuffer, boot data, the registers of a device.
	contiguous: bool,
	uncached:   bool, // The registers of a device: a mapping uses no cache.
	serial:     u64, // A number that no other memory object has had: a slot of the table serves many objects in time.
}

region_serial: u64 // The serial of the last memory object.
// The reserved pages: paid by a budget, with no page frame yet. The kernel
// keeps free_frames = the pages of all the budgets + reserved_pages.
reserved_pages: u64

// The `object` of a handle slot, by kind:
//   Memory: index in regions       Program: index in programs
//   Interrupt: index in the interrupt tables (INTERRUPT_CAPACITY)
//   Ports: first port; count: number of ports
//   Thread: index in threads       Budget: index in budgets
Object_Kind :: op.Object_Kind

// The rights of the handle of a new object, by kind.
RIGHTS_MEMORY :: op.Rights{.Give, .Read, .Write, .Execute}
RIGHTS_PROGRAM :: op.Rights{.Give, .Read, .Control}
RIGHTS_THREAD :: op.Rights{.Give, .Read, .Control}
RIGHTS_PORTS :: op.Rights{.Give}
RIGHTS_INTERRUPT :: op.Rights{.Give, .Read}
RIGHTS_MACHINE :: op.Rights{.Give, .Inspect, .Devices, .Stop, .Physical, .Schedule}
RIGHTS_BUDGET :: op.Rights{.Give, .Read, .Spend}
RIGHTS_LOG :: op.Rights{.Give, .Write}

Handle_Slot :: struct {
	kind:       Object_Kind,
	ended:      u8, // An empty slot: how the handle of the generation before ended (errors.End). For an error record.
	generation: u16,
	rights:     op.Rights,
	object:     u32,
	count:      u32,
	through:    u64, // Not 0: the serial of the memory object that the handle came through (Handle_Give).
}

Mapping :: struct {
	address:    u64,
	page_count: u64, // 0: the slot is free.
	first:      u64, // The first page of the memory object.
	bits:       u64, // The protection bits of each page table entry of the mapping.
	region:     u32,
	// The pages of the mapping whose entry is present. Written only where an
	// entry of the mapping becomes present or the mapping ends, each time
	// under the program lock: map_region, page_give, unmap. A report reads it
	// in place of a walk of the page table (its cost is one read for each
	// mapping, not one for each page).
	present_page_count: u64,
}

// A thread: one flow of execution in a program. It is a register state and
// a kernel ring. Its stack is memory of the program: the kernel does not
// know it.
//
// The first 64 bytes are the hot line of the scheduler: what a pick, a wake
// and a tick read (docs/SCHEDULING.md, "The hot data"). The record is
// aligned on 64 bytes, so the line is one cache line.
Thread :: struct #align (64) {
	// Scheduling (schedule.odin, strategy.odin), under the run lock of home.
	state:          op.Program_State, // None, Ready, Waiting or Stopped.
	home:           u32, // The processor whose run queue the thread is in, or was in last.
	queue_next:     u32,
	queue_previous: u32,
	processor:      u32, // 1 + the index of the processor that runs the thread. 0: none.
	budget:         u32, // The budget that paid for the slot. Written under the frame lock (atomic).
	weight:         u32, // 1 to op.WEIGHT_FULL. Written at the creation only.
	request:        u32, // Microseconds: the request of EEVDF. Written at the creation only.
	// The fields of the strategy of the queue of home (strategy.odin). Zero
	// is valid for each strategy: the thread is not placed.
	virtual:          u64, // The virtual time.
	virtual_deadline: u64, // EEVDF.
	lag:              i64, // At the last wait: EEVDF, the lag; fair, the distance to the queue clock.
	queued:           bool,
	placed:           bool, // The strategy placed the thread: virtual means something.
	frame:        Frame,
	fpu:          Fpu_State,
	program:      u32,
	number:       u32, // The index of the thread area in the program.
	ring:         ring.Ring,
	record:       u64, // The address of the thread record in the program.
	events:       ^u32, // The `events` word of the thread record, for the kernel.
	deadline:     u64,
	references:   u32, // Handles to this thread.
	in_enter:     bool,
	run_time:     u64,
	// The word wait of the entry in progress or of the wait in progress:
	// the physical addresses of the words.
	words:        [op.WORD_WAIT_CAPACITY]u64,
	word_count:   u32, // The words registered in the wait table (wait.odin).
	word_changed: bool, // A word did not hold the value: this entry does not wait.
	wait_serial:  u32, // Changes when a wait ends: wait.odin. Run lock of home.
	woken:        bool, // A waker came while the thread registered its words. Run lock of home.
	stop_requested: bool, // Another processor ends the thread: its processor ends it (atomic).
	finished:     bool, // thread_finish ran: the thread area is free. Control lock.
	serial:       u32, // Changes for each new thread in the slot (the record of the gs register).
}

#assert(offset_of(Thread, placed) < 64)
#assert(offset_of(Thread, frame) == 64)

// word_address gives the physical address of a 32-bit word of a program,
// or 0 if the program cannot read it.
word_address :: proc "contextless" (program: ^Program, address: u64) -> u64 {
	if address & 3 != 0 || !user_range(program, address, 4, false) {
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
	modules:      [op.PROGRAM_MODULE_CAPACITY]op.Module_Record, // What the loaders asserted (Program_Module).
	stop:         op.Stop_Report, // A program that stopped on a fault: where.
	// The processors that run a thread of the program, plus 1 while a stop
	// marks the threads; HOLDS_STOPPED when the marks are done (atomic).
	holds:        u64,
	ports_serial: u64, // Changes with each Ports handle of the program. It stays when the slot serves a new program.
	cleaned:      bool, // program_cleanup ran: the slot can be free when no handle names it. Control lock.
	serial:       u32, // Changes for each new program in the slot. It stays when the slot serves a new program.
}

HOLDS_STOPPED :: u64(1) << 32

// An operation that needs the control lock gives this status: enter.odin
// runs it again with the control lock. No program sees it.
STATUS_RETRY :: op.Status(0xFFFF)

// program_leave says that a processor left a thread of a program. true:
// it was the last one after a stop, and the caller cleans the program up.
program_leave :: proc "contextless" (index: u32) -> bool {
	return intrinsics.atomic_sub(&programs[index].holds, 1) - 1 == HOLDS_STOPPED
}

// program_module records a module that a loader put in a program, replaces
// the record with the same base, or removes it (size 0). Two records do not
// share an address.
program_module :: proc "contextless" (program: ^Program, record: op.Module_Record) -> op.Status {
	if record.size != 0 && (record.base >= op.USER_END || record.size > op.USER_END - record.base) {
		return .Bad_Address
	}
	place: ^op.Module_Record
	for &item in program.modules {
		if item.size != 0 && item.base == record.base {
			place = &item
		} else if item.size != 0 && record.size != 0 && record.base < item.base + item.size && item.base < record.base + record.size {
			return .Bad_Address
		} else if item.size == 0 && place == nil {
			place = &item
		}
	}
	if place == nil {
		return .No_Slot
	}
	if record.size == 0 && (place.size == 0 || place.base != record.base) {
		return .Bad_Address
	}
	place^ = record.size == 0 ? {} : record
	return .Ok
}

// module_of gives the module record of a program that holds an address, or nil.
module_of :: proc "contextless" (program: ^Program, address: u64) -> ^op.Module_Record {
	for &item in program.modules {
		if item.size != 0 && address >= item.base && address - item.base < item.size {
			return &item
		}
	}
	return nil
}

// hash_head gives the first 8 bytes of a hash as a number: its hexadecimal
// text is the text of these bytes.
hash_head :: proc "contextless" (hash: [32]u8) -> Hex {
	value: u64
	for index in 0 ..< 8 {
		value = value << 8 | u64(hash[index])
	}
	return Hex(value)
}

BUDGET_CAPACITY :: 128

// A budget: see operation.Budget_Amounts. Budget 0 is not live: it holds
// what returned to no budget.
Budget :: struct {
	live:       bool,
	parent:     u32, // The budget that this budget came from. It is live, or it is 0.
	references: u32, // Handles to this budget.
	amounts:    op.Budget_Amounts,
	// limit.odin:
	spent:       u64, // Cycles of processor time in this period, and what was above the part of the periods before.
	spent_total: u64, // Cycles of processor time since the budget was made.
	logged:      u64, // The second (high 32 bits) and the log records in it (low 32 bits): limit.odin.
	refused:     u64, // Log records that the kernel refused.
	ended:       bool, // The slot held a budget that ended: a tick can still walk through it (budget_create).
}

budgets: [BUDGET_CAPACITY]Budget
regions: [REGION_CAPACITY]Region
programs: [PROGRAM_CAPACITY]Program
threads: [THREAD_TABLE_CAPACITY]Thread
interrupt_owner: [INTERRUPT_CAPACITY]u32 // A program.
interrupt_pending: [INTERRUPT_CAPACITY]u32
interrupt_references: [INTERRUPT_CAPACITY]u32 // Handles. A message interrupt with none is free.
// The milliseconds since the kernel made the time page. The tick of the
// first processor writes it, from the cycle counter: a tick that comes late
// loses no time. It never goes back.
time_milliseconds: u64
cycle_start: u64 // The cycle counter at the time 0.
time_region: u32 // The memory object of the time page. It is in each program.
time_record: ^op.Time_Record

// budget_create moves amounts from a budget to a new budget.
budget_create :: proc "contextless" (parent: u32, amounts: op.Budget_Amounts) -> (index: u32, status: op.Status) {
	from := &budgets[parent]
	lock_take(&frame_lock, .Frame)
	defer lock_free(&frame_lock, .Frame)
	if !from.live || amounts.pages > from.amounts.pages || amounts.programs > from.amounts.programs || amounts.threads > from.amounts.threads || amounts.processor > from.amounts.processor || amounts.log_records > from.amounts.log_records {
		return 0, .No_Budget
	}
	for &budget, slot in budgets[1:] {
		if !budget.live {
			if budget.ended {
				// A tick or a log record can walk the chain of a thread
				// through this slot: after processor_sync, none does.
				processor_sync(all_other_processors())
			}
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
	// A copy of a Budget handle in its own program adds 1 with no control
	// lock: the count is atomic.
	if intrinsics.atomic_sub(&budget.references, 1) != 1 {
		return
	}
	parent := budget.parent
	lock_take(&frame_lock, .Frame)
	defer lock_free(&frame_lock, .Frame)
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
			intrinsics.atomic_store(&program.budget, parent) // read_log_count reads it with an atomic load.
		}
	}
	for &thread in threads {
		if thread.state != .None && thread.budget == index {
			intrinsics.atomic_store(&thread.budget, parent)
		}
	}
	for &other in budgets {
		if other.live && other.parent == index {
			intrinsics.atomic_store(&other.parent, parent)
		}
	}
	budget^ = {ended = true, parent = parent}
}

list_pages :: op.memory_list_pages

// region_cost gives the pages that a budget pays for a memory object.
region_cost :: proc "contextless" (page_count: u64, contiguous: bool) -> u64 {
	return contiguous ? page_count : op.memory_cost(page_count)
}

// frame_take gives one page frame, not zero, for a page that a budget
// reserved or paid (memory.odin, frame_take_held): it cannot fail. The
// caller holds the frame lock.
@(private = "file")
frame_take :: proc "contextless" () -> u64 {
	return frame_take_held()
}

// region_create makes a memory object. The budget pays for its pages and
// for its frame list. A contiguous object has all its frames now; another
// one has its frames at first use, or now with `now`.
region_create :: proc "contextless" (budget: u32, page_count: u64, contiguous := false, now := false) -> (index: u32, status: op.Status) {
	if page_count == 0 || !contiguous && page_count > op.MEMORY_PAGE_LIMIT {
		return 0, .Bad_Operation
	}
	cost := region_cost(page_count, contiguous)
	// One section of the frame lock: the budget pays, the slot is taken, the
	// frames of a contiguous object or of the frame list are taken, the pages
	// are reserved. The frames are zero filled after the section.
	lock_take(&frame_lock, .Frame)
	if !budgets[budget].live || budgets[budget].amounts.pages < cost {
		lock_free(&frame_lock, .Frame)
		return 0, .No_Budget
	}
	index = region_slot_take()
	if index == 0 {
		lock_free(&frame_lock, .Frame)
		return 0, .No_Slot
	}
	region := &regions[index]
	region^ = {page_count = page_count, budget = budget, contiguous = contiguous, serial = region.serial}
	if contiguous {
		region.physical = frames_take(page_count)
		if region.physical == 0 {
			// Frames in the stacks of the processors can make the run.
			caches_drain()
			region.physical = frames_take(page_count)
		}
		if region.physical == 0 {
			region^ = {serial = region.serial}
			lock_free(&frame_lock, .Frame)
			return 0, .No_Memory
		}
		region.present = page_count
	} else {
		// The budget has the cost: free frames for the list exist, and
		// after the payment free_frames stays >= reserved_pages.
		lists := list_pages(page_count)
		if lists != 0 {
			region.frames[0] = frame_take()
		}
		reserved_pages += page_count
	}
	budgets[budget].amounts.pages -= cost
	lock_free(&frame_lock, .Frame)
	if contiguous {
		frames_zero(region.physical, page_count)
	} else if lists := list_pages(page_count); lists != 0 {
		frames_zero(region.frames[0], 1)
		if lists > 1 {
			lock_take(&frame_lock, .Frame)
			for list in 1 ..< lists {
				direct(region.frames[0], [LIST_ENTRIES]u64)[list - 1] = frame_take()
			}
			lock_free(&frame_lock, .Frame)
			for list in 1 ..< lists {
				frames_zero(direct(region.frames[0], [LIST_ENTRIES]u64)[list - 1], 1)
			}
		}
	}
	if now {
		for page in 0 ..< page_count {
			region_frame(region, page, true)
		}
	}
	return index, .Ok
}

region_hint: u32 // Where the search of a free slot starts. Frame lock.

// region_slot_take takes a free slot of the table of memory objects, and
// gives it a new serial. The caller holds the frame lock. 0: none.
@(private = "file")
region_slot_take :: proc "contextless" () -> u32 {
	for step in 0 ..< u32(REGION_CAPACITY - 1) {
		index := 1 + (region_hint + step) % (REGION_CAPACITY - 1)
		if regions[index].page_count == 0 {
			region_hint = index
			region_serial += 1
			regions[index].serial = region_serial
			return index
		}
	}
	return 0
}

region_device :: proc "contextless" (physical: u64, page_count: u64) -> u32 {
	lock_take(&frame_lock, .Frame)
	defer lock_free(&frame_lock, .Frame)
	index := region_slot_take()
	if index != 0 {
		regions[index] = {physical = physical, page_count = page_count, present = page_count, device = true, contiguous = true, serial = regions[index].serial}
	}
	return index
}

// region_slot gives the place of the frame of one page in the frame list of
// a memory object that is not contiguous.
@(private = "file")
region_slot :: proc "contextless" (region: ^Region, page: u64) -> ^u64 {
	switch {
	case region.page_count <= REGION_INLINE_PAGES:
		return &region.frames[page]
	case region.page_count <= LIST_ENTRIES:
		return &direct(region.frames[0], [LIST_ENTRIES]u64)[page]
	}
	list := direct(region.frames[0], [LIST_ENTRIES]u64)[page / LIST_ENTRIES]
	return &direct(list, [LIST_ENTRIES]u64)[page % LIST_ENTRIES]
}

// region_frame gives the page frame of one page of a memory object. With
// give, a page with no frame gets one now: a zero page. Without give, 0
// means that the page has no frame yet.
region_frame :: proc "contextless" (region: ^Region, page: u64, give: bool) -> u64 {
	if region.contiguous {
		return region.physical + page * PAGE_SIZE
	}
	slot := region_slot(region, page)
	frame := intrinsics.atomic_load(slot)
	if frame != 0 || !give {
		return frame
	}
	// The region lock gives the page one frame, when two processors give it
	// at one time. The frame is zero before the slot names it.
	index := u32(intrinsics.ptr_sub(region, &regions[0]))
	lock_take(&region_locks[index], .Region)
	frame = intrinsics.atomic_load(slot)
	if frame == 0 {
		frame = frame_reserved_take()
		frames_zero(frame, 1)
		intrinsics.atomic_store(slot, frame)
		intrinsics.atomic_add(&region.present, 1)
	}
	lock_free(&region_locks[index], .Region)
	return frame
}

// The lock of each memory object: it gives a page on first use one frame.
region_locks: [REGION_CAPACITY]Lock

// region_has_frame says if a page frame is a frame of a memory object.
region_has_frame :: proc "contextless" (region: ^Region, frame: u64) -> bool {
	if region.contiguous {
		return frame >= region.physical && frame - region.physical < region.page_count * PAGE_SIZE
	}
	for page in 0 ..< region.page_count {
		if region_frame(region, page, false) == frame {
			return true
		}
	}
	return false
}

region_release :: proc "contextless" (index: u32) {
	region := &regions[index]
	if intrinsics.atomic_sub(&region.references, 1) != 1 {
		return
	}
	// No handle and no mapping names the object: no other processor uses it.
	lock_take(&frame_lock, .Frame)
	switch {
	case region.device:
	case region.contiguous:
		frames_free_held(region.physical, region.page_count)
		budgets[region.budget].amounts.pages += region.page_count
	case:
		for page in 0 ..< region.page_count {
			if frame := region_frame(region, page, false); frame != 0 {
				frames_free_held(frame, 1)
			}
		}
		lists := list_pages(region.page_count)
		for list in 1 ..< lists {
			frames_free_held(direct(region.frames[0], [LIST_ENTRIES]u64)[list - 1], 1)
		}
		if lists != 0 {
			frames_free_held(region.frames[0], 1)
		}
		reserved_pages -= region.page_count - region.present
		budgets[region.budget].amounts.pages += region_cost(region.page_count, false)
	}
	region^ = {serial = region.serial}
	lock_free(&frame_lock, .Frame)
}

// handle_insert puts a handle in a free slot of a program. The caller holds
// the program lock; for a Ports or an Interrupt handle, also the control
// lock. A reference count is atomic: the caller holds a handle or a mapping
// of the object, so the count is not 0. 0: no free slot.
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
			intrinsics.atomic_add(&regions[slot.object].references, 1)
		case .Program:
			intrinsics.atomic_add(&programs[slot.object].references, 1)
		case .Thread:
			intrinsics.atomic_add(&threads[slot.object].references, 1)
		case .Budget:
			intrinsics.atomic_add(&budgets[slot.object].references, 1)
		case .Ports:
			intrinsics.atomic_store(&program.has_ports, true)
			ports_changed(program)
		case .Interrupt:
			intrinsics.atomic_store(&interrupt_owner[slot.object], index_of_program(program))
			interrupt_references[slot.object] += 1
		}
		return op.Handle(u32(index + 1) | u32(generation) << 16)
	}
	return 0
}

// handle_insert_undo takes back a handle that handle_insert just made and
// that no program saw: the origin tree refused it during a revocation.
handle_insert_undo :: proc "contextless" (program: ^Program, handle: op.Handle) {
	slot := &program.handles[u32(handle) & 0xFFFF]
	#partial switch slot.kind {
	case .Memory:
		intrinsics.atomic_sub(&regions[slot.object].references, 1)
	case .Program:
		intrinsics.atomic_sub(&programs[slot.object].references, 1)
	case .Thread:
		intrinsics.atomic_sub(&threads[slot.object].references, 1)
	case .Budget:
		intrinsics.atomic_sub(&budgets[slot.object].references, 1)
	}
	slot^ = {generation = slot.generation}
}

// handle_needs_control says if a handle of this kind changes data of the
// control lock when it is made or closed.
handle_needs_control :: proc "contextless" (kind: Object_Kind) -> bool {
	#partial switch kind {
	case .Memory, .Log, .Machine:
		return false
	}
	return true
}

index_of_program :: #force_inline proc "contextless" (program: ^Program) -> u32 {
	return u32(intrinsics.ptr_sub(program, &programs[0]))
}

// ports_changed makes each processor open the ports of the program again
// before it returns to a program: run checks ports_serial. The caller holds
// the control lock.
ports_changed :: proc "contextless" (program: ^Program) {
	intrinsics.atomic_add(&program.ports_serial, 1)
	processor_sync(all_other_processors())
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

// handle_close closes a handle of a program. The caller holds the program
// lock; for a kind of handle_needs_control, also the control lock.
handle_close :: proc "contextless" (program: ^Program, slot: ^Handle_Slot) {
	origin_detach(holding_of_handle(program, slot))
	#partial switch slot.kind {
	case .Memory:
		region_release(slot.object)
	case .Program:
		// A program runs only while a handle names it: nobody can stop a
		// program that no handle names. The stop waits for control_free.
		if intrinsics.atomic_sub(&programs[slot.object].references, 1) == 1 {
			stops_pending |= 1 << slot.object
		}
	case .Thread:
		thread := &threads[slot.object]
		if intrinsics.atomic_sub(&thread.references, 1) == 1 && thread.finished {
			thread_free(thread)
		}
	case .Budget:
		budget_release(slot.object)
	case .Interrupt:
		interrupt_references[slot.object] -= 1
		if interrupt_owner[slot.object] == index_of_program(program) {
			intrinsics.atomic_store(&interrupt_owner[slot.object], 0)
		}
	case .Ports:
		slot.kind = .None
		ports_changed(program)
	}
	slot^ = {generation = slot.generation + 1, ended = u8(errors.End.Closed)}
}

// map puts pages of a region in the address space of a program. origin is
// the memory handle that a program mapped (origin.odin), or 0.
map_region :: proc "contextless" (program: ^Program, region_index: u32, address: u64, flags: op.Map_Flags, first: u64, count: u64, origin: Holding = 0) -> (result: u64, status: op.Status) {
	region := &regions[region_index]
	count := count
	if count == 0 && first < region.page_count {
		count = region.page_count - first
	}
	if count == 0 || first >= region.page_count || count > region.page_count - first {
		return 0, .Bad_Address
	}
	address := address
	chosen := address == 0
	if chosen {
		address = program.next_address
	}
	size := count * PAGE_SIZE
	if address % PAGE_SIZE != 0 || address < PAGE_SIZE || address >= USER_END || size > USER_END - address {
		return 0, .Bad_Address
	}
	// A page on first use has no page table entry yet: the mappings say
	// which addresses are taken.
	mapping: ^Mapping
	for &candidate in program.mappings {
		if candidate.page_count == 0 {
			if mapping == nil {
				mapping = &candidate
			}
		} else if address < candidate.address + candidate.page_count * PAGE_SIZE && candidate.address < address + size {
			return 0, .Bad_Address
		}
	}
	if mapping == nil {
		return 0, .No_Slot
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
	if region.uncached {
		bits |= PAGE_NO_CACHE
	}
	// The origin first: during a revocation, a path with no control lock
	// adds no holding, and runs again under the control lock.
	holding := holding_of_mapping(program, mapping)
	if !origin_attach(holding, origin) {
		return 0, STATUS_RETRY
	}
	present_page_count: u64
	for page in 0 ..< count {
		entry := page_entry(program.table, address + page * PAGE_SIZE, true, &program.budget)
		if entry == nil {
			// Another thread of the program can have used a page that was
			// present: as in unmap, each processor forgets the entries.
			self := processor_self()
			for undo in 0 ..< page {
				page_entry(program.table, address + undo * PAGE_SIZE, false)^ = 0
				if intrinsics.atomic_load(&self.table) == program.table {
					page_flush(address + undo * PAGE_SIZE)
				}
			}
			intrinsics.atomic_thread_fence(.Seq_Cst)
			processor_sync(processors_with_table(program.table))
			origin_detach(holding)
			return 0, budgets[program.budget].amounts.pages == 0 ? .No_Budget : .No_Memory
		}
		// The tables exist now: a page fault never needs a table. A page
		// with no frame keeps an entry of 0 until its first use.
		frame := region_frame(region, first + page, false)
		entry^ = frame == 0 ? 0 : frame | bits
		present_page_count += frame == 0 ? 0 : 1
	}
	// Under the program lock of the program: each caller of map_region holds
	// it (Memory_Map through target_lock in enter.odin, program_create and
	// thread_create in this file, the start of the root service in main.odin).
	mapping^ = {address = address, page_count = count, first = first, bits = bits, region = region_index, present_page_count = present_page_count}
	if chosen {
		program.next_address += (count + 1) * PAGE_SIZE
	}
	intrinsics.atomic_add(&region.references, 1)
	program.mapped_pages += count
	return address, .Ok
}

// unmap removes a mapping. Before the memory object can end, each
// processor that uses the page table of the program forgets the mapping.
// The caller holds the program lock.
unmap :: proc "contextless" (program: ^Program, mapping: ^Mapping) {
	origin_detach(holding_of_mapping(program, mapping))
	self := processor_self()
	walked_present_pages: u64
	for page in 0 ..< mapping.page_count {
		address := mapping.address + page * PAGE_SIZE
		entry := page_entry(program.table, address, false)
		if entry != nil {
			walked_present_pages += entry^ & PAGE_PRESENT
			entry^ = 0
			if self.table == program.table {
				page_flush(address)
			}
		}
	}
	// The entries are 0 before the read of the tables of the processors: a
	// processor that loads the table after the read sees the 0 entries.
	intrinsics.atomic_thread_fence(.Seq_Cst)
	processor_sync(processors_with_table(program.table))
	// The test build checks the count of the present pages against the
	// walk that this loop made anyway: one comparison, no other walk.
	when LOCK_ORDER_CHECK {
		if walked_present_pages != mapping.present_page_count {
			present_count_broken(mapping, walked_present_pages)
		}
	}
	program.mapped_pages -= mapping.page_count
	region_release(mapping.region)
	mapping^ = {} // The count of the present pages ends with the mapping (under the program lock: the caller holds it).
}

// all_other_processors gives the set of the processors but this one.
all_other_processors :: proc "contextless" () -> (set: u64) {
	self := processor_self()
	for cpu in processors[:processor_count] {
		if cpu != self {
			set |= 1 << cpu.index
		}
	}
	return set
}

// processors_with_table gives the other processors that use a page table.
processors_with_table :: proc "contextless" (table: u64) -> (set: u64) {
	self := processor_self()
	for cpu in processors[:processor_count] {
		if cpu != self && intrinsics.atomic_load(&cpu.table) == table {
			set |= 1 << cpu.index
		}
	}
	return set
}

// mapping_at gives the mapping of a program that holds an address, or nil.
mapping_at :: proc "contextless" (program: ^Program, address: u64) -> ^Mapping {
	for &mapping in program.mappings {
		if mapping.page_count != 0 && address >= mapping.address && address - mapping.address < mapping.page_count * PAGE_SIZE {
			return &mapping
		}
	}
	return nil
}

// page_give makes the page of an address present in a program, for an
// access of the program (a page fault) or of the kernel (user_range). The
// page gets the frame of its memory object; a page on first use gets its
// zero frame now. The caller holds the program lock, so no other processor
// changes the tables or the mappings of the program meanwhile. A processor
// keeps no translation of an entry that was not present, so no other
// processor must forget anything: a thread there that faults on the same
// page waits for the lock, then finds the entry present and continues.
// false: the program has no mapping there, or it does not permit the access.
page_give :: proc "contextless" (program: ^Program, address: u64, write: bool, execute: bool) -> bool {
	mapping := mapping_at(program, address)
	if mapping == nil || write && mapping.bits & PAGE_WRITE == 0 || execute && mapping.bits & PAGE_NO_EXECUTE != 0 {
		return false
	}
	page := (address - mapping.address) / PAGE_SIZE
	entry := page_entry(program.table, mapping.address + page * PAGE_SIZE, false)
	if entry == nil {
		return false // map_region made the tables: this does not happen.
	}
	if entry^ & PAGE_PRESENT == 0 {
		entry^ = region_frame(&regions[mapping.region], mapping.first + page, true) | mapping.bits
		mapping.present_page_count += 1 // Under the program lock: the caller holds it (see above).
	}
	return true
}

// present_count_broken stops the machine of the test when the count of the
// present pages of a mapping is not what its page table holds.
present_count_broken :: proc "contextless" (mapping: ^Mapping, walked: u64) -> ! {
	intrinsics.atomic_store(&log_serial_only, true)
	log("kernel: the count of the present pages of a mapping is ", mapping.present_page_count, ", its page table holds ", walked)
	machine_stop(3)
}

// present_pages gives the pages of the mappings of a program that have a
// page frame.
present_pages :: proc "contextless" (program: ^Program) -> (count: u64) {
	for mapping in program.mappings {
		count += mapping.present_page_count
	}
	return count
}

// holds_region says if a program has a handle to a memory object.
holds_region :: proc "contextless" (program: ^Program, region: u32) -> bool {
	for &slot in program.handles {
		if slot.kind == .Memory && slot.object == region {
			return true
		}
	}
	return false
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

// time_page_create makes the time page. The kernel keeps one reference:
// the page stays when no program has it.
time_page_create :: proc "contextless" () -> bool {
	physical := frames_allocate(1)
	if physical == 0 {
		return false
	}
	time_region = region_device(physical, 1) // No budget pays for it, and no program frees it.
	if time_region == 0 {
		return false
	}
	regions[time_region].references = 1
	time_record = direct(physical, op.Time_Record)
	direct(physical, [PAGE_SIZE]u8)^ = {}
	time_record.cycle_frequency = cycle_frequency // timer_calibrate measured it.
	cycle_start = cycles_now()
	time_record.cycle_start = cycle_start
	return true
}

// program_create makes a program with no memory. The budget pays for the
// slot and for the page tables. The caller holds the control lock.
program_create :: proc "contextless" (budget: u32, name: []u8) -> (index: u32, status: op.Status) {
	if !budgets[budget].live || budgets[budget].amounts.programs == 0 || budgets[budget].amounts.pages == 0 {
		return 0, .No_Budget
	}
	for &program, slot in programs[1:] {
		if program.state != .None {
			continue
		}
		index = u32(slot + 1)
		taken := program_lock(index)
		defer program_unlock(index, taken)
		ports_serial := program.ports_serial
		serial := program.serial + 1
		program = {ports_serial = ports_serial, serial = serial, budget = budget}
		program.table = address_space_create(&program.budget)
		if program.table == 0 {
			program = {ports_serial = ports_serial, serial = serial}
			return 0, .No_Budget
		}
		budgets[budget].amounts.programs -= 1
		program.next_address = op.CHOSEN_BASE
		copy(program.name[:len(program.name) - 1], name)
		// The time page: read only. A program cannot remove it (Memory_Unmap).
		if _, map_status := map_region(&program, time_region, op.TIME_ADDRESS, {}, 0, 1); map_status != .Ok {
			address_space_free(program.table, &program.budget)
			budgets[budget].amounts.programs += 1
			program = {ports_serial = ports_serial, serial = serial}
			return 0, map_status
		}
		program.state = .Created
		program.start_time = microseconds(cycles_now())
		return index, .Ok
	}
	return 0, .No_Slot
}

// program_free frees the slot of a stopped program that no handle names,
// after its cleanup. Stopped alone does not say that the cleanup ran: a
// thread of it can still run on a processor. The caller holds the control
// lock.
program_free :: proc "contextless" (program: ^Program) {
	if program.state != .Stopped || !program.cleaned {
		return
	}
	program.state = .None
	budgets[program.budget].amounts.programs += 1
}

// thread_free frees the slot of a finished thread that no handle names.
// The caller holds the control lock.
thread_free :: proc "contextless" (thread: ^Thread) {
	intrinsics.atomic_store(&thread.state, .None)
	budgets[thread.budget].amounts.threads += 1
}

// thread_create adds a thread to a program. The kernel makes the thread
// area: the thread record and the kernel ring of the thread.
// The budget pays for the slot and for the thread area. The weight and the
// request are checked by the caller; 0 gives the full weight and the
// default request (docs/SCHEDULING.md). The caller holds the control lock.
thread_create :: proc "contextless" (program_index: u32, budget: u32, entry, stack, parameter: u64, weight: u64 = 0, request: u64 = 0) -> (index: u32, status: op.Status) {
	program := &programs[program_index]
	taken := program_lock(program_index)
	defer program_unlock(program_index, taken)
	// A stop marks each thread of the program once: a thread made after it
	// would run in a program that ends.
	if program.state != .Created && program.state != .Ready {
		return 0, .Bad_State
	}
	number := u32(op.THREAD_CAPACITY)
	for candidate in 0 ..< u32(op.THREAD_CAPACITY) {
		if program.thread_areas & (1 << candidate) == 0 {
			number = candidate
			break
		}
	}
	for &candidate, slot in threads[1:] {
		if candidate.state == .None && intrinsics.atomic_load(&candidate.references) == 0 {
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
	// The kernel reads the thread area through the direct map, as one
	// block: it is contiguous.
	region := region_create(budget, 1 + ring.PAGE_COUNT, contiguous = true) or_return
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
		processors = u32(processor_count),
	}
	thread_ring, _ := ring.open(direct(regions[region].physical + PAGE_SIZE, u8), ring.PAGE_COUNT)
	thread := &threads[index]
	serial := thread.serial + 1
	wait_serial := thread.wait_serial
	home := thread.home
	thread^ = {
		state = .Ready,
		program = program_index,
		budget = budget,
		number = number,
		ring = thread_ring,
		record = record,
		events = &direct(regions[region].physical, op.Thread_Record).events,
		serial = serial,
		wait_serial = wait_serial,
		home = home,
		weight = weight == 0 ? op.WEIGHT_FULL : u32(weight),
		request = request == 0 ? op.REQUEST_DEFAULT : u32(request),
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
	budgets[budget].amounts.threads -= 1
	program.thread_areas |= 1 << number
	program.thread_count += 1
	thread_queue(thread)
	return index, .Ok
}

// thread_stop ends one thread (docs/ARCHITECTURE.md, "The owner of a
// running thread"). A thread on a processor gets stop_requested, and its
// processor ends it (schedule); another thread ends now. The caller holds
// the control lock.
thread_stop :: proc "contextless" (index: u32) {
	thread := &threads[index]
	home := run_lock(thread)
	if thread.state == .None || thread.state == .Stopped {
		run_unlock(home)
		return
	}
	if running := thread.processor; running != 0 {
		intrinsics.atomic_store(&thread.stop_requested, true)
		run_unlock(home)
		if cpu := processors[running - 1]; cpu != processor_self() {
			apic_send(cpu.apic_id, VECTOR_WAKE)
			// The operation returns after the thread left its processor.
			if self := processor_self(); self.operation {
				self.stopped_thread, self.stopped_thread_serial = index, thread.serial
			}
		}
		return
	}
	queue_remove(thread)
	thread.state = .Stopped
	intrinsics.atomic_add(&thread.wait_serial, 1)
	run_unlock(home)
	thread_finish(index, thread.serial)
}

// thread_finish frees what an ended thread has: its entries in the wait
// table, its thread area. No processor runs the thread. The other threads
// of the program get an event: one of them can wait for this end. A
// program with no thread stops. The caller holds the control lock.
// `serial` names the thread: if the slot serves another thread now, this
// thread was finished already.
thread_finish :: proc "contextless" (index: u32, serial: u32) {
	thread := &threads[index]
	if thread.finished || thread.serial != serial {
		return
	}
	thread.finished = true
	wait_unregister(thread)
	program_index := thread.program
	program := &programs[program_index]
	taken := program_lock(program_index)
	thread.events = nil
	thread.ring = {}
	// Under the program lock: program_event, which holds only this lock,
	// never reads this slot as a thread of the program again, also when a
	// new thread of another program takes the slot.
	thread.program = 0
	running := program.state != .Stopped
	last := false
	if running {
		for &mapping in program.mappings {
			if mapping.page_count != 0 && mapping.address == thread.record {
				unmap(program, &mapping)
				break
			}
		}
		program.thread_areas &~= 1 << thread.number
		program.thread_count -= 1
		last = program.thread_count == 0
	}
	program_unlock(program_index, taken)
	if intrinsics.atomic_load(&thread.references) == 0 {
		thread_free(thread)
	}
	if last {
		program_stop(program_index, 0)
	} else if running {
		program_event(program_index)
	}
}

// program_event tells each thread of a program that an event arrived: see
// operation.Word. A thread that waits on its event word wakes. It takes the
// program lock: the thread area of a thread that ends is free only after.
program_event :: proc "contextless" (index: u32) {
	taken := program_lock(index)
	defer program_unlock(index, taken)
	for &thread in threads[1:] {
		if thread.program != index || thread.events == nil {
			continue
		}
		intrinsics.atomic_add(thread.events, 1)
		word_wake(physical_of(thread.events), max(u64))
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
		if thread.program == index && intrinsics.atomic_load(&thread.state) == .Ready {
			return .Ready
		}
	}
	return .Waiting
}

// program_stop ends a program (docs/ARCHITECTURE.md, "A program ends after
// its last thread leaves its processor"). Each thread that waits or is in a
// queue ends now; each thread on a processor gets stop_requested. The last
// of these processors to leave its thread, or this call if none runs one,
// cleans the program up. The caller holds the control lock.
program_stop :: proc "contextless" (index: u32, code: u32) {
	program := &programs[index]
	taken := program_lock(index)
	if program.state == .None || program.state == .Stopped {
		// Another stop marked the threads, and some can still be on their
		// processors: this operation also returns only after they left.
		if self := processor_self(); program.state == .Stopped && self.operation {
			self.stopped_programs |= 1 << index
			self.stopped_serials[index] = program.serial
		}
		program_unlock(index, taken)
		return
	}
	intrinsics.atomic_add(&program.holds, 1)
	// The state changes first: a handle that this program closes later can
	// name this program, and an operation of the program sees it.
	program.state = .Stopped
	program.code = code
	program_unlock(index, taken)
	self := processor_self()
	running: u64
	ended: [THREAD_TABLE_CAPACITY]bool
	for &thread, slot in threads[1:] {
		if thread.program != index {
			continue
		}
		home := run_lock(&thread)
		if thread.state != .None && thread.state != .Stopped {
			if thread.processor != 0 {
				intrinsics.atomic_store(&thread.stop_requested, true)
				running |= 1 << (thread.processor - 1)
			} else {
				queue_remove(&thread)
				thread.state = .Stopped
				intrinsics.atomic_add(&thread.wait_serial, 1)
				ended[slot + 1] = true
			}
		}
		run_unlock(home)
	}
	for slot in 1 ..< u32(THREAD_TABLE_CAPACITY) {
		if ended[slot] {
			thread_finish(slot, threads[slot].serial)
		}
	}
	for cpu in processors[:processor_count] {
		if running & (1 << cpu.index) != 0 && cpu != self {
			apic_send(cpu.apic_id, VECTOR_WAKE)
		}
	}
	// The operation returns after the threads left their processors.
	if running &~ (1 << self.index) != 0 && self.operation {
		self.stopped_programs |= 1 << index
		self.stopped_serials[index] = program.serial
	}
	if intrinsics.atomic_add(&program.holds, HOLDS_STOPPED - 1) + HOLDS_STOPPED - 1 == HOLDS_STOPPED {
		program_cleanup(index)
	}
}

// program_cleanup frees all that a stopped program has. No processor runs
// a thread of it. The caller holds the control lock.
program_cleanup :: proc "contextless" (index: u32) {
	program := &programs[index]
	for &thread, slot in threads[1:] {
		if thread.program == index && thread.state == .Stopped && !thread.finished {
			thread_finish(u32(slot + 1), thread.serial)
		}
	}
	taken := program_lock(index)
	program.thread_count = 0
	program.thread_areas = 0
	// No processor keeps the page table of the program.
	self := processor_self()
	if intrinsics.atomic_load(&self.table) == program.table {
		intrinsics.atomic_store(&self.table, kernel_table)
		cr3_write(kernel_table)
	}
	processor_sync(processors_with_table(program.table))
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
	address_space_free(program.table, &program.budget)
	program.table = 0
	program.cleaned = true
	program_unlock(index, taken)
	for &other, other_index in programs[1:] {
		other_slot := u32(other_index + 1)
		other_taken := program_lock(other_slot)
		holds := false
		if other.state != .None && other.state != .Stopped {
			for slot in other.handles {
				if slot.kind == .Program && slot.object == index {
					holds = true
					break
				}
			}
		}
		program_unlock(other_slot, other_taken)
		if holds {
			program_event(other_slot)
		}
	}
	if intrinsics.atomic_load(&program.references) == 0 {
		program_free(program)
	}
}

// ports_switch opens on a processor the ports of program index (0: none),
// when the program or its ports changed (ports_serial). A processor writes
// only its own port bitmap.
ports_switch :: proc "contextless" (cpu: ^Processor, index: u32) {
	serial := intrinsics.atomic_load(&programs[index].ports_serial)
	if cpu.ports_loaded == index && (index == 0 || cpu.ports_serial == serial) {
		return
	}
	if cpu.ports_loaded != 0 {
		for &b in cpu.task_state.ports {
			b = 0xFF
		}
	}
	if index != 0 {
		for &slot in programs[index].handles {
			if intrinsics.atomic_load(&slot.kind) == .Ports {
				ports_allow(cpu, u64(slot.object), u64(slot.count), true)
			}
		}
	}
	cpu.ports_loaded = index
	cpu.ports_serial = serial
}

EXCEPTION_NAMES := [32]string {
	0  = "division by zero",
	6  = "invalid instruction",
	8  = "double fault",
	13 = "protection fault",
	14 = "page fault",
}

// kernel_interrupt is where every interrupt, exception and kernel entry
// arrives. It takes no lock of its own: each path takes the locks of the
// data that it touches (docs/ARCHITECTURE.md, "Locks of the kernel").
@(require, linkage = "strong", link_name = "kernel_interrupt")
kernel_interrupt :: proc "c" (frame: ^Frame) {
	from_program := frame.cs & 3 != 0
	if !from_program && frame.vector < VECTOR_INTERRUPT_BASE {
		// The processor can hold any lock: it takes none.
		name := EXCEPTION_NAMES[frame.vector]
		address := cr2_read()
		intrinsics.atomic_store(&log_serial_only, true)
		log("kernel: exception in the kernel: ", name, " vector ", frame.vector, " error ", Hex(frame.error), " at ", Hex(frame.rip), " address ", Hex(address), ": ", fault_reason(frame, address))
		machine_stop(2)
	}
	cpu := processor_self()
	sync_acknowledge(cpu)
	// The thread of a program entry is the current thread of this
	// processor: no other processor takes it away.
	thread: ^Thread
	if from_program {
		thread = &threads[cpu.current]
		thread.frame = frame^
	}
	switch {
	case frame.vector == VECTOR_KERNEL_ENTER:
		cpu.entries += 1
		enter(cpu.current)
	case frame.vector == VECTOR_TIMER:
		if from_program {
			cpu.busy_time += 1
			thread.run_time += 1
			intrinsics.atomic_add(&programs[thread.program].run_time, 1)
			if strategy_tick(cpu, thread, budget_charge(cpu)) {
				cpu.slice_left = 0 // The strategy ends the turn.
			}
			if budget_spent(intrinsics.atomic_load(&thread.budget)) {
				cpu.slice_left = 0 // The budget has no time left in this period.
			}
		}
		// The first processor counts the time.
		if cpu.index == 0 {
			now := max(time_milliseconds, milliseconds_now())
			intrinsics.atomic_store(&time_milliseconds, now)
			intrinsics.volatile_store(&time_record.milliseconds, now)
			budget_period(now)
			// The deadlines: read with no lock, then checked under the run
			// lock by thread_wake.
			for &waiting in threads[1:] {
				if intrinsics.atomic_load(&waiting.state) == .Waiting && intrinsics.atomic_load(&waiting.deadline) <= now {
					thread_wake(&waiting, now)
				}
			}
		}
		apic_write(APIC_END, 0)
	case frame.vector == VECTOR_WAKE || frame.vector == VECTOR_SYNC:
		// A thread that woke on another processor preempts the thread
		// that runs here (kick). Interrupts are off in the kernel, so this
		// interrupt arrives either when the processor returns to a program
		// (from_program) or while it waits idle with no thread: then no
		// turn is to end, and the processor picks a thread anyway. A flag
		// for a thread that left its processor before the interrupt ends
		// the turn of the next thread (one more pass through schedule).
		if intrinsics.atomic_exchange(&cpu.preempt, false) && from_program {
			cpu.slice_left = 0
			cpu.preemptions += 1
			cpu.preempt_from = cycles_now()
		}
		apic_write(APIC_END, 0)
	case frame.vector == VECTOR_SPURIOUS:
	case frame.vector >= VECTOR_INTERRUPT_BASE && frame.vector < VECTOR_INTERRUPT_BASE + INTERRUPT_LINES:
		line := frame.vector - VECTOR_INTERRUPT_BASE
		cpu.interrupts += 1
		interrupt_signal(line)
		interrupt_end(line)
	case frame.vector >= VECTOR_MESSAGE_BASE && frame.vector < VECTOR_MESSAGE_BASE + op.MESSAGE_CAPACITY:
		cpu.interrupts += 1
		interrupt_signal(INTERRUPT_LINES + frame.vector - VECTOR_MESSAGE_BASE)
		apic_write(APIC_END, 0)
	case frame.vector == VECTOR_PAGE_FAULT && frame.error & FAULT_PRESENT == 0 && page_fault(thread.program, cr2_read(), frame.error):
		// A page on first use, or a page that another thread made present
		// while this one waited for the lock: the instruction runs again.
		cpu.first_use_faults += 1
	case:
		program_fault(thread.program, frame)
	}
	if !from_program {
		return // The processor was idle: it looks for a thread itself.
	}
	// The thread that entered continues, unless it waits, it ends, or its
	// time slice is over.
	if !intrinsics.atomic_load(&thread.stop_requested) && intrinsics.atomic_load(&thread.state) == .Ready && cpu.slice_left > 0 {
		run(cpu, thread)
	}
	schedule()
}

// interrupt_signal counts an interrupt and tells its owner. The owner is
// read with no lock: when the handle closes at the same time, the event
// can go to the program that held it.
interrupt_signal :: proc "contextless" (index: u64) {
	intrinsics.atomic_add(&interrupt_pending[index], 1)
	if owner := intrinsics.atomic_load(&interrupt_owner[index]); owner != 0 {
		program_event(owner)
	}
}

// page_fault gives a page on first use to a program, under its program
// lock. false: the program has no mapping there, or no right for the access.
page_fault :: proc "contextless" (index: u32, address: u64, error: u64) -> bool {
	taken := program_lock(index)
	defer program_unlock(index, taken)
	return page_give(&programs[index], address, error & FAULT_WRITE != 0, error & FAULT_EXECUTE != 0)
}

// program_fault stops the program of a thread that faulted. A fault in one
// thread stops the program: the threads share all their memory.
program_fault :: proc "contextless" (index: u32, frame: ^Frame) {
	control_take()
	defer control_free()
	program := &programs[index]
	taken := program_lock(index)
	name := frame.vector < 32 ? EXCEPTION_NAMES[frame.vector] : ""
	// The module of the instruction, as the loader recorded it: a
	// replacement names the module that runs, not the one of the import.
	found := module_of(program, frame.rip)
	// The first stop is the one that the report keeps: a program that a stop
	// or another fault already stopped keeps its code and its report.
	first := program.state != .Stopped && program.state != .None
	if first {
		program.stop = {code = op.STOP_CODE_FAULT + u32(frame.vector), vector = u32(frame.vector), instruction = frame.rip}
		if frame.vector == 14 {
			program.stop.address = cr2_read()
		}
		if found != nil {
			program.stop.module = found^
		}
	}
	if found == nil {
		log_in("fault", .Warning, "kernel: program ", program_name(program), " stopped: ", name, " vector ", frame.vector, " error ", Hex(frame.error), " at ", Hex(frame.rip), " address ", Hex(cr2_read()))
	} else if found.replaces == {} {
		log_in("fault", .Warning, "kernel: program ", program_name(program), " stopped: ", name, " vector ", frame.vector, " at ", Hex(frame.rip), " address ", Hex(cr2_read()), ", in module ", hash_head(found.hash), " at offset ", Hex(frame.rip - found.base))
	} else {
		log_in("fault", .Warning, "kernel: program ", program_name(program), " stopped: ", name, " vector ", frame.vector, " at ", Hex(frame.rip), " address ", Hex(cr2_read()), ", in module ", hash_head(found.hash), " at offset ", Hex(frame.rip - found.base), ", which replaces ", hash_head(found.replaces))
	}
	// The stack trace: the page table of the program is the one of this
	// processor, and the program lock is held (user_range, user_copy).
	if first {
		stack_trace(program, frame, &program.stop)
	}
	program_unlock(index, taken)
	program_stop(index, op.STOP_CODE_FAULT + u32(frame.vector))
}

program_name :: proc "contextless" (program: ^Program) -> string {
	count := 0
	for count < len(program.name) && program.name[count] != 0 {
		count += 1
	}
	return string(program.name[:count])
}
