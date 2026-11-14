package vector_font

import "modus:contract/glyph_cache"

// A glyph of a proportional font (docs/FONTS.md, section 12.4): not in a
// cell of the grid, but at its origin, at one of the subpixel positions of
// a pixel, and kept as the box of its ink. The size on the grid comes from
// the cap height: PROPORTIONAL_CAP_HEIGHT_ROWS rows at scale 1, so the
// capitals of the interface font stand as high as the line allows.

// The cap height at scale 1, in rows of the line of 16 (docs/FONTS.md,
// section 12.2): B612 then has an em of 13.33 pixels.
PROPORTIONAL_CAP_HEIGHT_ROWS :: 10
// The work row of one glyph: its origin at the column PLACED_ORIGIN_COLUMN,
// room on its left for ink before the origin and for the spread of the
// filter, room on its right for the widest glyph at scale 3.
PLACED_WIDTH_LIMIT :: glyph_cache.GLYPH_WIDTH_LIMIT
PLACED_ORIGIN_COLUMN :: 4
#assert(PLACED_ORIGIN_COLUMN <= glyph_cache.LEFT_LIMIT)

// Placed_Box: the box of the ink of one glyph in the work row, in pixels.
// left is from the column of the origin; a glyph with no ink has a box of 0.
Placed_Box :: struct {
	left, width:          int,
	first_row, row_count: int,
	first_column:         int, // In the work row: the column of the first word.
}

// proportional_measures gives the measures of a proportional font with
// the advance replaced by the units of the font for the width of one cell
// at scale 1: the scale that puts its cap height on PROPORTIONAL_CAP_HEIGHT_ROWS
// rows. The placement of the outlines (placement_of) and the baseline
// (glyph_style_of) then work as for a monospace font.
//
// The cap height and the x-height are those that the font states in its
// table OS/2 (version 2 and later), when they are plausible: the top of
// the outline of "H" and of "x" is not always the flat top of the letters.
// In B612 the stems of "H" end with an angle at 1520 units, while E, T and
// Z end flat at 1500, the stated cap height. The flat tops are the ones
// that must sit on whole rows. A font with no such values keeps the tops of
// the outlines.
proportional_measures :: proc "contextless" (font: ^Font_File, measures: Font_Measures) -> (placed: Font_Measures, problem: Font_Problem) {
	placed = measures
	stated_x_height, stated_cap_height := stated_heights(font)
	if stated_x_height > 0 && stated_cap_height > stated_x_height && stated_cap_height <= measures.top {
		placed.x_height = stated_x_height
		placed.cap_height = stated_cap_height
	}
	placed.advance = int(divide_rounded(i64(placed.cap_height) * 8, PROPORTIONAL_CAP_HEIGHT_ROWS))
	if placed.advance <= 0 {
		return placed, .Unknown_Format
	}
	return placed, .None
}

// stated_heights reads sxHeight and sCapHeight of the table OS/2: 0 and 0
// when the table is absent, shorter than its version 2, or of version 0
// or 1, which do not have them. Each read is checked against the table.
stated_heights :: proc "contextless" (font: ^Font_File) -> (x_height, cap_height: int) {
	if font.os2.length == 0 || font.os2.offset < 0 || font.os2.offset + font.os2.length > len(font.bytes) {
		return 0, 0
	}
	table := font.bytes[font.os2.offset:][:font.os2.length]
	version := read_u16(table, 0) or_else 0
	if version < 2 {
		return 0, 0
	}
	return read_i16(table, 86) or_else 0, read_i16(table, 88) or_else 0
}

// glyph_render_placed draws the glyph of one character with its origin at
// position / position_count of a pixel right of the column
// PLACED_ORIGIN_COLUMN, into memory.placed (PLACED_WIDTH_LIMIT words for
// each row of the line), and gives the box of its ink. The words of the
// box are row first_row + r, columns first_column ..< first_column + width.
// A glyph whose ink reaches a side of the work row is refused: it does not
// fit in the limits of the cache.
glyph_render_placed :: proc "contextless" (font: ^Font_File, measures: Font_Measures, style: Glyph_Style, character: rune, position, position_count: int, memory: ^Render_Memory) -> (box: Placed_Box, problem: Font_Problem) {
	width, height := PLACED_WIDTH_LIMIT, style.cell_height
	if height < 1 || height > CELL_HEIGHT_LIMIT || position_count < 1 || position_count > glyph_cache.POSITION_LIMIT || position < 0 || position >= position_count {
		return {}, .Too_Many_Points
	}
	pixels := memory.placed[:width * height]
	for &pixel in pixels {
		pixel = 0
	}
	glyph := glyph_of(font, character) or_return
	outline := Outline{points = memory.points[:], contour_ends = memory.contours[:]}
	glyph_outline(font, glyph, &outline) or_return
	row_length := 3 * width + 2 * STRIPE_MARGIN
	target, ok := accumulation_of(memory.cells[:], row_length, height)
	if !ok {
		return {}, .Too_Many_Points
	}
	placement := placement_of(measures, style, true)
	// The origin in thirds of a pixel: the column of the origin, then the
	// position (one third for each step with three positions).
	placement.origin_x += i64(3 * PLACED_ORIGIN_COLUMN) * SUBUNITS_PER_PIXEL + i64(3 * position) * SUBUNITS_PER_PIXEL / i64(position_count)
	outline_add(&target, &outline, &placement)
	coverage_finish(&target, memory.thirds[:])
	first_row, last_row := height, -1
	first_column, last_column := width, -1
	for row in 0 ..< height {
		thirds := memory.thirds[row * row_length:][:row_length]
		stripes_filter(thirds, memory.filtered[:row_length], style.filter)
		for column in 0 ..< width {
			at := STRIPE_MARGIN + 3 * column
			red, green, blue := u32(memory.filtered[at]), u32(memory.filtered[at + 1]), u32(memory.filtered[at + 2])
			gray := (u32(thirds[at]) + u32(thirds[at + 1]) + u32(thirds[at + 2]) + 1) / 3
			word := gray << 24 | red << 16 | green << 8 | blue
			pixels[row * width + column] = word
			if word != 0 {
				first_row = min(first_row, row)
				last_row = max(last_row, row)
				first_column = min(first_column, column)
				last_column = max(last_column, column)
			}
		}
	}
	if last_row < 0 {
		return {}, .None // No ink: a space.
	}
	if first_column == 0 || last_column == width - 1 {
		return {}, .Unknown_Format
	}
	return {left = first_column - PLACED_ORIGIN_COLUMN, width = last_column - first_column + 1, first_row = first_row, row_count = last_row - first_row + 1, first_column = first_column}, .None
}

// units_to_subpixels gives a length of the font in 1/64 of a pixel at one
// scale: units * 8 * scale / units_per_cell pixels, rounded to the nearest
// integer, a half up, toward plus infinity (divide_rounded): -42.5 gives
// -42, 42.5 gives 43. A negative pair adjustment is rounded by the same
// rule as a positive one, not toward 0: -42.67 gives -43.
@(private)
units_to_subpixels :: proc "contextless" (units, scale, units_per_cell: int) -> i32 {
	return i32(divide_rounded(i64(units) * i64(8 * scale * glyph_cache.SUBPIXEL), i64(units_per_cell)))
}
