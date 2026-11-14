#+build !freestanding
package graphics

import "core:testing"

// The least contrast of a text of normal size (WCAG 2), and of a large
// text: a text of 24 pixels or more.
@(private = "file")
TEXT_CONTRAST_LEAST :: 4.5
@(private = "file")
LARGE_TEXT_CONTRAST_LEAST :: 3.0

@(private = "file")
expect_contrast :: proc(t: ^testing.T, what: string, text, surface: Color, least: f64) {
	ratio := value_contrast_ratio(text, surface)
	testing.expectf(t, ratio >= least, "%s (%06x on %06x): a contrast of %.2f; at least %.1f", what, u32(text), u32(surface), ratio, least)
}

// The pairs of colors of the palette (docs/DESIGN.md, "Palette") keep the
// contrast that a text needs.
@(test)
palette_colors_keep_their_contrast :: proc(t: ^testing.T) {
	// The chosen row: its name and its hint are white on the chosen blue.
	expect_contrast(t, "white on the chosen row", COLOR_WHITE, COLOR_CHOSEN, TEXT_CONTRAST_LEAST)
	// The row that asks for a second Enter: white on the color of "stop a
	// program".
	expect_contrast(t, "white on the row that asks", COLOR_WHITE, COLOR_STOP_PROGRAM, TEXT_CONTRAST_LEAST)
	// The input band: the typed part is white on the track, and each class
	// of code keeps its contrast there too.
	expect_contrast(t, "the typed part on the input band", COLOR_WHITE, COLOR_TRACK, TEXT_CONTRAST_LEAST)
	for class in Code_Class {
		if class != .None {
			expect_contrast(t, "a class of code on the input band", code_class_color(class, false), COLOR_TRACK, TEXT_CONTRAST_LEAST)
		}
	}
	// The placeholder of the input band is dim, at twice the size of the
	// font: a large text.
	expect_contrast(t, "the placeholder on the input band", COLOR_DIM, COLOR_TRACK, LARGE_TEXT_CONTRAST_LEAST)
	// The rows, the headings of the groups, the detail line and the footer
	// are on the surface of a card: the name in the text color, the words
	// at the right and the sentences in the dim color.
	for surface in ([2]Color{COLOR_CARD_TOP, COLOR_CARD_BOTTOM}) {
		expect_contrast(t, "a name on the card", COLOR_TEXT, surface, TEXT_CONTRAST_LEAST)
		expect_contrast(t, "a dim text on the card", COLOR_DIM, surface, TEXT_CONTRAST_LEAST)
	}
}

// The least contrast of a graphic that carries a fact (WCAG 2.1, 1.4.11).
@(private = "file")
GRAPHIC_CONTRAST_LEAST :: 3.0

// The icon of a row of the palette (docs/DESIGN.md, "The icons of the
// kinds") keeps the contrast of a graphic on each surface under it: each
// color that an icon takes on the surface of a card, and white on the
// chosen row and on the row that asks for a second Enter. The deep red of
// "stop a program" does not keep it on a card, so the icon of an entry
// that destroys has the brighter red of that concept.
@(test)
palette_icon_colors_keep_their_contrast :: proc(t: ^testing.T) {
	icon_colors := [?]Color {
		value_kind_color(.Module, false), // A program that has a window, an export.
		value_kind_color(.Command, false), // A command.
		value_kind_color(.Grant, false), // A grant, as a candidate of a field.
		COLOR_TITLE, // The window that has the focus.
		COLOR_TEXT, // The value of a setting that the machine uses.
		COLOR_DIM, // The quiet state of each of them.
		COLOR_STOP_PROGRAM_POINTER_OVER, // An entry that destroys.
	}
	for surface in ([2]Color{COLOR_CARD_TOP, COLOR_CARD_BOTTOM}) {
		for color in icon_colors {
			expect_contrast(t, "an icon on the card", color, surface, GRAPHIC_CONTRAST_LEAST)
		}
	}
	expect_contrast(t, "a white icon on the chosen row", COLOR_WHITE, COLOR_CHOSEN, GRAPHIC_CONTRAST_LEAST)
	expect_contrast(t, "a white icon on the row that asks", COLOR_WHITE, COLOR_STOP_PROGRAM, GRAPHIC_CONTRAST_LEAST)
	// Why the icon of an entry that destroys is not in the deep red, and
	// why each icon of a chosen row is white: these pairs are under the
	// bound.
	testing.expect(t, value_contrast_ratio(COLOR_STOP_PROGRAM, COLOR_CARD_TOP) < GRAPHIC_CONTRAST_LEAST)
	testing.expect(t, value_contrast_ratio(value_kind_color(.Module, false), COLOR_CHOSEN) < GRAPHIC_CONTRAST_LEAST)
}
