// The font of the name of the mark (docs/DESIGN.md, "The font of the name"):
// a TrueType file whose glyphs are the cells of the letters of
// src/library/support/mark. A page that writes the name of the system as text in this
// font shows the letters of the files of the mark, and the text stays text.
//
// The file is written here, table by table, with no other program: the
// letters are a few rectangles, so the font needs no curve and no
// instruction. Each glyph is the union of its cells: the outline goes around
// the whole letter, so that no line shows between two cells when a browser
// smooths the edges.
//
// The units: a cell is MARK_FONT_UNITS_OF_A_CELL units and the em is
// MARK_FONT_CELLS_OF_THE_EM cells: the seven rows of the name above the
// baseline and one empty row under it. At a font size of 8 pixels a cell is
// one pixel, so each font size that is a multiple of 8 pixels draws whole
// cells.
package kerneltool

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "support:mark"

// The file in the repository, beside the pictures of the mark.
MARK_FONT_FILE_NAME :: "modus_mark.ttf"
MARK_FONT_FILE :: LOGO_FOLDER + "/" + MARK_FONT_FILE_NAME
// The text of the license of the repository: the font carries it.
MARK_FONT_LICENSE_FILE :: SITE_LICENSE_FILE

// The names that the font carries. It is not a font for a text: it has the
// letters of the name only.
MARK_FONT_FAMILY :: "modus mark"
MARK_FONT_STYLE :: "Regular"
MARK_FONT_POSTSCRIPT_NAME :: "modusmark-Regular"
MARK_FONT_VERSION :: "Version 1.000"

// The letters of the name, in the order of mark.name_letters.
MARK_FONT_LETTERS :: "modus"
#assert(len(MARK_FONT_LETTERS) == mark.NAME_LETTER_COUNT)

MARK_FONT_UNITS_OF_A_CELL :: 128
MARK_FONT_CELLS_OF_THE_EM :: mark.NAME_ROWS + 1
MARK_FONT_UNITS_OF_THE_EM :: MARK_FONT_CELLS_OF_THE_EM * MARK_FONT_UNITS_OF_A_CELL
// The rows of the name are above the baseline: the letters stand on it.
MARK_FONT_ASCENT :: mark.NAME_ROWS * MARK_FONT_UNITS_OF_A_CELL
MARK_FONT_DESCENT :: MARK_FONT_UNITS_OF_THE_EM - MARK_FONT_ASCENT
// The letters with no stem start on the third row: five rows high.
MARK_FONT_LETTER_HEIGHT :: (mark.NAME_ROWS - 2) * MARK_FONT_UNITS_OF_A_CELL
// A letter and the gap after it, as name_draw places them. Each glyph has
// this advance, the space too.
MARK_FONT_ADVANCE :: (mark.NAME_LETTER_COLUMNS + mark.NAME_GAP_COLUMNS) * MARK_FONT_UNITS_OF_A_CELL

// The glyphs: the glyph of a character that the font does not have (no
// contour: a browser takes such a character from the next font), the space,
// then the letters.
MARK_FONT_GLYPH_MISSING :: 0
MARK_FONT_GLYPH_SPACE :: 1
MARK_FONT_GLYPH_FIRST_LETTER :: 2
MARK_FONT_GLYPH_COUNT :: MARK_FONT_GLYPH_FIRST_LETTER + mark.NAME_LETTER_COUNT

// A corner of an outline, in cells: x from the left of the letter, y up from
// the baseline.
Mark_Font_Point :: struct {
	x, y: int,
}

// One side of a filled cell that has an empty cell at its other side. The
// filled cell is at the right of the direction from `from` to `to`.
Mark_Font_Edge :: struct {
	from, to: Mark_Font_Point,
	used:     bool, // A contour holds it.
}

// The box of a glyph, in units.
Mark_Font_Box :: struct {
	x_least, y_least, x_most, y_most: int,
}

// One character of the font and its glyph.
Mark_Font_Mapping :: struct {
	character: int,
	glyph:     int,
}

// append_units writes a number of 16 bits, big endian. A number under 0 is
// written in two's complement: its low 16 bits.
@(private = "file")
append_units :: proc(bytes: ^[dynamic]u8, value: int) {
	append_u16(bytes, u16(value & 0xFFFF))
}

// mark_font_letter_cell_is_filled tells whether a cell of a letter is
// filled. A cell outside the letter is empty.
mark_font_letter_cell_is_filled :: proc(letter, column, row: int) -> bool {
	if letter < 0 || letter >= mark.NAME_LETTER_COUNT || column < 0 || row < 0 || column >= mark.NAME_LETTER_COLUMNS || row >= mark.NAME_ROWS {
		return false
	}
	return mark.name_letters[letter][row][column] == '1'
}

// mark_font_letter_contours gives the outline of a letter: the limit of the
// union of its filled cells, as closed contours of corners. The filled part
// is at the right of each contour, with y up: an outer contour turns
// clockwise and a hole turns the other way, as a TrueType outline does.
//
// Each side between a filled cell and an empty one is an edge with the
// filled cell at its right. The edges are then joined end to start. Where
// two filled cells touch by a corner only, two edges leave the corner: the
// contour takes the one most to the right, and stays around its own cell.
mark_font_letter_contours :: proc(letter: int) -> (contours: [][]Mark_Font_Point, ok: bool) {
	edges := make([dynamic]Mark_Font_Edge, context.temp_allocator)
	for row in 0 ..< mark.NAME_ROWS {
		for column in 0 ..< mark.NAME_LETTER_COLUMNS {
			if !mark_font_letter_cell_is_filled(letter, column, row) {
				continue
			}
			left := column
			right := column + 1
			top := mark.NAME_ROWS - row
			bottom := top - 1
			if !mark_font_letter_cell_is_filled(letter, column - 1, row) {
				append(&edges, Mark_Font_Edge{from = {left, bottom}, to = {left, top}})
			}
			if !mark_font_letter_cell_is_filled(letter, column, row - 1) {
				append(&edges, Mark_Font_Edge{from = {left, top}, to = {right, top}})
			}
			if !mark_font_letter_cell_is_filled(letter, column + 1, row) {
				append(&edges, Mark_Font_Edge{from = {right, top}, to = {right, bottom}})
			}
			if !mark_font_letter_cell_is_filled(letter, column, row + 1) {
				append(&edges, Mark_Font_Edge{from = {right, bottom}, to = {left, bottom}})
			}
		}
	}
	found := make([dynamic][]Mark_Font_Point, context.temp_allocator)
	for first in 0 ..< len(edges) {
		if edges[first].used {
			continue
		}
		points := make([dynamic]Mark_Font_Point, context.temp_allocator)
		current := first
		for {
			edges[current].used = true
			append(&points, edges[current].from)
			if edges[current].to == edges[first].from {
				break
			}
			next := mark_font_next_edge(edges[:], current)
			if next < 0 {
				return nil, false // An edge with no edge after it: not a closed limit.
			}
			current = next
		}
		append(&found, mark_font_corners(points[:]))
	}
	return found[:], true
}

// mark_font_next_edge gives the edge that follows an edge in its contour:
// an edge that no contour holds yet and that starts where the edge ends.
// Of two, the one that turns most to the right; -1 when there is none.
@(private = "file")
mark_font_next_edge :: proc(edges: []Mark_Font_Edge, arrival: int) -> int {
	arrival_x := edges[arrival].to.x - edges[arrival].from.x
	arrival_y := edges[arrival].to.y - edges[arrival].from.y
	best := -1
	best_turn := 0
	for edge, index in edges {
		if edge.used || edge.from != edges[arrival].to {
			continue
		}
		// Under 0: a turn to the right; 0: straight on; over 0: to the left.
		turn := arrival_x * (edge.to.y - edge.from.y) - arrival_y * (edge.to.x - edge.from.x)
		if best < 0 || turn < best_turn {
			best = index
			best_turn = turn
		}
	}
	return best
}

// mark_font_corners keeps the points of a closed contour where its
// direction changes: a point on a straight line between its two neighbours
// is not a corner.
@(private = "file")
mark_font_corners :: proc(points: []Mark_Font_Point) -> []Mark_Font_Point {
	corners := make([dynamic]Mark_Font_Point, context.temp_allocator)
	count := len(points)
	for point, index in points {
		before := points[(index + count - 1) % count]
		after := points[(index + 1) % count]
		if (point.x - before.x) * (after.y - point.y) - (point.y - before.y) * (after.x - point.x) != 0 {
			append(&corners, point)
		}
	}
	return corners[:]
}

// mark_font_glyph_contours gives the outline of a glyph of the font. The
// glyph of a missing character and the space have no contour.
mark_font_glyph_contours :: proc(glyph: int) -> (contours: [][]Mark_Font_Point, ok: bool) {
	if glyph < MARK_FONT_GLYPH_FIRST_LETTER || glyph >= MARK_FONT_GLYPH_COUNT {
		return nil, glyph >= 0 && glyph < MARK_FONT_GLYPH_FIRST_LETTER
	}
	return mark_font_letter_contours(glyph - MARK_FONT_GLYPH_FIRST_LETTER)
}

// mark_font_mappings gives each character of the font with its glyph, by
// character: the space, each letter of the name, and the capital of each
// letter with the glyph of the small letter. The name of the mark has small
// letters only, so a text "Modus" in this font still shows the mark.
mark_font_mappings :: proc() -> []Mark_Font_Mapping {
	mappings := make([dynamic]Mark_Font_Mapping, context.temp_allocator)
	append(&mappings, Mark_Font_Mapping{character = ' ', glyph = MARK_FONT_GLYPH_SPACE})
	letters := MARK_FONT_LETTERS
	for index in 0 ..< len(letters) {
		small := int(letters[index])
		append(&mappings, Mark_Font_Mapping{character = small, glyph = MARK_FONT_GLYPH_FIRST_LETTER + index})
		append(&mappings, Mark_Font_Mapping{character = small - 'a' + 'A', glyph = MARK_FONT_GLYPH_FIRST_LETTER + index})
	}
	slice.sort_by(mappings[:], proc(first, second: Mark_Font_Mapping) -> bool {
		return first.character < second.character
	})
	return mappings[:]
}

// mark_font_glyph_data gives the record of one glyph in the table `glyf`,
// with its box and the count of its points. A glyph with no contour has no
// record: its length in the table `loca` is 0.
//
// The record: the count of contours, the box, the index of the last point of
// each contour, a length of 0 for the instructions (the font has none), one
// flag for each point, then the x and the y of each point as its distance
// from the point before, in 16 bits. The flag 1 says "on the curve": each
// point is a corner. The short forms of a coordinate are not used: a glyph
// has few points, and one form is one path to test.
@(private = "file")
mark_font_glyph_data :: proc(contours: [][]Mark_Font_Point) -> (data: []u8, box: Mark_Font_Box, point_count: int) {
	if len(contours) == 0 {
		return nil, {}, 0
	}
	first_point := true
	for contour in contours {
		for point in contour {
			x := point.x * MARK_FONT_UNITS_OF_A_CELL
			y := point.y * MARK_FONT_UNITS_OF_A_CELL
			if first_point {
				box = {x, y, x, y}
				first_point = false
			}
			box.x_least = min(box.x_least, x)
			box.y_least = min(box.y_least, y)
			box.x_most = max(box.x_most, x)
			box.y_most = max(box.y_most, y)
			point_count += 1
		}
	}
	bytes := make([dynamic]u8, context.temp_allocator)
	append_units(&bytes, len(contours))
	append_units(&bytes, box.x_least)
	append_units(&bytes, box.y_least)
	append_units(&bytes, box.x_most)
	append_units(&bytes, box.y_most)
	last_point := -1
	for contour in contours {
		last_point += len(contour)
		append_units(&bytes, last_point)
	}
	append_units(&bytes, 0)
	for _ in 0 ..< point_count {
		append(&bytes, u8(MARK_FONT_FLAG_ON_CURVE))
	}
	before := 0
	for contour in contours {
		for point in contour {
			x := point.x * MARK_FONT_UNITS_OF_A_CELL
			append_units(&bytes, x - before)
			before = x
		}
	}
	before = 0
	for contour in contours {
		for point in contour {
			y := point.y * MARK_FONT_UNITS_OF_A_CELL
			append_units(&bytes, y - before)
			before = y
		}
	}
	return bytes[:], box, point_count
}

MARK_FONT_FLAG_ON_CURVE :: 1

// mark_font_name_text gives a text of the table `name` in the form of the
// Windows platform: 16 bits for each character, big endian. A character
// past 16 bits is written as "?": the names and the license have none.
@(private = "file")
mark_font_name_text :: proc(text: string) -> []u8 {
	bytes := make([dynamic]u8, context.temp_allocator)
	for character in text {
		append_units(&bytes, int(character) if character < 0x10000 else '?')
	}
	return bytes[:]
}

// mark_font_copyright gives the line of the license that names who holds
// the copyright: its first line that starts with "Copyright".
mark_font_copyright :: proc(license_text: string) -> string {
	rest := license_text
	for line in strings.split_lines_iterator(&rest) {
		trimmed := strings.trim_space(line)
		if strings.has_prefix(trimmed, "Copyright") {
			return trimmed
		}
	}
	return ""
}

// mark_font_build gives the bytes of the font file, from the cells of
// src/library/support/mark and the text of the license of the repository. The same
// inputs give the same bytes: the file holds no date and no random value.
mark_font_build :: proc(license_text: string) -> (file: []u8, ok: bool) {
	// The outlines, and what the tables say about all of them.
	glyph_data: [MARK_FONT_GLYPH_COUNT][]u8
	glyph_boxes: [MARK_FONT_GLYPH_COUNT]Mark_Font_Box
	font_box: Mark_Font_Box
	most_points, most_contours := 0, 0
	least_left, least_right, most_extent := 0, 0, 0
	first_outline := true
	for glyph in 0 ..< MARK_FONT_GLYPH_COUNT {
		contours := mark_font_glyph_contours(glyph) or_return
		point_count: int
		glyph_data[glyph], glyph_boxes[glyph], point_count = mark_font_glyph_data(contours)
		if len(contours) == 0 {
			continue
		}
		box := glyph_boxes[glyph]
		if first_outline {
			font_box = box
			least_left = box.x_least
			least_right = MARK_FONT_ADVANCE - box.x_most
			most_extent = box.x_most
			first_outline = false
		}
		font_box.x_least = min(font_box.x_least, box.x_least)
		font_box.y_least = min(font_box.y_least, box.y_least)
		font_box.x_most = max(font_box.x_most, box.x_most)
		font_box.y_most = max(font_box.y_most, box.y_most)
		least_left = min(least_left, box.x_least)
		least_right = min(least_right, MARK_FONT_ADVANCE - box.x_most)
		most_extent = max(most_extent, box.x_most)
		most_points = max(most_points, point_count)
		most_contours = max(most_contours, len(contours))
	}
	if first_outline {
		return nil, false // No letter has a filled cell.
	}
	mappings := mark_font_mappings()

	// `glyf`: the records of the glyphs, each padded to 4 bytes. `loca`: the
	// offset of each record in `glyf`, and the end of the last one, each as
	// half its value in 16 bits (the short form). A glyph with no record has
	// the offset of the next one.
	glyphs := make([dynamic]u8, context.temp_allocator)
	locations := make([dynamic]u8, context.temp_allocator)
	for glyph in 0 ..< MARK_FONT_GLYPH_COUNT {
		append_units(&locations, len(glyphs) / 2)
		append(&glyphs, ..glyph_data[glyph])
		for len(glyphs) % 4 != 0 {
			append(&glyphs, 0)
		}
	}
	append_units(&locations, len(glyphs) / 2)

	// `head`: the font as a whole. The version 1.0, the revision 1.0, the
	// place of the adjustment of the checksum (written at the end), the magic
	// number. The flags: the baseline is at y = 0, the left side of a glyph
	// is at x = 0, and a size is a whole count of pixels. Then the units of
	// the em, no date (the history of the repository has the date, and a
	// date here changes the bytes at each build), the box of all the glyphs,
	// no style, the smallest size that reads (a cell of one pixel), the
	// direction left to right, the short form of `loca`, the one format of
	// `glyf`.
	head := make([dynamic]u8, context.temp_allocator)
	append_units(&head, 1)
	append_units(&head, 0)
	append_u32(&head, 0x00010000)
	append_u32(&head, 0)
	append_u32(&head, 0x5F0F3CF5)
	append_units(&head, 0x000B)
	append_units(&head, MARK_FONT_UNITS_OF_THE_EM)
	for _ in 0 ..< 4 {
		append_u32(&head, 0) // Created and modified: 64 bits each.
	}
	append_units(&head, font_box.x_least)
	append_units(&head, font_box.y_least)
	append_units(&head, font_box.x_most)
	append_units(&head, font_box.y_most)
	append_units(&head, 0)
	append_units(&head, MARK_FONT_CELLS_OF_THE_EM)
	append_units(&head, 2)
	append_units(&head, 0)
	append_units(&head, 0)

	// `hhea`: the measures of a line. The version 1.0, the ascent, the
	// descent (under 0), no gap between two lines, the widest advance, the
	// least space at the left and at the right of a glyph, the farthest
	// right edge, an upright caret (rise 1, run 0, no offset), four reserved
	// words, the one format of `hmtx`, and the count of its full rows: each
	// glyph has one.
	horizontal_header := make([dynamic]u8, context.temp_allocator)
	append_units(&horizontal_header, 1)
	append_units(&horizontal_header, 0)
	append_units(&horizontal_header, MARK_FONT_ASCENT)
	append_units(&horizontal_header, -MARK_FONT_DESCENT)
	append_units(&horizontal_header, 0)
	append_units(&horizontal_header, MARK_FONT_ADVANCE)
	append_units(&horizontal_header, least_left)
	append_units(&horizontal_header, least_right)
	append_units(&horizontal_header, most_extent)
	append_units(&horizontal_header, 1)
	append_units(&horizontal_header, 0)
	append_units(&horizontal_header, 0)
	for _ in 0 ..< 4 {
		append_units(&horizontal_header, 0)
	}
	append_units(&horizontal_header, 0)
	append_units(&horizontal_header, MARK_FONT_GLYPH_COUNT)

	// `hmtx`: for each glyph, its advance and the space at its left.
	horizontal_metrics := make([dynamic]u8, context.temp_allocator)
	for glyph in 0 ..< MARK_FONT_GLYPH_COUNT {
		append_units(&horizontal_metrics, MARK_FONT_ADVANCE)
		append_units(&horizontal_metrics, glyph_boxes[glyph].x_least)
	}

	// `maxp`: the most that a reader must hold. The version 1.0, the count
	// of glyphs, the most points and the most contours of a glyph, none for
	// a glyph made of other glyphs (two words), two zones (the value that a
	// font with no instruction can state), then nothing for the
	// instructions (six words) and for the glyphs made of other glyphs (two
	// words).
	maximum_profile := make([dynamic]u8, context.temp_allocator)
	append_u32(&maximum_profile, 0x00010000)
	append_units(&maximum_profile, MARK_FONT_GLYPH_COUNT)
	append_units(&maximum_profile, most_points)
	append_units(&maximum_profile, most_contours)
	append_units(&maximum_profile, 0)
	append_units(&maximum_profile, 0)
	append_units(&maximum_profile, 2)
	for _ in 0 ..< 8 {
		append_units(&maximum_profile, 0)
	}

	// `OS/2`: the measures that Windows and a browser read. The version 4;
	// the mean advance; the weight 400 and the width 5 (normal: the font
	// has one face, and a page must not make it bold); no limit on its use
	// in a document. The sizes and the places of a subscript, of a
	// superscript and of a line through the text, in cells: the font is not
	// for such a text, the values only keep a reader of the file content.
	// No family class and no shape numbers. The characters are in the first
	// range of Unicode (Basic Latin) and the first code page (Latin 1). The
	// maker has no registered tag: four spaces. The selection: a regular
	// face, whose line measures are the three "typo" values. The first and
	// the last character. The ascent and the descent again, in the two forms
	// that the readers use. The height of a small letter and of a capital
	// (the capitals have the glyphs of the small letters), no glyph of its
	// own for a missing character, the space as the character that breaks a
	// line, and no context between glyphs.
	system_metrics := make([dynamic]u8, context.temp_allocator)
	append_units(&system_metrics, 4)
	append_units(&system_metrics, MARK_FONT_ADVANCE)
	append_units(&system_metrics, 400)
	append_units(&system_metrics, 5)
	append_units(&system_metrics, 0)
	// A subscript, then a superscript: the width, the height, the offset to
	// the right, the offset down or up.
	append_units(&system_metrics, MARK_FONT_UNITS_OF_THE_EM / 2)
	append_units(&system_metrics, MARK_FONT_UNITS_OF_THE_EM / 2)
	append_units(&system_metrics, 0)
	append_units(&system_metrics, MARK_FONT_UNITS_OF_A_CELL)
	append_units(&system_metrics, MARK_FONT_UNITS_OF_THE_EM / 2)
	append_units(&system_metrics, MARK_FONT_UNITS_OF_THE_EM / 2)
	append_units(&system_metrics, 0)
	append_units(&system_metrics, MARK_FONT_ASCENT / 2)
	// The line through the text: one cell thick, in the middle of a small
	// letter.
	append_units(&system_metrics, MARK_FONT_UNITS_OF_A_CELL)
	append_units(&system_metrics, 3 * MARK_FONT_UNITS_OF_A_CELL)
	append_units(&system_metrics, 0)
	for _ in 0 ..< 10 {
		append(&system_metrics, 0)
	}
	append_u32(&system_metrics, 1)
	append_u32(&system_metrics, 0)
	append_u32(&system_metrics, 0)
	append_u32(&system_metrics, 0)
	append(&system_metrics, ' ', ' ', ' ', ' ')
	append_units(&system_metrics, 0x00C0)
	append_units(&system_metrics, mappings[0].character)
	append_units(&system_metrics, mappings[len(mappings) - 1].character)
	append_units(&system_metrics, MARK_FONT_ASCENT)
	append_units(&system_metrics, -MARK_FONT_DESCENT)
	append_units(&system_metrics, 0)
	append_units(&system_metrics, MARK_FONT_ASCENT)
	append_units(&system_metrics, MARK_FONT_DESCENT)
	append_u32(&system_metrics, 1)
	append_u32(&system_metrics, 0)
	append_units(&system_metrics, MARK_FONT_LETTER_HEIGHT)
	append_units(&system_metrics, MARK_FONT_LETTER_HEIGHT)
	append_units(&system_metrics, 0)
	append_units(&system_metrics, ' ')
	append_units(&system_metrics, 0)

	// `cmap`: from a character to its glyph. The version 0 and one
	// subtable, for the Windows platform with Unicode in 16 bits (platform
	// 3, encoding 1), which every browser reads, at the offset 12. The
	// subtable has the format 4: segments of characters that follow one
	// another. Each character of the font is a segment of its own: its last
	// character, its first character, the number to add to a character to
	// get its glyph (in 16 bits, which wrap), and 0 for "no table of
	// glyphs". The last segment is the character 0xFFFF alone, which the
	// format requires: it gives the glyph of a missing character. Before
	// the segments: the format, the length of the subtable, no language,
	// twice the count of segments, and three values for a search by halves:
	// twice the largest power of two that is at most the count, its
	// exponent, and the rest.
	segment_count := len(mappings) + 1
	largest_power, exponent := 1, 0
	for largest_power * 2 <= segment_count {
		largest_power *= 2
		exponent += 1
	}
	character_map := make([dynamic]u8, context.temp_allocator)
	append_units(&character_map, 0)
	append_units(&character_map, 1)
	append_units(&character_map, 3)
	append_units(&character_map, 1)
	append_u32(&character_map, 12)
	append_units(&character_map, 4)
	append_units(&character_map, 16 + 8 * segment_count)
	append_units(&character_map, 0)
	append_units(&character_map, 2 * segment_count)
	append_units(&character_map, 2 * largest_power)
	append_units(&character_map, exponent)
	append_units(&character_map, 2 * segment_count - 2 * largest_power)
	for mapping in mappings {
		append_units(&character_map, mapping.character)
	}
	append_units(&character_map, 0xFFFF)
	append_units(&character_map, 0) // A reserved word between the two lists.
	for mapping in mappings {
		append_units(&character_map, mapping.character)
	}
	append_units(&character_map, 0xFFFF)
	for mapping in mappings {
		append_units(&character_map, mapping.glyph - mapping.character)
	}
	append_units(&character_map, 1)
	for _ in 0 ..< segment_count {
		append_units(&character_map, 0)
	}

	// `name`: the texts of the font, for the Windows platform, in English
	// of the United States (platform 3, encoding 1, language 0x0409), by
	// their number: 0 the copyright, 1 the family, 2 the style, 3 a name
	// that no other font has, 4 the family and the style, 5 the version,
	// 6 the name with no space, 13 the text of the license. The format 0:
	// the count of the records, the offset of the texts, a record for each
	// text (with its length and its offset among the texts), then the
	// texts.
	names := [?]struct {
		number: int,
		text:   string,
	} {
		{0, mark_font_copyright(license_text)},
		{1, MARK_FONT_FAMILY},
		{2, MARK_FONT_STYLE},
		{3, MARK_FONT_FAMILY + " " + MARK_FONT_STYLE + " " + MARK_FONT_VERSION},
		{4, MARK_FONT_FAMILY},
		{5, MARK_FONT_VERSION},
		{6, MARK_FONT_POSTSCRIPT_NAME},
		{13, strings.trim_space(license_text)},
	}
	name_table := make([dynamic]u8, context.temp_allocator)
	name_texts := make([dynamic]u8, context.temp_allocator)
	append_units(&name_table, 0)
	append_units(&name_table, len(names))
	append_units(&name_table, 6 + 12 * len(names))
	for name in names {
		text := mark_font_name_text(name.text)
		append_units(&name_table, 3)
		append_units(&name_table, 1)
		append_units(&name_table, 0x0409)
		append_units(&name_table, name.number)
		append_units(&name_table, len(text))
		append_units(&name_table, len(name_texts))
		append(&name_texts, ..text)
	}
	if len(name_texts) > 0xFFFF {
		return nil, false // The license is longer than the table can say.
	}
	append(&name_table, ..name_texts[:])

	// `post`: what a printer reads. The format 3: no name for each glyph.
	// An upright face, the place and the thickness of a line under the text
	// (in the row under the baseline, one cell thick), "each glyph has the
	// same advance", and no statement about memory (four words).
	printer_table := make([dynamic]u8, context.temp_allocator)
	append_u32(&printer_table, 0x00030000)
	append_u32(&printer_table, 0)
	append_units(&printer_table, -MARK_FONT_DESCENT / 2)
	append_units(&printer_table, MARK_FONT_UNITS_OF_A_CELL)
	append_u32(&printer_table, 1)
	for _ in 0 ..< 4 {
		append_u32(&printer_table, 0)
	}

	// The file: the tables by their tags. sfnt_write (vector_fonts.odin)
	// writes the header, the directory with the checksum of each table, the
	// tables padded to 4 bytes, and the adjustment of the checksum in `head`.
	tables := [?]Subset_Table {
		{"OS/2", system_metrics[:]},
		{"cmap", character_map[:]},
		{"glyf", glyphs[:]},
		{"head", head[:]},
		{"hhea", horizontal_header[:]},
		{"hmtx", horizontal_metrics[:]},
		{"loca", locations[:]},
		{"maxp", maximum_profile[:]},
		{"name", name_table[:]},
		{"post", printer_table[:]},
	}
	return sfnt_write(tables[:]), true
}

// mark_font_of_the_repository gives the font built from the license of the
// repository: the bytes that MARK_FONT_FILE must have, and that the site
// serves.
mark_font_of_the_repository :: proc() -> (file: []u8, ok: bool) {
	license_text := read_file(MARK_FONT_LICENSE_FILE) or_return
	file, ok = mark_font_build(string(license_text))
	if !ok {
		fmt.eprintln("kerneltool: cannot build the font of the name of the mark from the letters of " + MARK_SOURCE_FOLDER)
	}
	return
}

// mark_font_write writes the font beside the pictures of the mark.
mark_font_write :: proc() -> bool {
	file := mark_font_of_the_repository() or_return
	if err := os.write_entire_file(MARK_FONT_FILE, file); err != nil {
		fmt.eprintfln("kerneltool: cannot write %s: %v", MARK_FONT_FILE, err)
		return false
	}
	fmt.printfln("kerneltool: wrote %s (the font of the name of the mark: %d glyphs, %d units in the em, %d units in a cell, %d bytes)", MARK_FONT_FILE, MARK_FONT_GLYPH_COUNT, MARK_FONT_UNITS_OF_THE_EM, MARK_FONT_UNITS_OF_A_CELL, len(file))
	return true
}

// mark_font_check verifies that the font of the repository has the bytes
// that the letters of src/library/support/mark and the license give now. The writer is
// this file, so the bytes are compared, not the outlines.
mark_font_check :: proc() -> bool {
	expected := mark_font_of_the_repository() or_return
	data, read_error := os.read_entire_file(MARK_FONT_FILE, context.temp_allocator)
	if read_error != nil {
		fmt.eprintfln("kerneltool: test failed: cannot read %s (%v): run kerneltool logo", MARK_FONT_FILE, read_error)
		return false
	}
	if string(data) != string(expected) {
		fmt.eprintfln("kerneltool: test failed: %s is not the font of the letters of " + MARK_SOURCE_FOLDER + " and of %s: run kerneltool logo", MARK_FONT_FILE, MARK_FONT_LICENSE_FILE)
		return false
	}
	test_passed_print("%s is the font of the letters of " + MARK_SOURCE_FOLDER, MARK_FONT_FILE)
	return true
}
