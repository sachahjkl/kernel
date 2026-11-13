package kerneltool

// The debugger of a program (docs/ARCHITECTURE.md, "The debugger of a
// program"): one machine. The program debugged starts a child of its own
// module and is its debugger: the program that creates a program has the
// right Debug on it. It attaches, and the kernel refuses a write of
// breakpoints on a thread that is not held, a handle with no Debug and a
// breakpoint at an address of the kernel. The thread of the child reaches
// an execute breakpoint at a procedure; the debugger reads its registers,
// reads a value of the child in the memory of the child, and the kernel
// refuses a read of an address of the kernel, of a page that the child
// does not map, and a read through a thread handle with Inspect only. A
// single step runs one instruction; a data breakpoint stops the thread
// after its write; with the breakpoints removed the child ends with its
// own code. Then the end of the debugging gives the program back: a detach
// while a thread is held, and a second debugger that ends while the child
// waits at its breakpoint.
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
	{kind = .Wait, text = "debugged: a single step: one instruction ran, and the record names the step: as it must"},
	{kind = .Wait, text = "debugged: a data breakpoint on a word that the child writes: the fault record names breakpoint 1: as it must"},
	{kind = .Wait, text = "debugged: the breakpoints removed: the child resumed and ended with its own code: as it must"},
	{kind = .Wait, text = "debugged: a detach while a thread is held: the child runs again: as it must"},
	{kind = .Wait, text = "debugged: the debugger ended while the child was held at a breakpoint: the child runs again: as it must"},
	{kind = .Wait, text = "debugged: ok, 15 cases: a debugger holds, reads and steps one program, and its end gives the program back"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "shutdown()"},
	{kind = .Wait, text = "kernel: the machine stops with code 0"},
}

debugger_tests_run :: proc() -> bool {
	return machine_test(scenario_debugger[:], BOOT_VOLUME, TEST_OUTPUT_DEBUGGER, MACHINE_STOP_OK, TEST_DATA_DISK)
}
