package root

import "contract:settings"
import "support:graphics"
import "support:system"

// The text of the system and the settings of the person (docs/FONTS.md):
// this service creates the settings page, checks the hash of the glyph
// cache of the boot image once, draws the boot display with it, and maps the
// two read-only into each program with a surface, into each terminal and
// into the compositor. The program `settings` receives the page with Write.

GLYPH_CACHE_RESOURCE :: "glyph_cache"

settings_memory: system.Handle
settings_page: ^settings.Page
glyph_cache_mapping: system.Mapping // page_count 0: no glyph cache.

// text_settings_create makes the settings page and finds the glyph cache.
// With no cache, or a cache whose hash is wrong, each program draws with
// Spleen 8x16, and the log says why.
text_settings_create :: proc "contextless" () {
	status: system.Status
	settings_memory, status = system.memory_create(1)
	address: rawptr
	if status == .Ok {
		address, status = system.memory_map(settings_memory)
	}
	if status != .Ok {
		fail("cannot create the settings page", status)
	}
	settings_page = (^settings.Page)(address)
	mapping, size, given := resource_mapping(GLYPH_CACHE_RESOURCE, settings.GLYPH_CACHE_ADDRESS, "each program with a surface")
	if !given {
		system.log_in("programs", .Warning, "root: the boot image has no valid glyph cache: the text of the system is Spleen 8x16")
		return
	}
	glyph_cache_mapping = mapping
	entry := system.image_resource_find(image, GLYPH_CACHE_RESOURCE)
	settings_page.glyph_cache_address = settings.GLYPH_CACHE_ADDRESS
	settings_page.glyph_cache_size = size
	settings_page.glyph_cache_hash = entry.hash
	// The boot display: the cache in the image that this service maps.
	start := system.nanoseconds()
	problem := graphics.text_cache_set(image[entry.offset:][:entry.size])
	spent := system.nanoseconds() - start
	if problem.kind != .None {
		system.log_in("programs", .Warning, "root: the glyph cache is refused: problem ", u64(problem.kind), ", value ", problem.value, ": the boot display is Spleen 8x16")
		return
	}
	system.log("root: the glyph cache of the vector font is valid, ", size, " bytes, checked in ", spent / 1000, " us; the boot display draws with it")
}

// text_settings_give adds the settings page and the glyph cache, read-only,
// to the mappings of a program that has a surface or a terminal, and the
// address of the page to its values.
text_settings_give :: proc "contextless" (mappings: []system.Mapping, count: ^int, values: ^[16]u64) {
	if settings_page == nil || count^ + 2 > len(mappings) {
		return
	}
	mappings[count^] = {memory = settings_memory, address = settings.PAGE_ADDRESS, first = 0, page_count = 1}
	count^ += 1
	if glyph_cache_mapping.page_count != 0 {
		mappings[count^] = glyph_cache_mapping
		count^ += 1
	}
	values[settings.VALUE_PAGE] = settings.PAGE_ADDRESS
}
