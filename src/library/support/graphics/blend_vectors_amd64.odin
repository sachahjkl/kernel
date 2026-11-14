#+build amd64
package graphics

import "base:intrinsics"

// The SSE2 forms of the blends of blend.odin (docs/SIMD.md). Each does the
// same integer arithmetic as its scalar form, in lanes, and gives the same
// bytes for every input: the host tests compare each form with the scalar
// form. A group of pixels is loaded and stored whole only when the whole
// group is inside the row; the columns after the last whole group go
// through the scalar form, so no load and no store passes the end of a row.
//
// SSE2 is in every x86-64 processor, and every kernel saves its registers:
// these forms need no test of the processor. A group of four pixels has one
// lane of 16 bits for each byte: 16 lanes, which the compiler splits in two
// registers of 128 bits.

@(private)
Four_Pixels :: #simd[4]u32
@(private)
Sixteen_Bytes :: #simd[16]u8
// The bytes of four pixels, one lane of 16 bits for each: blue, green, red
// and the byte above red, then the same for the next pixel. The product of
// two bytes fits in such a lane.
@(private)
Sixteen_Channels :: #simd[16]u16
// The same lanes at 32 bits: the sum of the blend in linear light needs 24.
@(private)
Sixteen_Wide_Channels :: #simd[16]u32

// The three color lanes of each pixel. The lane of the byte above red is 0
// in a blended pixel, as in the scalar form.
@(private)
COLOR_LANES_OF_FOUR_PIXELS :: Sixteen_Channels{0xFFFF, 0xFFFF, 0xFFFF, 0, 0xFFFF, 0xFFFF, 0xFFFF, 0, 0xFFFF, 0xFFFF, 0xFFFF, 0, 0xFFFF, 0xFFFF, 0xFFFF, 0}

@(private)
channels_of_four_pixels :: #force_inline proc "contextless" (pixels: Four_Pixels) -> Sixteen_Channels {
	return cast(Sixteen_Channels)(transmute(Sixteen_Bytes)pixels)
}

// four_pixels_of_channels keeps the low byte of each lane: the caller gives
// lanes of 0 to 255 only, so no value changes.
@(private)
four_pixels_of_channels :: #force_inline proc "contextless" (channels: Sixteen_Channels) -> Four_Pixels {
	return transmute(Four_Pixels)(cast(Sixteen_Bytes)channels)
}

// ---------------------------------------------------------------------------
// The blend of a glyph: a color over the pixels, with one coverage for each
// channel, in linear light (blend_coverage_row_in_order is the scalar form).
//
// What is vectorised: the split of the pixels and of the coverage words into
// channels, the squares, the two products and their sum, the shift that
// gives the index of the table, the choice of each channel (no coverage:
// the pixel; full coverage: the color; else the table), and the choice of
// each pixel (a word of 0 keeps the pixel whole; a word that covers the
// three stripes writes the color whole).
//
// What is not: the read of the table square_root. It is a gather, one byte
// at an index of each lane, and SSE2 has no gather: the form extracts the
// twelve indices of four pixels, reads twelve bytes, and puts them back in
// lanes. The table stays as it is: twelve reads of one byte cost less than
// a square root computed in lanes (eight steps of a search for each
// channel).
// ---------------------------------------------------------------------------

// The values of a blend of one color that do not change along a row.
@(private)
Coverage_Color :: struct {
	pixels:             Four_Pixels, // The color, whole, in each pixel: the result where a word covers the three stripes.
	channels:           Sixteen_Channels, // The channels of the color, 0 above red.
	squares:            Sixteen_Channels, // The square of each channel of the color.
	full_coverage:      Four_Pixels, // The bits of a word that are all set where the word covers the three stripes.
	full_coverage_word: u32,
}

@(private)
coverage_color_of :: #force_inline proc "contextless" (color: Color, $ORDER: Subpixel_Order, result: ^Coverage_Color) {
	result.pixels = Four_Pixels{color, color, color, color}
	result.channels = intrinsics.simd_bit_and(channels_of_four_pixels(result.pixels), COLOR_LANES_OF_FOUR_PIXELS)
	result.squares = result.channels * result.channels
	// The order None has one coverage, in the high byte; the two other
	// orders have three, in the three low bytes.
	result.full_coverage_word = ORDER == .None ? 0xFF000000 : 0x00FFFFFF
	result.full_coverage = Four_Pixels{result.full_coverage_word, result.full_coverage_word, result.full_coverage_word, result.full_coverage_word}
}

// coverage_in_pixel_order puts the coverage of each channel in the lane of
// that channel of the pixel. In the order red, green, blue the bytes of a
// word are already in the order of the bytes of a pixel; in the order blue,
// green, red the coverage of red is in the low byte; with no order the one
// coverage is the high byte, for the three channels.
@(private)
coverage_in_pixel_order :: #force_inline proc "contextless" (words: Four_Pixels, $ORDER: Subpixel_Order) -> Sixteen_Channels {
	coverage := channels_of_four_pixels(words)
	when ORDER == .Blue_Green_Red {
		return intrinsics.simd_shuffle(coverage, coverage, 2, 1, 0, 3, 6, 5, 4, 7, 10, 9, 8, 11, 14, 13, 12, 15)
	} else when ORDER == .None {
		return intrinsics.simd_shuffle(coverage, coverage, 3, 3, 3, 3, 7, 7, 7, 7, 11, 11, 11, 11, 15, 15, 15, 15)
	} else {
		return coverage
	}
}

// square_root_indices gives, for each lane, (d * d * (255 - a) + c * c * a)
// >> 12: the index of the table in the scalar form. Each value is a byte,
// so d * d fits in 16 bits; the sum is at most 255 * 255 * 255, under 2^24.
@(private)
square_root_indices :: #force_inline proc "contextless" (under, coverage, color_squares: Sixteen_Channels) -> Sixteen_Wide_Channels {
	under_squares := cast(Sixteen_Wide_Channels)(under * under)
	weights_of_under := cast(Sixteen_Wide_Channels)(Sixteen_Channels(255) - coverage)
	sums := under_squares * weights_of_under + cast(Sixteen_Wide_Channels)color_squares * cast(Sixteen_Wide_Channels)coverage
	return intrinsics.simd_shr(sums, Sixteen_Wide_Channels(12))
}

// coverage_blend_finish chooses each channel and each pixel as the scalar
// form does, from the bytes that the table gave.
@(private)
coverage_blend_finish :: #force_inline proc "contextless" (under_pixels: Four_Pixels, under, coverage, from_table: Sixteen_Channels, words: Four_Pixels, color: ^Coverage_Color) -> Four_Pixels {
	no_coverage := intrinsics.simd_lanes_eq(coverage, Sixteen_Channels(0))
	full_coverage := intrinsics.simd_lanes_eq(coverage, Sixteen_Channels(255))
	channels := intrinsics.simd_select(no_coverage, under, intrinsics.simd_select(full_coverage, color.channels, from_table))
	blended := four_pixels_of_channels(intrinsics.simd_bit_and(channels, COLOR_LANES_OF_FOUR_PIXELS))
	word_is_zero := intrinsics.simd_lanes_eq(words, Four_Pixels(0))
	word_covers_whole := intrinsics.simd_lanes_eq(intrinsics.simd_bit_and(words, color.full_coverage), color.full_coverage)
	return intrinsics.simd_select(word_is_zero, under_pixels, intrinsics.simd_select(word_covers_whole, color.pixels, blended))
}

// square_roots_one_at_a_time is the gather of the SSE2 form: one byte of the
// table for each lane of a color channel; the lane above red needs none.
// Each index is at most 4048 (square_root_indices).
@(private)
square_roots_one_at_a_time :: #force_inline proc "contextless" (indices: Sixteen_Wide_Channels, square_root: ^[4096]u8) -> Sixteen_Channels #no_bounds_check {
	narrow := cast(Sixteen_Channels)indices
	return Sixteen_Channels{
		u16(square_root[intrinsics.simd_extract(narrow, 0)]),
		u16(square_root[intrinsics.simd_extract(narrow, 1)]),
		u16(square_root[intrinsics.simd_extract(narrow, 2)]),
		0,
		u16(square_root[intrinsics.simd_extract(narrow, 4)]),
		u16(square_root[intrinsics.simd_extract(narrow, 5)]),
		u16(square_root[intrinsics.simd_extract(narrow, 6)]),
		0,
		u16(square_root[intrinsics.simd_extract(narrow, 8)]),
		u16(square_root[intrinsics.simd_extract(narrow, 9)]),
		u16(square_root[intrinsics.simd_extract(narrow, 10)]),
		0,
		u16(square_root[intrinsics.simd_extract(narrow, 12)]),
		u16(square_root[intrinsics.simd_extract(narrow, 13)]),
		u16(square_root[intrinsics.simd_extract(narrow, 14)]),
		0,
	}
}

// coverage_four_pixels blends the four pixels at address.
@(private)
coverage_four_pixels :: #force_inline proc "contextless" (address: ^Four_Pixels, words: Four_Pixels, color: ^Coverage_Color, $ORDER: Subpixel_Order, square_root: ^[4096]u8) {
	under_pixels := intrinsics.unaligned_load(address)
	under := channels_of_four_pixels(under_pixels)
	coverage := coverage_in_pixel_order(words, ORDER)
	from_table := square_roots_one_at_a_time(square_root_indices(under, coverage, color.squares), square_root)
	intrinsics.unaligned_store(address, coverage_blend_finish(under_pixels, under, coverage, from_table, words, color))
}

// blend_coverage_row_sse2 is the SSE2 form of blend_coverage_row_in_order:
// four pixels at a time. A group whose four words are 0 is not read; a
// group whose four words cover the three stripes gets the color: the
// general path gives the same bytes for both, at a higher cost.
@(private)
blend_coverage_row_sse2 :: proc "contextless" (line: [^]Color, words: [^]u32, first, last: int, color: Color, $ORDER: Subpixel_Order, square_root: ^[4096]u8) #no_bounds_check {
	blend_color: Coverage_Color
	coverage_color_of(color, ORDER, &blend_color)
	column := first
	for ; column + 4 <= last; column += 4 {
		group_words := intrinsics.unaligned_load((^Four_Pixels)(&words[column]))
		if intrinsics.simd_reduce_or(group_words) == 0 {
			continue
		}
		address := (^Four_Pixels)(&line[column])
		if intrinsics.simd_reduce_and(intrinsics.simd_bit_and(group_words, blend_color.full_coverage)) == blend_color.full_coverage_word {
			intrinsics.unaligned_store(address, blend_color.pixels)
			continue
		}
		coverage_four_pixels(address, group_words, &blend_color, ORDER, square_root)
	}
	blend_coverage_row_in_order(line, words, column, last, color, ORDER, square_root)
}

// ---------------------------------------------------------------------------
// The blend of a picture with premultiplied alpha
// (blend_premultiplied_alpha_row_scalar is the scalar form).
//
// For each channel, with d the pixel and a the alpha of the source:
// t = d * (255 - a) + 128, then (t + t >> 8) >> 8. The scalar form computes
// red and blue in two lanes of 16 bits of one word and green alone; here
// each channel has its own lane of 16 bits. t is at most 65153 and
// t + t >> 8 at most 65407: no lane passes 16 bits, as no lane of the
// scalar form does. Then the source is added to the four pixels as words
// of 32 bits, as in the scalar form: a source that is not premultiplied
// carries from one channel into the next in both forms. A source with
// alpha 0 keeps the pixel whole. A source with alpha 255 needs no case of
// its own: 255 - a is 0, the blended channels are 0, and the result is the
// source without its alpha, as in the scalar form.
// ---------------------------------------------------------------------------

@(private)
premultiplied_four_pixels :: #force_inline proc "contextless" (address: ^Four_Pixels, source: Four_Pixels) {
	under_pixels := intrinsics.unaligned_load(address)
	// The lane above red is 0: its t is 128, and its result 0.
	under := intrinsics.simd_bit_and(channels_of_four_pixels(under_pixels), COLOR_LANES_OF_FOUR_PIXELS)
	source_channels := channels_of_four_pixels(source)
	alpha := intrinsics.simd_shuffle(source_channels, source_channels, 3, 3, 3, 3, 7, 7, 7, 7, 11, 11, 11, 11, 15, 15, 15, 15)
	t := under * (Sixteen_Channels(255) - alpha) + Sixteen_Channels(128)
	scaled := intrinsics.simd_shr(t + intrinsics.simd_shr(t, Sixteen_Channels(8)), Sixteen_Channels(8))
	blended := four_pixels_of_channels(scaled) + intrinsics.simd_bit_and(source, Four_Pixels(0x00FFFFFF))
	transparent := intrinsics.simd_lanes_eq(intrinsics.simd_bit_and(source, Four_Pixels(0xFF000000)), Four_Pixels(0))
	intrinsics.unaligned_store(address, intrinsics.simd_select(transparent, under_pixels, blended))
}

// blend_premultiplied_alpha_row_sse2 is the SSE2 form of
// blend_premultiplied_alpha_row_scalar: four pixels at a time. A group of four
// transparent pixels is not read.
@(private)
blend_premultiplied_alpha_row_sse2 :: proc "contextless" (to: [^]Color, from: [^]u32, count: int) #no_bounds_check {
	column := 0
	for ; column + 4 <= count; column += 4 {
		source := intrinsics.unaligned_load((^Four_Pixels)(&from[column]))
		if intrinsics.simd_reduce_or(intrinsics.simd_bit_and(source, Four_Pixels(0xFF000000))) == 0 {
			continue
		}
		premultiplied_four_pixels((^Four_Pixels)(&to[column]), source)
	}
	blend_premultiplied_alpha_row_scalar(to[column:], from[column:], count - column)
}
