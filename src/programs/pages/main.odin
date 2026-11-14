// A system tool: what the page tables give, as the kernel reads it from
// the tables themselves.
//
// The top part is the kernel half of the addresses: the direct map, the
// kernel module, and the kernel stacks between their guard pages. The
// bottom part is the half of this program. Each line is a run of pages
// with one protection. No page is both writable and executable.
//
// The program needs the grant to inspect the machine.
//
// **What it is for.** It shows two rules of the memory of the system as the
// processor sees them, not as a document claims them: no page is both
// writable and executable, and each kernel stack has a guard page on each
// side. It also shows whether the processor keeps the kernel out of the
// memory of programs (no execution of it, and no access outside a copy).
//
// **Start**: `start("pages")` in the console, or the bar of the desktop.
//
// **Grants**, as the root service gives them:
//
// - **Inspect**: the machine with the right Inspect, for the report
//   `Inspect_Kind.Mappings` of the kernel half and of the half of this
//   program. The kernel walks the page tables themselves to make it.
//
// **What a reader sees**: the two halves as runs of pages, each with its
// protection, and the rules with a mark each. The log has, once:
//
// - the pages, the runs, the pages that are write and execute, and the
//   guard pages of the kernel half;
// - the same counts for this program;
// - "pages: ok, the page tables keep the rules", or "pages: failed, ...";
// - whether the processor refuses the memory of programs to the kernel.
//
// **What it does not prove**: it reads the tables of one program, its own.
// It shows the state at one moment, every 500 ms; it does not watch each
// change of a mapping.
package pages

import info "modus:contract/boot_info"
import "modus:support/display"
import "modus:support/graphics"
import op "modus:contract/operation"
import "modus:support/system"

WIDTH :: 688
HEIGHT :: 668
MARGIN :: 12
LINE :: 16
KERNEL_ROWS :: 22
PROGRAM_ROWS :: 10
INTERVAL :: 500

COLOR_PANEL :: 0x131B26
COLOR_EXECUTE :: 0x4A9CF0
COLOR_WRITE :: 0xE0A040
COLOR_READ :: 0x58D878
COLOR_GUARD :: 0xF06060

kernel_half: op.Mapping_Report
program_half: op.Mapping_Report

Text :: struct {
	bytes: [96]u8,
	count: int,
}

put :: proc "contextless" (text: ^Text, part: string) {
	for index in 0 ..< len(part) {
		if text.count < len(text.bytes) {
			text.bytes[text.count] = part[index]
			text.count += 1
		}
	}
}

put_number :: proc "contextless" (text: ^Text, value: u64) {
	digits: [20]u8
	count := 0
	for rest := value; rest != 0 || count == 0; rest /= 10 {
		digits[count] = '0' + u8(rest % 10)
		count += 1
	}
	for count > 0 {
		count -= 1
		put(text, string(digits[count:][:1]))
	}
}

put_hex :: proc "contextless" (text: ^Text, value: u64) {
	characters := "0123456789abcdef"
	for index := 15; index >= 0; index -= 1 {
		put(text, characters[value >> (uint(index) * 4) & 15:][:1])
	}
}

// put_size adds a count of pages as a size, in 9 characters.
put_size :: proc "contextless" (text: ^Text, page_count: u64) {
	start := text.count
	kib := page_count * 4
	switch {
	case kib < 1024:
		put_number(text, kib)
		put(text, " KiB")
	case kib < 1024 * 1024:
		put_number(text, kib >> 10)
		put(text, ".")
		put_number(text, (kib & 1023) * 10 >> 10)
		put(text, " MiB")
	case:
		put_number(text, kib >> 20)
		put(text, ".")
		put_number(text, (kib & (1 << 20 - 1)) * 10 >> 20)
		put(text, " GiB")
	}
	for text.count < start + 9 {
		put(text, " ")
	}
}

show :: proc "contextless" (canvas: graphics.Canvas, x, y: int, text: ^Text, color: graphics.Color) -> int {
	after := graphics.text(canvas, x, y, string(text.bytes[:text.count]), color)
	text.count = 0
	return after
}

// part says which part of the kernel half holds an address.
part :: proc "contextless" (text: ^Text, address: u64) {
	slot_size :: u64(op.KERNEL_STACK_SLOT_PAGES * info.PAGE_SIZE)
	switch {
	case address >= u64(info.KERNEL_BASE):
		put(text, "kernel module")
	case address >= op.KERNEL_STACK_BASE:
		page := (address - op.KERNEL_STACK_BASE) % slot_size / info.PAGE_SIZE
		switch page {
		case 1:
			put(text, "stack of processor ")
		case 2 + op.KERNEL_STACK_PAGES:
			put(text, "double fault stack of processor ")
		case:
			put(text, "interrupt stack of processor ")
		}
		put_number(text, (address - op.KERNEL_STACK_BASE) / slot_size)
	case address >= u64(info.DIRECT_MAP_BASE):
		put(text, "direct map")
	}
}

// half draws the runs of one report from line `line`, and gives the next line.
half :: proc "contextless" (canvas: graphics.Canvas, line: int, title: string, report: ^op.Mapping_Report, rows: int, kernel: bool) -> int {
	line := line
	text: Text
	y := MARGIN + line * LINE
	graphics.fill(canvas, MARGIN, y, WIDTH - 2 * MARGIN, 2, kernel ? COLOR_EXECUTE : COLOR_READ)
	x := graphics.text(canvas, MARGIN, y + 6, title, kernel ? COLOR_EXECUTE : COLOR_READ)
	put(&text, "  ")
	put_number(&text, report.pages)
	put(&text, " pages, ")
	put_number(&text, report.execute_pages)
	put(&text, " of code, ")
	put_number(&text, report.run_count)
	put(&text, " runs")
	show(canvas, x, y + 6, &text, graphics.COLOR_DIM)
	line += 2
	shown := min(int(report.run_count), rows, op.MAPPING_RUN_CAPACITY)
	for run, index in report.runs[:shown] {
		y = MARGIN + line * LINE
		color: graphics.Color = COLOR_READ
		switch {
		case .Execute in run.flags:
			color = COLOR_EXECUTE
		case .Write in run.flags:
			color = COLOR_WRITE
		}
		// A place with no page before a kernel stack is a guard.
		if kernel && run.start >= op.KERNEL_STACK_BASE && run.start < u64(info.KERNEL_BASE) {
			graphics.fill(canvas, MARGIN, y, 8, 3, COLOR_GUARD)
			if index + 1 == shown || report.runs[index + 1].start >= u64(info.KERNEL_BASE) {
				graphics.fill(canvas, MARGIN, y + LINE - 3, 8, 3, COLOR_GUARD)
			}
		}
		graphics.fill(canvas, MARGIN, y + 4, 8, 8, color)
		put_hex(&text, run.start)
		put(&text, "  ")
		put_size(&text, run.page_count)
		x = show(canvas, MARGIN + 16, y, &text, graphics.COLOR_TEXT)
		put(&text, " read")
		if .Write in run.flags {
			put(&text, " write")
		}
		if .Execute in run.flags {
			put(&text, " execute")
		}
		if .Large in run.flags {
			put(&text, ", 2 MiB pages")
		}
		show(canvas, x, y, &text, color)
		if kernel {
			part(&text, run.start)
			show(canvas, 464, y, &text, graphics.COLOR_DIM)
		}
		line += 1
	}
	if int(report.run_count) > shown {
		put(&text, "and ")
		put_number(&text, report.run_count - u64(shown))
		put(&text, " more runs")
		show(canvas, MARGIN + 16, MARGIN + line * LINE, &text, graphics.COLOR_DIM)
		line += 1
	}
	return line
}

rule :: proc "contextless" (canvas: graphics.Canvas, line: int, kept: bool, text: ^Text) {
	y := MARGIN + line * LINE
	graphics.fill(canvas, MARGIN, y + 4, 8, 8, kept ? graphics.COLOR_PROGRAM : COLOR_GUARD)
	show(canvas, MARGIN + 16, y, text, kept ? graphics.COLOR_TEXT : COLOR_GUARD)
}

draw :: proc "contextless" (canvas: graphics.Canvas) {
	graphics.clear(canvas, graphics.COLOR_BACKGROUND)
	text: Text
	line := half(canvas, 0, "the kernel half", &kernel_half, KERNEL_ROWS, true)
	line += 1
	put(&text, "write and execute: ")
	put_number(&text, kernel_half.write_execute_pages + program_half.write_execute_pages)
	put(&text, " pages")
	rule(canvas, line, kernel_half.write_execute_pages + program_half.write_execute_pages == 0, &text)
	put(&text, "guard pages around the kernel stacks: ")
	put_number(&text, kernel_half.guard_pages)
	put(&text, " of ")
	put_number(&text, kernel_half.guards_expected)
	rule(canvas, line + 1, kernel_half.guard_pages == kernel_half.guards_expected, &text)
	put(&text, kernel_half.kernel_no_execute != 0 ? "the kernel cannot execute memory of programs" : "the kernel can execute memory of programs: the processor has no guard")
	rule(canvas, line + 2, kernel_half.kernel_no_execute != 0, &text)
	put(&text, kernel_half.kernel_guard != 0 ? "the kernel cannot use memory of programs outside a copy" : "the kernel can use memory of programs: the processor has no guard")
	rule(canvas, line + 3, kernel_half.kernel_guard != 0, &text)
	half(canvas, line + 5, "the half of this program", &program_half, PROGRAM_ROWS, false)
}

// The entry of pages: every 500 ms it reads the two mapping reports and
// draws them, and the first time it writes the result on the log.
//
// With no window it stops with the code 1. It never stops by itself.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	window, ok := display.open(ctx, WIDTH, HEIGHT, "pages")
	if !ok {
		system.stop(1)
	}
	machine := ctx.handles[system.GRANT_MACHINE]
	logged := false
	for {
		system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.Mappings), 0, u64(uintptr(&kernel_half)), size_of(op.Mapping_Report))
		system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.Mappings), 1, u64(uintptr(&program_half)), size_of(op.Mapping_Report))
		draw(window.canvas)
		display.present(&window)
		if !logged {
			logged = true
			system.log("pages: the kernel half: ", kernel_half.pages, " pages in ", kernel_half.run_count, " runs, ", kernel_half.write_execute_pages, " write and execute, ", kernel_half.guard_pages, " guard pages of ", kernel_half.guards_expected)
			system.log("pages: this program: ", program_half.pages, " pages in ", program_half.run_count, " runs, ", program_half.write_execute_pages, " write and execute")
			kept := kernel_half.pages != 0 && program_half.pages != 0 && kernel_half.write_execute_pages == 0 && program_half.write_execute_pages == 0 && kernel_half.guard_pages == kernel_half.guards_expected && kernel_half.guards_expected != 0
			guards := kernel_half.kernel_no_execute != 0 && kernel_half.kernel_guard != 0
			system.log(kept ? "pages: ok, the page tables keep the rules" : "pages: failed, the page tables do not keep the rules")
			system.log(guards ? "pages: the processor refuses the memory of programs to the kernel" : "pages: the processor has no guard for the memory of programs")
		}
		for _ in display.next_event(&window) {}
		system.sleep(system.time() + INTERVAL)
	}
}
