package kerneltool

// The fault ring (docs/ARCHITECTURE.md, "The fault ring"): one machine. The
// program fault_ring runs one child for each role; a fault of a child is a
// record for a handler thread of the child in place of a stop. The
// child that repairs commits a page, gives Write back to a page, grows a
// stack by 64 pages and sees a wrong serial refused; the other children stop
// with the report of today (an answer Stop, a fault of the handler itself, a
// full ring), stop while a thread waits, or lose their handler while a
// thread waits. Four more children: the entry of an earlier word wait does
// not wake a thread that waits for an answer; a new handler while a thread
// waits stops the program; an answer from another program is refused;
// 10 000 answers given at once from another processor each resume once.
// Then the fault kinds that are not page faults: a divide error, an invalid
// opcode and a privileged instruction each give one record of their kind,
// Resume is refused and Stop gives their stop report; a breakpoint resumes
// after its int3; a handler of page faults only does not get a divide
// error; the vectors that the kernel never delivers are refused. Then the
// control of a thread: a stop, a read and a write of the registers, the
// writes that the kernel refuses, a stop of a thread that waits, two stops,
// the rights of a thread handle, a divide error that its handler skips, and no
// way to name a thread of another program without a handle. Then the
// entries to the gates and the debug trap: int 3 in two bytes, int 14,
// int1, the trap flag set with popfq, and mov ss before a syscall, before
// int3 and before int1, each with the trap flag.
// Each child gives back every page and every thread of its budget. The
// time of one repaired fault is a line of the log and of the window.

TEST_OUTPUT_FAULT_RING :: BUILD_FOLDER + "/test_output_fault_ring.txt"

@(rodata)
scenario_fault_ring := [?]Step {
	{kind = .Wait, text = "kernel: ok"},
	{kind = .Wait, text = "compositor: surface console"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "start(\"fault_ring\")"},
	{kind = .Wait, text = "fault_ring: a read of a page that is not committed: the handler committed it and wrote 5eed000000000003; the thread read 5eed000000000003: as it must"},
	{kind = .Wait, text = "fault_ring: a write to a read-only page: the handler gave Write back; the page holds 42: as it must"},
	{kind = .Wait, text = "fault_ring: a stack that grows: 64 pages of 64, each one committed by the handler at its first touch; one repaired fault took "},
	{kind = .Wait, text = "fault_ring: an answer with a wrong serial: refused with Bad_State, then the right answer resumed the thread: as it must"},
	{kind = .Wait, text = "fault_ring: the handler answers stop: the child stopped with the code 0000000000000300, the address "},
	{kind = .Wait, text = "fault_ring: a fault of the handler itself: the child stopped with the code 0000000000000300, the address "},
	{kind = .Wait, text = "kernel: program fault_ring child: the fault ring is full (1 times): the fault stops the program"},
	{kind = .Wait, text = "fault_ring: a full ring: the child stopped with the code 0000000000000300, the address "},
	{kind = .Wait, text = "fault_ring: the program stops while a thread waits: the child stopped with the code 0000000000000007, the address 0000000000000000: as it must"},
	{kind = .Wait, text = "fault_ring: the handler ends while a thread waits: the child stopped with the code 0000000000000500, the address 0000000000000000: as it must"},
	{kind = .Wait, text = "fault_ring: a word wait, a fault, a decommit of the word: the waker woke 1 thread; no second record and no run before the answer; the answer: Ok, the thread read 5eed000000000000: as it must"},
	{kind = .Wait, text = "fault_ring: a word wait, a fault, a decommit of the word: the child stopped with the code 0000000000000027, the address 0000000000000000: as it must"},
	{kind = .Wait, text = "fault_ring: a new handler while a thread waits: the child stopped with the code 0000000000000500, the address 0000000000000000: as it must"},
	{kind = .Wait, text = "fault_ring: an answer from another program: the parent answered for the thread 2 and the serial 1: refused with Bad_State; the thread still waited, and the answer of its own program resumed it: as it must"},
	{kind = .Wait, text = "fault_ring: an answer from another program: the child stopped with the code 0000000000000037, the address 0000000000000000: as it must"},
	// A Wait finds its text anywhere in the log: the line goes on with the
	// time of the case (", in N ms"), which changes from run to run. The
	// case writes its progress, and its time grows with the load of the
	// host: the step has the bound of such a case.
	{kind = .Wait, text = "fault_ring: 10 000 answers given at once: 10000 faults resumed, 10000 values right, of 10000: as it must", seconds = PROGRESS_CASE_HANG_BOUND_SECONDS},
	{kind = .Wait, text = "fault_ring: 10 000 answers given at once: the child stopped with the code 0000000000000043, the address 0000000000000000: as it must"},
	{kind = .Wait, text = "fault_ring: a divide error, answered stop: 1 record of the kind 0, the error code 0, the instruction of the stop report; Resume got Bad_State: as it must"},
	{kind = .Wait, text = "fault_ring: a divide error, answered stop: the child stopped with the code 0000000000000100, the address 0000000000000000: as it must"},
	{kind = .Wait, text = "fault_ring: an invalid opcode, answered stop: 1 record of the kind 6, the error code 0, the instruction of the stop report; Resume got Bad_State: as it must"},
	{kind = .Wait, text = "fault_ring: an invalid opcode, answered stop: the child stopped with the code 0000000000000106, the address 0000000000000000: as it must"},
	{kind = .Wait, text = "fault_ring: a breakpoint, answered resume: 1 record of the kind 3; the thread went on after the int3 and computed 42: as it must"},
	{kind = .Wait, text = "fault_ring: a breakpoint, answered resume: the child stopped with the code 0000000000000053, the address 0000000000000000: as it must"},
	{kind = .Wait, text = "fault_ring: a divide error with a handler of pages: the handler read 0 records; the stop report names the vector 0: as it must"},
	{kind = .Wait, text = "fault_ring: a divide error with a handler of pages: the child stopped with the code 0000000000000100, the address 0000000000000000: as it must"},
	{kind = .Wait, text = "fault_ring: a privileged instruction, answered stop: 1 record of the kind 13, the error code 0, the instruction of the stop report; Resume got Bad_State: as it must"},
	{kind = .Wait, text = "fault_ring: a privileged instruction, answered stop: the child stopped with the code 000000000000010d, the address 0000000000000000: as it must"},
	{kind = .Wait, text = "fault_ring: the kinds never delivered: Fault_Handler_Set refused 15 arguments of 15 with Bad_Operation: as it must"},
	{kind = .Wait, text = "fault_ring: the kinds never delivered: the child stopped with the code 0000000000000100, the address 0000000000000000: as it must"},
	// The control of a thread (docs/ARCHITECTURE.md, "The control of a
	// thread"), in one child.
	{kind = .Wait, text = "fault_ring: a stop of a thread that spins: the instruction address is inside its loop, and the loop did not turn while the thread was stopped: as it must"},
	{kind = .Wait, text = "fault_ring: a write of a register: the thread published 5eed000000000007 from r12 after its Resume: as it must"},
	{kind = .Wait, text = "fault_ring: a frame that a program cannot hold: 4 writes of 4 refused with Bad_Operation (the code selector of the kernel, the I/O privilege level, interrupts off, an instruction address that is not canonical); the thread ran after its Resume: as it must"},
	{kind = .Wait, text = "fault_ring: an extended state that faults: every hostile write refused with Bad_Operation, the area that was read accepted; the thread ran after its Resume: as it must"},
	{kind = .Wait, text = "fault_ring: a stop of a thread that waits: its wait ended, it did not run before its Resume, and it ran after it: as it must"},
	{kind = .Wait, text = "fault_ring: two stops, two resumes: still stopped after one Resume, running after the second; a third Resume got Bad_State: as it must"},
	{kind = .Wait, text = "fault_ring: the rights of a thread handle: with Read and Control, Stop got No_Right, Read_Registers No_Right, Write_Registers No_Right; with Inspect only, Stop, Read_Registers and Resume got Ok, Write_Registers No_Right; with Write only, Write_Registers got No_Right; the thread kept running: as it must"},
	{kind = .Wait, text = "fault_ring: a divide error skipped by its handler: Resume before the write got Bad_State; after the write of the instruction address and rax, the thread went on with 42: as it must"},
	{kind = .Wait, text = "fault_ring: the control of a thread: the child stopped with the code 00000000000010ff: as it must"},
	{kind = .Wait, text = "fault_ring: the thread of another program: 32 calls of 32 refused; no number and no handle of this program names it: as it must"},
	{kind = .Wait, text = "fault_ring: the thread of another program: the thread of the parent has the stop count 0 and kept running: as it must"},
	// The entries to the gates and the debug trap, in one child.
	{kind = .Wait, text = "fault_ring: int 3 in two bytes: one breakpoint record, at the address of the instruction plus 2: as it must"},
	{kind = .Wait, text = "fault_ring: int 14: one protection fault with the error code 0x72, no page fault; the handler skipped the two bytes: as it must"},
	{kind = .Wait, text = "fault_ring: int1: one debug record, at the address of the instruction plus 1: as it must"},
	{kind = .Wait, text = "fault_ring: the trap flag set with popfq: 6 debug records, one after each instruction, the last after the popfq that cleared the flag: as it must"},
	// It shows what this processor did, not every processor: a trap at the
	// first instruction of the kernel entry is dropped by the kernel there.
	{kind = .Wait, text = "fault_ring: mov ss, then syscall, with the trap flag: on this processor the machine went on, and each record is a debug trap of this program, in its code: as it must"},
	// A held trap at the stub of int3 is dropped by the kernel: the line
	// shows what this processor did.
	{kind = .Wait, text = "fault_ring: mov ss, then int3, with the trap flag: on this processor the machine went on; one breakpoint record after the int3, and each other record is a debug trap of this program, in its code: as it must"},
	{kind = .Wait, text = "fault_ring: the entries and the debug trap: the child stopped with the code 000000000000203f: as it must"},
	// Two outcomes are right, by what the processor does: the line names
	// the one of this processor, and the last line counts the case.
	{kind = .Wait, text = "fault_ring: mov ss, then int1, with the trap flag: the machine went on and the child gave back every page and every thread; on this processor "},
	{kind = .Wait, text = "fault_ring: ok, 35 cases: each fault was repaired, or stopped its program with the report of today, each control of a thread held, and each child gave back every page and every thread"},
	{kind = .Front, text = "fault_ring"},
	{kind = .Shot, text = "fault_ring"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "shutdown()"},
	{kind = .Wait, text = "kernel: the machine stops with code 0"},
}

fault_ring_tests_run :: proc() -> bool {
	return machine_test(scenario_fault_ring[:], BOOT_VOLUME, TEST_OUTPUT_FAULT_RING, MACHINE_STOP_OK, TEST_DATA_DISK)
}
