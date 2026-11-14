// A test module with one export. It uses the three things that a loader must
// get right: addresses in data (rebases), constant data, and private data
// that the module writes.
//
// **What it is for.** It is the callee of the first test of the loader,
// which runs on the host with no machine: the kernel tool loads it and
// test_caller with the loader of the system and calls the entry of
// test_caller (`test_modules` in `tools/kerneltool/modules.odin`). A wrong
// rebase gives a wrong address in `operations`, a wrong data segment gives
// a wrong count: either changes the result.
//
// It is not in the boot image. The module lonely imports it, to show a
// load that fails for a missing import.
package test_callee

double :: proc "c" (x: i64) -> i64 {return x * 2}
triple :: proc "c" (x: i64) -> i64 {return x * 3}

operations := [2]proc "c" (x: i64) -> i64{double, triple}
calls: i64

// apply gives `operations[operation](x)`, plus the number of calls so far.
//
// - **operation**: 0 doubles, 1 triples; only its lowest bit counts.
// - **x**: the integer.
//
// The count of calls includes this call, so the first call of apply(0, 10) gives 21.
@(export, link_name = "apply")
apply :: proc "c" (operation, x: i64) -> i64 {
	calls += 1
	return operations[operation & 1](x) + calls
}
