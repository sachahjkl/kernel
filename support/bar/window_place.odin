package bar

// The places of the windows on the screen. The compositor moves the windows;
// these procedures hold no state, so a host test checks each edge.
//
// A window is on the grid of GRID pixels. Wherever a person puts it, a part
// of its title stays on the screen: the person can always take it again,
// and bring its close button back. Without that part, a window that went
// past an edge could never come back: the menu of the windows only brings
// a window to the front.

GRID :: 8 // docs/DESIGN.md, section 6.
TITLE_KEPT :: GRID // The pixels of the title that stay on the screen, at least.

// The frame of a window, around its surface: the compositor draws it.
Window_Frame :: struct {
	outer_width:  int, // The surface and the two borders.
	border:       int,
	close_size:   int, // The close button, at the right end of the title.
	title_height: int,
}

grid_floor :: proc "contextless" (place: int) -> int {
	return place - place %% GRID
}

grid_ceiling :: proc "contextless" (place: int) -> int {
	return -grid_floor(-place)
}

// window_place_kept gives the place nearest to (x, y), on the grid, where
// TITLE_KEPT pixels of the title are on the screen, under the bar:
//   - at the left, the end of the title (before the close button) is at
//     TITLE_KEPT or more, so the close button is on the screen too;
//   - at the right, the start of the title is TITLE_KEPT before the edge;
//   - at the top, the title is under the bar;
//   - at the bottom, TITLE_KEPT lines of the title are on the screen.
// On a screen too small for two bounds, the bound of the left or of the top
// wins: the start of the title stays on the screen.
window_place_kept :: proc "contextless" (x, y: int, frame: Window_Frame, screen_width, screen_height: int) -> (kept_x, kept_y: int) {
	title_width := max(frame.outer_width - frame.border - frame.close_size, 0)
	left_bound := grid_ceiling(TITLE_KEPT - title_width)
	right_bound := grid_floor(screen_width - TITLE_KEPT)
	top_bound := HEIGHT // The bar is on the grid: HEIGHT is a multiple of GRID.
	bottom_bound := grid_floor(screen_height - TITLE_KEPT)
	kept_x = max(min(grid_floor(x), right_bound), left_bound)
	kept_y = max(min(grid_floor(y), bottom_bound), top_bound)
	return
}

// dragged_window_place gives the place of a window that a person drags: the
// pointer is at (pointer_x, pointer_y) and holds the window at (held_x,
// held_y) from its corner. The place is the nearest point of the grid, then
// kept on the screen.
dragged_window_place :: proc "contextless" (pointer_x, pointer_y, held_x, held_y: int, frame: Window_Frame, screen_width, screen_height: int) -> (x, y: int) {
	return window_place_kept(pointer_x - held_x + GRID / 2, pointer_y - held_y + GRID / 2, frame, screen_width, screen_height)
}

// new_window_place gives the place of a new window from the place that the
// compositor chose for it: the whole window on the screen when it fits.
// A window wider than the screen puts the right end of its title at the
// right of the screen: its close button is on the screen at once, and a
// drag shows its left part. A window higher than the screen starts under
// the bar.
new_window_place :: proc "contextless" (x, y: int, frame: Window_Frame, surface_height, screen_width, screen_height: int) -> (placed_x, placed_y: int) {
	placed_x = max(grid_floor(min(x, screen_width - frame.outer_width)), 0)
	if frame.outer_width > screen_width {
		placed_x = grid_floor(screen_width - frame.outer_width)
	}
	outer_height := surface_height + frame.title_height + frame.border
	placed_y = max(grid_floor(min(y, screen_height - outer_height)), HEIGHT)
	return window_place_kept(placed_x, placed_y, frame, screen_width, screen_height)
}
