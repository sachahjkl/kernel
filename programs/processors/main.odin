// A demonstration of several processors.
//
// First, the program asks the kernel what each processor runs, while four
// of its threads compute: the kernel answers that all the processors run
// threads of this one program at the same time.
//
// Then 1, 2 and 4 threads compute the same picture, one row at a time.
// Each row has the tint of the thread that computed it. The panel shows
// the time of each picture, and the load of each processor.
//
// The program needs the grant to inspect the machine.
package processors

import "support:display"
import "support:graphics"
import op "contract:operation"
import "support:system"
import "base:intrinsics"

PICTURE_WIDTH :: 448
PICTURE_HEIGHT :: 320
MARGIN :: 12
HEADER :: 28
PANEL :: 264
WIDTH :: PICTURE_WIDTH + PANEL + 3 * MARGIN
HEIGHT :: HEADER + PICTURE_HEIGHT + 2 * MARGIN
FRAME_TIME :: 33
PICTURE_PAUSE :: 500 // Milliseconds between two pictures.
LOAD_INTERVAL :: 250 // Milliseconds between two measures of the load.
TOGETHER_TIME :: 3000 // Milliseconds, at most, of the first test.
WORKER_COUNT :: 4
PROCESSOR_ROWS :: 8 // The panel shows at most this number of processors.
ITERATIONS :: 4000
LINE :: 20

COLOR_WAITS :: 0xE0B040
COLOR_BAR :: 0x4A90E0

// One picture to compute: the threads share it, the lock keeps it correct.
Job :: struct {
	lock:    system.Lock,
	number:  u32, // The number of the picture. A thread with no work waits on this word.
	threads: u32, // The threads that compute this picture: the workers 0 to threads - 1.
	next:    u32, // The first row that no thread took.
	done:    u32, // The rows that are complete.
	finish:  u64, // The time when the last row was complete.
}

Worker :: struct {
	number: int,
	rows:   u32, // The rows of this picture that the thread computed.
}

// What the kernel says of one processor.
Processor :: struct {
	name:      [32]u8, // The program that the processor runs.
	busy_time: u64,
	load:      u64, // Percent.
}

@(rodata)
thread_counts := [?]u32{1, 2, 4}

job: Job
workers: [WORKER_COUNT]Worker
picture: graphics.Canvas
machine: system.Handle
processor_count: u64
processors: [PROCESSOR_ROWS]Processor
together: u64 // The most processors that ran this program at one time.
spin_stop: u32
times: [len(thread_counts)]u64 // The milliseconds of the last picture with thread_counts[n] threads.

@(rodata)
tints := [WORKER_COUNT][3]u32{{70, 150, 255}, {255, 150, 60}, {90, 230, 110}, {220, 100, 250}}

tint_color :: proc "contextless" (number: int, level: u32) -> graphics.Color {
	tint := tints[number]
	return graphics.rgb(tint[0] * level / 255, tint[1] * level / 255, tint[2] * level / 255)
}

// spin is the entry of the threads of the first test: they compute until
// the first thread says stop.
spin :: proc "c" (parameter: rawptr) -> ! {
	for intrinsics.atomic_load(&spin_stop) == 0 {
		intrinsics.cpu_relax()
	}
	system.thread_stop()
}

// processors_same asks the kernel how many processors run a thread of
// this program now. The thread that asks is on one of them.
processors_same :: proc "contextless" () -> (count: u64) {
	for index in 0 ..< processor_count {
		report: op.Processor_Report
		system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.Processor), index, u64(uintptr(&report)), size_of(report))
		count += report.same
	}
	return count
}

// run_together runs one thread per processor, and waits until the kernel
// sees them all at one time.
run_together :: proc "contextless" () {
	threads: [WORKER_COUNT]system.Thread
	for &thread in threads {
		status: system.Status
		thread, status = system.thread_start(spin, nil)
		if status != .Ok {
			system.log("processors: cannot start a thread")
			system.stop(1)
		}
	}
	// This thread is the fifth: with the four others, it can fill 5 processors.
	target := min(processor_count, WORKER_COUNT + 1)
	start := system.time()
	for together < target && system.time() < start + TOGETHER_TIME {
		together = max(together, processors_same())
	}
	intrinsics.atomic_store(&spin_stop, 1)
	for thread in threads {
		system.thread_wait(thread)
	}
}

// compute is the entry of the four threads that take rows.
compute :: proc "c" (parameter: rawptr) -> ! {
	worker := (^Worker)(parameter)
	for {
		system.lock(&job.lock)
		if u32(worker.number) >= job.threads || job.next == PICTURE_HEIGHT {
			number := job.number
			system.unlock(&job.lock)
			system.word_wait(&job.number, number)
			continue
		}
		y := int(job.next)
		job.next += 1
		system.unlock(&job.lock)

		row := picture.pixels[y * picture.stride:]
		for x in 0 ..< PICTURE_WIDTH {
			cx := -0.62 + (f64(x) - PICTURE_WIDTH / 2) * (2.6 / PICTURE_WIDTH)
			cy := (f64(y) - PICTURE_HEIGHT / 2) * (2.6 / PICTURE_WIDTH)
			zx, zy: f64
			count: u32
			for count < ITERATIONS && zx * zx + zy * zy < 4 {
				zx, zy = zx * zx - zy * zy + cx, 2 * zx * zy + cy
				count += 1
			}
			row[x] = count == ITERATIONS ? tint_color(worker.number, 48) : tint_color(worker.number, 80 + (count * 12) % 176)
		}

		system.lock(&job.lock)
		job.done += 1
		worker.rows += 1
		if job.done == PICTURE_HEIGHT {
			job.finish = system.time()
		}
		system.unlock(&job.lock)
	}
}

// load_measure reads what each processor runs, and its load since the
// last measure.
load_measure :: proc "contextless" (elapsed: u64) {
	for &processor, index in processors[:min(processor_count, PROCESSOR_ROWS)] {
		report: op.Processor_Report
		system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.Processor), u64(index), u64(uintptr(&report)), size_of(report))
		processor.load = min((report.busy_time - processor.busy_time) * 100 / max(elapsed, 1), 100)
		processor.busy_time = report.busy_time
		processor.name = {}
		if report.program != 0 {
			program: op.Program_Report
			system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.Program), report.program, u64(uintptr(&program)), size_of(program))
			processor.name = program.name
		}
	}
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	window, ok := display.open(ctx, WIDTH, HEIGHT, "processors")
	if !ok {
		system.stop(1)
	}
	canvas := window.canvas
	graphics.clear(canvas, graphics.COLOR_BACKGROUND)
	graphics.text(canvas, MARGIN, 8, "One picture, computed by 1, 2 and 4 threads.", graphics.COLOR_TEXT)
	display.present(&window)

	machine = ctx.handles[system.GRANT_MACHINE]
	report: op.System_Report
	if _, status := system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.System), 0, u64(uintptr(&report)), size_of(report)); status != .Ok {
		system.log("processors: no grant to inspect the machine")
		system.stop(1)
	}
	processor_count = report.processors

	run_together()
	if together == min(processor_count, WORKER_COUNT + 1) {
		system.log("processors: ok, ", together, " processors ran the program at the same time")
	} else {
		system.log("processors: at most ", together, " of ", processor_count, " processors ran the program at the same time")
	}

	picture = graphics.view(canvas, MARGIN, HEADER + MARGIN, PICTURE_WIDTH, PICTURE_HEIGHT)
	job.next = PICTURE_HEIGHT
	job.done = PICTURE_HEIGHT
	for &worker, index in workers {
		worker.number = index
		if _, status := system.thread_start(compute, &worker); status != .Ok {
			system.log("processors: cannot start a thread")
			system.stop(1)
		}
	}

	phase := -1 // The index in thread_counts of the picture that the threads compute.
	started_at: u64
	complete_at: u64
	measured_at := system.time()
	logged := false
	for {
		now := system.time()
		system.lock(&job.lock)
		done := job.done
		if done == PICTURE_HEIGHT && complete_at == 0 {
			complete_at = now
			if phase >= 0 {
				times[phase] = job.finish - started_at
			}
			if phase == len(thread_counts) - 1 && !logged {
				logged = true
				system.log("processors: the picture took ", times[0], " ms with 1 thread, ", times[1], " ms with 2 threads, ", times[2], " ms with 4 threads")
			}
		}
		if done == PICTURE_HEIGHT && now >= complete_at + (phase < 0 ? 0 : PICTURE_PAUSE) {
			// A new picture: all the rows are free again.
			phase = (phase + 1) % len(thread_counts)
			graphics.clear(picture, graphics.COLOR_CARD_TOP)
			for &worker in workers {
				worker.rows = 0
			}
			job.threads = thread_counts[phase]
			job.next = 0
			job.done = 0
			job.number += 1
			complete_at = 0
			done = 0
			started_at = system.time()
			system.unlock(&job.lock)
			system.word_wake(&job.number, WORKER_COUNT)
		} else {
			system.unlock(&job.lock)
		}
		if now >= measured_at + LOAD_INTERVAL {
			load_measure(now - measured_at)
			measured_at = now
		}

		x := 2 * MARGIN + PICTURE_WIDTH
		y := HEADER + MARGIN
		graphics.fill(canvas, x, y, PANEL, PICTURE_HEIGHT, graphics.COLOR_CARD_TOP)
		x += 8
		y += 8
		after := graphics.unsigned(canvas, x, y, processor_count, graphics.COLOR_TEXT)
		after = graphics.text(canvas, after, y, " processors, at one time ", graphics.COLOR_TEXT)
		graphics.unsigned(canvas, after, y, together, graphics.COLOR_PROGRAM)
		y += LINE + 4
		for &processor, index in processors[:min(processor_count, PROCESSOR_ROWS)] {
			graphics.unsigned(canvas, x, y, u64(index), graphics.COLOR_DIM)
			graphics.fill(canvas, x + 20, y + 3, 80, 10, graphics.COLOR_TRACK)
			graphics.fill(canvas, x + 20, y + 3, int(processor.load) * 80 / 100, 10, COLOR_BAR)
			graphics.text(canvas, x + 108, y, system.name_of(processor.name[:]), graphics.COLOR_TEXT)
			y += LINE
		}
		y += 8
		graphics.text(canvas, x, y, "threads  time of the picture", graphics.COLOR_DIM)
		y += LINE
		for count, index in thread_counts {
			color := graphics.Color(index == phase ? graphics.COLOR_TEXT : graphics.COLOR_DIM)
			graphics.unsigned(canvas, x, y, u64(count), color)
			if times[index] != 0 {
				after = graphics.unsigned(canvas, x + 72, y, times[index], color)
				graphics.text(canvas, after, y, " ms", color)
				graphics.fill(canvas, x + 152, y + 3, int(times[index] * 88 / max(times[0], times[index])), 10, COLOR_BAR)
			}
			y += LINE
		}
		y += 8
		graphics.text(canvas, x, y, "thread   rows of this picture", graphics.COLOR_DIM)
		y += LINE
		for &worker, index in workers {
			graphics.unsigned(canvas, x, y, u64(index + 1), tint_color(index, 255))
			graphics.unsigned(canvas, x + 72, y, u64(worker.rows), graphics.COLOR_TEXT)
			graphics.fill(canvas, x + 112, y + 3, int(worker.rows) * 128 / PICTURE_HEIGHT, 10, tint_color(index, 255))
			y += LINE
		}
		y += 4
		after = graphics.text(canvas, x, y, "lock waits ", COLOR_WAITS)
		graphics.unsigned(canvas, after, y, u64(job.lock.waits), COLOR_WAITS)
		display.present(&window)
		for _ in display.next_event(&window) {}
		display.wait(&window, now + FRAME_TIME)
	}
}
