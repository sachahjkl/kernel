// The pages of the modules (docs/SITE.md, "The reference tables"): an index,
// and one page for each module of module_builds. A page gives the
// documentation of the module, its exports as the console prints them, its
// imports, and for a program what the root service gives it. Each fact is
// read from the source that the build reads: the list of the builds, the
// source of the module (describe.odin), and the root service.
package kerneltool

import "core:fmt"
import "core:strings"
import "support:graphics"

// site_module_by_name gives the module of module_builds with this name.
site_module_by_name :: proc(site: ^Site, name: string) -> (item: Site_Module, found: bool) {
	for candidate in site.reference.modules {
		if candidate.build.name == name {
			return candidate, true
		}
	}
	return {}, false
}

// site_module_link writes the name of a module as a link to its page, from
// a page of the site.
site_module_link :: proc(site: ^Site, b: ^strings.Builder, from_page, name: string) {
	if item, found := site_module_by_name(site, name); found {
		fmt.sbprintf(b, "<a href=\"%s\"><code>", site_relative(from_page, item.page))
		site_escape(b, name)
		strings.write_string(b, "</code></a>")
		return
	}
	strings.write_string(b, "<code>")
	site_escape(b, name)
	strings.write_string(b, "</code>")
}

// site_program_names_cell writes the names of a case of the root service,
// each a link to the page of its module.
site_program_names_cell :: proc(site: ^Site, b: ^strings.Builder, names: []string) {
	strings.write_string(b, "<td class=\"code\">")
	for name, index in names {
		if index > 0 {
			strings.write_string(b, ", ")
		}
		site_module_link(site, b, SITE_GRANTS_PAGE, name)
	}
	strings.write_string(b, "</td>")
}

// site_case_of gives the case of a procedure of the root service that names
// a program, or the value for each other program.
site_case_of :: proc(cases: []Site_Name_Case, otherwise: Site_Name_Case, name: string) -> (item: Site_Name_Case, named: bool) {
	for candidate in cases {
		for case_name in candidate.names {
			if case_name == name {
				return candidate, true
			}
		}
	}
	return otherwise, false
}

// site_boot_image_entry gives the entry of a module in the boot image of
// the last build.
site_boot_image_entry :: proc(site: ^Site, name: string) -> (entry: Site_Image_Entry, found: bool) {
	for candidate in site.boot_image {
		if !candidate.resource && candidate.name == name {
			return candidate, true
		}
	}
	return {}, false
}

site_module_pages_add :: proc(site: ^Site, entries: ^[dynamic]Site_Reference_Entry) {
	reference := &site.reference

	// The index.
	{
		b := strings.builder_make(context.temp_allocator)
		in_image := 0
		for item in reference.modules {
			in_image += item.build.image ? 1 : 0
		}
		fmt.sbprintf(&b, "<h1>Modules</h1>\n<p>The %d modules that the tool builds, %d of them in the boot image. A program is a module whose source is in <code>programs/</code>; the others are modules that a program loads or calls. The purpose of each is the first sentence of the comment before <code>package</code> in its source.</p>\n", len(reference.modules), in_image)
		modules_table := site_table_start(&b, "Modules", {{"Module", .Name}, {"Kind", .Short}, {"Boot image", .Short}, {"Exports", .Number}, {"Imports", .Prose}, {"Purpose", .Prose}})
		for item in reference.modules {
			fmt.sbprintf(&b, "<tr id=\"module-%s\"><td class=\"code name\">", site_slug(item.build.name))
			site_module_link(site, &b, SITE_MODULES_PAGE, item.build.name)
			in_boot_image: string = item.build.image ? "yes" : "no"
			fmt.sbprintf(&b, "</td><td>%s</td><td>%s</td><td class=\"code\">%d</td><td class=\"code\">", item.kind, in_boot_image, len(item.description.exports))
			for name, index in item.build.imports {
				if index > 0 {
					strings.write_string(&b, ", ")
				}
				site_module_link(site, &b, SITE_MODULES_PAGE, name)
			}
			strings.write_string(&b, "</td>")
			site_text_cell(&b, item.description.about)
			strings.write_string(&b, "</tr>\n")
		}
		site_table_end(&b, modules_table)
		strings.write_string(&b, "<p class=\"source\">Read from <code>module_builds</code> in <a href=\"")
		site_escape(&b, site_repository_file(site, SITE_MODULES_FILE))
		strings.write_string(&b, "\"><code>" + SITE_MODULES_FILE + "</code></a> and from the source folder of each module.</p>\n")
		site_page_add(site, Site_Page{path = SITE_MODULES_PAGE, title = "Modules", description = site_description_cut(fmt.tprintf("The %d modules and programs of %s, %d of them in the boot image, with their purpose, their exports and their imports.", len(reference.modules), SITE_SYSTEM_NAME, in_image)), section = .Reference, crumbs = site_crumbs(.Reference), body = strings.to_string(b), sources = site_sources(SITE_MODULES_FILE)})
		append(entries, Site_Reference_Entry{path = SITE_MODULES_PAGE, title = "Modules", what = "Each module and program, with a page for each: its documentation, its exports, its imports, and for a program its grants and its budget.", source = SITE_MODULES_FILE})
	}

	// One page for each module.
	crumbs := make([dynamic]Site_Crumb, context.temp_allocator)
	append(&crumbs, ..site_crumbs(.Reference))
	append(&crumbs, Site_Crumb{title = "Modules", path = SITE_MODULES_PAGE})
	for item in reference.modules {
		build := item.build
		description := item.description
		b := strings.builder_make(context.temp_allocator)
		title := fmt.tprintf("The %s %s", item.kind, build.name)
		strings.write_string(&b, "<h1>")
		site_escape(&b, title)
		strings.write_string(&b, "</h1>\n<div class=\"prose\">\n")
		// The documentation text: one paragraph for each line (text_of).
		for paragraph in strings.split(description.text, "\n", context.temp_allocator) {
			if strings.trim_space(paragraph) == "" {
				continue
			}
			strings.write_string(&b, "<p>")
			site_escape(&b, strings.trim_space(paragraph))
			strings.write_string(&b, "</p>\n")
		}
		strings.write_string(&b, "</div>\n")

		// The facts of the build.
		facts_table := site_table_start(&b, "Facts", {{"Fact", .Short}, {"Value", .Prose}})
		strings.write_string(&b, "<tr><td>Source</td><td class=\"code name\"><a href=\"")
		site_escape(&b, site_folder_address(site, build.source))
		strings.write_string(&b, "\"><code>")
		site_escape(&b, build.source)
		strings.write_string(&b, "</code></a></td></tr>\n<tr><td>Boot image</td><td>")
		if !build.image {
			strings.write_string(&b, "not in the boot image")
		} else if entry, found := site_boot_image_entry(site, build.name); found {
			fmt.sbprintf(&b, "in the boot image, %d bytes in this build", entry.size)
		} else if len(site.boot_image) == 0 {
			strings.write_string(&b, "in the boot image; the image is not built, so its size is not known")
		} else {
			strings.write_string(&b, "in the list of the boot image, not in the image of the last build")
		}
		strings.write_string(&b, "</td></tr>\n")
		if build.kernel {
			strings.write_string(&b, "<tr><td>Mode</td><td>runs in kernel mode</td></tr>\n")
		}
		strings.write_string(&b, "<tr><td>Imports</td><td class=\"code\">")
		if len(build.imports) == 0 {
			strings.write_string(&b, "none")
		}
		for name, index in build.imports {
			if index > 0 {
				strings.write_string(&b, ", ")
			}
			site_module_link(site, &b, item.page, name)
		}
		strings.write_string(&b, "</td></tr>\n<tr><td>Imported by</td><td class=\"code\">")
		importers := 0
		for other in reference.modules {
			for name in other.build.imports {
				if name == build.name {
					if importers > 0 {
						strings.write_string(&b, ", ")
					}
					site_module_link(site, &b, item.page, other.build.name)
					importers += 1
				}
			}
		}
		if importers == 0 {
			strings.write_string(&b, "none")
		}
		strings.write_string(&b, "</td></tr>\n")
		site_table_end(&b, facts_table)

		// The exports.
		fmt.sbprintf(&b, "<h2 id=\"exports\">Exports</h2>\n")
		if len(description.exports) == 0 {
			strings.write_string(&b, "<p>No export.</p>\n")
		} else {
			exports_table := site_table_start(&b, "Exports", {{"Export", .Name}, {"What it does", .Prose}})
			for export in description.exports {
				fmt.sbprintf(&b, "<tr id=\"export-%s\">", site_slug(export.name))
				site_text_cell(&b, site_export_signature(description, export), "code name")
				site_text_cell(&b, export.about)
				strings.write_string(&b, "</tr>\n")
			}
			site_table_end(&b, exports_table)
		}
		fmt.sbprintf(&b, "<p class=\"source\">Read from the source of the module, as the build reads it to describe the exports (<a href=\"%s\"><code>tools/kerneltool/describe.odin</code></a>).</p>\n", site_repository_file(site, "tools/kerneltool/describe.odin"))

		// What the root service gives a program.
		sources := make([dynamic]string, context.temp_allocator)
		append(&sources, SITE_MODULES_FILE, build.source)
		if item.kind == "program" {
			grants, named_in_grants := site_case_of(reference.program_grants, reference.grants_otherwise, build.name)
			budget, named_in_budget := site_case_of(reference.program_budgets, reference.budget_otherwise, build.name)
			strings.write_string(&b, "<h2 id=\"root\">What the root service gives it</h2>\n")
			budget_table := site_table_start(&b, "Grants and budget", {{"What", .Short}, {"Value", .Short}, {"As the root service says", .Prose}})
			strings.write_string(&b, "<tr><td><a href=\"../grants.html#programs\">Grants</a></td>")
			site_name_cell(site, &b, grants.value, SITE_ROOT_FILE, grants.line)
			site_text_cell(&b, named_in_grants ? grants.comment : "Not named in grants_of: the grants of each other program.")
			strings.write_string(&b, "</tr>\n<tr><td>Budget: pages, programs, threads</td>")
			site_name_cell(site, &b, budget.value, SITE_ROOT_FILE, budget.line)
			site_text_cell(&b, named_in_budget ? budget.comment : "Not named in things_of: the budget of each other program.")
			strings.write_string(&b, "</tr>\n")
			site_table_end(&b, budget_table)
			fmt.sbprintf(&b, "<p class=\"source\">Read from <code>grants_of</code> and <code>things_of</code> in <a href=\"%s\"><code>%s</code></a>; <code>budget_of</code> in the same file adds the limits of processor time and of log records.</p>\n", site_repository_file(site, SITE_ROOT_FILE), SITE_ROOT_FILE)
			append(&sources, SITE_ROOT_FILE)
		}
		about := description.about != "" ? description.about : "no documentation"
		site_page_add(site, Site_Page{path = item.page, title = title, description = site_description_cut(fmt.tprintf("The %s %s of %s: %s.", item.kind, build.name, SITE_SYSTEM_NAME, about)), section = .Reference, crumbs = crumbs[:], body = strings.to_string(b), sources = sources[:]})
	}
}

// The tiles of the boot image on the home: as the boot display draws them
// (support/bootscreen), one tile for each module of the image of the last
// build, its width from its size, its color from the first byte of its hash
// (graphics.hue_color). The colors go into the style sheet: the pages hold
// no inline style.
SITE_TILE_ROWS :: 5
SITE_TILE_ROW_WIDTH :: 1088 // A card on a wide page: the page without its padding and the padding of the card.
SITE_TILE_LEAST :: 48

site_tiles_write :: proc(site: ^Site, b: ^strings.Builder, page: string) {
	entries := make([dynamic]Site_Image_Entry, context.temp_allocator)
	for entry in site.boot_image {
		if !entry.resource {
			append(&entries, entry)
		}
	}
	built := len(entries) > 0
	if !built {
		for build in module_builds {
			if build.image {
				append(&entries, Site_Image_Entry{name = build.name})
			}
		}
	}
	total: u64 = 1
	for entry in entries {
		total += entry.size
	}
	rules := strings.builder_make(context.temp_allocator)
	strings.write_string(b, "<section class=\"card accent-boot\" aria-labelledby=\"boot-image\">\n<h2 id=\"boot-image\">The boot image</h2>\n<ul class=\"tiles\">\n")
	for entry in entries {
		class := strings.concatenate({"tile-", site_slug(entry.name)}, context.temp_allocator)
		if built {
			width := max(int(entry.size * SITE_TILE_ROWS * SITE_TILE_ROW_WIDTH / total), SITE_TILE_LEAST)
			color := graphics.hue_color(entry.hash[0])
			fmt.sbprintf(&rules, ".tiles .%s {{ flex-basis: %dpx; background: linear-gradient(%s, %s); border-bottom-color: %s; color: %s; }}\n", class, width, site_color(graphics.shade(color, 70)), site_color(graphics.shade(color, 40)), site_color(color), site_color(graphics.shade(color, 175)))
		}
		fmt.sbprintf(b, "<li class=\"tile %s\">", class)
		if item, found := site_module_by_name(site, entry.name); found {
			fmt.sbprintf(b, "<a href=\"%s\">", site_relative(page, item.page))
			site_escape(b, entry.name)
			strings.write_string(b, "</a>")
		} else {
			site_escape(b, entry.name)
		}
		strings.write_string(b, "</li>\n")
	}
	strings.write_string(b, "</ul>\n")
	if built {
		fmt.sbprintf(b, "<p class=\"source\">%d modules, %d KiB, in <code>%s</code> of the last build. A tile is a module: its width is its size, and its color comes from its hash, as the boot display draws it.</p>\n", len(entries), (total - 1) / 1024, BOOT_IMAGE)
	} else {
		fmt.sbprintf(b, "<p class=\"missing\">The boot image is not built: the tiles are the modules of <code>module_builds</code> that it holds, with no size and no color.</p>\n")
	}
	strings.write_string(b, "</section>\n")
	site.tile_rules = strings.to_string(rules)
}
