package kerneltool

// The fault ring (docs/ARCHITECTURE.md, "The fault ring"): one machine. The
// program fault_ring runs one child for each role; a page fault of a child
// is a record for a handler thread of the child in place of a stop. The
// child that repairs commits a page, gives Write back to a page, grows a
// stack by 64 pages and sees a wrong serial refused; the other children stop
// with the report of today (an answer Stop, a fault of the handler itself, a
// full ring), stop while a thread waits, or lose their handler while a
// thread waits. Each child gives back every page and every thread of its
// budget. The time of one repaired fault is a line of the log.

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
	{kind = .Wait, text = "fault_ring: ok, 9 cases: each fault was repaired, or stopped its program with the report of today, and each child gave back every page and every thread"},
	{kind = .Front, text = "fault_ring"},
	{kind = .Shot, text = "fault_ring"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "shutdown()"},
	{kind = .Wait, text = "kernel: the machine stops with code 0"},
}

fault_ring_tests_run :: proc() -> bool {
	return machine_test(scenario_fault_ring[:], BOOT_VOLUME, TEST_OUTPUT_FAULT_RING, MACHINE_STOP_OK, TEST_DATA_DISK)
}
