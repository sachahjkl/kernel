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
//
// Who uses it: the kernel tool (the files of the mark: the logo, the icon of
// the site), the boot display and the programs that show the mark. The
// parts:
//
// - `heron_rows`, `parts`, `Part`: the heron as cells.
// - `mark_pixel`, `mark_draw`: the heron at a cell size.
// - `name_letters`, `name_pixel`, `name_draw`: the name.
// - `Animation`, `animation_frames`, `play_order` (`animation.odin`): the
//   idle movements.
//
// See [mark](term:mark) and (docs/DESIGN.md, "The mark").
package mark

import "support:graphics"

// The heron is a square of this many cells on each side.
HERON_GRID_SIZE :: 24

// The largest cell size that the procedures of this package accept. A larger
// cell is refused: the mark is then 0 by 0 pixels and no pixel is covered.
// The limit keeps every product of the gradient in a signed integer of 64
// bits with a wide margin (the largest is about 7 * 255 * 2 * 65536 * 1152,
// near 2.7e11), and a heron of 24 * 65536 pixels is already wider than any
// screen. The caller gives the cell size, so a program of the system can
// pass any value.
CELL_SIZE_LIMIT :: 1 << 16

// cell_size_is_accepted tells whether the procedures of this package draw at
// a cell size.
cell_size_is_accepted :: proc "contextless" (cell_size: int) -> bool {
	return cell_size > 0 && cell_size <= CELL_SIZE_LIMIT
}

// The two backgrounds of the mark: the background of the system, and a light
// background for a page of another program.
BACKGROUND_DARK :: graphics.COLOR_BACKGROUND
BACKGROUND_LIGHT :: 0xF4F6F8 // The light background: a page of the site.

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
	first_column, first_row, last_column, last_row: int, // In cells, from the top left of the heron.
}

// A part of the heron. The box is written in the table so that a pixel needs
// no scan of the rows; a host test checks each box against the rows.
Part :: struct {
	letter:         u8, // The letter of the part in the rows.
	color_on_dark:  u32, // 0xRRGGBB, on BACKGROUND_DARK.
	color_on_light: u32, // 0xRRGGBB, on BACKGROUND_LIGHT.
	flat:           bool, // One color, no gradient.
	box:            Cell_Box, // The box of the cells of the part.
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
// cell is a square of cell_size pixels. A cell size that is not accepted
// gives 0.
heron_size :: proc "contextless" (cell_size: int) -> int {
	if !cell_size_is_accepted(cell_size) {
		return 0
	}
	return HERON_GRID_SIZE * cell_size
}

// mark_pixel gives the color of the pixel (x, y) of the heron, from its top
// left corner, when a cell is a square of cell_size pixels. A pixel of an
// empty cell, or outside the heron, is not covered: the background shows.
// A cell size that is not accepted covers no pixel.
mark_pixel :: proc "contextless" (cell_size, x, y: int, on_light: bool) -> (color: u32, covered: bool) {
	if !cell_size_is_accepted(cell_size) || x < 0 || y < 0 || x >= heron_size(cell_size) || y >= heron_size(cell_size) {
		return 0, false
	}
	index, found := heron_cell_part(x / cell_size, y / cell_size)
	if !found {
		return 0, false
	}
	return part_pixel(index, cell_size, x, y, on_light), true
}

// part_pixel gives the color of the pixel (x, y) of the heron in a cell of
// the part number index: its flat color, or its gradient over the box of the
// part in the still heron. A frame of an animation colors its cells with the
// same procedure, so a cell that moves keeps the gradient of its part. The
// caller checks the cell size and keeps the pixel inside the heron.
@(private)
part_pixel :: proc "contextless" (index, cell_size, x, y: int, on_light: bool) -> u32 {
	part := parts[index]
	base := part.color_on_light if on_light else part.color_on_dark
	if part.flat {
		return base
	}
	return gradient_color(base, part.box, cell_size, x, y)
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
//
// The caller keeps the cell size within CELL_SIZE_LIMIT and the pixel inside
// the heron: the products then stay far from the limits of 64 bits.
@(private)
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
NAME_ROWS :: 7 // The rows of cells of the name.
NAME_GAP_COLUMNS :: 2 // Empty columns between two letters.

NAME_LETTER_COUNT :: 5 // The letters of "modus".

// The cells of each letter of the name, by row: '1' is a filled cell.
@(rodata)
name_letters := [NAME_LETTER_COUNT][NAME_ROWS]string {
	{".....", ".....", "11111", "1.1.1", "1.1.1", "1.1.1", "1.1.1"}, // m
	{".....", ".....", "11111", "1...1", "1...1", "1...1", "11111"}, // o
	{"....1", "....1", "11111", "1...1", "1...1", "1...1", "11111"}, // d
	{".....", ".....", "1...1", "1...1", "1...1", "1...1", "11111"}, // u
	{".....", ".....", "11111", "1....", "11111", "....1", "11111"}, // s
}

// The columns of cells of the whole name, the gaps included.
NAME_COLUMNS :: NAME_LETTER_COUNT * NAME_LETTER_COLUMNS + (NAME_LETTER_COUNT - 1) * NAME_GAP_COLUMNS

// name_size gives the width and the height in pixels of the name, when a
// cell is a square of cell_size pixels. A cell size that is not accepted
// gives 0 by 0.
name_size :: proc "contextless" (cell_size: int) -> (width, height: int) {
	if !cell_size_is_accepted(cell_size) {
		return 0, 0
	}
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
	width, height := name_size(cell_size)
	if !cell_size_is_accepted(cell_size) || x < 0 || y < 0 || x >= width || y >= height || !name_cell_is_filled(x / cell_size, y / cell_size) {
		return 0, false
	}
	return name_color(on_light), true
}

// name_color gives the color of the name: the text color on the dark
// background, the dark background color on the light one.
name_color :: proc "contextless" (on_light: bool) -> u32 {
	return BACKGROUND_DARK if on_light else graphics.COLOR_TEXT
}

// background_color gives the color of the background of the mark.
background_color :: proc "contextless" (on_light: bool) -> u32 {
	return BACKGROUND_LIGHT if on_light else BACKGROUND_DARK
}

// Where mark_draw and name_draw write: the pixels of the canvas are
// 0x00RRGGBB, or have red in the low byte, as the framebuffers of some
// machines do.
Channel_Order :: enum u8 {
	Red_In_High_Byte, // graphics.Color.
	Red_In_Low_Byte, // Blue in the high byte: a framebuffer of the format Red_Green_Blue_X.
}

// color_in_order gives a color of the form 0xRRGGBB in the order of the
// canvas.
@(private)
color_in_order :: #force_inline proc "contextless" (color: u32, order: Channel_Order) -> graphics.Color {
	if order == .Red_In_Low_Byte {
		return color >> 16 & 0xFF | color & 0xFF00 | color << 16 & 0xFF0000
	}
	return color
}

// mark_draw draws the heron into a canvas, with its top left corner at
// (x, y) of the canvas, at a cell size. It writes only the covered pixels,
// so the empty cells keep what the canvas had there. It writes nothing
// outside the canvas: a place partly or fully outside draws the part that is
// inside. A cell size that is not accepted draws nothing.
//
// The cost: one call of mark_pixel for each pixel of the heron inside the
// canvas, 576 * cell_size * cell_size at most. A call makes two integer
// divisions to find the cell, and one more for each of the three channels of
// a pixel of a gradient. A caller that draws the heron each
// frame draws it once into a picture of its own and copies that picture.
mark_draw :: proc "contextless" (canvas: graphics.Canvas, x, y, cell_size: int, on_light: bool, order := Channel_Order.Red_In_High_Byte) {
	size := heron_size(cell_size)
	first_x, first_y, last_x, last_y, inside := place_in_canvas(canvas, x, y, size, size)
	if !inside {
		return
	}
	for canvas_y in first_y ..< last_y {
		for canvas_x in first_x ..< last_x {
			if color, covered := mark_pixel(cell_size, canvas_x - x, canvas_y - y, on_light); covered {
				canvas.pixels[canvas_y * canvas.stride + canvas_x] = color_in_order(color, order)
			}
		}
	}
}

// name_draw draws the name of the mark into a canvas, with its top left
// corner at (x, y) of the canvas, at a cell size, in the same way as
// mark_draw: the covered pixels only, nothing outside the canvas.
name_draw :: proc "contextless" (canvas: graphics.Canvas, x, y, cell_size: int, on_light: bool, order := Channel_Order.Red_In_High_Byte) {
	width, height := name_size(cell_size)
	first_x, first_y, last_x, last_y, inside := place_in_canvas(canvas, x, y, width, height)
	if !inside {
		return
	}
	for canvas_y in first_y ..< last_y {
		for canvas_x in first_x ..< last_x {
			if color, covered := name_pixel(cell_size, canvas_x - x, canvas_y - y, on_light); covered {
				canvas.pixels[canvas_y * canvas.stride + canvas_x] = color_in_order(color, order)
			}
		}
	}
}

// place_in_canvas gives the part of a rectangle at (x, y) that is inside the
// canvas: the first and the last pixel (the last one is not in it). inside is
// false when no pixel of the rectangle is in the canvas. The rectangle has a
// size of at most 33 * CELL_SIZE_LIMIT pixels, so x + width does not wrap
// for an x that a screen can have; an x near the limits of int is refused.
@(private)
place_in_canvas :: proc "contextless" (canvas: graphics.Canvas, x, y, width, height: int) -> (first_x, first_y, last_x, last_y: int, inside: bool) {
	PLACE_LIMIT :: 1 << 40
	if width <= 0 || height <= 0 || canvas.pixels == nil || x < -PLACE_LIMIT || y < -PLACE_LIMIT || x > PLACE_LIMIT || y > PLACE_LIMIT {
		return 0, 0, 0, 0, false
	}
	first_x = max(x, 0)
	first_y = max(y, 0)
	last_x = min(x + width, canvas.width)
	last_y = min(y + height, canvas.height)
	return first_x, first_y, last_x, last_y, first_x < last_x && first_y < last_y
}
