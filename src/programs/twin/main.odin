// A program that the program `frames` starts several times, to show the
// shared code of a module and a page that two programs share (package
// modus:support/twins). The value MODE of its context says what it does.
//
// **What it is for.** Two facts of the memory of the system need a second
// program to show them: the code pages of one module are shared between
// the programs that run it, and they cannot be written; and one page that
// two programs map is one frame. `frames` reads its own page table and the
// counts of the kernel while its twins run.
//
// **Start**: only `frames` starts it, from the boot image. It is not named
// in `grants_of`. It has no window and writes nothing on the log.
package twin

import "base:intrinsics"
import "modus:support/system"
import "modus:support/twins"

// The entry of twin: it does what its mode says, then sleeps until
// `frames` stops it.
//
// - `MODE_WRITE_PAGE`: it maps the shared page, writes the agreed word in
//   it, and wakes `frames`, which waits on that word. A page that does not
//   map stops it with the code 1.
// - `MODE_WRITE_CODE`: it writes one byte in its own code. The page has no
//   right Write, so the kernel stops the program as its own fault: the
//   expected result.
// - any other mode: it only sleeps, as one more program that shares the
//   code of the module.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	switch ctx.values[twins.VALUE_MODE] {
	case twins.MODE_WRITE_PAGE:
		// The first use of the page in this program: the page has the frame
		// that the program `frames` took, or it takes it now.
		address, status := system.memory_map(ctx.handles[twins.GRANT_PAGE])
		if status != .Ok {
			system.stop(1)
		}
		word := (^u32)(address)
		intrinsics.volatile_store(word, twins.WORD)
		system.word_wake(word)
	case twins.MODE_WRITE_CODE:
		// The code of this program is the shared code of the module: the
		// page has no Write, and the kernel stops this program.
		intrinsics.volatile_store((^u8)(rawptr(entry)), 0xC3)
	}
	for {
		system.sleep(system.WAIT_FOREVER)
	}
}
