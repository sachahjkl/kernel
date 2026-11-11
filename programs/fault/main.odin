// A program that writes to an address that it does not have. It shows that
// the kernel stops this program only: the rest of the system continues.
//
// The write is three calls deep: the stop report has a stack trace from the
// frame pointers, with the instruction in three and the return addresses in
// two, one and entry (program `errors`).
package fault

import "support:system"
import "base:intrinsics"

depth: u64 // Each function writes it after its call: no call is the last instruction of a function.

three :: #force_no_inline proc "contextless" (address: uintptr) {
	intrinsics.volatile_store((^u64)(address), 1)
	intrinsics.volatile_store(&depth, 3)
}

two :: #force_no_inline proc "contextless" (address: uintptr) {
	three(address)
	intrinsics.volatile_store(&depth, 2)
}

one :: #force_no_inline proc "contextless" (address: uintptr) {
	two(address)
	intrinsics.volatile_store(&depth, 1)
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	system.log("fault: this program writes to address 0")
	// The value 14: 0, as no starter writes it; the compiler cannot know it.
	// (The values 9 to 12 are the random seed of the program, 13 the
	// settings page, 15 the date page, 16 the strength of the seed.)
	address := uintptr(ctx.values[14])
	one(address)
	system.log("fault: the write did not stop the program")
	system.stop(1)
}
