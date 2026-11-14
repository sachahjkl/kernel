#+build !freestanding
package graphics

import "contract:value_kinds"
import "core:math"
import "core:testing"

// The least contrast of the text of a value on a dark surface of the
// desktop (WCAG 2, the bound of normal text).
VALUE_CONTRAST_LEAST :: 4.5

// value_contrast_ratio gives the contrast ratio of two colors (WCAG 2), as
// the tests of the site and of the terminal compute it.
value_contrast_ratio :: proc(first, second: Color) -> f64 {
	luminance :: proc(color: Color) -> f64 {
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

// Each value kind keeps its contrast on the surfaces where a program draws
// values: the background and the two colors of a card. The band of every
// second row of the program log (0x131B26) is darker than the top of a
// card, so the top of a card is the harder case.
@(test)
value_colors_keep_their_contrast :: proc(t: ^testing.T) {
	surfaces := [?]Color{COLOR_BACKGROUND, COLOR_CARD_TOP, COLOR_CARD_BOTTOM, 0x131B26}
	for kind in value_kinds.Value_Kind {
		color := value_kind_color(kind, false)
		for surface in surfaces {
			ratio := value_contrast_ratio(color, surface)
			testing.expectf(t, ratio >= VALUE_CONTRAST_LEAST, "the value kind %v (%06x) on %06x: a contrast of %.2f; at least %.1f", kind, u32(color), u32(surface), ratio, VALUE_CONTRAST_LEAST)
		}
	}
}

// The kind None and a byte past the kinds have the plain color: a record
// from another program never gives a color that the table does not hold.
@(test)
value_kind_none_is_plain :: proc(t: ^testing.T) {
	testing.expect_value(t, value_kind_color(.None, false, COLOR_DIM), Color(COLOR_DIM))
	testing.expect_value(t, value_kind_color(value_kinds.value_kind_of(200), false, COLOR_DIM), Color(COLOR_DIM))
	testing.expect_value(t, value_kind_color(.Size, false), shade(COLOR_MEMORY, 100))
}
