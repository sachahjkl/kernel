// The fault ring (docs/ARCHITECTURE.md, "The fault ring"), case by case.
//
// A program names one of its threads as its fault handler, with the fault
// kinds that it takes. A fault of such a kind of another thread then does
// not stop the program: the kernel writes a record in the ring of the
// handler, and the thread waits; the handler repairs with the operations of
// the virtual memory and answers. Each case of this
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
//  14. A divide error: one record of its kind; Resume is refused, Stop gives
//      the stop report of the fault, at the instruction of the record.
//  15. An invalid opcode (ud2): the same, with its kind.
//  16. A breakpoint (int3), a trap: Resume lets the thread go on after it.
//  17. A divide error with a handler of page faults only: no record, and the
//      program stops as with no handler.
//  18. A privileged instruction (cli): a protection fault, as in 14.
//  19. The kinds never delivered: Fault_Handler_Set refuses them; a divide
//      error of the handler itself stops the program.
//
// The control of a thread (docs/ARCHITECTURE.md, "The control of a
// thread"), cases 20 to 27 in one child:
//  20. A stop of a thread that spins: its instruction address is inside its
//      loop, and the loop does not turn while it is stopped.
//  21. A write of a register (r12) that the thread then publishes.
//  22. Writes of a frame that a program cannot hold (the code selector of
//      the kernel, the I/O privilege level, interrupts off, an instruction
//      address that is not canonical): each refused, and the thread runs
//      after its Resume.
//  23. Writes of an extended state that the processor refuses (a header
//      that names a component that is not saved, a reserved bit of MXCSR):
//      each refused; the area that was read is accepted.
//  24. A stop of a thread that waits, then its wake: it does not run until
//      its Resume.
//  25. Two stops need two Resumes.
//  26. The rights of a thread handle: with Read and Control (the right to
//      end it), each command is refused; with Inspect only, a stop, a
//      read and a resume are accepted, and a write is refused.
//  27. A divide error whose handler adds the length of the div to the
//      instruction address and writes rax: Resume, refused before the
//      write, is accepted after it, and the thread goes on.
//  28. In its own child: no call names a thread of another program without
//      a handle; the thread of the parent keeps running.
// The entries to the gates and the debug trap (cases 29 to 33, one child
// whose handler takes Debug, Breakpoint and General_Protection):
//  29. int 3 in two bytes (CD 03): a breakpoint, at the address + 2.
//  30. int 14 (CD 0E): a protection fault with the error code 0x72, never a
//      page fault; the handler skips its two bytes.
//  31. int1 (the byte F1): a debug trap at the address + 1.
//  32. The trap flag set with popfq: one debug record for each instruction
//      until the popfq that clears it.
//  33. mov ss, then syscall, with the trap flag: on the processor of the
//      test, the machine goes on, and each record is a debug trap of this
//      program, in its code. It does not show that the processor gave no
//      trap at the first instruction of the kernel entry: the kernel drops
//      such a trap there.
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
WIDTH :: 1024
HEIGHT :: 604
ROWS_IN_THE_FIRST_COLUMN :: 17
COLUMN_GAP :: 16
VALUE_X :: 300 // Where the value of a row starts, in its column.
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
	Divide_Error       = 11,
	Invalid_Opcode     = 12,
	Breakpoint         = 13,
	Page_Faults_Only   = 14,
	General_Protection = 15,
	Kinds_Never_Delivered = 16,
	Controls              = 17,
	Foreign_Thread        = 18,
	Debug_Entries         = 19,
}

// The routines of cases.asm, and the labels inside them.
Spin_Cells :: struct {
	count: u64, // One more at each turn of the loop.
	value: u64, // r12, written at each turn.
}

foreign _ {
	spin_and_publish :: proc "c" (parameter: rawptr) -> ! --- // The parameter is a ^Spin_Cells.
	divide_and_skip :: proc "c" () -> u64 ---
	two_byte_breakpoint :: proc "c" () ---
	interrupt_fourteen :: proc "c" () ---
	icebp :: proc "c" () ---
	single_step_six :: proc "c" () ---
	mov_ss_then_syscall :: proc "c" () ---
	spin_loop_start: u8
	spin_loop_end: u8
	divide_instruction: u8
	divide_instruction_end: u8
	two_byte_breakpoint_instruction: u8
	interrupt_fourteen_instruction: u8
	icebp_instruction: u8
	single_step_first: u8
	single_step_end: u8
	mov_ss_then_syscall_end: u8
}

address_of :: #force_inline proc "contextless" (label: ^u8) -> u64 {
	return u64(uintptr(label))
}

// control runs one Thread_Control: a thread handle, or 0 and the number of
// a thread of this program.
control :: proc "contextless" (handle: system.Handle, number: u64, command: op.Thread_Control_Command, address: rawptr = nil, size: u64 = 0) -> (results: [7]u64, status: system.Status) {
	return system.call(.Thread_Control, u64(handle), number, u64(command), u64(uintptr(address)), size)
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
BREAKPOINT_CODE :: 0x50
BREAKPOINT_ALL :: 0x3
// The child of the control of a thread and the child of the entries stop
// with their code and one bit for each of their cases that went as it must.
CONTROLS_CODE :: 0x1000
CONTROLS_ALL :: 0xFF
DEBUG_ENTRIES_CODE :: 0x2000
DEBUG_ENTRIES_ALL :: 0x1F
FOREIGN_THREAD_CODE :: 0x3000
FOREIGN_THREAD_ALL :: 0x1
WRITTEN_VALUE :: MAGIC | 0x7 // Case 21: the value written in r12.
DIVIDE_RESULT :: 42 // Case 27: the rax that the handler writes.
SINGLE_STEP_RECORDS :: 6 // Case 32: nop, nop, nop, pushfq, and, popfq.
INT_FOURTEEN_ERROR_CODE :: 14 << 3 | 2 // The gate 14, from the interrupt table.
// Case 19: each one with the page faults, so that only the vector is wrong.
NEVER_DELIVERED_VECTORS :: [?]u64{2, 4, 5, 7, 8, 9, 10, 15, 18, 20, 21, 31, 32, 63}
FULL_RING_THREADS :: op.FAULT_RECORD_CAPACITY + 1
// The budget of each child. The largest child needs about 300 pages (17
// threads with their stacks and thread areas, its own stack of 64 pages,
// 65 committed pages, its page tables) and 19 threads (the main thread,
// the handler, and the 17 threads of a full ring).
CHILD_PAGES :: 512
CHILD_THREADS :: 20
// The parent waits for the stop of a child while the child makes progress:
// at most system.TEST_HANG_BOUND_MILLISECONDS with no growth of
// Shared_Page.progress, and system.TEST_PROGRESS_OVERALL_BOUND_MILLISECONDS
// in all. The time of a case that makes many round trips grows with the
// load of the host; a stall does not.
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
	// Case 13: the faults that the main thread of the child went past, and
	// the answers of its handler. The parent bounds a stall of progress,
	// not the whole run, and logs both at a timeout: a slow host and a lost
	// wake then give different lines.
	progress:        u64,
	answers:         u64,
	// The cases 14 to 18: the last record that kinds_handler read, how
	// many it read, and the status of its answer Resume, plus 1 (0: no
	// answer yet).
	records_seen:       u64,
	record_kind:        u64,
	record_error_code:  u64,
	record_instruction: u64,
	resume_status:      u32,
	// Case 19: the arguments of Fault_Handler_Set that the kernel refused.
	refused_arguments:  u64,
	// 1: the parent read its budget after the start; the child runs its
	// case only then, so that no part of its budget returned before that
	// read.
	go:                 u32,
	// Case 28: the number of a thread handle of the parent, which names
	// nothing in the child.
	parent_thread_handle: u64,
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

// The rows of the cases 1 to 19, then of the control of a thread, then of
// the entries: the parent runs them in this order.
FIRST_CONTROL_ROW :: 19
FOREIGN_THREAD_ROW :: 27
FIRST_ENTRY_ROW :: 28

cases := [33]Case {
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
	{name = "a divide error, answered stop", role = .Divide_Error},
	{name = "an invalid opcode, answered stop", role = .Invalid_Opcode},
	{name = "a breakpoint, answered resume", role = .Breakpoint},
	{name = "a divide error with a handler of pages", role = .Page_Faults_Only},
	{name = "a privileged instruction, answered stop", role = .General_Protection},
	{name = "the kinds never delivered", role = .Kinds_Never_Delivered},
	{name = "a stop of a thread that spins", role = .Controls, bit = 0x01},
	{name = "a write of a register", role = .Controls, bit = 0x02},
	{name = "a frame that a program cannot hold", role = .Controls, bit = 0x04},
	{name = "an extended state that faults", role = .Controls, bit = 0x08},
	{name = "a stop of a thread that waits", role = .Controls, bit = 0x10},
	{name = "two stops, two resumes", role = .Controls, bit = 0x20},
	{name = "the rights of a thread handle", role = .Controls, bit = 0x40},
	{name = "a divide error skipped by its handler", role = .Controls, bit = 0x80},
	{name = "the thread of another program", role = .Foreign_Thread, bit = 0x01},
	{name = "int 3 in two bytes", role = .Debug_Entries, bit = 0x01},
	{name = "int 14", role = .Debug_Entries, bit = 0x02},
	{name = "int1", role = .Debug_Entries, bit = 0x04},
	{name = "the trap flag set with popfq", role = .Debug_Entries, bit = 0x08},
	{name = "mov ss, then syscall, with the trap flag", role = .Debug_Entries, bit = 0x10},
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

// wait_for waits until the word is not 0. The bound only ends a hang.
wait_for :: proc "contextless" (word: ^u32) -> bool {
	for deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS; intrinsics.atomic_load(word) == 0; {
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
leftover_value: u64 // What the waiting thread read after its answer.

// leftover_waiter makes one word wait, which the main thread ends: its
// entry stays in the table of words until the next kernel entry of this
// thread. The fault below comes first: no operation between the two.
leftover_waiter :: proc "c" (_: rawptr) -> ! {
	word := (^u32)(uintptr(word_base))
	for intrinsics.atomic_load(word) == 0 {
		system.word_wait(word, 0)
	}
	intrinsics.volatile_store(&leftover_value, intrinsics.volatile_load((^u64)(uintptr(lazy_base))))
	intrinsics.atomic_add(&resumed_threads, 1)
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
	waiter, waiter_started := system.thread_start(leftover_waiter, nil, 4)
	if waiter_started != .Ok {
		system.stop(20)
	}
	// The wake must find the thread in its word wait: a wake before it would
	// end no wait, and leave no entry in the table of words.
	for deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS; system.time() < deadline; {
		states, _ := system.call(.Thread_State, u64(waiter.handle))
		if op.Program_State(states[0]) == .Waiting {
			break
		}
		system.sleep(system.time() + 1)
	}
	word := (^u32)(uintptr(word_base))
	intrinsics.atomic_store(word, 1)
	intrinsics.atomic_store(&waker_woke, u32(system.word_wake(word)))
	wait_for(&resumed_threads)
	wait_for(&handler_done)
	value := intrinsics.volatile_load(&leftover_value)
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
	if wait_for(&shared_page().foreign_refused) && intrinsics.atomic_load(&shared_page().foreign_refused) == 1 {
		bits |= 1
	}
	// The answer of the parent did not resume the thread: it has not run,
	// and it did not fault again.
	system.sleep(system.time() + 50)
	if intrinsics.atomic_load(&resumed_threads) == 0 && intrinsics.atomic_load(&handler_record.fault_written) == 1 {
		bits |= 2
	}
	lazy_page_repair(MAGIC)
	if system.fault_answer(record, .Resume) == .Ok && wait_for(&resumed_threads) {
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
			answered := intrinsics.atomic_add(&early_answers, 1) + 1
			intrinsics.volatile_store(&shared_page().answers, u64(answered))
		}
	}
}

child_early_answer :: proc "contextless" () -> ! {
	lazy_object(1)
	handler_start(spinning_handler)
	right: u64
	ranges := [1]op.Page_Range{{first = 0, page_count = 1}}
	started := system.time()
	for n in 0 ..< u64(EARLY_FAULTS) {
		if intrinsics.volatile_load((^u64)(uintptr(lazy_base))) == MAGIC + n {
			right += 1
		}
		if _, status := system.memory_decommit(lazy_memory, ranges[:]); status != .Ok {
			system.stop(25)
		}
		intrinsics.volatile_store(&shared_page().progress, n + 1)
	}
	elapsed := system.time() - started
	answers := u64(intrinsics.atomic_load(&early_answers))
	bits: u32
	if answers == EARLY_FAULTS {
		bits |= 1
	}
	if right == EARLY_FAULTS {
		bits |= 2
	}
	system.log("fault_ring: 10 000 answers given at once: ", answers, " faults resumed, ", right, " values right, of ", u64(EARLY_FAULTS), bits == EARLY_ALL ? string(": as it must") : string(": WRONG"), ", in ", elapsed, " ms")
	system.stop(EARLY_CODE | bits)
}

// The cases 14 to 19: faults that are not page faults. The handler takes
// the kinds of kinds_wanted. To its first record it answers Resume: the
// kernel accepts it for a breakpoint, and must refuse it for a fault that
// would run the same instruction on the same registers; then it moves the
// instruction address of the thread by one byte and answers Stop, and the
// stop report must name the instruction of the fault, not the written one.
// A second record answers Stop at once: a Resume that the kernel took
// by mistake ends there, and does not loop.
kinds_wanted: op.Fault_Kinds

kinds_handler :: proc "c" (_: rawptr) -> ! {
	if system.fault_handler_set(kinds = kinds_wanted) != .Ok {
		system.stop(21)
	}
	handler_record = system.thread_record()
	intrinsics.atomic_store(&handler_ready, 1)
	seen: u64
	for {
		record, ok := system.fault_record_next()
		if !ok {
			continue
		}
		seen += 1
		shared := shared_page()
		intrinsics.volatile_store(&shared.record_kind, u64(record.kind))
		intrinsics.volatile_store(&shared.record_error_code, record.error_code)
		intrinsics.volatile_store(&shared.record_instruction, record.instruction)
		intrinsics.volatile_store(&shared.records_seen, seen)
		if seen > 1 {
			system.fault_answer(record, .Stop)
			continue
		}
		resumed := system.fault_answer(record, .Resume)
		intrinsics.atomic_store(&shared.resume_status, u32(resumed) + 1)
		if resumed != .Ok {
			// A write of the instruction address before the answer Stop:
			// the stop report must still name the instruction of the fault,
			// which the case compares with the record.
			registers: op.Thread_Registers
			if _, read := control(0, record.thread, .Read_Registers, &registers, size_of(registers)); read == .Ok {
				registers.rip += 1
				control(0, record.thread, .Write_Registers, &registers, size_of(registers))
			}
			system.fault_answer(record, .Stop)
		}
	}
}

// The divide error comes from the instruction div itself. A division that
// the compiler writes is guarded: it tests the divisor first and runs an
// invalid instruction for a zero, so the processor never sees the division.
divide_in_registers :: asm(low: u64, high: u64, divisor: u64) -> (quotient: u64, remainder: u64) [
	low -> quotient   = %rax,
	high -> remainder = %rdx,
	#volatile,
	#clobber memory,
	#clobber %flags,
] {
	div divisor
}

// The divisor is read from memory, so that no pass of the compiler folds
// the call.
zero_divisor: u64

divide_by_zero :: proc "contextless" () {
	_, _ = divide_in_registers(1000, 0, intrinsics.volatile_load(&zero_divisor))
}

// cli is privileged for a program (its I/O privilege level is 0): the
// processor gives a protection fault with the error code 0.
interrupts_off :: asm() [#volatile, #clobber memory, #clobber %flags] {
	cli
}

// Case 16. The operand of the value that the thread computes after the
// breakpoint.
breakpoint_operand: u64 = 7

child_breakpoint :: proc "contextless" () -> ! {
	kinds_wanted = {.Breakpoint}
	handler_start(kinds_handler)
	intrinsics.debug_trap()
	value := intrinsics.volatile_load(&breakpoint_operand) * 6
	shared := shared_page()
	// The handler stores its status after its answer returns: this thread
	// can run before that store.
	wait_for(&shared.resume_status)
	bits: u32
	if value == 42 {
		bits |= 1
	}
	if intrinsics.volatile_load(&shared.records_seen) == 1 && intrinsics.volatile_load(&shared.record_kind) == u64(op.Fault_Kind.Breakpoint) && intrinsics.atomic_load(&shared.resume_status) == u32(system.Status.Ok) + 1 {
		bits |= 2
	}
	system.log("fault_ring: a breakpoint, answered resume: ", intrinsics.volatile_load(&shared.records_seen), " record of the kind ", intrinsics.volatile_load(&shared.record_kind), "; the thread went on after the int3 and computed ", value, bits == BREAKPOINT_ALL ? string(": as it must") : string(": WRONG"))
	system.stop(BREAKPOINT_CODE | bits)
}

// Case 19. Each argument with a vector that the kernel never delivers is
// refused, and so are kinds with the end of the delivery. Then this thread
// becomes the handler of divide errors: its own divide error is not
// delivered, and the program stops as with no handler.
child_kinds_never_delivered :: proc "contextless" () -> ! {
	refused: u64
	vectors := NEVER_DELIVERED_VECTORS
	for vector in vectors {
		if _, status := system.call(.Fault_Handler_Set, 0, 0, u64(1) << vector | u64(1) << u64(op.Fault_Kind.Page_Fault)); status == .Bad_Operation {
			refused += 1
		}
	}
	if _, status := system.call(.Fault_Handler_Set, 0, 1, u64(1) << u64(op.Fault_Kind.Divide_Error)); status == .Bad_Operation {
		refused += 1
	}
	asked := u64(len(vectors)) + 1
	intrinsics.volatile_store(&shared_page().refused_arguments, refused)
	system.log("fault_ring: the kinds never delivered: Fault_Handler_Set refused ", refused, " arguments of ", asked, " with Bad_Operation", refused == asked ? string(": as it must") : string(": WRONG"))
	if system.fault_handler_set(kinds = {.Divide_Error}) != .Ok {
		system.stop(21)
	}
	divide_by_zero()
	system.stop(30)
}

// kinds_case_right says if the child of a fault answered Stop stopped with
// the report of its kind, after one record of that kind at the instruction
// of the report, and Resume refused, and logs it.
kinds_case_right :: proc "contextless" (item: ^Case, code: u32, report: ^op.Stop_Report, page: ^Shared_Page, kind: op.Fault_Kind) -> bool {
	vector := u32(kind)
	same_instruction := report.instruction != 0 && page.record_instruction == report.instruction
	resume := "no answer"
	if page.resume_status != 0 && page.resume_status - 1 <= u32(max(op.Status)) {
		resume = op.STATUS_NAMES[op.Status(page.resume_status - 1)]
	}
	right := code == op.STOP_CODE_FAULT + vector && report.vector == vector && page.records_seen == 1 && page.record_kind == u64(kind) && page.record_error_code == 0 && same_instruction && page.resume_status == u32(system.Status.Bad_State) + 1
	system.log("fault_ring: ", item.name, ": ", page.records_seen, " record of the kind ", page.record_kind, ", the error code ", page.record_error_code, ", ", same_instruction ? string("the instruction of the stop report") : string("not the instruction of the stop report"), "; Resume got ", resume, right ? string(": as it must") : string(": WRONG"))
	return right
}

// The cases 20 to 27: the control of a thread, in one child.
control_cells: Spin_Cells
parent_cells: Spin_Cells // Case 28: the thread of the parent.
waiter_word: u32
waiter_runs: u32
divide_record_instruction: u64
divide_resume_before_write: system.Status
divide_skip_right: bool
divide_handler_done: u32
// The extended state area of a thread, read and written by case 23: at
// most the area of the kernel (2688 bytes).
extended_state_area: [4096]u8
extended_state_hostile: [4096]u8

// grows waits until a count changes. The bound only ends a hang.
grows :: proc "contextless" (count: ^u64) -> bool {
	start := intrinsics.atomic_load(count)
	for deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS; system.time() < deadline; {
		if intrinsics.atomic_load(count) != start {
			return true
		}
		system.sleep(system.time() + 1)
	}
	return false
}

// still says if a count stays the same while the thread that adds to it
// had the time to turn its loop many times: a few milliseconds, which a
// stopped thread never uses. A thread that is not stopped makes the count
// change, also on a slow host, before its time ends.
still :: proc "contextless" (count: ^u64) -> bool {
	start := intrinsics.atomic_load(count)
	system.sleep(system.time() + 20)
	return intrinsics.atomic_load(count) == start
}

// The thread of case 24: one word wait, which the main thread ends.
control_waiter :: proc "c" (_: rawptr) -> ! {
	for intrinsics.atomic_load(&waiter_word) == 0 {
		system.word_wait(&waiter_word, 0)
	}
	intrinsics.atomic_store(&waiter_runs, 1)
	system.thread_stop()
}

// The handler of case 27. Resume after the divide error is refused while
// the registers are those of the fault; the handler then moves the
// instruction address past the div, writes the result in rax, and Resume
// is accepted. The faulting thread is named by its number: it is a thread
// of this program.
divide_handler :: proc "c" (_: rawptr) -> ! {
	if system.fault_handler_set(kinds = {.Divide_Error}) != .Ok {
		system.stop(21)
	}
	handler_record = system.thread_record()
	intrinsics.atomic_store(&handler_ready, 1)
	record, _ := system.fault_record_next()
	intrinsics.volatile_store(&divide_record_instruction, record.instruction)
	divide_resume_before_write = system.fault_answer(record, .Resume)
	registers: op.Thread_Registers
	_, read := control(0, record.thread, .Read_Registers, &registers, size_of(registers))
	same := registers.rip == record.instruction
	registers.rip += address_of(&divide_instruction_end) - address_of(&divide_instruction)
	registers.rax = DIVIDE_RESULT
	_, written := control(0, record.thread, .Write_Registers, &registers, size_of(registers))
	resumed := system.fault_answer(record, .Resume)
	divide_skip_right = read == .Ok && same && written == .Ok && resumed == .Ok
	intrinsics.atomic_store(&divide_handler_done, 1)
	for {
		system.sleep(system.time() + 1000)
	}
}

child_controls :: proc "contextless" () -> ! {
	bits: u32
	spinner, started := system.thread_start(spin_and_publish, &control_cells, 4)
	if started != .Ok {
		system.stop(20)
	}
	// The spinner turned once: a stop then finds it in its loop.
	grows(&control_cells.count)

	// 20. A stop of a thread that spins.
	registers: op.Thread_Registers
	stopped, stop_status := control(spinner.handle, 0, .Stop)
	_, read := control(spinner.handle, 0, .Read_Registers, &registers, size_of(registers))
	inside := registers.rip >= address_of(&spin_loop_start) && registers.rip < address_of(&spin_loop_end)
	quiet := still(&control_cells.count)
	right := stop_status == .Ok && stopped[0] == 1 && read == .Ok && inside && quiet
	if right {
		bits |= 0x01
	}
	system.log("fault_ring: a stop of a thread that spins: ", inside ? string("the instruction address is inside its loop") : string("the instruction address is NOT inside its loop"), ", ", quiet ? string("and the loop did not turn while the thread was stopped") : string("and the loop turned while the thread was stopped"), right ? string(": as it must") : string(": WRONG"))

	// 21. A write of a register that the thread then publishes.
	registers.r12 = WRITTEN_VALUE
	_, written := control(spinner.handle, 0, .Write_Registers, &registers, size_of(registers))
	resumed, resume_status := control(spinner.handle, 0, .Resume)
	published := false
	for deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS; !published && system.time() < deadline; {
		published = intrinsics.atomic_load(&control_cells.value) == WRITTEN_VALUE
		if !published {
			system.sleep(system.time() + 1)
		}
	}
	right = written == .Ok && resume_status == .Ok && resumed[0] == 0 && published
	if right {
		bits |= 0x02
	}
	system.log("fault_ring: a write of a register: the thread published ", system.Hex(intrinsics.atomic_load(&control_cells.value)), " from r12 after its Resume", right ? string(": as it must") : string(": WRONG"))

	// 22. Frames that a program cannot hold: each refused, nothing changed.
	control(spinner.handle, 0, .Stop)
	control(spinner.handle, 0, .Read_Registers, &registers, size_of(registers))
	hostile := [4]op.Thread_Registers{registers, registers, registers, registers}
	hostile[0].cs = 0x08 // The code selector of the kernel.
	hostile[1].rflags |= 0x3000 // The I/O privilege level 3.
	hostile[2].rflags &~= 0x200 // Interrupts off.
	hostile[3].rip = 0x8000_0000_0000_0000 // Not canonical.
	refused: u64
	for &item in hostile {
		if _, status := control(spinner.handle, 0, .Write_Registers, &item, size_of(item)); status == .Bad_Operation {
			refused += 1
		}
	}
	after: op.Thread_Registers
	control(spinner.handle, 0, .Read_Registers, &after, size_of(after))
	unchanged := after.rip == registers.rip && after.cs == registers.cs && after.rflags == registers.rflags
	control(spinner.handle, 0, .Resume)
	ran := grows(&control_cells.count)
	right = refused == len(hostile) && unchanged && ran
	if right {
		bits |= 0x04
	}
	system.log("fault_ring: a frame that a program cannot hold: ", refused, " writes of ", u64(len(hostile)), " refused with Bad_Operation (the code selector of the kernel, the I/O privilege level, interrupts off, an instruction address that is not canonical); ", ran ? string("the thread ran after its Resume") : string("the thread did not run after its Resume"), right ? string(": as it must") : string(": WRONG"))

	// 23. Extended states that the processor refuses.
	control(spinner.handle, 0, .Stop)
	state, _ := system.call(.Thread_State, u64(spinner.handle))
	size, with_header := state[2], state[4] == 1
	_, area_read := control(spinner.handle, 0, .Read_Extended_State, &extended_state_area, size)
	asked, area_refused: u64
	if with_header {
		// Bit 63 of XSTATE_BV: no processor has that component.
		extended_state_hostile = extended_state_area
		extended_state_hostile[op.EXTENDED_STATE_LEGACY_BYTES + 7] |= 0x80
		asked += 1
		if _, status := control(spinner.handle, 0, .Write_Extended_State, &extended_state_hostile, size); status == .Bad_Operation {
			area_refused += 1
		}
	}
	// Bit 31 of MXCSR: reserved on every processor.
	extended_state_hostile = extended_state_area
	extended_state_hostile[op.EXTENDED_STATE_MXCSR_OFFSET + 3] |= 0x80
	asked += 1
	if _, status := control(spinner.handle, 0, .Write_Extended_State, &extended_state_hostile, size); status == .Bad_Operation {
		area_refused += 1
	}
	_, area_written := control(spinner.handle, 0, .Write_Extended_State, &extended_state_area, size)
	control(spinner.handle, 0, .Resume)
	ran = grows(&control_cells.count)
	right = area_read == .Ok && area_refused == asked && area_written == .Ok && ran
	if right {
		bits |= 0x08
	}
	system.log("fault_ring: an extended state that faults: every hostile write refused with Bad_Operation, the area that was read accepted; ", ran ? string("the thread ran after its Resume") : string("the thread did not run after its Resume"), right ? string(": as it must") : string(": WRONG"))

	// 24. A stop of a thread that waits, then its wake.
	waiter, waiter_started := system.thread_start(control_waiter, nil, 4)
	if waiter_started != .Ok {
		system.stop(20)
	}
	for deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS; system.time() < deadline; {
		waiting, _ := system.call(.Thread_State, u64(waiter.handle))
		if op.Program_State(waiting[0]) == .Waiting {
			break
		}
		system.sleep(system.time() + 1)
	}
	control(waiter.handle, 0, .Stop)
	intrinsics.atomic_store(&waiter_word, 1)
	woke := system.word_wake(&waiter_word)
	system.sleep(system.time() + 20)
	held, _ := system.call(.Thread_State, u64(waiter.handle))
	did_not_run := intrinsics.atomic_load(&waiter_runs) == 0 && op.Program_State(held[0]) == .Ready && held[1] == 1
	control(waiter.handle, 0, .Resume)
	ran_after := wait_for(&waiter_runs)
	right = woke == 1 && did_not_run && ran_after
	if right {
		bits |= 0x10
	}
	system.log("fault_ring: a stop of a thread that waits: its wait ended, ", did_not_run ? string("it did not run before its Resume") : string("it ran before its Resume"), ", ", ran_after ? string("and it ran after it") : string("and it did not run after it"), right ? string(": as it must") : string(": WRONG"))

	// 25. Two stops need two resumes.
	first, _ := control(spinner.handle, 0, .Stop)
	second, _ := control(spinner.handle, 0, .Stop)
	one_left, _ := control(spinner.handle, 0, .Resume)
	quiet = still(&control_cells.count)
	none_left, _ := control(spinner.handle, 0, .Resume)
	ran = grows(&control_cells.count)
	_, third := control(spinner.handle, 0, .Resume)
	right = first[0] == 1 && second[0] == 2 && one_left[0] == 1 && quiet && none_left[0] == 0 && ran && third == .Bad_State
	if right {
		bits |= 0x20
	}
	system.log("fault_ring: two stops, two resumes: ", quiet ? string("still stopped after one Resume") : string("ran after one Resume"), ", ", ran ? string("running after the second") : string("not running after the second"), "; a third Resume got ", op.STATUS_NAMES[third], right ? string(": as it must") : string(": WRONG"))

	// 26. The rights of a thread handle. A handle with Read and Control,
	// the rights to read the state and to end the thread, neither holds the
	// thread nor reads or writes its registers. A handle with Inspect only
	// holds it, reads its registers and resumes it, and cannot write them.
	ender, ender_given := system.give(0, spinner.handle, {.Read, .Control})
	_, ender_stop := control(ender, 0, .Stop)
	_, ender_read := control(ender, 0, .Read_Registers, &registers, size_of(registers))
	_, ender_write := control(ender, 0, .Write_Registers, &registers, size_of(registers))
	count_state, state_status := system.call(.Thread_State, u64(ender))
	ender_right := ender_given == .Ok && ender_stop == .No_Right && ender_read == .No_Right && ender_write == .No_Right && state_status == .Ok && count_state[1] == 0
	inspector, inspector_given := system.give(0, spinner.handle, {.Inspect})
	_, inspector_stop := control(inspector, 0, .Stop)
	_, inspector_read := control(inspector, 0, .Read_Registers, &registers, size_of(registers))
	_, inspector_write := control(inspector, 0, .Write_Registers, &registers, size_of(registers))
	_, inspector_resume := control(inspector, 0, .Resume)
	inspector_right := inspector_given == .Ok && inspector_stop == .Ok && inspector_read == .Ok && inspector_write == .No_Right && inspector_resume == .Ok
	ran = grows(&control_cells.count)
	right = ender_right && inspector_right && ran
	if right {
		bits |= 0x40
	}
	system.log("fault_ring: the rights of a thread handle: with Read and Control, Stop got ", op.STATUS_NAMES[ender_stop], ", Read_Registers ", op.STATUS_NAMES[ender_read], ", Write_Registers ", op.STATUS_NAMES[ender_write], "; with Inspect only, Stop, Read_Registers and Resume got ", inspector_stop == .Ok && inspector_read == .Ok && inspector_resume == .Ok ? string("Ok") : string("an error"), ", Write_Registers ", op.STATUS_NAMES[inspector_write], "; the thread kept running", right ? string(": as it must") : string(": WRONG"))

	// 27. A divide error skipped by its handler.
	handler_start(divide_handler)
	result := divide_and_skip()
	wait_for(&divide_handler_done)
	at_div := intrinsics.volatile_load(&divide_record_instruction) == address_of(&divide_instruction)
	right = at_div && divide_resume_before_write == .Bad_State && divide_skip_right && result == DIVIDE_RESULT
	if right {
		bits |= 0x80
	}
	system.log("fault_ring: a divide error skipped by its handler: Resume before the write got ", op.STATUS_NAMES[divide_resume_before_write], "; after the write of the instruction address and rax, the thread went on with ", result, right ? string(": as it must") : string(": WRONG"))
	system.stop(CONTROLS_CODE | bits)
}

// Case 28. This program has its thread 0 alone: each other number names no
// thread, and the number of a handle of the parent names nothing here.
child_foreign_thread :: proc "contextless" () -> ! {
	tried, refused: u64
	for number in u64(1) ..< op.THREAD_CAPACITY {
		tried += 1
		if _, status := control(0, number, .Stop); status == .Bad_State {
			refused += 1
		}
	}
	tried += 1
	if _, status := control(system.Handle(intrinsics.volatile_load(&shared_page().parent_thread_handle)), 0, .Stop); status == .Bad_Handle {
		refused += 1
	}
	system.log("fault_ring: the thread of another program: ", refused, " calls of ", tried, " refused; no number and no handle of this program names it", refused == tried ? string(": as it must") : string(": WRONG"))
	system.stop(FOREIGN_THREAD_CODE | (refused == tried ? u32(FOREIGN_THREAD_ALL) : u32(0)))
}

// The cases 29 to 33: the entries to the gates and the debug trap. The
// handler keeps each record, skips the two bytes of int 14, and answers
// Resume to each record.
entry_records: [64]op.Fault_Record
entry_record_count: u32
entry_handler_failures: u32

entries_handler :: proc "c" (_: rawptr) -> ! {
	if system.fault_handler_set(kinds = {.Debug, .Breakpoint, .General_Protection}) != .Ok {
		system.stop(21)
	}
	handler_record = system.thread_record()
	intrinsics.atomic_store(&handler_ready, 1)
	for {
		record, ok := system.fault_record_next()
		if !ok {
			continue
		}
		count := intrinsics.atomic_load(&entry_record_count)
		if count < len(entry_records) {
			entry_records[count] = record
		}
		intrinsics.atomic_store(&entry_record_count, count + 1)
		if record.kind == .General_Protection {
			registers: op.Thread_Registers
			_, read := control(0, record.thread, .Read_Registers, &registers, size_of(registers))
			registers.rip += 2
			_, written := control(0, record.thread, .Write_Registers, &registers, size_of(registers))
			if read != .Ok || written != .Ok {
				intrinsics.atomic_add(&entry_handler_failures, 1)
			}
		}
		if system.fault_answer(record, .Resume) != .Ok {
			intrinsics.atomic_add(&entry_handler_failures, 1)
			system.fault_answer(record, .Stop)
		}
	}
}

// entry_records_since gives the records that the handler kept after the
// first `start` ones.
entry_records_since :: proc "contextless" (start: u32) -> []op.Fault_Record {
	count := min(intrinsics.atomic_load(&entry_record_count), u32(len(entry_records)))
	return entry_records[start:max(count, start)]
}

entry_line :: proc "contextless" (name: string, sentence: string, right: bool) {
	system.log("fault_ring: ", name, ": ", sentence, right ? string(": as it must") : string(": WRONG"))
}

child_debug_entries :: proc "contextless" () -> ! {
	handler_start(entries_handler)
	bits: u32

	// 29. int 3 in two bytes.
	start := intrinsics.atomic_load(&entry_record_count)
	two_byte_breakpoint()
	records := entry_records_since(start)
	right := len(records) == 1 && records[0].kind == .Breakpoint && records[0].instruction == address_of(&two_byte_breakpoint_instruction) + 2
	if right {
		bits |= 0x01
	}
	entry_line("int 3 in two bytes", "one breakpoint record, at the address of the instruction plus 2", right)

	// 30. int 14.
	start = intrinsics.atomic_load(&entry_record_count)
	interrupt_fourteen()
	records = entry_records_since(start)
	right = len(records) == 1 && records[0].kind == .General_Protection && records[0].error_code == INT_FOURTEEN_ERROR_CODE && records[0].instruction == address_of(&interrupt_fourteen_instruction) && intrinsics.atomic_load(&entry_handler_failures) == 0
	if right {
		bits |= 0x02
	}
	entry_line("int 14", "one protection fault with the error code 0x72, no page fault; the handler skipped the two bytes", right)

	// 31. int1.
	start = intrinsics.atomic_load(&entry_record_count)
	icebp()
	records = entry_records_since(start)
	right = len(records) == 1 && records[0].kind == .Debug && records[0].instruction == address_of(&icebp_instruction) + 1
	if right {
		bits |= 0x04
	}
	entry_line("int1", "one debug record, at the address of the instruction plus 1", right)

	// 32. The trap flag set with popfq.
	start = intrinsics.atomic_load(&entry_record_count)
	single_step_six()
	records = entry_records_since(start)
	right = len(records) == SINGLE_STEP_RECORDS && records[0].instruction == address_of(&single_step_first) + 1 && records[len(records) - 1].instruction == address_of(&single_step_end)
	for record, index in records {
		if record.kind != .Debug || index > 0 && record.instruction <= records[index - 1].instruction {
			right = false
		}
	}
	if right {
		bits |= 0x08
	}
	entry_line("the trap flag set with popfq", "6 debug records, one after each instruction, the last after the popfq that cleared the flag", right)

	// 33. mov ss, then syscall, with the trap flag.
	start = intrinsics.atomic_load(&entry_record_count)
	mov_ss_then_syscall()
	records = entry_records_since(start)
	right = len(records) >= 1 && intrinsics.atomic_load(&entry_handler_failures) == 0
	for record in records {
		if record.kind != .Debug || record.instruction <= u64(uintptr(rawptr(mov_ss_then_syscall))) || record.instruction > address_of(&mov_ss_then_syscall_end) {
			right = false
		}
	}
	if right {
		bits |= 0x10
	}
	entry_line("mov ss, then syscall, with the trap flag", "on this processor the machine went on, and each record is a debug trap of this program, in its code", right)
	system.stop(DEBUG_ENTRIES_CODE | bits)
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
		// The stop comes while the thread waits: after its record, which is
		// published after the thread waits.
		for intrinsics.atomic_load(&handler_record.fault_written) == 0 {
			system.sleep(system.time() + 1)
		}
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
	case .Divide_Error:
		kinds_wanted = {.Divide_Error}
		handler_start(kinds_handler)
		divide_by_zero()
	case .Invalid_Opcode:
		kinds_wanted = {.Invalid_Opcode}
		handler_start(kinds_handler)
		intrinsics.trap()
	case .Breakpoint:
		child_breakpoint()
	case .Page_Faults_Only:
		// No kinds: page faults only.
		kinds_wanted = {}
		handler_start(kinds_handler)
		divide_by_zero()
	case .General_Protection:
		kinds_wanted = {.General_Protection}
		handler_start(kinds_handler)
		interrupts_off()
	case .Kinds_Never_Delivered:
		child_kinds_never_delivered()
	case .Controls:
		child_controls()
	case .Foreign_Thread:
		child_foreign_thread()
	case .Debug_Entries:
		child_debug_entries()
	}
	system.stop(30) // Not reached: each case above stops its program.
}

// child_run starts the child of a role, waits for its stop, and gives its
// stop code and stop report. The budget of this program, before the start
// and after the end of the child, says if the child left anything behind.
// ran is false when a call failed: the call, its status and the budget are
// on the log, and the case is wrong; a failed call is never read as a stop.
child_run :: proc "contextless" (role: Role, name: string, parent_thread_handle: system.Handle = 0) -> (code: u32, report: op.Stop_Report, left_behind: bool, ran: bool, page: Shared_Page) {
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
	intrinsics.volatile_store(&in_parent.parent_thread_handle, u64(parent_thread_handle))
	intrinsics.atomic_store(&in_parent.go, 1)
	system.word_wake(&in_parent.go)
	stopped := false
	results: [7]u64
	// A case that never writes its progress keeps the bound of a hang from
	// its start.
	started := system.time()
	stall_deadline := started + system.TEST_HANG_BOUND_MILLISECONDS
	overall_deadline := started + system.TEST_PROGRESS_OVERALL_BOUND_MILLISECONDS
	progress_seen: u64
	for now := started; now < stall_deadline && now < overall_deadline; now = system.time() {
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
		if progress := intrinsics.volatile_load(&in_parent.progress); progress > progress_seen {
			progress_seen = progress
			stall_deadline = system.time() + system.TEST_HANG_BOUND_MILLISECONDS
		}
		system.sleep(system.time() + 10)
	}
	if !stopped {
		elapsed := system.time() - started
		progress := intrinsics.volatile_load(&in_parent.progress)
		answers := intrinsics.volatile_load(&in_parent.answers)
		switch {
		case role != .Early_Answer:
			system.log("fault_ring: ", name, ": the child did not stop in ", u64(system.TEST_HANG_BOUND_MILLISECONDS), " ms")
		case stall_deadline >= overall_deadline:
			// The loop ends at the first of the two bounds: here, the overall one.
			system.log("fault_ring: ", name, ": the child did not stop in ", u64(system.TEST_PROGRESS_OVERALL_BOUND_MILLISECONDS), " ms: at step ", progress, " of ", u64(EARLY_FAULTS), ", ", answers, " answers, after ", elapsed, " ms")
		case:
			system.log("fault_ring: ", name, ": the child did not stop: no progress for ", u64(system.TEST_HANG_BOUND_MILLISECONDS), " ms at step ", progress, " of ", u64(EARLY_FAULTS), ", ", answers, " answers, after ", elapsed, " ms")
		}
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
	// for it. The bound only ends a hang: a loaded host can take long.
	left_behind = true
	after: system.Budget_Amounts
	for deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS; left_behind && system.time() < deadline; {
		after, _ = system.budget_read()
		// The start also made page tables of this program for its views of
		// the module of the child (support/system, module_prepare and
		// segment_copy); each unmap of a view gave them back.
		left_behind = after.pages != before.pages || after.threads != before.threads || after.programs != before.programs
		if left_behind {
			system.sleep(system.time() + 10)
		}
	}
	if left_behind {
		// The numbers tell a slow release from a leak, and which amount it
		// is: the next read comes after the line.
		system.log("fault_ring: ", name, ": the budget of this program did not get back every page, thread and program of the child in ", u64(system.TEST_HANG_BOUND_MILLISECONDS), " ms: pages ", before.pages, " expected, ", after.pages, " after; threads ", before.threads, ", ", after.threads, "; programs ", before.programs, ", ", after.programs)
		later, _ := system.budget_read()
		system.log("fault_ring: ", name, ": after the line: pages ", later.pages, ", threads ", later.threads, ", programs ", later.programs)
	}
	page = in_parent^
	ran = true
	return
}

draw :: proc "contextless" (window: ^display.Window) {
	frame := interface.window_frame_begin(&drawing, window)
	interface.background(&frame, {0, 0, WIDTH, HEIGHT})
	content := interface.card(&frame, {8, 8, WIDTH - 16, HEIGHT - 16}, "THE FAULT RING", "a fault of a thread becomes a record for a handler thread of the program, in place of a stop", graphics.COLOR_KERNEL)
	// Two columns of rows: the cases do not fit in one window height.
	half := (content.width - COLUMN_GAP) / 2
	columns := [2]interface.Column {
		interface.column_of({content.x, content.y, half, content.height}),
		interface.column_of({content.x + half + COLUMN_GAP, content.y, half, content.height}),
	}
	for &item, index in cases {
		column := &columns[index < ROWS_IN_THE_FIRST_COLUMN ? 0 : 1]
		value := "not run yet"
		color: graphics.Color = graphics.COLOR_DIM
		if item.ran {
			value = item.right ? "as it must" : "WRONG: see the log"
			color = item.right ? graphics.COLOR_PROGRAM : graphics.COLOR_FAILED
			if item.value_length > 0 {
				value = string(item.value[:item.value_length])
			}
		}
		interface.label_value_line(&frame, interface.column_take(column, LINE), item.name, value, color, VALUE_X)
	}
	interface.window_frame_end(&drawing, &frame, window)
}

case_log :: proc "contextless" (item: ^Case, code: u32, address: u64) {
	system.log("fault_ring: ", item.name, ": the child stopped with the code ", system.Hex(u64(code)), ", the address ", system.Hex(address), item.right ? string(": as it must") : string(": WRONG"))
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	if role := role_of(ctx.values[VALUE_ROLE]); role != .Parent {
		go := &shared_page().go
		for intrinsics.atomic_load(go) == 0 {
			system.word_wait(go, 0)
		}
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
		cases[2].value_length = len(system.format(cases[2].value[:], "as it must: ", page.least_fault_nanoseconds, " ns a fault"))
	}
	draw(&window)
	for &item in cases[4:FIRST_CONTROL_ROW] {
		report: op.Stop_Report
		code, report, left, ran, page = child_run(item.role, item.name)
		item.ran = true
		switch item.role {
		case .Parent, .Repairs, .Controls, .Foreign_Thread, .Debug_Entries:
			// Not in these rows: the cases 1 to 4 ran above in one child, the
			// cases from 20 run below.
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
		case .Divide_Error:
			item.right = kinds_case_right(&item, code, &report, &page, .Divide_Error) && !left
		case .Invalid_Opcode:
			item.right = kinds_case_right(&item, code, &report, &page, .Invalid_Opcode) && !left
		case .General_Protection:
			item.right = kinds_case_right(&item, code, &report, &page, .General_Protection) && !left
		case .Breakpoint:
			item.right = code == BREAKPOINT_CODE | BREAKPOINT_ALL && !left
		case .Page_Faults_Only:
			item.right = code == op.STOP_CODE_FAULT + u32(op.Fault_Kind.Divide_Error) && report.vector == u32(op.Fault_Kind.Divide_Error) && page.records_seen == 0 && !left
			system.log("fault_ring: ", item.name, ": the handler read ", page.records_seen, " records; the stop report names the vector ", u64(report.vector), item.right ? string(": as it must") : string(": WRONG"))
		case .Kinds_Never_Delivered:
			item.right = code == op.STOP_CODE_FAULT + u32(op.Fault_Kind.Divide_Error) && page.refused_arguments == u64(len(NEVER_DELIVERED_VECTORS)) + 1 && !left
		}
		item.right = item.right && ran
		case_log(&item, code, report.address)
		draw(&window)
	}

	// The control of a thread: one child for the cases 20 to 27.
	code, _, left, ran, _ = child_run(.Controls, "the control of a thread")
	for &item in cases[FIRST_CONTROL_ROW:FOREIGN_THREAD_ROW] {
		item.ran = true
		item.right = ran && code & ~u32(CONTROLS_ALL) == CONTROLS_CODE && code & item.bit != 0 && !left
	}
	system.log("fault_ring: the control of a thread: the child stopped with the code ", system.Hex(u64(code)), code == CONTROLS_CODE | CONTROLS_ALL && !left ? string(": as it must") : string(": WRONG"))
	draw(&window)

	// Case 28: a thread of this program that spins, which the child cannot
	// name.
	foreign_case := &cases[FOREIGN_THREAD_ROW]
	parent_spinner, spinner_started := system.thread_start(spin_and_publish, &parent_cells, 4)
	if spinner_started == .Ok {
		grows(&parent_cells.count)
		code, _, left, ran, _ = child_run(.Foreign_Thread, foreign_case.name, parent_spinner.handle)
		state, _ := system.call(.Thread_State, u64(parent_spinner.handle))
		kept_running := state[1] == 0 && grows(&parent_cells.count)
		system.thread_end(parent_spinner)
		foreign_case.right = ran && code == FOREIGN_THREAD_CODE | FOREIGN_THREAD_ALL && kept_running && !left
		system.log("fault_ring: ", foreign_case.name, ": the thread of the parent has the stop count ", state[1], " and ", kept_running ? string("kept running") : string("did not run"), foreign_case.right ? string(": as it must") : string(": WRONG"))
	} else {
		system.log("fault_ring: ", foreign_case.name, ": the thread of the parent did not start: ", op.STATUS_NAMES[spinner_started])
	}
	foreign_case.ran = true
	draw(&window)

	// The entries to the gates and the debug trap: one child for the cases
	// 29 to 33.
	code, _, left, ran, _ = child_run(.Debug_Entries, "the entries and the debug trap")
	for &item in cases[FIRST_ENTRY_ROW:] {
		item.ran = true
		item.right = ran && code & ~u32(DEBUG_ENTRIES_ALL) == DEBUG_ENTRIES_CODE && code & item.bit != 0 && !left
	}
	system.log("fault_ring: the entries and the debug trap: the child stopped with the code ", system.Hex(u64(code)), code == DEBUG_ENTRIES_CODE | DEBUG_ENTRIES_ALL && !left ? string(": as it must") : string(": WRONG"))
	draw(&window)

	right := 0
	for item in cases {
		if item.right {
			right += 1
		}
	}
	if right == len(cases) {
		system.log("fault_ring: ok, ", u64(len(cases)), " cases: each fault was repaired, or stopped its program with the report of today, each control of a thread held, and each child gave back every page and every thread")
	} else {
		system.log("fault_ring: failed: ", u64(len(cases) - right), " cases of ", u64(len(cases)))
	}
	for {
		draw(&window)
		display.wait(&window, system.time() + 1000)
		interface.window_events(&drawing, &window)
	}
}
