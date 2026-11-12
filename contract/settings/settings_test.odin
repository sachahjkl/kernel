#+build !freestanding
package settings

import op "contract:operation"
import "core:testing"

// A writer that stops in a change (an odd count) does not stop a reader:
// after READ_TRIES reads it gives the defaults.
@(test)
a_page_left_in_a_change :: proc(t: ^testing.T) {
	page: Page
	write(&page, {.Font = 1, .Subpixel_Order = 2, .Pointer_Theme = 1, .Grid_Fit = 1})
	choice := read(&page)
	testing.expect_value(t, choice.values[.Font], 1)
	testing.expect_value(t, choice.change_count, 2)
	page.change_count = 3
	stopped := read(&page)
	testing.expect_value(t, stopped.values, [Setting]u32{})
	testing.expect_value(t, stopped.change_count, 3)
}

// A value that a setting does not have reads as its default.
@(test)
a_value_out_of_its_setting :: proc(t: ^testing.T) {
	page: Page
	page.values[Setting.Subpixel_Order] = 0xFFFF_FFFF
	page.values[Setting.Font] = 1
	choice := read(&page)
	testing.expect_value(t, choice.values[.Subpixel_Order], 0)
	testing.expect_value(t, choice.values[.Font], 1)
}

// The place of a glyph cache: its fixed address, and the size of the
// context, refused above the span of its range.
@(test)
the_place_of_a_glyph_cache :: proc(t: ^testing.T) {
	values: [op.CONTEXT_VALUES]u64
	values[op.CONTEXT_VALUE_GLYPH_CACHE_SIZE] = 424_784
	values[op.CONTEXT_VALUE_GLYPH_CACHE_BOLD_SIZE] = glyph_cache_places[.Bold].span + 1
	address, size := glyph_cache_place(&values, .With_Grid_Fit)
	testing.expect(t, address == GLYPH_CACHE_ADDRESS && size == 424_784)
	_, absent := glyph_cache_place(&values, .Without_Grid_Fit)
	testing.expect_value(t, absent, 0)
	bold_address, too_large := glyph_cache_place(&values, .Bold)
	testing.expect(t, bold_address == GLYPH_CACHE_BOLD_ADDRESS && too_large == 0)
}

// Two choices with the same values and other counts do not differ; one
// value changed makes them differ, for each setting.
@(test)
values_differ_compares_the_values_only :: proc(t: ^testing.T) {
	first := Choice{values = {.Font = 1, .Subpixel_Order = 2, .Pointer_Theme = 0, .Grid_Fit = 1}, change_count = 2}
	second := first
	second.change_count = 1_000_002
	testing.expect(t, !values_differ(first, second))
	testing.expect(t, !values_differ(first, first))
	for setting in Setting {
		changed := first
		changed.values[setting] += 1
		testing.expectf(t, values_differ(first, changed), "a change of %v", setting)
		testing.expectf(t, values_differ(changed, first), "a change of %v, in the other order", setting)
	}
}
