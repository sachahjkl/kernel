#+build !freestanding
package graphics

import "contract:glyph_cache"
import "core:testing"
import "support:text_shaping"
import "support:vector_font"

// The glyph cache of B612 Regular, three positions at scale 1 and one at
// the scales 2 and 3, in memory that the caller frees.
@(private = "file")
b612_cache_of :: proc(t: ^testing.T) -> (cache: glyph_cache.Cache, memory: []u64) {
	bytes := #load("../../../../resources/fonts/b612.ttf")
	font, problem := vector_font.font_open(bytes)
	testing.expect_value(t, problem, vector_font.Font_Problem.None)
	render := new(vector_font.Render_Memory)
	defer free(render)
	memory = make([]u64, vector_font.PROPORTIONAL_GLYPH_CACHE_LIMIT / 8)
	file := ([^]u8)(raw_data(memory))[:vector_font.PROPORTIONAL_GLYPH_CACHE_LIMIT]
	positions := [3]int{3, 1, 1}
	size: int
	size, problem = vector_font.glyph_cache_build_proportional(&font, bytes, "b612", true, render, file, positions[:])
	testing.expect_value(t, problem, vector_font.Font_Problem.None)
	refused: glyph_cache.Problem
	cache, refused = glyph_cache.validate(file[:size])
	testing.expect_value(t, refused.kind, glyph_cache.Problem_Kind.None)
	return cache, memory
}

// A valid cache of a proportional font is not a font of cells: the text of
// cells refuses it and draws with Spleen, and the bold weight refuses it.
@(test)
a_proportional_cache_is_not_a_font_of_cells :: proc(t: ^testing.T) {
	cache, memory := b612_cache_of(t)
	defer delete(memory)
	saved := text_state
	defer text_state = saved
	text_state.has_cache = true
	problem := text_cache_use(cache)
	testing.expect_value(t, problem.kind, glyph_cache.Problem_Kind.Proportional)
	testing.expect(t, !text_state.has_cache)
	bold_problem := text_bold_cache_use(cache)
	testing.expect_value(t, bold_problem.kind, glyph_cache.Problem_Kind.Proportional)
	testing.expect(t, !text_state.has_bold_cache)
}

// The measure and the draw agree to the pixel: the ink of each of 200
// texts lies inside the box that text_width gives, widened by
// PROPORTIONAL_INK_MARGIN on each side, and inside its line. The texts and
// the places (a fraction of a pixel each) come from a generator with a
// fixed seed; the background is flat, so a pixel with ink is a pixel that
// changed.
@(test)
the_ink_lies_inside_the_measured_box :: proc(t: ^testing.T) {
	cache, memory := b612_cache_of(t)
	defer delete(memory)
	spacing, spacing_ok := text_shaping.spacing_of(&cache, 1)
	testing.expect(t, spacing_ok)
	square_root: [4096]u8
	square_root_table_fill(&square_root)
	tables := new(Blend_Tables)
	defer free(tables)
	WIDTH :: 512
	HEIGHT :: 48
	LINE_TOP :: 16
	pixels := make([]Color, WIDTH * HEIGHT)
	defer delete(pixels)
	canvas := Canvas{pixels = raw_data(pixels), width = WIDTH, height = HEIGHT, stride = WIDTH}
	state := u32(12345)
	next :: proc(generator: ^u32) -> u32 {
		generator^ = generator^ * 1664525 + 1013904223
		return generator^ >> 8
	}
	outside := 0
	for _ in 0 ..< 200 {
		characters: [40]u8
		count := 1 + int(next(&state) % 40)
		for index in 0 ..< count {
			characters[index] = u8(32 + next(&state) % 95)
		}
		placed: [40]text_shaping.Placed_Glyph
		_, width, ok := text_shaping.shape(&spacing, characters[:count], placed[:count])
		testing.expect(t, ok)
		place := i64(32 * 64) + i64(next(&state) % 64)
		for &pixel in pixels {
			pixel = COLOR_CARD_BOTTOM
		}
		text_proportional_with(&cache, &square_root, tables, .Red_Green_Blue, canvas, place, LINE_TOP, placed[:count], 1, COLOR_TEXT)
		// The box in whole pixels: from the pixel of the origin to the pixel
		// of the end, widened by the margin.
		left := int(place / 64) - PROPORTIONAL_INK_MARGIN
		right := int((place + width + 63) / 64) + PROPORTIONAL_INK_MARGIN
		for row in 0 ..< HEIGHT {
			for column in 0 ..< WIDTH {
				if pixels[row * WIDTH + column] == COLOR_CARD_BOTTOM {
					continue
				}
				if column < left || column >= right || row < LINE_TOP || row >= LINE_TOP + 16 {
					outside += 1
				}
			}
		}
	}
	testing.expectf(t, outside == 0, "%v pixels of ink are outside the measured box and its margin", outside)
}

// A text far outside the canvas, a scale that the cache does not have, and
// a glyph past the characters of the cache draw nothing, and do not fault.
@(test)
a_proportional_text_outside_its_limits :: proc(t: ^testing.T) {
	cache, memory := b612_cache_of(t)
	defer delete(memory)
	square_root: [4096]u8
	square_root_table_fill(&square_root)
	tables := new(Blend_Tables)
	defer free(tables)
	pixels: [64 * 32]Color
	canvas := Canvas{pixels = raw_data(pixels[:]), width = 64, height = 32, stride = 64}
	placed := [3]text_shaping.Placed_Glyph{{glyph = 'A' - 32, x = 0}, {glyph = 200, x = 640}, {glyph = 'W' - 32, x = max(i32)}}
	places := [?]i64{-(1 << 40), 1 << 40, -64 * 70, 64 * 70}
	for place in places {
		text_proportional_with(&cache, &square_root, tables, .Red_Green_Blue, canvas, place, 0, placed[:], 1, COLOR_TEXT)
	}
	text_proportional_with(&cache, &square_root, tables, .Red_Green_Blue, canvas, 0, 0, placed[:], 4, COLOR_TEXT)
	text_proportional_with(&cache, &square_root, tables, .Red_Green_Blue, canvas, 0, -1000, placed[:], 1, COLOR_TEXT)
	for pixel in pixels {
		testing.expect_value(t, pixel, Color(0))
	}
}
