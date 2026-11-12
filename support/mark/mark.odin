// The mark of the system (docs/DESIGN.md, section "The mark"), as data: a
// heron drawn on a grid of 24 by 24 square cells, and the name "modus" in
// letters of square cells. The kernel tool writes the files of the mark from
// this package, and a program of the system can draw the mark from the same
// data. Pure code: no kernel operation, no allocation, so the kernel tool
// tests it on the host.
//
// Each part of the heron (all the cells of one letter of the rows) is filled
// with one linear gradient: from the top left corner of the box of the part,
// where the color is moved 30 % toward white, to the bottom right corner,
// where it is moved 30 % toward black. The eye is one flat color.
package mark

import "support:graphics"

// The heron is a square of this many cells on each side.
HERON_GRID_SIZE :: 24

// The two backgrounds of the mark: the background of the system, and a light
// background for a page of another program.
BACKGROUND_DARK :: graphics.COLOR_BACKGROUND
BACKGROUND_LIGHT :: 0xF4F6F8

// The heron, one string for each row of cells, from the top. A "." is an
// empty cell; each other letter is a part.
@(rodata)
heron_rows := [HERON_GRID_SIZE]string {
	"..............vv........",
	"...............hhhh.....",
	"..............hhhkhyyyyy",
	"...............hhhhyyy..",
	"...............hh.......",
	"...............hh.......",
	"..............hh........",
	".............hh.........",
	".............hh.........",
	"..............hh........",
	"..............hhh.......",
	"......bbbbbbbbbhh.......",
	"....bbbbbbbbbbbbh.......",
	"..vvbbbddddddbbbb.......",
	".vvvbbbbddddbbbb........",
	"vvv..bbbbbbbbbb.........",
	".........o..o...........",
	".........o..o...........",
	".........o...o..........",
	".........o....o.........",
	".........o...o..........",
	".........o..o...........",
	"..tttttttooottttttt.....",
	".....ttttttttttttttt....",
}

// The box of a part: its first and last column and row of cells, all
// inclusive. The gradient of the part goes from the top left corner of the
// box to its bottom right corner.
Cell_Box :: struct {
	first_column, first_row, last_column, last_row: int,
}

// A part of the heron. The box is written in the table so that a pixel needs
// no scan of the rows; a host test checks each box against the rows.
Part :: struct {
	letter:         u8,
	color_on_dark:  u32, // 0xRRGGBB, on BACKGROUND_DARK.
	color_on_light: u32, // 0xRRGGBB, on BACKGROUND_LIGHT.
	flat:           bool, // One color, no gradient.
	box:            Cell_Box,
}

// The pale neck is darker on a light background, so that it stays visible
// there. The eye has the color of the dark background on both.
@(rodata)
parts := [?]Part {
	{letter = 'v', color_on_dark = graphics.COLOR_FIRMWARE, color_on_light = graphics.COLOR_FIRMWARE, box = {0, 0, 15, 15}}, // The crest and the tail: one part.
	{letter = 'h', color_on_dark = graphics.COLOR_TEXT, color_on_light = 0x9FB2C8, box = {13, 1, 18, 12}}, // The head and the neck.
	{letter = 'k', color_on_dark = BACKGROUND_DARK, color_on_light = BACKGROUND_DARK, flat = true, box = {17, 2, 17, 2}}, // The eye.
	{letter = 'y', color_on_dark = graphics.COLOR_BOOT_PROGRAM, color_on_light = graphics.COLOR_BOOT_PROGRAM, box = {19, 2, 23, 3}}, // The beak.
	{letter = 'b', color_on_dark = graphics.COLOR_KERNEL, color_on_light = graphics.COLOR_KERNEL, box = {4, 11, 16, 15}}, // The body.
	{letter = 'd', color_on_dark = 0x2F6FC0, color_on_light = 0x2F6FC0, box = {7, 13, 12, 14}}, // The wing.
	{letter = 'o', color_on_dark = graphics.COLOR_BOOT_PROGRAM, color_on_light = graphics.COLOR_BOOT_PROGRAM, box = {9, 16, 14, 22}}, // The legs.
	{letter = 't', color_on_dark = graphics.COLOR_MEMORY, color_on_light = graphics.COLOR_MEMORY, box = {2, 22, 19, 23}}, // The water.
}

// part_of_letter gives the index in `parts` of the part of a letter of the
// rows. A "." or an unknown letter has no part.
part_of_letter :: proc "contextless" (letter: u8) -> (index: int, found: bool) {
	for part, part_index in parts {
		if part.letter == letter {
			return part_index, true
		}
	}
	return 0, false
}

// heron_cell_part gives the part of one cell of the heron. An empty cell, or
// a cell outside the grid, has no part.
heron_cell_part :: proc "contextless" (column, row: int) -> (index: int, found: bool) {
	if column < 0 || row < 0 || column >= HERON_GRID_SIZE || row >= HERON_GRID_SIZE {
		return 0, false
	}
	return part_of_letter(heron_rows[row][column])
}

// heron_size gives the width and the height in pixels of the heron, when a
// cell is a square of cell_size pixels.
heron_size :: proc "contextless" (cell_size: int) -> int {
	return HERON_GRID_SIZE * cell_size
}

// mark_pixel gives the color of the pixel (x, y) of the heron, from its top
// left corner, when a cell is a square of cell_size pixels. A pixel of an
// empty cell, or outside the heron, is not covered: the background shows.
mark_pixel :: proc "contextless" (cell_size, x, y: int, on_light: bool) -> (color: u32, covered: bool) {
	if cell_size <= 0 || x < 0 || y < 0 {
		return 0, false
	}
	index, found := heron_cell_part(x / cell_size, y / cell_size)
	if !found {
		return 0, false
	}
	part := parts[index]
	base := part.color_on_light if on_light else part.color_on_dark
	if part.flat {
		return base, true
	}
	return gradient_color(base, part.box, cell_size, x, y), true
}

// gradient_color gives the color of a linear gradient at the centre of the
// pixel (x, y). The start of the gradient is the top left corner of the box
// and its end is the bottom right corner. The centre of the pixel is
// projected on the line from the start to the end: the share t of the way is
// 0 at the start and 1 at the end, and outside them it stays at the nearer
// end.
//
// At the start a channel c is c + (255 - c) * 0.3, at the end it is c * 0.7,
// so at t it is 0.7 * c + 76.5 * (1 - t). The arithmetic is in integers, so
// that every machine gives the same bytes: the positions are counted in half
// pixels (the centre of a pixel is at 2 * x + 1), t is the fraction N / D,
// and each channel is (7 * c * D + 765 * (D - N)) / (10 * D): the formula
// multiplied by ten above and below the line, so that 0.7 and 76.5 are
// whole. The quotient is rounded to the nearest whole value (a half goes
// up). That is the exact value of the formula; a gradient in floats of 32
// bits gives the same value or a value one unit apart.
gradient_color :: proc "contextless" (base: u32, box: Cell_Box, cell_size, x, y: int) -> u32 {
	// The direction of the gradient, in cells.
	direction_x := i64(box.last_column + 1 - box.first_column)
	direction_y := i64(box.last_row + 1 - box.first_row)
	// The centre of the pixel from the start of the gradient, in half pixels.
	from_start_x := i64(2 * x + 1) - i64(2 * cell_size * box.first_column)
	from_start_y := i64(2 * y + 1) - i64(2 * cell_size * box.first_row)
	// t = numerator / denominator; the factor 2 * cell_size turns the
	// direction in cells into half pixels.
	numerator := from_start_x * direction_x + from_start_y * direction_y
	denominator := 2 * i64(cell_size) * (direction_x * direction_x + direction_y * direction_y)
	numerator = clamp(numerator, 0, denominator)
	color: u32
	channel_shifts := [3]u32{16, 8, 0} // Red, green, blue.
	for shift in channel_shifts {
		channel := i64((base >> shift) & 0xFF)
		value_numerator := 7 * channel * denominator + 765 * (denominator - numerator)
		value_denominator := 10 * denominator
		rounded := (2 * value_numerator + value_denominator) / (2 * value_denominator)
		color |= u32(clamp(rounded, 0, 255)) << shift
	}
	return color
}

// The letters of the name, each on a grid of 5 columns and 7 rows of cells.
// The two rows at the top are for the stem of the d; the other letters start
// on the third row.
NAME_LETTER_COLUMNS :: 5
NAME_ROWS :: 7
NAME_GAP_COLUMNS :: 2 // Empty columns between two letters.

NAME_LETTER_COUNT :: 5

@(rodata)
name_letters := [NAME_LETTER_COUNT][NAME_ROWS]string {
	{".....", ".....", "11111", "1.1.1", "1.1.1", "1.1.1", "1.1.1"}, // m
	{".....", ".....", "11111", "1...1", "1...1", "1...1", "11111"}, // o
	{"....1", "....1", "11111", "1...1", "1...1", "1...1", "11111"}, // d
	{".....", ".....", "1...1", "1...1", "1...1", "1...1", "11111"}, // u
	{".....", ".....", "11111", "1....", "11111", "....1", "11111"}, // s
}

NAME_COLUMNS :: NAME_LETTER_COUNT * NAME_LETTER_COLUMNS + (NAME_LETTER_COUNT - 1) * NAME_GAP_COLUMNS

// name_size gives the width and the height in pixels of the name, when a
// cell is a square of cell_size pixels.
name_size :: proc "contextless" (cell_size: int) -> (width, height: int) {
	return NAME_COLUMNS * cell_size, NAME_ROWS * cell_size
}

// name_cell_is_filled tells whether the cell (column, row) of the name is
// filled. The columns count across all the letters and the gaps.
name_cell_is_filled :: proc "contextless" (column, row: int) -> bool {
	if column < 0 || row < 0 || column >= NAME_COLUMNS || row >= NAME_ROWS {
		return false
	}
	letter := column / (NAME_LETTER_COLUMNS + NAME_GAP_COLUMNS)
	column_in_letter := column % (NAME_LETTER_COLUMNS + NAME_GAP_COLUMNS)
	if column_in_letter >= NAME_LETTER_COLUMNS {
		return false
	}
	return name_letters[letter][row][column_in_letter] == '1'
}

// name_pixel gives whether the pixel (x, y) of the name, from its top left
// corner, is covered, and its color. The name is one flat color: the text
// color on the dark background, the dark background color on the light one.
name_pixel :: proc "contextless" (cell_size, x, y: int, on_light: bool) -> (color: u32, covered: bool) {
	if cell_size <= 0 || x < 0 || y < 0 || !name_cell_is_filled(x / cell_size, y / cell_size) {
		return 0, false
	}
	return name_color(on_light), true
}

name_color :: proc "contextless" (on_light: bool) -> u32 {
	return BACKGROUND_DARK if on_light else graphics.COLOR_TEXT
}

// background_color gives the color of the background of the mark.
background_color :: proc "contextless" (on_light: bool) -> u32 {
	return BACKGROUND_LIGHT if on_light else BACKGROUND_DARK
}
