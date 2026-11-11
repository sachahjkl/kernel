#+build !freestanding
package vector_font

import "contract:glyph_cache"
import "core:fmt"
import "core:testing"

@(private = "file")
b612_regular := #load("../../resources/fonts/b612.ttf")
@(private = "file")
b612_bold := #load("../../resources/fonts/b612_bold.ttf")

// The positions of the interface font (docs/FONTS.md, section 12.4): three
// at scale 1, one at the scales 2 and 3; the bold weight at scale 1 only.
@(private = "file")
regular_positions := [3]int{3, 1, 1}
@(private = "file")
bold_positions := [1]int{3}

@(private = "file")
proportional_cache_of :: proc(t: ^testing.T, bytes: []u8, name: string, positions: []int) -> (file: []u8, size: int) {
	font, problem := font_open(bytes)
	testing.expect_value(t, problem, Font_Problem.None)
	memory := new(Render_Memory)
	defer free(memory)
	out := make([]u64, PROPORTIONAL_GLYPH_CACHE_LIMIT / 8)
	file = ([^]u8)(raw_data(out))[:PROPORTIONAL_GLYPH_CACHE_LIMIT]
	size, problem = glyph_cache_build_proportional(&font, bytes, name, true, memory, file, positions)
	testing.expect_value(t, problem, Font_Problem.None)
	return file, size
}

// The cache of B612: valid; its advances and its pairs are those of the
// font file scaled to the grid (one unit is 1/150 of a pixel at scale 1,
// so an advance of 1300 units is 8.67 pixels: 555 in 1/64); each glyph of
// a size has its positions; the same font gives the same file.
@(test)
the_glyph_cache_of_b612 :: proc(t: ^testing.T) {
	file, size := proportional_cache_of(t, b612_regular, "b612", regular_positions[:])
	defer free(raw_data(file))
	cache, refused := glyph_cache.validate(file[:size])
	testing.expect_value(t, refused.kind, glyph_cache.Problem_Kind.None)
	fmt.printfln("vector_font: the glyph cache of b612 with the positions %v: %v bytes, %v pairs for each size", regular_positions, size, cache.header.pair_count)
	testing.expect_value(t, len(cache.sizes), 3)
	testing.expect_value(t, cache.sizes[0].position_count, u16(3))
	testing.expect_value(t, cache.sizes[1].position_count, u16(1))
	testing.expect_value(t, cache.header.pair_count, u32(232))
	testing.expect_value(t, cache.sizes[0].baseline, u16(12))
	Known :: struct {
		character: u8,
		scale:     int,
		advance:   i32,
	}
	knowns := [?]Known{{'A', 1, 555}, {'i', 1, 256}, {'M', 1, 768}, {' ', 1, 299}, {'W', 1, 811}, {'A', 2, 1109}, {'i', 3, 768}}
	for known in knowns {
		advance := glyph_cache.advances_of(&cache, known.scale)[known.character - 32]
		testing.expectf(t, advance == known.advance, "the advance of %c at scale %v: %v, expected %v", known.character, known.scale, advance, known.advance)
	}
	// "To": -100 units, -42.67 in 1/64, rounded to -43; "LV": -150 units, -64.
	pairs := glyph_cache.pairs_of(&cache, 1)
	found_to, found_lv := false, false
	for pair in pairs {
		if pair.left == 'T' && pair.right == 'o' {
			found_to = pair.adjustment == -43
		}
		if pair.left == 'L' && pair.right == 'V' {
			found_lv = pair.adjustment == -64
		}
		testing.expect(t, !(pair.left == 'A' && pair.right == 'V')) // B612 has no pair "AV".
	}
	testing.expect(t, found_to && found_lv)
	// Each position of a glyph with ink is a glyph with ink, and starts at
	// the column of position 0 or the next one; a space has no ink.
	for character in u8(33) ..= 126 {
		_, first, _ := glyph_cache.glyph_at_position(&cache, character, 1, 0)
		for position in 1 ..< 3 {
			_, entry, found := glyph_cache.glyph_at_position(&cache, character, 1, position)
			testing.expect(t, found && entry.row_count > 0 && first.row_count > 0)
			testing.expectf(t, entry.left == first.left || entry.left == first.left + 1, "%c at position %v starts at %v, position 0 at %v", character, position, entry.left, first.left)
		}
	}
	_, space, _ := glyph_cache.glyph_at_position(&cache, ' ', 1, 2)
	testing.expect_value(t, space.row_count, u16(0))
	_, _, past := glyph_cache.glyph_at_position(&cache, 'A', 2, 1)
	testing.expect(t, !past) // Scale 2 has one position.
	// The positions of a stem differ: "l" at 0 and at 1/3 of a pixel.
	_, at_zero, _ := glyph_cache.glyph_at_position(&cache, 'l', 1, 0)
	_, at_third, _ := glyph_cache.glyph_at_position(&cache, 'l', 1, 1)
	zero_words := cache.words[at_zero.word_offset:][:int(at_zero.row_count) * int(at_zero.width)]
	third_words := cache.words[at_third.word_offset:][:int(at_third.row_count) * int(at_third.width)]
	testing.expect(t, at_zero.width != at_third.width || at_zero.left != at_third.left || string(([^]u8)(raw_data(zero_words))[:4 * len(zero_words)]) != string(([^]u8)(raw_data(third_words))[:4 * len(third_words)]))
	// The same font gives the same file.
	again, again_size := proportional_cache_of(t, b612_regular, "b612", regular_positions[:])
	defer free(raw_data(again))
	testing.expect(t, again_size == size && string(again[:size]) == string(file[:size]))
	// The bold weight at scale 1.
	bold, bold_size := proportional_cache_of(t, b612_bold, "b612_bold", bold_positions[:])
	defer free(raw_data(bold))
	bold_cache, bold_refused := glyph_cache.validate(bold[:bold_size])
	testing.expect_value(t, bold_refused.kind, glyph_cache.Problem_Kind.None)
	testing.expect_value(t, len(bold_cache.sizes), 1)
	testing.expect_value(t, bold_cache.header.pair_count, u32(239))
	fmt.printfln("vector_font: the glyph cache of b612_bold at scale 1 with 3 positions: %v bytes", bold_size)
}

// The size of B612 on the grid comes from the cap height that the font
// states (1500 units in both weights), not from the top of the outline of
// "H" (1520 in Regular, 1527 in Bold, the angled tops of its stems): one
// cell is 1200 units in both weights. So a flat capital sits on exactly 10
// rows at scale 1, rows 2 to 11 over the baseline on row 12.
@(test)
a_flat_capital_sits_on_ten_rows :: proc(t: ^testing.T) {
	memory := new(Render_Memory)
	defer free(memory)
	for bytes in ([2][]u8{b612_regular, b612_bold}) {
		font, problem := font_open(bytes)
		testing.expect_value(t, problem, Font_Problem.None)
		measures, measured := font_measures(&font, memory)
		testing.expect_value(t, measured, Font_Problem.None)
		testing.expect(t, measures.cap_height > 1500) // The top of "H".
		placed, placed_problem := proportional_measures(&font, measures)
		testing.expect_value(t, placed_problem, Font_Problem.None)
		testing.expect_value(t, placed.cap_height, 1500)
		testing.expect_value(t, placed.x_height, 1100)
		testing.expect_value(t, placed.advance, 1200)
	}
	file, size := proportional_cache_of(t, b612_regular, "b612", regular_positions[:])
	defer free(raw_data(file))
	cache, _ := glyph_cache.validate(file[:size])
	for character in ([?]u8{'E', 'T', 'Z'}) {
		size_entry, entry, _ := glyph_cache.glyph_at_position(&cache, character, 1, 0)
		testing.expect_value(t, size_entry.baseline, u16(12))
		testing.expectf(t, entry.first_row == 2 && entry.row_count == 10, "%c: rows %v to %v, expected 2 to 11", character, entry.first_row, int(entry.first_row) + int(entry.row_count) - 1)
	}
}

// The rounding of a length of the font to 1/64 of a pixel: the nearest
// integer, a half toward plus infinity, the same rule for a negative
// value. At scale 1 of B612 (1200 units for 8 pixels), -100 units are
// -42.67/64: -43; -150 units are -64 exactly.
@(test)
the_rounding_of_a_length :: proc(t: ^testing.T) {
	testing.expect_value(t, units_to_subpixels(-100, 1, 1200), i32(-43))
	testing.expect_value(t, units_to_subpixels(100, 1, 1200), i32(43))
	testing.expect_value(t, units_to_subpixels(-150, 1, 1200), i32(-64))
	testing.expect_value(t, units_to_subpixels(-50, 1, 1200), i32(-21)) // -21.33
	testing.expect_value(t, units_to_subpixels(-100, 3, 1200), i32(-128))
	// A half: toward plus infinity on both sides.
	testing.expect_value(t, divide_rounded(-85, 2), i64(-42))
	testing.expect_value(t, divide_rounded(85, 2), i64(43))
}

// The place of a glyph of text: the nearest third of a pixel.
@(test)
the_position_of_a_place :: proc(t: ^testing.T) {
	Case :: struct {
		place:    i64,
		pixel:    i64,
		position: int,
	}
	cases := [?]Case{{0, 0, 0}, {10, 0, 0}, {11, 0, 1}, {21, 0, 1}, {32, 0, 2}, {53, 0, 2}, {54, 1, 0}, {64 * 7 + 22, 7, 1}, {-1, 0, 0}, {-40, -1, 1}, {-64, -1, 0}}
	for item in cases {
		pixel, position := glyph_cache.position_of(item.place, 3)
		testing.expectf(t, pixel == item.pixel && position == item.position, "%v: %v %v, expected %v %v", item.place, pixel, position, item.pixel, item.position)
	}
	pixel, position := glyph_cache.position_of(64 * 5 + 40, 1)
	testing.expect(t, pixel == 6 && position == 0)
}

// A damaged field of the new parts of version 2 is refused with its
// problem, and no damage makes a fault.
@(test)
a_damaged_proportional_glyph_cache :: proc(t: ^testing.T) {
	file, size := proportional_cache_of(t, b612_regular, "b612", regular_positions[:])
	defer free(raw_data(file))
	good := make([]u8, size)
	defer delete(good)
	copy(good, file[:size])
	pair_count := int((^glyph_cache.Header)(raw_data(good)).pair_count)
	layout := cache_layout_of(regular_positions[:], pair_count)
	glyph_a := layout.glyphs + ('A' - 32) * glyph_cache.GLYPH_ENTRY_SIZE
	Damage :: struct {
		offset: int,
		bytes:  [4]u8,
		count:  int,
		kind:   glyph_cache.Problem_Kind,
	}
	damages := [?]Damage {
		{layout.sizes + 6, {4, 0, 0, 0}, 2, .Bad_Count}, // four positions
		{layout.sizes + 6, {0, 0, 0, 0}, 2, .Bad_Count}, // no position
		{layout.sizes + glyph_cache.SIZE_ENTRY_SIZE + 8, {1, 0, 0, 0}, 4, .Bad_Count}, // scale 2 does not start after scale 1
		{glyph_a + 10, {65, 0, 0, 0}, 2, .Bad_Glyph}, // a width of 65
		{glyph_a + 8, {0xEF, 0xFF, 0, 0}, 2, .Bad_Glyph}, // a left side of -17
		{glyph_a + 8, {65, 0, 0, 0}, 2, .Bad_Glyph}, // a left side of 65
		{glyph_a + 10, {0xFF, 0xFF, 0, 0}, 2, .Bad_Glyph}, // a width of 65535
		{layout.advances, {0x01, 0x10, 0, 0}, 4, .Bad_Advance}, // 4097
		{layout.advances + 4, {0xFF, 0xFF, 0xFF, 0xFF}, 4, .Bad_Advance}, // -1
		{layout.pairs, {31, 0, 0, 0}, 1, .Bad_Pair}, // a left character before the cache
		{layout.pairs + 1, {127, 0, 0, 0}, 1, .Bad_Pair}, // a right character after it
		{layout.pairs + 4, {0x01, 0x10, 0, 0}, 4, .Bad_Pair}, // an adjustment of 4097
		{layout.pairs + 4, {0xFF, 0xEF, 0xFF, 0xFF}, 4, .Bad_Pair}, // an adjustment of -4097
		{120, {0x42, 0x23, 0, 0}, 4, .Bad_Count}, // 9026 pairs
	}
	for damage in damages {
		copy(file[:size], good)
		bytes := damage.bytes
		copy(file[damage.offset:][:damage.count], bytes[:damage.count])
		_, problem := glyph_cache.validate(file[:size])
		testing.expectf(t, problem.kind == damage.kind, "a damage at %v: %v, expected %v", damage.offset, problem.kind, damage.kind)
	}
	// A pair twice: the first pair copied over the second.
	copy(file[:size], good)
	copy(file[layout.pairs + glyph_cache.PAIR_ENTRY_SIZE:][:glyph_cache.PAIR_ENTRY_SIZE], good[layout.pairs:][:glyph_cache.PAIR_ENTRY_SIZE])
	_, twice := glyph_cache.validate(file[:size])
	testing.expect_value(t, twice.kind, glyph_cache.Problem_Kind.Bad_Pair)
	// The pairs of scale 2 out of order: its first pair moved to the end.
	copy(file[:size], good)
	scale_two := layout.pairs + pair_count * glyph_cache.PAIR_ENTRY_SIZE
	copy(file[scale_two + (pair_count - 1) * glyph_cache.PAIR_ENTRY_SIZE:][:glyph_cache.PAIR_ENTRY_SIZE], good[scale_two:][:glyph_cache.PAIR_ENTRY_SIZE])
	_, order := glyph_cache.validate(file[:size])
	testing.expect_value(t, order.kind, glyph_cache.Problem_Kind.Bad_Pair)
	// One pair more than the file holds: refused.
	copy(file[:size], good)
	(^glyph_cache.Header)(raw_data(file)).pair_count += 1
	_, more := glyph_cache.validate(file[:size])
	testing.expect(t, more.kind != .None)
	// Cut at any length: refused, no fault.
	for length := 0; length < size; length += 977 {
		copy(file[:size], good)
		_, problem := glyph_cache.validate(file[:length])
		testing.expect(t, problem.kind != .None)
	}
}
