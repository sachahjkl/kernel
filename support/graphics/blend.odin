package graphics

// The blends of support/graphics: one family, two forms of what a pixel
// over the canvas covers.
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
		to := canvas.pixels[line * canvas.stride:]
		from := source.pixels[(line - y) * source.stride + (x0 - x):]
		for column in x0 ..< x1 {
			value := from[column - x0]
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
		blend_coverage_row_in_order(line, words, first, last, color, .Red_Green_Blue, square_root)
	case .Blue_Green_Red:
		blend_coverage_row_in_order(line, words, first, last, color, .Blue_Green_Red, square_root)
	case .None:
		blend_coverage_row_in_order(line, words, first, last, color, .None, square_root)
	}
}

// blend_coverage_row_in_order is the loop for one order of the stripes, a
// constant: no test of the order for each pixel. The squares of the last
// pixel that is not covered whole stay: on a plain background, each pixel
// has the same.
@(private)
blend_coverage_row_in_order :: #force_inline proc "contextless" (line: [^]Color, words: [^]u32, first, last: int, color: Color, $ORDER: Subpixel_Order, square_root: ^[4096]u8) #no_bounds_check {
	color_red, color_green, color_blue := color >> 16 & 0xFF, color >> 8 & 0xFF, color & 0xFF
	red_square, green_square, blue_square := color_red * color_red, color_green * color_green, color_blue * color_blue
	previous: Color = 0xFFFFFFFF // No pixel has this value: the squares are not known yet.
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
		if destination != previous {
			previous = destination
			under_red, under_green, under_blue = destination >> 16 & 0xFF, destination >> 8 & 0xFF, destination & 0xFF
		}
		line[column] = channel(under_red, under_red * under_red, color_red, red_square, red, square_root) << 16 | channel(under_green, under_green * under_green, color_green, green_square, green, square_root) << 8 | channel(under_blue, under_blue * under_blue, color_blue, blue_square, blue, square_root)
	}
}
