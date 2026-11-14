// A demonstration of the origin of a handle and of Handle_Revoke: a
// program holds only the handles that it was given, and each grant can be
// revoked with all that came from it.
//
// The kernel keeps, for each handle and each mapping, the handle that it
// came from. A program takes back what came from a handle of its own: the
// copies, the handles that other programs received, and their mappings.
// The window shows each case and the answer of the kernel.
//
// **What it is for.** It shows that each access in the system can be taken
// back. A program lends a handle for one call, then revokes it: the kernel
// ends each copy and each mapping that came from it, in this program and in
// the programs that received it. No program needs the cooperation of the
// receiver to take back what it gave.
//
// **The cases**, in order:
//
// - a copy with the right Read, then a copy of the copy that asks for Write:
//   the kernel gives Read only, because a copy never has more rights;
// - the count of what came from a handle, before and after a close;
// - a revocation: the copies end, the mapping of the program stays;
// - a mapping in another program, then its revocation;
// - a revocation in one other program only, with `Handle_Revoke` and the
//   handle of that program;
// - a revocation of a handle that the program does not have: `Bad_Handle`.
//
// **Start**: `start("origin")` in the console, or the bar of the desktop.
// It has no grant of `grants_of`: everything that it uses, it makes. Its
// budget has room for two programs: itself and the program "held", which
// never runs and only receives.
//
// **What a reader sees**: the table of the cases and the answers of the
// kernel. The log has "origin: ok, 12 cases", or "origin: wrong answer: ..."
// for each case that failed, then the cost of a lent handle: "origin: lend a
// handle and take it back: N ns with 4 kernel entries; copy and close: M ns
// with 2".
package origin

import "modus:support/display"
import "modus:support/graphics"
import "modus:support/interface"
import op "modus:contract/operation"
import "modus:support/system"

// The window is built with the interface package (docs/INTERFACE.md).
records_now, records_before: [512]interface.Draw_Record
text_now, text_before: [8192]u8
drawing: interface.Window_Drawing

LINE :: 22
ANSWER_X :: 424
WIDTH :: 640
CASE_CAPACITY :: 12
HEIGHT :: 12 + 4 * LINE + CASE_CAPACITY * LINE + 3 * LINE + 12

COLOR_WRONG :: 0xE0B040

// One case: what the program did, and what the kernel answered.
Case :: struct {
	text:   string,
	answer: string,
	right:  bool,
}

cases: [CASE_CAPACITY]Case
case_count: int

note :: proc "contextless" (text: string, answer: string, right: bool) {
	cases[case_count] = {text, answer, right}
	case_count += 1
}

// The measure: the cost of one handle that a program lends for a call and
// takes back, against the two kernel entries of a copy that it closes.
CYCLES :: 20000
lend_time, copy_time: u64 // Nanoseconds for one cycle.

// Where the program maps its memory object in the other program.
OTHER_ADDRESS :: 0x0000_0000_0100_0000

live :: proc "contextless" (handle: system.Handle) -> bool {
	kind, _, _ := system.handle_state(handle)
	return kind != .None
}

// The entry of origin: it runs the cases of the origin of a handle once,
// measures a lent handle, then shows the result until the principal closes
// the window.
//
// With no window it stops with the code 1. It creates one memory object and
// one program "held" from its own budget, runs the cases (each one compares
// the answer of the kernel with the expected answer), writes the result on
// the log, and measures 20000 cycles of "lend and take back" and 20000 of
// "copy and close". Then it draws the table and waits for events for ever.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	window, ok := display.open(ctx, WIDTH, HEIGHT, "origin")
	if !ok {
		system.stop(1)
	}
	// One memory object, mapped here, and one other program that never
	// runs: it only receives.
	memory, _ := system.memory_create(1)
	bytes, _ := system.memory_map(memory)
	(^u64)(bytes)^ = 7
	name := "held"
	created, _ := system.call(.Program_Create, u64(ctx.handles[op.CONTEXT_BUDGET]), u64(uintptr(raw_data(name))), u64(len(name)))
	other := system.Handle(created[0])
	count: u64

	first, _ := system.give(0, memory, {.Read})
	_, rights, _ := system.handle_state(first)
	note("copy the handle, with the right Read", "a handle with Read", rights == {.Read})
	second, _ := system.give(0, first, {.Read, .Write})
	_, rights, _ = system.handle_state(second)
	note("copy the copy, and ask for Write", "a handle with Read", rights == {.Read})
	note("count what came from the handle", "3: a mapping, 2 copies", system.handle_holdings(memory) == 3)
	system.close(first)
	note("close the first copy", "2: the second stays", system.handle_holdings(memory) == 2 && live(second))
	count, _ = system.handle_revoke(memory)
	note("revoke the handle", "the second copy ended", count == 1 && !live(second))
	note("read the memory of this program", "the mapping stays", (^u64)(bytes)^ == 7 && system.handle_holdings(memory) == 1)

	// A mapping in the other program, made with a copy that closes.
	first, _ = system.give(0, memory, {.Read})
	_, status := system.memory_map(first, {}, other, OTHER_ADDRESS)
	system.close(first)
	_, again := system.memory_map(memory, {}, other, OTHER_ADDRESS)
	note("map the memory in another program", "mapped", status == .Ok && again == .Bad_Address)
	count, _ = system.handle_revoke(memory)
	_, again = system.memory_map(memory, {}, other, OTHER_ADDRESS)
	note("revoke the handle", "the mapping ended", count == 1 && again == .Ok)

	// Now the other program has a mapping. It receives a handle too.
	given, _ := system.give(other, memory, {.Read})
	first, _ = system.give(0, memory, {.Read})
	note("give the handle to the other program", "4 came from the handle", given != 0 && system.handle_holdings(memory) == 4)
	count, _ = system.handle_revoke(memory, other)
	note("revoke in the other program only", "2 ended, the copy stays", count == 2 && live(first) && system.handle_holdings(memory) == 2)
	count, _ = system.handle_revoke(first)
	note("revoke the copy", "0 ended, the handle stays", count == 0 && live(memory))
	_, status = system.handle_revoke(system.Handle(0xFFFF))
	note("revoke a handle that the program does not have", "refused: bad handle", status == .Bad_Handle)

	wrong: u64
	for item in cases[:case_count] {
		if !item.right {
			wrong += 1
			system.log("origin: wrong answer: ", item.text)
		}
	}
	if wrong == 0 {
		system.log("origin: ok, ", u64(case_count), " cases")
	}

	// The measure. One cycle of a lent handle is four kernel entries: a
	// copy, a handle for the other program, the revocation, the close.
	start := system.time()
	for _ in 0 ..< CYCLES {
		copy, _ := system.give(0, memory, {.Read, .Give})
		system.give(other, copy, {.Read})
		system.handle_revoke(copy)
		system.close(copy)
	}
	lend_time = (system.time() - start) * 1_000_000 / CYCLES
	start = system.time()
	for _ in 0 ..< CYCLES {
		copy, _ := system.give(0, memory, {.Read, .Give})
		system.close(copy)
	}
	copy_time = (system.time() - start) * 1_000_000 / CYCLES
	system.log("origin: lend a handle and take it back: ", lend_time, " ns with 4 kernel entries; copy and close: ", copy_time, " ns with 2")

	for {
		if drawing.now.records == nil {
			drawing = interface.window_drawing_of(records_now[:], records_before[:], text_now[:], text_before[:])
		}
		frame := interface.window_frame_begin(&drawing, &window)
		table := frame.table
		interface.draw_rectangle(table, 0, 0, WIDTH, HEIGHT, graphics.COLOR_BACKGROUND)
		y := 12
		interface.draw_text(table, 12, y, "the kernel keeps the origin of each handle and of each mapping.", graphics.COLOR_DIM)
		y += LINE
		interface.draw_text(table, 12, y, "a program takes back what came from a handle that it holds.", graphics.COLOR_DIM)
		y += LINE + LINE / 2
		interface.draw_text(table, 12, y, "the program does", graphics.COLOR_DIM)
		interface.draw_text(table, ANSWER_X, y, "the kernel answers", graphics.COLOR_DIM)
		y += LINE
		for item, index in cases[:case_count] {
			if index % 2 == 0 {
				interface.draw_rectangle(table, 6, y - 3, WIDTH - 12, LINE, graphics.COLOR_CARD_TOP)
			}
			interface.draw_text(table, 12, y, item.text, graphics.COLOR_TEXT)
			interface.draw_text(table, ANSWER_X, y, item.right ? item.answer : "another answer", item.right ? graphics.COLOR_PROGRAM : COLOR_WRONG)
			y += LINE
		}
		y += LINE / 2
		line: [96]u8
		interface.draw_text(table, 12, y, system.format(line[:], "lend a handle for a call, then take it back: ", lend_time, " ns, 4 kernel entries"), graphics.COLOR_DIM)
		y += LINE
		interface.draw_text(table, 12, y, system.format(line[:], "copy a handle, then close the copy: ", copy_time, " ns, 2 kernel entries"), graphics.COLOR_DIM)
		interface.window_frame_end(&drawing, &frame, &window)
		display.wait(&window)
		for _ in display.next_event(&window) {
		}
	}
}
