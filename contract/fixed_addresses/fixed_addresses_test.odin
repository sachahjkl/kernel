#+build !freestanding
package fixed_addresses

import "core:testing"

// Each pair of ranges, not only the neighbours that the compile-time checks
// compare: no two overlap, and each is inside the band on a page.
@(test)
no_two_ranges_overlap :: proc(t: ^testing.T) {
	for first, first_name in ranges {
		testing.expectf(t, first.address >= BAND_START && first.address + first.span <= BAND_END, "%v is inside the band", first_name)
		testing.expectf(t, first.address % 4096 == 0 && first.span > 0, "%v starts on a page and is not empty", first_name)
		for second, second_name in ranges {
			if first_name == second_name {
				continue
			}
			apart := first.address + first.span <= second.address || second.address + second.span <= first.address
			testing.expectf(t, apart, "%v and %v do not overlap", first_name, second_name)
		}
	}
}
