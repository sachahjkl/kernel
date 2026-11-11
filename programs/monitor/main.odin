// A system tool: the memory of the machine and the programs that run, as a
// picture that changes twice per second. It needs the grant to inspect the machine.
//
// It is also a service: programs(), counts() and count() give the same
// facts as tables of records (exports.odin).
package monitor

import "support:display"
import "support:graphics"
import "support:interface"
import op "contract:operation"
import "support:system"

// The window is built with the interface package (docs/INTERFACE.md).
records_now, records_before: [512]interface.Draw_Record
text_now, text_before: [8192]u8
drawing: interface.Window_Drawing

WIDTH :: 440
HEIGHT :: 350
INTERVAL :: 500
LINE :: 20
BAR_X :: 190
PAGES_X :: 122
BAR_WIDTH :: 190
COLOR_BAR :: 0x48B0E0

PROGRAM_SLOTS :: 64

previous_run_time: [PROGRAM_SLOTS]u64

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	window, ok := display.open(ctx, WIDTH, HEIGHT, "monitor")
	if !ok {
		system.stop(1)
	}
	machine = ctx.handles[system.GRANT_MACHINE]
	service, _ = system.service_open(ctx)
	previous_time: u64
	logged := false
	lost := false
	for {
		report: op.System_Report
		_, status := system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.System), 0, u64(uintptr(&report)), size_of(report))
		if drawing.now.records == nil {
			drawing = interface.window_drawing_of(records_now[:], records_before[:], text_now[:], text_before[:])
		}
		frame := interface.window_frame_begin(&drawing, &window)
		table := frame.table
		interface.draw_rectangle(table, 0, 0, WIDTH, HEIGHT, graphics.COLOR_BACKGROUND)
		if status != .Ok {
			interface.draw_text(table, 10, 10, "no grant to inspect the machine", graphics.COLOR_TEXT)
			if !lost {
				system.log("monitor: no grant to inspect the machine")
				lost = true
			}
		} else {
			elapsed := max(report.time - previous_time, 1)
			previous_time = report.time
			used := report.page_count - report.free_pages

			y := 10
			x := interface.draw_text(table, 10, y, "memory ", graphics.COLOR_DIM)
			x = interface.draw_unsigned(table, x, y, used * system.PAGE_SIZE >> 20, graphics.COLOR_TEXT)
			x = interface.draw_text(table, x, y, " / ", graphics.COLOR_TEXT)
			x = interface.draw_unsigned(table, x, y, report.page_count * system.PAGE_SIZE >> 20, graphics.COLOR_TEXT)
			x = interface.draw_text(table, x, y, " MiB, reserved ", graphics.COLOR_TEXT)
			x = interface.draw_unsigned(table, x, y, report.reserved_pages * system.PAGE_SIZE >> 20, graphics.COLOR_TEXT)
			interface.draw_text(table, x, y, " MiB", graphics.COLOR_TEXT)
			y += LINE
			interface.draw_rectangle(table, 10, y, WIDTH - 20, 10, graphics.COLOR_TRACK)
			interface.draw_rectangle(table, 10, y, int(u64(WIDTH - 20) * used / max(report.page_count, 1)), 10, COLOR_BAR)
			y += LINE
			x = interface.draw_text(table, 10, y, "kernel entries ", graphics.COLOR_DIM)
			interface.draw_unsigned(table, x, y, report.entries, graphics.COLOR_TEXT)
			y += LINE
			x = interface.draw_text(table, 10, y, "interrupts ", graphics.COLOR_DIM)
			interface.draw_unsigned(table, x, y, report.interrupts, graphics.COLOR_TEXT)
			y += LINE
			// The locks of the kernel: the waits of all kinds, and the kind
			// that waited most.
			takes, waits, most: u64
			most_kind: op.Lock_Kind
			for kind in op.Lock_Kind {
				count := report.locks[kind]
				takes += count.takes
				waits += count.waits
				if count.waits > most {
					most, most_kind = count.waits, kind
				}
			}
			x = interface.draw_text(table, 10, y, "kernel locks ", graphics.COLOR_DIM)
			x = interface.draw_unsigned(table, x, y, waits, graphics.COLOR_TEXT)
			x = interface.draw_text(table, x, y, " waits of ", graphics.COLOR_DIM)
			x = interface.draw_unsigned(table, x, y, takes, graphics.COLOR_TEXT)
			if most != 0 {
				x = interface.draw_text(table, x, y, ", most: ", graphics.COLOR_DIM)
				interface.draw_text(table, x, y, op.LOCK_KIND_NAMES[most_kind], graphics.COLOR_TEXT)
			}
			y += LINE + 6
			interface.draw_text(table, 10, y, "program       pages", graphics.COLOR_DIM)
			interface.draw_text(table, BAR_X, y, "processor", graphics.COLOR_DIM)
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
				interface.draw_text(table, 10, y, system.name_of(program.name[:]), graphics.COLOR_TEXT)
				interface.draw_unsigned(table, PAGES_X, y, program.present_pages, graphics.COLOR_TEXT)
				interface.draw_rectangle(table, BAR_X, y + 2, BAR_WIDTH, 10, graphics.COLOR_TRACK)
				interface.draw_rectangle(table, BAR_X, y + 2, int(share) * BAR_WIDTH / 100, 10, COLOR_BAR)
				x = interface.draw_unsigned(table, BAR_X + BAR_WIDTH + 8, y, share, graphics.COLOR_TEXT)
				interface.draw_text(table, x, y, "%", graphics.COLOR_TEXT)
				y += LINE
			}
		}
		interface.window_frame_end(&drawing, &frame, &window)
		pictures += 1
		if !logged {
			system.log("monitor: ok")
			logged = true
		}
		for _ in display.next_event(&window) {}
		// The calls run while the monitor waits for its next picture.
		next := system.time() + INTERVAL
		for {
			wait: system.Wait
			display.wait_events(&wait, &window)
			system.service_wait(&wait, &service)
			now := system.wait_end(&wait, next)
			system.service_run(&service)
			for _ in display.next_event(&window) {}
			if now >= next {
				break
			}
		}
	}
}
