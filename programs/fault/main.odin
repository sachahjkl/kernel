// A program that writes to an address that it does not have. It shows that
// the kernel stops this program only: the rest of the system continues.
package fault

import "support:system"
import "base:intrinsics"

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	system.log("fault: this program writes to address 0")
	address := uintptr(ctx.values[len(ctx.values) - 1]) // 0; the compiler cannot know it.
	intrinsics.volatile_store((^u64)(address), 1)
	system.log("fault: the write did not stop the program")
	system.stop(1)
}
