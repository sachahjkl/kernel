// The settings of the person (docs/FONTS.md, "The setting"): one page that
// the root service creates. The program `settings` is its one writer; each
// program with a surface or a terminal, and the compositor, map it with the
// right Read only, at PAGE_ADDRESS. The context value VALUE_PAGE says where
// it is (0: the program has no page, and its text is Spleen).
//
// The page also names the glyph cache of the vector font: the root service
// maps that resource of the boot image read-only at GLYPH_CACHE_ADDRESS in
// the same programs, after it checked its hash.
//
// A change: the writer makes change_count odd, writes the fields, makes it
// even again, and wakes the threads that wait on it (the compositor). The
// compositor then sends the display event Settings_Changed to each window,
// and each program draws again. A reader copies the fields while
// change_count stays even and the same (read).
//
// All zero is valid (ZII): the vector font, red green blue.
package settings

import "base:intrinsics"

PAGE_ADDRESS :: 0x0000_3200_0000_0000
GLYPH_CACHE_ADDRESS :: 0x0000_3300_0000_0000
VALUE_PAGE :: 13 // The value of the context with the address of the page. The system fixes it for each program (contract:operation, Context).
GRANT_PAGE :: 12 // The handle of the context of the program `settings`: the page, with Read and Write.

// The setting "font".
Font :: enum u32 {
	Vector = 0, // The default: the vector font of the glyph cache.
	Spleen = 1, // The bitmap font Spleen 8x16: the fallback, and a choice of the person.
}

// The setting "subpixel_order": the order of the color stripes of the
// pixels of the screen, from the left.
Subpixel_Order :: enum u32 {
	Red_Green_Blue = 0,
	Blue_Green_Red = 1,
	None           = 2, // Grayscale: a screen with no stripes in rows, or a screenshot to read.
}

Page :: struct {
	change_count:        u32, // Even when the page is stable. Each change adds 2.
	font:                Font,
	subpixel_order:      Subpixel_Order,
	reserved:            u32,
	glyph_cache_address: u64, // The root service writes these three before any program starts.
	glyph_cache_size:    u64, // 0: no glyph cache (the image has none, or its hash is wrong).
	glyph_cache_hash:    [32]u8,
}
#assert(size_of(Page) <= 4096)

// Choice: the fields that a program uses, as one copy.
Choice :: struct {
	font:           Font,
	subpixel_order: Subpixel_Order,
	change_count:   u32,
}

// read copies the choice of a page that another program writes. It reads
// again while the page changes.
read :: proc "contextless" (page: ^Page) -> Choice {
	for {
		before := volatile_read(&page.change_count)
		if before & 1 != 0 {
			continue
		}
		choice := Choice{font = Font(volatile_read((^u32)(&page.font))), subpixel_order = Subpixel_Order(volatile_read((^u32)(&page.subpixel_order))), change_count = before}
		if volatile_read(&page.change_count) == before {
			// A value from a later version of the page is not known here: the default.
			if u32(choice.font) > u32(max(Font)) {
				choice.font = .Vector
			}
			if u32(choice.subpixel_order) > u32(max(Subpixel_Order)) {
				choice.subpixel_order = .Red_Green_Blue
			}
			return choice
		}
	}
}

// write changes the choice. The one writer is the program `settings`; it
// wakes the waiters after (it owns the kernel calls, this package has none).
write :: proc "contextless" (page: ^Page, font: Font, order: Subpixel_Order) {
	volatile_write(&page.change_count, page.change_count + 1)
	volatile_write((^u32)(&page.font), u32(font))
	volatile_write((^u32)(&page.subpixel_order), u32(order))
	volatile_write(&page.change_count, page.change_count + 1)
}

@(private)
volatile_read :: #force_inline proc "contextless" (place: ^u32) -> u32 {
	return intrinsics.atomic_load_explicit(place, .Acquire)
}

@(private)
volatile_write :: #force_inline proc "contextless" (place: ^u32, value: u32) {
	intrinsics.atomic_store_explicit(place, value, .Release)
}

// The names of the settings and of their values, for the exports of the
// program `settings` and for its window.
font_names := [Font]string {
	.Vector = "vector",
	.Spleen = "spleen",
}

subpixel_order_names := [Subpixel_Order]string {
	.Red_Green_Blue = "rgb",
	.Blue_Green_Red = "bgr",
	.None           = "none",
}
