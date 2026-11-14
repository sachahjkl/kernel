#+build !freestanding
package system

import "modus:contract/fixed_addresses"
import op "modus:contract/operation"
import "core:testing"

// The modules of a program end before the band of the fixed ranges: a
// module and the page with no memory after it end at MODULES_END or
// before.
@(test)
a_module_fits_below_the_band :: proc(t: ^testing.T) {
	SIZE :: 16 * PAGE_SIZE
	// It ends one page before the band: its page with no memory is the last
	// page before the band.
	testing.expect(t, module_fits_below_band(fixed_addresses.MODULES_END - PAGE_SIZE - SIZE, SIZE))
	// Its end reaches the band: the page after it would be in the band.
	testing.expect(t, !module_fits_below_band(fixed_addresses.MODULES_END - SIZE, SIZE))
	testing.expect(t, !module_fits_below_band(fixed_addresses.MODULES_END, 0))
	// A size that would wrap a sum.
	testing.expect(t, !module_fits_below_band(op.MODULE_BASE, max(u64) - PAGE_SIZE + 1))
	testing.expect(t, !module_fits_below_band(max(u64), SIZE))
	testing.expect(t, module_fits_below_band(op.MODULE_BASE, SIZE))
}
