#+build !freestanding
package mark

import "core:testing"
import "support:graphics"

// The box of each part in the table is the box of its letter in the rows,
// and each letter of the rows has a part.
@(test)
box_of_each_part_is_the_box_of_its_cells :: proc(t: ^testing.T) {
	for part in parts {
		box := Cell_Box{HERON_GRID_SIZE, HERON_GRID_SIZE, -1, -1}
		for row in 0 ..< HERON_GRID_SIZE {
			for column in 0 ..< HERON_GRID_SIZE {
				if heron_rows[row][column] == part.letter {
					box.first_column = min(box.first_column, column)
					box.first_row = min(box.first_row, row)
					box.last_column = max(box.last_column, column)
					box.last_row = max(box.last_row, row)
				}
			}
		}
		testing.expectf(t, box == part.box, "the part %c has the box %v in the rows, %v in the table", part.letter, box, part.box)
	}
	for row in heron_rows {
		testing.expect_value(t, len(row), HERON_GRID_SIZE)
		for index in 0 ..< len(row) {
			_, found := part_of_letter(row[index])
			testing.expectf(t, row[index] == '.' || found, "the letter %c of the rows has no part", row[index])
		}
	}
}

// Pixels pinned to the colors of the formula: the first and the last pixel
// of the body at cell sizes 1 and 24, the neck on both backgrounds, the eye,
// an empty cell and a pixel outside the heron.
@(test)
pinned_pixels :: proc(t: ^testing.T) {
	Pinned :: struct {
		cell_size, x, y: int,
		on_light:        bool,
		color:           u32,
		covered:         bool,
	}
	pinned := [?]Pinned {
		{1, 6, 11, false, 0x72ACE7, true}, // The first pixel of the body.
		{1, 14, 15, false, 0x427BB6, true}, // The last pixel of the body.
		{24, 144, 264, false, 0x76AFEA, true}, // The first pixel of the body, large.
		{24, 359, 383, false, 0x3E78B2, true}, // The last pixel of the body, large.
		{1, 15, 1, false, 0xDEE3E9, true}, // The first pixel of the neck.
		{1, 15, 1, true, 0xB3C0D0, true}, // The same pixel on the light background.
		{1, 17, 2, false, BACKGROUND_DARK, true}, // The eye.
		{8, 17 * 8 + 3, 2 * 8 + 5, true, BACKGROUND_DARK, true}, // The eye, on the light background.
		{1, 0, 1, false, 0, false}, // An empty cell.
		{4, 24 * 4, 0, false, 0, false}, // Outside the heron.
		{0, 0, 0, false, 0, false}, // No cell size.
	}
	for pinned_pixel in pinned {
		color, covered := mark_pixel(pinned_pixel.cell_size, pinned_pixel.x, pinned_pixel.y, pinned_pixel.on_light)
		testing.expectf(t, covered == pinned_pixel.covered && color == pinned_pixel.color, "pixel %v: 0x%06X covered %v", pinned_pixel, color, covered)
	}
	// The two ends of the gradient of the body: 30 % toward white at the
	// start, 30 % toward black at the end.
	testing.expect_value(t, gradient_color(0x4A9CF0, Cell_Box{0, 0, 0, 0}, 1000, 0, 0), u32(0x80BAF4))
	testing.expect_value(t, gradient_color(0x4A9CF0, Cell_Box{0, 0, 0, 0}, 1000, 999, 999), u32(0x346DA8))
}

// At cell size 1, a pixel is covered exactly where the rows have a cell.
@(test)
cell_size_one_has_the_cells_of_the_rows :: proc(t: ^testing.T) {
	for y in 0 ..< HERON_GRID_SIZE {
		for x in 0 ..< HERON_GRID_SIZE {
			_, covered := mark_pixel(1, x, y, false)
			testing.expectf(t, covered == (heron_rows[y][x] != '.'), "cell %d, %d", x, y)
		}
	}
}

// Two calls give the same colors: the arithmetic has no state.
@(test)
two_calls_give_the_same_pixels :: proc(t: ^testing.T) {
	CELL :: 8
	backgrounds := [2]bool{false, true} // Dark, then light.
	for on_light in backgrounds {
		for y in 0 ..< heron_size(CELL) {
			for x in 0 ..< heron_size(CELL) {
				first_color, first_covered := mark_pixel(CELL, x, y, on_light)
				second_color, second_covered := mark_pixel(CELL, x, y, on_light)
				if first_color != second_color || first_covered != second_covered {
					testing.expectf(t, false, "pixel %d, %d differs between two calls", x, y)
					return
				}
			}
		}
	}
}

// The name has 33 columns and 7 rows; the d has its stem in the two top
// rows, the other letters do not; the gaps are empty.
@(test)
name_cells :: proc(t: ^testing.T) {
	width, height := name_size(10)
	testing.expect_value(t, width, 330)
	testing.expect_value(t, height, 70)
	testing.expect(t, name_cell_is_filled(2 * 7 + 4, 0)) // The stem of the d.
	testing.expect(t, !name_cell_is_filled(0, 0))
	testing.expect(t, name_cell_is_filled(0, 2)) // The top left of the m.
	testing.expect(t, !name_cell_is_filled(5, 2)) // A gap.
	testing.expect(t, !name_cell_is_filled(6, 2)) // A gap.
	testing.expect(t, name_cell_is_filled(32, 6)) // The bottom right of the s.
	testing.expect(t, !name_cell_is_filled(NAME_COLUMNS, 6))
	color, covered := name_pixel(10, 0, 20, true)
	testing.expect(t, covered && color == BACKGROUND_DARK)
	color, covered = name_pixel(10, 0, 20, false)
	testing.expect(t, covered && color == 0xDCE4EC)
}

// A cell size above the limit covers no pixel and has no size; the old form
// trapped on a division by zero at a cell size of 1 << 52. A pixel past the
// picture is not covered. The limit itself draws.
@(test)
cell_sizes_and_places_out_of_range :: proc(t: ^testing.T) {
	_, covered := mark_pixel(1 << 52, 14 << 52, 0, false)
	testing.expect(t, !covered)
	_, covered = mark_pixel(CELL_SIZE_LIMIT + 1, 14 * (CELL_SIZE_LIMIT + 1), 0, false)
	testing.expect(t, !covered)
	_, covered = mark_pixel(max(int), 0, 0, false)
	testing.expect(t, !covered)
	_, covered = mark_pixel(-3, 14, 0, false)
	testing.expect(t, !covered)
	testing.expect_value(t, heron_size(CELL_SIZE_LIMIT + 1), 0)
	testing.expect_value(t, heron_size(max(int)), 0)
	testing.expect_value(t, heron_size(CELL_SIZE_LIMIT), HERON_GRID_SIZE * CELL_SIZE_LIMIT)
	width, height := name_size(CELL_SIZE_LIMIT + 1)
	testing.expect(t, width == 0 && height == 0)
	width, height = name_size(max(int))
	testing.expect(t, width == 0 && height == 0)
	_, covered = name_pixel(CELL_SIZE_LIMIT + 1, 0, 2 * (CELL_SIZE_LIMIT + 1), false)
	testing.expect(t, !covered)
	// The last pixel of the body at the largest cell size: covered, with the
	// color of the formula (computed apart; 0x3E78B2 at a cell size of 24).
	color: u32
	color, covered = mark_pixel(CELL_SIZE_LIMIT, 15 * CELL_SIZE_LIMIT - 1, 16 * CELL_SIZE_LIMIT - 1, false)
	testing.expect(t, covered)
	testing.expect_value(t, color, u32(0x3E77B2))
	// Past the right and the bottom of the heron and of the name.
	_, covered = mark_pixel(1, HERON_GRID_SIZE, 0, false)
	testing.expect(t, !covered)
	_, covered = mark_pixel(1, 0, HERON_GRID_SIZE, false)
	testing.expect(t, !covered)
	_, covered = mark_pixel(2, 2 * HERON_GRID_SIZE, 2 * 11, false)
	testing.expect(t, !covered)
	_, covered = name_pixel(1, NAME_COLUMNS, 6, false)
	testing.expect(t, !covered)
	_, covered = name_pixel(1, 32, NAME_ROWS, false)
	testing.expect(t, !covered)
	_, covered = name_pixel(1, max(int), max(int), false)
	testing.expect(t, !covered)
}

DRAW_TEST_SENTINEL :: graphics.Color(0xABCDEF) // No pixel of the mark has this color.

// mark_draw writes exactly the colors of mark_pixel at the covered pixels,
// and leaves every other pixel as it was.
@(test)
mark_draw_writes_the_pixels_of_mark_pixel :: proc(t: ^testing.T) {
	SIDE :: 64
	buffer: [SIDE * SIDE]graphics.Color
	backgrounds := [2]bool{false, true}
	for on_light in backgrounds {
		for &pixel in buffer {
			pixel = DRAW_TEST_SENTINEL
		}
		canvas := graphics.Canvas{pixels = raw_data(buffer[:]), width = SIDE, height = SIDE, stride = SIDE}
		LEFT :: 5
		TOP :: 7
		mark_draw(canvas, LEFT, TOP, 2, on_light)
		for y in 0 ..< SIDE {
			for x in 0 ..< SIDE {
				expected := DRAW_TEST_SENTINEL
				if color, covered := mark_pixel(2, x - LEFT, y - TOP, on_light); covered {
					expected = color
				}
				if buffer[y * SIDE + x] != expected {
					testing.expectf(t, false, "pixel %d, %d: 0x%06X, not 0x%06X", x, y, buffer[y * SIDE + x], expected)
					return
				}
			}
		}
	}
}

// A heron and a name partly outside a canvas: the canvas is a view inside a
// larger buffer, and no pixel of the buffer outside the view changes.
@(test)
a_place_partly_outside_writes_nothing_outside :: proc(t: ^testing.T) {
	SIDE :: 80
	VIEW_LEFT :: 16
	VIEW_TOP :: 16
	VIEW_SIDE :: 40
	buffer: [SIDE * SIDE]graphics.Color
	Place :: struct {
		x, y:      int,
		with_name: bool,
	}
	places := [?]Place{{-10, 20, false}, {20, -30, false}, {-47, -47, false}, {39, 39, false}, {-100, 0, false}, {-20, 30, true}, {30, -5, true}}
	for place in places {
		for &pixel in buffer {
			pixel = DRAW_TEST_SENTINEL
		}
		view := graphics.Canvas{pixels = ([^]graphics.Color)(&buffer[VIEW_TOP * SIDE + VIEW_LEFT]), width = VIEW_SIDE, height = VIEW_SIDE, stride = SIDE}
		if place.with_name {
			name_draw(view, place.x, place.y, 2, false)
		} else {
			mark_draw(view, place.x, place.y, 2, false)
		}
		for y in 0 ..< SIDE {
			for x in 0 ..< SIDE {
				expected := DRAW_TEST_SENTINEL
				in_view := x >= VIEW_LEFT && x < VIEW_LEFT + VIEW_SIDE && y >= VIEW_TOP && y < VIEW_TOP + VIEW_SIDE
				if in_view {
					view_x, view_y := x - VIEW_LEFT - place.x, y - VIEW_TOP - place.y
					color: u32
					covered: bool
					if place.with_name {
						color, covered = name_pixel(2, view_x, view_y, false)
					} else {
						color, covered = mark_pixel(2, view_x, view_y, false)
					}
					if covered {
						expected = color
					}
				}
				if buffer[y * SIDE + x] != expected {
					testing.expectf(t, false, "place %v, pixel %d, %d of the buffer: 0x%06X, not 0x%06X", place, x, y, buffer[y * SIDE + x], expected)
					return
				}
			}
		}
	}
	// A cell size that is not accepted, and a place far outside: nothing.
	for &pixel in buffer {
		pixel = DRAW_TEST_SENTINEL
	}
	whole := graphics.Canvas{pixels = raw_data(buffer[:]), width = SIDE, height = SIDE, stride = SIDE}
	mark_draw(whole, 0, 0, CELL_SIZE_LIMIT + 1, false)
	mark_draw(whole, 0, 0, 0, false)
	mark_draw(whole, min(int), min(int), 1, false)
	mark_draw(whole, max(int) - 10, 0, 1, false)
	name_draw(whole, max(int) - 10, max(int) - 10, 1, false)
	for pixel in buffer {
		if pixel != DRAW_TEST_SENTINEL {
			testing.expect(t, false, "a refused draw wrote a pixel")
			return
		}
	}
}

// With red in the low byte, the channels of each pixel are in the other
// order.
@(test)
mark_draw_with_red_in_the_low_byte :: proc(t: ^testing.T) {
	buffer: [HERON_GRID_SIZE * HERON_GRID_SIZE]graphics.Color
	canvas := graphics.Canvas{pixels = raw_data(buffer[:]), width = HERON_GRID_SIZE, height = HERON_GRID_SIZE, stride = HERON_GRID_SIZE}
	mark_draw(canvas, 0, 0, 1, false, .Red_In_Low_Byte)
	// The first pixel of the body (6, 11) is 0x72ACE7.
	testing.expect_value(t, buffer[11 * HERON_GRID_SIZE + 6], graphics.Color(0xE7AC72))
}
