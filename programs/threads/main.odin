// A demonstration of threads (docs/ARCHITECTURE.md, decision 6).
//
// One program, one address space, five threads. Each square is drawn by its
// own thread, directly in the surface of the program: the threads share all
// the memory. The same procedure runs in the four threads; only the
// parameter record differs. The kernel gives the processor to each thread in
// turn: no thread calls another.
//
// Each thread computes with floating point numbers. The kernel keeps the
// registers of each thread: a wrong picture means a lost register.
//
//   1 to 4: stop the thread of a square, or start it again
package threads

import "support:display"
import "support:graphics"
import "support:system"

SQUARE :: 176
MARGIN :: 12
LABEL :: 20
HEADER :: 28
WIDTH :: 2 * SQUARE + 3 * MARGIN
HEIGHT :: HEADER + 2 * (SQUARE + LABEL) + 3 * MARGIN
FRAME_TIME :: 33
WORKER_COUNT :: 4
ITERATIONS :: 28

COLOR_STOPPED :: 0xD05050

// The parameter record of one thread. The thread writes `frames`; the first
// thread reads it.
Worker :: struct {
	canvas: graphics.Canvas, // The square of the thread, in the surface.
	number: int,
	frames: u64,
	thread: system.Thread,
	runs:   bool,
}

workers: [WORKER_COUNT]Worker

// The center of the path of the constant of each Julia set, and its tint.
@(rodata)
centers := [WORKER_COUNT][2]f32{{-0.76, 0.12}, {0.30, 0.52}, {-0.12, 0.76}, {-0.40, -0.59}}
@(rodata)
tints := [WORKER_COUNT][3]u32{{2, 5, 9}, {9, 5, 2}, {3, 9, 4}, {8, 3, 9}}

// draw_square is the entry of the four drawing threads.
draw_square :: proc "c" (parameter: rawptr) -> ! {
	worker := (^Worker)(parameter)
	center := centers[worker.number]
	tint := tints[worker.number]
	// A triangle wave moves the constant: no table and no library.
	wave :: proc "contextless" (step: u64, period: u64) -> f32 {
		phase := f32(step % period) / f32(period)
		return phase < 0.5 ? 4 * phase - 1 : 3 - 4 * phase
	}
	for {
		now := system.time()
		cx := center.x + 0.06 * wave(now, 5000 + u64(worker.number) * 700)
		cy := center.y + 0.06 * wave(now + 1250, 7000 - u64(worker.number) * 500)
		for y in 0 ..< SQUARE {
			row := worker.canvas.pixels[y * worker.canvas.stride:]
			for x in 0 ..< SQUARE {
				zx := (f32(x) - SQUARE / 2) * (3.0 / SQUARE)
				zy := (f32(y) - SQUARE / 2) * (3.0 / SQUARE)
				count: u32
				for count < ITERATIONS && zx * zx + zy * zy < 4 {
					zx, zy = zx * zx - zy * zy + cx, 2 * zx * zy + cy
					count += 1
				}
				row[x] = graphics.rgb(min(count * tint[0], 255), min(count * tint[1], 255), min(count * tint[2], 255))
			}
		}
		worker.frames += 1
		// Each thread has its own kernel ring: it waits alone.
		system.sleep(system.time() + FRAME_TIME)
	}
}

// The sum that a thread computes for the first thread.
Sum :: struct {
	last:   u64,
	result: u64,
}

add_numbers :: proc "c" (parameter: rawptr) -> ! {
	sum := (^Sum)(parameter)
	for number in 1 ..= sum.last {
		sum.result += number
	}
	system.thread_stop()
}

worker_start :: proc "contextless" (index: int) -> bool {
	worker := &workers[index]
	status: system.Status
	worker.thread, status = system.thread_start(draw_square, worker)
	worker.runs = status == .Ok
	return worker.runs
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	window, ok := display.open(ctx, WIDTH, HEIGHT, "threads")
	if !ok {
		system.stop(1)
	}

	// A thread that ends: the first thread waits for it, then reads the
	// result in the memory that the two threads share.
	sum := Sum {
		last = 1000,
	}
	if adder, status := system.thread_start(add_numbers, &sum); status == .Ok {
		system.thread_wait(adder)
	}
	system.log("threads: a thread added the numbers to 1000: ", sum.result)

	graphics.clear(window.canvas, graphics.COLOR_BACKGROUND)
	for &worker, index in workers {
		x := MARGIN + (index % 2) * (SQUARE + MARGIN)
		y := HEADER + MARGIN + (index / 2) * (SQUARE + LABEL + MARGIN)
		worker.number = index
		worker.canvas = graphics.view(window.canvas, x, y, SQUARE, SQUARE)
		if !worker_start(index) {
			system.log("threads: cannot start a thread")
			system.stop(1)
		}
	}

	ready := false
	for {
		for event in display.next_event(&window) {
			if event.kind != .Key || !event.pressed || event.character < '1' || event.character >= '1' + WORKER_COUNT {
				continue
			}
			index := int(event.character - '1')
			worker := &workers[index]
			if worker.runs {
				system.thread_end(worker.thread)
				worker.runs = false
				system.log("threads: thread ", u64(index + 1), " stopped at frame ", worker.frames)
			} else if worker_start(index) {
				system.log("threads: thread ", u64(index + 1), " started")
			}
		}
		drawn := 0
		graphics.fill(window.canvas, 0, 0, WIDTH, HEADER + MARGIN, graphics.COLOR_BACKGROUND)
		graphics.text(window.canvas, MARGIN, 8, "One program. Each square is one thread.", graphics.COLOR_TEXT)
		for &worker, index in workers {
			x := MARGIN + (index % 2) * (SQUARE + MARGIN)
			y := HEADER + MARGIN + (index / 2) * (SQUARE + LABEL + MARGIN) + SQUARE
			graphics.fill(window.canvas, x, y, SQUARE, LABEL, graphics.COLOR_BACKGROUND)
			after := graphics.text(window.canvas, x, y + 3, "thread ", graphics.COLOR_TEXT)
			after = graphics.unsigned(window.canvas, after, y + 3, u64(index + 1), graphics.COLOR_TEXT)
			if worker.runs {
				after = graphics.text(window.canvas, after, y + 3, "  frame ", graphics.COLOR_DIM)
				graphics.unsigned(window.canvas, after, y + 3, worker.frames, graphics.COLOR_DIM)
			} else {
				graphics.text(window.canvas, after, y + 3, "  stopped", COLOR_STOPPED)
			}
			if worker.frames > 0 {
				drawn += 1
			}
		}
		if drawn == WORKER_COUNT && !ready {
			ready = true
			system.log("threads: ok, ", u64(WORKER_COUNT), " threads draw in one surface")
		}
		display.present(&window)
		display.wait(&window, system.time() + FRAME_TIME)
	}
}
