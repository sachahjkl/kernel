package kernel

import "contract:errors"
import "contract:ring"
import "base:intrinsics"
import op "contract:operation"

// The objects, the handle tables, the programs and the scheduler
// (docs/ARCHITECTURE.md, "Handle table"; docs/ARCHITECTURE.md, "Scheduler").
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
	uncommitted: bool, // Made Uncommitted: a page is paid when it is committed (the bit SLOT_COMMITTED of its slot).
	large_pages: bool, // Made Large_Pages: contiguous, aligned on 2 MiB, a whole number of large pages.
	committed:  u64, // Uncommitted: the committed pages. Region lock and frame lock to change it.
	marked_pages: u64, // The pages whose slot has a mark of protection (Memory_Protect of a part). Region lock; read atomically.
	serial:     u64, // A number that no other memory object has had: a slot of the table serves many objects in time.
}

// The state of a page in its slot of the frame list (docs/ARCHITECTURE.md,
// "The virtual memory of a program", "The state of a page"): a frame is
// aligned on 4096 bytes, so the low 12 bits of a slot hold the state.
SLOT_COMMITTED :: u64(1) // Uncommitted objects only: the budget paid for the page.
SLOT_DENY_WRITE :: u64(1) << 1
SLOT_DENY_EXECUTE :: u64(1) << 2
SLOT_NO_ACCESS :: u64(1) << 3
SLOT_STATE :: u64(PAGE_SIZE - 1)
SLOT_MARKS :: SLOT_DENY_WRITE | SLOT_DENY_EXECUTE | SLOT_NO_ACCESS

// region_page_state gives the state bits of a page of an object with a
// frame list; 0 for a contiguous object.
region_page_state :: proc "contextless" (region: ^Region, page: u64) -> u64 {
	if region.contiguous {
		return 0
	}
	return intrinsics.atomic_load(region_slot(region, page)) & SLOT_STATE
}

// page_committed says if a page can have a frame: each page of an object
// that is not Uncommitted, a committed page of one that is.
page_committed :: #force_inline proc "contextless" (region: ^Region, state: u64) -> bool {
	return !region.uncommitted || state & SLOT_COMMITTED != 0
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
RIGHTS_MACHINE :: op.Rights{.Give, .Inspect, .Devices, .Stop, .Physical, .Schedule, .Events}
RIGHTS_BUDGET :: op.Rights{.Give, .Read, .Spend, .Commit}
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
	// The protection that the handle permitted when the program mapped the
	// object: Memory_Protect can give back what `bits` lost, never more.
	limit_bits: u64,
	large:      bool, // Each 2 MiB of the mapping is one large page (an object made Large_Pages).
	protected:  bool, // Memory_Protect changed the protection of pages of the mapping.
}

// page_bits gives the bits of a page table entry for a page of a mapping
// with its state bits (region_page_state): 0 is no access.
page_bits :: proc "contextless" (mapping: ^Mapping, state: u64) -> u64 {
	if mapping.bits & PAGE_PRESENT == 0 || state & SLOT_NO_ACCESS != 0 {
		return 0
	}
	bits := mapping.bits
	if state & SLOT_DENY_WRITE != 0 {
		bits &~= PAGE_WRITE
	}
	if state & SLOT_DENY_EXECUTE != 0 {
		bits |= PAGE_NO_EXECUTE
	}
	return bits
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
	extended_state: Extended_State_Area, // Complete while the thread is on no processor: schedule saves it when a processor leaves the thread, and restores it when a processor takes it (docs/ARCHITECTURE.md, "The extended state of the processor").
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
	// The thread record of the thread through the direct map: the kernel
	// writes the fault ring there when this thread is the fault handler of
	// its program. nil after thread_finish. Program lock.
	record_in_kernel: ^op.Thread_Record,
	// The thread waits in the fault ring for an answer (fault_ring.odin).
	// Written under the program lock; the thread is Waiting with no deadline
	// while it is true.
	fault_waits:   bool,
	fault_serial:  u64, // The serial of that fault: Program.fault_serial when it came. Program lock.
	fault_address: u64, // The address of the access of that fault. Program lock.
	// The control of a thread (thread_control.odin). The stop count: the
	// thread enters no run queue while it is above 0. Written under the
	// run lock of home (atomic: kernel_interrupt reads it with no lock).
	control_stops: u32,
	// Thread_Control wrote the registers or the extended state since the
	// last fault of the thread: Fault_Answer then accepts Resume for any
	// kind. Program lock.
	registers_written: bool,
}

#assert(offset_of(Thread, placed) < 64)
#assert(offset_of(Thread, frame) == 64)

// word_address gives the physical address of a 32-bit word of a program,
// or 0 if the program cannot read it.
word_address :: proc "contextless" (program: ^Program, address: u64) -> u64 {
	if address & 3 != 0 || !user_range(program, address, 4, false) {
		return 0
	}
	entry := page_entry(program.table, address)^
	// A large page: its frame is 2 MiB, and the bits 12 to 20 of the
	// address are in the page.
	if entry & PAGE_LARGE != 0 {
		return entry & PAGE_ADDRESS &~ u64(LARGE_PAGE_SIZE - 1) | address & (LARGE_PAGE_SIZE - 1)
	}
	return entry & PAGE_ADDRESS | address & (PAGE_SIZE - 1)
}

THREAD_TABLE_CAPACITY :: 256

Program :: struct {
	state:        op.Program_State, // None, Created, Ready or Stopped.
	code:         u32,
	name:         [32]u8,
	table:        u64,
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
	// The fault ring (fault_ring.odin), under the program lock. 0: no fault
	// handler, and every fault stops the program.
	fault_handler:        u32, // The thread whose thread record holds the fault ring.
	// The fault kinds of the handler: bit n is the vector n. 0 with no
	// handler. Written under the program lock with an atomic store, and read
	// with no lock by a fault first, so that a fault that is not delivered
	// takes no lock.
	fault_kinds:          u64,
	fault_handler_serial: u32,
	fault_written:        u32, // The records that the kernel wrote in that ring: the kernel's own count, not the one in memory of the program.
	fault_full:           u32, // The faults that found the ring full.
	fault_serial:         u64, // The faults given to a ring: the serial of the next record is one more. A count of this program only.
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

// uncommitted_base_cost gives the pages that the budget of an Uncommitted
// object pays at its creation: its frame list, at least one page.
uncommitted_base_cost :: proc "contextless" (page_count: u64) -> u64 {
	return max(list_pages(page_count), 1)
}

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
region_create :: proc "contextless" (budget: u32, page_count: u64, contiguous := false, now := false, uncommitted := false, large_pages := false) -> (index: u32, status: op.Status) {
	if page_count == 0 || !contiguous && page_count > op.MEMORY_PAGE_LIMIT {
		return 0, .Bad_Operation
	}
	// An uncommitted object pays its frame list only, and at least one page:
	// no budget holds a slot of the table of memory objects for nothing
	// for nothing.
	cost := uncommitted ? uncommitted_base_cost(page_count) : region_cost(page_count, contiguous)
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
	region^ = {page_count = page_count, budget = budget, contiguous = contiguous, serial = region.serial, uncommitted = uncommitted, large_pages = large_pages}
	if contiguous {
		alignment := large_pages ? u64(op.LARGE_PAGE_PAGES) : 1
		region.physical = frames_take_aligned(page_count, alignment)
		if region.physical == 0 {
			// Frames in the stacks of the processors can make the run.
			caches_drain()
			region.physical = frames_take_aligned(page_count, alignment)
		}
		if region.physical == 0 {
			region^ = {serial = region.serial}
			lock_free(&frame_lock, .Frame)
			return 0, .No_Memory
		}
		region.present = page_count
	} else {
		// The budget has the cost: free frames for the list exist. Each
		// list page is taken in this section, so that the sums of the frames
		// hold whenever the frame lock is free (memory.odin): a second
		// section took the other list pages before, and a report or a drain
		// between the two saw the budget paid for frames not yet taken.
		lists := list_pages(page_count)
		if lists != 0 {
			region.frames[0] = frame_take()
			for list in 1 ..< lists {
				direct(region.frames[0], [LIST_ENTRIES]u64)[list - 1] = frame_take()
			}
		}
		if !uncommitted {
			reserved_pages += page_count
		} else {
			// The page that an Uncommitted object with no list page pays
			// (uncommitted_base_cost) has no frame: it is a reserved page,
			// so the sums of the frames hold.
			reserved_pages += cost - lists
		}
	}
	budgets[budget].amounts.pages -= cost
	lock_free(&frame_lock, .Frame)
	if contiguous {
		frames_zero(region.physical, page_count)
	} else if lists := list_pages(page_count); lists != 0 {
		// The top page holds the frames of the other list pages: they are
		// zero filled first, then the top page keeps their frames.
		for list in 1 ..< lists {
			frames_zero(direct(region.frames[0], [LIST_ENTRIES]u64)[list - 1], 1)
		}
		if lists == 1 {
			frames_zero(region.frames[0], 1)
		} else {
			// The top page: zero after its first lists - 1 entries.
			top := direct(region.frames[0], [LIST_ENTRIES]u64)
			for &entry in top[lists - 1:] {
				entry = 0
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
	value := intrinsics.atomic_load(slot)
	frame := value & PAGE_ADDRESS
	if frame != 0 || !give || !page_committed(region, value) {
		return frame // A page that is not committed has no frame, and gets none.
	}
	// The region lock gives the page one frame, when two processors give it
	// at one time. The frame is zero before the slot names it. The state
	// bits of the slot stay.
	index := u32(intrinsics.ptr_sub(region, &regions[0]))
	lock_take(&region_locks[index], .Region)
	value = intrinsics.atomic_load(slot)
	frame = value & PAGE_ADDRESS
	if frame == 0 && page_committed(region, value) {
		frame = frame_reserved_take()
		frames_zero(frame, 1)
		intrinsics.atomic_store(slot, frame | value & SLOT_STATE)
		intrinsics.atomic_add(&region.present, 1)
	}
	lock_free(&region_locks[index], .Region)
	return frame
}

// The lock of each memory object: it gives a page on first use one frame.
region_locks: [REGION_CAPACITY]Lock

region_release :: proc "contextless" (index: u32) {
	region := &regions[index]
	if intrinsics.atomic_sub(&region.references, 1) != 1 {
		return
	}
	// No handle and no mapping names the object: no other processor uses it.
	// The test build checks the committed pages before the frame lock: the
	// walk of each slot of a large object does not hold the lock that each
	// processor needs to take a frame.
	when TEST_BUILD_CHECKS_FRAME_SUMS {
		if region.uncommitted {
			committed_slots: u64
			for page in 0 ..< region.page_count {
				committed_slots += intrinsics.atomic_load(region_slot(region, page)) & SLOT_COMMITTED
			}
			if committed_slots != region.committed {
				intrinsics.atomic_store(&log_serial_only, true)
				log("kernel: the committed pages of a memory object do not add up: slots ", committed_slots, ", count ", region.committed)
				machine_stop(3)
			}
		}
	}
	lock_take(&frame_lock, .Frame)
	switch {
	case region.device:
	case region.contiguous:
		frames_free_held(region.physical, region.page_count)
		budgets[region.budget].amounts.pages += region.page_count
	case:
		// The frames go to the stack of this processor: its next pages on
		// first use take them with no frame lock (memory.odin).
		// The walk ends at the last frame (`present`): an object of 1 GiB
		// with few frames is not walked to its end under the frame lock. The
		// bound that stays: an object whose last page has a frame is one
		// pass over its slots (262 144 for 1 GiB, 2 MiB read in order).
		cache := &processor_self().frame_cache
		lock_take(&cache.lock, .Cache)
		found: u64
		for page := u64(0); page < region.page_count && found < region.present; page += 1 {
			if frame := region_frame(region, page, false); frame != 0 {
				cache_put_held(cache, frame)
				found += 1
			}
		}
		lock_free(&cache.lock, .Cache)
		lists := list_pages(region.page_count)
		for list in 1 ..< lists {
			frames_free_held(direct(region.frames[0], [LIST_ENTRIES]u64)[list - 1], 1)
		}
		if lists != 0 {
			frames_free_held(region.frames[0], 1)
		}
		// The pages that the budget paid: all, or the committed ones; each
		// paid page with no frame is a reserved page.
		paid := region.uncommitted ? region.committed : region.page_count
		reserved_pages -= paid - region.present
		base := region.uncommitted ? uncommitted_base_cost(region.page_count) : list_pages(region.page_count)
		reserved_pages -= base - list_pages(region.page_count) // The page with no frame of a small Uncommitted object.
		budgets[region.budget].amounts.pages += base + paid
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
// lock; for a kind of handle_needs_control, and for a machine handle with
// the right Events, also the control lock.
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
	case .Machine:
		// The event table of the program lives while it has the right
		// Events (events.odin): a close and a revocation both come here.
		if .Events in slot.rights {
			event_right_closed(program, slot)
		}
	}
	slot^ = {generation = slot.generation + 1, ended = u8(errors.End.Closed)}
}

// map puts pages of a region in the address space of a program. origin is
// the memory handle that a program mapped (origin.odin), or 0.
map_region :: proc "contextless" (program: ^Program, region_index: u32, address: u64, flags: op.Map_Flags, first: u64, count: u64, origin: Holding = 0) -> (result: u64, status: op.Status) {
	region := &regions[region_index]
	// An object with marks of protection is mapped once: the marks are of
	// the object, and would reach a second mapping.
	if intrinsics.atomic_load(&region.marked_pages) != 0 {
		return 0, .Bad_State
	}
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
		// An object of large pages, mapped by whole large pages, gets an
		// address on 2 MiB.
		alignment := u64(PAGE_SIZE)
		if region.large_pages && first % op.LARGE_PAGE_PAGES == 0 && count % op.LARGE_PAGE_PAGES == 0 {
			alignment = LARGE_PAGE_SIZE
		}
		address = chosen_address(program, count, alignment)
		if address == 0 {
			return 0, .No_Slot // No gap below MODULE_BASE.
		}
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
	limit_bits := PAGE_PRESENT | PAGE_USER
	if .Write in flags {
		limit_bits |= PAGE_WRITE
	}
	if .Execute not_in flags {
		limit_bits |= PAGE_NO_EXECUTE
	}
	if region.uncached {
		limit_bits |= PAGE_NO_CACHE
	}
	// No_Access: the mapping has its addresses and no access until
	// Memory_Protect gives it some.
	bits := .No_Access in flags ? 0 : limit_bits
	// Large pages: an object made Large_Pages, and a mapping whose address,
	// first page and size are whole large pages.
	large := region.large_pages && address % LARGE_PAGE_SIZE == 0 && first % op.LARGE_PAGE_PAGES == 0 && count % op.LARGE_PAGE_PAGES == 0
	// The origin first: during a revocation, a path with no control lock
	// adds no holding, and runs again under the control lock.
	holding := holding_of_mapping(program, mapping)
	if !origin_attach(holding, origin) {
		return 0, STATUS_RETRY
	}
	present_page_count: u64
	// The tables that a failed map emptied: freed after its shoot-down.
	freed: Freed_Tables
	if large {
		for part in 0 ..< count / op.LARGE_PAGE_PAGES {
			entry := page_directory_entry_hold(program.table, address + part * LARGE_PAGE_SIZE, &program.budget, &freed)
			if entry == nil {
				// The status before the free: the freed tables return pages
				// to the budget.
				refusal: op.Status = budgets[program.budget].amounts.pages == 0 ? .No_Budget : .No_Memory
				self := processor_self()
				for undo in 0 ..< part {
					undo_address := address + undo * LARGE_PAGE_SIZE
					undo_entry := page_directory_entry(program.table, undo_address)
					if undo_entry == nil {
						page_table_count_broken("a held entry has no table")
					}
					undo_entry^ = 0
					if intrinsics.atomic_load(&self.table) == program.table {
						page_flush(undo_address)
					}
					page_entries_release(program.table, undo_address, 2, 1, &freed)
				}
				intrinsics.atomic_thread_fence(.Seq_Cst)
				processor_sync(processors_with_table(program.table))
				page_tables_free(program.table, &program.budget, &freed)
				origin_detach(holding)
				return 0, refusal
			}
			frame := region.physical + (first + part * op.LARGE_PAGE_PAGES) * PAGE_SIZE
			entry^ = bits == 0 ? 0 : frame | bits | PAGE_LARGE
			present_page_count += bits == 0 ? 0 : op.LARGE_PAGE_PAGES
		}
	}
	// One table of the last level at a time: one walk of the upper levels
	// and one addition to the count of the table for its run of pages.
	for page := u64(0); page < (large ? 0 : count); {
		run_address := address + page * PAGE_SIZE
		run := min(512 - (run_address >> 12 & 511), count - page)
		run_first_entry := page_entry_hold(program.table, run_address, run, &program.budget, &freed)
		if run_first_entry == nil {
			refusal: op.Status = budgets[program.budget].amounts.pages == 0 ? .No_Budget : .No_Memory
			// Another thread of the program can have used a page that was
			// present: as in unmap, each processor forgets the entries. The
			// runs of the undo are the runs of the map: the same start.
			self := processor_self()
			for undo := u64(0); undo < page; {
				undo_address := address + undo * PAGE_SIZE
				undo_run := min(512 - (undo_address >> 12 & 511), page - undo)
				undo_first_entry := page_entry(program.table, undo_address)
				if undo_first_entry == nil {
					page_table_count_broken("a held entry has no table")
				}
				undo_entries := ([^]u64)(undo_first_entry)
				for at in 0 ..< undo_run {
					if undo_entries[at] & PAGE_PRESENT != 0 {
						undo_entries[at] = 0
						if intrinsics.atomic_load(&self.table) == program.table {
							page_flush(undo_address + at * PAGE_SIZE)
						}
					}
				}
				page_entries_release(program.table, undo_address, 1, undo_run, &freed)
				undo += undo_run
			}
			intrinsics.atomic_thread_fence(.Seq_Cst)
			processor_sync(processors_with_table(program.table))
			page_tables_free(program.table, &program.budget, &freed)
			origin_detach(holding)
			return 0, refusal
		}
		// The tables exist now and hold the entries while the mapping
		// lives: a page fault never needs a table. A page with no frame
		// keeps an entry of 0 until its first use.
		run_entries := ([^]u64)(run_first_entry)
		for at in 0 ..< run {
			frame := region_frame(region, first + page + at, false)
			page_bits_now := frame == 0 ? 0 : page_bits(&Mapping{bits = bits}, region_page_state(region, first + page + at))
			run_entries[at] = page_bits_now == 0 ? 0 : frame | page_bits_now
			present_page_count += page_bits_now == 0 ? 0 : 1
		}
		page += run
	}
	// Under the program lock of the program: each caller of map_region holds
	// it (Memory_Map through target_lock in enter.odin, program_create and
	// thread_create in this file, the start of the root service in main.odin).
	mapping^ = {address = address, page_count = count, first = first, bits = bits, region = region_index, present_page_count = present_page_count, limit_bits = limit_bits, large = large}
	intrinsics.atomic_add(&region.references, 1)
	program.mapped_pages += count
	return address, .Ok
}

// chosen_address gives the lowest address from op.CHOSEN_BASE where count
// pages fit with one page with no mapping before and after them: the first
// gap between the mappings of the program. The range of a mapping that
// ended serves again: a program that maps and unmaps at each call uses the
// same few addresses, and its tables are those of one mapping at a time.
// At most MAPPING_CAPACITY passes over the 128 mappings. The caller holds
// the program lock.
chosen_address :: proc "contextless" (program: ^Program, count: u64, alignment: u64 = PAGE_SIZE) -> u64 {
	align_up :: #force_inline proc "contextless" (value, alignment: u64) -> u64 {
		return (value + alignment - 1) / alignment * alignment
	}
	candidate := align_up(u64(op.CHOSEN_BASE), alignment)
	size := count * PAGE_SIZE
	for _ in 0 ..= MAPPING_CAPACITY {
		moved := false
		for mapping in program.mappings {
			if mapping.page_count == 0 {
				continue
			}
			end := mapping.address + mapping.page_count * PAGE_SIZE
			if candidate < end + PAGE_SIZE && mapping.address < candidate + size + PAGE_SIZE {
				candidate = align_up(end + PAGE_SIZE, alignment)
				moved = true
			}
		}
		if !moved {
			break
		}
	}
	// The range of the chosen addresses ends where the modules start.
	if candidate + size > op.MODULE_BASE {
		return 0
	}
	return candidate
}

// unmap removes a mapping. Before the memory object can end, each
// processor that uses the page table of the program forgets the mapping.
// The entries of the mapping stop being held, and each table that holds no
// entry then is freed after that shoot-down. The caller holds the program
// lock.
unmap :: proc "contextless" (program: ^Program, mapping: ^Mapping) {
	origin_detach(holding_of_mapping(program, mapping))
	self := processor_self()
	walked_present_pages: u64
	freed: Freed_Tables
	// A large page is one entry of the second level for 512 pages.
	for part in 0 ..< (mapping.large ? mapping.page_count / op.LARGE_PAGE_PAGES : 0) {
		address := mapping.address + part * LARGE_PAGE_SIZE
		entry := page_directory_entry(program.table, address)
		if entry == nil {
			// The mapping holds its tables: a missing one is a wrong count.
			page_table_count_broken("a held entry has no table")
		}
		walked_present_pages += (entry^ & PAGE_PRESENT) * op.LARGE_PAGE_PAGES
		entry^ = 0
		if self.table == program.table {
			page_flush(address)
		}
		page_entries_release(program.table, address, 2, 1, &freed)
	}
	// One table of the last level at a time (one walk of the upper levels
	// for 512 pages). Each page of the mapping is a held entry, present or
	// not, so each table of the mapping loses its run of held entries with
	// one subtraction. The entries that are not present are already 0, so
	// the read of the entries ends when it has cleared each present entry of
	// the mapping (`present_page_count`): the tables of a mapping of 1 GiB
	// with few pages that have a frame are not read entry by entry. The test
	// build reads each entry, to compare the count with the walk.
	for page := u64(0); page < (mapping.large ? 0 : mapping.page_count); {
		address := mapping.address + page * PAGE_SIZE
		run := min(512 - (address >> 12 & 511), mapping.page_count - page)
		entry := page_entry(program.table, address)
		if entry == nil {
			// The mapping holds its tables: a missing one is a wrong count.
			page_table_count_broken("a held entry has no table")
		}
		read_entries := walked_present_pages != mapping.present_page_count
		when TEST_BUILD_CHECKS_LOCK_ORDER {
			read_entries = true
		}
		entries := ([^]u64)(entry)
		for at in 0 ..< (read_entries ? run : 0) {
			if entries[at] & PAGE_PRESENT != 0 {
				walked_present_pages += 1
				entries[at] = 0
				if self.table == program.table {
					page_flush(address + at * PAGE_SIZE)
				}
			}
		}
		page_entries_release(program.table, address, 1, run, &freed)
		page += run
	}
	// The entries are 0 before the read of the tables of the processors: a
	// processor that loads the table after the read sees the 0 entries.
	intrinsics.atomic_thread_fence(.Seq_Cst)
	processor_sync(processors_with_table(program.table))
	// No processor walks into a freed table now: the frames can serve again.
	page_tables_free(program.table, &program.budget, &freed)
	// The test build checks the count of the present pages against the
	// walk that this loop made anyway: one comparison, no other walk.
	when TEST_BUILD_CHECKS_LOCK_ORDER {
		if walked_present_pages != mapping.present_page_count {
			present_count_broken(mapping, walked_present_pages)
		}
	}
	// The marks of protection of the pages end with the one mapping that
	// has them: the object can be mapped
	// and given again.
	if region := &regions[mapping.region]; intrinsics.atomic_load(&region.marked_pages) != 0 && !region.contiguous {
		lock := &region_locks[mapping.region]
		lock_take(lock, .Region)
		for page in mapping.first ..< mapping.first + mapping.page_count {
			slot := region_slot(region, page)
			intrinsics.atomic_store(slot, intrinsics.atomic_load(slot) &~ SLOT_MARKS)
		}
		intrinsics.atomic_store(&region.marked_pages, 0)
		lock_free(lock, .Region)
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
	if mapping == nil {
		return false
	}
	// Each page of a large mapping with access is present. A fault there
	// that the entry permits now came through an old translation, before the
	// shoot-down of a protection change: the instruction runs again
	// with no stop of the program.
	if mapping.large {
		entry := page_directory_entry(program.table, address &~ u64(LARGE_PAGE_SIZE - 1))
		return entry != nil && entry^ & PAGE_PRESENT != 0 && (!write || entry^ & PAGE_WRITE != 0) && (!execute || entry^ & PAGE_NO_EXECUTE == 0)
	}
	page := (address - mapping.address) / PAGE_SIZE
	region := &regions[mapping.region]
	state := region_page_state(region, mapping.first + page)
	bits := page_bits(mapping, state)
	// No access, a page that is not committed, or an access that the
	// protection of the page refuses: a fault of the program.
	if bits == 0 || !page_committed(region, state) || write && bits & PAGE_WRITE == 0 || execute && bits & PAGE_NO_EXECUTE != 0 {
		return false
	}
	entry := page_entry(program.table, mapping.address + page * PAGE_SIZE)
	if entry == nil {
		return false // map_region made the tables and the mapping holds them: this does not happen.
	}
	if entry^ & PAGE_PRESENT == 0 {
		frame := region_frame(region, mapping.first + page, true)
		if frame == 0 {
			return false
		}
		entry^ = frame | bits
		mapping.present_page_count += 1 // Under the program lock: the caller holds it (see above).
	}
	return true
}

// present_count_broken stops the machine of the test when the count of the
// present pages of a mapping is not what its page table holds.
present_count_broken :: proc "contextless" (mapping: ^Mapping, walked: u64) -> ! {
	fault_report_begin()
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
	// The first instruction and the stack are in the half of the addresses
	// of a program. The processor refuses to return to an address that is
	// not canonical, and it refuses in the kernel, after the kernel loaded
	// the state of the program: the fault would be a fault of the kernel,
	// and one program would stop the machine.
	if entry >= USER_END || stack > USER_END || stack < 8 {
		return 0, .Bad_Address
	}
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
	// Written in place: a composite literal of the whole entry can be built
	// on the kernel stack first, and the entry holds an extended state area
	// of 2688 bytes.
	intrinsics.mem_zero(thread, size_of(Thread))
	thread.state = .Ready
	thread.program = program_index
	thread.budget = budget
	thread.number = number
	thread.ring = thread_ring
	thread.record = record
	thread.events = &direct(regions[region].physical, op.Thread_Record).events
	thread.record_in_kernel = direct(regions[region].physical, op.Thread_Record)
	thread.serial = serial
	thread.wait_serial = wait_serial
	thread.home = home
	thread.weight = weight == 0 ? op.WEIGHT_FULL : u32(weight)
	thread.request = request == 0 ? op.REQUEST_DEFAULT : u32(request)
	thread.frame = {
		rip    = entry,
		cs     = SELECTOR_USER_CODE,
		rflags = USER_FLAGS,
		rsp    = stack - 8, // As after a call instruction.
		ss     = SELECTOR_USER_DATA,
		rdi    = parameter,
	}
	extended_state_start(&thread.extended_state)
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
	thread.record_in_kernel = nil
	thread.ring = {}
	// The thread record is unmapped below: a fault handler that ends ends
	// the fault ring. A thread that waits for an answer then has no thread
	// that can read its record: the program stops (after the lock).
	handler_ended := program.fault_handler == index
	if handler_ended {
		program.fault_handler = 0
		intrinsics.atomic_store(&program.fault_kinds, 0)
	}
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
	unanswered := handler_ended && running && fault_waiter_exists(program_index)
	program_unlock(program_index, taken)
	if intrinsics.atomic_load(&thread.references) == 0 {
		thread_free(thread)
	}
	if last {
		program_stop(program_index, 0)
	} else if unanswered {
		program_stop(program_index, op.STOP_CODE_FAULT_UNANSWERED)
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
	// The event table belongs to the program that gave it: it ends with it,
	// before its handles close (events.odin). No program lock is held here.
	event_table_end_for(index)
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
		control_register_3_write(kernel_table)
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
	1  = "debug",
	2  = "non-maskable interrupt",
	3  = "breakpoint",
	4  = "overflow",
	5  = "bound range",
	6  = "invalid instruction",
	7  = "device not available",
	8  = "double fault",
	10 = "invalid task state",
	11 = "segment not present",
	12 = "stack fault",
	13 = "protection fault",
	14 = "page fault",
	16 = "x87 floating point",
	17 = "alignment check",
	18 = "machine check",
	19 = "SIMD floating point",
	21 = "control protection",
}

// kernel_interrupt is where every interrupt, exception and kernel entry
// arrives. It takes no lock of its own: each path takes the locks of the
// data that it touches (docs/ARCHITECTURE.md, "Locks of the kernel").
@(require, linkage = "strong", link_name = "kernel_interrupt")
kernel_interrupt :: proc "c" (frame: ^Frame) {
	from_program := frame.cs & 3 != 0
	// The address of a page fault, read once and first: every later use
	// takes this value, also if a later path can take another page fault.
	fault_address: u64
	if frame.vector == VECTOR_PAGE_FAULT {
		fault_address = control_register_2_read()
	}
	// A fault of the iretq of resume: the processor refused the return to
	// the current thread. The same test as in interrupt_common, which gave
	// the kernel its gs back for this case only.
	if !from_program && frame.rip == u64(uintptr(&resume_return)) && frame.vector >= 11 && frame.vector <= 13 {
		return_refused_by_the_processor(frame)
	}
	// A non-maskable interrupt, a double fault and a machine check are not
	// faults of an instruction of the program that ran: a double fault is a
	// mistake of the kernel, a machine check an error of the machine, and
	// the kernel sends no non-maskable interrupt, so one reports the machine
	// (a hardware error, or a request through the hypervisor). To stop only
	// that program would hide the fault and go on with a machine that is
	// not sound: the machine stops with a line, as in the kernel below.
	if from_program && (frame.vector == VECTOR_NON_MASKABLE_INTERRUPT || frame.vector == VECTOR_DOUBLE_FAULT || frame.vector == VECTOR_MACHINE_CHECK) {
		fault_report_begin()
		log("kernel: ", EXCEPTION_NAMES[frame.vector], " vector ", frame.vector, " while a program ran, at ", Hex(frame.rip), ": a fault of the machine, not of the program: the machine stops")
		machine_stop(2)
	}
	if !from_program && frame.vector < VECTOR_INTERRUPT_BASE {
		// The processor can hold any lock: it takes none.
		name := EXCEPTION_NAMES[frame.vector]
		address := fault_address
		if frame.vector != VECTOR_PAGE_FAULT {
			address = control_register_2_read()
		}
		fault_report_begin()
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
		enter(cpu, cpu.current)
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
	case frame.vector == VECTOR_PAGE_FAULT && frame.error & FAULT_RESERVED_BIT != 0:
		// The processor found a reserved bit in an entry of a page table.
		// Only the kernel writes those entries: it is a mistake of the
		// kernel, not of the program. The machine stops, as at an exception
		// in the kernel; a fault handler never sees it, so a repair cannot
		// hide it in a loop of faults.
		fault_report_begin()
		log("kernel: a page table entry of program ", program_name(&programs[thread.program]), " has a reserved bit: page fault error ", Hex(frame.error), " at ", Hex(frame.rip), " address ", Hex(fault_address))
		machine_stop(2)
	case frame.vector == VECTOR_PAGE_FAULT && frame.error & FAULT_PRESENT == 0 && page_fault(thread.program, fault_address, frame.error):
		// A page on first use, or a page that another thread made present
		// while this one waited for the lock: the instruction runs again.
		cpu.first_use_faults += 1
		// The event points of a fault (events.odin) come after the work, so
		// that the record says what the kernel did. The thread keeps its
		// program and its number until its processor leaves it.
		if event_wanted(cpu, OBSERVED_FAULT, .Fault, thread.program) {
			event_record(cpu, .Fault, thread.program, thread.number, frame.vector, fault_address, u64(op.Event_Fault_Outcome.First_Use))
		}
	case from_program && frame.vector < VECTOR_INTERRUPT_BASE && fault_deliver(cpu.current, fault_address):
		// A record of the fault ring: the thread is Waiting until a thread
		// of its program answers, so the end below goes to schedule. The
		// address is 0 for a fault that is not a page fault.
		if event_wanted(cpu, OBSERVED_FAULT, .Fault, thread.program) {
			event_record(cpu, .Fault, thread.program, thread.number, frame.vector, fault_address, u64(op.Event_Fault_Outcome.Fault_Ring))
		}
	case:
		program_fault(thread.program, frame, fault_address)
		if from_program && frame.vector < VECTOR_INTERRUPT_BASE && event_wanted(cpu, OBSERVED_FAULT, .Fault, thread.program) {
			event_record(cpu, .Fault, thread.program, thread.number, frame.vector, fault_address, u64(op.Event_Fault_Outcome.Stopped))
		}
	}
	if !from_program {
		return // The processor was idle: it looks for a thread itself.
	}
	// The thread that entered continues, unless it waits, it ends, a stop
	// of Thread_Control holds it, or its time slice is over.
	if !intrinsics.atomic_load(&thread.stop_requested) && intrinsics.atomic_load(&thread.state) == .Ready && intrinsics.atomic_load(&thread.control_stops) == 0 && cpu.slice_left > 0 {
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
program_fault :: proc "contextless" (index: u32, frame: ^Frame, address: u64) {
	control_take()
	defer control_free()
	program_stop(index, program_fault_report(index, frame, address))
}

// program_fault_report writes the stop report and the line of the log of a
// fault of a thread of a program, and gives the stop code. address is the
// address of a page fault (the processor gives it in cr2). The caller holds
// the control lock, and the page table of this processor is the one of the
// program: the stack trace reads its memory. Then the caller stops the
// program with the code.
program_fault_report :: proc "contextless" (index: u32, frame: ^Frame, address: u64) -> (code: u32) {
	program := &programs[index]
	taken := program_lock(index)
	name := frame.vector < 32 ? EXCEPTION_NAMES[frame.vector] : ""
	// The module of the instruction, as the loader recorded it: a
	// replacement names the module that runs, not the one of the import.
	found := module_of(program, frame.rip)
	// The first stop is the one that the report keeps: a program that a stop
	// or another fault already stopped keeps its code and its report.
	first := program.state != .Stopped && program.state != .None
	// A page of an Uncommitted object that is not committed has its own
	// code: the access went to addresses with no memory paid behind them.
	code = op.STOP_CODE_FAULT + u32(frame.vector)
	if frame.vector == VECTOR_PAGE_FAULT && program.table != 0 {
		if mapping := mapping_at(program, address); mapping != nil && mapping.region < REGION_CAPACITY {
			region := &regions[mapping.region]
			page := mapping.first + (address - mapping.address) / PAGE_SIZE
			if region.uncommitted && !page_committed(region, region_page_state(region, page)) {
				code = op.STOP_CODE_NOT_COMMITTED
				name = "page fault on a page that is not committed"
			}
		}
	}
	if first {
		program.stop = {code = code, vector = u32(frame.vector), instruction = frame.rip}
		if frame.vector == 14 {
			program.stop.address = address
		}
		if found != nil {
			program.stop.module = found^
		}
	}
	if found == nil {
		log_in("fault", .Warning, "kernel: program ", program_name(program), " stopped: ", name, " vector ", frame.vector, " error ", Hex(frame.error), " at ", Hex(frame.rip), " address ", Hex(address))
	} else if found.replaces == {} {
		log_in("fault", .Warning, "kernel: program ", program_name(program), " stopped: ", name, " vector ", frame.vector, " at ", Hex(frame.rip), " address ", Hex(address), ", in module ", hash_head(found.hash), " at offset ", Hex(frame.rip - found.base))
	} else {
		log_in("fault", .Warning, "kernel: program ", program_name(program), " stopped: ", name, " vector ", frame.vector, " at ", Hex(frame.rip), " address ", Hex(address), ", in module ", hash_head(found.hash), " at offset ", Hex(frame.rip - found.base), ", which replaces ", hash_head(found.replaces))
	}
	// The stack trace: the page table of the program is the one of this
	// processor, and the program lock is held (user_range, user_copy).
	if first {
		stack_trace(program, frame, &program.stop)
	}
	program_unlock(index, taken)
	return code
}

program_name :: proc "contextless" (program: ^Program) -> string {
	count := 0
	for count < len(program.name) && program.name[count] != 0 {
		count += 1
	}
	return string(program.name[:count])
}
