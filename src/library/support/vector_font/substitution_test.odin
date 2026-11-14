#+build !freestanding
package vector_font

import "core:testing"

// The forms of a table GSUB that the test builds: one script DFLT with a
// default language system, one feature "zero", one lookup, one subtable.
@(private = "file")
Gsub_Form :: struct {
	extension:       bool, // A lookup of type 7 that holds the type 1.
	format:          int, // 1: a delta of 10; 2: a list with the substitute 304.
	coverage_format: int, // 1: a list of glyphs; 2: a range of glyphs.
	script:          Feature_Tag,
}

@(private = "file")
put_big_endian :: proc(bytes: ^[dynamic]u8, value: int) {
	append(bytes, u8(value >> 8), u8(value))
}

// gsub_of writes the table. The places are fixed: the header (10 bytes),
// the script list at 10, the feature list at 30, the lookup list at 44.
@(private = "file")
gsub_of :: proc(form: Gsub_Form) -> [dynamic]u8 {
	bytes := make([dynamic]u8)
	put_big_endian(&bytes, 1) // major version
	put_big_endian(&bytes, 0) // minor version
	put_big_endian(&bytes, 10) // the script list
	put_big_endian(&bytes, 30) // the feature list
	put_big_endian(&bytes, 44) // the lookup list
	// Script list at 10: one script, its record, then the script at 18.
	put_big_endian(&bytes, 1)
	append(&bytes, form.script[0], form.script[1], form.script[2], form.script[3])
	put_big_endian(&bytes, 8)
	put_big_endian(&bytes, 4) // Script at 18: the default language system at 22.
	put_big_endian(&bytes, 0)
	put_big_endian(&bytes, 0) // Language system at 22: no lookup order,
	put_big_endian(&bytes, 0xFFFF) // no required feature,
	put_big_endian(&bytes, 1) // one feature: index 0.
	put_big_endian(&bytes, 0)
	// Feature list at 30: "zero", the feature at 38.
	put_big_endian(&bytes, 1)
	append(&bytes, 'z', 'e', 'r', 'o')
	put_big_endian(&bytes, 8)
	put_big_endian(&bytes, 0) // Feature at 38: no parameters,
	put_big_endian(&bytes, 1) // one lookup: index 0.
	put_big_endian(&bytes, 0)
	// Lookup list at 44: one lookup at 48.
	put_big_endian(&bytes, 1)
	put_big_endian(&bytes, 4)
	put_big_endian(&bytes, form.extension ? 7 : 1) // Lookup at 48.
	put_big_endian(&bytes, 0)
	put_big_endian(&bytes, 1)
	put_big_endian(&bytes, 8) // Its subtable at 56.
	if form.extension {
		put_big_endian(&bytes, 1) // Extension at 56: format 1, type 1, offset 8 (a 32-bit offset).
		put_big_endian(&bytes, 1)
		put_big_endian(&bytes, 0)
		put_big_endian(&bytes, 8)
	}
	coverage_offset := form.format == 1 ? 6 : 8
	put_big_endian(&bytes, form.format)
	put_big_endian(&bytes, coverage_offset)
	if form.format == 1 {
		put_big_endian(&bytes, 10) // delta
	} else {
		put_big_endian(&bytes, 1) // one substitute
		put_big_endian(&bytes, 304)
	}
	if form.coverage_format == 1 {
		put_big_endian(&bytes, 1)
		put_big_endian(&bytes, 1)
		put_big_endian(&bytes, 294)
	} else {
		put_big_endian(&bytes, 2) // One range: 294 to 299, its first glyph at coverage index 0.
		put_big_endian(&bytes, 1)
		put_big_endian(&bytes, 294)
		put_big_endian(&bytes, 299)
		put_big_endian(&bytes, 0)
	}
	return bytes
}

@(private = "file")
font_with_gsub :: proc(table: []u8, glyph_count := 400) -> Font_File {
	return {bytes = table, glyph_count = glyph_count, gsub = {0, len(table)}}
}

// Each form gives 304 for 294: a delta or a list, a coverage of a list or
// of a range, a lookup of type 1 or an extension, the script DFLT or latn.
@(test)
a_single_substitution_in_each_form :: proc(t: ^testing.T) {
	forms := [?]Gsub_Form {
		{false, 1, 1, {'D', 'F', 'L', 'T'}},
		{false, 2, 1, {'D', 'F', 'L', 'T'}},
		{false, 1, 2, {'l', 'a', 't', 'n'}},
		{true, 2, 2, {'D', 'F', 'L', 'T'}},
	}
	for form in forms {
		table := gsub_of(form)
		defer delete(table)
		font := font_with_gsub(table[:])
		substitute, problem := single_substitution(&font, {'z', 'e', 'r', 'o'}, 294)
		testing.expectf(t, problem == .None && substitute == 304, "%v: %v %v", form, substitute, problem)
		// A glyph that the coverage does not have, and another feature.
		_, other := single_substitution(&font, {'z', 'e', 'r', 'o'}, 78)
		testing.expect_value(t, other, Font_Problem.No_Feature)
		_, other_feature := single_substitution(&font, {'s', 's', '0', '1'}, 294)
		testing.expect_value(t, other_feature, Font_Problem.No_Feature)
	}
	// A script that is neither DFLT nor latn: no feature.
	table := gsub_of({false, 1, 1, {'c', 'y', 'r', 'l'}})
	defer delete(table)
	font := font_with_gsub(table[:])
	_, problem := single_substitution(&font, {'z', 'e', 'r', 'o'}, 294)
	testing.expect_value(t, problem, Font_Problem.No_Feature)
	// A font with no table GSUB.
	none: Font_File
	_, absent := single_substitution(&none, {'z', 'e', 'r', 'o'}, 294)
	testing.expect_value(t, absent, Font_Problem.No_Feature)
}

// A damaged table GSUB gives its problem, and no damage makes a fault: the
// version, an offset past the end, a feature or a lookup index past its
// list, a coverage longer than the table, an unknown format, a substitute
// past the glyphs of the font, and the table cut at each length.
@(test)
a_damaged_substitution_table :: proc(t: ^testing.T) {
	good := gsub_of({false, 1, 1, {'D', 'F', 'L', 'T'}})
	defer delete(good)
	Damage :: struct {
		offset: int,
		value:  int,
		kind:   Font_Problem,
	}
	damages := [?]Damage {
		{0, 2, .Unknown_Format}, // major version 2
		{6, 0xFFFF, .Too_Short}, // the feature list past the end
		{28, 3, .Unknown_Format}, // the feature index 3 of a list of 1
		{42, 5, .Unknown_Format}, // the lookup index 5 of a list of 1
		{64, 0xFFFF, .Too_Short}, // a coverage of 65535 glyphs
		{62, 3, .Unknown_Format}, // coverage format 3
		{56, 3, .Unknown_Format}, // subtable format 3
		{54, 0xFFFF, .Too_Short}, // the subtable past the end
	}
	table := make([]u8, len(good))
	defer delete(table)
	for damage in damages {
		copy(table, good[:])
		table[damage.offset] = u8(damage.value >> 8)
		table[damage.offset + 1] = u8(damage.value)
		font := font_with_gsub(table)
		_, problem := single_substitution(&font, {'z', 'e', 'r', 'o'}, 294)
		testing.expectf(t, problem == damage.kind, "a damage at %v: %v, expected %v", damage.offset, problem, damage.kind)
	}
	// A substitute past the glyphs of the font.
	few := font_with_gsub(good[:], 300)
	_, past := single_substitution(&few, {'z', 'e', 'r', 'o'}, 294)
	testing.expect_value(t, past, Font_Problem.Unknown_Format)
	// The table cut at each length: never a substitute.
	for length in 1 ..< len(good) {
		cut := font_with_gsub(good[:length])
		_, problem := single_substitution(&cut, {'z', 'e', 'r', 'o'}, 294)
		testing.expectf(t, problem != .None, "the table cut at %v gives a substitute", length)
	}
	// A table that the directory places past the end of the file.
	outside := font_with_gsub(good[:])
	outside.gsub = {len(good) - 2, 10}
	_, outside_problem := single_substitution(&outside, {'z', 'e', 'r', 'o'}, 294)
	testing.expect_value(t, outside_problem, Font_Problem.Too_Short)
}

// The subsets of Paper Mono that "kerneltool vector_fonts" writes draw the
// slashed zero: 3 contours and 32 points, where the zero of the font has 2
// contours (24 points in Regular, 26 in SemiBold), like the capital O.
@(test)
the_zero_of_the_paper_mono_subsets :: proc(t: ^testing.T) {
	subsets := [2][]u8{#load("../../../../resources/fonts/paper_mono.ttf"), #load("../../../../resources/fonts/paper_mono_semibold.ttf")}
	memory := new(Render_Memory)
	defer free(memory)
	outline := Outline{points = memory.points[:], contour_ends = memory.contours[:]}
	for bytes in subsets {
		font, problem := font_open(bytes)
		testing.expect_value(t, problem, Font_Problem.None)
		zero, _ := glyph_of(&font, '0')
		testing.expect_value(t, glyph_outline(&font, zero, &outline), Font_Problem.None)
		testing.expect_value(t, outline.contour_count, 3)
		testing.expect_value(t, outline.point_count, 32)
		capital, _ := glyph_of(&font, 'O')
		testing.expect_value(t, glyph_outline(&font, capital, &outline), Font_Problem.None)
		testing.expect_value(t, outline.contour_count, 2)
	}
}
