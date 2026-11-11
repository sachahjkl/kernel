package kerneltool

// The randomness of the system: three machines (docs/RANDOMNESS.md).
//
// Two machines with each feature of the processor: the root service makes
// the seed of the system from rdseed; two programs `randomness` show two
// streams. The third machine has no rdrand and no rdseed (`-cpu
// max,-rdrand,-rdseed`): the seed comes from the cycle counter only, the
// root service and the window say "weak", and each program still starts.
// The first bytes of the stream of each program, in the three machines,
// all differ: two programs, and a restart, give different streams.

TEST_OUTPUT_RANDOM :: BUILD_FOLDER + "/test_output_random.txt"

scenario_random_with_the_processor := [?]Step {
	{kind = .Wait, text = "root: the random seed of the system, strength entropy (rdseed): rdseed present, 8 good values, 0 refused; rdrand present, 8 good, 0 refused"},
	{kind = .Wait, text = "compositor: surface console"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "start(\"randomness\")"},
	{kind = .Remember, text = "randomness: the seed of the system: strength entropy (rdseed); the first bytes of the stream of this program: "},
	{kind = .Wait, text = "randomness: 1 MiB by the high 4 bits of each byte: from "},
	{kind = .Wait, text = "randomness: the generator: 4 MiB in "},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "start(\"randomness\")"},
	{kind = .Remember, text = "randomness: the seed of the system: strength entropy (rdseed); the first bytes of the stream of this program: "},
	{kind = .Wait, text = "randomness: the generator: 4 MiB in "},
	{kind = .Front, text = "randomness"},
	{kind = .Shot, text = "randomness"},
	{kind = .Distinct, text = "two programs of one machine"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "shutdown()"},
	{kind = .Wait, text = "kernel: the machine stops with code 0"},
}

scenario_random_restart := [?]Step {
	{kind = .Wait, text = "root: the random seed of the system, strength entropy (rdseed)"},
	{kind = .Wait, text = "compositor: surface console"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "start(\"randomness\")"},
	{kind = .Remember, text = "randomness: the seed of the system: strength entropy (rdseed); the first bytes of the stream of this program: "},
	{kind = .Distinct, text = "two programs, then a restart of the machine"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "shutdown()"},
	{kind = .Wait, text = "kernel: the machine stops with code 0"},
}

scenario_random_without_the_processor := [?]Step {
	{kind = .Wait, text = "root: the random seed of the system, strength weak (the cycle counter only): rdseed absent, 0 good values, 0 refused; rdrand absent, 0 good, 0 refused; the cycle counter, 2048 samples, "},
	{kind = .Wait, text = "compositor: surface console"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "start(\"randomness\")"},
	{kind = .Remember, text = "randomness: the seed of the system: strength weak (the cycle counter only); the first bytes of the stream of this program: "},
	{kind = .Wait, text = "randomness: the generator: 4 MiB in "},
	{kind = .Front, text = "randomness"},
	{kind = .Shot, text = "randomness_weak"},
	{kind = .Distinct, text = "three machines, one of them with no rdrand and no rdseed"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "shutdown()"},
	{kind = .Wait, text = "kernel: the machine stops with code 0"},
}

random_tests_run :: proc() -> bool {
	clear(&remembered_values)
	return machine_test(scenario_random_with_the_processor[:], BOOT_VOLUME, TEST_OUTPUT_RANDOM, MACHINE_STOP_OK, TEST_DATA_DISK) && machine_test(scenario_random_restart[:], BOOT_VOLUME, TEST_OUTPUT_RANDOM, MACHINE_STOP_OK, TEST_DATA_DISK) && machine_test(scenario_random_without_the_processor[:], BOOT_VOLUME, TEST_OUTPUT_RANDOM, MACHINE_STOP_OK, TEST_DATA_DISK, processor_without_random = true)
}
