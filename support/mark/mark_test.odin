#+build !freestanding
package mark

import "core:testing"

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
