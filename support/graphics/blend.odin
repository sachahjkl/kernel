package graphics

// The blends of support/graphics: one family, two kinds of cover of a pixel
// of the canvas.
//
// - blend_premultiplied_alpha: a picture with one alpha for each pixel,
//   premultiplied (the pointer pictures, docs/POINTERS.md). It blends in
//   the encoded values, as the picture was made.
// - blend_coverage_row: a color with one coverage for each channel (the
//   glyphs of the vector font with subpixel bands, docs/FONTS.md). It
//   blends in linear light with a gamma of 2.
//
// Both use integers only, keep the pixel where nothing covers it and copy
// the source where it covers all.
//
// Each blend has two forms (docs/SIMD.md): the scalar form here, the
// reference, and an SSE2 form in blend_vectors_amd64.odin that gives the
// same bytes for every input. On amd64 the public procedure runs the SSE2
// form; the scalar form is the code of another target, and of the last
// columns of a row that do not fill a group of four pixels.

// blend_premultiplied_alpha draws source over canvas at (x, y), cut to the
// canvas. Each pixel of source is 0xAARRGGBB with premultiplied alpha (the
// form of a pointer picture, docs/POINTERS.md); a pixel of canvas is
// 0x00RRGGBB. For each channel:
//
//   result = source + destination * (255 - alpha) / 255
//
// with a division by 255 that is exact for each 16-bit product:
// t = product + 128, then (t + t / 256) / 256. Red and blue are computed
// together in one 32-bit word (each in a lane of 16 bits), green alone. A
// pixel with alpha 0 is not read again; with alpha 255 it is copied. As the
// source is premultiplied, no channel of the result passes 255.
blend_premultiplied_alpha :: proc "contextless" (canvas: Canvas, x, y: int, source: Canvas) {
	x0 := max(x, 0)
	y0 := max(y, 0)
	x1 := min(x + source.width, canvas.width)
	y1 := min(y + source.height, canvas.height)
	if x0 >= x1 || y0 >= y1 {
		return
	}
	for line in y0 ..< y1 {
		blend_premultiplied_alpha_row(canvas.pixels[line * canvas.stride + x0:], source.pixels[(line - y) * source.stride + (x0 - x):], x1 - x0)
	}
}

// blend_premultiplied_alpha_row blends one row in the form of the target.
@(private)
blend_premultiplied_alpha_row :: #force_inline proc "contextless" (to: [^]Color, from: [^]u32, count: int) {
	when ODIN_ARCH == .amd64 {
		blend_premultiplied_alpha_row_sse2(to, from, count)
	} else {
		blend_premultiplied_alpha_row_scalar(to, from, count)
	}
}

// blend_premultiplied_alpha_row_scalar is the scalar form of one row: count
// pixels of from over the pixels of to. The two rows must not overlap.
@(private)
blend_premultiplied_alpha_row_scalar :: proc "contextless" (to: [^]Color, from: [^]u32, count: int) {
	for column in 0 ..< count {
		value := from[column]
		alpha := value >> 24
		if alpha == 0 {
			continue
		}
		if alpha == 255 {
			to[column] = value & 0xFFFFFF
			continue
		}
		inverse := 255 - alpha
		destination := to[column]
		red_blue := (destination & 0xFF00FF) * inverse + 0x800080
		red_blue = (red_blue + (red_blue >> 8 & 0xFF00FF)) >> 8 & 0xFF00FF
		green := (destination & 0x00FF00) * inverse + 0x008000
		green = (green + (green >> 8 & 0x00FF00)) >> 8 & 0x00FF00
		to[column] = red_blue + green + (value & 0xFFFFFF)
	}
}


// blend_coverage_row blends a color over the pixels of one row of a canvas,
// with the coverage words of one row of a glyph (contract/glyph_cache): a
// coverage for each channel, from the stripe of the screen that has that
// color (docs/FONTS.md, "Subpixel bands"). line is the row of the canvas
// from the first column of the glyph; the columns first ..< last are drawn.
//
// The blend is in linear light, with a gamma of 2 in place of the curve of
// sRGB: for each channel, with d the pixel, c the color and a the coverage,
//
//   result = sqrt((d * d * (255 - a) + c * c * a) / 255)
//
// with integers only: the sum is at most 255 * 255 * 255, under 2^24; the
// sum shifted right by 12 bits indexes square_root (4096 entries): no
// division. docs/FONTS.md gives
// the error of the approximation against sRGB.
//
// No bounds check: the caller cuts first and last to the row, and an index
// of square_root is at most 255 * 255 * 255 >> 12 = 4048.
blend_coverage_row :: proc "contextless" (line: [^]Color, words: [^]u32, first, last: int, color: Color, order: Subpixel_Order, square_root: ^[4096]u8) {
	switch order {
	case .Red_Green_Blue:
		blend_coverage_row_in_form_of_target(line, words, first, last, color, .Red_Green_Blue, square_root)
	case .Blue_Green_Red:
		blend_coverage_row_in_form_of_target(line, words, first, last, color, .Blue_Green_Red, square_root)
	case .None:
		blend_coverage_row_in_form_of_target(line, words, first, last, color, .None, square_root)
	}
}

// blend_coverage_row_in_form_of_target blends one row in the form of the
// target, for one order of the stripes.
@(private)
blend_coverage_row_in_form_of_target :: #force_inline proc "contextless" (line: [^]Color, words: [^]u32, first, last: int, color: Color, $ORDER: Subpixel_Order, square_root: ^[4096]u8) {
	when ODIN_ARCH == .amd64 {
		blend_coverage_row_sse2(line, words, first, last, color, ORDER, square_root)
	} else {
		blend_coverage_row_in_order(line, words, first, last, color, ORDER, square_root)
	}
}

// blend_coverage_row_in_order is the scalar form, for one order of the
// stripes, a constant: no test of the order for each pixel. The channels of
// the last pixel that is not covered whole stay: on a plain background,
// each pixel has the same.
@(private)
blend_coverage_row_in_order :: #force_inline proc "contextless" (line: [^]Color, words: [^]u32, first, last: int, color: Color, $ORDER: Subpixel_Order, square_root: ^[4096]u8) #no_bounds_check {
	color_red, color_green, color_blue := color >> 16 & 0xFF, color >> 8 & 0xFF, color & 0xFF
	red_square, green_square, blue_square := color_red * color_red, color_green * color_green, color_blue * color_blue
	// The channels of previous are known only after the first pixel: a
	// pixel can have any value, so no value of previous can mean "none".
	previous_known := false
	previous: Color
	under_red, under_green, under_blue: u32
	// A channel with no coverage keeps the pixel, a full one is the color:
	// the table rounds only the values between.
	channel :: #force_inline proc "contextless" (destination, destination_square, color, color_square, coverage: u32, square_root: ^[4096]u8) -> u32 #no_bounds_check {
		switch coverage {
		case 0:
			return destination
		case 255:
			return color
		}
		return u32(square_root[(destination_square * (255 - coverage) + color_square * coverage) >> 12])
	}
	for column in first ..< last {
		word := words[column]
		if word == 0 {
			continue
		}
		red, green, blue: u32
		when ORDER == .Red_Green_Blue {
			red, green, blue = word >> 16 & 0xFF, word >> 8 & 0xFF, word & 0xFF
		} else when ORDER == .Blue_Green_Red {
			red, green, blue = word & 0xFF, word >> 8 & 0xFF, word >> 16 & 0xFF
		} else {
			red = word >> 24
			green, blue = red, red
		}
		if red & green & blue == 255 {
			line[column] = color
			continue
		}
		destination := line[column]
		if !previous_known || destination != previous {
			previous_known = true
			previous = destination
			under_red, under_green, under_blue = destination >> 16 & 0xFF, destination >> 8 & 0xFF, destination & 0xFF
		}
		line[column] = channel(under_red, under_red * under_red, color_red, red_square, red, square_root) << 16 | channel(under_green, under_green * under_green, color_green, green_square, green, square_root) << 8 | channel(under_blue, under_blue * under_blue, color_blue, blue_square, blue, square_root)
	}
}

// The fast form of the blend for text over a pixel of one flat color (the
// cards, the console): for one text color over one pixel color, the result
// of a channel is a function of its coverage only. A blend table keeps it
// for each coverage, computed on first use with the formula of
// blend_coverage_row, so a pixel is three loads and a store, and its value
// is the value of the reference, bit for bit (host test
// fast_blend_is_the_reference).
//
// The choice is made for each row of a glyph: a row whose two end pixels
// have one color takes the table of that color, and each pixel of the row
// with that color under it uses the table; another pixel, or a row over a
// gradient across or a picture, takes the reference blend.
//
// The tables are in the memory of the caller (Blend_Tables, in the text
// state of the program). A new table clears nothing: it takes a new
// generation, and a value of another generation is computed again.

// Blend_Table: the results for one text color over one pixel color. Each
// value has its generation in the high byte; red is already shifted by 16,
// green by 8.
Blend_Table :: struct {
	color, under: Color,
	generation:   u32, // 1 to 255; 0: the table holds nothing.
	channels:     [3][256]u32,
}

BLEND_TABLE_COUNT :: 8

// Blend_Tables: a few tables, the one replaced next in turn. All zero is
// valid: no table yet.
Blend_Tables :: struct {
	tables: [BLEND_TABLE_COUNT]Blend_Table,
	next:   int,
	last:   int, // The table that the last search found.
	made:   u64, // Tables made since the start: a measure.
}

// blend_table_of gives the table of a text color over a pixel color; it
// makes it when no table has the pair.
blend_table_of :: proc "contextless" (tables: ^Blend_Tables, color, under: Color) -> ^Blend_Table #no_bounds_check {
	last := &tables.tables[tables.last]
	if last.generation != 0 && last.under == under && last.color == color {
		return last
	}
	for &table, index in tables.tables {
		if table.generation != 0 && table.under == under && table.color == color {
			tables.last = index
			return &table
		}
	}
	index := tables.next
	tables.next = (tables.next + 1) % BLEND_TABLE_COUNT
	table := &tables.tables[index]
	table.color, table.under = color, under
	table.generation += 1
	if table.generation > 255 {
		// Each value of an old generation can have the number 1: clear.
		for &channel in table.channels {
			channel = {}
		}
		table.generation = 1
	}
	tables.last = index
	tables.made += 1
	return table
}

// blend_glyph_rows draws the rows of a glyph with the fast blend: the same
// pixels as blend_coverage_row for each row.
blend_glyph_rows :: proc "contextless" (canvas_row: [^]Color, stride: int, words: [^]u32, width, first_row, last_row, first, last: int, color: Color, order: Subpixel_Order, square_root: ^[4096]u8, tables: ^Blend_Tables) {
	switch order {
	case .Red_Green_Blue:
		blend_glyph_rows_in_order(canvas_row, stride, words, width, first_row, last_row, first, last, color, .Red_Green_Blue, square_root, tables)
	case .Blue_Green_Red:
		blend_glyph_rows_in_order(canvas_row, stride, words, width, first_row, last_row, first, last, color, .Blue_Green_Red, square_root, tables)
	case .None:
		blend_glyph_rows_in_order(canvas_row, stride, words, width, first_row, last_row, first, last, color, .None, square_root, tables)
	}
}

@(private)
blend_glyph_rows_in_order :: #force_inline proc "contextless" (canvas_row: [^]Color, stride: int, words: [^]u32, width, first_row, last_row, first, last: int, color: Color, $ORDER: Subpixel_Order, square_root: ^[4096]u8, tables: ^Blend_Tables) #no_bounds_check {
	for row in first_row ..< last_row {
		line := canvas_row[row * stride:]
		row_words := words[row * width:]
		under := line[first]
		if line[last - 1] != under {
			// A row over a gradient across or a picture: no table holds it;
			// the form of the target (SSE2 on amd64), the same bytes.
			blend_coverage_row_in_form_of_target(line, row_words, first, last, color, ORDER, square_root)
			continue
		}
		table := blend_table_of(tables, color, under)
		generation := table.generation << 24
		red_values, green_values, blue_values := &table.channels[0], &table.channels[1], &table.channels[2]
		under_red, under_green, under_blue := under >> 16 & 0xFF, under >> 8 & 0xFF, under & 0xFF
		color_red, color_green, color_blue := color >> 16 & 0xFF, color >> 8 & 0xFF, color & 0xFF
		// A value of the table, computed on first use with the formula of
		// the reference blend.
		value_of :: #force_inline proc "contextless" (values: ^[256]u32, coverage, generation, under, front: u32, $SHIFT: uint, square_root: ^[4096]u8) -> u32 #no_bounds_check {
			value := values[coverage]
			if value & 0xFF000000 != generation {
				result: u32
				switch coverage {
				case 0:
					result = under
				case 255:
					result = front
				case:
					result = u32(square_root[(under * under * (255 - coverage) + front * front * coverage) >> 12])
				}
				value = result << SHIFT | generation
				values[coverage] = value
			}
			return value
		}
		for column in first ..< last {
			word := row_words[column]
			if word == 0 {
				continue
			}
			if line[column] != under {
				// One pixel: the SSE2 form works on groups of four and
				// gives a lone pixel to this scalar form anyway.
				blend_coverage_row_in_order(line, row_words, column, column + 1, color, ORDER, square_root)
				continue
			}
			red, green, blue: u32
			when ORDER == .Red_Green_Blue {
				red, green, blue = word >> 16 & 0xFF, word >> 8 & 0xFF, word & 0xFF
			} else when ORDER == .Blue_Green_Red {
				red, green, blue = word & 0xFF, word >> 8 & 0xFF, word >> 16 & 0xFF
			} else {
				red = word >> 24
				green, blue = red, red
			}
			line[column] = (value_of(red_values, red, generation, under_red, color_red, 16, square_root) | value_of(green_values, green, generation, under_green, color_green, 8, square_root) | value_of(blue_values, blue, generation, under_blue, color_blue, 0, square_root)) & 0x00FFFFFF
		}
	}
}
