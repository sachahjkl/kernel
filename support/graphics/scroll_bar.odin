package graphics

// The scroll bar (docs/DESIGN.md, "The scroll bar"): the one
// table of its sizes, of the stops of its gradients and of its colors. The
// interface package draws each scroll bar of the system from it
// (support/interface/scroll_bar.odin), and the kernel tool writes the scroll
// bars of the site from it (tools/kerneltool/site_style.odin). A change of a
// number here changes both.
//
// The parts, along the bar: an arrow button, the track, an arrow button.
// The thumb lies on the track. Each gradient goes across the bar: from the
// left to the right of a vertical bar, from the top to the bottom of a
// horizontal one.

SCROLL_BAR_THICKNESS :: 17 // The width of a vertical bar, the height of a horizontal one, and the side of an arrow button. It is odd: the grip and the point of a triangle are on its middle line.
SCROLL_BAR_BORDER :: 1 // The border of the track, of an arrow button and of the thumb.
SCROLL_BAR_THUMB_LEAST_PERCENT :: 8 // The thumb is at least this part of the track.
SCROLL_BAR_THUMB_LEAST :: 8 // And at least this many pixels: a border, the inner line and room for the pointer.
SCROLL_BAR_GRIP_LINES :: 4 // The lines of the grip, across the thumb.
SCROLL_BAR_GRIP_LINE_LENGTH :: 7 // The length of a line of the grip.
SCROLL_BAR_GRIP_LINE_STEP :: 2 // From one line of the grip to the next: a line of 1 pixel and a gap of 1 pixel.
SCROLL_BAR_GRIP_LENGTH :: (SCROLL_BAR_GRIP_LINES - 1) * SCROLL_BAR_GRIP_LINE_STEP + 1 // The grip along the thumb.
SCROLL_BAR_GRIP_THUMB_LEAST :: 20 // A thumb longer than this has a grip.
SCROLL_BAR_TRIANGLE_ROWS :: 4 // The triangle of an arrow button: rows of 1, 3, 5 and 7 pixels.
SCROLL_BAR_REPEAT_AFTER :: 400 // Milliseconds: a held arrow button starts to repeat after this.
SCROLL_BAR_REPEAT_EVERY :: 60 // Milliseconds between two steps of a held arrow button.

#assert((SCROLL_BAR_THICKNESS - SCROLL_BAR_GRIP_LINE_LENGTH) % 2 == 0)
#assert(SCROLL_BAR_THICKNESS % 2 == 1)

// Where each stop of a gradient is across its box, in percent.
SCROLL_BAR_TRACK_STOP_PERCENTS :: [3]int{0, 50, 100}
SCROLL_BAR_THUMB_STOP_PERCENTS :: [4]int{0, 45, 55, 100}

// The colors of a scroll bar in one form. Lit: the pointer is over the bar,
// or the thumb is dragged. Hot: the pointer is over this part.
Scroll_Bar_Colors :: struct {
	track:            [3]Color, // The track, across.
	track_border:     Color,
	lit_border:       Color, // The border of an arrow button while the bar is lit.
	thumb_border:     Color, // The border of the thumb at rest.
	hot_border:       Color, // The border of the hot arrow button, and of the thumb while the bar is lit.
	arrow_lit:        [2]Color, // The fill of an arrow button while the bar is lit. At rest a button has no fill: the track shows.
	arrow_hot:        [2]Color,
	arrow_pressed:    [2]Color,
	triangle:         Color,
	triangle_hot:     Color,
	thumb_rest:       [4]Color, // The thumb, across.
	thumb_hot:        [4]Color, // While the pointer is over the bar.
	thumb_pressed:    [4]Color, // While the thumb is dragged.
	thumb_line_level: u32, // The inner line of the thumb: its fill moved toward white by this level of 255.
	grip:             Color,
	grip_lit:         Color,
}

// The dark form: each scroll bar of the system, and the dark form of the site.
@(rodata)
scroll_bar_colors_dark := Scroll_Bar_Colors {
	track            = {0x26303A, 0x2C3743, 0x26303A},
	track_border     = 0x1B232B,
	lit_border       = 0x56687A,
	thumb_border     = 0x56687A,
	hot_border       = 0x4B8FD0,
	arrow_lit        = {0x3A4855, 0x313E4A},
	arrow_hot        = {0x2A4660, 0x223C53},
	arrow_pressed    = {0x2D5578, 0x244A6B},
	triangle         = 0xA7B4C0,
	triangle_hot     = 0xCFE6FA,
	thumb_rest       = {0x4A5967, 0x43515E, 0x3C4955, 0x36424D},
	thumb_hot        = {0x365B7D, 0x305273, 0x2A4968, 0x25415D},
	thumb_pressed    = {0x3C6890, 0x355F85, 0x2E5579, 0x284D6F},
	thumb_line_level = 0x1F,
	grip             = 0x22303C,
	grip_lit         = 0x9CC8EE,
}

// The light form: the light form of the site. No surface of the system is light.
@(rodata)
scroll_bar_colors_light := Scroll_Bar_Colors {
	track            = {0xE3E3E3, 0xF1F1F1, 0xE3E3E3},
	track_border     = 0xD7D7D7,
	lit_border       = 0x9DA8B2,
	thumb_border     = 0x9B9B9B,
	hot_border       = 0x3C7FB1,
	arrow_lit        = {0xF3F3F3, 0xDCDCDC},
	arrow_hot        = {0xE3F4FC, 0xC6E8FA},
	arrow_pressed    = {0xC2E4F6, 0xA9D9F2},
	triangle         = 0x606060,
	triangle_hot     = 0x1C5180,
	thumb_rest       = {0xF3F3F3, 0xE8E8E8, 0xD9D9D9, 0xCDCDCD},
	thumb_hot        = {0xE3F4FC, 0xD0ECFA, 0xBDE4F8, 0xA9DCF6},
	thumb_pressed    = {0xCDE9F8, 0xB4DEF4, 0x9FD4F0, 0x8CCAEC},
	thumb_line_level = 0x66,
	grip             = 0x8E8E8E,
	grip_lit         = 0x3C7FB1,
}

// scroll_bar_stop_place gives the place of a stop across a box of `size`
// pixels: the first pixel for 0 percent, the last one for 100, and the
// nearest pixel between them.
scroll_bar_stop_place :: proc "contextless" (percent, size: int) -> int {
	return (percent * max(size - 1, 0) + 50) / 100
}

// scroll_bar_thumb_line_color gives the color of the inner line of the
// thumb over one color of its fill. The line is opaque: no draw of the
// system blends (docs/DESIGN.md, section 2).
scroll_bar_thumb_line_color :: proc "contextless" (colors: ^Scroll_Bar_Colors, fill_color: Color) -> Color {
	return mix(fill_color, COLOR_WHITE, colors.thumb_line_level)
}
