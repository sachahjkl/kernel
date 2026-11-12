// The pages of the modules (docs/SITE.md, "The reference tables"): an index,
// and one page for each module of module_builds. A page gives the
// documentation of the module, its exports as the console prints them, its
// imports, and for a program what the root service gives it. Each fact is
// read from the source that the build reads: the list of the builds, the
// source of the module (describe.odin), and the root service.
package kerneltool

import "core:fmt"
import "core:strings"
import module "contract:module"
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
		site_value_link(b, .Module, site_page_link(site, from_page, item.page), name, false)
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
		site_module_link(site, b, site_page_file(SITE_GRANTS_FOLDER), name)
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

	modules_page := site_page_file(SITE_MODULES_FOLDER)
	// The index.
	{
		b := strings.builder_make(context.temp_allocator)
		in_image := 0
		for item in reference.modules {
			in_image += item.build.image ? 1 : 0
		}
		fmt.sbprintf(&b, "<h1>Modules</h1>\n<p>The %d modules that the tool builds, %d of them in the boot image. A kernel runs in kernel mode; a program is a module whose source is in <code>programs/</code>; the others are modules that a program loads or calls. The purpose of each is the first sentence of the comment before <code>package</code> in its source.</p>\n", len(reference.modules), in_image)
		// One table for each group, in the order of the tree of the documentation.
		for group in Site_Module_Group {
			count := 0
			for item in reference.modules {
				count += site_module_group(item) == group ? 1 : 0
			}
			if count == 0 {
				continue
			}
			fmt.sbprintf(&b, "<h2 id=\"%s\">%s</h2>\n", site_module_group_ids[group], site_module_group_titles[group])
			modules_table := site_table_start(&b, site_module_group_titles[group], {{"Module", .Name}, {"Boot image", .Short}, {"Exports", .Number}, {"Imports", .Prose}, {"Purpose", .Prose}}, {.Module, .None, .None, .Module, .None})
			for item in reference.modules {
				if site_module_group(item) != group {
					continue
				}
				fmt.sbprintf(&b, "<tr id=\"module-%s\"><td class=\"code name\">", site_slug(item.build.name))
				site_module_link(site, &b, modules_page, item.build.name)
				// A column of two states: each cell has the icon of its state.
				strings.write_string(&b, "</td><td>")
				site_value(&b, item.build.image ? Site_Value_Kind.Yes : Site_Value_Kind.No, item.build.image ? "yes" : "no", true)
				fmt.sbprintf(&b, "</td><td>%d</td><td>", len(item.description.exports))
				for name, index in item.build.imports {
					if index > 0 {
						strings.write_string(&b, ", ")
					}
					site_module_link(site, &b, modules_page, name)
				}
				strings.write_string(&b, "</td>")
				// A summary: the page of the module shows the whole text with its references.
				site_text_cell(&b, site_source_comment_plain(site, item.description.about))
				strings.write_string(&b, "</tr>\n")
			}
			site_table_end(&b, modules_table)
		}
		strings.write_string(&b, "<p class=\"source\">Read from <code>module_builds</code> in <a href=\"")
		site_escape(&b, site_repository_file(site, SITE_MODULES_FILE))
		strings.write_string(&b, "\"><code>" + SITE_MODULES_FILE + "</code></a> and from the source folder of each module.</p>\n")
		site_page_add(site, Site_Page{path = modules_page, is_index = true, title = "Modules", description = site_description_cut(fmt.tprintf("The %d modules and programs of %s, %d of them in the boot image, with their purpose, their exports and their imports.", len(reference.modules), SITE_SYSTEM_NAME, in_image)), section = .Reference, crumbs = site_crumbs(.Reference), body = strings.to_string(b), sources = site_sources(SITE_MODULES_FILE), layout = .Documentation})
		append(entries, Site_Reference_Entry{path = modules_page, title = "Modules", what = "Each module and program, with a page for each: its documentation, its exports, its imports, and for a program its grants and its budget.", source = SITE_MODULES_FILE})
	}

	// One page for each module. The list of the builds holds the comment
	// above the row of a module with settings of its own.
	modules_text, _ := site_read_quiet(SITE_MODULES_FILE)
	crumbs := make([dynamic]Site_Crumb, context.temp_allocator)
	append(&crumbs, ..site_crumbs(.Reference))
	append(&crumbs, Site_Crumb{title = "Modules", path = modules_page})
	for item in reference.modules {
		build := item.build
		description := item.description
		b := strings.builder_make(context.temp_allocator)
		title := fmt.tprintf("The %s %s", item.kind, build.name)
		strings.write_string(&b, "<h1>")
		site_escape(&b, title)
		strings.write_string(&b, "</h1>\n<div class=\"prose\">\n")
		// A build of the source of another module with settings of its own
		// says so first: the documentation below is the comment of that
		// source, which describes the other module.
		if len(build.defines) > 0 {
			site_module_build_note(site, &b, item, modules_text)
		}
		// The documentation text: one paragraph for each line (text_of),
		// then the references to the documents that it names.
		site_source_comment(site, &b, item.page, description.text, .Paragraphs)
		strings.write_string(&b, "</div>\n")

		// The facts of the build.
		facts_table := site_table_start(&b, "Facts", {{"Fact", .Short}, {"Value", .Prose}})
		fmt.sbprintf(&b, "<tr><td>Kind</td><td><a href=\"%s#%s\">%s</a></td></tr>\n", site_page_link(site, item.page, modules_page), site_module_group_ids[site_module_group(item)], site_module_group_titles[site_module_group(item)])
		// The facts hold values of several kinds: each value has its icon.
		strings.write_string(&b, "<tr><td>Source</td><td class=\"name\">")
		site_value_link(&b, .File, site_folder_address(site, build.source), build.source, true)
		strings.write_string(&b, "</td></tr>\n<tr><td>Boot image</td><td>")
		if !build.image {
			site_value(&b, .No, "no", true)
			strings.write_string(&b, ": not in the boot image")
		} else if entry, found := site_boot_image_entry(site, build.name); found {
			site_value(&b, .Yes, "yes", true)
			strings.write_string(&b, ": in the boot image, ")
			site_value(&b, .Size, fmt.tprintf("%d bytes", entry.size), true)
			strings.write_string(&b, " in this build")
		} else if len(site.boot_image) == 0 {
			site_value(&b, .Yes, "yes", true)
			strings.write_string(&b, ": in the boot image; the image is not built, so its size is not known")
		} else {
			site_value(&b, .No, "no", true)
			strings.write_string(&b, ": in the list of the boot image, not in the image of the last build")
		}
		strings.write_string(&b, "</td></tr>\n")
		if build.kernel {
			strings.write_string(&b, "<tr><td>Mode</td><td>runs in kernel mode</td></tr>\n")
		}
		// The settings of the compiler for this module only: two modules of
		// one source differ by them.
		strings.write_string(&b, "<tr><td>Build settings</td><td class=\"code\">")
		if len(build.defines) == 0 {
			strings.write_string(&b, "none: the defaults of the source")
		}
		for define, index in build.defines {
			if index > 0 {
				strings.write_string(&b, ", ")
			}
			strings.write_string(&b, "<code>")
			site_escape(&b, define)
			strings.write_string(&b, "</code>")
		}
		strings.write_string(&b, "</td></tr>\n")
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

		// The exports: a summary table, then each export as a documented
		// symbol, as a package page of a programming language shows it.
		fmt.sbprintf(&b, "<h2 id=\"exports\">Exports</h2>\n")
		if len(description.exports) == 0 {
			strings.write_string(&b, "<p>No export.</p>\n")
		} else {
			exports_table := site_table_start(&b, "Exports", {{"Export", .Name}, {"What it does", .Prose}})
			for export in description.exports {
				fmt.sbprintf(&b, "<tr><td class=\"code name\"><a href=\"#export-%s\"><code>", site_slug(export.name))
				site_escape(&b, site_export_signature(description, export))
				strings.write_string(&b, "</code></a></td>")
				site_text_cell(&b, site_source_comment_plain(site, export.about))
				strings.write_string(&b, "</tr>\n")
			}
			site_table_end(&b, exports_table)
			for export in description.exports {
				site_export_symbol_write(site, &b, item.page, build.name, description, export)
			}
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
			fmt.sbprintf(&b, "<tr><td><a href=\"%s#programs\">Grants</a></td>", site_page_link(site, item.page, site_page_file(SITE_GRANTS_FOLDER)))
			site_name_cell(site, &b, grants.value, SITE_ROOT_FILE, grants.line)
			site_comment_cell(site, &b, item.page, named_in_grants ? grants.comment : "Not named in grants_of: the grants of each other program.")
			strings.write_string(&b, "</tr>\n<tr><td>Budget: pages, programs, threads</td>")
			site_name_cell(site, &b, budget.value, SITE_ROOT_FILE, budget.line)
			site_comment_cell(site, &b, item.page, named_in_budget ? budget.comment : "Not named in things_of: the budget of each other program.")
			strings.write_string(&b, "</tr>\n")
			site_table_end(&b, budget_table)
			fmt.sbprintf(&b, "<p class=\"source\">Read from <code>grants_of</code> and <code>things_of</code> in <a href=\"%s\"><code>%s</code></a>; <code>budget_of</code> in the same file adds the limits of processor time and of log records.</p>\n", site_repository_file(site, SITE_ROOT_FILE), SITE_ROOT_FILE)
			append(&sources, SITE_ROOT_FILE)
		}
		about := description.about != "" ? site_source_comment_plain(site, description.about) : "no documentation"
		if len(build.defines) > 0 {
			about = strings.concatenate({"its source ", build.source, " built with ", strings.join(build.defines, ", ", context.temp_allocator)}, context.temp_allocator)
		}
		site_page_add(site, Site_Page{path = item.page, title = title, description = site_description_cut(fmt.tprintf("The %s %s of %s: %s.", item.kind, build.name, SITE_SYSTEM_NAME, about)), section = .Reference, crumbs = crumbs[:], body = strings.to_string(b), sources = sources[:], layout = .Documentation})
	}
}

// site_module_build_note writes the first paragraph of a module that is a
// build of the source of another module with settings of its own: "The
// module kernel built with the setting ...", then the comment above its row
// in module_builds, which says why it exists.
site_module_build_note :: proc(site: ^Site, b: ^strings.Builder, item: Site_Module, modules_text: string) {
	same_source := ""
	for other in site.reference.modules {
		if other.build.name != item.build.name && other.build.source == item.build.source && len(other.build.defines) == 0 {
			same_source = other.build.name
			break
		}
	}
	strings.write_string(b, "<p>")
	if other_item, found := site_module_by_name(site, same_source); found {
		// A link in a sentence: no colored value in running prose.
		fmt.sbprintf(b, "The module <a href=\"%s\"><code>", site_page_link(site, item.page, other_item.page))
		site_escape(b, same_source)
		strings.write_string(b, "</code></a> built with ")
	} else {
		strings.write_string(b, "The source <code>")
		site_escape(b, item.build.source)
		strings.write_string(b, "</code> built with ")
	}
	strings.write_string(b, len(item.build.defines) == 1 ? "the setting " : "the settings ")
	for define, index in item.build.defines {
		if index > 0 {
			strings.write_string(b, ", ")
		}
		strings.write_string(b, "<code>")
		site_escape(b, define)
		strings.write_string(b, "</code>")
	}
	strings.write_string(b, ". The text after this paragraph is the comment of that source.</p>\n")
	if comment := site_comment_above(modules_text, strings.concatenate({"\t{name = \"", item.build.name, "\","}, context.temp_allocator)); comment != "" {
		site_source_comment(site, b, item.page, comment, .Paragraphs)
	}
}

// site_export_symbol_write writes one export of a module as a documented
// symbol: its signature as the console prints it, the text of its comment,
// its parameters, its result, how it fails, and its line in the source. The
// rules that give these facts are those of the build (describe.odin): no
// fact is typed here.
site_export_symbol_write :: proc(site: ^Site, b: ^strings.Builder, page, module_name: string, description: Module_Description, export: Export_Description) {
	facts := make([dynamic]Site_Symbol_Fact, context.temp_allocator)
	if export.name == ENTRY_NAME {
		append(&facts, Site_Symbol_Fact{label = "Form", html = site_text_html("The entry of the module: one parameter, an address, fixed by the contract.")})
	} else {
		// Each type opens its card: the wire form and the record.
		parameters := strings.builder_make(context.temp_allocator)
		for type, index in export.parameters {
			if index > 0 {
				strings.write_string(&parameters, ", ")
			}
			name := index < len(export.names) ? export.names[index] : ""
			detail: u32 = index < len(export.details) ? export.details[index] : 0
			direction: module.Direction = index < len(export.directions) ? export.directions[index] : .Read
			strings.write_string(&parameters, "<code class=\"value value-type\">")
			site_escape(&parameters, name)
			strings.write_string(&parameters, ": ")
			strings.write_string(&parameters, site_type_html(site, module_name, description, type, detail, direction, true))
			strings.write_string(&parameters, "</code>")
		}
		if len(export.parameters) == 0 {
			strings.write_string(&parameters, "none")
		}
		append(&facts, Site_Symbol_Fact{label = "Parameters", kind = .Type, html = strings.to_string(parameters)})
		result: string = export.result == .None ? site_value_html(.Type, "none") : strings.concatenate({"<code class=\"value value-type\">", site_type_html(site, module_name, description, export.result, export.result_detail, .Read, false), "</code>"}, context.temp_allocator)
		append(&facts, Site_Symbol_Fact{label = "Result", kind = .Type, html = result})
		if export.error_record != 0 {
			// The rule of the build: an export with an error record fails
			// when its result is negative, and writes the record.
			record_name := "an error record"
			if int(export.error_record) <= len(description.records) {
				record_name = description.records[export.error_record - 1].name
			}
			append(&facts, Site_Symbol_Fact{label = "When it fails", html = strings.concatenate({site_text_html("a negative result, and the error record "), site_type_reference_html(site, site_module_record_key(module_name, record_name), record_name, true)}, context.temp_allocator)})
		}
	}
	site_symbol_write(site, b, Site_Symbol{id = strings.concatenate({"export-", site_slug(export.name)}, context.temp_allocator), name = export.name, signature = site_export_signature(description, export), signature_html = site_export_signature_html(site, module_name, description, export), description = export.text, page = page, facts = facts[:], source = export.file, line = export.line})
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
			fmt.sbprintf(b, "<a href=\"%s\">", site_page_link(site, page, item.page))
			site_escape(b, entry.name)
			strings.write_string(b, "</a>")
		} else {
			site_escape(b, entry.name)
		}
		strings.write_string(b, "</li>\n")
	}
	strings.write_string(b, "</ul>\n")
	if built {
		fmt.sbprintf(b, "<p class=\"source\">%d modules, %d KiB, in <code>%s</code> of the last build. A tile is a module: its width follows its size, and is at least the width of its name; its color comes from its hash, as the boot display draws it.</p>\n", len(entries), (total - 1) / 1024, BOOT_IMAGE)
	} else {
		fmt.sbprintf(b, "<p class=\"missing\">The boot image is not built: the tiles are the modules of <code>module_builds</code> that it holds, with no size and no color.</p>\n")
	}
	strings.write_string(b, "</section>\n")
	site.tile_rules = strings.to_string(rules)
}
