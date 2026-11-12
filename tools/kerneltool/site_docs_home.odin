// The home of the docs (docs/SITE.md, "The home of the docs"): a door to
// the guides and to the reference. Its large search field is the search of
// the page, and the bar of the page has none. Under the field: what the
// search knows, a card for each part of the docs, and a row of doors. Every
// count comes from the data that the pages and the index of the search show;
// no count is typed.
package kerneltool

import "core:fmt"
import "core:strings"

// The guides that the card of the guides lists, the first in the reading
// order of the page of the guides.
SITE_DOCS_HOME_FIRST_GUIDES :: 6

// One part of the reference on the home of the docs: its page, what it
// holds, and the count of the things on it.
Site_Docs_Reference_Part :: struct {
	title:  string,
	what:   string,
	folder: string,
	count:  int,
}

// site_docs_reference_parts gives the parts of the reference that a reader
// looks for first, in the order of the card, each with the count of what
// its page shows. The index of the reference lists every table.
site_docs_reference_parts :: proc(site: ^Site) -> []Site_Docs_Reference_Part {
	// The operation of number 0 is not an operation: its page and the
	// search leave it out.
	operation_count := 0
	for operation in site.reference.operations {
		operation_count += operation.member.number != 0 ? 1 : 0
	}
	tool_commands := COMMANDS
	parts := make([dynamic]Site_Docs_Reference_Part, context.temp_allocator)
	append(&parts, Site_Docs_Reference_Part{title = "Kernel operations", what = "What a program asks the kernel, with its parameters and its statuses.", folder = SITE_OPERATIONS_FOLDER, count = operation_count})
	append(&parts, Site_Docs_Reference_Part{title = "Types", what = "The types of the contract and of the modules: the size, the alignment, the fields.", folder = SITE_TYPES_FOLDER, count = len(site.types)})
	append(&parts, Site_Docs_Reference_Part{title = "Modules", what = "Each module and program: its exports, its imports, its documentation.", folder = SITE_MODULES_FOLDER, count = len(site.reference.modules)})
	append(&parts, Site_Docs_Reference_Part{title = "Commands of the console", what = "The commands that the console has before it loads a module.", folder = SITE_CONSOLE_FOLDER, count = len(site.reference.console_commands)})
	append(&parts, Site_Docs_Reference_Part{title = "Commands of kerneltool", what = "The commands of the one tool of the project.", folder = SITE_COMMANDS_FOLDER, count = len(tool_commands)})
	append(&parts, Site_Docs_Reference_Part{title = "Glossary", what = "One term for each concept, with its definition.", folder = SITE_GLOSSARY_FOLDER, count = len(site.terms)})
	append(&parts, Site_Docs_Reference_Part{title = "Measured numbers", what = "The numbers that the machine tests print, each with its log.", folder = SITE_NUMBERS_FOLDER, count = len(site.measured)})
	return parts[:]
}

// site_search_kind_words gives the name of a kind of entry for a count:
// "1 term", "3 terms", "2 properties"; "news" has one form.
site_search_kind_words :: proc(kind: Site_Search_Kind, count: int) -> string {
	name := site_search_kind_names[kind]
	if count == 1 || kind == .News {
		return name
	}
	if strings.has_suffix(name, "y") {
		return strings.concatenate({name[:len(name) - 1], "ies"}, context.temp_allocator)
	}
	return strings.concatenate({name, "s"}, context.temp_allocator)
}

// site_docs_search_knows writes what the search knows: the count of the
// entries of the index, and of each kind that has entries, in the tie order
// of the kinds.
site_docs_search_knows :: proc(b: ^strings.Builder, entries: []Site_Search_Entry) {
	counts: [Site_Search_Kind]int
	for entry in entries {
		counts[entry.kind] += 1
	}
	fmt.sbprintf(b, "<p class=\"docs-knows\">The search knows %d entries: ", len(entries))
	written := 0
	for kind in Site_Search_Kind {
		if counts[kind] == 0 {
			continue
		}
		if written > 0 {
			strings.write_string(b, ", ")
		}
		fmt.sbprintf(b, "%d %s", counts[kind], site_search_kind_words(kind, counts[kind]))
		written += 1
	}
	strings.write_string(b, ". Every other page searches the same index from the field of its bar.</p>\n")
}

// site_docs_home_add records the home of the docs, with no text yet: its
// text says what the index of the search holds, and the index is made from
// the pages (site_docs_home_fill). Its title and its description, which the
// index reads, are known now.
site_docs_home_add :: proc(site: ^Site) {
	description := site_description_cut(fmt.tprintf("The docs of %s: %d guides on how each part is designed and why, %d reference tables generated from the code, and one search over the whole site.", SITE_SYSTEM_NAME, len(site.guides), len(site.reference_entries)))
	site_page_add(site, Site_Page{path = site_section_page(.Docs), is_index = true, title = site_section_titles[.Docs], description = description, section = .Docs, crumbs = site_crumbs(.Home), sources = site_sources(SITE_README_FILE), search_in_page = true})
}

// site_docs_home_fill writes the text of the home of the docs, once the
// entries of the index of the search are known.
site_docs_home_fill :: proc(site: ^Site, entries: []Site_Search_Entry) {
	path := site_section_page(.Docs)
	for &page in site.pages {
		if page.path == path {
			page.body = site_docs_home_body(site, path, entries)
		}
	}
}

// site_docs_home_body gives the text of the home of the docs: the heading,
// the search field of the page, what the search knows, the card of the
// guides, the card of the reference, and the doors.
site_docs_home_body :: proc(site: ^Site, path: string, entries: []Site_Search_Entry) -> string {
	b := strings.builder_make(context.temp_allocator)
	guides_page := site_section_page(.Guides)
	reference_page := site_section_page(.Reference)

	fmt.sbprintf(&b, "<div class=\"docs-head\">\n<h1>%s</h1>\n", site_section_titles[.Docs])
	fmt.sbprintf(&b, "<p class=\"lead\">How %s works. The guides explain how each part is designed, and why; the reference states what exists in this build, generated from the code.</p>\n</div>\n", SITE_SYSTEM_NAME)
	// The search field of this page; with no script it stays hidden, and
	// the cards under it carry the page.
	strings.write_string(&b, site_search_field_html(.Docs_Home))
	site_docs_search_knows(&b, entries)

	strings.write_string(&b, "<div class=\"docs-parts\">\n")
	if site_page_exists(site, guides_page) {
		strings.write_string(&b, "<section class=\"card accent-kernel\" aria-labelledby=\"guides\">\n")
		fmt.sbprintf(&b, "<h2 id=\"guides\"><a href=\"%s\">%s</a></h2>\n", site_page_link(site, path, guides_page), site_section_titles[.Guides])
		fmt.sbprintf(&b, "<p>A guide is a document of the repository: how one part of %s is designed, and why. %d guides; the first ones in their reading order:</p>\n<ol>\n", SITE_SYSTEM_NAME, len(site.guides))
		for guide, index in site.guides {
			if index == SITE_DOCS_HOME_FIRST_GUIDES {
				break
			}
			fmt.sbprintf(&b, "<li><a href=\"%s\">", site_page_link(site, path, guide.path))
			site_escape(&b, guide.title)
			strings.write_string(&b, "</a></li>\n")
		}
		fmt.sbprintf(&b, "</ol>\n<p><a href=\"%s\">All %d guides</a></p>\n</section>\n", site_page_link(site, path, guides_page), len(site.guides))
	}
	if site_page_exists(site, reference_page) {
		strings.write_string(&b, "<section class=\"card accent-memory\" aria-labelledby=\"reference\">\n")
		fmt.sbprintf(&b, "<h2 id=\"reference\"><a href=\"%s\">%s</a></h2>\n", site_page_link(site, path, reference_page), site_section_titles[.Reference])
		strings.write_string(&b, "<p>What exists in this build, generated from the code and from the files that define each thing. Each row of a table links to its line in the source.</p>\n")
		parts_table := site_table_start(&b, "What the reference holds", {{"Part", .Prose}, {"What it holds", .Prose}, {"Count", .Number}})
		for part in site_docs_reference_parts(site) {
			part_page := site_page_file(part.folder)
			if !site_page_exists(site, part_page) {
				continue
			}
			fmt.sbprintf(&b, "<tr><td><a href=\"%s\">", site_page_link(site, path, part_page))
			site_escape(&b, part.title)
			strings.write_string(&b, "</a></td><td>")
			site_escape(&b, part.what)
			fmt.sbprintf(&b, "</td><td>%d</td></tr>\n", part.count)
		}
		site_table_end(&b, parts_table)
		fmt.sbprintf(&b, "<p><a href=\"%s\">All %d reference tables</a></p>\n</section>\n", site_page_link(site, path, reference_page), len(site.reference_entries))
	}
	strings.write_string(&b, "</div>\n")

	// The doors: where a reader starts, and the pages of the state of the
	// system that are not docs.
	strings.write_string(&b, "<h2 id=\"start\">Where to start</h2>\n<ul class=\"doors\">\n")
	if len(site.guides) > 0 {
		fmt.sbprintf(&b, "<li><a href=\"%s\">Read first: ", site_page_link(site, path, site.guides[0].path))
		site_escape(&b, site.guides[0].title)
		strings.write_string(&b, "</a></li>\n")
	}
	if status_page := site_section_page(.Status); site_page_exists(site, status_page) {
		fmt.sbprintf(&b, "<li><a href=\"%s\">The state of the %d properties</a></li>\n", site_page_link(site, path, status_page), len(site.principles.properties))
	}
	if releases_page := site_section_page(.Releases); site_page_exists(site, releases_page) {
		release_link := strings.concatenate({releases_page, "#", site_release_id(site.release)}, context.temp_allocator)
		fmt.sbprintf(&b, "<li><a href=\"%s\">The newest release, %s</a></li>\n", site_page_link(site, path, release_link), site.release)
	}
	if news_page := site_section_page(.News); site_page_exists(site, news_page) {
		fmt.sbprintf(&b, "<li><a href=\"%s\">%s</a></li>\n", site_page_link(site, path, news_page), site_section_titles[.News])
	}
	fmt.sbprintf(&b, "<li><a href=\"%s\">The repository</a></li>\n</ul>\n", SITE_REPOSITORY_ADDRESS)
	return strings.to_string(b)
}
