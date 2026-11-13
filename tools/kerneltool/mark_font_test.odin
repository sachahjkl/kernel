package kerneltool

import "core:strings"
import "core:testing"
import "support:mark"
import "support:vector_font"

// A license for the tests: the font of a test does not depend on the text
// of the license of the repository.
MARK_FONT_TEST_LICENSE :: "A license\n\nCopyright (c) 2026 The holder\n\nThe text of the license.\n"

// mark_font_test_winding gives how many times the contours of an outline
// turn around a point: 0 for a point outside, and for a point in a hole.
// A contour that turns clockwise, with y up, counts -1.
@(private = "file")
mark_font_test_winding :: proc(outline: ^vector_font.Outline, x, y: int) -> int {
	winding := 0
	first := 0
	for contour in 0 ..< outline.contour_count {
		end := outline.contour_ends[contour]
		for index in first ..< end {
			from := outline.points[index]
			to := outline.points[index + 1 < end ? index + 1 : first]
			from_x, from_y := int(from.x), int(from.y)
			to_x, to_y := int(to.x), int(to.y)
			// Over 0: the point is at the left of the edge.
			side := (to_x - from_x) * (y - from_y) - (x - from_x) * (to_y - from_y)
			if from_y <= y && to_y > y && side > 0 {
				winding += 1
			}
			if from_y > y && to_y <= y && side < 0 {
				winding -= 1
			}
		}
		first = end
	}
	return winding
}

// The font is read by the reader of fonts of the system, which did not
// write it. Each glyph of a letter, sampled at the centre of each cell with
// the rule of the winding that is not zero, is the cells of the letter in
// support/mark. The area of the outline is the area of the filled cells with
// the sign of a clockwise turn: the outer contours turn clockwise, the holes
// the other way, and no contour covers another.
@(test)
mark_font_glyphs_are_the_cells_of_the_letters :: proc(t: ^testing.T) {
	file, built := mark_font_build(MARK_FONT_TEST_LICENSE)
	testing.expect(t, built, "the font is not built")
	font, problem := vector_font.font_open(file)
	testing.expectf(t, problem == .None, "the reader of the system refuses the font: %v", problem)
	if !built || problem != .None {
		return
	}
	testing.expect_value(t, font.units_per_em, MARK_FONT_UNITS_OF_THE_EM)
	testing.expect_value(t, font.glyph_count, MARK_FONT_GLYPH_COUNT)
	testing.expect_value(t, font.ascender, MARK_FONT_ASCENT)
	testing.expect_value(t, font.descender, -MARK_FONT_DESCENT)
	testing.expect_value(t, font.ascender - font.descender, font.units_per_em)
	points: [256]vector_font.Outline_Point
	contour_ends: [16]int
	cell :: MARK_FONT_UNITS_OF_A_CELL
	letters := MARK_FONT_LETTERS
	for letter in 0 ..< mark.NAME_LETTER_COUNT {
		name := letters[letter:letter + 1]
		glyph, glyph_problem := vector_font.glyph_of(&font, rune(letters[letter]))
		testing.expectf(t, glyph_problem == .None && glyph == MARK_FONT_GLYPH_FIRST_LETTER + letter, "%s has the glyph %d (%v)", name, glyph, glyph_problem)
		outline := vector_font.Outline {
			points       = points[:],
			contour_ends = contour_ends[:],
		}
		outline_problem := vector_font.glyph_outline(&font, glyph, &outline)
		testing.expectf(t, outline_problem == .None, "%s: the outline does not read: %v", name, outline_problem)
		if outline_problem != .None {
			continue
		}
		testing.expectf(t, outline.contour_count >= 1, "%s has no contour", name)
		for point in outline.points[:outline.point_count] {
			testing.expectf(t, point.on_curve && int(point.x) % cell == 0 && int(point.y) % cell == 0, "%s: the point (%d, %d) is not a corner of a cell", name, point.x, point.y)
		}
		filled_count := 0
		for row in 0 ..< mark.NAME_ROWS {
			for column in 0 ..< mark.NAME_LETTER_COLUMNS {
				filled := mark.name_letters[letter][row][column] == '1'
				if filled {
					filled_count += 1
				}
				winding := mark_font_test_winding(&outline, column * cell + cell / 2, (mark.NAME_ROWS - 1 - row) * cell + cell / 2)
				testing.expectf(t, winding == (-1 if filled else 0), "%s: the cell at the column %d and the row %d is %v in support/mark, and the outline turns %d times around its centre", name, column, row, filled, winding)
			}
		}
		// Twice the area, by the corners; under 0 for a clockwise turn.
		twice_the_area := 0
		first := 0
		for contour in 0 ..< outline.contour_count {
			end := outline.contour_ends[contour]
			for index in first ..< end {
				from := outline.points[index]
				to := outline.points[index + 1 < end ? index + 1 : first]
				twice_the_area += int(from.x) * int(to.y) - int(to.x) * int(from.y)
			}
			first = end
		}
		testing.expectf(t, twice_the_area == -2 * filled_count * cell * cell, "%s: twice the area of the outline is %d; its %d cells have %d", name, twice_the_area, filled_count, 2 * filled_count * cell * cell)
	}
	// The glyph of a missing character and the space have no contour.
	for glyph in ([]int{MARK_FONT_GLYPH_MISSING, MARK_FONT_GLYPH_SPACE}) {
		outline := vector_font.Outline {
			points       = points[:],
			contour_ends = contour_ends[:],
		}
		testing.expect_value(t, vector_font.glyph_outline(&font, glyph, &outline), vector_font.Font_Problem.None)
		testing.expect_value(t, outline.contour_count, 0)
		testing.expect_value(t, outline.point_count, 0)
	}
}

// The outline goes around the whole letter: one contour for a letter with no
// closed part, two for the o and the d (the letter and its hole), and no
// point on a straight line between its neighbours.
@(test)
mark_font_outlines_are_merged :: proc(t: ^testing.T) {
	expected_contours := [mark.NAME_LETTER_COUNT]int{1, 2, 2, 1, 1}
	for letter in 0 ..< mark.NAME_LETTER_COUNT {
		contours, ok := mark_font_letter_contours(letter)
		testing.expect(t, ok)
		testing.expect_value(t, len(contours), expected_contours[letter])
		for contour in contours {
			testing.expect(t, len(contour) >= 4)
			count := len(contour)
			for point, index in contour {
				before := contour[(index + count - 1) % count]
				after := contour[(index + 1) % count]
				turn := (point.x - before.x) * (after.y - point.y) - (point.y - before.y) * (after.x - point.x)
				testing.expectf(t, turn != 0, "the letter %d has a point on a straight line at (%d, %d)", letter, point.x, point.y)
				testing.expectf(t, (point.x == before.x) != (point.y == before.y), "the letter %d has a side that is not along a row or a column at (%d, %d)", letter, point.x, point.y)
			}
		}
	}
	_, outside := mark_font_letter_contours(mark.NAME_LETTER_COUNT)
	testing.expect(t, outside, "a letter that the name does not have is not an empty outline")
	missing, missing_ok := mark_font_glyph_contours(MARK_FONT_GLYPH_COUNT)
	testing.expect(t, !missing_ok && len(missing) == 0)
}

// The characters: the space, the five letters, and their capitals with the
// glyphs of the small letters. No other character has a glyph.
@(test)
mark_font_characters :: proc(t: ^testing.T) {
	file, built := mark_font_build(MARK_FONT_TEST_LICENSE)
	font, problem := vector_font.font_open(file)
	testing.expect(t, built && problem == .None)
	if !built || problem != .None {
		return
	}
	small := MARK_FONT_LETTERS
	capitals := strings.to_upper(MARK_FONT_LETTERS, context.temp_allocator)
	for index in 0 ..< mark.NAME_LETTER_COUNT {
		for character in ([]rune{rune(small[index]), rune(capitals[index])}) {
			glyph, glyph_problem := vector_font.glyph_of(&font, character)
			testing.expectf(t, glyph_problem == .None && glyph == MARK_FONT_GLYPH_FIRST_LETTER + index, "%v has the glyph %d (%v)", character, glyph, glyph_problem)
		}
	}
	space, space_problem := vector_font.glyph_of(&font, ' ')
	testing.expect(t, space_problem == .None && space == MARK_FONT_GLYPH_SPACE)
	for character in ([]rune{'a', 'n', 'z', 'A', 'Z', '0', '!', '~', 0xE9, 0xFFFF}) {
		_, missing := vector_font.glyph_of(&font, character)
		testing.expectf(t, missing == .No_Glyph, "%v has a glyph", character)
	}
	// The characters are in order and no two are the same: the segments of
	// the table are read by a search.
	mappings := mark_font_mappings()
	testing.expect_value(t, len(mappings), 1 + 2 * mark.NAME_LETTER_COUNT)
	for index in 1 ..< len(mappings) {
		testing.expect(t, mappings[index - 1].character < mappings[index].character)
	}
}

// The text "modus" in the font has the proportions of name_draw: each
// letter advances by its five columns and the gap, so the five letters less
// the gap after the last one are the columns of the name, and the rows of
// the name are the ascent. A font size of one em of cells in pixels gives
// cells of one pixel.
@(test)
mark_font_measures_are_those_of_the_name :: proc(t: ^testing.T) {
	file, built := mark_font_build(MARK_FONT_TEST_LICENSE)
	font, problem := vector_font.font_open(file)
	testing.expect(t, built && problem == .None)
	if !built || problem != .None {
		return
	}
	for glyph in 0 ..< MARK_FONT_GLYPH_COUNT {
		testing.expect_value(t, vector_font.glyph_advance(&font, glyph), MARK_FONT_ADVANCE)
	}
	cell :: MARK_FONT_UNITS_OF_A_CELL
	testing.expect_value(t, MARK_FONT_ADVANCE, (mark.NAME_LETTER_COLUMNS + mark.NAME_GAP_COLUMNS) * cell)
	testing.expect_value(t, mark.NAME_LETTER_COUNT * MARK_FONT_ADVANCE - mark.NAME_GAP_COLUMNS * cell, mark.NAME_COLUMNS * cell)
	testing.expect_value(t, MARK_FONT_ASCENT, mark.NAME_ROWS * cell)
	testing.expect_value(t, MARK_FONT_UNITS_OF_THE_EM, MARK_FONT_CELLS_OF_THE_EM * cell)
	// The sizes of the site: a whole count of pixels for a cell, and the
	// box of the name that name_size gives at that cell size.
	for cell_size in ([]int{SITE_MARK_NAME_CELL_SIZE, SITE_MARK_NAME_HOME_CELL_SIZE}) {
		width, height := mark.name_size(cell_size)
		testing.expect_value(t, site_mark_name_font_size(cell_size) * MARK_FONT_UNITS_OF_A_CELL, cell_size * MARK_FONT_UNITS_OF_THE_EM)
		testing.expect_value(t, site_mark_name_font_size(cell_size) % MARK_FONT_CELLS_OF_THE_EM, 0)
		testing.expect_value(t, width, mark.NAME_COLUMNS * cell_size)
		testing.expect_value(t, height, mark.NAME_ROWS * cell_size)
	}
}

// The file: the tables that a browser needs, by their tags, each at a
// multiple of 4 bytes with its checksum, zeros between two tables, and the
// checksum of the whole file. Two builds give the same bytes.
@(test)
mark_font_file_is_well_formed :: proc(t: ^testing.T) {
	file, built := mark_font_build(MARK_FONT_TEST_LICENSE)
	testing.expect(t, built)
	if !built {
		return
	}
	again, _ := mark_font_build(MARK_FONT_TEST_LICENSE)
	testing.expect(t, string(file) == string(again), "two builds of the font differ")
	testing.expect_value(t, len(file) % 4, 0)
	testing.expect_value(t, get_u32(file, 0), u32(0x00010000))
	testing.expect_value(t, table_checksum(file), u32(0xB1B0AFBA))
	expected_tags := [?]string{"OS/2", "cmap", "glyf", "head", "hhea", "hmtx", "loca", "maxp", "name", "post"}
	count := int(get_u16(file, 4))
	testing.expect_value(t, count, len(expected_tags))
	if count != len(expected_tags) {
		return
	}
	next_offset := 12 + 16 * count
	for expected_tag, index in expected_tags {
		record := 12 + 16 * index
		tag := string(file[record:][:4])
		checksum := get_u32(file, record + 4)
		offset := int(get_u32(file, record + 8))
		length := int(get_u32(file, record + 12))
		testing.expect_value(t, tag, expected_tag)
		testing.expectf(t, offset == next_offset && offset % 4 == 0 && offset + length <= len(file), "%s is at %d with %d bytes; the table before it ends at %d", tag, offset, length, next_offset)
		if offset != next_offset || offset + length > len(file) {
			return
		}
		table := make([]u8, length, context.temp_allocator)
		copy(table, file[offset:][:length])
		if tag == "head" {
			// The checksum of head counts its adjustment as 0.
			testing.expect_value(t, length, 54)
			testing.expect_value(t, get_u32(table, 12), u32(0x5F0F3CF5))
			for index_in_field in 8 ..< 12 {
				table[index_in_field] = 0
			}
			// No date: the same bytes at each build.
			for index_in_dates in 20 ..< 36 {
				testing.expect_value(t, table[index_in_dates], u8(0))
			}
		}
		testing.expectf(t, table_checksum(table) == checksum, "the checksum of %s is not the one of the directory", tag)
		next_offset = (offset + length + 3) / 4 * 4
		for padding in offset + length ..< next_offset {
			testing.expect_value(t, file[padding], u8(0))
		}
	}
	testing.expect_value(t, next_offset, len(file))
	// The names, in 16 bits for each character: the family, and the line of
	// the copyright and the text of the license.
	for text in ([]string{MARK_FONT_FAMILY, MARK_FONT_POSTSCRIPT_NAME, "Copyright (c) 2026 The holder", "The text of the license."}) {
		wide := make([dynamic]u8, context.temp_allocator)
		for character in transmute([]u8)text {
			append(&wide, 0, character)
		}
		testing.expectf(t, strings.contains(string(file), string(wide[:])), "the font does not carry \"%s\"", text)
	}
	testing.expect_value(t, mark_font_copyright(MARK_FONT_TEST_LICENSE), "Copyright (c) 2026 The holder")
	// Another license is another file: the text is in the font.
	other, _ := mark_font_build("Copyright (c) 2026 Another holder\n")
	testing.expect(t, string(file) != string(other))
}
