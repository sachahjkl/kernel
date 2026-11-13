package kerneltool

import "core:strings"
import "core:testing"

// A screen is settled when the program of each window is in a wait in the
// two reads, with the same count of kernel entries, and no change waits for
// a frame.
@(test)
screen_settle_problem_accepts_a_settled_screen :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	programs := []Settle_Program{{slot = 3, name = "console", state = "waiting", entries = 900}, {slot = 7, name = "notes", state = "waiting", entries = 120}}
	windows := []Settle_Window{{title = "console", presents = 14}, {title = "notes", presents = 2}}
	testing.expect_value(t, screen_settle_problem(programs, windows, false, programs), "")
}

// Each fact that is missing is a reason, and the reason names the window.
@(test)
screen_settle_problem_names_what_is_not_settled :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	before := []Settle_Program{{slot = 7, name = "notes", state = "waiting", entries = 120}}
	windows := []Settle_Window{{title = "notes", presents = 2}}
	testing.expect(t, strings.contains(screen_settle_problem(before, windows, true, before), "the desktop"), "a change of the desktop that waits")
	waiting := []Settle_Window{{title = "notes", presents = 2, waits = true}}
	testing.expect(t, strings.contains(screen_settle_problem(before, waiting, false, before), "the window notes has a picture that no frame drew yet"), "a Present that waits")
	ready := []Settle_Program{{slot = 7, name = "notes", state = "ready", entries = 120}}
	testing.expect(t, strings.contains(screen_settle_problem(before, windows, false, ready), "the program of the window notes is ready"), "the program runs at the second read")
	testing.expect(t, strings.contains(screen_settle_problem(ready, windows, false, before), "the program of the window notes was ready"), "the program ran at the first read")
	entered := []Settle_Program{{slot = 7, name = "notes", state = "waiting", entries = 123}}
	testing.expect(t, strings.contains(screen_settle_problem(before, windows, false, entered), "entered the kernel 3 times"), "the program ran between the reads")
	testing.expect(t, strings.contains(screen_settle_problem(nil, windows, false, before), "started between two reads"), "the program is new")
	empty := []Settle_Window{{title = "notes"}}
	testing.expect(t, strings.contains(screen_settle_problem(before, empty, false, before), "the window notes has no picture of its program yet"), "a surface with no Present")
}

// A window that draws with no end, the windows of the programs that carry
// the reads, and a window whose program stopped do not hold a picture back.
@(test)
screen_settle_problem_leaves_windows_out :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	before := []Settle_Program{{slot = 4, name = "plasma", state = "ready", entries = 10}, {slot = 5, name = "remote", state = "ready", entries = 50}, {slot = 6, name = "monitor", state = "ready", entries = 70}, {slot = 8, name = "rights", state = "stopped", entries = 30}}
	after := []Settle_Program{{slot = 4, name = "plasma", state = "ready", entries = 400}, {slot = 5, name = "remote", state = "ready", entries = 90}, {slot = 6, name = "monitor", state = "ready", entries = 99}, {slot = 8, name = "rights", state = "stopped", entries = 30}}
	windows := []Settle_Window{{title = "plasma", presents = 800, waits = true}, {title = "remote", presents = 9, waits = true}, {title = "monitor", presents = 5}, {title = "rights", presents = 0}}
	testing.expect_value(t, screen_settle_problem(before, windows, false, after), "")
	testing.expect(t, draws_without_end("life") && !draws_without_end("notes") && left_out_of_calls("remote") && !draws_without_end("remote"))
}

// The rectangle of a window comes from the line of its surface, and from
// the line of its last move when it moved after.
@(test)
log_window_rectangle_reads_the_lines :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	log := "[compositor] compositor: surface life 480x320 at 64,56\n[compositor] compositor: surface plasma 320x200 at 104,88\n[compositor] compositor: window life moved to 232,144\n"
	life, life_found := log_window_rectangle(log, "life")
	testing.expect(t, life_found)
	testing.expect_value(t, life, Picture_Rectangle{232, 144, 232 + 480 + 2 * WINDOW_BORDER, 144 + WINDOW_TITLE_HEIGHT + 320 + WINDOW_BORDER})
	plasma, plasma_found := log_window_rectangle(log, "plasma")
	testing.expect(t, plasma_found)
	testing.expect_value(t, plasma, Picture_Rectangle{104, 88, 104 + 320 + 2 * WINDOW_BORDER, 88 + WINDOW_TITLE_HEIGHT + 200 + WINDOW_BORDER})
	_, temple_found := log_window_rectangle(log, "temple")
	testing.expect(t, !temple_found, "a window that the log does not have")
	// A window made again after a move is at the place of its new surface.
	again := strings.concatenate({log, "[compositor] compositor: surface life 480x320 at 144,120\n"}, context.temp_allocator)
	life, life_found = log_window_rectangle(again, "life")
	testing.expect(t, life_found && life.left == 144 && life.top == 120)
}

// Two pictures differ where a pixel differs outside the rectangles that
// are left out.
@(test)
pictures_differ_outside_reads_each_pixel :: proc(t: ^testing.T) {
	WIDTH :: 4
	HEIGHT :: 3
	first, second: [WIDTH * HEIGHT * 3]u8
	_, _, differ := pictures_differ_outside(first[:], second[:], WIDTH, HEIGHT, nil)
	testing.expect(t, !differ, "the same pictures")
	second[(2 * WIDTH + 1) * 3 + 2] = 9 // The pixel 1,2.
	x, y, differ_now := pictures_differ_outside(first[:], second[:], WIDTH, HEIGHT, nil)
	testing.expect(t, differ_now && x == 1 && y == 2)
	_, _, differ_inside := pictures_differ_outside(first[:], second[:], WIDTH, HEIGHT, []Picture_Rectangle{{1, 2, 2, 3}})
	testing.expect(t, !differ_inside, "the pixel is in a rectangle that is left out")
	second[0] = 1 // The pixel 0,0, outside the rectangle.
	x, y, differ_now = pictures_differ_outside(first[:], second[:], WIDTH, HEIGHT, []Picture_Rectangle{{1, 2, 2, 3}})
	testing.expect(t, differ_now && x == 0 && y == 0)
}
