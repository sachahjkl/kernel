// A test module that imports test_callee and has the entry.
package test_caller

foreign _ {
	apply :: proc "c" (operation: u32, x: i64) -> i64 ---
}

// kerneltool test expects this value: (10 * 3 + 1) + (10 * 2 + 2).
@(export, link_name = "entry")
entry :: proc "c" (context_address: rawptr) -> i64 {
	return apply(1, 10) + apply(0, 10)
}
