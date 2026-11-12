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
//  10. A thread with the entry of an earlier word wait still in the table of
//      words faults, and the page of that word is decommitted while it
//      waits: it still waits, with one record, and one answer resumes it.
//  11. A new handler while a thread waits: the ring with its record ends,
//      and the program stops with the same code as in case 9.
//  12. An answer from another program (this parent), with the thread number
//      and the serial of the record of the child: refused.
//  13. 10 000 faults, each answered at once by a handler that spins on
//      another processor, while the faulting thread can still be on its way
//      out of its processor: each one resumes once, with the right value.
package fault_ring

import "base:intrinsics"
import "contract:fixed_addresses"
import "contract:module"
import op "contract:operation"
import "support:display"
import "support:graphics"
import "support:interface"
import "support:random"
import "support:system"

LINE :: interface.TABLE_LINE
WIDTH :: 960
HEIGHT :: 460
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
	Word_Leftover      = 7,
	Handler_Changed    = 8,
	Foreign_Answer     = 9,
	Early_Answer       = 10,
}

// The child that repairs stops with REPAIRS_CODE and one bit for each of
// its four cases that went as it must.
REPAIRS_CODE :: 0x10
REPAIRS_ALL :: 0xF
STOP_WHILE_WAITING_CODE :: 7
// The children of the cases 10, 12 and 13 stop with their code and one bit
// for each check that went as it must.
LEFTOVER_CODE :: 0x20
LEFTOVER_ALL :: 0x7
FOREIGN_CODE :: 0x30
FOREIGN_ALL :: 0x7
EARLY_CODE :: 0x40
EARLY_ALL :: 0x3
EARLY_FAULTS :: 10_000
FULL_RING_THREADS :: op.FAULT_RECORD_CAPACITY + 1
// The budget of each child. The largest child needs about 300 pages (17
// threads with their stacks and thread areas, its own stack of 64 pages,
// 65 committed pages, its page tables) and 19 threads (the main thread,
// the handler, and the 17 threads of a full ring).
CHILD_PAGES :: 512
CHILD_THREADS :: 20
STACK_PAGES :: 64
LAZY_PAGES :: 16
LAZY_PAGE :: 3 // The page of the lazy object that case 1 reads.
MAGIC :: u64(0x5EED_0000_0000_0000)

// The page that the parent shares with each child, at SHARED_ADDRESS in the
// child.
SHARED_ADDRESS :: fixed_addresses.OWN_CHOICE_START + 0x0000_0400_0000_0000
Shared_Page :: struct {
	least_fault_nanoseconds: u64, // Case 3: the least time of one repaired fault.
	// Case 12: the record of the fault that waits, for the answer of the
	// parent. waiting is 1 when the two values are written.
	waiting_thread:  u64,
	waiting_serial:  u64,
	waiting:         u32,
	foreign_refused: u32, // 1: the answer of the parent got Bad_State; 2: it got another status.
}

// One case of the parent: what its child gave.
Case :: struct {
	name:  string,
	role:  Role,
	bit:   u32, // For the child that repairs: its bit in the stop code.
	ran:   bool,
	right: bool,
	value: [64]u8, // The text of the row, when the case gives a number.
	value_length: int,
}

cases := [13]Case {
	{name = "a read of a page that is not committed", role = .Repairs, bit = 1},
	{name = "a write to a read-only page", role = .Repairs, bit = 2},
	{name = "a stack that grows by 64 pages", role = .Repairs, bit = 4},
	{name = "an answer with a wrong serial", role = .Repairs, bit = 8},
	{name = "the handler answers stop", role = .Answer_Stop},
	{name = "a fault of the handler itself", role = .Handler_Fault},
	{name = "a full ring", role = .Full_Ring},
	{name = "the program stops while a thread waits", role = .Stop_While_Waiting},
	{name = "the handler ends while a thread waits", role = .Handler_Ends},
	{name = "a word wait, a fault, a decommit of the word", role = .Word_Leftover},
	{name = "a new handler while a thread waits", role = .Handler_Changed},
	{name = "an answer from another program", role = .Foreign_Answer},
	{name = "10 000 answers given at once", role = .Early_Answer},
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
handler_record: ^op.Thread_Record // The thread record of the handler: its ring.
wrong_serial_refused: bool
stack_repairs: u32
resumed_threads: u32 // The threads of fault_on_a_page that went past their fault.
handler_done: u32

// shared_page gives the page that the parent shares with this child.
shared_page :: #force_inline proc "contextless" () -> ^Shared_Page {
	return (^Shared_Page)(uintptr(SHARED_ADDRESS))
}

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
	handler_record = system.thread_record() // Read after handler_ready, which is stored after it.
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
	intrinsics.volatile_store(&shared_page().least_fault_nanoseconds, least)
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
	intrinsics.atomic_add(&resumed_threads, 1)
	system.thread_stop()
}

// wait_for waits until the word is not 0, at most a number of milliseconds.
wait_for :: proc "contextless" (word: ^u32, milliseconds: u64) -> bool {
	for deadline := system.time() + milliseconds; intrinsics.atomic_load(word) == 0; {
		if system.time() >= deadline {
			return false
		}
		system.sleep(system.time() + 1)
	}
	return true
}

lazy_page_repair :: proc "contextless" (value: u64) {
	ranges := [1]op.Page_Range{{first = 0, page_count = 1}}
	if _, status := system.memory_commit(lazy_memory, ranges[:]); status != .Ok {
		system.stop(24)
	}
	intrinsics.volatile_store((^u64)(uintptr(lazy_base)), value)
}

// Case 10. The word of a word wait, in a committed page of an uncommitted
// object: the handler decommits that page while the thread waits.
word_memory: system.Handle
word_base: u64
waker_woke: u32
leftover_quiet: bool // No second record, and the thread did not run, before the answer.
leftover_answer: system.Status

// waker sets the word and wakes the main thread, once it waits.
waker :: proc "c" (_: rawptr) -> ! {
	system.sleep(system.time() + 50)
	word := (^u32)(uintptr(word_base))
	intrinsics.atomic_store(word, 1)
	intrinsics.atomic_store(&waker_woke, u32(system.word_wake(word)))
	system.thread_stop()
}

leftover_handler :: proc "c" (_: rawptr) -> ! {
	handler_become()
	record, _ := system.fault_record_next()
	// The kernel ends the wait of each thread with a word in a page that
	// leaves the program. The faulting thread still has the entry of its
	// word wait: it must not wake.
	ranges := [1]op.Page_Range{{first = 0, page_count = 1}}
	if _, status := system.memory_decommit(word_memory, ranges[:]); status != .Ok {
		system.stop(25)
	}
	written := intrinsics.atomic_load(&handler_record.fault_written)
	system.sleep(system.time() + 100)
	leftover_quiet = intrinsics.atomic_load(&handler_record.fault_written) == written && intrinsics.atomic_load(&resumed_threads) == 0
	lazy_page_repair(MAGIC)
	leftover_answer = system.fault_answer(record, .Resume)
	intrinsics.atomic_store(&handler_done, 1)
	for {
		system.sleep(system.time() + 1000)
	}
}

child_word_leftover :: proc "contextless" () -> ! {
	lazy_object(1)
	status: system.Status
	word_memory, status = system.memory_create(1, flags = {.Uncommitted})
	address, _ := system.memory_map(word_memory)
	word_base = u64(uintptr(address))
	ranges := [1]op.Page_Range{{first = 0, page_count = 1}}
	if status != .Ok || word_base == 0 {
		system.stop(22)
	}
	if _, committed := system.memory_commit(word_memory, ranges[:]); committed != .Ok {
		system.stop(24)
	}
	handler_start(leftover_handler)
	system.thread_start(waker, nil, 4)
	// One word wait, ended by the waker: its entry stays in the table of
	// words until the next kernel entry of this thread. The fault below
	// comes first: no operation between the two.
	word := (^u32)(uintptr(word_base))
	for intrinsics.atomic_load(word) == 0 {
		system.word_wait(word, 0)
	}
	value := intrinsics.volatile_load((^u64)(uintptr(lazy_base)))
	intrinsics.atomic_add(&resumed_threads, 1)
	wait_for(&handler_done, 2000)
	bits: u32
	if intrinsics.atomic_load(&waker_woke) == 1 {
		bits |= 1
	}
	if leftover_quiet {
		bits |= 2
	}
	if leftover_answer == .Ok && value == MAGIC {
		bits |= 4
	}
	system.log("fault_ring: a word wait, a fault, a decommit of the word: the waker woke ", u64(waker_woke), " thread; ", leftover_quiet ? string("no second record and no run before the answer") : string("the thread ran or faulted again with no answer: WRONG"), "; the answer: ", op.STATUS_NAMES[leftover_answer], ", the thread read ", system.Hex(value), bits == LEFTOVER_ALL ? string(": as it must") : string(": WRONG"))
	system.stop(LEFTOVER_CODE | bits)
}

// Case 12. The handler writes the record for the parent, and answers only
// after the answer of the parent.
foreign_handler :: proc "c" (_: rawptr) -> ! {
	handler_become()
	record, _ := system.fault_record_next()
	intrinsics.volatile_store(&shared_page().waiting_thread, record.thread)
	intrinsics.volatile_store(&shared_page().waiting_serial, record.serial)
	intrinsics.atomic_store(&shared_page().waiting, 1)
	bits: u32
	if wait_for(&shared_page().foreign_refused, 2000) && intrinsics.atomic_load(&shared_page().foreign_refused) == 1 {
		bits |= 1
	}
	// The answer of the parent did not resume the thread: it has not run,
	// and it did not fault again.
	system.sleep(system.time() + 50)
	if intrinsics.atomic_load(&resumed_threads) == 0 && intrinsics.atomic_load(&handler_record.fault_written) == 1 {
		bits |= 2
	}
	lazy_page_repair(MAGIC)
	if system.fault_answer(record, .Resume) == .Ok && wait_for(&resumed_threads, 1000) {
		bits |= 4
	}
	system.log("fault_ring: an answer from another program: the parent answered for the thread ", record.thread, " and the serial ", record.serial, ": ", intrinsics.atomic_load(&shared_page().foreign_refused) == 1 ? string("refused with Bad_State") : string("not refused"), "; the thread still waited, and the answer of its own program resumed it", bits == FOREIGN_ALL ? string(": as it must") : string(": WRONG"))
	system.stop(FOREIGN_CODE | bits)
}

// Case 13. The handler spins on its ring and answers each record at once:
// the answer can come while the faulting thread still leaves its
// processor.
early_answers: u32

spinning_handler :: proc "c" (_: rawptr) -> ! {
	handler_become()
	own := system.thread_record()
	served: u64
	for {
		written := intrinsics.atomic_load(&own.fault_written)
		read := intrinsics.atomic_load(&own.fault_read)
		if written == read {
			// Spin for a while, then wait: a handler that only spins can
			// spend the processor time of the budget of the child.
			for spin := 0; spin < 100_000 && intrinsics.atomic_load(&own.fault_written) == written; spin += 1 {
				intrinsics.cpu_relax()
			}
			if intrinsics.atomic_load(&own.fault_written) == written {
				system.word_wait(&own.fault_written, written, system.time() + 1)
			}
			continue
		}
		record := own.fault_records[read % op.FAULT_RECORD_CAPACITY]
		intrinsics.atomic_store(&own.fault_read, read + 1)
		lazy_page_repair(MAGIC + served)
		served += 1
		if system.fault_answer(record, .Resume) == .Ok {
			intrinsics.atomic_add(&early_answers, 1)
		}
	}
}

child_early_answer :: proc "contextless" () -> ! {
	lazy_object(1)
	handler_start(spinning_handler)
	right: u64
	ranges := [1]op.Page_Range{{first = 0, page_count = 1}}
	for n in 0 ..< u64(EARLY_FAULTS) {
		if intrinsics.volatile_load((^u64)(uintptr(lazy_base))) == MAGIC + n {
			right += 1
		}
		if _, status := system.memory_decommit(lazy_memory, ranges[:]); status != .Ok {
			system.stop(25)
		}
	}
	answers := u64(intrinsics.atomic_load(&early_answers))
	bits: u32
	if answers == EARLY_FAULTS {
		bits |= 1
	}
	if right == EARLY_FAULTS {
		bits |= 2
	}
	system.log("fault_ring: 10 000 answers given at once: ", answers, " faults resumed, ", right, " values right, of ", u64(EARLY_FAULTS), bits == EARLY_ALL ? string(": as it must") : string(": WRONG"))
	system.stop(EARLY_CODE | bits)
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
	case .Word_Leftover:
		child_word_leftover()
	case .Handler_Changed:
		lazy_object(1)
		handler_start(silent_handler)
		system.thread_start(fault_on_a_page, nil, 4)
		// The record is published after its thread waits.
		for intrinsics.atomic_load(&handler_record.fault_written) == 0 {
			system.sleep(system.time() + 1)
		}
		// This thread becomes the handler: the ring of the first one, with
		// the record of the waiting thread, ends.
		system.fault_handler_set()
	case .Foreign_Answer:
		lazy_object(1)
		handler_start(foreign_handler)
		system.thread_start(fault_on_a_page, nil, 4)
		for {
			system.sleep(system.time() + 1000)
		}
	case .Early_Answer:
		child_early_answer()
	}
	system.stop(30) // Not reached: each case above stops its program.
}

// child_run starts the child of a role, waits for its stop, and gives its
// stop code and stop report. The budget of this program, before the start
// and after the end of the child, says if the child left anything behind.
// ran is false when a call failed: the call, its status and the budget are
// on the log, and the case is wrong; a failed call is never read as a stop.
child_run :: proc "contextless" (role: Role, name: string) -> (code: u32, report: op.Stop_Report, left_behind: bool, ran: bool, page: Shared_Page) {
	shared_memory, created := system.memory_create(1)
	if created != .Ok {
		system.log("fault_ring: ", name, ": memory_create of the shared page failed: ", op.STATUS_NAMES[created])
		return
	}
	defer system.close(shared_memory)
	shared_address, mapped := system.memory_map(shared_memory)
	if mapped != .Ok {
		system.log("fault_ring: ", name, ": memory_map of the shared page failed: ", op.STATUS_NAMES[mapped])
		return
	}
	defer system.memory_unmap(shared_address)
	in_parent := (^Shared_Page)(shared_address)
	mappings := [1]system.Mapping{{memory = shared_memory, address = SHARED_ADDRESS, flags = {.Write}}}
	before, _ := system.budget_read()
	grants: [op.CONTEXT_HANDLES]system.Grant
	grants[op.CONTEXT_LOG] = {log_handle, {.Write}}
	values: [op.CONTEXT_VALUES]u64
	values[VALUE_ROLE] = ROLE_TAG | u64(role)
	error: module.Load_Error
	program, status := system.program_start(system.image_find(image, "fault_ring"), "fault_ring child", grants, random.values_with_seed(&program_generator, values), {pages = CHILD_PAGES, programs = 1, threads = CHILD_THREADS, processor = 500_000, log_records = 20}, mappings[:], nil, {image = image}, &error)
	if status != .Ok {
		buffer: [512]u8
		lines := system.Writer{buffer = buffer[:]}
		system.load_error_text(&lines, &error)
		system.log("fault_ring: ", name, ": program_start failed: ", op.STATUS_NAMES[status], "; the load: ", system.written(&lines), "; this program can give pages ", before.pages, ", programs ", before.programs, ", threads ", before.threads, ", and the child asks ", u64(CHILD_PAGES), ", 1, ", u64(CHILD_THREADS))
		return
	}
	stopped := false
	results: [7]u64
	for deadline := system.time() + 10_000; system.time() < deadline; {
		results, status = system.call(.Program_State, u64(program))
		if status != .Ok {
			system.log("fault_ring: ", name, ": Program_State failed: ", op.STATUS_NAMES[status])
			system.close(program)
			return
		}
		if op.Program_State(results[0]) == .Stopped {
			stopped = true
			break
		}
		// Case 12: the answer of another program, with the two values of
		// the record of the child.
		if role == .Foreign_Answer && intrinsics.atomic_load(&in_parent.waiting) == 1 && intrinsics.atomic_load(&in_parent.foreign_refused) == 0 {
			record := op.Fault_Record{thread = intrinsics.volatile_load(&in_parent.waiting_thread), serial = intrinsics.volatile_load(&in_parent.waiting_serial)}
			answered := system.fault_answer(record, .Resume)
			if answered != .Bad_State {
				system.log("fault_ring: ", name, ": Fault_Answer of the parent gave ", op.STATUS_NAMES[answered], ", not Bad_State")
			}
			intrinsics.atomic_store(&in_parent.foreign_refused, answered == .Bad_State ? u32(1) : u32(2))
		}
		system.sleep(system.time() + 10)
	}
	if !stopped {
		system.log("fault_ring: ", name, ": the child did not stop in 10 s")
		system.close(program)
		return
	}
	code = u32(results[1])
	if _, status = system.call(.Program_State, u64(program), u64(uintptr(&report))); status != .Ok {
		system.log("fault_ring: ", name, ": Program_State with the stop report failed: ", op.STATUS_NAMES[status])
		system.close(program)
		return
	}
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
	if left_behind {
		system.log("fault_ring: ", name, ": the budget of this program did not get back every page, thread and program of the child in 1 s")
	}
	page = in_parent^
	ran = true
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
			if item.value_length > 0 {
				value = string(item.value[:item.value_length])
			}
		}
		interface.label_value_line(&frame, interface.column_take(&column, LINE), item.name, value, color, 420)
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
	code, _, left, ran, page := child_run(.Repairs, "the child that repairs")
	for &item in cases[:4] {
		item.ran = true
		item.right = ran && code & ~u32(REPAIRS_ALL) == REPAIRS_CODE && code & item.bit != 0 && !left
	}
	// The row of case 3 shows the measured time.
	if cases[2].right {
		cases[2].value_length = len(system.format(cases[2].value[:], "as it must: one repaired fault in ", page.least_fault_nanoseconds, " ns at least"))
	}
	draw(&window)
	for &item in cases[4:] {
		report: op.Stop_Report
		code, report, left, ran, _ = child_run(item.role, item.name)
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
		case .Handler_Ends, .Handler_Changed:
			item.right = code == op.STOP_CODE_FAULT_UNANSWERED && !left
		case .Word_Leftover:
			item.right = code == LEFTOVER_CODE | LEFTOVER_ALL && !left
		case .Foreign_Answer:
			item.right = code == FOREIGN_CODE | FOREIGN_ALL && !left
		case .Early_Answer:
			item.right = code == EARLY_CODE | EARLY_ALL && !left
		}
		item.right = item.right && ran
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
