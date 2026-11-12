#+build !freestanding
package terminal_records

import "core:math"
import "core:testing"
import "support:graphics"

// The least contrast of a color of code on the surfaces where the terminal
// draws code: the text and the edit line on the background, a row of the
// completion list on the card.
CODE_CONTRAST_LEAST :: 4.5

// The chosen row of the list is on the blue of the title bar, as each
// chosen line of the desktop: white has 4.29 to 1 there, and no color of a
// kind has more than white. The row draws each kind in white; this is the
// contrast that it keeps.
CHOSEN_ROW_CONTRAST_LEAST :: 4.25

// contrast_ratio gives the contrast ratio of two colors (WCAG 2), as the
// tests of the site compute it.
contrast_ratio :: proc(first, second: graphics.Color) -> f64 {
	luminance :: proc(color: graphics.Color) -> f64 {
		channel :: proc(value: u32) -> f64 {
			part := f64(value) / 255
			return part <= 0.03928 ? part / 12.92 : math.pow((part + 0.055) / 1.055, 2.4)
		}
		value := u32(color)
		return 0.2126 * channel((value >> 16) & 0xFF) + 0.7152 * channel((value >> 8) & 0xFF) + 0.0722 * channel(value & 0xFF)
	}
	lighter, darker := luminance(first), luminance(second)
	if lighter < darker {
		lighter, darker = darker, lighter
	}
	return (lighter + 0.05) / (darker + 0.05)
}

// Each kind with a color keeps its contrast on the background and on the
// card; the plain parts have the text color; the chosen row is white.
@(test)
code_colors_keep_their_contrast :: proc(t: ^testing.T) {
	surfaces := [?]graphics.Color{graphics.COLOR_BACKGROUND, graphics.COLOR_CARD_TOP, graphics.COLOR_CARD_BOTTOM}
	for kind in Code_Kind {
		color := code_kind_color(kind, graphics.COLOR_TEXT)
		for surface in surfaces {
			ratio := contrast_ratio(color, surface)
			testing.expectf(t, ratio >= CODE_CONTRAST_LEAST, "the kind %v (%06x) on %06x: a contrast of %.2f; at least %.1f", kind, u32(color), u32(surface), ratio, CODE_CONTRAST_LEAST)
		}
	}
	white := contrast_ratio(graphics.COLOR_WHITE, graphics.COLOR_TITLE)
	testing.expectf(t, white >= CHOSEN_ROW_CONTRAST_LEAST, "white on the chosen row: %.2f", white)
	for kind in Code_Kind {
		testing.expectf(t, contrast_ratio(code_kind_color(kind, graphics.COLOR_TEXT), graphics.COLOR_TITLE) <= white, "the kind %v has more contrast than white on the chosen row", kind)
	}
	// The site and the terminal read one table: the colors of a type and
	// of a literal on a dark surface.
	testing.expect_value(t, code_kind_color(.Type, 0), graphics.code_class_color(.Type, false))
	testing.expect_value(t, code_kind_color(.Number, 0), graphics.code_class_color(.Literal, false))
	// A text still typed has the color of a text: no change at each key.
	testing.expect_value(t, code_kind_color(.Text_Unfinished, 0), code_kind_color(.Text, 0))
	// A kind past the known ones is plain.
	testing.expect_value(t, code_kind_of(200), Code_Kind.None)
	testing.expect_value(t, code_kind_of(u8(Code_Kind.Arrow)), Code_Kind.Arrow)
}

// The runs of a row: inside it, in order, with no overlap, at least one
// byte, a kind that exists. One run that is not: no runs, and the text
// stays as it is.
@(test)
code_runs_checked_against_their_row :: proc(t: ^testing.T) {
	Case :: struct {
		runs:   [3]Code_Run,
		count:  int,
		length: int,
		kept:   bool,
	}
	bad_kind := transmute(Code_Kind)u8(99)
	cases := [?]Case {
		{{{0, 3, .Function, 0}, {3, 1, .Operator, 0}, {5, 2, .Number, 0}}, 3, 8, true},
		{{{0, 3, .Function, 0}, {3, 1, .Operator, 0}, {5, 4, .Number, 0}}, 3, 8, false}, // Past the row.
		{{{0, 3, .Function, 0}, {2, 1, .Operator, 0}}, 2, 8, false}, // Overlap.
		{{{4, 1, .Operator, 0}, {0, 3, .Function, 0}}, 2, 8, false}, // Not in order.
		{{{0, 0, .Function, 0}}, 1, 8, false}, // No byte.
		{{{0, 1, bad_kind, 0}}, 1, 8, false}, // A kind that does not exist.
		{{{0, 1, .None, 0}}, 1, 8, false},
		{{{255, 1, .Words, 0}}, 1, RUN_LIMIT, true}, // The last byte of a row of RUN_LIMIT bytes.
		{{}, 0, 0, true},
	}
	for &item, index in cases {
		runs: Code_Runs
		copy(runs.runs[:], item.runs[:])
		runs.count = item.count
		kept := code_runs_check(&runs, item.length)
		testing.expectf(t, kept == item.kept, "case %d: kept %v", index, kept)
		testing.expectf(t, kept ? runs.count == item.count : runs.count == 0, "case %d: %d runs", index, runs.count)
	}
	// A count past the limit is the limit.
	many: Code_Runs
	for &run, index in many.runs {
		run = {u8(index), 1, .Operator, 0}
	}
	many.count = 1000
	testing.expect(t, code_runs_check(&many, RUN_LIMIT) && many.count == CODE_RUN_LIMIT)
}

// The bytes of a Code_Runs record, in two parts of the text region; a count
// of bytes that is not a whole count of runs gives no runs.
@(test)
code_runs_read_from_the_text_region :: proc(t: ^testing.T) {
	runs := [2]Code_Run{{0, 7, .Module, 0}, {7, 1, .Operator, 0}}
	bytes := transmute([8]u8)runs
	read, ok := code_runs_read(bytes[:3], bytes[3:])
	testing.expect(t, ok && read.count == 2 && read.runs[0] == runs[0] && read.runs[1] == runs[1])
	read, ok = code_runs_read(bytes[:3], nil)
	testing.expect(t, !ok && read.count == 0)
	too_many: [RUN_LIMIT + 4]u8
	read, ok = code_runs_read(too_many[:], nil)
	testing.expect(t, !ok && read.count == 0)
}

// The kind of each byte of a row, read in order with a cursor.
@(test)
code_runs_kind_of_each_byte :: proc(t: ^testing.T) {
	runs: Code_Runs
	runs.runs[0] = {2, 7, .Module, 0}
	runs.runs[1] = {9, 1, .Operator, 0}
	runs.runs[2] = {12, 2, .Number, 0}
	runs.count = 3
	expected := [?]Code_Kind{.None, .None, .Module, .Module, .Module, .Module, .Module, .Module, .Module, .Operator, .None, .None, .Number, .Number, .None}
	cursor := 0
	for kind, place in expected {
		testing.expectf(t, code_runs_kind_at(&runs, place, &cursor) == kind, "the byte %d", place)
	}
}

// A list row takes the runs that came for its number before it; a row with
// no runs before it is plain; runs that do not fit leave the row plain and
// whole, and are counted.
@(test)
list_rows_take_their_runs :: proc(t: ^testing.T) {
	keeping: List_Keeping
	name := "monitor.count"
	runs := [3]Code_Run{{0, 7, .Module, 0}, {7, 1, .Operator, 0}, {8, 5, .Function, 0}}
	bytes := transmute([12]u8)runs
	list_keep_code_runs(&keeping, {0 = u64(Kind.List_Row), 1 = 0}, bytes[:], nil)
	list_keep_row(&keeping, {0 = 0, 1 = 13}, transmute([]u8)name, nil)
	list_keep_row(&keeping, {0 = 1, 1 = 13}, transmute([]u8)name, nil) // No runs: plain.
	// Runs for the row 2 that pass its text of 5 bytes.
	list_keep_code_runs(&keeping, {0 = u64(Kind.List_Row), 1 = 2}, bytes[:], nil)
	list_keep_row(&keeping, {0 = 2, 1 = 5}, transmute([]u8)name[:5], nil)
	list_keep_show(&keeping, {0 = 3, 1 = 0, 3 = 3})
	testing.expect_value(t, keeping.shown.rows[0].code.count, 3)
	testing.expect_value(t, keeping.shown.rows[1].code.count, 0)
	testing.expect_value(t, keeping.shown.rows[2].code.count, 0)
	testing.expect_value(t, keeping.shown.rows[2].length, 5) // The text is whole.
	testing.expect_value(t, keeping.runs_refused, 1)
	// The runs went to one row: the next row 0 is plain.
	list_keep_row(&keeping, {0 = 0, 1 = 13}, transmute([]u8)name, nil)
	testing.expect_value(t, keeping.next[0].code.count, 0)
	// A row past the rows, and bytes that are no runs: counted, not kept.
	list_keep_code_runs(&keeping, {0 = u64(Kind.List_Row), 1 = LIST_ROWS}, bytes[:], nil)
	list_keep_code_runs(&keeping, {0 = u64(Kind.List_Row), 1 = 3}, bytes[:5], nil)
	testing.expect_value(t, keeping.runs_refused, 3)
	testing.expect_value(t, keeping.pending[3].count, 0)
	// The count stays when the program stops; the runs go.
	list_keep_code_runs(&keeping, {0 = u64(Kind.List_Row), 1 = 4}, bytes[:], nil)
	list_keep_forget(&keeping)
	testing.expect_value(t, keeping.runs_refused, 3)
	testing.expect_value(t, keeping.pending[4].count, 0)
}

// The kind of a Text run lives in a byte that was reserved: the style keeps
// its size, and the zero style has no kind.
@(test)
style_holds_a_code_kind :: proc(t: ^testing.T) {
	testing.expect_value(t, size_of(Style), 8)
	style: Style
	testing.expect_value(t, style.code, Code_Kind.None)
	style = {tone = .Strong, code = .Type}
	testing.expect_value(t, (transmute([8]u8)style)[2], u8(Code_Kind.Type))
}
