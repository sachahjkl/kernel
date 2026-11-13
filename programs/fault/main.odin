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

// one is the first of the three calls.
one :: #force_no_inline proc "contextless" (address: uintptr) {
	two(address)
	intrinsics.volatile_store(&depth, 1)
}

// entry writes a log line, then writes to address 0 three calls deep.
//
// **What it is for.** It shows the sandbox of a program: a fault ends the
// program that made it, never the machine or another program. The kernel
// writes the [stop report](term:stop-report) of the program (the vector,
// the address, and the frames of its stack), and keeps it while a handle
// names the program, so that a developer tool reads it later.
//
// **What a reader sees.** Start it from the menu of the programs, or with
// `start("fault")` in the console. It has no window and no grant. The log
// gets `fault: this program writes to address 0`, then the line of the
// kernel that reports the page fault (vector 14) and stops the program.
// The desktop goes on. In `inspect`, the stopped program shows its stop
// report, each frame named by its procedure and its source line from the
// debug image. The program `errors` starts it in its fault case, and checks
// that the four frames are all in this module.
//
// **Why the code looks odd.** The address comes from a value of the context
// that no starter writes, so the compiler cannot prove that it is 0 and
// drop the write. Each function writes `depth` after its call, so no call
// is the last instruction of a function: each call keeps its frame and its
// return address, and the stack trace has every level.
//
// If the write ever succeeds, the program writes `fault: the write did not
// stop the program` and stops with the code 1: that line is a fault of the
// kernel.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	system.log("fault: this program writes to address 0")
	// The value 14: 0, as no starter writes it; the compiler cannot know it.
	// (The values 9 to 12 are the random seed of the program, 16 the
	// strength of the seed; 13 and 15 have no role.)
	address := uintptr(ctx.values[14])
	one(address)
	system.log("fault: the write did not stop the program")
	system.stop(1)
}
