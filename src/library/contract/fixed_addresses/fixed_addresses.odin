// The fixed addresses of the mappings that the system gives a program: one
// table of named ranges. The owner of each range (the contract that
// describes what is mapped there) takes its address from here.
//
// One program can receive several of these mappings at one time: the root
// service gives each program with a surface the settings page, the glyph
// caches and the date page, and the same program can also have the files
// of its modules, a storage file or the pointer themes. So no two ranges
// overlap.
//
// The enumeration Fixed_Range is the table, and the only place of a range:
// the range of a member is the slot of its number, and each named address
// below is the address of a member. A new range is a new member; an
// address written another way is not a fixed range. So two ranges cannot
// overlap, and the compiler checks that the band holds every member.
//
// An address of the band has no other source than this table. No other
// file computes an address from BAND_START or SLOT: `kerneltool check`
// refuses a file of contract, support, programs or modules outside this
// folder that names them (tools/kerneltool/fixed_addresses_check.odin).
//
// A mapping that a program places by its own choice goes outside the
// band, at OWN_CHOICE_START or after. The modules that a program loads
// end at MODULES_END or before: src/library/support/system (load.odin) refuses a
// module that passes it.
//
// Example: the settings page of each program with a surface is at
// `SETTINGS_PAGE_ADDRESS`, 0x0000_3200_0000_0000: the slot 2 of the band.
// A program reads it only when the bit `Settings_Page` of
// `ranges_mapped(&ctx.values)` is set.
//
// See [fixed range](term:fixed-range) and [mapped ranges](term:mapped-ranges).
package fixed_addresses

import op "modus:contract/operation"

// The band of the fixed ranges: one slot of 1 TiB for each range.
BAND_START :: 0x0000_3000_0000_0000
SLOT :: 0x0000_0100_0000_0000 // 1 TiB: the addresses of one range.
SLOT_COUNT :: 16 // The slots of the band: the most members of Fixed_Range.
BAND_END :: BAND_START + SLOT_COUNT * SLOT
// The first address of a mapping that a program places by its own choice.
OWN_CHOICE_START :: BAND_END
// The end of the addresses where a program loads its modules, from
// op.MODULE_BASE: the band starts there.
MODULES_END :: BAND_START
// The span of each range: one slot.
RANGE_SPAN :: SLOT

// The table of the fixed ranges: a new range is a new member, and its
// address is its slot. A constant written by hand in the band, with no
// member, is not a fixed range, and the check of the tool refuses it.
//
// A starter maps a range in its child before the child runs. For the
// settings page, the glyph caches, the date page and the debug image, it
// also sets the bit of the range in the value 20 of the context of the
// child (`range_mapped_add`). The child reads nothing at a range whose bit
// is clear (`ranges_mapped`): an address that is not mapped faults at the
// first read, and the bit tells the child before it reads. The other
// ranges come with their size in a value of the context.
Fixed_Range :: enum u8 {
	Module_Files, // The files of a module and of its imports, in the program that runs the module (modus:contract/isolated).
	// A call host finds there, read-only, the module that it runs, its
	// imports and the replacement records, as one list in the form of the
	// boot image. The console or the root service maps them before the
	// call host starts, and states their size in the values of its
	// context: a call host has no handle to the boot image, so it cannot
	// look for them.
	Pointer_Themes, // The pointer themes of the compositor, one after the other (src/programs/root).
	// The root service maps the theme files of the boot image there,
	// read-only, in the compositor, and gives the address and the size of
	// each one in the values of its context.
	Settings_Page, // The settings page (modus:contract/settings).
	// One page, read-only, that the program `settings` writes and every
	// program with a surface or a terminal reads: the value of each setting
	// of the machine. The root service maps it. A program reads a change at
	// its next read of the page, with no message.
	Glyph_Cache, // The glyph caches of the text of the system (modus:contract/settings).
	// The glyphs of the default font of the text, fitted to the grid of
	// the pixels, drawn once at build time. The root service maps it,
	// read-only, beside the settings page; each program draws text from it
	// and draws no glyph itself.
	Glyph_Cache_Without_Grid_Fit,
	// The glyphs of the default font with no fit to the grid of the
	// pixels, for the setting that chooses them. Mapped as the cache
	// above.
	Glyph_Cache_Bold,
	// The glyphs of the emphasis weight of the default font. Mapped as the
	// cache above.
	Date_Page, // The date page (modus:contract/date).
	// One page, read-only, that the program `date` writes from the
	// real-time clock: each program reads the date of the day there with
	// no call. The root service maps it.
	Storage_File, // The file of the storage service (src/library/support/storage).
	// The file of the program of the storage service, read-only, in a
	// program that the root service connects to the storage service at its
	// start: the program reads the descriptions of the exports there. The
	// root service maps it, and gives its size at the value 3 of the
	// context.
	Module_Tables, // The tables of the parameters of one export, in the program that receives the call (modus:contract/isolated).
	// A receiver maps the memory object of each table parameter there for
	// the time of one call: the parameter n at `TABLE_ADDRESS` plus n
	// times 16 GiB. The same addresses at each call cost no new page
	// tables, where an address that the kernel chooses would.
	Interface_Glyph_Cache, // The glyph cache of the interface font, regular weight (modus:contract/settings).
	// The glyphs of the proportional font of the windows. Mapped as the
	// glyph caches above.
	Interface_Glyph_Cache_Bold, // The glyph cache of the interface font, bold weight.
	// Mapped as the glyph caches above.
	Debug_Image, // The debug image, read-only: the debug objects of the modules, by the hash of each module (modus:contract/debug_object).
	// The root service maps it in a program that prints stop reports, as
	// the console, and gives its size at the value 21 of the context. The
	// report then names the procedure and the line of each frame.
}
#assert(int(max(Fixed_Range)) < SLOT_COUNT)

// Fixed_Ranges: a set of ranges, one bit for each member. The value
// op.CONTEXT_VALUE_FIXED_RANGES_MAPPED of the context of a program is the
// set that its starter mapped. A bit past the last member has no meaning.
Fixed_Ranges :: bit_set[Fixed_Range;u64]
#assert(size_of(Fixed_Ranges) == size_of(u64))

// ranges_mapped gives the ranges that the starter of a program mapped for it.
ranges_mapped :: proc "contextless" (values: ^[op.CONTEXT_VALUES]u64) -> Fixed_Ranges {
	return transmute(Fixed_Ranges)values[op.CONTEXT_VALUE_FIXED_RANGES_MAPPED]
}

// range_mapped_add is for a starter: it states in the values of its child
// that it maps a range.
range_mapped_add :: proc "contextless" (values: ^[op.CONTEXT_VALUES]u64, range: Fixed_Range) {
	values[op.CONTEXT_VALUE_FIXED_RANGES_MAPPED] = transmute(u64)(ranges_mapped(values) + {range})
}

// The band is after the addresses that the kernel chooses and the modules,
// and inside the addresses of a program.
#assert(BAND_START >= op.MODULE_BASE + SLOT)
#assert(BAND_END <= op.USER_END)

// The address of each range: the first byte of its slot.
MODULE_FILES_ADDRESS :: BAND_START + SLOT * u64(Fixed_Range.Module_Files)
POINTER_THEMES_ADDRESS :: BAND_START + SLOT * u64(Fixed_Range.Pointer_Themes)
SETTINGS_PAGE_ADDRESS :: BAND_START + SLOT * u64(Fixed_Range.Settings_Page)
GLYPH_CACHE_ADDRESS :: BAND_START + SLOT * u64(Fixed_Range.Glyph_Cache)
GLYPH_CACHE_WITHOUT_GRID_FIT_ADDRESS :: BAND_START + SLOT * u64(Fixed_Range.Glyph_Cache_Without_Grid_Fit)
GLYPH_CACHE_BOLD_ADDRESS :: BAND_START + SLOT * u64(Fixed_Range.Glyph_Cache_Bold)
DATE_PAGE_ADDRESS :: BAND_START + SLOT * u64(Fixed_Range.Date_Page)
STORAGE_FILE_ADDRESS :: BAND_START + SLOT * u64(Fixed_Range.Storage_File)
MODULE_TABLES_ADDRESS :: BAND_START + SLOT * u64(Fixed_Range.Module_Tables)
INTERFACE_GLYPH_CACHE_ADDRESS :: BAND_START + SLOT * u64(Fixed_Range.Interface_Glyph_Cache)
INTERFACE_GLYPH_CACHE_BOLD_ADDRESS :: BAND_START + SLOT * u64(Fixed_Range.Interface_Glyph_Cache_Bold)
DEBUG_IMAGE_ADDRESS :: BAND_START + SLOT * u64(Fixed_Range.Debug_Image)

// The addresses of one range.
Address_Range :: struct {
	address: u64, // The first byte of the range.
	span:    u64, // The bytes of addresses of the range: RANGE_SPAN.
}

// range_of gives the address and the span of a range.
range_of :: proc "contextless" (range: Fixed_Range) -> Address_Range {
	return {address = BAND_START + SLOT * u64(range), span = RANGE_SPAN}
}
