package graphics

import "contract:glyph_cache"
import "support:text_shaping"

// The text of the system (docs/FONTS.md). Two fonts draw on one grid of
// cells of 8 x 16 pixels at scale 1 (16 x 32, 24 x 48 at the scales 2 and
// 3): the vector font, from a glyph cache that the root service maps for
// the program, and Spleen 8x16 (font.odin), the fallback and the other
// value of the setting. A program calls text, character and text_scaled;
// it does not know which font draws.
//
// The state is in this package, one for the program, and changes only
// through text_cache_set and text_choice_set (src/library/support/display calls them
// at the start of a window and at a change of the setting, between two
// frames). The zero state draws with Spleen: no cache yet.

// The fonts of the setting "font". Zero is the default (ZII): the vector font.
Text_Font :: enum u8 {
	Vector, // The vector font of the system, from the glyph cache.
	Spleen, // Spleen 8x16, a bitmap font in the library itself.
}

// The order of the color stripes of the pixels of the screen: the setting
// "subpixel_order". None draws the vector font in grayscale.
Subpixel_Order :: enum u8 {
	Red_Green_Blue, // Red on the left of each pixel: most screens.
	Blue_Green_Red, // Blue on the left.
	None, // No subpixels: grayscale.
}

// The text state of a program: the setting of the font, the caches, and
// the tables of the blend. One for the program, in `text_state`.
Text_State :: struct {
	font:        Text_Font, // The setting "font".
	order:       Subpixel_Order, // The setting "subpixel_order".
	has_cache:   bool, // A glyph cache was accepted: the vector font can draw.
	cache:       glyph_cache.Cache, // The glyph cache of the regular weight.
	// The blend in linear light: square_root[i] is the 8-bit value whose
	// square is nearest to (4096 i + 2048) / 255 (docs/FONTS.md, "The blend in linear light").
	square_root: [4096]u8,
	// The bold weight at scale 1, for emphasis: the titles of the cards.
	has_bold_cache: bool, // A bold cache was accepted.
	bold_cache:     glyph_cache.Cache, // The glyph cache of the bold weight.
	// The blend tables of text over a flat color (blend.odin), 24 KiB.
	blend_tables: Blend_Tables,
}

// The text state of this program. `text_cache_set` and `text_choice_set`
// change it, between two frames.
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
	return text_cache_use(cache)
}

// cell_cache_problem says if a valid cache can draw the cells of the grid:
// a cache of a proportional font cannot. Its glyphs are boxes of ink that
// pass their cells, so the damage of a grid of text cells, which depends
// on a glyph that stays in its cell, would leave stale pixels. A
// proportional cache is drawn by text_proportional only.
cell_cache_problem :: proc "contextless" (cache: ^glyph_cache.Cache) -> glyph_cache.Problem {
	if cache.header.flags & glyph_cache.FLAG_PROPORTIONAL != 0 {
		return {kind = .Proportional, value = u64(cache.header.flags)}
	}
	return {}
}

// text_cache_use makes a cache that glyph_cache.validate accepted the cache
// of the vector font: a change of the setting "grid_fit" between two
// caches that the program validated once. A cache of a proportional font
// is refused: the program draws with Spleen, as for any refused cache.
text_cache_use :: proc "contextless" (cache: glyph_cache.Cache) -> glyph_cache.Problem {
	cache := cache
	if problem := cell_cache_problem(&cache); problem.kind != .None {
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

// text_bold_cache_use makes a cache that glyph_cache.validate accepted the
// cache of the bold weight. A cache of a proportional font is refused: the
// titles are the regular weight.
text_bold_cache_use :: proc "contextless" (cache: glyph_cache.Cache) -> glyph_cache.Problem {
	cache := cache
	if problem := cell_cache_problem(&cache); problem.kind != .None {
		text_state.has_bold_cache = false
		return problem
	}
	text_state.bold_cache = cache
	text_state.has_bold_cache = true
	return {}
}

// text_bold draws characters at scale 1 in the bold weight of the vector
// font: the titles of the cards. With Spleen, or with no bold cache, it is
// text. It gives the x after the last character.
text_bold :: proc "contextless" (canvas: Canvas, x, y: int, characters: string, color: Color) -> int {
	if !text_vector_drawn() || !text_state.has_bold_cache {
		return text(canvas, x, y, characters, color)
	}
	at := x
	for index in 0 ..< len(characters) {
		if at >= canvas.width {
			break
		}
		if at + CELL_WIDTH > 0 {
			character_vector_with(&text_state.bold_cache, &text_state.square_root, &text_state.blend_tables, text_state.order, canvas, at, y, characters[index], color, 1)
		}
		at += CELL_WIDTH
	}
	return x + CELL_WIDTH * len(characters)
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

// text_width gives the width of a text in the font of the cells at scale 1,
// in pixels: 8 pixels for each byte. Both fonts of the cells have that
// width.
text_width :: proc "contextless" (characters: string) -> int {
	return len(characters) * CELL_WIDTH
}

// character_vector draws one character of the glyph cache: each word of the
// glyph blends the color over the pixel of the canvas, one coverage for
// each channel.
character_vector :: #force_inline proc "contextless" (canvas: Canvas, x, y: int, value: u8, color: Color, scale: int) {
	character_vector_with(&text_state.cache, &text_state.square_root, &text_state.blend_tables, text_state.order, canvas, x, y, value, color, scale)
}

// character_vector_with draws one character with the fast blend: the same
// pixels as character_vector_reference.
character_vector_with :: proc "contextless" (cache: ^glyph_cache.Cache, square_root: ^[4096]u8, tables: ^Blend_Tables, order: Subpixel_Order, canvas: Canvas, x, y: int, value: u8, color: Color, scale: int) {
	_, entry, found := glyph_cache.glyph(cache, value, scale)
	if !found || entry.row_count == 0 {
		return
	}
	glyph_entry_draw(cache, entry, square_root, tables, order, canvas, x, y, color)
}

// glyph_entry_draw draws one glyph entry of a valid cache with the fast
// blend, its origin at the whole pixel x, the top of its line at y, cut to
// the canvas. The text of cells and the text of a proportional font both
// draw through it, so both have the same blend.
@(private)
glyph_entry_draw :: proc "contextless" (cache: ^glyph_cache.Cache, entry: glyph_cache.Glyph_Entry, square_root: ^[4096]u8, tables: ^Blend_Tables, order: Subpixel_Order, canvas: Canvas, x, y: int, color: Color) #no_bounds_check {
	if entry.row_count == 0 {
		return
	}
	// The words of a row start at the column left of the origin: 0, and
	// the width of the cell, in the cache of a monospace font.
	column_x := x + int(entry.left)
	width := int(entry.width)
	first_column := max(0, -column_x)
	last_column := min(width, canvas.width - column_x)
	first_row := max(0, -(y + int(entry.first_row)))
	last_row := min(int(entry.row_count), canvas.height - y - int(entry.first_row))
	if first_column >= last_column || first_row >= last_row {
		return
	}
	words := raw_data(cache.words[entry.word_offset:])
	blend_glyph_rows(canvas.pixels[(y + int(entry.first_row)) * canvas.stride + column_x:], canvas.stride, words, width, first_row, last_row, first_column, last_column, color, order, square_root, tables)
}

// character_vector_reference draws one character of a glyph cache that
// glyph_cache.validate accepted: each entry and each word is inside the
// file, so the loop has no bounds check (the rows and the columns are cut
// to the canvas here).
character_vector_reference :: proc "contextless" (cache: ^glyph_cache.Cache, square_root: ^[4096]u8, order: Subpixel_Order, canvas: Canvas, x, y: int, value: u8, color: Color, scale: int) #no_bounds_check {
	_, entry, found := glyph_cache.glyph(cache, value, scale)
	if !found || entry.row_count == 0 {
		return
	}
	// The words of a row start at the column left of the cell: 0, and the
	// width of the cell, in the cache of a monospace font.
	column_x := x + int(entry.left)
	width := int(entry.width)
	first_column := max(0, -column_x)
	last_column := min(width, canvas.width - column_x)
	first_row := max(0, -(y + int(entry.first_row)))
	last_row := min(int(entry.row_count), canvas.height - y - int(entry.first_row))
	if first_column >= last_column || first_row >= last_row {
		return
	}
	words := raw_data(cache.words[entry.word_offset:])
	for row in first_row ..< last_row {
		line := canvas.pixels[(y + int(entry.first_row) + row) * canvas.stride + column_x:]
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

// The ink of a text of a proportional font can pass the box that its
// measure gives (text_shaping.text_width), on each side, by at most this
// many pixels at scale 1: a glyph that starts left of its origin (B612: at
// most 126 units, 0.84 pixel), the spread of the filter (two thirds of a
// pixel), and the rounding to a third of a pixel (one sixth). A caller that
// damages the place of a text widens the measured box by it, times the
// scale (docs/FONTS.md, section 12.5).
PROPORTIONAL_INK_MARGIN :: 2

// text_proportional draws the placed glyphs of a text of a proportional
// font (text_shaping.shape) from a cache of that font: place is the x of
// the origin of the text in 1/64 of a pixel, y the top of its line. Each
// glyph is drawn at the nearest of the positions of its scale, through the
// blend of the text of cells, cut to the canvas. The state of the program
// gives the order of the stripes and the blend tables.
text_proportional :: proc "contextless" (canvas: Canvas, place: i64, y: int, placed: []text_shaping.Placed_Glyph, cache: ^glyph_cache.Cache, scale: int, color: Color) {
	if text_state.square_root[4095] == 0 {
		square_root_table_fill(&text_state.square_root)
	}
	text_proportional_with(cache, &text_state.square_root, &text_state.blend_tables, text_state.order, canvas, place, y, placed, scale, color)
}

// text_proportional_with is text_proportional with its state given: the
// tests draw with it, each with its own tables.
text_proportional_with :: proc "contextless" (cache: ^glyph_cache.Cache, square_root: ^[4096]u8, tables: ^Blend_Tables, order: Subpixel_Order, canvas: Canvas, place: i64, y: int, placed: []text_shaping.Placed_Glyph, scale: int, color: Color) {
	if scale < 1 || scale > len(cache.sizes) {
		return
	}
	position_count := int(cache.sizes[scale - 1].position_count)
	for glyph in placed {
		if glyph.glyph >= cache.header.character_count {
			continue
		}
		pixel, position := glyph_cache.position_of(place + i64(glyph.x), position_count)
		// A glyph far outside the canvas: its pixel does not fit an int of
		// the canvas, and it draws nothing.
		if pixel < -i64(glyph_cache.GLYPH_WIDTH_LIMIT) || pixel > i64(canvas.width) {
			continue
		}
		_, entry, found := glyph_cache.glyph_at_position(cache, u8(cache.header.first_character + glyph.glyph), scale, position)
		if !found {
			continue
		}
		glyph_entry_draw(cache, entry, square_root, tables, order, canvas, int(pixel), y, color)
	}
}
