// The settings of the person (docs/FONTS.md, "The setting"): one page that
// the root service creates. The program `settings` is its one writer; each
// program with a surface or a terminal, and the compositor, map it with the
// right Read only, at PAGE_ADDRESS. The context value VALUE_PAGE says where
// it is (0: the program has no page, and its text is Spleen).
//
// Each setting is one value of the page and one row of `descriptions`: its
// name and the names of its values. Value 0 of each setting is its default
// (ZII): an all-zero page is the vector font with the grid fit, red green
// blue, the pointer theme of the owner when the boot image has it.
//
// The page also names the two glyph caches of the vector font (with and
// without the grid fit): the root service maps these resources of the boot
// image read-only in the same programs, after it checked their hashes.
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

PAGE_ADDRESS :: 0x0000_3200_0000_0000
GLYPH_CACHE_ADDRESS :: 0x0000_3300_0000_0000
GLYPH_CACHE_WITHOUT_GRID_FIT_ADDRESS :: 0x0000_3400_0000_0000
VALUE_PAGE :: 13 // The value of the context with the address of the page. The system fixes it for each program (contract:operation, Context).
GRANT_PAGE :: 12 // The handle of the context of the program `settings`: the page, with Read and Write.
VALUE_BOOT_PASS :: 15 // The program `settings` (the values 9 to 12 are its random seed): 1 for the pass at boot (read the kept record, write the page, stop).
KEPT_OBJECT_NAME :: "settings" // The object of the private store of `settings` that holds Kept_Settings.

// The settings, in the order of the page and of the window.
Setting :: enum u32 {
	Font           = 0,
	Subpixel_Order = 1,
	Pointer_Theme  = 2,
	Grid_Fit       = 3,
}

// The values of each setting. 0 is the default.
Font :: enum u32 {
	Vector = 0, // The vector font of the glyph cache.
	Spleen = 1, // The bitmap font Spleen 8x16: the fallback, and a choice of the person.
}

// The order of the color stripes of the pixels of the screen, from the left.
Subpixel_Order :: enum u32 {
	Red_Green_Blue = 0,
	Blue_Green_Red = 1,
	None           = 2, // Grayscale: a screen with no stripes in rows, or a screenshot to read.
}

Pointer_Theme :: enum u32 {
	Of_The_Owner  = 0, // The first theme of pointer_pictures.RESOURCE_PREFERENCE that the boot image has.
	Of_The_System = 1, // The theme of the system (resources/pointers/system.manifest).
}

Grid_Fit :: enum u32 {
	On  = 0, // The baseline, the x-height and the cap height on whole pixels (docs/FONTS.md, "Grid fit").
	Off = 1, // The shapes of the design: the glyph cache with no grid fit.
}

SETTING_CAPACITY :: 8 // The page and the kept record have room for 8 values.
VALUE_NAME_CAPACITY :: 4

// Description: the name of a setting and the names of its values, for the
// exports and the window of `settings`.
Description :: struct {
	name:        string,
	title:       string, // For the window.
	value_names: [VALUE_NAME_CAPACITY]string,
	value_count: u32,
}

descriptions := [Setting]Description {
	.Font           = {"font", "font", {"vector", "spleen", "", ""}, 2},
	.Subpixel_Order = {"subpixel_order", "subpixel order", {"rgb", "bgr", "none", ""}, 3},
	.Pointer_Theme  = {"pointer_theme", "pointer theme", {"owner", "system", "", ""}, 2},
	.Grid_Fit       = {"grid_fit", "grid fit", {"on", "off", "", ""}, 2},
}

Page :: struct {
	change_count:                     u32, // Even when the page is stable. Each change adds 2.
	reserved:                         u32,
	values:                           [SETTING_CAPACITY]u32, // By Setting.
	// The root service writes the rest before any program starts.
	glyph_cache_address:              u64, // 0: no glyph cache (the image has none, or its hash is wrong).
	glyph_cache_size:                 u64,
	glyph_cache_hash:                 [32]u8,
	glyph_cache_without_grid_fit_address: u64,
	glyph_cache_without_grid_fit_size:    u64,
}
#assert(size_of(Page) <= 4096)

// Choice: the values of a page, as one copy.
Choice :: struct {
	values:       [Setting]u32,
	change_count: u32,
}

font_of :: #force_inline proc "contextless" (choice: Choice) -> Font {
	return Font(choice.values[.Font])
}

subpixel_order_of :: #force_inline proc "contextless" (choice: Choice) -> Subpixel_Order {
	return Subpixel_Order(choice.values[.Subpixel_Order])
}

pointer_theme_of :: #force_inline proc "contextless" (choice: Choice) -> Pointer_Theme {
	return Pointer_Theme(choice.values[.Pointer_Theme])
}

grid_fit_of :: #force_inline proc "contextless" (choice: Choice) -> Grid_Fit {
	return Grid_Fit(choice.values[.Grid_Fit])
}

// valid gives the value, or the default 0 for a value that the setting does
// not have (a page or a record of a later version).
valid :: proc "contextless" (setting: Setting, value: u32) -> u32 {
	return value < descriptions[setting].value_count ? value : 0
}

// read copies the choice of a page that another program writes. It reads
// again while the page changes.
read :: proc "contextless" (page: ^Page) -> Choice {
	for {
		before := intrinsics.atomic_load_explicit(&page.change_count, .Acquire)
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
