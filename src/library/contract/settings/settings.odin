// The settings of the owner (docs/FONTS.md, "The setting"): one page that
// the root service creates. The program `settings` is its one writer; each
// program with a surface or a terminal, and the compositor, map it with the
// right Read only, at PAGE_ADDRESS. The bit of the range Settings_Page in
// the context value op.CONTEXT_VALUE_FIXED_RANGES_MAPPED says that it is
// mapped (clear: the program has no page, and its text is Spleen).
//
// Each setting is one value of the page and one row of `descriptions`: its
// name and the names of its values. Value 0 of each setting is its default
// (ZII): an all-zero page is the vector font with the grid fit, red green
// blue, the pointer theme of the owner when the boot image has it.
//
// The page holds the choices only. The glyph caches (the three of the font
// of the cells, the two of the interface font) are not on the page: the
// root service maps these resources of the boot image read-only in the
// same programs, after it checked their hashes and their format, at the
// fixed ranges of modus:contract/fixed_addresses, and sets the bit of each range
// in the context of each program (glyph_cache_open). The program
// `settings` writes the page, so a field of the page can only change a
// look: no program reads an address or a size from it.
//
// A change: the writer makes change_count odd, writes the values, makes it
// even again, and wakes the threads that wait on it (the compositor). The
// compositor then sends the display event Settings_Changed to each window,
// and each program draws again. A reader copies the values while
// change_count stays even and the same (read).
//
// The program `settings` keeps the values in its private store, as one
// record (Kept_Settings) in one object: one write is one commit, so a loss
// of power gives the old record or the new one, never a mix. At boot the
// root service starts `settings` for one pass with no window: it reads the
// record and writes the page.
package settings

import "base:intrinsics"
import "modus:contract/fixed_addresses"
import "modus:contract/glyph_cache"
import op "modus:contract/operation"

PAGE_ADDRESS :: fixed_addresses.SETTINGS_PAGE_ADDRESS // Where a program maps the settings page.
GLYPH_CACHE_ADDRESS :: fixed_addresses.GLYPH_CACHE_ADDRESS // Where a program maps the glyph cache with grid fit.
GLYPH_CACHE_WITHOUT_GRID_FIT_ADDRESS :: fixed_addresses.GLYPH_CACHE_WITHOUT_GRID_FIT_ADDRESS // The glyph cache with no grid fit.
GLYPH_CACHE_BOLD_ADDRESS :: fixed_addresses.GLYPH_CACHE_BOLD_ADDRESS // The glyph cache of the bold weight.
GRANT_PAGE :: 12 // The handle of the context of the program `settings`: the page, with Read and Write.
VALUE_BOOT_PASS :: op.CONTEXT_VALUE_SETTINGS_BOOT_PASS // The program `settings`: 1 for the pass at boot (read the kept record, write the page, stop).
KEPT_OBJECT_NAME :: "settings" // The object of the private store of `settings` that holds Kept_Settings.

// The settings, in the order of the page and of the window.
Setting :: enum u32 {
	Font           = 0, // Which font draws the text of the system: `Font`.
	Subpixel_Order = 1, // The order of the color stripes of the screen: `Subpixel_Order`.
	Pointer_Theme  = 2, // Which pointer theme the compositor draws: `Pointer_Theme`.
	Grid_Fit       = 3, // Whether the glyphs sit on whole pixels: `Grid_Fit`.
}

// The values of each setting. 0 is the default.
Font :: enum u32 {
	Vector = 0, // The vector font of the glyph cache.
	Spleen = 1, // The bitmap font Spleen 8x16: the fallback, and a choice of the owner.
}

// The order of the color stripes of the pixels of the screen, from the left.
Subpixel_Order :: enum u32 {
	Red_Green_Blue = 0, // Red at the left: most screens.
	Blue_Green_Red = 1, // Blue at the left.
	None           = 2, // Grayscale: a screen with no stripes in rows, or a screenshot to read.
}

// The pointer theme that the compositor draws (docs/POINTERS.md).
Pointer_Theme :: enum u32 {
	Of_The_Owner  = 0, // The first theme of pointer_pictures.RESOURCE_PREFERENCE that the boot image has.
	Of_The_System = 1, // The theme of the system (resources/pointers/system.manifest).
}

// Whether the text of the system is fitted to the grid of pixels.
Grid_Fit :: enum u32 {
	On  = 0, // The baseline, the x-height and the cap height on whole pixels (docs/FONTS.md, "Grid fit").
	Off = 1, // The shapes of the design: the glyph cache with no grid fit.
}

SETTING_CAPACITY :: 8 // The page and the kept record have room for 8 values.
VALUE_NAME_CAPACITY :: 4 // The most values of one setting.

// Description: the name of a setting and the names of its values, for the
// exports and the window of `settings`.
Description :: struct {
	name:        string, // The name in the exports and in the console: "subpixel_order".
	title:       string, // For the window.
	value_names: [VALUE_NAME_CAPACITY]string, // The name of each value, by its number.
	value_count: u32, // The values of the setting.
}

// The description of each setting.
descriptions := [Setting]Description {
	.Font           = {"font", "font", {"vector", "spleen", "", ""}, len(Font)},
	.Subpixel_Order = {"subpixel_order", "subpixel order", {"rgb", "bgr", "none", ""}, len(Subpixel_Order)},
	.Pointer_Theme  = {"pointer_theme", "pointer theme", {"owner", "system", "", ""}, len(Pointer_Theme)},
	.Grid_Fit       = {"grid_fit", "grid fit", {"on", "off", "", ""}, len(Grid_Fit)},
}

// The settings page: what the program `settings` writes and each program
// with a surface reads, at PAGE_ADDRESS. A reader copies it while
// change_count stays even and the same.
Page :: struct {
	change_count:                     u32, // Even when the page is stable. Each change adds 2.
	reserved:                         u32, // 0.
	values:                           [SETTING_CAPACITY]u32, // By Setting. A reader keeps each value through `valid`.
}
#assert(size_of(Page) <= 4096)

// The glyph caches that a program with a surface or a terminal can
// receive: the three of the font of the cells, and the two of the
// interface font (docs/FONTS.md, section 12).
Glyph_Cache :: enum u8 {
	With_Grid_Fit, // The font of the cells, with grid fit.
	Without_Grid_Fit, // The font of the cells, with no grid fit.
	Bold, // Scale 1 only: the titles of the cards. Absent: the titles are the regular weight.
	Interface, // B612 Regular: three positions at scale 1, one at the scales 2 and 3.
	Interface_Bold, // B612 Bold: scale 1 only, three positions.
}

// The fixed range of each glyph cache.
glyph_cache_ranges := [Glyph_Cache]fixed_addresses.Fixed_Range {
	.With_Grid_Fit    = .Glyph_Cache,
	.Without_Grid_Fit = .Glyph_Cache_Without_Grid_Fit,
	.Bold             = .Glyph_Cache_Bold,
	.Interface        = .Interface_Glyph_Cache,
	.Interface_Bold   = .Interface_Glyph_Cache_Bold,
}

// glyph_cache_open validates a glyph cache of this program at its fixed
// range. With the bit of the range clear in the context (the starter did
// not map it), nothing is read and the problem is Not_Mapped. Else the
// size comes from the header of the cache, bounded by the span of the
// range (glyph_cache.validate_at). The bytes there are pages of the boot
// image, mapped read-only, that no program can write (docs/FONTS.md,
// section 5, "Who can write a cache").
glyph_cache_open :: proc "contextless" (values: ^[op.CONTEXT_VALUES]u64, cache: Glyph_Cache) -> (glyph_cache.Cache, glyph_cache.Problem) {
	range := glyph_cache_ranges[cache]
	if range not_in fixed_addresses.ranges_mapped(values) {
		return {}, {kind = .Not_Mapped, index = u32(range)}
	}
	place := fixed_addresses.range_of(range)
	return glyph_cache.validate_at(uintptr(place.address), place.span)
}

// Choice: the values of a page, as one copy.
Choice :: struct {
	values:       [Setting]u32, // The value of each setting, kept valid.
	change_count: u32, // The change count of the page at the copy.
}

// font_of gives the font of a choice.
font_of :: #force_inline proc "contextless" (choice: Choice) -> Font {
	return Font(choice.values[.Font])
}

// subpixel_order_of gives the subpixel order of a choice.
subpixel_order_of :: #force_inline proc "contextless" (choice: Choice) -> Subpixel_Order {
	return Subpixel_Order(choice.values[.Subpixel_Order])
}

// pointer_theme_of gives the pointer theme of a choice.
pointer_theme_of :: #force_inline proc "contextless" (choice: Choice) -> Pointer_Theme {
	return Pointer_Theme(choice.values[.Pointer_Theme])
}

// grid_fit_of gives the grid fit of a choice.
grid_fit_of :: #force_inline proc "contextless" (choice: Choice) -> Grid_Fit {
	return Grid_Fit(choice.values[.Grid_Fit])
}

// valid gives the value, or the default 0 for a value that the setting does
// not have (a page or a record of a later version).
//
// The count of the values of each setting is a number in the code here, and
// not a read of `descriptions`: that table holds names, so it has addresses
// that a loader writes, and a module that only reads a choice (the drawing
// module) must have no such data (docs/MODULE_CONTRACT.md, "A library as a
// module").
valid :: proc "contextless" (setting: Setting, value: u32) -> u32 {
	count: u32
	switch setting {
	case .Font:
		count = len(Font)
	case .Subpixel_Order:
		count = len(Subpixel_Order)
	case .Pointer_Theme:
		count = len(Pointer_Theme)
	case .Grid_Fit:
		count = len(Grid_Fit)
	}
	return value < count ? value : 0
}

// values_differ tells whether two choices have different values. The count
// of changes is not compared: the program `settings` can change the count
// with no end and leave the values as they were, and a reader that acts on
// each new count then does work for nothing (the compositor tells every
// window, and a window ring that is full loses the keys of the input).
values_differ :: proc "contextless" (first, second: Choice) -> bool {
	for setting in Setting {
		if first.values[setting] != second.values[setting] {
			return true
		}
	}
	return false
}

// READ_TRIES: the most reads of a page that changes, or that its writer
// left in the middle of a change (change_count odd). A reader does not wait
// for the writer.
READ_TRIES :: 64

// read copies the choice of a page that another program writes. It reads
// again while the page changes, at most READ_TRIES times; then it gives the
// defaults (all values 0) with the count that it saw, so a writer that
// stops in a change, or changes the page with no end, changes the look of
// the other programs and never stops them.
read :: proc "contextless" (page: ^Page) -> Choice {
	before: u32
	for _ in 0 ..< READ_TRIES {
		before = intrinsics.atomic_load_explicit(&page.change_count, .Acquire)
		if before & 1 != 0 {
			continue
		}
		choice: Choice
		for setting in Setting {
			choice.values[setting] = valid(setting, intrinsics.atomic_load_explicit(&page.values[setting], .Relaxed))
		}
		intrinsics.atomic_thread_fence(.Acquire)
		if intrinsics.atomic_load_explicit(&page.change_count, .Relaxed) == before {
			choice.change_count = before
			return choice
		}
	}
	return {change_count = before}
}

// write changes the values of the page. The one writer is the program
// `settings`; it wakes the waiters after (it owns the kernel calls, this
// package has none).
write :: proc "contextless" (page: ^Page, values: [Setting]u32) {
	intrinsics.atomic_store_explicit(&page.change_count, page.change_count + 1, .Release)
	intrinsics.atomic_thread_fence(.Release)
	for setting in Setting {
		intrinsics.atomic_store_explicit(&page.values[setting], valid(setting, values[setting]), .Relaxed)
	}
	intrinsics.atomic_store_explicit(&page.change_count, page.change_count + 1, .Release)
}

// Kept_Settings: the record of the private store of `settings`, 48 bytes,
// little-endian. A record with another magic or version is not used: the
// defaults hold.
KEPT_MAGIC :: u64(0x53474E4954544553) // The bytes "SETTINGS".
KEPT_VERSION :: 1

Kept_Settings :: struct {
	magic:   u64,
	version: u32,
	count:   u32, // The values that follow: the count of Setting when it was written.
	values:  [SETTING_CAPACITY]u32,
}
#assert(size_of(Kept_Settings) == 48)

// kept_of makes the record of a choice.
kept_of :: proc "contextless" (values: [Setting]u32) -> (kept: Kept_Settings) {
	kept.magic, kept.version, kept.count = KEPT_MAGIC, KEPT_VERSION, len(Setting)
	for setting in Setting {
		kept.values[setting] = values[setting]
	}
	return kept
}

// kept_read reads a record from its bytes: ok is false for bytes that are
// not a record of this version. A value that a setting does not have is
// its default.
kept_read :: proc "contextless" (bytes: []u8) -> (values: [Setting]u32, ok: bool) {
	if len(bytes) != size_of(Kept_Settings) {
		return {}, false
	}
	kept: Kept_Settings // A copy: the bytes can be at any alignment.
	intrinsics.mem_copy_non_overlapping(&kept, raw_data(bytes), size_of(kept))
	if kept.magic != KEPT_MAGIC || kept.version != KEPT_VERSION || kept.count > SETTING_CAPACITY {
		return {}, false
	}
	for setting in Setting {
		if u32(setting) < kept.count {
			values[setting] = valid(setting, kept.values[setting])
		}
	}
	return values, true
}
