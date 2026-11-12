package kerneltool

// The return to a program (docs/ARCHITECTURE.md, "The return to a program"):
// one machine. The program extended_state holds its registers in more
// threads than processors; while it runs, the program return_fault starts
// three children, each with a thread whose return the processor would
// refuse at iretq. The kernel stops the first two as their own faults, with
// the stop code of a refused return and the address in the stop report, and
// returns to the third with the flags of a program. The machine goes on: the
// threads of extended_state keep each register, also the threads that ran
// on the processor of a child that the kernel stopped while it held values
// in the high halves of its ymm registers.
//
// The lines of the two programs come in any order between them: each Wait
// but the last one searches from the place after "extended_state: the
// usable instruction sets".

TEST_OUTPUT_RETURN_FAULT :: BUILD_FOLDER + "/test_output_return_fault.txt"

@(rodata)
scenario_return_fault := [?]Step {
	{kind = .Wait, text = "kernel: ok"},
	{kind = .Wait, text = "compositor: surface console"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "start(\"extended_state\")"},
	{kind = .Wait, text = "extended_state: the usable instruction sets: SSE, SSE2"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "start(\"return_fault\")"},
	{kind = .Wait, text = "kernel: program return_fault child stopped: the kernel cannot return to its thread: the instruction address is not an address of a program: 0000800000000000", any_order = true},
	{kind = .Wait, text = "return_fault: the instruction address after the last page: the child stopped with the code 0000000000000400, the address 0000800000000000: as it must", any_order = true},
	{kind = .Wait, text = "kernel: program return_fault child stopped: the kernel cannot return to its thread: the stack address is not canonical: 8000000000000000", any_order = true},
	{kind = .Wait, text = "return_fault: a stack address that is not canonical: the child stopped with the code 0000000000000400, the address 8000000000000000: as it must", any_order = true},
	{kind = .Wait, text = "return_fault: the flag nested task at a syscall: the child stopped with the code 0000000000000001, the address 0000000000000000: as it must", any_order = true},
	{kind = .Wait, text = "extended_state: ok, ", any_order = true},
	{kind = .Wait, text = "return_fault: ok, 3 cases: each child stopped as its own fault or returned with the flags of a program, and the machine goes on"},
	{kind = .Front, text = "return_fault"},
	{kind = .Shot, text = "return_fault"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "shutdown()"},
	{kind = .Wait, text = "kernel: the machine stops with code 0"},
}

return_fault_tests_run :: proc() -> bool {
	return machine_test(scenario_return_fault[:], BOOT_VOLUME, TEST_OUTPUT_RETURN_FAULT, MACHINE_STOP_OK, TEST_DATA_DISK)
}
