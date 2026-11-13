package kerneltool

// The debugger of a program (docs/ARCHITECTURE.md, "The debugger of a
// program"): one machine. The program debugged starts children of its own
// module and is their debugger: the program that creates a program has the
// right Debug on the handle that the creation gave.
//
// On the first child: the attach; the refusals (a write of breakpoints on
// a thread that is not held, a handle with no Debug, a breakpoint at an
// address of the kernel, a write of breakpoints by a program on its own
// thread); an execute breakpoint at a procedure, the registers at the
// stop, the memory of the child and the reads that the kernel refuses, a
// single step, a data breakpoint, and the end of the child with its own
// code.
//
// Then the end of the debugging gives the program back: a detach while a
// thread is held; a second debugger that ends while the child waits at
// its breakpoint, that closes its handle, whose handle is revoked, and
// that ends after a single step with its trap flag still in the thread.
//
// Then: a breakpoint of one thread does not stop another thread; a stop
// of the child on its own thread stays after a detach; a data breakpoint
// on a buffer that the kernel copies, and one that a load of the stack
// selector holds before a syscall; a full ring of the debugger, with the
// one line of the kernel for it.
//
// Each line of a case has a fixed text: the addresses and the statuses
// are in the lines "debugged: detail:", which no step waits for.

TEST_OUTPUT_DEBUGGER :: BUILD_FOLDER + "/test_output_debugger.txt"

@(rodata)
scenario_debugger := [?]Step {
	{kind = .Wait, text = "kernel: ok"},
	{kind = .Wait, text = "compositor: surface console"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "start(\"debugged\")"},
	{kind = .Wait, text = "debugged: attach: the debugger is the debug handler of the child: as it must"},
	{kind = .Wait, text = "debugged: a write of breakpoints on a thread that is not held: refused with Bad_State: as it must"},
	{kind = .Wait, text = "debugged: a handle with no Debug: attach and Stop refused with No_Right: as it must"},
	{kind = .Wait, text = "debugged: a breakpoint at an address of the kernel: refused with the breakpoint address in the error record: as it must"},
	{kind = .Wait, text = "debugged: an execute breakpoint at a procedure of the child: the fault record names breakpoint 0 and the address: as it must"},
	{kind = .Wait, text = "debugged: the registers at the stop: the instruction address is the breakpoint: as it must"},
	{kind = .Wait, text = "debugged: Read_Memory of a value of the child: the bytes of the child, not of the debugger: as it must"},
	{kind = .Wait, text = "debugged: Read_Memory at an address of the kernel: refused with Bad_Address: as it must"},
	{kind = .Wait, text = "debugged: Read_Memory of a page that the child does not map: refused with Bad_Address: as it must"},
	{kind = .Wait, text = "debugged: Read_Memory through a thread handle with Inspect only: refused with No_Right: as it must"},
	{kind = .Wait, text = "debugged: a write of breakpoints on a thread of the caller, with no Debug handle: refused with Bad_Handle: as it must"},
	{kind = .Wait, text = "debugged: a single step: one instruction ran, and the record names the step: as it must"},
	{kind = .Wait, text = "debugged: a data breakpoint on a word that the child writes: the fault record names breakpoint 1: as it must"},
	{kind = .Wait, text = "debugged: the breakpoints removed: the child resumed and ended with its own code: as it must"},
	{kind = .Wait, text = "debugged: a detach while a thread is held: the child runs again: as it must"},
	{kind = .Wait, text = "debugged: the debugger ended while the child was held at a breakpoint: the child runs again: as it must"},
	{kind = .Wait, text = "debugged: the debugger closed its handle while the child was held at a breakpoint: the child runs again: as it must"},
	{kind = .Wait, text = "debugged: the handle of the debugger was revoked while the child was held at a breakpoint: the child runs again: as it must"},
	{kind = .Wait, text = "debugged: a single step, then the end of the debugger: the child ran to its own end: as it must"},
	{kind = .Wait, text = "debugged: a breakpoint of one thread: that thread stops, and another thread of the child runs through the same procedure: as it must"},
	{kind = .Wait, text = "debugged: a stop of the child on its own thread, then a stop and a detach of the debugger: the thread is still held by the stop of the child: as it must"},
	{kind = .Wait, text = "the kernel copied this line from a watched buffer"},
	{kind = .Wait, text = "debugged: a data breakpoint on a buffer that the kernel copies: the operation succeeded, no record came for the copy, and the read of the child came: as it must"},
	{kind = .Wait, text = "debugged: a data breakpoint that a load of the stack selector holds before a syscall: the kernel entry returned: as it must"},
	{kind = .Wait, text = "kernel: program debugged child: the ring of its debugger is full (1 times): the debugger does not see the fault"},
	{kind = .Wait, text = "debugged: a full ring of the debugger: the breakpoint is lost for the debugger, the child goes on, and a record comes again when the ring has room: as it must"},
	{kind = .Wait, text = "debugged: ok, 24 cases: a debugger holds, reads and steps one program, and its end gives the program back"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "shutdown()"},
	{kind = .Wait, text = "kernel: the machine stops with code 0"},
}

debugger_tests_run :: proc() -> bool {
	return machine_test(scenario_debugger[:], BOOT_VOLUME, TEST_OUTPUT_DEBUGGER, MACHINE_STOP_OK, TEST_DATA_DISK)
}
