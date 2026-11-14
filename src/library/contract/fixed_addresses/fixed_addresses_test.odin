#+build !freestanding
package fixed_addresses

import op "contract:operation"
import "core:testing"

// Each pair of ranges: no two overlap, and each is inside the band on a
// page. Each named address is the address of its member.
@(test)
no_two_ranges_overlap :: proc(t: ^testing.T) {
	for first_name in Fixed_Range {
		first := range_of(first_name)
		testing.expectf(t, first.address >= BAND_START && first.address + first.span <= BAND_END, "%v is inside the band", first_name)
		testing.expectf(t, first.address % 4096 == 0 && first.span > 0, "%v starts on a page and is not empty", first_name)
		for second_name in Fixed_Range {
			if first_name == second_name {
				continue
			}
			second := range_of(second_name)
			apart := first.address + first.span <= second.address || second.address + second.span <= first.address
			testing.expectf(t, apart, "%v and %v do not overlap", first_name, second_name)
		}
	}
	named := [Fixed_Range]u64 {
		.Module_Files                 = MODULE_FILES_ADDRESS,
		.Pointer_Themes               = POINTER_THEMES_ADDRESS,
		.Settings_Page                = SETTINGS_PAGE_ADDRESS,
		.Glyph_Cache                  = GLYPH_CACHE_ADDRESS,
		.Glyph_Cache_Without_Grid_Fit = GLYPH_CACHE_WITHOUT_GRID_FIT_ADDRESS,
		.Glyph_Cache_Bold             = GLYPH_CACHE_BOLD_ADDRESS,
		.Date_Page                    = DATE_PAGE_ADDRESS,
		.Storage_File                 = STORAGE_FILE_ADDRESS,
		.Module_Tables                = MODULE_TABLES_ADDRESS,
		.Interface_Glyph_Cache        = INTERFACE_GLYPH_CACHE_ADDRESS,
		.Interface_Glyph_Cache_Bold   = INTERFACE_GLYPH_CACHE_BOLD_ADDRESS,
		.Debug_Image                  = DEBUG_IMAGE_ADDRESS,
	}
	for address, name in named {
		testing.expectf(t, address == range_of(name).address, "%v: the named address is the address of its member", name)
	}
}

// The set of the mapped ranges: each member is its own bit, a starter adds
// each one, and a bit past the members names no range.
@(test)
the_set_of_the_mapped_ranges :: proc(t: ^testing.T) {
	values: [op.CONTEXT_VALUES]u64
	testing.expect_value(t, ranges_mapped(&values), Fixed_Ranges{})
	for range in Fixed_Range {
		range_mapped_add(&values, range)
		testing.expectf(t, range in ranges_mapped(&values), "%v is in the set after its add", range)
		testing.expectf(t, values[op.CONTEXT_VALUE_FIXED_RANGES_MAPPED] & (u64(1) << uint(range)) != 0, "%v is the bit %v", range, int(range))
	}
	all := ranges_mapped(&values)
	for range in Fixed_Range {
		testing.expect(t, range in all)
	}
	testing.expect_value(t, values[op.CONTEXT_VALUE_FIXED_RANGES_MAPPED], (u64(1) << uint(int(max(Fixed_Range)) + 1)) - 1)
	// One bit alone: the other ranges are not mapped.
	values = {}
	range_mapped_add(&values, .Date_Page)
	testing.expect_value(t, ranges_mapped(&values), Fixed_Ranges{.Date_Page})
	// A bit past the last member: no member is in the set.
	values[op.CONTEXT_VALUE_FIXED_RANGES_MAPPED] = u64(1) << 63
	for range in Fixed_Range {
		testing.expect(t, range not_in ranges_mapped(&values))
	}
}
