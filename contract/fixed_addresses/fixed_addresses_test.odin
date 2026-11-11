#+build !freestanding
package fixed_addresses

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
	}
	for address, name in named {
		testing.expectf(t, address == range_of(name).address, "%v: the named address is the address of its member", name)
	}
}
