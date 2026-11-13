package kerneltool

// The large objects of a store (docs/STORAGE.md, "Large objects"): the
// program `ranges` makes an object of 8 GiB from three range writes, makes
// 1000 small writes at scrambled offsets and one commit, and checks that the
// commit hashed and wrote what the writes touched, not the object; then a
// version, a cut, an extension, the refusals, and a loop of range commits.
// A second machine starts on the same disk: the open of the disk walks each
// block tree again, and `ranges` reads back what the first run left. The
// counts of a commit and the times are measures in the lines; the scenario
// waits for the parts that do not depend on the machine.

TEST_RANGES_DISK :: BUILD_FOLDER + "/test_ranges_disk.img"
TEST_OUTPUT_RANGES :: BUILD_FOLDER + "/test_output_ranges_%d.txt"

scenario_ranges_first := [?]Step {
	{kind = .Wait, text = "compositor: surface console"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "start(\"ranges\")"},
	{kind = .Wait, text = "ranges: a new store: the first run", any_order = true},
	{kind = .Wait, text = "ranges: three range writes are pending, and the size of the object is 8589934592 bytes: as it must"},
	{kind = .Wait, text = "ranges: the commit of the sparse object: 3 blocks changed of 2097152, "},
	{kind = .Wait, text = "ranges: a sparse object of 8 GiB from 3 writes and one commit holds 13 blocks: as it must"},
	{kind = .Wait, text = "ranges: its three blocks read back, a hole reads as zero bytes, and a read across a block edge gives the end of a block and zero bytes: as it must"},
	{kind = .Wait, text = "ranges: 1000 range writes at scrambled offsets are pending, in "},
	{kind = .Wait, text = "ranges: 1000 writes at scrambled offsets, then one commit: 1000 blocks changed of 2097152, "},
	// The counts of the hash are in the line: a measure. The case checks
	// that they are bounded by the blocks changed.
	{kind = .Wait, text = " object nodes, bounded by the blocks changed, not by the 2097152 blocks of the object: as it must"},
	{kind = .Wait, text = "ranges: the 1000 writes read back, each one byte for byte, and the three blocks before them: as it must"},
	{kind = .Wait, text = "ranges: the version before the 1000 writes holds 4 blocks of its own: the root and the path of the first block; its other blocks are shared with the new state: as it must"},
	{kind = .Wait, text = "ranges: an old version reads its old bytes after a range write, and compare gives the one range written: as it must"},
	{kind = .Wait, text = "ranges: a cut of an object of 70 blocks to 6000 bytes holds 3 blocks; an extension to 1 GiB holds 5 blocks, and reads zero bytes past the cut: as it must"},
	{kind = .Wait, text = "ranges: a read at the end gives no byte, and a read past the end is refused: as it must"},
	{kind = .Wait, text = "ranges: a place of another store, a place of no connection, and a commit with no pending change are refused: as it must"},
	{kind = .Wait, text = "ranges: a commit after another change of the object is refused, and its pending changes are dropped: as it must"},
	{kind = .Wait, text = "ranges: loop, 50 commits of 4 range writes, in "},
	{kind = .Wait, text = "ranges: loop, 100 commits of 4 range writes, in "},
	{kind = .Wait, text = "ranges: loop, 150 commits of 4 range writes, in "},
	{kind = .Wait, text = "ranges: loop, 200 commits of 4 range writes, in "},
	{kind = .Wait, text = "ranges: the loop made 200 commits of range writes: as it must"},
	{kind = .Wait, text = "ranges: done, 0 wrong"},
	{kind = .Wait, text = "root: ranges stopped with code 0"},
	{kind = .Type, text = "shutdown()"},
	{kind = .Wait, text = "kernel: the machine stops with code 0"},
}

scenario_ranges_second := [?]Step {
	{kind = .Wait, text = "storage: ok, generation ", any_order = true},
	{kind = .Wait, text = "compositor: surface console"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "start(\"ranges\")"},
	{kind = .Wait, text = "ranges: a store with 4 objects: the run after the remount"},
	{kind = .Wait, text = "ranges: after the remount: the sparse object of 8589934592 bytes reads its 3 blocks and its 1000 writes, byte for byte: as it must"},
	{kind = .Wait, text = "ranges: after the remount: the small object, the object of the cut and the object of the loop: as it must"},
	{kind = .Wait, text = "ranges: done, 0 wrong"},
	{kind = .Type, text = "shutdown()"},
	{kind = .Wait, text = "kernel: the machine stops with code 0"},
}

ranges_tests_run :: proc() -> bool {
	disk_prepare(TEST_RANGES_DISK, DATA_DISK_SIZE, true) or_return
	machine_test(scenario_ranges_first[:], BOOT_VOLUME, self_test_file(TEST_OUTPUT_RANGES, 1), MACHINE_STOP_OK, TEST_RANGES_DISK) or_return
	return machine_test(scenario_ranges_second[:], BOOT_VOLUME, self_test_file(TEST_OUTPUT_RANGES, 2), MACHINE_STOP_OK, TEST_RANGES_DISK)
}
