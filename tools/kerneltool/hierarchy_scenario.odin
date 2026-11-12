package kerneltool

// The trees of a store (docs/STORAGE.md): the program `hierarchy` makes
// 100000 objects in trees inside trees, lists them in pages, renames,
// removes a tree, and checks that a share reaches nothing outside its tree.
// A second machine starts on the same disk: the open of the disk walks
// every tree again, and `hierarchy` checks the counts and the contents.

TEST_HIERARCHY_DISK :: BUILD_FOLDER + "/test_hierarchy_disk.img"
TEST_OUTPUT_HIERARCHY :: BUILD_FOLDER + "/test_output_hierarchy_%d.txt"

scenario_hierarchy_first := [?]Step {
	{kind = .Wait, text = "compositor: surface console"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "start(\"hierarchy\")"},
	{kind = .Wait, text = "hierarchy: a new store: the first run", any_order = true},
	// One line for each 10000 objects: each wait has the hang bound.
	{kind = .Wait, text = "hierarchy: 10000 objects made in "},
	{kind = .Wait, text = "hierarchy: 20000 objects made in "},
	{kind = .Wait, text = "hierarchy: 30000 objects made in "},
	{kind = .Wait, text = "hierarchy: 40000 objects made in "},
	{kind = .Wait, text = "hierarchy: 50000 objects made in "},
	{kind = .Wait, text = "hierarchy: 60000 objects made in "},
	{kind = .Wait, text = "hierarchy: 70000 objects made in "},
	{kind = .Wait, text = "hierarchy: 80000 objects made in "},
	{kind = .Wait, text = "hierarchy: 90000 objects made in "},
	{kind = .Wait, text = "hierarchy: 100000 objects made in "},
	{kind = .Wait, text = "hierarchy: made 100100 objects and 1100 trees in 1201 commits, in "},
	{kind = .Wait, text = "hierarchy: the root in pages of 16: 100 trees, in order: as it must"},
	{kind = .Wait, text = "hierarchy: listed 100000 objects in 1000 trees in pages of 16, each page after the one before, in "},
	{kind = .Wait, text = "hierarchy: rename of an object to the root: the part has 99 objects: as it must"},
	{kind = .Wait, text = "hierarchy: rename of a tree of 10 trees and 1000 objects: one commit: as it must"},
	{kind = .Wait, text = "hierarchy: a tree cannot move inside itself: as it must"},
	{kind = .Wait, text = "hierarchy: a rename onto a name that exists is refused: as it must"},
	// The service can run a step of the removal before the next call: the
	// count of the trees that wait is a measure.
	{kind = .Wait, text = "hierarchy: remove of a tree: the name is gone at its commit; "},
	{kind = .Wait, text = "hierarchy: the removal freed 1001 objects, 11 trees and "},
	// Names in a scrambled order: splits and merges in the middle of
	// leaves and branches.
	{kind = .Wait, text = "hierarchy: added 6000 names in a scrambled order in 24 commits, listed in order, each read back; removed 3000 in another order, 3000 left in order, in "},
	{kind = .Wait, text = "hierarchy: a read-only share of tree_003: as it must"},
	{kind = .Wait, text = "hierarchy: the share lists the 10 trees of tree_003 only: as it must"},
	{kind = .Wait, text = "hierarchy: the name \"..\" is refused: as it must"},
	{kind = .Wait, text = "hierarchy: the name \".\" is refused: as it must"},
	{kind = .Wait, text = "hierarchy: the name \"/tree_004\" is refused: as it must"},
	{kind = .Wait, text = "hierarchy: the name \"part_000/../..\" is refused: as it must"},
	{kind = .Wait, text = "hierarchy: the name \"../tree_004\" is refused: as it must"},
	{kind = .Wait, text = "hierarchy: a place of another connection names nothing on the share: as it must"},
	{kind = .Wait, text = "hierarchy: a name of another store is refused: as it must"},
	{kind = .Wait, text = "hierarchy: the read-only share cannot write: as it must"},
	{kind = .Wait, text = "hierarchy: the read-only share cannot remove: as it must"},
	{kind = .Wait, text = "hierarchy: after unshare, the handles of the share are revoked: a call gives Gone: as it must"},
	{kind = .Wait, text = "hierarchy: a writable share writes in tree_005, and the maker reads it: as it must"},
	{kind = .Wait, text = "hierarchy: the first run leaves 102100 objects and 1090 trees: as it must"},
	{kind = .Wait, text = "hierarchy: done, 0 wrong"},
	{kind = .Wait, text = "root: hierarchy stopped with code 0"},
	{kind = .Type, text = "shutdown()"},
	{kind = .Wait, text = "kernel: the machine stops with code 0"},
}

scenario_hierarchy_second := [?]Step {
	{kind = .Wait, text = "storage: ok, generation ", any_order = true},
	{kind = .Wait, text = "compositor: surface console"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "start(\"hierarchy\")"},
	{kind = .Wait, text = "hierarchy: a store with 102100 objects: the run after the remount"},
	{kind = .Wait, text = "hierarchy: after the remount: 102100 objects and 1090 trees: as it must"},
	{kind = .Wait, text = "hierarchy: after the remount: 3000 scrambled names left, in order: as it must"},
	{kind = .Wait, text = "hierarchy: after the remount: 97999 objects listed in the parts, 98 contents byte for byte, the renamed tree and object in their places, in "},
	{kind = .Wait, text = "hierarchy: done, 0 wrong"},
	{kind = .Type, text = "shutdown()"},
	{kind = .Wait, text = "kernel: the machine stops with code 0"},
}

hierarchy_tests_run :: proc() -> bool {
	disk_prepare(TEST_HIERARCHY_DISK, DATA_DISK_SIZE, true) or_return
	machine_test(scenario_hierarchy_first[:], BOOT_VOLUME, self_test_file(TEST_OUTPUT_HIERARCHY, 1), MACHINE_STOP_OK, TEST_HIERARCHY_DISK) or_return
	return machine_test(scenario_hierarchy_second[:], BOOT_VOLUME, self_test_file(TEST_OUTPUT_HIERARCHY, 2), MACHINE_STOP_OK, TEST_HIERARCHY_DISK)
}
