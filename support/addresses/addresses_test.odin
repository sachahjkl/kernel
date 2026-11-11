#+build !freestanding
package addresses

import op "contract:operation"
import "core:testing"

// Two mappings that follow each other have no gap; a gap is one folded part
// of its fixed width; the parts fill the band, in order.
@(test)
band_folds_gaps :: proc(t: ^testing.T) {
	mappings := [?]op.Program_Mapping {
		{address = 0x400000, page_count = 10},
		{address = 0x40A000, page_count = 30}, // Right after the first.
		{address = 0x7FFF_0000_0000, page_count = 4}, // Far away: one folded gap.
	}
	segments: [8]Segment
	count := band(mappings[:], 400, 16, 4, segments[:])
	testing.expect_value(t, count, 4)
	testing.expect_value(t, segments[0].mapping, 0)
	testing.expect_value(t, segments[1].mapping, 1)
	testing.expect_value(t, segments[2].mapping, -1)
	testing.expect_value(t, segments[2].width, 16)
	testing.expect_value(t, segments[3].mapping, 2)
	end := segments[3].x + segments[3].width
	testing.expect_value(t, end, 400)
	for index in 1 ..< count {
		testing.expect_value(t, segments[index].x, segments[index - 1].x + segments[index - 1].width)
	}
	// The widths follow the pages: 30 pages are wider than 10, and 4.
	testing.expect(t, segments[1].width > segments[0].width && segments[0].width > segments[3].width)
	// Each mapping has its least width, also in a narrow band.
	count = band(mappings[:], 10, 16, 4, segments[:])
	for index in 0 ..< count {
		testing.expect(t, segments[index].width >= 4)
	}
	testing.expect_value(t, band(nil, 400, 16, 4, segments[:]), 0)
}

// An address is "module + offset" in the record that holds it.
@(test)
module_offset :: proc(t: ^testing.T) {
	modules := [?]op.Module_Record{{base = 0x400000, size = 0x20000}, {base = 0x430000, size = 0x8000}}
	index, offset := module_of(0x401234, modules[:])
	testing.expect(t, index == 0 && offset == 0x1234)
	index, offset = module_of(0x437FFF, modules[:])
	testing.expect(t, index == 1 && offset == 0x7FFF)
	index, _ = module_of(0x438000, modules[:])
	testing.expect(t, index == -1, "the first byte after a module is in no module")
	index, _ = module_of(0x420000, modules[:])
	testing.expect(t, index == -1, "between two modules")
}

@(test)
kinds :: proc(t: ^testing.T) {
	modules := [?]op.Module_Record{{base = 0x400000, size = 0x20000}}
	testing.expect_value(t, kind_of({address = 0x400000, flags = {.Execute}}, modules[:]), Kind.Module_Code)
	testing.expect_value(t, kind_of({address = 0x410000, flags = {.Write}}, modules[:]), Kind.Module_Data)
	testing.expect_value(t, kind_of({address = 0x408000}, modules[:]), Kind.Module_Constants)
	testing.expect_value(t, kind_of({address = 0x900000, flags = {.Write, .Shared}}, modules[:]), Kind.Shared)
	testing.expect_value(t, kind_of({address = 0x900000, flags = {.Write}}, modules[:]), Kind.Memory)
	testing.expect_value(t, kind_of({address = op.THREAD_AREA_BASE, flags = {.Write, .Thread_Area}}, modules[:]), Kind.Thread_Area)
	testing.expect_value(t, kind_of({address = 0x900000, flags = {.Write, .Device, .Shared}}, modules[:]), Kind.Device)
}
