// Text shaping as a module (docs/FONTS.md, section 12.3): each export calls
// one function of src/library/support/text_shaping over tables in memory of the
// caller. The spacing of the font is two tables of the caller: the
// advances of the characters 32 to 126 and the pairs, of one scale of a
// glyph cache (text_shaping.spacing_of gives them from a cache). The
// module holds no state of a program.
//
// The tables are hostile input: the counts are checked here; each advance,
// each pair, each byte and each range is read once by the package, and kept
// in its limits there, because the caller can change them during the call.
//
// **What it is for.** A proportional font needs the place of each glyph:
// its advance, and the adjustment of each pair of characters. This module
// gives that work through the call form, in batches, so one call places a
// whole text or measures all the labels of a window. Because the spacing
// comes from the caller, the module holds no font and no state, and an
// isolated call gives the same answer as a direct call. A program in the
// system calls the package `src/library/support/text_shaping` directly; this module is
// the same code for a caller that loads it or isolates it.
//
// **The units**: each position and width is in 1/64 of a pixel.
//
// **What it does not do**: no character outside 32 to 126 (each such byte
// is placed as "?"), no ligature, no direction other than left to right.
package text_shaping_module

import "modus:contract/errors"
import "modus:contract/glyph_cache"
import "modus:support/system"
import shaping "modus:support/text_shaping"

// The most records or bytes of a table of a caller, its count included: no
// count times a size wraps, and a count holds in the i64 of the result.
@(private)
TABLE_LIMIT :: u64(1) << 40

// spacing_of_tables makes the spacing of the package over the two tables.
// It gives an error record for advances that are not 95 records (argument
// 1) or more pairs than glyph_cache.PAIR_LIMIT (argument 2).
@(private)
spacing_of_tables :: proc "contextless" (advances: ^system.Table_To_Read(shaping.Character_Advance), pairs: ^system.Table_To_Read(glyph_cache.Pair_Entry), spacing: ^shaping.Spacing, error: ^errors.Error_Record) -> bool {
	if advances.count != shaping.CHARACTER_COUNT {
		errors.fail(error, -1, advances.count < shaping.CHARACTER_COUNT ? errors.Kind.Too_Small : errors.Kind.Too_Long, .Records, 1, i64(min(advances.count, TABLE_LIMIT)), shaping.CHARACTER_COUNT)
		return false
	}
	if pairs.count > glyph_cache.PAIR_LIMIT {
		errors.fail(error, -1, .Too_Long, .Records, 2, i64(min(pairs.count, TABLE_LIMIT)), glyph_cache.PAIR_LIMIT)
		return false
	}
	spacing.advances = ([^]i32)(rawptr(advances.records))[:shaping.CHARACTER_COUNT]
	spacing.pairs = pairs.records[:pairs.count]
	return true
}

// shape_text appends the placed glyphs of a text: one for each byte, x from the origin of the text and the advance with the pair adjustment, in 1/64 of a pixel. A byte outside 32 to 126 is placed as "?". The result is the count of placed glyphs of the full answer (larger than the capacity: it did not fit), or -1 with an error record: advances that are not 95 records (argument 1), more than 9025 pairs (argument 2), a text of more than 65536 bytes (argument 3), a table of placed glyphs over 2^40 records (argument 4).
@(export, link_name = "shape_text")
shape_text :: proc "c" (advances: ^system.Table_To_Read(shaping.Character_Advance), pairs: ^system.Table_To_Read(glyph_cache.Pair_Entry), text: ^system.Bytes_To_Read, placed: ^system.Table_To_Append(shaping.Placed_Glyph), error: ^errors.Error_Record) -> i64 {
	spacing: shaping.Spacing
	if !spacing_of_tables(advances, pairs, &spacing, error) {
		return -1
	}
	if text.count > shaping.TEXT_LIMIT {
		return errors.fail(error, -1, .Too_Long, .Bytes, 3, i64(min(text.count, TABLE_LIMIT)), shaping.TEXT_LIMIT)
	}
	if placed.capacity > TABLE_LIMIT || placed.count > TABLE_LIMIT {
		return errors.fail(error, -1, .Too_Long, .Records, 4, i64(min(max(placed.capacity, placed.count), TABLE_LIMIT + 1)), i64(TABLE_LIMIT))
	}
	// The Append rule: write only at or after the count and before the
	// capacity; the count grows by the full answer.
	room: []shaping.Placed_Glyph
	if placed.count < placed.capacity {
		room = placed.records[placed.count:][:placed.capacity - placed.count]
	}
	count, _, _ := shaping.shape(&spacing, text.bytes[:text.count], room)
	placed.count += u64(count)
	return i64(placed.count)
}

// measure_texts writes the width of each text of a table of ranges into one table of bytes, in 1/64 of a pixel: a window measures all its labels in one call. The width of a text is the sum of the advances of its placed glyphs. The result is the count of ranges, or -1 with an error record: advances (argument 1) or pairs (argument 2) as for shape_text, a table of bytes (argument 3) or of ranges (argument 4) over 2^40, a range past the end of the bytes (Out_Of_Range: its end, the count of bytes, the number of the range from 1), or a range of more than 65536 bytes (Too_Long: its count, the limit, the number of the range from 1). The ranges before the one that fails have their width.
@(export, link_name = "measure_texts")
measure_texts :: proc "c" (advances: ^system.Table_To_Read(shaping.Character_Advance), pairs: ^system.Table_To_Read(glyph_cache.Pair_Entry), text: ^system.Bytes_To_Read, ranges: ^system.Table_To_Change(shaping.Text_Range), error: ^errors.Error_Record) -> i64 {
	spacing: shaping.Spacing
	if !spacing_of_tables(advances, pairs, &spacing, error) {
		return -1
	}
	if text.count > TABLE_LIMIT {
		return errors.fail(error, -1, .Too_Long, .Bytes, 3, i64(min(text.count, TABLE_LIMIT + 1)), i64(TABLE_LIMIT))
	}
	if ranges.count > TABLE_LIMIT {
		return errors.fail(error, -1, .Too_Long, .Records, 4, i64(min(ranges.count, TABLE_LIMIT + 1)), i64(TABLE_LIMIT))
	}
	problem, index, end := shaping.measure_ranges(&spacing, text.bytes[:text.count], ranges.records[:ranges.count])
	switch problem {
	case .Past_The_Text:
		return errors.fail(error, -1, .Out_Of_Range, .Bytes, 4, i64(end), i64(text.count), i64(index + 1))
	case .Too_Long:
		return errors.fail(error, -1, .Too_Long, .Bytes, 4, i64(end), shaping.TEXT_LIMIT, i64(index + 1))
	case .None:
	}
	return i64(ranges.count)
}
