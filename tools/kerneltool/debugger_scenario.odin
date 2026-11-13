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

// The commands of the debugger (docs/TOOLS.md, "The debugger"): a second
// machine. The console starts the program debug_target, which has no grant
// of the root service and values that this scenario knows, and debugs it
// through the service `debugger`:
//
// - the attach; a breakpoint by a procedure name, then the frames of the
//   stack; a second breakpoint, and a local variable of the caller;
// - one step, which moves one instruction, and one line;
// - a breakpoint by a file and a line;
// - a field of a record inside a record, an element of an array, the name
//   of an enumeration value, a text, each by a path;
// - a watch on a global, which stops at the write;
// - the detach: the program writes its line again, so it runs.
//
// Then who can debug which program: a program with a private store, a
// service and a device service are refused; a program with a right of the
// machine, which the console holds, is given. A revocation of a grant of
// the console ends a debugging that the rule no longer gives: the machine,
// while the console debugs that program, then the attach is refused; the
// grant to act for the principal, while a thread is held, and the program
// runs again.
//
// Then the same exports from the host, through the service `remote`: the
// attach, a breakpoint by a file and a line, the stop, the source line
// with the text that the tool reads in the repository, the refusal of a
// second program while one is debugged, the detach, and the refusal of a
// program with a grant that `remote` does not hold.
//
// Each row is drawn through `columns` or `where`, so that the widths of
// its columns depend only on values that the scenario knows. A wait for a
// stop is a wait for the line of the stop in the log, then `events()` or
// `wait_stop`, which gives the stop that waits: no step waits a time. The
// machine ends by a quit of QEMU: the console lost the machine by then.

TEST_OUTPUT_DEBUGGER_COMMANDS :: BUILD_FOLDER + "/test_output_debugger_commands.txt"

// The line of the second statement of the procedure add_step of
// programs/debug_target/main.odin, a volatile store. The compiler gives
// the load of the first statement and the store one row of the line table,
// with this line. A change of that file above the procedure changes it.
DEBUG_TARGET_LINE_OF_THE_STORE :: "79"
DEBUG_TARGET_TEXT_OF_THE_STORE :: "\tintrinsics.volatile_store(sum, before + step)"

DEBUG_TARGET_RUNS :: "debug_target: 64 more rounds ran, so the program is not held: as it must"
DEBUG_ACCESS_REFUSED_BY_THE_GRANT :: "debugger.attach: the caller has no grant for this: the debug access to this program: the program holds a grant that the caller does not hold, the grant "
// The number of a grant in the enumeration Grant of programs/root/main.odin.
GRANT_NUMBER_INSPECT :: "1"
GRANT_NUMBER_SERVE :: "5"
GRANT_NUMBER_STORE :: "7"
GRANT_NUMBER_SYSTEM_PART :: "24"

@(rodata)
scenario_debugger_commands := [?]Step {
	{kind = .Wait, text = "kernel: ok"},
	{kind = .Wait, text = "compositor: surface console"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "start(\"debug_target\")"},
	{kind = .Wait, text = "root: started debug_target"},
	{kind = .Wait, text = DEBUG_TARGET_RUNS},

	// The attach: the program module has its debug object.
	{kind = .Type, text = "columns(debug(\"debug_target\"), \"program described\")"},
	{kind = .Wait, text = "[console] debug_target          1"},

	// A breakpoint by a procedure name: the main thread stops at the first
	// instruction of its next round, and its caller is the next frame.
	{kind = .Type, text = "columns(break_at(\"debug_target::count_rounds\"), \"number kind place\")"},
	// The thread can stop before the console draws the row of the command
	// that let it run: the stop is waited for first, and the row is looked
	// for in the whole log.
	{kind = .Wait, text = "debugger: the thread 0 of debug_target stopped: breakpoint 0"},
	{kind = .Wait, text = "[console]      0  execute  debug_target::count_rounds", any_order = true},
	{kind = .Type, text = "columns(events(), \"thread kind procedure offset\")"},
	{kind = .Wait, text = "[console]      0  breakpoint 0  debug_target::count_rounds       0"},
	{kind = .Type, text = "columns(stack(0), \"frame procedure\")"},
	{kind = .Wait, text = "[console]     0  debug_target::count_rounds"},
	{kind = .Wait, text = "[console]     1  debug_target::run_rounds"},

	// A second breakpoint: the first call of add_step of that round. The
	// chain of the known procedures, and a local variable of the caller,
	// which is in memory at its frame pointer.
	{kind = .Type, text = "columns(where(break_at(\"debug_target::add_step\"), \"number\", 1), \"number kind place\")"},
	{kind = .Wait, text = "[console]      1  execute  debug_target::add_step"},
	{kind = .Type, text = "columns(resume(0), \"thread\")"},
	{kind = .Wait, text = "debugger: the thread 0 of debug_target stopped: breakpoint 1"},
	{kind = .Wait, text = "[console]      0", any_order = true},
	{kind = .Type, text = "columns(wait_stop(3000), \"thread kind procedure offset\")"},
	{kind = .Wait, text = "[console]      0  breakpoint 1  debug_target::add_step       0"},
	{kind = .Type, text = "columns(stack(0), \"frame procedure\")"},
	{kind = .Wait, text = "[console]     0  debug_target::add_step"},
	{kind = .Wait, text = "[console]     1  debug_target::count_rounds"},
	{kind = .Wait, text = "[console]     2  debug_target::run_rounds"},
	{kind = .Type, text = "columns(where(locals(0, 1), \"name\", \"total\"), \"name role value type\")"},
	{kind = .Wait, text = "[console] total  local  0      u64"},

	// One step: the first instruction of the procedure, one byte. Then one
	// line: from the line of the procedure to the line of its first
	// statement.
	{kind = .Type, text = "columns(step(0), \"thread state procedure offset\")"},
	{kind = .Wait, text = "[console]      0  stopped  debug_target::add_step       1"},
	{kind = .Type, text = "columns(step_line(0), \"procedure line pending\")"},
	// The compiler gives the load and the store one row of the line table,
	// with the line of the store: the next line after the first one is it.
	{kind = .Wait, text = "[console] debug_target::add_step    " + DEBUG_TARGET_LINE_OF_THE_STORE + "        0"},

	// A breakpoint by a file and a line, in the place of the second one.
	{kind = .Type, text = "columns(break_remove(1), \"number place\")"},
	{kind = .Wait, text = "[console]      0  debug_target::count_rounds"},
	{kind = .Type, text = "columns(where(break_at(\"programs/debug_target/main.odin:" + DEBUG_TARGET_LINE_OF_THE_STORE + "\"), \"number\", 1), \"number kind\")"},
	{kind = .Wait, text = "[console]      1  execute"},
	{kind = .Type, text = "columns(resume(0), \"thread\")"},
	{kind = .Wait, text = "debugger: the thread 0 of debug_target stopped: breakpoint 1"},
	{kind = .Wait, text = "[console]      0", any_order = true},
	// The ends of the step and of the line above are no events: one row.
	{kind = .Type, text = "columns(events(), \"kind procedure line\")"},
	{kind = .Wait, text = "[console] breakpoint 1  debug_target::add_step    " + DEBUG_TARGET_LINE_OF_THE_STORE},

	// The values, each by a path from a global: the fields of a record
	// inside a record, an element of an array, the name of an enumeration
	// value, a text.
	{kind = .Type, text = "columns(value(0, 0, \"debug_target::shape.size\"), \"name value type\")"},
	{kind = .Wait, text = "[console] x     30     i64"},
	{kind = .Wait, text = "[console] y     40     i64"},
	{kind = .Type, text = "columns(value(0, 0, \"debug_target::table[2]\"), \"name value\")"},
	{kind = .Wait, text = "[console] debug_target::table[2]  30"},
	{kind = .Type, text = "columns(value(0, 0, \"debug_target::shape.phase\"), \"name value\")"},
	{kind = .Wait, text = "[console] debug_target::shape.phase  Counting"},
	{kind = .Type, text = "columns(value(0, 0, \"debug_target::title\"), \"name value\")"},
	{kind = .Wait, text = "[console] debug_target::title  \"debug target\""},

	// A watch on a global, with no other breakpoint: the thread stops after
	// the instruction that writes it, in the one procedure that does.
	{kind = .Type, text = "columns(break_remove(1), \"number place\")"},
	{kind = .Wait, text = "[console]      0  debug_target::count_rounds"},
	{kind = .Type, text = "break_remove(0)"},
	{kind = .Wait, text = "[console] 0 rows of Break_Row"},
	{kind = .Type, text = "columns(watch(\"debug_target::rounds\", 8), \"number kind length place\")"},
	{kind = .Wait, text = "[console]      0  write       8  debug_target::rounds"},
	{kind = .Type, text = "columns(resume(0), \"thread\")"},
	{kind = .Wait, text = "debugger: the thread 0 of debug_target stopped: watch 0"},
	{kind = .Wait, text = "[console]      0", any_order = true},
	{kind = .Type, text = "columns(events(), \"thread kind procedure\")"},
	{kind = .Wait, text = "[console]      0  watch 0  debug_target::record_round"},

	// The detach: one breakpoint leaves, the held thread runs, and the
	// program writes its line again.
	{kind = .Type, text = "columns(detach(), \"program breakpoints\")"},
	{kind = .Wait, text = "[console] debug_target            1"},
	{kind = .Wait, text = DEBUG_TARGET_RUNS},

	// Who can debug which program. A private store belongs to its program:
	// the grant Store refuses, though the console holds a grant Store too.
	{kind = .Type, text = "start(\"notes\")"},
	{kind = .Wait, text = "compositor: surface notes"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "debug(\"notes\")"},
	{kind = .Wait, text = DEBUG_ACCESS_REFUSED_BY_THE_GRANT + GRANT_NUMBER_STORE + " of the root service (-4)"},
	// A service: refused for each caller. A device service: a grant that
	// no caller holds.
	{kind = .Type, text = "debug(\"storage\")"},
	{kind = .Wait, text = DEBUG_ACCESS_REFUSED_BY_THE_GRANT + GRANT_NUMBER_SERVE + " of the root service (-4)"},
	{kind = .Type, text = "debug(\"block\")"},
	{kind = .Wait, text = DEBUG_ACCESS_REFUSED_BY_THE_GRANT + GRANT_NUMBER_SYSTEM_PART + " of the root service (-4)"},

	// A revocation ends a debugging that the rule no longer gives. clock
	// holds the machine with Inspect, and so does the console: the access
	// is given. The grant machine of the console is revoked while it
	// debugs clock, with a thread held: the root service ends the
	// debugging, and a new attach is refused by the grant Inspect.
	{kind = .Type, text = "start(\"clock\")"},
	{kind = .Wait, text = "compositor: surface clock"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "columns(debug(\"clock\"), \"program described\")"},
	{kind = .Wait, text = "[console] clock            1"},
	{kind = .Type, text = "columns(hold(0), \"thread state\")"},
	{kind = .Wait, text = "[console]      0  held"},
	{kind = .Type, text = "revoke(\"console\", \"machine\")"},
	{kind = .Wait, text = "root: revoked the grant machine of console, holdings ended: "},
	{kind = .Wait, text = "root: ended the debugging of clock for console: the rule no longer gives the debug access, after a revocation"},
	{kind = .Type, text = "debug(\"clock\")"},
	{kind = .Wait, text = DEBUG_ACCESS_REFUSED_BY_THE_GRANT + GRANT_NUMBER_INSPECT + " of the root service (-4)"},

	// The grant to act for the principal is revoked while the console
	// holds a thread of debug_target: the root service ends the debugging,
	// the held thread runs again (the program writes its line), and the
	// service has no session left for the console.
	{kind = .Type, text = "columns(debug(\"debug_target\"), \"program described\")"},
	{kind = .Wait, text = "[console] debug_target          1"},
	{kind = .Type, text = "columns(hold(0), \"thread state\")"},
	{kind = .Wait, text = "[console]      0  held"},
	{kind = .Type, text = "revoke(\"console\", \"acts_for_principal\")"},
	{kind = .Wait, text = "root: revoked the grant acts_for_principal of console, connections changed: "},
	{kind = .Wait, text = "root: ended the debugging of debug_target for console: the rule no longer gives the debug access, after a revocation"},
	{kind = .Wait, text = DEBUG_TARGET_RUNS},
	// The detach needs no grant; the session ended already.
	{kind = .Type, text = "detach()"},
	{kind = .Wait, text = "debugger.detach: the call names none of the programs that the debugger service debugs for this caller (-2)"},
	{kind = .Type, text = "debug(\"debug_target\")"},
	{kind = .Wait, text = "debugger.attach: the caller has no grant for this: to act for the principal (-1)"},

	// From the host, through the service remote: the same exports.
	// debug_target has no grant; notes has a private store.
	{kind = .Launch, text = "remote"},
	{kind = .Wait, text = "root: started remote"},
	{kind = .Remote_Key, text = "remote: the public key of this service: "},
	{kind = .Wait, text = "remote: listening on the UDP port 7100, for the host 10.0.2.2 only", any_order = true},
	{kind = .Call, text = "debugger.attach(\"debug_target\")", expected = "1 rows of Attached"},
	{kind = .Call, text = "debugger.break_at(\"programs/debug_target/main.odin:" + DEBUG_TARGET_LINE_OF_THE_STORE + "\")", expected = "1 rows of Break_Row"},
	{kind = .Wait, text = "debugger: the thread 0 of debug_target stopped: breakpoint 0"},
	{kind = .Call, text = "debugger.events()", expected = "breakpoint 0"},
	// The machine has no source text: the tool reads the line in the
	// repository, because the file has the hash of the build.
	{kind = .Call, text = "debugger.source(0, 0)", expected = "source: programs/debug_target/main.odin:" + DEBUG_TARGET_LINE_OF_THE_STORE + ": " + DEBUG_TARGET_TEXT_OF_THE_STORE},
	{kind = .Call, text = "debugger.attach(\"notes\")", outcome = .Failed, expected = "error: debugger.attach: no free place: the table has its 1 programs that the debugger service debugs for this caller (-3)"},
	{kind = .Call, text = "debugger.detach()", expected = "1 rows of Detached"},
	{kind = .Wait, text = DEBUG_TARGET_RUNS},
	{kind = .Call, text = "debugger.attach(\"notes\")", outcome = .Failed, expected = "error: " + DEBUG_ACCESS_REFUSED_BY_THE_GRANT + GRANT_NUMBER_STORE + " of the root service (-4)"},

	// The console lost the machine: QEMU ends the machine.
	{kind = .Quit},
}

// The exit status of QEMU after a step Quit.
QEMU_QUIT_STATUS :: 0

// debugger_tests_run runs the two machines of the debugger: the contract
// of the kernel, then the commands. The second one runs also when the
// first one fails: each one has its own verdict.
debugger_tests_run :: proc() -> bool {
	kernel_contract := machine_test(scenario_debugger[:], BOOT_VOLUME, TEST_OUTPUT_DEBUGGER, MACHINE_STOP_OK, TEST_DATA_DISK)
	commands := machine_test(scenario_debugger_commands[:], BOOT_VOLUME, TEST_OUTPUT_DEBUGGER_COMMANDS, QEMU_QUIT_STATUS, TEST_DATA_DISK)
	return kernel_contract && commands
}
