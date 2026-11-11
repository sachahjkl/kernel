// The fixed addresses of the mappings that the system gives a program: one
// table of named ranges, an address and a span for each. The owner of each
// range (the contract that describes what is mapped there) takes its
// address from here.
//
// One program can receive several of these mappings at one time: the root
// service gives each program with a surface the settings page, the glyph
// caches and the date page, and the same program can also have the files
// of its modules, a storage file or the pointer themes. So no two ranges
// overlap, and the compiler checks it below. A mapping that a program
// places by its own choice (a test page, a measure) goes outside the band,
// at OWN_CHOICE_START or after.
package fixed_addresses

import op "contract:operation"

// The band of the fixed ranges: one slot of 1 TiB for each range.
BAND_START :: 0x0000_3000_0000_0000
SLOT :: 0x0000_0100_0000_0000
BAND_END :: BAND_START + 16 * SLOT
// The first address of a mapping that a program places by its own choice.
OWN_CHOICE_START :: BAND_END

// Where the caller maps the files of a module and of its imports, in the
// program that runs the module (contract:isolated).
MODULE_FILES_ADDRESS :: BAND_START + 0 * SLOT
MODULE_FILES_SPAN :: SLOT
// The pointer themes of the compositor, one after the other (programs/root).
POINTER_THEMES_ADDRESS :: BAND_START + 1 * SLOT
POINTER_THEMES_SPAN :: SLOT
// The settings page (contract:settings).
SETTINGS_PAGE_ADDRESS :: BAND_START + 2 * SLOT
SETTINGS_PAGE_SPAN :: SLOT
// The glyph caches of the text of the system (contract:settings).
GLYPH_CACHE_ADDRESS :: BAND_START + 3 * SLOT
GLYPH_CACHE_SPAN :: SLOT
GLYPH_CACHE_WITHOUT_GRID_FIT_ADDRESS :: BAND_START + 4 * SLOT
GLYPH_CACHE_WITHOUT_GRID_FIT_SPAN :: SLOT
GLYPH_CACHE_BOLD_ADDRESS :: BAND_START + 5 * SLOT
GLYPH_CACHE_BOLD_SPAN :: SLOT
// The date page (contract:date).
DATE_PAGE_ADDRESS :: BAND_START + 6 * SLOT
DATE_PAGE_SPAN :: SLOT
// The file of the storage service (support/storage).
STORAGE_FILE_ADDRESS :: BAND_START + 7 * SLOT
STORAGE_FILE_SPAN :: SLOT
// The tables of the parameters of one export, in the program that receives
// the call (contract:isolated): one sub-range for each parameter.
MODULE_TABLES_ADDRESS :: BAND_START + 8 * SLOT
MODULE_TABLES_SPAN :: SLOT

// The ranges in the order of their addresses: each one ends at or before
// the start of the next, so no two overlap.
#assert(MODULE_FILES_ADDRESS >= BAND_START)
#assert(MODULE_FILES_ADDRESS + MODULE_FILES_SPAN <= POINTER_THEMES_ADDRESS)
#assert(POINTER_THEMES_ADDRESS + POINTER_THEMES_SPAN <= SETTINGS_PAGE_ADDRESS)
#assert(SETTINGS_PAGE_ADDRESS + SETTINGS_PAGE_SPAN <= GLYPH_CACHE_ADDRESS)
#assert(GLYPH_CACHE_ADDRESS + GLYPH_CACHE_SPAN <= GLYPH_CACHE_WITHOUT_GRID_FIT_ADDRESS)
#assert(GLYPH_CACHE_WITHOUT_GRID_FIT_ADDRESS + GLYPH_CACHE_WITHOUT_GRID_FIT_SPAN <= GLYPH_CACHE_BOLD_ADDRESS)
#assert(GLYPH_CACHE_BOLD_ADDRESS + GLYPH_CACHE_BOLD_SPAN <= DATE_PAGE_ADDRESS)
#assert(DATE_PAGE_ADDRESS + DATE_PAGE_SPAN <= STORAGE_FILE_ADDRESS)
#assert(STORAGE_FILE_ADDRESS + STORAGE_FILE_SPAN <= MODULE_TABLES_ADDRESS)
#assert(MODULE_TABLES_ADDRESS + MODULE_TABLES_SPAN <= BAND_END)
// The band is after the addresses that the kernel chooses and the modules,
// and inside the addresses of a program.
#assert(BAND_START >= op.MODULE_BASE + SLOT)
#assert(BAND_END <= op.USER_END)

// The same ranges as a table, for a test and for a reader that lists them.
Fixed_Range :: enum u8 {
	Module_Files,
	Pointer_Themes,
	Settings_Page,
	Glyph_Cache,
	Glyph_Cache_Without_Grid_Fit,
	Glyph_Cache_Bold,
	Date_Page,
	Storage_File,
	Module_Tables,
}

Address_Range :: struct {
	address: u64,
	span:    u64,
}

ranges := [Fixed_Range]Address_Range {
	.Module_Files                 = {MODULE_FILES_ADDRESS, MODULE_FILES_SPAN},
	.Pointer_Themes               = {POINTER_THEMES_ADDRESS, POINTER_THEMES_SPAN},
	.Settings_Page                = {SETTINGS_PAGE_ADDRESS, SETTINGS_PAGE_SPAN},
	.Glyph_Cache                  = {GLYPH_CACHE_ADDRESS, GLYPH_CACHE_SPAN},
	.Glyph_Cache_Without_Grid_Fit = {GLYPH_CACHE_WITHOUT_GRID_FIT_ADDRESS, GLYPH_CACHE_WITHOUT_GRID_FIT_SPAN},
	.Glyph_Cache_Bold             = {GLYPH_CACHE_BOLD_ADDRESS, GLYPH_CACHE_BOLD_SPAN},
	.Date_Page                    = {DATE_PAGE_ADDRESS, DATE_PAGE_SPAN},
	.Storage_File                 = {STORAGE_FILE_ADDRESS, STORAGE_FILE_SPAN},
	.Module_Tables                = {MODULE_TABLES_ADDRESS, MODULE_TABLES_SPAN},
}
