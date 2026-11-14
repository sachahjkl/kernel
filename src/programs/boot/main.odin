// A system tool: how the machine started, at any time. It draws the boot
// display (package bootscreen) in a window, with the records that the
// kernel has now. It needs the grant to inspect the machine, and the boot
// image.
//
// **What it is for.** The [boot display](term:boot-display) is on the
// screen only while the machine starts; the compositor then takes the
// screen. This program shows the same picture again, in a window, at any
// time: the [stages](term:stage) of the start with their times, the memory
// ranges of the firmware, the processors, the files of the
// [boot image](term:boot-image) and the check of their hashes, and the
// programs that run. A reader who looks for the cause of a slow or odd
// start reads it here, after the start.
//
// **What a reader sees.** Start it from the menu of the programs, or with
// `start("boot")` in the console. The window is the boot display at its
// full size (`bootscreen.WIDTH` by `bootscreen.HEIGHT`), with the message
// "the desktop runs". It draws again each 500 ms, with the records of the
// kernel of that time. At its first draw it writes `boot: ok, <count>
// stages, <count> memory ranges, <count> programs` on the log.
//
// **Its grants**: **Inspect**, the machine handle that reads the
// [boot record](term:boot-record) and the other reports of the kernel
// (`src/library/support/bootscreen/collect`), and **Image**, the boot image, read-only,
// for the names and the kinds of its files. It changes nothing.
//
// **What it shows of the design.** One picture, three programs: the boot
// program, the root service and this program draw the same record
// (`bootscreen.Data`) with the same package; the kernel draws nothing. The
// rules of the picture are in docs/DESIGN.md.
package boot

import "modus:support/bootscreen"
import "modus:support/bootscreen/collect"
import "modus:support/display"
import "modus:support/system"

INTERVAL :: 500

data: bootscreen.Data

// entry opens the window of the boot display and draws it again each
// 500 ms, until the program is stopped.
//
// It maps the boot image when the grant gives it. Each turn reads the records of
// the kernel (`collect.data`), draws the display into the window, and
// presents it. The first turn writes `boot: ok, ...` on the log. The
// events of the window are read and dropped: the window takes no input.
// With no window, the program stops with the code 1.
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
