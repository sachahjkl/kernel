#+build !freestanding
package image_card

import info "contract:boot_info"
import module "contract:module"
import "core:testing"

// The width of the content of the card on the boot display, and the width
// of its names: what the boot display gives to this package.
@(private = "file")
CARD_WIDTH :: 536
@(private = "file")
NAMES_WIDTH :: 320

@(private = "file")
Test_File :: struct {
	name: string,
	size: u64,
	kind: File_Kind,
}

// The modules and the resources of the boot image of the last build when
// this test was written (77 modules, 9 resources), in the order of the
// image.
@(private = "file", rodata)
image_of_today := [?]Test_File {
	{"root", 249856, .Program},
	{"input", 20480, .Program},
	{"compositor", 166219, .Program},
	{"console", 304344, .Program},
	{"monitor", 110592, .Program},
	{"plasma", 69632, .Program},
	{"life", 92924, .Program},
	{"paint", 94208, .Program},
	{"fault", 16384, .Program},
	{"temple", 249856, .Program},
	{"node", 16384, .Program},
	{"rings", 126976, .Program},
	{"threads", 77824, .Program},
	{"workers", 77824, .Program},
	{"rights", 77824, .Program},
	{"origin", 77824, .Program},
	{"limits", 79537, .Program},
	{"budget", 77824, .Program},
	{"flow", 77824, .Program},
	{"crowd", 86016, .Program},
	{"tally", 94208, .Program},
	{"manual", 180224, .Program},
	{"clock", 87632, .Program},
	{"randomness", 86016, .Program},
	{"extended_state", 102400, .Program},
	{"return_fault", 127833, .Program},
	{"fault_ring", 153257, .Program},
	{"kernel_events", 179329, .Program},
	{"terminal", 98304, .Program},
	{"flood", 28672, .Program},
	{"processors", 81920, .Program},
	{"boot", 102400, .Program},
	{"pages", 53248, .Program},
	{"frames", 131072, .Program},
	{"twin", 12288, .Program},
	{"locks", 147456, .Program},
	{"shortage", 24576, .Program},
	{"scheduler", 106496, .Program},
	{"address_space", 204800, .Program},
	{"locker", 16384, .Program},
	{"log", 73728, .Program},
	{"block", 24576, .Program},
	{"frame", 24576, .Program},
	{"network", 61440, .Program},
	{"net", 115931, .Program},
	{"server", 172032, .Program},
	{"fetch", 114688, .Program},
	{"inspect", 131072, .Program},
	{"disk", 105124, .Program},
	{"storage", 131072, .Program},
	{"notes", 118352, .Program},
	{"host", 81920, .Program},
	{"probe", 16384, .No_Entry},
	{"math", 15297, .No_Entry},
	{"cryptography", 282473, .No_Entry},
	{"cryptography_vectors", 102400, .Program},
	{"quic_echo", 204800, .Program},
	{"remote", 237568, .Program},
	{"sample", 45056, .Program},
	{"hostile_exports", 12288, .No_Entry},
	{"calendar", 12288, .No_Entry},
	{"calendar_fixed", 12288, .No_Entry},
	{"calendar_changed", 12288, .No_Entry},
	{"agenda", 12288, .Program},
	{"lonely", 9154, .No_Entry},
	{"imports", 155648, .Program},
	{"errors", 209873, .Program},
	{"interface_elements", 94208, .Program},
	{"tables", 163840, .Program},
	{"interface_module", 57344, .No_Entry},
	{"interface_through_module", 49152, .Program},
	{"text_shaping", 12288, .No_Entry},
	{"vector_glyphs", 221184, .Program},
	{"interface_font", 86016, .Program},
	{"pointers", 96136, .Program},
	{"settings", 136697, .Program},
	{"date", 45056, .Program},
	{"pointers_posy", 883008, .Resource},
	{"pointers_system", 208512, .Resource},
	{"glyph_cache", 378368, .Resource},
	{"glyph_cache_no_grid_fit", 383104, .Resource},
	{"glyph_cache_bold", 29600, .Resource},
	{"interface_glyph_cache", 424784, .Resource},
	{"interface_glyph_cache_bold", 108324, .Resource},
	{"system_description", 6816, .Resource},
	{"system_description_signature", 64, .Resource},
}

@(private = "file")
layout_of :: proc(layout: ^Layout, files: []Test_File, failed_name: string, strip_width, names_width: int) {
	layout_reset(layout)
	for file in files {
		file_add(layout, file.name, file.size, file.kind, failed_name)
	}
	layout_place(layout, strip_width, names_width)
}

// The parts of the strip follow each other with no gap and fill the width
// exactly; no part is narrower than its least width.
@(private = "file")
strip_check :: proc(t: ^testing.T, layout: ^Layout, width: int, case_name: string) {
	x := 0
	for &file in layout.files[:layout.file_count] {
		if file.strip_width == 0 {
			continue
		}
		testing.expectf(t, file.strip_x == x, "%s: %s starts at %d, not at %d", case_name, file.name, file.strip_x, x)
		least := min(file.failed ? FAILED_LEAST_WIDTH : STRIP_LEAST_WIDTH, width)
		testing.expectf(t, file.strip_width >= least, "%s: %s has %d pixels, under %d", case_name, file.name, file.strip_width, least)
		x += file.strip_width
	}
	if layout.file_count != 0 {
		testing.expectf(t, x == width, "%s: the parts fill %d pixels of %d", case_name, x, width)
	}
}

// The files go by kind, then from the largest to the smallest.
@(private = "file")
order_check :: proc(t: ^testing.T, layout: ^Layout, case_name: string) {
	for index in 1 ..< layout.file_count {
		before := &layout.files[index - 1]
		after := &layout.files[index]
		in_order := before.kind < after.kind || (before.kind == after.kind && before.size >= after.size)
		testing.expectf(t, in_order, "%s: %s before %s", case_name, before.name, after.name)
	}
}

// Each tile holds its whole name and stays in the width; two tiles of one
// row do not touch; the tiles of a kind are its largest files, in order;
// the count of the files with no tile fits after them.
@(private = "file")
names_check :: proc(t: ^testing.T, layout: ^Layout, width: int, case_name: string) {
	for &tile, index in layout.tiles[:layout.tile_count] {
		file := &layout.files[tile.file]
		testing.expectf(t, tile.width == len(file.name) * CELL_WIDTH + 2 * TILE_PADDING, "%s: the tile of %s is not its whole name", case_name, file.name)
		testing.expectf(t, tile.x >= 0 && tile.x + tile.width <= width, "%s: the tile of %s passes the width", case_name, file.name)
		testing.expectf(t, tile.row >= 0 && tile.row < NAME_ROW_COUNT, "%s: the tile of %s is in row %d", case_name, file.name, tile.row)
		if index > 0 {
			before := &layout.tiles[index - 1]
			if before.row == tile.row {
				testing.expectf(t, tile.x >= before.x + before.width + TILE_GAP, "%s: the tile of %s touches the tile before it", case_name, file.name)
			} else {
				testing.expectf(t, tile.row > before.row, "%s: the tile of %s goes back to an earlier row", case_name, file.name)
			}
		}
	}
	rows := 0
	for kind in File_Kind {
		summary := &layout.kinds[kind]
		rows += summary.row_count
		seen := 0
		for &tile in layout.tiles[:layout.tile_count] {
			if layout.files[tile.file].kind != kind {
				continue
			}
			testing.expectf(t, tile.file == summary.first + seen, "%s: a tile of %v is not of the next largest file", case_name, kind)
			testing.expectf(t, tile.row >= summary.first_row && tile.row < summary.first_row + summary.row_count, "%s: a tile of %v is outside the rows of its kind", case_name, kind)
			seen += 1
		}
		testing.expectf(t, seen == summary.named, "%s: %v has %d tiles and says %d", case_name, kind, seen, summary.named)
		// A count after a tile is on the last row of the kind, which kept room for it.
		if summary.count > summary.named && summary.more_x > 0 {
			testing.expectf(t, summary.more_x + more_width(summary.count - summary.named) <= width, "%s: the count of the files of %v with no tile passes the width", case_name, kind)
		}
	}
	testing.expectf(t, rows <= NAME_ROW_COUNT, "%s: %d rows of names", case_name, rows)
}

@(test)
the_strip_fills_the_width :: proc(t: ^testing.T) {
	layout := new(Layout)
	defer free(layout)
	one_large := [?]Test_File{{"large", 1_000_000, .Program}, {"a", 10, .Program}, {"b", 10, .No_Entry}, {"c", 10, .Resource}}
	all_empty := [?]Test_File{{"a", 0, .Program}, {"b", 0, .Program}, {"c", 0, .Resource}}
	alone := [?]Test_File{{"alone", 12345, .No_Entry}}
	equal := [?]Test_File{{"a", 7, .Resource}, {"b", 7, .Resource}, {"c", 7, .Resource}}
	many: [300]Test_File
	for &file, index in many {
		file = {"many", u64(index * 7919 % 1000), File_Kind(index % 3)}
	}
	cases := [?][]Test_File{one_large[:], all_empty[:], alone[:], equal[:], many[:], image_of_today[:]}
	for files, case_index in cases {
		for width in ([?]int{CARD_WIDTH, 100, 37, 1}) {
			layout_of(layout, files, "", width, NAMES_WIDTH)
			case_name := "a list of sizes"
			if case_index == len(cases) - 1 {
				case_name = "the image of today"
			}
			strip_check(t, layout, width, case_name)
			order_check(t, layout, case_name)
		}
	}
}

// When the files outnumber the pixels, the smallest ones have no part, and
// each file with a part has at least as many bytes as each file with none.
@(test)
the_smallest_files_leave_a_narrow_strip :: proc(t: ^testing.T) {
	layout := new(Layout)
	defer free(layout)
	many: [400]Test_File
	for &file, index in many {
		file = {"many", u64(1 + index * 7919 % 4000), File_Kind(index % 3)}
	}
	many[17].name = "failed"
	many[17].size = 0
	layout_of(layout, many[:], "failed", 300, NAMES_WIDTH)
	strip_check(t, layout, 300, "400 files in 300 pixels")
	smallest_kept := max(u64)
	largest_left := u64(0)
	parts := 0
	for &file in layout.files[:layout.file_count] {
		if file.failed {
			testing.expectf(t, file.strip_width >= FAILED_LEAST_WIDTH, "the failed file has %d pixels", file.strip_width)
			continue
		}
		if file.strip_width == 0 {
			largest_left = max(largest_left, file.size)
		} else {
			smallest_kept = min(smallest_kept, file.size)
			parts += 1
		}
	}
	testing.expectf(t, largest_left <= smallest_kept, "a file of %d bytes has no part, and one of %d bytes has one", largest_left, smallest_kept)
	testing.expectf(t, parts == (300 - FAILED_LEAST_WIDTH) / STRIP_LEAST_WIDTH, "%d parts", parts)
}

// Files of equal sizes keep the order of the image; the kinds keep their
// order whatever the order of the image.
@(test)
the_order_is_stable :: proc(t: ^testing.T) {
	layout := new(Layout)
	defer free(layout)
	files := [?]Test_File{{"resource", 50, .Resource}, {"first", 10, .Program}, {"no_entry", 90, .No_Entry}, {"second", 10, .Program}, {"large", 20, .Program}, {"third", 10, .Program}}
	layout_of(layout, files[:], "", CARD_WIDTH, NAMES_WIDTH)
	expected := [?]string{"large", "first", "second", "third", "no_entry", "resource"}
	testing.expect_value(t, layout.file_count, len(expected))
	for name, index in expected {
		testing.expectf(t, layout.files[index].name == name, "place %d: %s, not %s", index, layout.files[index].name, name)
	}
	testing.expect_value(t, layout.kinds[.Program].count, 4)
	testing.expect_value(t, layout.kinds[.Program].bytes, u64(50))
	testing.expect_value(t, file_total(layout), 6)
	testing.expect_value(t, byte_total(layout), u64(190))
}

@(test)
names_are_whole_or_absent :: proc(t: ^testing.T) {
	layout := new(Layout)
	defer free(layout)
	long_names := [?]Test_File{{"a_name_much_wider_than_the_names_of_the_card", 900, .Program}, {"short", 800, .Program}, {"b", 1, .Resource}}
	for width in ([?]int{NAMES_WIDTH, 200, 64, 8}) {
		layout_of(layout, image_of_today[:], "", CARD_WIDTH, width)
		names_check(t, layout, width, "the image of today")
		layout_of(layout, long_names[:], "", CARD_WIDTH, width)
		names_check(t, layout, width, "a name wider than the card")
	}
	// The first name does not fit: no smaller program takes its place.
	layout_of(layout, long_names[:], "", CARD_WIDTH, NAMES_WIDTH)
	testing.expect_value(t, layout.kinds[.Program].named, 0)
	testing.expect_value(t, layout.kinds[.Resource].named, 1)
}

// The real image shows the names of its largest files, far more than the
// two names of the tiles that the card had before.
@(test)
the_image_of_today_names_twelve_files :: proc(t: ^testing.T) {
	layout := new(Layout)
	defer free(layout)
	layout_of(layout, image_of_today[:], "", CARD_WIDTH, NAMES_WIDTH)
	testing.expectf(t, layout.tile_count >= 12, "%d names", layout.tile_count)
	testing.expect_value(t, layout.kinds[.Program].count, 67)
	testing.expect_value(t, layout.kinds[.No_Entry].count, 10)
	testing.expect_value(t, layout.kinds[.Resource].count, 9)
	// The largest program, module with no entry and resource each have a tile.
	for name in ([?]string{"console", "cryptography", "pointers_posy"}) {
		found := false
		for &tile in layout.tiles[:layout.tile_count] {
			if layout.files[tile.file].name == name {
				found = true
			}
		}
		testing.expectf(t, found, "%s has no tile", name)
	}
}

@(test)
the_failed_file_is_marked :: proc(t: ^testing.T) {
	layout := new(Layout)
	defer free(layout)
	for failed_name in ([?]string{"console", "lonely", "system_description_signature"}) {
		layout_of(layout, image_of_today[:], failed_name, CARD_WIDTH, NAMES_WIDTH)
		strip_check(t, layout, CARD_WIDTH, failed_name)
		marked := 0
		for &file in layout.files[:layout.file_count] {
			if file.failed {
				marked += 1
				testing.expectf(t, file.name == failed_name, "%s is marked, not %s", file.name, failed_name)
				testing.expectf(t, file.strip_width >= FAILED_LEAST_WIDTH, "%s has %d pixels", file.name, file.strip_width)
			}
		}
		testing.expectf(t, marked == 1, "%s: %d files marked", failed_name, marked)
	}
	// The kernel is not a file of the image: no file is marked.
	layout_of(layout, image_of_today[:], "kernel", CARD_WIDTH, NAMES_WIDTH)
	for &file in layout.files[:layout.file_count] {
		testing.expectf(t, !file.failed, "%s is marked", file.name)
	}
}

@(private = "file")
put :: proc(destination: []u8, offset: int, value: $T) {
	copy_of := value
	copy(destination[offset:], ([^]u8)(&copy_of)[:size_of(T)])
}

@(private = "file")
entry_of :: proc(name: string, offset, size: u64) -> (entry: info.Image_Entry) {
	copy(entry.name[:], name)
	entry.offset = offset
	entry.size = size
	return
}

// An image in memory: the kind of a module comes from its header, and an
// entry that points outside the image counts with no bytes.
@(test)
files_read_from_an_image :: proc(t: ^testing.T) {
	image := make([]u8, 4096)
	defer delete(image)
	put(image, 0, info.Image_Header{magic = info.IMAGE_MAGIC, count = 3, resource_count = 1})
	table := size_of(info.Image_Header)
	put(image, table, entry_of("starts", 1024, 100))
	put(image, table + size_of(info.Image_Entry), entry_of("imported", 2048, 100))
	put(image, table + 2 * size_of(info.Image_Entry), entry_of("outside", 1 << 40, 100))
	put(image, table + 3 * size_of(info.Image_Entry), entry_of("theme", 3072, 10))
	put(image, 1024, module.Header{magic = module.MAGIC, version = module.VERSION, header_size = size_of(module.Header), machine = .X86_64, entry_export = 1})
	put(image, 2048, module.Header{magic = module.MAGIC, version = module.VERSION, header_size = size_of(module.Header), machine = .X86_64})
	layout := new(Layout)
	defer free(layout)
	layout_compute(layout, image, "imported", CARD_WIDTH, NAMES_WIDTH)
	testing.expect(t, layout.valid)
	testing.expect_value(t, layout.file_count, 4)
	testing.expect_value(t, layout.kinds[.Program].count, 1)
	testing.expect_value(t, layout.kinds[.No_Entry].count, 2)
	testing.expect_value(t, layout.kinds[.No_Entry].bytes, u64(100))
	testing.expect_value(t, layout.kinds[.Resource].count, 1)
	testing.expect(t, layout.files[0].name == "starts" && layout.files[0].kind == .Program)
	testing.expect(t, layout.files[1].name == "imported" && layout.files[1].failed)
	testing.expect(t, layout.files[2].name == "outside" && layout.files[2].size == 0)
	testing.expect(t, layout.files[3].name == "theme" && layout.files[3].kind == .Resource)
	strip_check(t, layout, CARD_WIDTH, "an image in memory")
	names_check(t, layout, NAMES_WIDTH, "an image in memory")
	// A wrong mark: the layout is not valid and holds no file.
	image[0] = 0
	layout_compute(layout, image, "", CARD_WIDTH, NAMES_WIDTH)
	testing.expect(t, !layout.valid)
	testing.expect_value(t, layout.file_count, 0)
}
