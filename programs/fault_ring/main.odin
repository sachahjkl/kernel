// The fault ring (docs/ARCHITECTURE.md, "The fault ring"), case by case.
//
// A program names one of its threads as its fault handler. A page fault of
// another thread then does not stop the program: the kernel writes a record
// in the ring of the handler, and the thread waits; the handler repairs
// with the operations of the virtual memory and answers. Each case of this
// program runs in a child program (this module, with a role), so that a
// case that stops its program stops only that child:
//
//   1. to 4. One child repairs: a read of a page that is not committed (the
//      handler commits the page and writes a value in it; the thread reads
//      that value), a write to a read-only page (the handler gives Write
//      back), a stack that grows by 64 pages (the time of one repaired
//      fault is measured), and an answer with a wrong serial (refused).
//   5. The handler answers Stop: the stop report is the one of a fault with
//      no handler.
//   6. A fault of the handler itself: not delivered, the program stops.
//   7. A full ring: 17 threads fault, the handler reads none; the 17th fault
//      stops the program, and the kernel counts it.
//   8. The program stops while a thread waits: its budget gets back every
//      page and every thread.
//   9. The handler ends while a thread waits: the program stops with the
//      code of a fault that no thread can answer.
package fault_ring

import "base:intrinsics"
import "contract:module"
import op "contract:operation"
import "support:display"
import "support:graphics"
import "support:interface"
import "support:random"
import "support:system"

LINE :: interface.TABLE_LINE
WIDTH :: 896
HEIGHT :: 400
PAGE :: system.PAGE_SIZE

// The value of the context that gives the role of a child: ROLE_TAG in the
// high half, the role in the low half. The root service writes the values 0
// to 2 for a program with grants (value 0: the size of the boot image), and
// other values for some programs: a value without the tag is the parent.
VALUE_ROLE :: 5
ROLE_TAG :: u64(0x4641_554C_0000_0000) // "FAUL"

// role_of gives the role that the starter of this program wrote.
role_of :: proc "contextless" (value: u64) -> Role {
	if value & 0xFFFF_FFFF_0000_0000 != ROLE_TAG || value & 0xFFFF_FFFF > u64(max(Role)) {
		return .Parent
	}
	return Role(value & 0xFFFF_FFFF)
}

Role :: enum u64 {
	Parent             = 0,
	Repairs            = 1,
	Answer_Stop        = 2,
	Handler_Fault      = 3,
	Full_Ring          = 4,
	Stop_While_Waiting = 5,
	Handler_Ends       = 6,
}

// The child that repairs stops with REPAIRS_CODE and one bit for each of
// its four cases that went as it must.
REPAIRS_CODE :: 0x10
REPAIRS_ALL :: 0xF
STOP_WHILE_WAITING_CODE :: 7
FULL_RING_THREADS :: op.FAULT_RECORD_CAPACITY + 1
STACK_PAGES :: 64
LAZY_PAGES :: 16
LAZY_PAGE :: 3 // The page of the lazy object that case 1 reads.
MAGIC :: u64(0x5EED_0000_0000_0000)

// One case of the parent: what its child gave.
Case :: struct {
	name:  string,
	role:  Role,
	bit:   u32, // For the child that repairs: its bit in the stop code.
	ran:   bool,
	right: bool,
}

cases := [9]Case {
	{name = "a read of a page that is not committed", role = .Repairs, bit = 1},
	{name = "a write to a read-only page", role = .Repairs, bit = 2},
	{name = "a stack that grows by 64 pages", role = .Repairs, bit = 4},
	{name = "an answer with a wrong serial", role = .Repairs, bit = 8},
	{name = "the handler answers stop", role = .Answer_Stop},
	{name = "a fault of the handler itself", role = .Handler_Fault},
	{name = "a full ring", role = .Full_Ring},
	{name = "the program stops while a thread waits", role = .Stop_While_Waiting},
	{name = "the handler ends while a thread waits", role = .Handler_Ends},
}

program_generator: random.Generator
image: []u8
log_handle: system.Handle

records_now, records_before: [256]interface.Draw_Record
text_now, text_before: [4096]u8
drawing: interface.Window_Drawing

// The state that the threads of a child share.
lazy_memory: system.Handle // Uncommitted: case 1, and the faults of the other children.
lazy_base: u64
read_only_base: u64
stack_memory: system.Handle // Uncommitted: case 3.
stack_base: u64
handler_ready: u32
wrong_serial_refused: bool
stack_repairs: u32

// handler_start starts the handler thread of a child and waits until it is
// the fault handler of the program.
handler_start :: proc "contextless" (entry: proc "c" (parameter: rawptr) -> !) {
	if _, status := system.thread_start(entry, nil); status != .Ok {
		system.stop(20)
	}
	for intrinsics.atomic_load(&handler_ready) == 0 {
		system.sleep(system.time() + 1)
	}
}

// handler_become makes the calling thread the fault handler.
handler_become :: proc "contextless" () {
	if system.fault_handler_set() != .Ok {
		system.stop(21)
	}
	intrinsics.atomic_store(&handler_ready, 1)
}

// The handler of the child that repairs: it commits, gives Write back, and
// answers Resume; the first answer of case 1 has a wrong serial.
repairs_handler :: proc "c" (_: rawptr) -> ! {
	handler_become()
	first := true
	for {
		record, ok := system.fault_record_next()
		if !ok {
			continue
		}
		page := record.address &~ (PAGE - 1)
		switch {
		case page >= lazy_base && page < lazy_base + LAZY_PAGES * PAGE:
			ranges := [1]op.Page_Range{{first = (page - lazy_base) / PAGE, page_count = 1}}
			system.memory_commit(lazy_memory, ranges[:])
			intrinsics.volatile_store((^u64)(uintptr(page)), MAGIC + (page - lazy_base) / PAGE)
			if first {
				first = false
				wrong := record
				wrong.serial += 1
				wrong_serial_refused = system.fault_answer(wrong, .Resume) == .Bad_State
			}
		case page == read_only_base:
			ranges := [1]op.Address_Range{{address = page, page_count = 1}}
			system.memory_protect(ranges[:], {.Write})
		case page >= stack_base && page < stack_base + STACK_PAGES * PAGE:
			ranges := [1]op.Page_Range{{first = (page - stack_base) / PAGE, page_count = 1}}
			system.memory_commit(stack_memory, ranges[:])
			intrinsics.atomic_add(&stack_repairs, 1)
		case:
			system.fault_answer(record, .Stop)
			continue
		}
		system.fault_answer(record, .Resume)
	}
}

child_repairs :: proc "contextless" () -> ! {
	bits: u32
	status: system.Status
	lazy_memory, status = system.memory_create(LAZY_PAGES, flags = {.Uncommitted})
	lazy_address, _ := system.memory_map(lazy_memory)
	lazy_base = u64(uintptr(lazy_address))
	read_only_memory, _ := system.memory_create(1)
	read_only_address, _ := system.memory_map(read_only_memory)
	read_only_base = u64(uintptr(read_only_address))
	stack_memory, _ = system.memory_create(STACK_PAGES, flags = {.Uncommitted})
	stack_address, _ := system.memory_map(stack_memory)
	stack_base = u64(uintptr(stack_address))
	if status != .Ok || lazy_base == 0 || read_only_base == 0 || stack_base == 0 {
		system.stop(22)
	}
	read_only := [1]op.Address_Range{{address = read_only_base, page_count = 1}}
	if _, protected := system.memory_protect(read_only[:], {}); protected != .Ok {
		system.stop(23)
	}
	handler_start(repairs_handler)

	// 1. A read of a page that is not committed.
	value := intrinsics.volatile_load((^u64)(uintptr(lazy_base + LAZY_PAGE * PAGE)))
	if value == MAGIC + LAZY_PAGE {
		bits |= 1
	}
	system.log("fault_ring: a read of a page that is not committed: the handler committed it and wrote ", system.Hex(MAGIC + LAZY_PAGE), "; the thread read ", system.Hex(value), value == MAGIC + LAZY_PAGE ? string(": as it must") : string(": WRONG"))

	// 2. A write to a read-only page.
	intrinsics.volatile_store((^u64)(uintptr(read_only_base)), 42)
	written := intrinsics.volatile_load((^u64)(uintptr(read_only_base)))
	if written == 42 {
		bits |= 2
	}
	system.log("fault_ring: a write to a read-only page: the handler gave Write back; the page holds ", written, written == 42 ? string(": as it must") : string(": WRONG"))

	// 3. A stack that grows down by one page at each fault.
	least := max(u64)
	top := stack_base + STACK_PAGES * PAGE
	for page in 1 ..= u64(STACK_PAGES) {
		before := system.nanoseconds()
		intrinsics.volatile_store((^u64)(uintptr(top - page * PAGE)), page)
		least = min(least, system.nanoseconds() - before)
	}
	repairs := intrinsics.atomic_load(&stack_repairs)
	if repairs == STACK_PAGES {
		bits |= 4
	}
	system.log("fault_ring: a stack that grows: ", u64(repairs), " pages of ", u64(STACK_PAGES), ", each one committed by the handler at its first touch; one repaired fault took ", least, " ns at least", repairs == STACK_PAGES ? string(": as it must") : string(": WRONG"))

	// 4. The wrong serial of case 1.
	if wrong_serial_refused {
		bits |= 8
	}
	system.log("fault_ring: an answer with a wrong serial: ", wrong_serial_refused ? string("refused with Bad_State, then the right answer resumed the thread: as it must") : string("not refused: WRONG"))
	system.stop(REPAIRS_CODE | bits)
}

// The handler of the children that do not repair: it answers Stop to each
// record (Answer_Stop), ends at the first one (Handler_Ends), or never reads
// (Full_Ring, Stop_While_Waiting).
stop_handler :: proc "c" (_: rawptr) -> ! {
	handler_become()
	for {
		record, ok := system.fault_record_next()
		if ok {
			system.fault_answer(record, .Stop)
		}
	}
}

ending_handler :: proc "c" (_: rawptr) -> ! {
	handler_become()
	for {
		if _, ok := system.fault_record_next(); ok {
			system.thread_stop()
		}
	}
}

silent_handler :: proc "c" (_: rawptr) -> ! {
	handler_become()
	for {
		system.sleep(system.time() + 1000)
	}
}

// fault_on_a_page touches the page of the lazy object that its parameter
// names: a fault that the handler gets.
fault_on_a_page :: proc "c" (parameter: rawptr) -> ! {
	page := u64(uintptr(parameter))
	intrinsics.volatile_store((^u64)(uintptr(lazy_base + page * PAGE)), page)
	system.thread_stop()
}

lazy_object :: proc "contextless" (pages: u64) {
	status: system.Status
	lazy_memory, status = system.memory_create(pages, flags = {.Uncommitted})
	address, _ := system.memory_map(lazy_memory)
	lazy_base = u64(uintptr(address))
	if status != .Ok || lazy_base == 0 {
		system.stop(22)
	}
}

child :: proc "contextless" (role: Role) -> ! {
	switch role {
	case .Parent:
		// Not a child: entry calls child only for another role.
	case .Repairs:
		child_repairs()
	case .Answer_Stop:
		lazy_object(1)
		handler_start(stop_handler)
		_ = intrinsics.volatile_load((^u64)(uintptr(lazy_base)))
	case .Handler_Fault:
		lazy_object(2)
		// The handler is this thread: its own fault is not delivered.
		handler_become()
		_ = intrinsics.volatile_load((^u64)(uintptr(lazy_base + PAGE)))
	case .Full_Ring:
		lazy_object(FULL_RING_THREADS)
		handler_start(silent_handler)
		for page in 0 ..< u64(FULL_RING_THREADS) {
			system.thread_start(fault_on_a_page, rawptr(uintptr(page)), 4)
		}
		for {
			system.sleep(system.time() + 1000)
		}
	case .Stop_While_Waiting:
		lazy_object(1)
		handler_start(silent_handler)
		system.thread_start(fault_on_a_page, nil, 4)
		system.sleep(system.time() + 50)
		system.stop(STOP_WHILE_WAITING_CODE)
	case .Handler_Ends:
		lazy_object(1)
		handler_start(ending_handler)
		system.thread_start(fault_on_a_page, nil, 4)
		for {
			system.sleep(system.time() + 1000)
		}
	}
	system.stop(30) // Not reached: each case above stops its program.
}

// child_run starts the child of a role, waits for its stop, and gives its
// stop code and stop report. The budget of this program, before the start
// and after the end of the child, says if the child left anything behind.
child_run :: proc "contextless" (role: Role) -> (code: u32, report: op.Stop_Report, left_behind: bool) {
	before, _ := system.budget_read()
	grants: [op.CONTEXT_HANDLES]system.Grant
	grants[op.CONTEXT_LOG] = {log_handle, {.Write}}
	values: [op.CONTEXT_VALUES]u64
	values[VALUE_ROLE] = ROLE_TAG | u64(role)
	error: module.Load_Error
	program, status := system.program_start(system.image_find(image, "fault_ring"), "fault_ring child", grants, random.values_with_seed(&program_generator, values), {pages = 1024, programs = 1, threads = 20, processor = 500_000, log_records = 20}, nil, nil, {image = image}, &error)
	if status != .Ok {
		return 0, {}, true
	}
	for deadline := system.time() + 10_000; system.time() < deadline; {
		if state, _ := system.program_state(program); state == .Stopped {
			break
		}
		system.sleep(system.time() + 10)
	}
	_, code = system.program_state(program)
	report = system.program_stop_report(program)
	system.close(program)
	// The budget of a child returns when its last processor left it: wait
	// for it, at most one second.
	left_behind = true
	for deadline := system.time() + 1000; left_behind && system.time() < deadline; {
		after, _ := system.budget_read()
		left_behind = after.pages != before.pages || after.threads != before.threads || after.programs != before.programs
		if left_behind {
			system.sleep(system.time() + 10)
		}
	}
	return
}

draw :: proc "contextless" (window: ^display.Window) {
	frame := interface.window_frame_begin(&drawing, window)
	interface.background(&frame, {0, 0, WIDTH, HEIGHT})
	content := interface.card(&frame, {8, 8, WIDTH - 16, HEIGHT - 16}, "THE FAULT RING", "a page fault becomes a record for a handler thread of the program, in place of a stop", graphics.COLOR_KERNEL)
	column := interface.column_of(content)
	for &item in cases {
		value := "not run yet"
		color: graphics.Color = graphics.COLOR_DIM
		if item.ran {
			value = item.right ? "as it must" : "WRONG: see the log"
			color = item.right ? graphics.COLOR_PROGRAM : graphics.COLOR_FAILED
		}
		interface.label_value_line(&frame, interface.column_take(&column, LINE), item.name, value, color, 400)
	}
	interface.window_frame_end(&drawing, &frame, window)
}

case_log :: proc "contextless" (item: ^Case, code: u32, address: u64) {
	system.log("fault_ring: ", item.name, ": the child stopped with the code ", system.Hex(u64(code)), ", the address ", system.Hex(address), item.right ? string(": as it must") : string(": WRONG"))
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	if role := role_of(ctx.values[VALUE_ROLE]); role != .Parent {
		child(role)
	}
	if !random.generator_from_context(&program_generator, ctx) {
		system.log("fault_ring: no random seed in the context")
		system.stop(1)
	}
	log_handle = ctx.handles[op.CONTEXT_LOG]
	window, ok := display.open(ctx, WIDTH, HEIGHT, "fault_ring")
	if !ok {
		system.stop(1)
	}
	drawing = interface.window_drawing_of(records_now[:], records_before[:], text_now[:], text_before[:])
	address, status := system.memory_map(ctx.handles[system.GRANT_IMAGE], {})
	if status != .Ok {
		system.log("fault_ring: no boot image")
		system.stop(1)
	}
	image = ([^]u8)(address)[:ctx.values[system.GRANT_VALUE_IMAGE_SIZE]]
	draw(&window)

	// The child that repairs: one run for the cases 1 to 4.
	code, _, left := child_run(.Repairs)
	for &item in cases[:4] {
		item.ran = true
		item.right = code & ~u32(REPAIRS_ALL) == REPAIRS_CODE && code & item.bit != 0 && !left
	}
	draw(&window)
	for &item in cases[4:] {
		report: op.Stop_Report
		code, report, left = child_run(item.role)
		item.ran = true
		switch item.role {
		case .Parent, .Repairs:
			// Not in cases[4:]: the cases 1 to 4 ran above in one child.
		case .Answer_Stop:
			// The report of a fault with no handler: a read of a page that is
			// not committed, at the page that the child read.
			item.right = code == op.STOP_CODE_NOT_COMMITTED && report.vector == 14 && report.address != 0 && !left
		case .Handler_Fault:
			item.right = code == op.STOP_CODE_NOT_COMMITTED && report.vector == 14 && report.address & (PAGE - 1) == 0 && !left
		case .Full_Ring:
			item.right = code == op.STOP_CODE_NOT_COMMITTED && !left
		case .Stop_While_Waiting:
			item.right = code == STOP_WHILE_WAITING_CODE && !left
		case .Handler_Ends:
			item.right = code == op.STOP_CODE_FAULT_UNANSWERED && !left
		}
		case_log(&item, code, report.address)
		draw(&window)
	}
	right := 0
	for item in cases {
		if item.right {
			right += 1
		}
	}
	if right == len(cases) {
		system.log("fault_ring: ok, ", u64(len(cases)), " cases: each fault was repaired, or stopped its program with the report of today, and each child gave back every page and every thread")
	} else {
		system.log("fault_ring: failed: ", u64(len(cases) - right), " cases of ", u64(len(cases)))
	}
	for {
		draw(&window)
		display.wait(&window, system.time() + 1000)
		interface.window_events(&drawing, &window)
	}
}
