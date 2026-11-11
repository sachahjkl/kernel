// A demonstration of rights on handles (properties 2 and 20).
//
// The root service gives this program two handles, each with a part of its
// rights: the machine with Inspect, the boot image with Read. The program
// asks the kernel for nine operations. The window shows each answer of the
// kernel: the kernel refuses each operation that needs another right.
package rights

import "support:display"
import "support:graphics"
import op "contract:operation"
import "support:system"

LINE :: 22
ANSWER_X :: 384
WIDTH :: 544
ATTEMPT_CAPACITY :: 9
HEIGHT :: 12 + 5 * LINE + ATTEMPT_CAPACITY * LINE + 12

COLOR_REFUSED :: 0xF06060
COLOR_WRONG :: 0xE0B040

// One operation that the program asked, and the answer of the kernel.
Attempt :: struct {
	text:     string,
	expected: system.Status,
	status:   system.Status,
}

attempts: [ATTEMPT_CAPACITY]Attempt
attempt_count: int

note :: proc "contextless" (text: string, expected: system.Status, status: system.Status) {
	attempts[attempt_count] = {text, expected, status}
	attempt_count += 1
}

answer :: proc "contextless" (status: system.Status) -> string {
	switch status {
	case .Ok:
		return "done"
	case .No_Right:
		return "refused: no right"
	case .Bad_Operation:
		return "bad operation"
	case .Bad_Handle:
		return "bad handle"
	case .Bad_Address:
		return "bad address"
	case .No_Memory:
		return "no memory"
	case .No_Slot:
		return "no slot"
	case .Bad_State:
		return "bad state"
	case .No_Budget:
		return "no budget"
	}
	return "?"
}

// The entry of a thread that ends at once.
idle :: proc "c" (parameter: rawptr) -> ! {
	system.thread_stop()
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	window, ok := display.open(ctx, WIDTH, HEIGHT, "rights")
	if !ok {
		system.stop(1)
	}
	machine := ctx.handles[system.GRANT_MACHINE]
	image := ctx.handles[system.GRANT_IMAGE]
	status: system.Status

	report: op.System_Report
	_, status = system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.System), 0, u64(uintptr(&report)), size_of(report))
	note("read the report of the machine", .Ok, status)
	_, status = system.call(.Device_Create, u64(machine), u64(op.Device_Kind.Ports), 0x60, 5)
	note("create a handle to the ports of the keyboard", .No_Right, status)
	_, status = system.call(.Machine_Stop, u64(machine), 0)
	note("stop the machine", .No_Right, status)

	_, status = system.memory_map(image, {})
	note("map the boot image to read it", .Ok, status)
	_, status = system.memory_map(image, {.Write})
	note("map the boot image to write in it", .No_Right, status)
	_, status = system.memory_map(image, {.Execute})
	note("map the boot image to execute it", .No_Right, status)
	_, status = system.give(window.ring_memory, image, {.Read})
	note("give the boot image to the compositor", .No_Right, status)

	// The handle of an object that the program creates has each right.
	memory: system.Handle
	memory, status = system.memory_create(1)
	if status == .Ok {
		address: rawptr
		address, status = system.memory_map(memory)
		if status == .Ok {
			(^u64)(address)^ = 1
		}
	}
	note("create memory and write in it", .Ok, status)
	thread: system.Thread
	thread, status = system.thread_start(idle, nil)
	if status == .Ok {
		_, status = system.call(.Thread_State, u64(thread.handle))
		system.thread_wait(thread)
	}
	note("start a thread and read its state", .Ok, status)

	allowed, refused, wrong: u64
	for attempt in attempts[:attempt_count] {
		if attempt.status != attempt.expected {
			wrong += 1
			system.log("rights: wrong answer: ", attempt.text, ": status ", u64(attempt.status))
		} else if attempt.status == .Ok {
			allowed += 1
		} else {
			refused += 1
		}
	}
	if wrong == 0 {
		system.log("rights: ok, ", allowed, " allowed, ", refused, " refused")
	}

	canvas := window.canvas
	for {
		display.picture_begin(&window) // The measure of a picture (display.present).
		graphics.clear(canvas, graphics.COLOR_BACKGROUND)
		y := 12
		graphics.text(canvas, 12, y, "this program holds two handles from the root service:", graphics.COLOR_DIM)
		y += LINE
		x := graphics.text(canvas, 28, y, "the machine, with the right ", graphics.COLOR_TEXT)
		graphics.text(canvas, x, y, "Inspect", graphics.COLOR_PROGRAM)
		y += LINE
		x = graphics.text(canvas, 28, y, "the boot image, with the right ", graphics.COLOR_TEXT)
		graphics.text(canvas, x, y, "Read", graphics.COLOR_PROGRAM)
		y += LINE + LINE / 2
		graphics.text(canvas, 12, y, "the program asks", graphics.COLOR_DIM)
		graphics.text(canvas, ANSWER_X, y, "the kernel answers", graphics.COLOR_DIM)
		y += LINE
		for attempt, index in attempts[:attempt_count] {
			if index % 2 == 0 {
				graphics.fill(canvas, 6, y - 3, WIDTH - 12, LINE, graphics.COLOR_CARD_TOP)
			}
			graphics.text(canvas, 12, y, attempt.text, graphics.COLOR_TEXT)
			color: graphics.Color = attempt.status == .Ok ? graphics.COLOR_PROGRAM : COLOR_REFUSED
			if attempt.status != attempt.expected {
				color = COLOR_WRONG
			}
			graphics.text(canvas, ANSWER_X, y, answer(attempt.status), color)
			y += LINE
		}
		display.present(&window)
		display.wait(&window)
		for _ in display.next_event(&window) {
		}
	}
}
