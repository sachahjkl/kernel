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
