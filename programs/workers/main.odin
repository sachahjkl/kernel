// A demonstration of the lock and of the word wait.
//
// One program, five threads, one queue of work. The first thread cuts a
// picture in tiles and puts all the tiles in the queue. Four threads take
// the tiles: each tile is computed by the thread that took it, and has the
// tint of this thread. A lock keeps the queue correct. A thread with no
// work waits on a word of memory; the first thread changes the word and
// wakes the four threads.
//
// Before the picture, the four threads add to one number, first with the
// lock, then with no lock. With no lock, additions are lost.
package workers

import "../../display"
import "../../graphics"
import "../../system"
import "base:intrinsics"

TILE :: 32
COLUMNS :: 14
ROWS :: 10
PICTURE_WIDTH :: COLUMNS * TILE
PICTURE_HEIGHT :: ROWS * TILE
MARGIN :: 12
HEADER :: 28
PANEL :: 208
WIDTH :: PICTURE_WIDTH + PANEL + 3 * MARGIN
HEIGHT :: HEADER + PICTURE_HEIGHT + 2 * MARGIN
FRAME_TIME :: 33
PICTURE_PAUSE :: 700 // Milliseconds between two pictures.
WORKER_COUNT :: 4
ITERATIONS :: 600
ADD_TIME :: 150 // Milliseconds: each thread adds for this time.

COLOR_BACKGROUND :: 0x10151C
COLOR_PANEL :: 0x18202A
COLOR_TEXT :: 0xD8E0E8
COLOR_DIM :: 0x7A8794
COLOR_WAITS :: 0xE0B040

// The queue of work: the threads share it, the lock keeps it correct.
Queue :: struct {
	lock:    system.Lock,
	picture: u32, // The number of the picture. A thread with no work waits on this word.
	next:    u32, // The first tile that no thread took.
	done:    u32, // The tiles that are complete.
	zoom:    f32,
}

Worker :: struct {
	number: int,
	tiles:  u64, // The tiles that this thread computed, in all the pictures.
	share:  u32, // The same, in this picture.
	thread: system.Thread,
}

queue: Queue
workers: [WORKER_COUNT]Worker
picture: graphics.Canvas
sum_locked, sum_free: u64
made_locked, made_free: u64
nothing: u64 // Always 0.
sum_lock: system.Lock

@(rodata)
tints := [WORKER_COUNT][3]u32{{70, 150, 255}, {255, 150, 60}, {90, 230, 110}, {220, 100, 250}}

tint_color :: proc "contextless" (number: int, level: u32) -> graphics.Color {
	tint := tints[number]
	return graphics.rgb(tint[0] * level / 255, tint[1] * level / 255, tint[2] * level / 255)
}

// One thread that adds to the number, and the additions that it made.
Adder :: struct {
	with_lock: bool,
	count:     u64,
}

// add is the entry of the threads that add to one number, for ADD_TIME.
add :: proc "c" (parameter: rawptr) -> ! {
	adder := (^Adder)(parameter)
	target := adder.with_lock ? &sum_locked : &sum_free
	start := system.time()
	for system.time() < start + ADD_TIME {
		for _ in 0 ..< 4096 {
			if adder.with_lock {
				system.lock(&sum_lock)
			}
			// A read, then a write: another thread can run between the two.
			// Real code computes between the two: here, it reads 8 words.
			value := intrinsics.volatile_load(target)
			for _ in 0 ..< 8 {
				value += intrinsics.volatile_load(&nothing)
			}
			intrinsics.volatile_store(target, value + 1)
			if adder.with_lock {
				system.unlock(&sum_lock)
			}
		}
		adder.count += 4096
	}
	system.thread_stop()
}

// add_with_threads gives the additions that the four threads made.
add_with_threads :: proc "contextless" (with_lock: bool) -> (total: u64) {
	adders: [WORKER_COUNT]Adder
	threads: [WORKER_COUNT]system.Thread
	for &thread, index in threads {
		adders[index].with_lock = with_lock
		thread, _ = system.thread_start(add, &adders[index])
	}
	for thread, index in threads {
		system.thread_wait(thread)
		total += adders[index].count
	}
	return total
}

// compute is the entry of the four threads that take tiles.
compute :: proc "c" (parameter: rawptr) -> ! {
	worker := (^Worker)(parameter)
	for {
		system.lock(&queue.lock)
		if queue.next == COLUMNS * ROWS {
			number := queue.picture
			system.unlock(&queue.lock)
			system.word_wait(&queue.picture, number)
			continue
		}
		tile := int(queue.next)
		queue.next += 1
		zoom := queue.zoom
		system.unlock(&queue.lock)

		left := tile % COLUMNS * TILE
		top := tile / COLUMNS * TILE
		for y in top ..< top + TILE {
			row := picture.pixels[y * picture.stride:]
			for x in left ..< left + TILE {
				cx := -0.7436 + (f32(x) - PICTURE_WIDTH / 2) * zoom
				cy := 0.1318 + (f32(y) - PICTURE_HEIGHT / 2) * zoom
				zx, zy: f32
				count: u32
				for count < ITERATIONS && zx * zx + zy * zy < 4 {
					zx, zy = zx * zx - zy * zy + cx, 2 * zx * zy + cy
					count += 1
				}
				row[x] = count == ITERATIONS ? tint_color(worker.number, 40) : tint_color(worker.number, 70 + (count * 8) % 186)
			}
		}

		system.lock(&queue.lock)
		queue.done += 1
		worker.tiles += 1
		worker.share += 1
		system.unlock(&queue.lock)
	}
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	window, ok := display.open(ctx, WIDTH, HEIGHT, "workers")
	if !ok {
		system.stop(1)
	}
	graphics.clear(window.canvas, COLOR_BACKGROUND)
	graphics.text(window.canvas, MARGIN, 8, "One queue of tiles, one lock, four threads.", COLOR_TEXT)
	display.present(&window)

	made_locked = add_with_threads(true)
	made_free = add_with_threads(false)
	system.log("workers: with the lock, 4 threads made ", made_locked, " additions: the number is ", sum_locked, ", ", u64(sum_lock.waits), " waits")
	system.log("workers: with no lock, 4 threads made ", made_free, " additions: the number is ", sum_free)
	if made_locked == sum_locked {
		system.log("workers: the lock lost no addition")
	}

	picture = graphics.view(window.canvas, MARGIN, HEADER + MARGIN, PICTURE_WIDTH, PICTURE_HEIGHT)
	queue.next = COLUMNS * ROWS
	queue.done = COLUMNS * ROWS
	queue.zoom = 0.012
	for &worker, index in workers {
		worker.number = index
		status: system.Status
		worker.thread, status = system.thread_start(compute, &worker)
		if status != .Ok {
			system.log("workers: cannot start a thread")
			system.stop(1)
		}
	}

	pictures: u64
	complete_at: u64
	for {
		now := system.time()
		system.lock(&queue.lock)
		done := queue.done
		if done == COLUMNS * ROWS && complete_at == 0 {
			complete_at = now
			if pictures == 1 {
				system.log("workers: ok, 4 threads computed ", u64(COLUMNS * ROWS), " tiles: ", workers[0].tiles, " ", workers[1].tiles, " ", workers[2].tiles, " ", workers[3].tiles)
			}
		}
		if done == COLUMNS * ROWS && now >= complete_at + (pictures == 0 ? 0 : PICTURE_PAUSE) {
			// A new picture: all the tiles go in the queue.
			queue.next = 0
			queue.done = 0
			queue.zoom *= 0.8
			if queue.zoom < 0.00002 {
				queue.zoom = 0.012
			}
			queue.picture += 1
			for &worker in workers {
				worker.share = 0
			}
			pictures += 1
			complete_at = 0
			done = 0
			system.unlock(&queue.lock)
			system.word_wake(&queue.picture, WORKER_COUNT)
		} else {
			system.unlock(&queue.lock)
		}

		x := 2 * MARGIN + PICTURE_WIDTH
		y := HEADER + MARGIN
		graphics.fill(window.canvas, x, y, PANEL, PICTURE_HEIGHT, COLOR_PANEL)
		after := graphics.text(window.canvas, x + 8, y + 8, "picture ", COLOR_TEXT)
		graphics.unsigned(window.canvas, after, y + 8, pictures, COLOR_TEXT)
		after = graphics.text(window.canvas, x + 8, y + 28, "tiles   ", COLOR_DIM)
		after = graphics.unsigned(window.canvas, after, y + 28, u64(done), COLOR_DIM)
		after = graphics.text(window.canvas, after, y + 28, "/", COLOR_DIM)
		graphics.unsigned(window.canvas, after, y + 28, COLUMNS * ROWS, COLOR_DIM)
		for &worker, index in workers {
			line := y + 60 + index * 44
			after = graphics.text(window.canvas, x + 8, line, "thread ", tint_color(index, 255))
			after = graphics.unsigned(window.canvas, after, line, u64(index + 1), tint_color(index, 255))
			graphics.unsigned(window.canvas, after + 16, line, u64(worker.share), COLOR_TEXT)
			// The part of the tiles of this picture that the thread took.
			graphics.fill(window.canvas, x + 8, line + 20, PANEL - 16, 8, COLOR_BACKGROUND)
			graphics.fill(window.canvas, x + 8, line + 20, int(worker.share) * (PANEL - 16) / (COLUMNS * ROWS), 8, tint_color(index, 255))
		}
		line := y + 60 + WORKER_COUNT * 44 + 4
		after = graphics.text(window.canvas, x + 8, line, "lock waits ", COLOR_WAITS)
		graphics.unsigned(window.canvas, after, line, u64(queue.lock.waits), COLOR_WAITS)
		graphics.text(window.canvas, x + 8, line + 24, "4 threads, 1 number", COLOR_DIM)
		after = graphics.text(window.canvas, x + 8, line + 42, "lock:    lost ", COLOR_TEXT)
		graphics.unsigned(window.canvas, after, line + 42, made_locked - sum_locked, COLOR_TEXT)
		after = graphics.text(window.canvas, x + 8, line + 60, "no lock: lost ", COLOR_TEXT)
		graphics.unsigned(window.canvas, after, line + 60, made_free - sum_free, COLOR_WAITS)
		display.present(&window)
		system.wait(now + FRAME_TIME)
	}
}
