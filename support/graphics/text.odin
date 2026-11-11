package graphics

import "contract:glyph_cache"

// The text of the system (docs/FONTS.md). Two fonts draw on one grid of
// cells of 8 x 16 pixels at scale 1 (16 x 32, 24 x 48 at the scales 2 and
// 3): the vector font, from a glyph cache that the root service maps for
// the program, and Spleen 8x16 (font.odin), the fallback and the other
// value of the setting. A program calls text, character and text_scaled;
// it does not know which font draws.
//
// The state is in this package, one for the program, and changes only
// through text_cache_set and text_choice_set (support/display calls them
// at the start of a window and at a change of the setting, between two
// frames). The zero state draws with Spleen: no cache yet.

// The fonts of the setting "font". Zero is the default (ZII): the vector font.
Text_Font :: enum u8 {
	Vector,
	Spleen,
}

// The order of the color stripes of the pixels of the screen: the setting
// "subpixel_order". None draws the vector font in grayscale.
Subpixel_Order :: enum u8 {
	Red_Green_Blue,
	Blue_Green_Red,
	None,
}

Text_State :: struct {
	font:        Text_Font,
	order:       Subpixel_Order,
	has_cache:   bool,
	cache:       glyph_cache.Cache,
	// The blend in linear light: square_root[i] is the 8-bit value whose
	// square is nearest to (4096 i + 2048) / 255 (docs/FONTS.md, "Gamma").
	square_root: [4096]u8,
}

text_state: Text_State

// text_cache_set validates a glyph cache once and makes it the cache of the
// vector font. A refused cache leaves the program with Spleen; the problem
// is a value for the log of the caller.
text_cache_set :: proc "contextless" (bytes: []u8) -> glyph_cache.Problem {
	cache, problem := glyph_cache.validate(bytes)
	if problem.kind != .None {
		text_state.has_cache = false
		return problem
	}
	text_state.cache = cache
	text_state.has_cache = true
	if text_state.square_root[4095] == 0 {
		square_root_table_fill(&text_state.square_root)
	}
	return {}
}

// square_root_table_fill makes the table of the blend in linear light:
// entry i is the 8-bit value whose square is nearest to the middle of the
// sums d * d * (255 - a) + c * c * a that shift to i: (4096 i + 2048) / 255.
// In units of 1/255 to stay in integers: the square of r times 255 against
// 4096 i + 2048.
square_root_table_fill :: proc "contextless" (table: ^[4096]u8) {
	root := 0
	for &value, index in table {
		target := 4096 * index + 2048
		for root < 255 && (root + 1) * (root + 1) * 255 <= target {
			root += 1
		}
		below := target - root * root * 255
		above := (root + 1) * (root + 1) * 255 - target
		value = u8(min(below > above ? root + 1 : root, 255))
	}
}

// text_choice_set sets the font and the order of the stripes.
text_choice_set :: proc "contextless" (font: Text_Font, order: Subpixel_Order) {
	text_state.font = font
	text_state.order = order
}

// text_vector_drawn says if text is drawn with the vector font now.
text_vector_drawn :: #force_inline proc "contextless" () -> bool {
	return text_state.font == .Vector && text_state.has_cache
}

// text draws characters from (x, y), the top left corner of the first cell,
// at scale 1. It gives the x after the last character.
text :: proc "contextless" (canvas: Canvas, x, y: int, characters: string, color: Color) -> int {
	if !text_vector_drawn() {
		at := x
		for index in 0 ..< len(characters) {
			character_spleen(canvas, at, y, characters[index], color)
			at += CELL_WIDTH
		}
		return at
	}
	return text_scaled(canvas, x, y, characters, color, 1)
}

// character draws one character in the cell at (x, y), at scale 1.
character :: proc "contextless" (canvas: Canvas, x, y: int, value: u8, color: Color) {
	if text_vector_drawn() {
		character_vector(canvas, x, y, value, color, 1)
	} else {
		character_spleen(canvas, x, y, value, color)
	}
}

// text_scaled draws characters in cells of scale times the size of a cell:
// 1, 2 or 3 (docs/DESIGN.md, section 5). The vector font draws each size
// from its outline; Spleen draws each of its pixels as a square of scale
// pixels. It gives the x after the last character.
text_scaled :: proc "contextless" (canvas: Canvas, x, y: int, characters: string, color: Color, scale_asked: int) -> int {
	scale := clamp(scale_asked, 1, 3)
	advance := CELL_WIDTH * scale
	at := x
	vector := text_vector_drawn()
	for index in 0 ..< len(characters) {
		if at >= canvas.width {
			break
		}
		if at + advance > 0 {
			switch {
			case vector:
				character_vector(canvas, at, y, characters[index], color, scale)
			case scale == 1:
				character_spleen(canvas, at, y, characters[index], color)
			case:
				character_spleen_enlarged(canvas, at, y, characters[index], color, scale)
			}
		}
		at += advance
	}
	return x + advance * len(characters)
}

text_width :: proc "contextless" (characters: string) -> int {
	return len(characters) * CELL_WIDTH
}

// character_vector draws one character of the glyph cache: each word of the
// glyph blends the color over the pixel of the canvas, one coverage for
// each channel.
character_vector :: #force_inline proc "contextless" (canvas: Canvas, x, y: int, value: u8, color: Color, scale: int) {
	character_vector_with(&text_state.cache, &text_state.square_root, text_state.order, canvas, x, y, value, color, scale)
}

// character_vector_with draws one character of a glyph cache that
// glyph_cache.validate accepted: each entry and each word is inside the
// file, so the loop has no bounds check (the rows and the columns are cut
// to the canvas here).
character_vector_with :: proc "contextless" (cache: ^glyph_cache.Cache, square_root: ^[4096]u8, order: Subpixel_Order, canvas: Canvas, x, y: int, value: u8, color: Color, scale: int) #no_bounds_check {
	size, entry, found := glyph_cache.glyph(cache, value, scale)
	if !found || entry.row_count == 0 {
		return
	}
	width := int(size.cell_width)
	first_column := max(0, -x)
	last_column := min(width, canvas.width - x)
	first_row := max(0, -(y + int(entry.first_row)))
	last_row := min(int(entry.row_count), canvas.height - y - int(entry.first_row))
	if first_column >= last_column || first_row >= last_row {
		return
	}
	words := raw_data(cache.words[entry.word_offset:])
	for row in first_row ..< last_row {
		line := canvas.pixels[(y + int(entry.first_row) + row) * canvas.stride + x:]
		blend_coverage_row(line, words[row * width:], first_column, last_column, color, order, square_root)
	}
}

// character_spleen draws one character of Spleen 8x16 at its native size.
character_spleen :: proc "contextless" (canvas: Canvas, x, y: int, value: u8, color: Color) {
	if value < FONT_FIRST || value > FONT_LAST {
		return
	}
	glyph := font[value - FONT_FIRST]
	if x >= 0 && y >= 0 && x + CELL_WIDTH <= canvas.width && y + CELL_HEIGHT <= canvas.height {
		// The whole glyph is inside the canvas: no test for each pixel.
		for bits, row in glyph {
			line := canvas.pixels[(y + row) * canvas.stride + x:]
			for column in 0 ..< CELL_WIDTH {
				if bits << uint(column) & 0x80 != 0 {
					line[column] = color
				}
			}
		}
		return
	}
	for bits, row in glyph {
		for column in 0 ..< CELL_WIDTH {
			if bits << uint(column) & 0x80 != 0 {
				pixel(canvas, x + column, y + row, color)
			}
		}
	}
}

// character_spleen_enlarged draws one character of Spleen with each pixel
// as a square of scale pixels: the large sizes when the setting is Spleen.
character_spleen_enlarged :: proc "contextless" (canvas: Canvas, x, y: int, value: u8, color: Color, scale: int) {
	if value < FONT_FIRST || value > FONT_LAST {
		return
	}
	for bits, row in font[value - FONT_FIRST] {
		for column in 0 ..< CELL_WIDTH {
			if bits << uint(column) & 0x80 != 0 {
				fill(canvas, x + column * scale, y + row * scale, scale, scale, color)
			}
		}
	}
}
