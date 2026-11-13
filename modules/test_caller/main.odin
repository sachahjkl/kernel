// A test module that imports test_callee and has the entry.
//
// **What it is for.** It is the caller of the first test of the loader, on
// the host (`test_modules` in `tools/kerneltool/modules.odin`): its entry
// calls test_callee through an import slot, so the test checks the import
// and the rebases of both modules in one number. It is not in the boot
// image, and its entry is not the entry of a program: it returns a value.
package test_caller

foreign _ {
	apply :: proc "c" (operation, x: i64) -> i64 ---
}

// The entry of test_caller: two calls of apply through the import slot.
// The kernel tool expects this value: (10 * 3 + 1) + (10 * 2 + 2), so 53.
// The first call is the first of the module: its count adds 1, the second
// adds 2.
@(export, link_name = "entry")
entry :: proc "c" (context_address: rawptr) -> i64 {
	return apply(1, 10) + apply(0, 10)
}
