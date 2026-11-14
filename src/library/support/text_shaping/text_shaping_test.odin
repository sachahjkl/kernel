#+build !freestanding
package text_shaping

import "modus:contract/glyph_cache"
import "core:testing"
import "modus:support/vector_font"

@(private = "file")
b612_regular := #load("../../../../resources/fonts/b612.ttf")

// test_spacing builds the glyph cache of B612 (three positions at scale 1,
// one at the scales 2 and 3) and gives the spacing of scale 1. The memory
// of the cache stays for the test: the spacing reads it in place.
@(private = "file")
test_spacing :: proc(t: ^testing.T) -> (spacing: Spacing, memory: []u64) {
	font, problem := vector_font.font_open(b612_regular)
	testing.expect_value(t, problem, vector_font.Font_Problem.None)
	render := new(vector_font.Render_Memory)
	defer free(render)
	memory = make([]u64, vector_font.PROPORTIONAL_GLYPH_CACHE_LIMIT / 8)
	out := ([^]u8)(raw_data(memory))[:vector_font.PROPORTIONAL_GLYPH_CACHE_LIMIT]
	positions := [3]int{3, 1, 1}
	size: int
	size, problem = vector_font.glyph_cache_build_proportional(&font, b612_regular, "b612", true, render, out, positions[:])
	testing.expect_value(t, problem, vector_font.Font_Problem.None)
	cache, refused := glyph_cache.validate(out[:size])
	testing.expect_value(t, refused.kind, glyph_cache.Problem_Kind.None)
	ok: bool
	spacing, ok = spacing_of(&cache, 1)
	testing.expect(t, ok)
	return spacing, memory
}

// The width of a text is the sum of the advances of its placed glyphs, and
// the x of each glyph is the sum of the advances before it.
@(test)
the_width_is_the_sum_of_the_placed_glyphs :: proc(t: ^testing.T) {
	spacing, memory := test_spacing(t)
	defer delete(memory)
	text := "To Live: AVATAR, Wave 1234 - the quick brown fox jumps over the lazy dog."
	placed: [128]Placed_Glyph
	count, width, ok := shape(&spacing, transmute([]u8)text, placed[:])
	testing.expect(t, ok)
	testing.expect_value(t, count, len(text))
	sum: i64
	for glyph in placed[:count] {
		testing.expect_value(t, i64(glyph.x), sum)
		testing.expect_value(t, glyph.cluster, u32(0))
		sum += i64(glyph.advance)
	}
	testing.expect_value(t, width, sum)
	measured, measured_ok := text_width(&spacing, transmute([]u8)text)
	testing.expect(t, measured_ok && measured == sum)
}

// The pair adjustment is that of the font file: "To" is -100 units, -43 in
// 1/64 of a pixel at scale 1 (one unit is 1/150 of a pixel); "AV" has no
// pair in B612, so its advance is the advance of "A" alone (555). The rule
// of the sum: the cache rounds the advance and the adjustment each on its
// own, and the shaper adds the two integers: "T" before "o" is 512 - 43 =
// 469. The rounding of the sum of the units (1100 units, 469.33) also
// gives 469 here; for other pairs the two rules differ by 1/64.
@(test)
a_pair_changes_the_advance_by_the_value_of_the_file :: proc(t: ^testing.T) {
	spacing, memory := test_spacing(t)
	defer delete(memory)
	placed: [2]Placed_Glyph
	shape(&spacing, transmute([]u8)string("To"), placed[:])
	testing.expect_value(t, placed[0].advance, spacing.advances['T' - 32] - 43)
	testing.expect_value(t, spacing.advances['T' - 32], 512) // 1200 units.
	testing.expect_value(t, placed[0].advance, 469)
	testing.expect_value(t, placed[1].x, placed[0].advance)
	shape(&spacing, transmute([]u8)string("AV"), placed[:])
	testing.expect_value(t, placed[0].advance, spacing.advances['A' - 32])
	testing.expect_value(t, placed[0].advance, 555) // 1300 units.
	// The last glyph of a text has no pair after it.
	shape(&spacing, transmute([]u8)string("T"), placed[:1])
	testing.expect_value(t, placed[0].advance, 512)
}

// An empty text has no glyph and no width. A character outside the cache
// is placed as "?", with the advance of "?".
@(test)
an_empty_text_and_a_character_outside_the_cache :: proc(t: ^testing.T) {
	spacing, memory := test_spacing(t)
	defer delete(memory)
	count, width, ok := shape(&spacing, nil, nil)
	testing.expect(t, ok && count == 0 && width == 0)
	outside := [3]u8{'\n', 200, 127}
	placed: [3]Placed_Glyph
	count, width, ok = shape(&spacing, outside[:], placed[:])
	testing.expect(t, ok && count == 3)
	question := spacing.advances['?' - 32]
	for glyph in placed {
		testing.expect_value(t, glyph.glyph, u32('?' - 32))
	}
	// The width is the sum, with the pairs of "?" and "?" if the font has one.
	testing.expect_value(t, width, i64(placed[0].advance) + i64(placed[1].advance) + i64(placed[2].advance))
	testing.expect_value(t, placed[2].advance, question)
	// A text over the limit writes nothing.
	long := make([]u8, TEXT_LIMIT + 1)
	defer delete(long)
	placed[0] = {}
	_, _, ok = shape(&spacing, long, placed[:])
	testing.expect(t, !ok)
	testing.expect_value(t, placed[0], Placed_Glyph{})
}

// 10 000 texts in one call give the widths of 10 000 calls of one text.
@(test)
ten_thousand_texts_in_one_call :: proc(t: ^testing.T) {
	spacing, memory := test_spacing(t)
	defer delete(memory)
	COUNT :: 10_000
	words := [?]string{"File", "Edit", "View", "To", "AVATAR", "Wave", "Settings", "", "Lily", "0123456789", "Ty", "LT"}
	bytes := make([dynamic]u8)
	defer delete(bytes)
	ranges := make([]Text_Range, COUNT)
	defer delete(ranges)
	for index in 0 ..< COUNT {
		word := words[index % len(words)]
		ranges[index] = {start = u32(len(bytes)), count = u32(len(word) + index % 3)}
		append(&bytes, ..transmute([]u8)word)
		for _ in 0 ..< index % 3 {
			append(&bytes, 'a' + u8(index % 26))
		}
	}
	problem, measured, _ := measure_ranges(&spacing, bytes[:], ranges)
	testing.expect_value(t, problem, Range_Problem.None)
	testing.expect_value(t, measured, COUNT)
	for range in ranges {
		width, _ := text_width(&spacing, bytes[range.start:][:range.count])
		testing.expect_value(t, range.width, width)
	}
	// A range past the text stops the measure at its index.
	ranges[7] = {start = u32(len(bytes)) - 1, count = 2}
	stopped, index, end := measure_ranges(&spacing, bytes[:], ranges)
	testing.expect(t, stopped == .Past_The_Text && index == 7 && end == u64(len(bytes)) + 1)
}
