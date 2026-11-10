// A demonstration of budgets (properties 2 and 20).
//
// No operation creates an object from nothing: a budget pays for each
// memory object, each program and each thread. The root service gave this
// program a budget. The program creates objects until the kernel refuses,
// then frees them: each page returns. Then it takes a part of its budget
// for a new budget, and closes it: what the new budget held returns, and
// this budget pays for the objects that live.
package budget

import "support:display"
import "support:graphics"
import op "contract:operation"
import "support:system"

LINE :: 22
ANSWER_X :: 336
BAR_X :: 560
BAR_WIDTH :: 150
WIDTH :: BAR_X + BAR_WIDTH + 64
ROW_CAPACITY :: 11
HEIGHT :: 12 + 3 * LINE + ROW_CAPACITY * LINE + 12

OBJECT_PAGES :: 64
OBJECT_CAPACITY :: 64
THREAD_CAPACITY :: 8
PART_PAGES :: 256
FIRST_PAGES :: 200
SECOND_PAGES :: 100

COLOR_BACKGROUND :: 0x10151C
COLOR_PANEL :: 0x18202A
COLOR_TEXT :: 0xD8E0E8
COLOR_DIM :: 0x7A8794
COLOR_DONE :: 0x58D878
COLOR_REFUSED :: 0xF06060
COLOR_WRONG :: 0xE0B040
COLOR_BAR :: 0x4A90E0
COLOR_BAR_BACK :: 0x232C38

// One step of the program: what it asked, the answer of the kernel, and
// the pages that the budget holds after the step.
Row :: struct {
	text:    string,
	buffer:  [40]u8,
	count:   int, // The bytes of the answer in buffer.
	refused: bool, // The answer ends with a refusal of the kernel.
	correct: bool, // The answer and the pages are what the rules give.
	pages:   u64,
}

rows: [ROW_CAPACITY]Row
row_count: int
release: u32 // The threads of the test wait while this word is 0.

pages_left :: proc "contextless" () -> u64 {
	amounts, _ := system.budget_read()
	return amounts.pages
}

note :: proc "contextless" (text: string, refused: bool, correct: bool, parts: ..system.Part) {
	row := &rows[row_count]
	row_count += 1
	row.text = text
	row.count = len(system.format(row.buffer[:], ..parts))
	row.refused = refused
	row.correct = correct
	row.pages = pages_left()
}

// wait_release is the entry of a thread that waits, then ends.
wait_release :: proc "c" (parameter: rawptr) -> ! {
	for release == 0 {
		system.word_wait(&release, 0)
	}
	system.thread_stop()
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	window, ok := display.open(ctx, WIDTH, HEIGHT, "budget")
	if !ok {
		system.stop(1)
	}
	start, _ := system.budget_read()
	note("the budget from the root service", false, start.pages != 0, start.pages, " pages")

	// Memory objects, until the budget cannot pay.
	objects: [OBJECT_CAPACITY]system.Handle
	object_count: u64
	status := system.Status.Ok
	for object_count < OBJECT_CAPACITY {
		objects[object_count], status = system.memory_create(OBJECT_PAGES)
		if status != .Ok {
			break
		}
		object_count += 1
	}
	// An object also pays for its frame list (operation.memory_cost).
	cost := op.memory_cost(OBJECT_PAGES)
	note("create memory objects of 64 pages", true, status == .No_Budget && object_count == start.pages / cost && pages_left() == start.pages % cost, object_count, " done, then no budget")
	for object in objects[:object_count] {
		system.close(object)
	}
	note("close these memory objects", false, pages_left() == start.pages, "each page returns")

	// Threads, until the budget cannot pay.
	threads: [THREAD_CAPACITY]system.Thread
	thread_count: u64
	for thread_count < THREAD_CAPACITY {
		threads[thread_count], status = system.thread_start(wait_release, nil)
		if status != .Ok {
			break
		}
		thread_count += 1
	}
	note("start threads", true, status == .No_Budget && thread_count == start.threads, thread_count, " done, then no budget")
	release = 1
	system.word_wake(&release, THREAD_CAPACITY)
	for thread in threads[:thread_count] {
		system.thread_wait(thread)
	}
	after_threads, _ := system.budget_read()
	note("end these threads", false, after_threads == start, "each page returns")

	// A part of the budget becomes a new budget.
	part, part_status := system.budget_create({pages = PART_PAGES})
	note("take 256 pages for a new budget", false, part_status == .Ok && pages_left() == start.pages - PART_PAGES, "done")
	first, first_status := system.memory_create(FIRST_PAGES, part)
	note("create 200 pages with the new budget", false, first_status == .Ok && pages_left() == start.pages - PART_PAGES, "done")
	_, second_status := system.memory_create(SECOND_PAGES, part)
	note("create 100 pages more with it", true, second_status == .No_Budget, "no budget")
	system.close(part)
	note("close the new budget, keep the memory", false, pages_left() == start.pages - op.memory_cost(FIRST_PAGES), "this budget pays for it")
	system.close(first)
	note("close the memory", false, pages_left() == start.pages, "each page returns")

	// The budget paid for one program: this one.
	_, status = system.call(.Program_Create, u64(system.own_budget()), 0, 0)
	note("create a program", true, status == .No_Budget, "no budget")

	wrong: u64
	for &row in rows[:row_count] {
		if !row.correct {
			wrong += 1
			system.log("budget: wrong answer: ", row.text, ": ", string(row.buffer[:row.count]), ", ", row.pages, " pages")
		}
	}
	if wrong == 0 {
		system.log("budget: ok, ", object_count, " memory objects then no budget, ", thread_count, " threads then no budget, each page returned")
	}

	canvas := window.canvas
	for {
		graphics.clear(canvas, COLOR_BACKGROUND)
		y := 12
		graphics.text(canvas, 12, y, "no object comes from nothing: a budget pays for each page,", COLOR_DIM)
		y += LINE
		graphics.text(canvas, 12, y, "each program and each thread. what ends returns to its budget.", COLOR_DIM)
		y += LINE + LINE / 2
		graphics.text(canvas, 12, y, "the program asks", COLOR_DIM)
		graphics.text(canvas, ANSWER_X, y, "the kernel answers", COLOR_DIM)
		graphics.text(canvas, BAR_X, y, "pages of the budget", COLOR_DIM)
		y += LINE
		for &row, index in rows[:row_count] {
			if index % 2 == 0 {
				graphics.fill(canvas, 6, y - 3, WIDTH - 12, LINE, COLOR_PANEL)
			}
			graphics.text(canvas, 12, y, row.text, COLOR_TEXT)
			color: graphics.Color = row.refused ? COLOR_REFUSED : COLOR_DONE
			if !row.correct {
				color = COLOR_WRONG
			}
			graphics.text(canvas, ANSWER_X, y, string(row.buffer[:row.count]), color)
			graphics.fill(canvas, BAR_X, y + 2, BAR_WIDTH, 10, COLOR_BAR_BACK)
			graphics.fill(canvas, BAR_X, y + 2, int(row.pages * BAR_WIDTH / max(start.pages, 1)), 10, COLOR_BAR)
			graphics.unsigned(canvas, BAR_X + BAR_WIDTH + 8, y, row.pages, COLOR_TEXT)
			y += LINE
		}
		display.present(&window)
		display.wait(&window)
		for _ in display.next_event(&window) {
		}
	}
}
