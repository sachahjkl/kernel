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
// end at MODULES_END or before: support/system (load.odin) refuses a
// module that passes it.
package fixed_addresses

import op "contract:operation"

// The band of the fixed ranges: one slot of 1 TiB for each range.
BAND_START :: 0x0000_3000_0000_0000
SLOT :: 0x0000_0100_0000_0000
SLOT_COUNT :: 16
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
Fixed_Range :: enum u8 {
	Module_Files, // The files of a module and of its imports, in the program that runs the module (contract:isolated).
	Pointer_Themes, // The pointer themes of the compositor, one after the other (programs/root).
	Settings_Page, // The settings page (contract:settings).
	Glyph_Cache, // The glyph caches of the text of the system (contract:settings).
	Glyph_Cache_Without_Grid_Fit,
	Glyph_Cache_Bold,
	Date_Page, // The date page (contract:date).
	Storage_File, // The file of the storage service (support/storage).
	Module_Tables, // The tables of the parameters of one export, in the program that receives the call (contract:isolated).
	Interface_Glyph_Cache, // The glyph cache of the interface font, regular weight (contract:settings).
	Interface_Glyph_Cache_Bold, // The glyph cache of the interface font, bold weight.
	Debug_Image, // The debug image, read-only: the debug objects of the modules, by the hash of each module (contract:debug_object).
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

Address_Range :: struct {
	address: u64,
	span:    u64,
}

// range_of gives the address and the span of a range.
range_of :: proc "contextless" (range: Fixed_Range) -> Address_Range {
	return {address = BAND_START + SLOT * u64(range), span = RANGE_SPAN}
}
