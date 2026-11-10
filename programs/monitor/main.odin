// A system tool: the memory of the machine and the programs that run, as a
// picture that changes twice per second. It needs the grant to inspect the machine.
package monitor

import "../../display"
import "../../graphics"
import op "../../kernel/operation"
import "../../system"

WIDTH :: 440
HEIGHT :: 330
INTERVAL :: 500
LINE :: 20
BAR_X :: 190
PAGES_X :: 122
BAR_WIDTH :: 190
COLOR_BACKGROUND :: 0x14181E
COLOR_TEXT :: 0xD8E0E8
COLOR_DIM :: 0x8090A0
COLOR_BAR_BACK :: 0x283038
COLOR_BAR :: 0x48B0E0

PROGRAM_SLOTS :: 64

previous_run_time: [PROGRAM_SLOTS]u64

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	window, ok := display.open(ctx, WIDTH, HEIGHT, "monitor")
	if !ok {
		system.stop(1)
	}
	canvas := window.canvas
	machine := ctx.handles[system.GRANT_MACHINE]
	previous_time: u64
	logged := false
	for {
		report: op.System_Report
		_, status := system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.System), 0, u64(uintptr(&report)), size_of(report))
		graphics.clear(canvas, COLOR_BACKGROUND)
		if status != .Ok {
			graphics.text(canvas, 10, 10, "no grant to inspect the machine", COLOR_TEXT)
		} else {
			elapsed := max(report.time - previous_time, 1)
			previous_time = report.time
			used := report.page_count - report.free_pages

			y := 10
			x := graphics.text(canvas, 10, y, "memory ", COLOR_DIM)
			x = graphics.unsigned(canvas, x, y, used * system.PAGE_SIZE >> 20, COLOR_TEXT)
			x = graphics.text(canvas, x, y, " / ", COLOR_TEXT)
			x = graphics.unsigned(canvas, x, y, report.page_count * system.PAGE_SIZE >> 20, COLOR_TEXT)
			graphics.text(canvas, x, y, " MiB", COLOR_TEXT)
			y += LINE
			graphics.fill(canvas, 10, y, WIDTH - 20, 10, COLOR_BAR_BACK)
			graphics.fill(canvas, 10, y, int(u64(WIDTH - 20) * used / max(report.page_count, 1)), 10, COLOR_BAR)
			y += LINE
			x = graphics.text(canvas, 10, y, "kernel entries ", COLOR_DIM)
			graphics.unsigned(canvas, x, y, report.entries, COLOR_TEXT)
			y += LINE
			x = graphics.text(canvas, 10, y, "interrupts ", COLOR_DIM)
			graphics.unsigned(canvas, x, y, report.interrupts, COLOR_TEXT)
			y += LINE + 6
			graphics.text(canvas, 10, y, "program       pages", COLOR_DIM)
			graphics.text(canvas, BAR_X, y, "processor", COLOR_DIM)
			y += LINE

			for slot in 1 ..< min(report.program_slots, PROGRAM_SLOTS) {
				program: op.Program_Report
				system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.Program), slot, u64(uintptr(&program)), size_of(program))
				if program.state == .None {
					previous_run_time[slot] = 0
					continue
				}
				share := min((program.run_time - min(previous_run_time[slot], program.run_time)) * 100 / elapsed, 100)
				previous_run_time[slot] = program.run_time
				graphics.text(canvas, 10, y, system.name_of(program.name[:]), COLOR_TEXT)
				graphics.unsigned(canvas, PAGES_X, y, program.mapped_pages, COLOR_TEXT)
				graphics.fill(canvas, BAR_X, y + 2, BAR_WIDTH, 10, COLOR_BAR_BACK)
				graphics.fill(canvas, BAR_X, y + 2, int(share) * BAR_WIDTH / 100, 10, COLOR_BAR)
				x = graphics.unsigned(canvas, BAR_X + BAR_WIDTH + 8, y, share, COLOR_TEXT)
				graphics.text(canvas, x, y, "%", COLOR_TEXT)
				y += LINE
			}
		}
		display.present(&window)
		if !logged {
			system.log("monitor: ok")
			logged = true
		}
		for _ in display.next_event(&window) {}
		system.sleep(system.time() + INTERVAL)
	}
}
