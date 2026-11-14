#+build !freestanding
package text_shaping_module

import "modus:contract/errors"
import "modus:contract/glyph_cache"
import "core:testing"
import "modus:support/system"
import shaping "modus:support/text_shaping"
import "modus:support/vector_font"

@(private = "file")
b612_regular := #load("../../../resources/fonts/b612.ttf")

// The spacing of scale 1 of the glyph cache of B612, as the two tables that
// a caller gives: the advances and the pairs. The memory of the cache stays
// for the test.
@(private = "file")
Test_Font :: struct {
	memory:   []u64,
	spacing:  shaping.Spacing,
	advances: system.Table_To_Read(shaping.Character_Advance),
	pairs:    system.Table_To_Read(glyph_cache.Pair_Entry),
}

@(private = "file")
test_font_of :: proc(t: ^testing.T) -> (font: Test_Font) {
	file, problem := vector_font.font_open(b612_regular)
	testing.expect_value(t, problem, vector_font.Font_Problem.None)
	render := new(vector_font.Render_Memory)
	defer free(render)
	font.memory = make([]u64, vector_font.PROPORTIONAL_GLYPH_CACHE_LIMIT / 8)
	out := ([^]u8)(raw_data(font.memory))[:vector_font.PROPORTIONAL_GLYPH_CACHE_LIMIT]
	positions := [3]int{3, 1, 1}
	size: int
	size, problem = vector_font.glyph_cache_build_proportional(&file, b612_regular, "b612", true, render, out, positions[:])
	testing.expect_value(t, problem, vector_font.Font_Problem.None)
	cache, refused := glyph_cache.validate(out[:size])
	testing.expect_value(t, refused.kind, glyph_cache.Problem_Kind.None)
	ok: bool
	font.spacing, ok = shaping.spacing_of(&cache, 1)
	testing.expect(t, ok)
	font.advances = {records = ([^]shaping.Character_Advance)(rawptr(raw_data(font.spacing.advances))), count = u64(len(font.spacing.advances)), capacity = u64(len(font.spacing.advances))}
	font.pairs = {records = raw_data(font.spacing.pairs), count = u64(len(font.spacing.pairs)), capacity = u64(len(font.spacing.pairs))}
	return font
}

@(private = "file")
bytes_to_read :: proc(bytes: []u8) -> system.Bytes_To_Read {
	return {bytes = raw_data(bytes), count = u64(len(bytes)), capacity = u64(len(bytes))}
}

// The three ways to call give the same records: the package compiled in;
// the export called with the tables of the caller (a direct call of the
// module); the export called with copies of the tables in another place,
// whose answer is copied back (the form of an isolated call, where the
// receiver sees the tables in the call region).
@(test)
the_three_ways_give_the_same_records :: proc(t: ^testing.T) {
	font := test_font_of(t)
	defer delete(font.memory)
	text := "Settings: To AVATAR, LT Wave."
	text_bytes := transmute([]u8)text
	// 1. The package.
	compiled_in: [64]shaping.Placed_Glyph
	count, width, ok := shaping.shape(&font.spacing, text_bytes, compiled_in[:])
	testing.expect(t, ok && count == len(text))
	// 2. The export over the tables of the caller.
	direct: [64]shaping.Placed_Glyph
	placed := system.Table_To_Append(shaping.Placed_Glyph){records = &direct[0], count = 0, capacity = 64}
	text_table := bytes_to_read(text_bytes)
	error: errors.Error_Record
	testing.expect_value(t, shape_text(&font.advances, &font.pairs, &text_table, &placed, &error), i64(len(text)))
	testing.expect_value(t, error.kind, i64(0))
	// 3. The export over copies, the answer copied back.
	region_advances := make([]shaping.Character_Advance, len(font.spacing.advances))
	defer delete(region_advances)
	for advance, index in font.spacing.advances {
		region_advances[index] = {advance}
	}
	region_pairs := make([]glyph_cache.Pair_Entry, len(font.spacing.pairs))
	defer delete(region_pairs)
	copy(region_pairs, font.spacing.pairs)
	region_text := make([]u8, len(text))
	defer delete(region_text)
	copy(region_text, text_bytes)
	region_placed: [64]shaping.Placed_Glyph
	advances_copy := system.Table_To_Read(shaping.Character_Advance){records = raw_data(region_advances), count = u64(len(region_advances)), capacity = u64(len(region_advances))}
	pairs_copy := system.Table_To_Read(glyph_cache.Pair_Entry){records = raw_data(region_pairs), count = u64(len(region_pairs)), capacity = u64(len(region_pairs))}
	text_copy := bytes_to_read(region_text)
	placed_copy := system.Table_To_Append(shaping.Placed_Glyph){records = &region_placed[0], count = 0, capacity = 64}
	testing.expect_value(t, shape_text(&advances_copy, &pairs_copy, &text_copy, &placed_copy, &error), i64(len(text)))
	isolated: [64]shaping.Placed_Glyph
	copy(isolated[:placed_copy.count], region_placed[:placed_copy.count])
	testing.expect(t, compiled_in == direct && direct == isolated, "the same placed glyphs in the three ways")
	// The measure in the three ways: the width of shape.
	ranges := [2]shaping.Text_Range{{start = 0, count = u32(len(text))}, {start = 9, count = 2}}
	problem, _, _ := shaping.measure_ranges(&font.spacing, text_bytes, ranges[:])
	testing.expect(t, problem == .None && ranges[0].width == width)
	direct_ranges := [2]shaping.Text_Range{{start = 0, count = u32(len(text))}, {start = 9, count = 2}}
	range_table := system.Table_To_Change(shaping.Text_Range){records = &direct_ranges[0], count = 2, capacity = 2}
	testing.expect_value(t, measure_texts(&font.advances, &font.pairs, &text_table, &range_table, &error), 2)
	region_ranges := [2]shaping.Text_Range{{start = 0, count = u32(len(text))}, {start = 9, count = 2}}
	range_copy := system.Table_To_Change(shaping.Text_Range){records = &region_ranges[0], count = 2, capacity = 2}
	testing.expect_value(t, measure_texts(&advances_copy, &pairs_copy, &text_copy, &range_copy, &error), 2)
	testing.expect(t, ranges == direct_ranges && direct_ranges == region_ranges, "the same widths in the three ways")
}

// The Append rule across calls: the count of the full answer; nothing is
// written at or after the capacity; each text starts at x 0.
@(test)
placed_glyphs_across_calls :: proc(t: ^testing.T) {
	font := test_font_of(t)
	defer delete(font.memory)
	memory: [4]shaping.Placed_Glyph // 3 places, then a guard record.
	memory[3] = {glyph = 0xA5A5_A5A5}
	placed := system.Table_To_Append(shaping.Placed_Glyph){records = &memory[0], count = 0, capacity = 3}
	error: errors.Error_Record
	two := bytes_to_read(transmute([]u8)string("To"))
	testing.expect_value(t, shape_text(&font.advances, &font.pairs, &two, &placed, &error), 2)
	testing.expect_value(t, shape_text(&font.advances, &font.pairs, &two, &placed, &error), 4) // 1 of 2 fits.
	testing.expect_value(t, memory[2].x, i32(0)) // The "T" of the second text, at its origin.
	testing.expect_value(t, memory[2].glyph, u32('T' - 32))
	empty := bytes_to_read(nil)
	testing.expect_value(t, shape_text(&font.advances, &font.pairs, &empty, &placed, &error), 4)
	testing.expect_value(t, shape_text(&font.advances, &font.pairs, &two, &placed, &error), 6)
	testing.expect_value(t, memory[3].glyph, u32(0xA5A5_A5A5))
}

// Each count of a hostile caller is refused with its argument named; no
// value of a table makes a fault or a sum that wraps.
@(test)
hostile_callers_are_refused :: proc(t: ^testing.T) {
	font := test_font_of(t)
	defer delete(font.memory)
	error: errors.Error_Record
	text := bytes_to_read(transmute([]u8)string("To"))
	room: [4]shaping.Placed_Glyph
	placed := system.Table_To_Append(shaping.Placed_Glyph){records = &room[0], count = 0, capacity = 4}
	expect_error :: proc(t: ^testing.T, result: i64, error: errors.Error_Record, kind: errors.Kind, argument: i64, loc := #caller_location) {
		testing.expect_value(t, result, -1, loc = loc)
		testing.expect_value(t, errors.Kind(error.kind), kind, loc = loc)
		testing.expect_value(t, error.argument, argument, loc = loc)
	}
	// 94 and 96 advances.
	short := font.advances
	short.count = 94
	expect_error(t, shape_text(&short, &font.pairs, &text, &placed, &error), error, .Too_Small, 1)
	long := font.advances
	long.count = 96
	expect_error(t, shape_text(&long, &font.pairs, &text, &placed, &error), error, .Too_Long, 1)
	// More pairs than a cache holds: the records are not read.
	many := font.pairs
	many.count = glyph_cache.PAIR_LIMIT + 1
	expect_error(t, shape_text(&font.advances, &many, &text, &placed, &error), error, .Too_Long, 2)
	// A text over the limit.
	large := make([]u8, shaping.TEXT_LIMIT + 1)
	defer delete(large)
	large_text := bytes_to_read(large)
	expect_error(t, shape_text(&font.advances, &font.pairs, &large_text, &placed, &error), error, .Too_Long, 3)
	// A capacity of 2^63: a negative int.
	huge := system.Table_To_Append(shaping.Placed_Glyph){records = &room[0], count = 0, capacity = 1 << 63}
	expect_error(t, shape_text(&font.advances, &font.pairs, &text, &huge, &error), error, .Too_Long, 4)
	testing.expect_value(t, placed.count, u64(0))
	// A range past the bytes, and one over the limit: the ranges before it
	// have their width.
	ranges := [3]shaping.Text_Range{{start = 0, count = 2}, {start = 1, count = 2}, {start = 0, count = 1}}
	range_table := system.Table_To_Change(shaping.Text_Range){records = &ranges[0], count = 3, capacity = 3}
	expect_error(t, measure_texts(&font.advances, &font.pairs, &text, &range_table, &error), error, .Out_Of_Range, 4)
	testing.expect(t, error.value == 3 && error.limit == 2 && error.found == 2)
	testing.expect(t, ranges[0].width > 0 && ranges[1].width == 0)
	long_ranges := [1]shaping.Text_Range{{start = 0, count = shaping.TEXT_LIMIT + 1}}
	long_table := system.Table_To_Change(shaping.Text_Range){records = &long_ranges[0], count = 1, capacity = 1}
	expect_error(t, measure_texts(&font.advances, &font.pairs, &large_text, &long_table, &error), error, .Too_Long, 4)
	testing.expect_value(t, error.found, i64(1))
	// Advances and pairs at the ends of their numbers, and pairs out of
	// order: other numbers, each in its limits, and no fault.
	wild_advances: [95]shaping.Character_Advance
	for &advance, index in wild_advances {
		advance.advance = index % 2 == 0 ? max(i32) : min(i32)
	}
	wild_pairs := [3]glyph_cache.Pair_Entry{{left = 'T', right = 'o', adjustment = max(i32)}, {left = 'A', right = 'V', adjustment = min(i32)}, {left = 200, right = 1, adjustment = max(i32)}}
	advances := system.Table_To_Read(shaping.Character_Advance){records = &wild_advances[0], count = 95, capacity = 95}
	pairs := system.Table_To_Read(glyph_cache.Pair_Entry){records = &wild_pairs[0], count = 3, capacity = 3}
	all := make([]u8, shaping.TEXT_LIMIT)
	defer delete(all)
	for &byte, index in all {
		byte = u8(index % 256)
	}
	all_text := bytes_to_read(all)
	output := make([]shaping.Placed_Glyph, shaping.TEXT_LIMIT)
	defer delete(output)
	wild := system.Table_To_Append(shaping.Placed_Glyph){records = raw_data(output), count = 0, capacity = u64(len(output))}
	testing.expect_value(t, shape_text(&advances, &pairs, &all_text, &wild, &error), i64(shaping.TEXT_LIMIT))
	for glyph in output {
		testing.expect(t, glyph.advance >= -glyph_cache.ADVANCE_LIMIT && glyph.advance <= 2 * glyph_cache.ADVANCE_LIMIT && glyph.glyph < 95)
	}
}
