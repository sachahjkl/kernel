package kerneltool

// The extended state of the processor: three machines (docs/ARCHITECTURE.md,
// "The extended state of the processor").
//
// The first machine has each feature of the processor (`-cpu max`): the
// kernel saves x87, SSE and AVX, and AVX-512 when the host has it, with
// xsaveopt; the program extended_state holds ymm0 to ymm15 or zmm0 to zmm31
// in more threads than processors. The second machine has no AVX: the
// kernel saves x87 and SSE with xsaveopt (576 bytes), and the program says
// that AVX is not usable and holds xmm0 to xmm15. The third machine has no
// xsave: the kernel saves with fxsave (512 bytes), the other form of the
// same save, and the program holds xmm0 to xmm15.

TEST_OUTPUT_EXTENDED_STATE :: BUILD_FOLDER + "/test_output_extended_state.txt"

@(rodata)
scenario_extended_state_with_each_feature := [?]Step {
	{kind = .Wait, text = "kernel: extended state: x87, SSE, AVX"},
	{kind = .Wait, text = "compositor: surface console"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "start(\"extended_state\")"},
	{kind = .Wait, text = "extended_state: the kernel saves x87, SSE, AVX"},
	{kind = .Wait, text = "extended_state: the usable instruction sets: SSE, SSE2"},
	{kind = .Wait, text = "extended_state: an empty kernel entry, 100000 times: "},
	{kind = .Wait, text = "extended_state: ok, "},
	{kind = .Front, text = "extended_state"},
	{kind = .Shot, text = "extended_state"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "shutdown()"},
	{kind = .Wait, text = "kernel: the machine stops with code 0"},
}

@(rodata)
scenario_extended_state_without_avx := [?]Step {
	{kind = .Wait, text = "kernel: extended state: x87, SSE, 576 bytes for each thread, saved with xsaveopt"},
	{kind = .Wait, text = "compositor: surface console"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "start(\"extended_state\")"},
	{kind = .Wait, text = "extended_state: the kernel saves x87, SSE; 576 bytes for each thread"},
	{kind = .Wait, text = "extended_state: AVX is not usable: the processor does not have it or the kernel does not save it; the test holds xmm0 to xmm15"},
	{kind = .Wait, text = "kernel entries in the passes: each thread kept xmm0 to xmm15, the x87 stack, the x87 control word and MXCSR, and started with the start state"},
	{kind = .Front, text = "extended_state"},
	{kind = .Shot, text = "extended_state_without_avx"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "shutdown()"},
	{kind = .Wait, text = "kernel: the machine stops with code 0"},
}

@(rodata)
scenario_extended_state_without_xsave := [?]Step {
	{kind = .Wait, text = "kernel: extended state: x87, SSE, 512 bytes for each thread, saved with fxsave: the processor has no xsave or no xsaveopt"},
	{kind = .Wait, text = "compositor: surface console"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "start(\"extended_state\")"},
	{kind = .Wait, text = "extended_state: the kernel saves x87, SSE; 512 bytes for each thread"},
	{kind = .Wait, text = "extended_state: AVX is not usable: "},
	{kind = .Wait, text = "kernel entries in the passes: each thread kept xmm0 to xmm15, the x87 stack, the x87 control word and MXCSR, and started with the start state"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "shutdown()"},
	{kind = .Wait, text = "kernel: the machine stops with code 0"},
}

extended_state_tests_run :: proc() -> bool {
	return machine_test(scenario_extended_state_with_each_feature[:], BOOT_VOLUME, TEST_OUTPUT_EXTENDED_STATE, MACHINE_STOP_OK, TEST_DATA_DISK) && machine_test(scenario_extended_state_without_avx[:], BOOT_VOLUME, TEST_OUTPUT_EXTENDED_STATE, MACHINE_STOP_OK, TEST_DATA_DISK, processor = .Without_Avx) && machine_test(scenario_extended_state_without_xsave[:], BOOT_VOLUME, TEST_OUTPUT_EXTENDED_STATE, MACHINE_STOP_OK, TEST_DATA_DISK, processor = .Without_Xsave)
}
