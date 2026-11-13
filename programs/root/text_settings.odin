package root

import "contract:fixed_addresses"
import "contract:glyph_cache"
import "support:bootscreen"
import "support:display"
import "contract:settings"
import op "contract:operation"
import "support:graphics"
import "support:system"

// The text of the system and the settings of the person (docs/FONTS.md):
// this service creates the settings page, checks the hashes and the format
// of the glyph caches of the boot image once, draws the boot display with the
// default one, and maps the page and the caches read-only into each
// program with a surface, into each terminal and into the compositor. The
// program `settings` receives the page with Write.
//
// The boot display is drawn before the storage service runs: it uses the
// defaults (the vector font with the grid fit, red green blue). At the end
// of the boot this service starts `settings` for its boot pass: it reads the
// settings kept in its private store and writes the page; the compositor
// sees the change and each window draws again.

// The resource of the boot image of each glyph cache.
glyph_cache_resources := [settings.Glyph_Cache]string {
	.With_Grid_Fit    = "glyph_cache",
	.Without_Grid_Fit = "glyph_cache_no_grid_fit",
	.Bold             = "glyph_cache_bold",
	.Interface        = "interface_glyph_cache",
	.Interface_Bold   = "interface_glyph_cache_bold",
}

settings_memory: system.Handle
boot_interface_font: display.Interface_Font // The interface font of the boot display, from the boot image.
settings_page: ^settings.Page
glyph_cache_mappings: [settings.Glyph_Cache]system.Mapping // page_count 0: no such glyph cache.
// The boot pass of `settings` is the next start of that name: start() gives
// it the value VALUE_BOOT_PASS.
settings_boot_pass: bool

// text_settings_create makes the settings page and finds the glyph caches.
// Each cache is given only when its hash is right (resource_mapping) and
// its format is valid: a resource shorter than the header of a cache, or
// whose header states another size than the resource, is not given, so a
// program that reads the size in the header reads only mapped bytes. With
// no cache of the text of cells, each program draws with Spleen 8x16, and
// the log says why.
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
	caches: [settings.Glyph_Cache]glyph_cache.Cache
	for name, cache in glyph_cache_resources {
		place := fixed_addresses.range_of(settings.glyph_cache_ranges[cache])
		mapping, _, given := resource_mapping(name, place.address, "each program with a surface")
		if !given {
			continue
		}
		entry := system.image_resource_find(image, name)
		problem: glyph_cache.Problem
		caches[cache], problem = glyph_cache.validate(image[entry.offset:][:entry.size])
		if problem.kind != .None {
			system.log_in("programs", .Warning, "root: the glyph cache ", name, " is refused: ", glyph_cache.problem_sentences[problem.kind], ", value ", problem.value, ": it is not given")
			continue
		}
		glyph_cache_mappings[cache] = mapping
	}
	if glyph_cache_mappings[.With_Grid_Fit].page_count == 0 {
		system.log_in("programs", .Warning, "root: the boot image has no valid glyph cache: the text of the system is Spleen 8x16")
		return
	}
	// The boot display: the caches in the image that this service maps.
	if problem := graphics.text_cache_use(caches[.With_Grid_Fit]); problem.kind != .None {
		system.log_in("programs", .Warning, "root: the glyph cache is refused: ", glyph_cache.problem_sentences[problem.kind], ": the boot display is Spleen 8x16")
	}
	if glyph_cache_mappings[.Bold].page_count != 0 {
		graphics.text_bold_cache_use(caches[.Bold])
	}
	// The boot display: its titles and the names of its facts in the
	// interface font, from the same caches that the programs receive.
	interface_given := glyph_cache_mappings[.Interface].page_count != 0 && glyph_cache_mappings[.Interface_Bold].page_count != 0
	if interface_given && caches[.Interface].header.flags & glyph_cache.FLAG_PROPORTIONAL != 0 && caches[.Interface_Bold].header.flags & glyph_cache.FLAG_PROPORTIONAL != 0 {
		boot_interface_font = {regular = caches[.Interface], bold = caches[.Interface_Bold]}
		bootscreen.interface_font_use(&boot_interface_font)
	}
}

// text_settings_give adds the settings page and the glyph caches,
// read-only, to the mappings of a program that has a surface or a terminal,
// and sets the bit of each range in its values. A cache mapping has no
// flag: the right Read only, for every program, the program `settings`
// included. The pages come from the boot image, whose one handle (of this
// service) has no right Write.
text_settings_give :: proc "contextless" (mappings: []system.Mapping, count: ^int, values: ^[op.CONTEXT_VALUES]u64) {
	if settings_page == nil || count^ + 1 + len(glyph_cache_mappings) > len(mappings) {
		return
	}
	mappings[count^] = {memory = settings_memory, address = settings.PAGE_ADDRESS, first = 0, page_count = 1}
	count^ += 1
	fixed_addresses.range_mapped_add(values, .Settings_Page)
	for mapping, cache in glyph_cache_mappings {
		if mapping.page_count != 0 {
			mappings[count^] = mapping
			mappings[count^].flags = {}
			count^ += 1
			fixed_addresses.range_mapped_add(values, settings.glyph_cache_ranges[cache])
		}
	}
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
		system.log_in("programs", .Warning, "root: the boot pass of settings did not start (status ", status, "): the settings are the defaults")
	}
}
