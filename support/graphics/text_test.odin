#+build !freestanding
package graphics

import "contract:glyph_cache"
import "core:fmt"
import "core:math"
import "core:testing"
import "core:time"
import "support:vector_font"

// The blend in linear light with a gamma of 2 (blend_coverage_row) against
// the curve of sRGB, for the text of the rules on a card: light text on a
// dark surface, the case of this system. The plain blend of the encoded
// values is the third column: the error that a blend with no gamma makes.
@(test)
blend_error_against_srgb :: proc(t: ^testing.T) {
	to_linear :: proc(value: u32) -> f64 {
		c := f64(value) / 255
		return c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4)
	}
	to_encoded :: proc(linear: f64) -> f64 {
		return 255 * (linear <= 0.0031308 ? linear * 12.92 : 1.055 * math.pow(linear, 1 / 2.4) - 0.055)
	}
	table: [4096]u8
	square_root_table_fill(&table)
	Pair :: struct {
		front, back: Color,
	}
	pairs := [?]Pair{{COLOR_TEXT, COLOR_CARD_BOTTOM}, {COLOR_DIM, COLOR_BACKGROUND}, {COLOR_PROGRAM, COLOR_CARD_TOP}, {COLOR_BACKGROUND, COLOR_TEXT}}
	for pair in pairs {
		worst_gamma_two, worst_plain: f64
		for coverage in u32(0) ..= 255 {
			line: [1]Color = {pair.back}
			word := [1]u32{coverage << 24 | coverage << 16 | coverage << 8 | coverage}
			blend_coverage_row(raw_data(line[:]), raw_data(word[:]), 0, 1, pair.front, .Red_Green_Blue, &table)
			for shift in ([3]uint{16, 8, 0}) {
				front, back := pair.front >> shift & 0xFF, pair.back >> shift & 0xFF
				exact := to_encoded(to_linear(front) * f64(coverage) / 255 + to_linear(back) * (1 - f64(coverage) / 255))
				ours := f64(line[0] >> shift & 0xFF)
				plain := f64(back) + (f64(front) - f64(back)) * f64(coverage) / 255
				worst_gamma_two = max(worst_gamma_two, abs(ours - exact))
				worst_plain = max(worst_plain, abs(plain - exact))
			}
		}
		fmt.printfln("graphics: %06x over %06x: a gamma of 2 is at most %.1f levels from sRGB; a blend with no gamma, %.1f levels", pair.front, pair.back, worst_gamma_two, worst_plain)
		testing.expect(t, worst_gamma_two < 16)
	}
	// Coverage 0 keeps the pixel; coverage 255 on each stripe is the color.
	line := [2]Color{COLOR_CARD_BOTTOM, COLOR_CARD_BOTTOM}
	words := [2]u32{0, 0xFFFFFFFF}
	blend_coverage_row(raw_data(line[:]), raw_data(words[:]), 0, 2, COLOR_TEXT, .Red_Green_Blue, &table)
	testing.expect_value(t, line[0], Color(COLOR_CARD_BOTTOM))
	testing.expect_value(t, line[1], Color(COLOR_TEXT))
	// The order blue, green, red takes the red coverage for the blue channel.
	line = {0, 0}
	words = {0x00FF0000, 0x00FF0000}
	blend_coverage_row(raw_data(line[:]), raw_data(words[:]), 0, 1, COLOR_WHITE, .Blue_Green_Red, &table)
	testing.expect_value(t, line[0], Color(0x0000FF))
}

// With no glyph cache, text draws Spleen 8x16, at each scale: the fallback.
// The text state is the zero state: no cache yet.
@(test)
text_without_cache_is_spleen :: proc(t: ^testing.T) {
	first, second: [24 * 48]Color
	a := Canvas{pixels = raw_data(first[:]), width = 24, height = 48, stride = 24}
	b := Canvas{pixels = raw_data(second[:]), width = 24, height = 48, stride = 24}
	text(a, 0, 0, "g", COLOR_TEXT)
	character_spleen(b, 0, 0, 'g', COLOR_TEXT)
	testing.expect(t, first == second)
	first, second = {}, {}
	text_scaled(a, 0, 0, "g", COLOR_TEXT, 3)
	character_spleen_enlarged(b, 0, 0, 'g', COLOR_TEXT, 3)
	testing.expect(t, first == second)
}

// The cost of one glyph from the glyph cache against one glyph of Spleen,
// on the host: the same order is the target (docs/FONTS.md, "Measures").
@(test)
glyph_draw_cost :: proc(t: ^testing.T) {
	bytes := #load("../../resources/fonts/jetbrains_mono.ttf")
	font, _ := vector_font.font_open(bytes)
	memory := new(vector_font.Render_Memory)
	defer free(memory)
	out := make([]u64, vector_font.GLYPH_CACHE_LIMIT / 8)
	defer delete(out)
	file := ([^]u8)(raw_data(out))[:vector_font.GLYPH_CACHE_LIMIT]
	size, problem := vector_font.glyph_cache_build(&font, bytes, "jetbrains_mono", true, memory, file)
	testing.expect_value(t, problem, vector_font.Font_Problem.None)
	state: Text_State
	pixels: [64 * 48]Color
	canvas := Canvas{pixels = raw_data(pixels[:]), width = 64, height = 48, stride = 64}
	cache, _ := glyph_cache.validate(file[:size])
	square_root_table_fill(&state.square_root)
	sample := "Rag{0}%e"
	REPEAT :: 200_000
	start := time.tick_now()
	for index in 0 ..< REPEAT {
		character_vector_with(&cache, &state.square_root, .Red_Green_Blue, canvas, 8, 8, sample[index % len(sample)], COLOR_TEXT, 1)
	}
	vector := time.duration_nanoseconds(time.tick_since(start)) / REPEAT
	start = time.tick_now()
	for index in 0 ..< REPEAT {
		character_spleen(canvas, 8, 8, sample[index % len(sample)], COLOR_TEXT)
	}
	spleen := time.duration_nanoseconds(time.tick_since(start)) / REPEAT
	fmt.printfln("graphics: one glyph on the host: from the glyph cache %v ns, Spleen 8x16 %v ns", vector, spleen)
}
