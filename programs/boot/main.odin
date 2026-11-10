// A system tool: how the machine started, at any time. It draws the boot
// display (package bootscreen) in a window, with the records that the
// kernel has now. It needs the grant to inspect the machine, and the boot
// image.
package boot

import "support:bootscreen"
import "support:bootscreen/collect"
import "support:display"
import "support:system"

INTERVAL :: 500

data: bootscreen.Data

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	window, ok := display.open(ctx, bootscreen.WIDTH, bootscreen.HEIGHT, "boot")
	if !ok {
		system.stop(1)
	}
	machine := ctx.handles[system.GRANT_MACHINE]
	if address, status := system.memory_map(ctx.handles[system.GRANT_IMAGE], {}); status == .Ok {
		data.image = ([^]u8)(address)[:ctx.values[system.GRANT_VALUE_IMAGE_SIZE]]
	}
	data.message = "the desktop runs"
	data.state = .Ready
	logged := false
	for {
		collect.data(&data, machine)
		bootscreen.draw(window.canvas, &data)
		display.present(&window)
		if !logged {
			logged = true
			system.log("boot: ok, ", data.boot.stage_count, " stages, ", data.boot.range_count, " memory ranges, ", u64(data.program_total), " programs")
		}
		for _ in display.next_event(&window) {}
		system.sleep(system.time() + INTERVAL)
	}
}
