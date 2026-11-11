#+build !freestanding
package bar

import "core:testing"

// The frame of the compositor: borders of 2, a close button of 24, a title
// of 24.
@(private = "file")
frame_of :: proc(surface_width: int) -> Window_Frame {
	return {outer_width = surface_width + 4, border = 2, close_size = 24, title_height = 24}
}

// kept_on_screen says if TITLE_KEPT pixels of the title are on the screen,
// under the bar, and if the place is on the grid.
@(private = "file")
kept_on_screen :: proc(x, y: int, frame: Window_Frame, screen_width, screen_height: int) -> bool {
	title_left, title_right := x, x + frame.outer_width - frame.border - frame.close_size
	visible := min(title_right, screen_width) - max(title_left, 0)
	return visible >= TITLE_KEPT && y >= HEIGHT && y + TITLE_KEPT <= screen_height && x %% GRID == 0 && y %% GRID == 0
}

// The pointer at each edge, the window held at each pixel of its title:
// the place keeps a part of the title on the screen. The widths 1280 and
// 1366 (not a multiple of 8) and the heights 768 and 765.
@(test)
dragged_window_stays_on_screen :: proc(t: ^testing.T) {
	sizes := [?][2]int{{1280, 768}, {1366, 765}, {1024, 768}}
	for size in sizes {
		screen_width, screen_height := size[0], size[1]
		surface_widths := [?]int{100, 480, screen_width - 4, screen_width + 300}
		for surface_width in surface_widths {
			frame := frame_of(surface_width)
			for held_x := 0; held_x < frame.outer_width - frame.border; held_x += 1 {
				for held_y in 0 ..< 24 {
					pointers := [?][2]int{{0, 0}, {screen_width - 1, 0}, {0, screen_height - 1}, {screen_width - 1, screen_height - 1}, {screen_width / 2, screen_height / 2}}
					for pointer in pointers {
						x, y := dragged_window_place(pointer[0], pointer[1], held_x, held_y, frame, screen_width, screen_height)
						if !kept_on_screen(x, y, frame, screen_width, screen_height) {
							testing.expectf(t, false, "screen %dx%d, surface %d, held at %d,%d, pointer %d,%d: the place %d,%d leaves too little of the title", screen_width, screen_height, surface_width, held_x, held_y, pointer[0], pointer[1], x, y)
							return
						}
					}
				}
			}
		}
	}
}

// The inputs of the read: a press in the first four columns of the title,
// then the pointer at the right edge. The rounding alone gave x = 1280 (and
// 1368 on a screen of 1366): no pixel on the screen.
@(test)
dragged_window_right_edge_cases :: proc(t: ^testing.T) {
	frame := frame_of(480)
	for held_x in 0 ..< 4 {
		x, _ := dragged_window_place(1279, 300, held_x, 10, frame, 1280, 768)
		testing.expect_value(t, x, 1272)
		x, _ = dragged_window_place(1365, 300, held_x, 10, frame, 1366, 768)
		testing.expect_value(t, x, 1352)
	}
	// The bottom edge, a height that is a multiple of 8.
	for held_y in 0 ..< 4 {
		_, y := dragged_window_place(300, 767, 100, held_y, frame, 1280, 768)
		testing.expect_value(t, y, 760)
	}
	// The left edge, held next to the close button: the end of the title
	// stays at 8 or more, so the close button is on the screen.
	title_width := frame.outer_width - frame.border - frame.close_size
	x, _ := dragged_window_place(0, 300, title_width - 1, 10, frame, 1280, 768)
	testing.expect(t, x + title_width >= TITLE_KEPT, "the end of the title is on the screen")
	testing.expect(t, x + title_width >= 0, "the close button is on the screen")
	// The top: never over the bar.
	_, y := dragged_window_place(300, 0, 100, 20, frame, 1280, 768)
	testing.expect_value(t, y, HEIGHT)
	// Inside the screen, the place is the nearest point of the grid.
	x, y = dragged_window_place(503, 205, 100, 12, frame, 1280, 768)
	testing.expect_value(t, x, 400)
	testing.expect_value(t, y, 192)
}

// A new window that fits keeps the place that the compositor chose; a
// window wider than the screen shows its close button; a window higher
// than the screen starts under the bar.
@(test)
new_window_places :: proc(t: ^testing.T) {
	frame := frame_of(480)
	x, y := new_window_place(64, 56, frame, 320, 1024, 768)
	testing.expect_value(t, x, 64)
	testing.expect_value(t, y, 56)
	// Near the right and the bottom: up and left until it fits.
	x, y = new_window_place(800, 600, frame, 320, 1024, 768)
	testing.expect_value(t, x, 536)
	testing.expect_value(t, y, 416)
	wide := frame_of(1500)
	x, y = new_window_place(64, 56, wide, 320, 1366, 768)
	close_right := x + wide.outer_width - wide.border
	testing.expect(t, close_right <= 1366 && close_right - wide.close_size >= 0, "the close button is on the screen")
	testing.expect(t, x %% GRID == 0, "on the grid")
	tall := frame_of(480)
	_, y = new_window_place(64, 56, tall, 900, 1024, 768)
	testing.expect_value(t, y, HEIGHT)
}
