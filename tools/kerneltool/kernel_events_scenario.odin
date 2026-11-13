package kerneltool

// Kernel events (docs/ARCHITECTURE.md, "Kernel events"): one machine. The
// program kernel_events gives event tables to the kernel and reads the
// rings: a copy of the machine handle with no right is refused, and so is a
// seventeenth rule; 1000 operations of one child are 1000 records, and 100
// with "one in 10"; a thread that sleeps 20 times has at least 20 switches;
// a child that faults once has one record of a fault that stopped it; a
// full ring of 16 records counts each lost record; a table taken away
// writes no more records; the address of a fault is 0 for a rule for every
// program and given for a rule that names the child; 1000 gives and ends of
// a table under a load on each processor leave a pattern whole after each
// end. The cost of an entry in four rounds (no rule, a rule that names
// another program, a rule for every program that matches nothing, a rule
// that accepts each operation), with records + lost that agree with the
// count of the loop of the child, is a line of the log, for the
// coordinator.
//
// Then the two ends of a table that the program does not ask for. The tool
// stops kernel_events while its table is given: the kernel ends the table
// with its owner; the second run of kernel_events gives its first table
// with Ok (a table that the kernel had kept, of another program now, would
// be refused). In the second run, the scenario revokes the grant machine in
// the console: the table ends with the right, no record comes after, and
// Events_Set is refused.

TEST_OUTPUT_KERNEL_EVENTS :: BUILD_FOLDER + "/test_output_kernel_events.txt"

@(rodata)
scenario_kernel_events := [?]Step {
	{kind = .Wait, text = "kernel: ok"},
	{kind = .Wait, text = "compositor: surface console"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "start(\"kernel_events\")"},
	{kind = .Wait, text = "kernel_events: no grant: Events_Set with a copy of the machine handle with no right gave No_Right: as it must"},
	{kind = .Wait, text = "kernel: program kernel_events gave the event table: 16 rules, 8192 records in the ring of each of "},
	{kind = .Wait, text = "kernel_events: a seventeenth rule: 16 rules Ok, 17 rules No_Slot: as it must"},
	{kind = .Wait, text = "kernel_events: 1000 operations Memory_Size of one program: 1000 records, 0 lost: as it must"},
	{kind = .Wait, text = "kernel_events: a thread that sleeps 20 times: "},
	{kind = .Wait, text = "kernel_events: a child that faults once: 1 record of a fault that stopped it, vector 14, address 0000000000001000, stop code 000000000000010e: as it must"},
	{kind = .Wait, text = "kernel_events: one in 10: 100 records of 1000 operations: as it must"},
	{kind = .Wait, text = "kernel_events: a full ring of 16 records: "},
	{kind = .Wait, text = "kernel_events: the table taken away: 0 records after it; a second take gave Bad_State: as it must"},
	{kind = .Wait, text = "kernel_events: the address of a fault: a rule for every program: "},
	{kind = .Wait, text = "kernel_events: 1000 gives and ends under load: 1000 ends with "},
	{kind = .Wait, text = "kernel_events: kernel entries in one second of the load child (its own count and time): no rule "},
	{kind = .Wait, text = "; a rule that names another program "},
	{kind = .Wait, text = " lost, of 0); a rule for every program that matches nothing "},
	{kind = .Wait, text = " lost, of 0); a rule that accepts each of its operations "},
	{kind = .Wait, text = "kernel_events: in 200 ms while this program sleeps, every program: "},
	{kind = .Wait, text = "kernel_events: the table is given; waiting for the revocation of the grant machine"},
	// The end of the table with its owner.
	{kind = .Front, text = "console"},
	{kind = .Type, text = "stop(\"kernel_events\")"},
	{kind = .Wait, text = "kernel: the event table of program kernel_events ended: its program stopped; "},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "start(\"kernel_events\")"},
	{kind = .Wait, text = "kernel_events: a seventeenth rule: 16 rules Ok, 17 rules No_Slot: as it must"},
	{kind = .Wait, text = "kernel_events: the table is given; waiting for the revocation of the grant machine"},
	// The end of the table with its right.
	{kind = .Front, text = "console"},
	{kind = .Type, text = "revoke(\"kernel_events\", \"machine\")"},
	{kind = .Wait, text = "kernel: the event table of program kernel_events ended: its right Events ended; ", any_order = true},
	{kind = .Wait, text = "root: revoked the grant machine of kernel_events, holdings ended: 1", any_order = true},
	{kind = .Wait, text = "kernel_events: the right revoked: 1000 records of 1000 before it; 0 records after it; Events_Set after it gave Bad_Handle: as it must"},
	{kind = .Wait, text = "kernel_events: ok, 12 cases: each count of the rings was exact, each refusal came, and each child gave back every page and every thread"},
	{kind = .Front, text = "kernel_events"},
	{kind = .Shot, text = "kernel_events"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "shutdown()"},
	{kind = .Wait, text = "kernel: the machine stops with code 0"},
}

kernel_events_tests_run :: proc() -> bool {
	return machine_test(scenario_kernel_events[:], BOOT_VOLUME, TEST_OUTPUT_KERNEL_EVENTS, MACHINE_STOP_OK, TEST_DATA_DISK)
}
