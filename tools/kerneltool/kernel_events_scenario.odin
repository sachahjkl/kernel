package kerneltool

// Kernel events (docs/ARCHITECTURE.md, "Kernel events"): one machine. The
// program kernel_events gives event tables to the kernel and reads the
// rings: a copy of the machine handle with no right is refused, and so is a
// seventeenth rule; 1000 operations of one child are 1000 records, and 100
// with "one in 10"; a thread that sleeps 20 times has at least 20 switches;
// a child that faults once has one record of a fault that stopped it; a
// full ring of 16 records counts each lost record; a table taken away
// writes no more records; a child that stops with its own table ends the
// table, and the program can give its own after it. The cost of an entry
// with no rule, with one rule that matches nothing, and with a rule on each
// operation is a line of the log, for the coordinator.

TEST_OUTPUT_KERNEL_EVENTS :: BUILD_FOLDER + "/test_output_kernel_events.txt"

@(rodata)
scenario_kernel_events := [?]Step {
	{kind = .Wait, text = "kernel: ok"},
	{kind = .Wait, text = "compositor: surface console"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "start(\"kernel_events\")"},
	{kind = .Wait, text = "kernel_events: no grant: Events_Set with a copy of the machine handle with no right gave No_Right: as it must"},
	{kind = .Wait, text = "kernel_events: a seventeenth rule: 16 rules Ok, 17 rules No_Slot: as it must"},
	{kind = .Wait, text = "kernel: program kernel_events gave the event table: 4 rules, 8192 records in the ring of each of "},
	{kind = .Wait, text = "kernel_events: 1000 operations Memory_Size of one program: 1000 records, 0 lost: as it must"},
	{kind = .Wait, text = "kernel_events: a thread that sleeps 20 times: "},
	{kind = .Wait, text = "kernel_events: a child that faults once: 1 record of a fault that stopped it, vector 14, address 0000000000001000, stop code 000000000000010e: as it must"},
	{kind = .Wait, text = "kernel_events: one in 10: 100 records of 1000 operations: as it must"},
	{kind = .Wait, text = "kernel_events: a full ring of 16 records: "},
	{kind = .Wait, text = "kernel_events: the table taken away: 0 records after it; a second take gave Bad_State: as it must"},
	{kind = .Wait, text = "kernel: the event table of program kernel_events child ended: "},
	{kind = .Wait, text = "kernel_events: a program that stops with its table: the child gave it (Ok); this program while it ran: Bad_State; after its stop: Ok: as it must"},
	{kind = .Wait, text = "kernel_events: kernel entries in one second, one program: no rule "},
	{kind = .Wait, text = "kernel_events: the longest operation of the machine in 200 ms: "},
	{kind = .Wait, text = "kernel_events: ok, 10 cases: each count of the rings was exact, each refusal came, and each child gave back every page and every thread"},
	{kind = .Front, text = "kernel_events"},
	{kind = .Shot, text = "kernel_events"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "shutdown()"},
	{kind = .Wait, text = "kernel: the machine stops with code 0"},
}

kernel_events_tests_run :: proc() -> bool {
	return machine_test(scenario_kernel_events[:], BOOT_VOLUME, TEST_OUTPUT_KERNEL_EVENTS, MACHINE_STOP_OK, TEST_DATA_DISK)
}
