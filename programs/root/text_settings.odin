package root

import "contract:glyph_cache"
import "contract:settings"
import op "contract:operation"
import "support:graphics"
import "support:system"

// The text of the system and the settings of the person (docs/FONTS.md):
// this service creates the settings page, checks the hashes of the two
// glyph caches of the boot image once, draws the boot display with the
// default one, and maps the page and the caches read-only into each
// program with a surface, into each terminal and into the compositor. The
// program `settings` receives the page with Write.
//
// The boot display is drawn before the storage service runs: it uses the
// defaults (the vector font with the grid fit, red green blue). At the end
// of the boot this service starts `settings` for its boot pass: it reads the
// settings kept in its private store and writes the page; the compositor
// sees the change and each window draws again.

GLYPH_CACHE_RESOURCE :: "glyph_cache"
GLYPH_CACHE_WITHOUT_GRID_FIT_RESOURCE :: "glyph_cache_no_grid_fit"
GLYPH_CACHE_BOLD_RESOURCE :: "glyph_cache_bold"

settings_memory: system.Handle
settings_page: ^settings.Page
glyph_cache_mappings: [3]system.Mapping // page_count 0: no such glyph cache.
// The boot pass of `settings` is the next start of that name: start() gives
// it the value VALUE_BOOT_PASS.
settings_boot_pass: bool

// text_settings_create makes the settings page and finds the glyph caches.
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
	if mapping, size, given := resource_mapping(GLYPH_CACHE_WITHOUT_GRID_FIT_RESOURCE, settings.GLYPH_CACHE_WITHOUT_GRID_FIT_ADDRESS, "each program with a surface"); given {
		glyph_cache_mappings[1] = mapping
		settings_page.glyph_cache_without_grid_fit_address = settings.GLYPH_CACHE_WITHOUT_GRID_FIT_ADDRESS
		settings_page.glyph_cache_without_grid_fit_size = size
	}
	if mapping, size, given := resource_mapping(GLYPH_CACHE_BOLD_RESOURCE, settings.GLYPH_CACHE_BOLD_ADDRESS, "each program with a surface"); given {
		glyph_cache_mappings[2] = mapping
		settings_page.glyph_cache_bold_address = settings.GLYPH_CACHE_BOLD_ADDRESS
		settings_page.glyph_cache_bold_size = size
	}
	mapping, size, given := resource_mapping(GLYPH_CACHE_RESOURCE, settings.GLYPH_CACHE_ADDRESS, "each program with a surface")
	if !given {
		system.log_in("programs", .Warning, "root: the boot image has no valid glyph cache: the text of the system is Spleen 8x16")
		return
	}
	glyph_cache_mappings[0] = mapping
	entry := system.image_resource_find(image, GLYPH_CACHE_RESOURCE)
	settings_page.glyph_cache_address = settings.GLYPH_CACHE_ADDRESS
	settings_page.glyph_cache_size = size
	settings_page.glyph_cache_hash = entry.hash
	// The boot display: the cache in the image that this service maps. The
	// line of resource_mapping says that the hash is right; a refusal of the
	// format has a line of its own.
	if problem := graphics.text_cache_set(image[entry.offset:][:entry.size]); problem.kind != .None {
		system.log_in("programs", .Warning, "root: the glyph cache is refused: problem ", u64(problem.kind), ", value ", problem.value, ": the boot display is Spleen 8x16")
	}
	if bold := system.image_resource_find(image, GLYPH_CACHE_BOLD_RESOURCE); bold != nil && glyph_cache_mappings[2].page_count != 0 {
		if cache, problem := glyph_cache.validate(image[bold.offset:][:bold.size]); problem.kind == .None {
			graphics.text_bold_cache_use(cache)
		}
	}
}

// text_settings_give adds the settings page and the glyph caches,
// read-only, to the mappings of a program that has a surface or a terminal,
// and the address of the page to its values.
text_settings_give :: proc "contextless" (mappings: []system.Mapping, count: ^int, values: ^[op.CONTEXT_VALUES]u64) {
	if settings_page == nil || count^ + 1 + len(glyph_cache_mappings) > len(mappings) {
		return
	}
	mappings[count^] = {memory = settings_memory, address = settings.PAGE_ADDRESS, first = 0, page_count = 1}
	count^ += 1
	for mapping in glyph_cache_mappings {
		if mapping.page_count != 0 {
			mappings[count^] = mapping
			count^ += 1
		}
	}
	values[settings.VALUE_PAGE] = settings.PAGE_ADDRESS
}

// settings_boot_pass_start starts `settings` for its boot pass: it reads
// the settings kept in its private store, writes the page, and stops. The
// storage service starts first, with the block service of the data disk.
// A machine with no data disk keeps the defaults.
settings_boot_pass_start :: proc "contextless" () {
	settings_boot_pass = true
	status := start("settings")
	settings_boot_pass = false
	if status != .Ok {
		system.log_in("programs", .Warning, "root: the boot pass of settings did not start (status ", u64(status), "): the settings are the defaults")
	}
}
