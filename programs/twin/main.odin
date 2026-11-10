// A program that the program `frames` starts several times, to show the
// shared code of a module and a page that two programs share (package
// support:twins). The value MODE of its context says what it does.
package twin

import "base:intrinsics"
import "support:system"
import "support:twins"

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
